import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// F8 Q&A — answer a question ON-DEVICE with Apple **Foundation Models**, the default Q&A path when
/// `DocumentEngine.verifyEnabled` is false. This is a Swift-native path: the Python sidecar is used ONLY for
/// retrieval (the `retrieve` command → `pipeline.query`, unchanged); generation happens here and **no NLI
/// grounding runs** (by design — the verified cloud/MLX + NLI path in the sidecar is preserved, just not
/// called on this path).
///
/// Two modes:
///   • ``answerFromDocument`` — the off-topic gate passed, so we have relevant chunks: answer grounded in
///     them. The caller shows page-level reference sources, explicitly UNVERIFIED (Perplexity-style).
///   • ``answerFromGeneralKnowledge`` — the gate rejected (no relevant chunks): answer from the model's own
///     knowledge instead of "not found", with no page sources.
///
/// Neither mode instructs the model to refuse ("NOT_FOUND"): the product intent here is "always answer".
/// Requires macOS 26 + Apple Intelligence (same gate as `SummarizationService`); callers fall back to the
/// verified path otherwise. Reuses ``SummarizationError`` so the panel renders failures uniformly.
@available(macOS 26, *)
enum OnDeviceQA {

    /// Retained so the async asset load it kicks off actually completes (and the model stays warm for the
    /// fresh per-answer sessions). Loading is shared at the MODEL level, so a throwaway prewarm session warms
    /// every later session.
    private static var warmSession: LanguageModelSession?

    /// F8 speed: ask the system to load the on-device model into memory BEFORE the first question, cutting the
    /// first-token latency. No-op when Apple Intelligence isn't available. Cheap + idempotent.
    static func prewarm() {
        guard case .available = SummarizationService.availability() else { return }
        let session = LanguageModelSession(instructions: fromDocumentInstructions)
        session.prewarm()
        warmSession = session
    }

    /// Grounded-in-chunks Q&A. The passages are the model's source of facts; we do NOT force a refusal, so a
    /// thin passage set still yields the model's best answer (unverified — the caller marks it as such).
    private static let fromDocumentInstructions =
        "You answer the user's question about an open document. Use the numbered context passages below as "
        + "your source of facts. Answer in 1–4 concise sentences in English. If the "
        + "passages don't fully cover the question, answer with what they do contain. Do not mention passage "
        + "numbers or say 'according to the passage'."

    /// General-knowledge fallback when the document has nothing relevant (gate rejected).
    private static let generalInstructions =
        "Answer the user's question concisely (1–4 sentences) in English, from your "
        + "general knowledge. The user's open document does not contain information about this, so answer from "
        + "what you already know."

    /// Answer grounded in the retrieved `chunks` (gate passed). Throws a distinct ``SummarizationError`` per
    /// failure mode — nothing swallowed.
    static func answerFromDocument(question: String, chunks: [String]) async throws -> String {
        let context = chunks.enumerated()
            .map { "[\($0.offset + 1)] \($0.element)" }
            .joined(separator: "\n\n")
        return try await respond(instructions: fromDocumentInstructions,
                                 prompt: "Context passages:\n\(context)\n\nQuestion: \(question)")
    }

    /// Answer from the model's general knowledge (gate rejected — no relevant chunks).
    static func answerFromGeneralKnowledge(question: String) async throws -> String {
        return try await respond(instructions: generalInstructions, prompt: question)
    }

    /// STREAMING variant of ``answerFromDocument`` (the unverified path). Yields the CUMULATIVE answer so far —
    /// FoundationModels snapshots are cumulative and `String.PartiallyGenerated == String`, so the UI just SETS
    /// the body to the latest value (first words appear in ~1–2s). Same availability gate + error mapping as
    /// the non-streaming variant. NOT used on the verified path — NLI grounding needs the completed answer.
    static func answerFromDocumentStream(question: String, chunks: [String]) -> AsyncThrowingStream<String, Error> {
        let context = chunks.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n\n")
        let prompt = "Context passages:\n\(context)\n\nQuestion: \(question)"
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard case .available = SummarizationService.availability() else {
                    continuation.finish(throwing: SummarizationError.unavailable(SummarizationService.availability())); return
                }
                let session = LanguageModelSession(instructions: fromDocumentInstructions)
                do {
                    let stream: LanguageModelSession.ResponseStream<String> = session.streamResponse(to: prompt)
                    for try await snapshot in stream {
                        continuation.yield(snapshot.content)                  // cumulative answer (String)
                    }
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: mapGenerationError(error))
                } catch {
                    continuation.finish(throwing: SummarizationError.generationFailed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Shared one-shot session call with the same availability gate + GenerationError mapping as summarize.
    private static func respond(instructions: String, prompt: String) async throws -> String {
        guard case .available = SummarizationService.availability() else {
            throw SummarizationError.unavailable(SummarizationService.availability())
        }
        let session = LanguageModelSession(instructions: instructions)
        do {
            return try await session.respond(to: prompt).content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapGenerationError(error)
        } catch {
            throw SummarizationError.generationFailed(error.localizedDescription)
        }
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
