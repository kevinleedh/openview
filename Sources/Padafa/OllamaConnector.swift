import AppKit

/// One-click Ollama connection — zero terminal use. Detects the local Ollama, auto-starts its server when it's
/// installed-but-down, downloads a default model in-app when none exists, and points the user at the official
/// installer when it's missing. New symbol; it only feeds the EXISTING Ollama provider slot (OllamaQA + the
/// model chip via Settings.ollamaURL) — grounding / verification / answer routing are untouched.
///
/// Deployment premise: Developer-ID direct distribution (NOT sandboxed) → launching the `ollama` binary and
/// hitting localhost are permitted.
enum OllamaState: Equatable {
    case notInstalled
    case installedNotRunning
    case running(models: [String])     // up and serving a non-empty model list
    case readyNoModel                  // up but 0 models
    case startingServer
    case pullingModel(progress: Double)
    case connected(model: String)
    case error(String)
}

final class OllamaConnector {

    /// Default local endpoint (spec). The existing OllamaQA / ModelCatalog read Settings.ollamaURL; on a
    /// successful connect the caller writes this value there so every layer agrees.
    static let base = "http://127.0.0.1:11434"
    /// The small default model pulled when none is present.
    static let defaultModel = "gemma3:1b"

    /// Kept so the spawned server isn't deallocated mid-run. We deliberately do NOT terminate it on quit
    /// (policy: leave it running so the user's other Ollama work isn't disrupted).
    private var serveProcess: Process?

    // MARK: – 1) Detect

    func detect() async -> OllamaState {
        if let models = await fetchTags() {
            return models.isEmpty ? .readyNoModel : .running(models: models)
        }
        return binaryPath() != nil ? .installedNotRunning : .notInstalled
    }

    /// `GET {base}/api/tags` (≈1.5s). Returns the model-name list on HTTP 200, or nil if unreachable.
    private func fetchTags() async -> [String]? {
        guard let url = URL(string: Self.base + "/api/tags") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["models"] as? [[String: Any]] else { return nil }
        return arr.compactMap { $0["name"] as? String }
    }

    /// Path to an `ollama` executable, or nil. Checks the two Homebrew/installer locations, then `which`.
    func binaryPath() -> String? {
        for c in ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
        return which("ollama")
    }

    private func which(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [name]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }

    // MARK: – 2) Start the server (only valid from .installedNotRunning — never double-starts a running one)

    func startServer() async throws {
        guard let bin = binaryPath() else { throw err("Ollama isn't installed.") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["serve"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { throw err("Couldn't start the Ollama server.") }
        serveProcess = p
        for _ in 0..<20 {                                  // poll /api/tags up to ~10s
            if await fetchTags() != nil { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw err("Couldn't start the Ollama server.")
    }

    // MARK: – 3) Pull a model in-app, streaming progress

    /// `POST {base}/api/pull` (NDJSON stream). `onProgress` gets completed/total in [0,1] as it downloads.
    /// Ollama resumes partial pulls itself, so a failure only needs a Retry.
    func pullModel(_ name: String, onProgress: @escaping (Double) -> Void) async throws {
        guard let url = URL(string: Self.base + "/api/pull") else { throw err("Bad Ollama URL.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "stream": true])
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw err("Couldn't download the model.") }
        for try await line in bytes.lines {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let status = obj["status"] as? String, status == "success" { return }
            if let total = obj["total"] as? Double, let completed = obj["completed"] as? Double, total > 0 {
                onProgress(min(max(completed / total, 0), 1))
            }
        }
    }

    private func err(_ message: String) -> NSError {
        NSError(domain: "Padafa.OllamaConnector", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
