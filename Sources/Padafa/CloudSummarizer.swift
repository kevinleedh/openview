import Foundation

/// CLOUD summarization, Swift-direct (URLSession → Anthropic /v1/messages), STREAMING via SSE so the summary
/// appears progressively (like the on-device summary and Apple Q&A) instead of dumping all at once.
///
/// Deliberately does NOT go through the Python sidecar: a URLSession call adds essentially no resident memory
/// (vs spawning the heavy Python ML process), and it never touches the Q&A retrieval/NLI grounding path (that
/// is `answer.py`, which ALWAYS re-verifies — wrong for a free-form whole-document summary). The whole document
/// text is sent to the cloud model and the result is shown UNVERIFIED, exactly like the on-device summary.
///
/// Request shape mirrors sidecar/cloudllm.py (headers x-api-key + anthropic-version, body {model, max_tokens,
/// system, messages}, NO temperature) plus `stream: true`. Works on any macOS (no FoundationModels dependency).
enum CloudSummarizer {

    /// Whole-document summarization prompt (distinct from the on-device "few sentences" prompt — a cloud
    /// model can produce a fuller summary of a long document, but it is still UNVERIFIED).
    private static let instructions =
        "You are a summarization assistant. Summarize the following document faithfully and concisely. "
        + "Cover the document's main points in a few short paragraphs. Summarize only what the document "
        + "states; never add outside information. Reply with the summary text only, in English."

    private static let maxOutputTokens = 2048

    /// Stream the cloud summary, yielding the CUMULATIVE text so far (the panel just SETS the answer body to
    /// the latest value, like every other streaming path). The key/model come from `CloudBackend.current()`
    /// (env `PADAFA_ANTHROPIC_KEY` → Keychain); the caller ensures a key exists first. Throws a distinct
    /// ``SummarizationError`` per failure mode (nothing swallowed).
    static func summarizeStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try makeRequest(text)
                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do { (bytes, response) = try await URLSession.shared.bytes(for: req) }
                    catch { throw SummarizationError.network(error.localizedDescription) }
                    guard let http = response as? HTTPURLResponse else {
                        throw SummarizationError.network("No HTTP response")
                    }
                    guard http.statusCode == 200 else {
                        // A non-200 returns a plain JSON error body (not SSE) — drain it for the detail.
                        var errData = Data()
                        for try await b in bytes { errData.append(b) }
                        throw statusError(http.statusCode, errorMessage(from: errData))
                    }
                    // Anthropic SSE: each event is an `event:` line + a `data: {json}` line. We only need the
                    // data lines and dispatch on the JSON's own "type": text_delta chunks → append; error →
                    // throw; message_stop → done.
                    var acc = ""
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let d = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let type = obj["type"] as? String else { continue }
                        switch type {
                        case "content_block_delta":
                            if let delta = obj["delta"] as? [String: Any],
                               (delta["type"] as? String) == "text_delta",
                               let t = delta["text"] as? String, !t.isEmpty {
                                acc += t
                                continuation.yield(acc)
                            }
                        case "message_stop":
                            continuation.finish(); return
                        case "error":
                            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "stream error"
                            throw SummarizationError.generationFailed(msg)
                        default:
                            continue
                        }
                    }
                    if acc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw SummarizationError.generationFailed("Empty cloud response")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func makeRequest(_ text: String) throws -> URLRequest {
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
            "stream": true,
            "system": instructions,
            "messages": [["role": "user", "content": "Summarize the following document:\n\n\(text)"]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Map an Anthropic HTTP error status → a distinct SummarizationError.
    private static func statusError(_ code: Int, _ detail: String) -> SummarizationError {
        switch code {
        case 401, 403: return .cloudAuthFailed(detail.isEmpty ? "Anthropic rejected the API key" : detail)
        case 429:      return .rateLimited(detail)
        case 400 where detail.lowercased().contains("token") || detail.lowercased().contains("long")
                        || detail.lowercased().contains("large") || detail.lowercased().contains("maximum"):
            return .contextWindowExceeded(detail)                       // doc too big even for the cloud model
        case 500...599: return .network("Anthropic service error (HTTP \(code))")
        default:        return .generationFailed("HTTP \(code): \(detail)")
        }
    }

    /// Pull `error.message` out of an Anthropic error body, if present.
    private static func errorMessage(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any],
              let msg = err["message"] as? String else { return "" }
        return msg
    }
}
