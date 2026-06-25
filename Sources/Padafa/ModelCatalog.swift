import Foundation

/// Which backend generates for a model. Drives routing in DocumentEngine and the answer marker.
enum ModelProvider: String { case apple, anthropic, ollama }

/// One selectable Q&A model. `id` is what gets persisted/routed (`"apple"`, an Anthropic model id like
/// `"claude-opus-4-8"`, or an Ollama model name like `"gemma3:1b"`); `displayName` is the human label.
struct ModelOption: Equatable {
    let id: String
    let displayName: String
    let provider: ModelProvider

    static let appleId = "apple"
    static let apple = ModelOption(id: appleId, displayName: "Apple Intelligence", provider: .apple)
    var isApple: Bool { provider == .apple }
}

/// F8 dynamic model list. Apple Intelligence is ALWAYS available (on-device, no key). The OTHER providers
/// appear only when configured — Anthropic models when a key is set (live `GET /v1/models`), local Ollama
/// models when Ollama is reachable (live `GET /api/tags`). Same "configure a provider → its models populate"
/// pattern for all of them. Each provider's models route to its own generator at answer time.
enum ModelCatalog {

    // MARK: Anthropic (cloud)

    /// Known Anthropic models — fallback when `/v1/models` can't be reached but a key exists (so cloud options
    /// still show offline). The live fetch supersedes this whenever it succeeds.
    static let anthropicFallback: [ModelOption] = [
        ModelOption(id: "claude-opus-4-8",           displayName: "Claude Opus 4.8",   provider: .anthropic),
        ModelOption(id: "claude-sonnet-4-6",         displayName: "Claude Sonnet 4.6", provider: .anthropic),
        ModelOption(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5",  provider: .anthropic),
    ]

    /// Live Anthropic model list. `[]` when no key; the live list (or `anthropicFallback` on error) otherwise.
    static func fetchAnthropic() async -> [ModelOption] {
        guard let key = CloudBackend.key() else { return [] }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["data"] as? [[String: Any]] else { return anthropicFallback }
            let models = arr.compactMap { m -> ModelOption? in
                guard let id = m["id"] as? String else { return nil }
                return ModelOption(id: id, displayName: (m["display_name"] as? String) ?? id, provider: .anthropic)
            }
            return models.isEmpty ? anthropicFallback : models
        } catch {
            return anthropicFallback
        }
    }

    // MARK: Ollama (local)

    /// Live local model list via `GET {ollamaURL}/api/tags`. Returns `[]` when Ollama isn't reachable (not
    /// running / wrong address) — so local models simply don't appear, never a crash. Each model's `name` is
    /// the id (e.g. `"gemma3:1b"`). The model runs in OLLAMA's process — Padafa only makes HTTP calls, so this
    /// adds no model memory to the app (the 8GB-safe path; no MLX-direct OOM).
    static func fetchOllama() async -> [ModelOption] {
        let base = Settings.ollamaURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, let url = URL(string: base + "/api/tags") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4                                    // localhost is instant; down = fast refusal
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["models"] as? [[String: Any]] else { return [] }
            return arr.compactMap { m -> ModelOption? in
                guard let name = m["name"] as? String else { return nil }
                return ModelOption(id: name, displayName: name, provider: .ollama)
            }
        } catch {
            return []
        }
    }

    /// Display name for a model id (selector button title), falling back across the live list, the hardcoded
    /// list, then the raw id.
    static func displayName(forId id: String, in live: [ModelOption]) -> String {
        if id == ModelOption.appleId { return ModelOption.apple.displayName }
        return live.first(where: { $0.id == id })?.displayName
            ?? anthropicFallback.first(where: { $0.id == id })?.displayName
            ?? id
    }
}
