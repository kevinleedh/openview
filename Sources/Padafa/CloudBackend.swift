import Foundation
import Security

/// Cloud LLM backend resolution for the C hybrid (Stage 4a — functional path, no UI yet).
///
/// #13 measured the local MLX answer stack at ~2.3GB Metal, which pushes the persistent sidecar to
/// ~5.5GB on an 8GB machine (OOM / "Analyzing…" thrash). C moves ONLY the LLM *generation* to a cloud
/// BYO-key (Anthropic /v1/messages, in sidecar/cloudllm.py); retrieval, embeddings, and the per-sentence
/// NLI grounding re-check all stay LOCAL — the grounding contract (zero verified-but-wrong) is unchanged
/// because answer.py re-verifies every sentence regardless of which backend generated it. Only the
/// retrieved chunks (not the whole document) leave the device.
///
/// `Keychain` is ported verbatim from the proven prior SwiftUI build (it was pure Security framework —
/// no SwiftUI coupling). The provider model/registry + UI live in the prior build's `LLMSettings`
/// (@MainActor ObservableObject) — that is SwiftUI-coupled and is the 4b model-selector pass, NOT ported here.
enum CloudBackend {

    /// 4a default model. Overridable via PADAFA_ANTHROPIC_MODEL for verification; 4b's selector replaces this.
    static let defaultModel = "claude-opus-4-8"

    /// The backend dict passed to SidecarBridge.answer(backend:) — `{provider, key, model}` matching
    /// cloudllm.py — or nil to use the LOCAL MLX path (no key configured). Key source (4a, no UI):
    /// the PADAFA_ANTHROPIC_KEY env var (temporary injection for functional verification) takes
    /// precedence, else the Keychain item that 4b's settings UI will populate. NEVER hardcoded.
    static func current() -> [String: String]? {
        let env = ProcessInfo.processInfo.environment
        let envKey = env["PADAFA_ANTHROPIC_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        guard let key = envKey ?? Keychain.read(account: "anthropic"), !key.isEmpty else {
            return nil                                  // no key → local MLX (Stage 3 default, unchanged)
        }
        let model = env["PADAFA_ANTHROPIC_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        return ["provider": "anthropic", "key": key, "model": model]
    }

    /// The resolved cloud API key (env `PADAFA_ANTHROPIC_KEY` → Keychain), or nil. Used by the F8 model
    /// selector to supply the key to the live `/v1/models` fetch and to Swift-direct cloud Q&A. (The model
    /// LIST UI uses `Keychain.exists` for its presence check to avoid the consent prompt; this resolves the
    /// actual secret only when a cloud call is genuinely being made.)
    static func key() -> String? {
        let env = ProcessInfo.processInfo.environment
        // Test override: force the "no cloud key" state (Apple-only model list) WITHOUT touching the user's
        // Keychain — used to verify the dynamic list; harmless in production (env var absent).
        if env["PADAFA_FORCE_NO_KEY"] == "1" { return nil }
        if let envKey = env["PADAFA_ANTHROPIC_KEY"].flatMap({ $0.isEmpty ? nil : $0 }) { return envKey }
        let stored = Keychain.read(account: "anthropic")
        return (stored?.isEmpty == false) ? stored : nil
    }

    /// Non-blocking "is a cloud key configured?" — env override → env var → `Keychain.exists` (no data read,
    /// so NO securityd consent prompt and no main-thread block). The Settings UI uses this for "설정됨/미설정"
    /// so the status agrees with whether the model list will offer cloud models.
    static func hasKey() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["PADAFA_FORCE_NO_KEY"] == "1" { return false }
        if (env["PADAFA_ANTHROPIC_KEY"].flatMap { $0.isEmpty ? nil : $0 }) != nil { return true }
        return Keychain.exists(account: "anthropic")
    }

    /// The backend dict for a SPECIFIC model id (provider + resolved key + that model), or nil if no key.
    static func backend(model: String) -> [String: String]? {
        guard let key = key() else { return nil }
        return ["provider": "anthropic", "key": key, "model": model]
    }
}

/// Keychain (Security framework) — the ONLY place API keys are stored. Ported verbatim from the prior
/// build. File-based (login) keychain so an ad-hoc/unsigned app can read back its own items without the
/// keychain-access-groups entitlement the data-protection keychain requires.
enum Keychain {
    private static let service = "com.padafa.apikeys"

    /// Upsert (or delete when empty). Returns nil on success, else a human-readable error.
    @discardableResult
    static func save(_ key: String, account: String) -> String? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if key.isEmpty {
            let s = SecItemDelete(base as CFDictionary)
            return (s == errSecSuccess || s == errSecItemNotFound) ? nil : message(s)
        }
        let data = Data(key.utf8)
        let upd = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if upd == errSecSuccess { return nil }
        if upd == errSecItemNotFound {
            var add = base; add[kSecValueData as String] = data
            let s = SecItemAdd(add as CFDictionary, nil)
            return s == errSecSuccess ? nil : message(s)
        }
        return message(upd)
    }

    static func read(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Existence check that does NOT request the secret data — so it does NOT trip the securityd ACL
    /// consent prompt a data-returning `read` does after a dev re-sign. Used by the Settings UI to show
    /// "설정됨" without popping a keychain dialog every time the panel opens.
    static func exists(account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    private static func message(_ s: OSStatus) -> String {
        let txt = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
        return "Keychain error \(s): \(txt)"
    }
}
