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
    // documentKeys whose CURRENT session has already been prewarmed → skip a duplicate prewarm. Cleared when the
    // session is recreated (overflow reset) or evicted (LRU), so a fresh cold session can be warmed again.
    private static var prewarmedKeys: Set<String> = []

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
        return sessionLocked(key)
    }

    /// Get-or-create `key`'s session. PRECONDITION: `lock` is held (lets `prewarm` do its dedup check + fetch
    /// under a single lock acquisition without re-entering it).
    private static func sessionLocked(_ key: String) -> LanguageModelSession {
        if let s = sessions[key] { touch(key); return s }
        return install(LanguageModelSession(instructions: fromDocumentInstructions), for: key)
    }

    /// Start a FRESH session for `key` (transcript overflow), replacing this document's session. Same fixed
    /// instructions, so behavior is identical — only the accumulated conversation is dropped. Lock-guarded.
    @discardableResult
    private static func resetSession(documentKey key: String) -> LanguageModelSession {
        lock.lock(); defer { lock.unlock() }
        prewarmedKeys.remove(key)                               // the new session is cold → eligible to warm again
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
            prewarmedKeys.remove(oldest)                        // evicted session is gone → drop its warmed flag
        }
        return s
    }

    /// Move `key` to most-recently-used. PRECONDITION: `lock` is held.
    private static func touch(_ key: String) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    /// F8 speed: warm the document's reused session BEFORE the first question, cutting first-token latency — call
    /// once when the document opens + its index is ready (DocumentEngine.start). The SAME session then answers
    /// (the old code prewarmed a throwaway session and answered on fresh ones). IDEMPOTENT: the per-document
    /// `prewarmedKeys` guard means warming the same document's session twice is a no-op, so a duplicate open /
    /// re-ready can't re-warm it. No-op when Apple Intelligence is unavailable. Meant to be called off-main.
    static func prewarm(documentKey key: String) {
        guard case .available = SummarizationService.availability() else { return }
        lock.lock()
        if prewarmedKeys.contains(key) {                        // already warmed this doc's session → skip
            lock.unlock()
            NSLog("[Openview] prewarm skip (already warmed) %@", (key as NSString).lastPathComponent)
            return
        }
        prewarmedKeys.insert(key)
        let session = sessionLocked(key)                        // get-or-create under the same lock (no re-entry)
        lock.unlock()
        NSLog("[Openview] prewarm Apple session %@", (key as NSString).lastPathComponent)
        session.prewarm()                                       // outside the lock — don't hold it during the load
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
            guard isRetriable(e) else { throw e }
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
                        // Retriable error before any token → clean restart on a fresh session (overflow drops the
                        // transcript; the language-locale misfire usually clears on a second try). No dup: nothing
                        // was emitted yet.
                        if isRetriable(mapped), !yieldedAny {
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
        // Frame the request in clear English on BOTH sides of the question. A terse one-word question (e.g.
        // "summary") trips the on-device model's input language detector → unsupportedLanguageOrLocale, even with
        // English context; bracketing it with English keeps the detected language unambiguous.
        let prompt = "Answer the question in English, using the context passages below.\n\n"
            + "Context passages:\n\(context)\n\nQuestion: \(question)\n\nAnswer in English."
        logBudget(question: question, chunks: chunks, prompt: prompt)
        return prompt
    }

    /// Errors worth a one-shot retry on a fresh session: transcript overflow (clean slate) and the intermittent
    /// language/locale misfire (a fresh session + the English-framed prompt usually clears it).
    private static func isRetriable(_ e: SummarizationError) -> Bool {
        switch e {
        case .contextWindowExceeded, .unsupportedLanguage: return true
        default:                                            return false
        }
    }

    // MARK: – Token budget (measurement only; behavior-neutral)

    /// Apple on-device context window (no public getter in the SDK — verified against the swiftinterface).
    private static let contextWindowTokens = 4096
    /// Approximate token count: ~4 chars/token for English (no public Apple tokenizer). Consistent across docs so
    /// the relative budget picture is comparable even if absolute counts are rough.
    private static func approxTokens(_ s: String) -> Int { (s.count + 3) / 4 }

    /// Log the per-question prompt's token composition so the chunk-size / top-k budget can be MEASURED (not
    /// guessed) against the 4096 window: instructions (session prefix) + the chunks + the question = input, and
    /// what's left for the answer. Single-turn (a reused session's accumulated transcript is bounded separately
    /// by the overflow-reset guard). `[budget]` so a sweep over several docs is greppable + comparable.
    private static func logBudget(question: String, chunks: [String], prompt: String) {
        let instr = approxTokens(fromDocumentInstructions)
        let chunkToks = chunks.reduce(0) { $0 + approxTokens($1) }
        let qToks = approxTokens(question)
        let promptToks = approxTokens(prompt)           // chunks + question + "[i]"/"Context passages:" framing
        let input = instr + promptToks
        let remaining = contextWindowTokens - input
        let avg = chunks.isEmpty ? 0 : chunkToks / chunks.count
        NSLog("[budget] instr≈%d k=%d chunkToks≈%d(avg %d) q≈%d prompt≈%d input≈%d/%d outRoom≈%d",
              instr, chunks.count, chunkToks, avg, qToks, promptToks, input, contextWindowTokens, remaining)
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
