import Foundation

/// F8 Q&A — answer with a LOCAL model via Ollama's OpenAI-compatible endpoint
/// (`POST {base}/v1/chat/completions`). The model runs inside the OLLAMA process; Padafa only makes HTTP
/// calls, so this adds NO model memory to the app — the 8GB-safe path (no MLX-direct load / OOM). Parallels
/// `CloudQA` (same OpenAI request shape; only the address is localhost and the key is a throwaway "ollama").
/// Supports both non-streaming and SSE streaming, so the unverified path streams like Apple on-device.
/// Generation only — `Settings.verifyEnabled` decides independently whether the answer is NLI-grounded
/// afterward (the same `pregenerated` re-grounding path the Apple/cloud paths use).
enum OllamaQA {

    /// FIXED system instruction (matches OnDeviceQA / CloudQA verbatim → stable prefix for caching). RAW
    /// direction: dense, direct output and NO forced refusal — answer freely from the excerpts and the model's
    /// own knowledge.
    private static let fromDocumentInstructions =
        "You are a reading assistant for the open document. Use the provided excerpts from the document to "
        + "answer the user's question. Answer directly and concisely — no preamble, no repetition, no filler. "
        + "Be thorough when the question needs depth, but don't pad."

    private static let maxOutputTokens = 2048   // headroom so a verbose local model isn't cut off mid-sentence

    static func answerFromDocument(question: String, chunks: [String], model: String, base: String) async throws -> String {
        let req = try request(base: base, model: model, system: fromDocumentInstructions,
                              user: userMessage(question: question, chunks: chunks), stream: false)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw connectionError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw connectionError(nil) }
        guard http.statusCode == 200 else {
            throw err("Ollama response error (HTTP \(http.statusCode)). Check that the model name is correct.")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
            throw err("Couldn't parse the Ollama response.")
        }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw err("Ollama returned an empty response.") }
        return text
    }

    /// STREAMING (SSE) variant for the unverified path — yields the CUMULATIVE answer so far (the UI just SETS
    /// the body to the latest value, like the Apple on-device stream). Connection failure → a clear "can't
    /// reach Ollama" error so the app shows a notice instead of crashing.
    static func answerFromDocumentStream(question: String, chunks: [String], model: String, base: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try request(base: base, model: model, system: fromDocumentInstructions,
                                          user: userMessage(question: question, chunks: chunks), stream: true)
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw connectionError(nil) }
                    guard http.statusCode == 200 else {
                        throw err("Ollama response error (HTTP \(http.statusCode)). Check that the model name is correct.")
                    }
                    var acc = ""
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        if let d = payload.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                           let choices = obj["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String, !content.isEmpty {
                            acc += content
                            continuation.yield(acc)                      // cumulative
                        }
                    }
                    continuation.finish()
                } catch let e where (e as NSError).domain == NSURLErrorDomain {
                    continuation.finish(throwing: connectionError(e))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func userMessage(question: String, chunks: [String]) -> String {
        let context = chunks.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n\n")
        return "Context passages:\n\(context)\n\nQuestion: \(question)"
    }

    private static func request(base: String, model: String, system: String, user: String, stream: Bool) throws -> URLRequest {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed + "/v1/chat/completions") else {
            throw err("Invalid Ollama address: \(trimmed)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer ollama", forHTTPHeaderField: "authorization")   // Ollama ignores the value
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxOutputTokens,
            "stream": stream,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func connectionError(_ underlying: Error?) -> NSError {
        err("Can't reach Ollama. Check that it's running and the address is correct. (\(Settings.ollamaURL))")
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "Padafa.Ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
