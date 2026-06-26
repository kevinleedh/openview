import Foundation

/// F8 Q&A — answer a question with a CLOUD model (Swift-direct → Anthropic /v1/messages), the generator used
/// when a cloud model is selected. Mirrors `CloudSummarizer`'s request shape verbatim (headers x-api-key +
/// anthropic-version, body {model, max_tokens, system, messages}, no temperature). Parallels `OnDeviceQA`:
/// document-grounded (from retrieved chunks) and general-knowledge modes. This only GENERATES — whether the
/// answer is NLI-verified afterward is decided independently by `Settings.verifyEnabled` (the verified path
/// re-grounds this text via the sidecar `pregenerated` route). Reuses `SummarizationError` for failures.
enum CloudQA {

    /// FIXED system instruction (matches OnDeviceQA / OllamaQA verbatim → stable prefix for caching). RAW
    /// direction: dense, direct output and NO forced refusal — answer freely from the excerpts and the model's
    /// own knowledge.
    private static let fromDocumentInstructions =
        "You are a reading assistant for the open document. Use the provided excerpts from the document to "
        + "answer the user's question. Answer directly and concisely — no preamble, no repetition, no filler. "
        + "Be thorough when the question needs depth, but don't pad."

    private static let maxOutputTokens = 2048   // headroom so a verbose answer isn't cut off mid-sentence

    static func answerFromDocument(question: String, chunks: [String], model: String, key: String) async throws -> String {
        let context = chunks.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n\n")
        return try await post(model: model, key: key, system: fromDocumentInstructions,
                              user: "Context passages:\n\(context)\n\nQuestion: \(question)")
    }

    /// One blocking POST to /v1/messages; concatenate the text content blocks. Distinct SummarizationError per
    /// failure (nothing swallowed) — mirrors CloudSummarizer.
    private static func post(model: String, key: String, system: String, user: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxOutputTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw SummarizationError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw SummarizationError.network("No HTTP response") }
        guard http.statusCode == 200 else {
            let detail = errorMessage(from: data)
            switch http.statusCode {
            case 401, 403: throw SummarizationError.cloudAuthFailed(detail.isEmpty ? "Anthropic rejected the API key" : detail)
            case 429:      throw SummarizationError.rateLimited(detail)
            case 500...599: throw SummarizationError.network("Anthropic service error (HTTP \(http.statusCode))")
            default:       throw SummarizationError.generationFailed("HTTP \(http.statusCode): \(detail)")
            }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw SummarizationError.generationFailed("Malformed Anthropic response")
        }
        let text = content
            .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummarizationError.generationFailed("Empty cloud response") }
        return text
    }

    private static func errorMessage(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any],
              let msg = err["message"] as? String else { return "" }
        return msg
    }
}
