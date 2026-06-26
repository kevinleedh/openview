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

    /// FIXED system instruction (never varies per question → the foundation for prefix caching). RAW direction:
    /// dense, direct output and NO forced refusal — the model answers freely, using the excerpts when relevant
    /// and its own knowledge otherwise.
    private static let fromDocumentInstructions =
        "You are a reading assistant for the open document. Use the provided excerpts from the document to "
        + "answer the user's question. Answer directly and concisely — no preamble, no repetition, no filler. "
        + "Be thorough when the question needs depth, but don't pad."

    /// Answer using the retrieved `chunks` as context. Throws a distinct ``SummarizationError`` per failure
    /// mode — nothing swallowed.
    static func answerFromDocument(question: String, chunks: [String]) async throws -> String {
        let context = chunks.enumerated()
            .map { "[\($0.offset + 1)] \($0.element)" }
            .joined(separator: "\n\n")
        return try await respond(instructions: fromDocumentInstructions,
                                 prompt: "Context passages:\n\(context)\n\nQuestion: \(question)")
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
