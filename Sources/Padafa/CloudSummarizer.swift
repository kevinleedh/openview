import Foundation

/// F8 Stage 2b — CLOUD summarization, Swift-direct (URLSession → Anthropic /v1/messages).
///
/// Deliberately does NOT go through the Python sidecar: F8 is sidecar-free by design, a URLSession call
/// adds essentially no resident memory (vs spawning the heavy Python ML process — the whole point of the
/// 8GB cloud offload), and it never touches the Q&A retrieval/NLI grounding path (that is `answer.py`,
/// which ALWAYS re-verifies — wrong for a free-form whole-document summary). The whole document text is
/// sent to the cloud model and the result is shown UNVERIFIED, exactly like the on-device summary.
///
/// Request shape mirrors sidecar/cloudllm.py verbatim (headers x-api-key + anthropic-version, body
/// {model, max_tokens, system, messages}, NO temperature). Non-streaming first cut (one blocking POST,
/// concatenate the `content[]` text blocks); SSE streaming is a straightforward follow-up since the panel
/// already supports cumulative streaming. Works on any macOS (no FoundationModels dependency).
enum CloudSummarizer {

    /// Whole-document summarization prompt (distinct from the on-device "few sentences" prompt — a cloud
    /// model can produce a fuller summary of a long document, but it is still UNVERIFIED).
    private static let instructions =
        "You are a summarization assistant. Summarize the following document faithfully and concisely. "
        + "Cover the document's main points in a few short paragraphs. Summarize only what the document "
        + "states; never add outside information. Reply with the summary text only, in English."

    private static let maxOutputTokens = 2048

    /// Summarize the full document text with the configured cloud model. Throws a distinct
    /// ``SummarizationError`` for each failure mode (nothing swallowed). The key/model come from
    /// `CloudBackend.current()` (env `PADAFA_ANTHROPIC_KEY` → Keychain) — caller ensures a key exists first.
    static func summarize(_ text: String) async throws -> String {
        guard let backend = CloudBackend.current(),
              let key = backend["key"], let model = backend["model"] else {
            throw SummarizationError.cloudKeyMissing
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")               // BYO key
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // No "temperature" (deprecated on Opus 4.8+, mirrors cloudllm.py). Single user message carrying the
        // whole document; the summarization instruction is the system prompt.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxOutputTokens,
            "system": instructions,
            "messages": [["role": "user", "content": "Summarize the following document:\n\n\(text)"]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw SummarizationError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SummarizationError.network("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let detail = errorMessage(from: data)
            switch http.statusCode {
            case 401, 403:
                throw SummarizationError.cloudAuthFailed(detail.isEmpty ? "Anthropic rejected the API key" : detail)
            case 429:
                throw SummarizationError.rateLimited(detail)
            case 400 where detail.lowercased().contains("token") || detail.lowercased().contains("long")
                            || detail.lowercased().contains("large") || detail.lowercased().contains("maximum"):
                throw SummarizationError.contextWindowExceeded(detail)   // doc too big even for the cloud model
            case 500...599:
                throw SummarizationError.network("Anthropic service error (HTTP \(http.statusCode))")
            default:
                throw SummarizationError.generationFailed("HTTP \(http.statusCode): \(detail)")
            }
        }
        // Concatenate every text content block (mirrors cloudllm.py response parsing).
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw SummarizationError.generationFailed("Malformed Anthropic response")
        }
        let summary = content
            .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw SummarizationError.generationFailed("Empty cloud response") }
        return summary
    }

    /// Pull `error.message` out of an Anthropic error body, if present.
    private static func errorMessage(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any],
              let msg = err["message"] as? String else { return "" }
        return msg
    }
}
