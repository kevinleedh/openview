import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// F8 Stage 1 — minimal Apple **Foundation Models** probe.
///
/// This is a COMPLETELY SEPARATE, Swift-native path. It does NOT touch the Python sidecar
/// (Docling / BGE / MLX / NLI) or the grounded Q&A + citation pipeline in any way: it calls the
/// on-device system language model directly to summarize a SHORT piece of text. Stage 1's only goal
/// is to confirm Foundation Models is reachable from this app and returns a response — UI wiring,
/// long-document chunking, and map-reduce are later stages.
///
/// Requires **macOS 26+ with Apple Intelligence enabled** (per spec, no pre-26 fallback). Every symbol
/// that touches `FoundationModels` is gated `@available(macOS 26, *)`; the package still deploys to
/// macOS 14, so callers MUST guard with `if #available(macOS 26, *)` (use ``probeAvailability()``,
/// which already encodes the OS check as `.unsupportedOS`).

// MARK: - Result/reason types (NOT @available-gated, so callers can report on any OS)

/// Why summarization can't run right now. Mirrors `SystemLanguageModel.Availability` plus the
/// "OS too old / framework absent" cases the FoundationModels enum can't express (it only exists on 26+).
enum SummarizationAvailability: Equatable {
    case available
    case unsupportedOS                 // running below macOS 26 → FoundationModels not present
    case deviceNotEligible             // hardware/region can't run Apple Intelligence
    case appleIntelligenceNotEnabled   // user hasn't turned Apple Intelligence on in Settings
    case modelNotReady                 // model still downloading / warming up
    case unknownReason                 // a future UnavailableReason the SDK adds later

    /// Human-readable reason (also used in the debug alert/log).
    var message: String {
        switch self {
        case .available:                  return "available"
        case .unsupportedOS:              return "This Mac's macOS is below 26, so Foundation Models isn't available."
        case .deviceNotEligible:          return "This Mac doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:return "Apple Intelligence is turned off in Settings."
        case .modelNotReady:              return "The on-device model is still getting ready (downloading/warming up)."
        case .unknownReason:              return "Foundation Models isn't available (unknown reason)."
        }
    }
}

/// Distinct, non-swallowed failure modes from a summarize call (spec: "삼키지 말 것").
enum SummarizationError: Error, LocalizedError {
    case unavailable(SummarizationAvailability)
    case contextWindowExceeded(String)   // input too long for the model's context window
    case guardrailViolation(String)      // safety guardrail blocked the request/response
    case unsupportedLanguage(String)     // language/locale the model can't handle
    case assetsUnavailable(String)       // model assets not available at call time
    case rateLimited(String)             // too many requests
    case refused(String)                 // the model refused to answer
    case generationFailed(String)        // any other GenerationError / unexpected error
    // Cloud path (Stage 2b) — Swift-direct Anthropic call, shares this error type so the panel renders
    // all summarize failures the same way.
    case cloudKeyMissing                 // no API key configured for the cloud path
    case cloudAuthFailed(String)         // Anthropic rejected the key (401/403)
    case network(String)                 // couldn't reach Anthropic

    var errorDescription: String? {
        switch self {
        case .unavailable(let a):         return "Foundation Models unavailable: \(a.message)"
        case .contextWindowExceeded(let d): return "The input exceeds the model's context window. (\(d))"
        case .guardrailViolation(let d):  return "Blocked by a safety guardrail. (\(d))"
        case .unsupportedLanguage(let d): return "Unsupported language/locale. (\(d))"
        case .assetsUnavailable(let d):   return "Model assets are unavailable. (\(d))"
        case .rateLimited(let d):         return "Too many requests (rate limited). (\(d))"
        case .refused(let d):             return "The model refused to answer. (\(d))"
        case .generationFailed(let d):    return "Summarization failed. (\(d))"
        case .cloudKeyMissing:            return "No API key is configured for cloud summarization."
        case .cloudAuthFailed(let d):     return "The API key is invalid. (\(d))"
        case .network(let d):             return "Couldn't connect to the cloud. (\(d))"
        }
    }
}

// MARK: - The service (macOS 26+ only)

@available(macOS 26, *)
enum SummarizationService {

    /// One-shot system prompt. Kept deliberately tight: summarize only what the text says.
    private static let instructions =
        "You are a summarization assistant. Given a piece of text, produce a concise, faithful "
        + "summary in a few sentences. Summarize only what the text states; never add outside "
        + "information. Reply with the summary text only, in English."

    /// Map the SDK availability to our reason enum. (Inside an @available(26) member, so the symbols exist.)
    static func availability() -> SummarizationAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:           return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady:               return .modelNotReady
            @unknown default:                  return .unknownReason
            }
        }
    }

    /// Summarize a SHORT text (a few paragraphs — Stage 1 assumption; chunking is Stage 2).
    /// Creates a fresh `LanguageModelSession` per call (one-shot). Throws a distinct
    /// ``SummarizationError`` for each failure mode — nothing is swallowed.
    static func summarize(_ text: String) async throws -> String {
        guard case .available = availability() else {
            throw SummarizationError.unavailable(availability())
        }
        // `instructions` is a String value (not a literal), so it binds to the String? initializer
        // overload — no ambiguity with the Instructions-builder overloads.
        let systemPrompt: String = instructions
        let session = LanguageModelSession(instructions: systemPrompt)
        do {
            let response = try await session.respond(to: "Summarize the following text:\n\n\(text)")
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapGenerationError(error)
        } catch {
            // Non-GenerationError (unexpected) — surface it rather than swallow.
            throw SummarizationError.generationFailed(error.localizedDescription)
        }
    }

    /// Streaming variant for the AI panel (progressive display). Each yielded String is the CUMULATIVE
    /// summary so far — FoundationModels snapshots are cumulative and `String.PartiallyGenerated == String`
    /// (the Generable default `PartiallyGenerated = Self`), so the UI just SETS the body to the latest value.
    /// Same availability gate + per-case error mapping as `summarize`; cancelling the consumer cancels generation.
    static func summarizeStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard case .available = availability() else {
                    continuation.finish(throwing: SummarizationError.unavailable(availability())); return
                }
                let session = LanguageModelSession(instructions: instructions)
                do {
                    let stream: LanguageModelSession.ResponseStream<String> =
                        session.streamResponse(to: "Summarize the following text:\n\n\(text)")
                    for try await snapshot in stream {
                        continuation.yield(snapshot.content)          // cumulative partial summary (String)
                    }
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: Self.mapGenerationError(error))
                } catch {
                    continuation.finish(throwing: SummarizationError.generationFailed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Map FoundationModels GenerationError → our distinct SummarizationError (nothing swallowed).
    private static func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> SummarizationError {
        switch error {
        case .exceededContextWindowSize(let ctx):   return .contextWindowExceeded(ctx.debugDescription)
        case .guardrailViolation(let ctx):          return .guardrailViolation(ctx.debugDescription)
        case .unsupportedLanguageOrLocale(let ctx): return .unsupportedLanguage(ctx.debugDescription)
        case .assetsUnavailable(let ctx):           return .assetsUnavailable(ctx.debugDescription)
        case .rateLimited(let ctx):                 return .rateLimited(ctx.debugDescription)
        case .refusal(_, let ctx):                  return .refused(ctx.debugDescription)
        default:                                    return .generationFailed(error.localizedDescription)  // concurrentRequests / unsupportedGuide / decodingFailure / future
        }
    }
}
