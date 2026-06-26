import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// F8 Q&A — answer a question ON-DEVICE with Apple **Foundation Models**. Pure Swift-native path: retrieval is
/// done by `DocumentIndex` (e5/NLEmbedding, ranking only) and the retrieved excerpts are passed here as context;
/// generation happens on-device with no grounding/verification step.
///
/// RAW direction: there is no off-topic gate and the model is never told to refuse — it answers every question
/// freely, using the excerpts when relevant and its own knowledge otherwise. Requires macOS 26 + Apple
/// Intelligence (same gate as `SummarizationService`); callers steer to another model otherwise. Reuses
/// ``SummarizationError`` so the panel renders failures uniformly.
///
/// SESSION REUSE (per document): each open document keeps its OWN `LanguageModelSession` (keyed by the
/// document's index path) and REUSES it for every question. Reusing the same session object — instead of spinning
/// up a fresh one per question — (1) keeps the model warm (KV cache → faster first token) and (2) fixes an
/// intermittent `unsupportedLanguageOrLocale` misfire that hit short inputs ("what's the problem?") when each
/// question created a brand-new session. Sessions live in a process-wide dictionary keyed by document, guarded by
/// a lock (the app is multi-document — two windows can have a question in flight at once) and LRU-capped to bound
/// memory (closing a document doesn't notify us, so the cap is also the cleanup). The on-device context window
/// (~4096 tokens) is finite and the reused transcript accumulates, so a `contextWindowExceeded` transparently
/// recreates that document's session and retries the question once — the answer is never lost.
@available(macOS 26, *)
enum OnDeviceQA {

    // Per-document reused sessions, keyed by the document's index path. Guarded by `lock` because they're reached
    // from DocumentEngine.ask's `Task.detached` and the app is multi-document (two windows can have questions in
    // flight at once → a single shared static would data-race / route to the wrong session). LRU-capped to bound
    // memory (each session keeps a KV cache; closing a doc doesn't notify us, so the cap is the cleanup). Within
    // ONE document the UI serializes questions, so a given session is never used by two responses at once.
    private static let lock = NSLock()
    private static var sessions: [String: LanguageModelSession] = [:]
    private static var lru: [String] = []                       // documentKeys, oldest first
    private static let maxSessions = 3

    /// FIXED system instruction (never varies per question → the prefix that stays KV-cached across the reused
    /// session). RAW direction: dense, direct, no forced refusal. The explicit English directive double-enforces
    /// the English-only mode and further suppresses the short-input locale misdetection.
    private static let fromDocumentInstructions =
        "You are a reading assistant for the open document. Use the provided excerpts from the document to "
        + "answer the user's question. Answer directly and concisely — no preamble, no repetition, no filler. "
        + "Be thorough when the question needs depth, but don't pad. Always respond in English."

    /// The reused session for `key`, creating one on first use for this document. Thread-safe (lock-guarded).
    private static func currentSession(documentKey key: String) -> LanguageModelSession {
        lock.lock(); defer { lock.unlock() }
        if let s = sessions[key] { touch(key); return s }
        return install(LanguageModelSession(instructions: fromDocumentInstructions), for: key)
    }

    /// Start a FRESH session for `key` (transcript overflow), replacing this document's session. Same fixed
    /// instructions, so behavior is identical — only the accumulated conversation is dropped. Lock-guarded.
    @discardableResult
    private static func resetSession(documentKey key: String) -> LanguageModelSession {
        lock.lock(); defer { lock.unlock() }
        return install(LanguageModelSession(instructions: fromDocumentInstructions), for: key)
    }

    /// Store `s` as `key`'s session, mark it most-recently-used, and evict the oldest beyond the cap.
    /// PRECONDITION: `lock` is held.
    @discardableResult
    private static func install(_ s: LanguageModelSession, for key: String) -> LanguageModelSession {
        sessions[key] = s
        touch(key)
        while lru.count > maxSessions, let oldest = lru.first {
            lru.removeFirst()
            sessions[oldest] = nil
        }
        return s
    }

    /// Move `key` to most-recently-used. PRECONDITION: `lock` is held.
    private static func touch(_ key: String) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    /// F8 speed: warm the document's reused session BEFORE the first question, cutting first-token latency. The
    /// SAME session then answers (the old code prewarmed a throwaway session and answered on fresh ones). No-op
    /// when Apple Intelligence is unavailable. Cheap + idempotent.
    static func prewarm(documentKey key: String) {
        guard case .available = SummarizationService.availability() else { return }
        currentSession(documentKey: key).prewarm()
    }

    /// Answer using the retrieved `chunks` as context, on the document's reused session. On transcript overflow,
    /// recreate the session and retry once. Throws a distinct ``SummarizationError`` per failure — nothing swallowed.
    static func answerFromDocument(question: String, chunks: [String], documentKey key: String) async throws -> String {
        guard case .available = SummarizationService.availability() else {
            throw SummarizationError.unavailable(SummarizationService.availability())
        }
        let prompt = makePrompt(question: question, chunks: chunks)
        do {
            return try await respond(currentSession(documentKey: key), to: prompt)
        } catch let e as SummarizationError {
            guard case .contextWindowExceeded = e else { throw e }
            return try await respond(resetSession(documentKey: key), to: prompt)   // clean session, retry once
        }
    }

    /// STREAMING variant — yields the CUMULATIVE answer so far (snapshots are cumulative; the UI just SETS the
    /// body to the latest value). Uses the document's reused session. Input overflow is detected at prefill —
    /// before any token is emitted — so on `contextWindowExceeded` with nothing yielded yet we recreate the
    /// session and restart the stream once, with no duplicated output.
    static func answerFromDocumentStream(question: String, chunks: [String], documentKey key: String) -> AsyncThrowingStream<String, Error> {
        let prompt = makePrompt(question: question, chunks: chunks)
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard case .available = SummarizationService.availability() else {
                    continuation.finish(throwing: SummarizationError.unavailable(SummarizationService.availability())); return
                }
                var yieldedAny = false
                func run(_ s: LanguageModelSession) async throws {
                    let stream: LanguageModelSession.ResponseStream<String> = s.streamResponse(to: prompt)
                    for try await snapshot in stream {
                        yieldedAny = true
                        continuation.yield(snapshot.content)                       // cumulative answer (String)
                    }
                }
                do {
                    do {
                        try await run(currentSession(documentKey: key))
                    } catch let error as LanguageModelSession.GenerationError {
                        let mapped = mapGenerationError(error)
                        // Overflow before any token → clean restart on a fresh session (transcript dropped).
                        if case .contextWindowExceeded = mapped, !yieldedAny {
                            try await run(resetSession(documentKey: key))
                        } else {
                            throw mapped
                        }
                    }
                    continuation.finish()
                } catch let e as SummarizationError {
                    continuation.finish(throwing: e)                               // already mapped — keep the case
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: mapGenerationError(error))       // from the retry attempt
                } catch {
                    continuation.finish(throwing: SummarizationError.generationFailed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One response on a GIVEN session, with GenerationError → SummarizationError mapping.
    private static func respond(_ session: LanguageModelSession, to prompt: String) async throws -> String {
        do {
            return try await session.respond(to: prompt).content
        } catch let error as LanguageModelSession.GenerationError {
            throw mapGenerationError(error)
        } catch {
            throw SummarizationError.generationFailed(error.localizedDescription)
        }
    }

    private static func makePrompt(question: String, chunks: [String]) -> String {
        let context = chunks.enumerated()
            .map { "[\($0.offset + 1)] \($0.element)" }
            .joined(separator: "\n\n")
        return "Context passages:\n\(context)\n\nQuestion: \(question)"
    }

    /// Map FoundationModels GenerationError → our distinct SummarizationError (mirrors SummarizationService).
    private static func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> SummarizationError {
        switch error {
        case .exceededContextWindowSize(let ctx):   return .contextWindowExceeded(ctx.debugDescription)
        case .guardrailViolation(let ctx):          return .guardrailViolation(ctx.debugDescription)
        case .unsupportedLanguageOrLocale(let ctx): return .unsupportedLanguage(ctx.debugDescription)
        case .assetsUnavailable(let ctx):           return .assetsUnavailable(ctx.debugDescription)
        case .rateLimited(let ctx):                 return .rateLimited(ctx.debugDescription)
        case .refusal(_, let ctx):                  return .refused(ctx.debugDescription)
        default:                                    return .generationFailed(error.localizedDescription)
        }
    }
}
