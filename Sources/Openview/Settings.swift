import Foundation

/// Runtime, user-controllable preferences persisted in UserDefaults. NON-secret values only — the API KEY
/// itself stays in the Keychain (via `Keychain` / `APIKeyPrompt`); here we persist only toggles/prefs.
///
/// `verifyEnabled` used to be a build-time `static let` in `DocumentEngine` (F8 Q&A). It now lives here so
/// the in-panel Settings toggle takes effect at the NEXT question with NO rebuild: `DocumentEngine.ask`
/// reads it fresh per question, and the AI-panel toggle writes it here. Default is `false` (the current
/// direction — Apple on-device, no NLI grounding). The NLI code is untouched; only the call is branched.
enum Settings {
    private static let defaults = UserDefaults.standard
    private static let verifyEnabledKey = "openview.qa.verifyEnabled"
    private static let selectedModelKey = "openview.qa.selectedModel"
    private static let selectedModelNameKey = "openview.qa.selectedModelName"
    private static let selectedModelProviderKey = "openview.qa.selectedModelProvider"
    private static let ollamaURLKey = "openview.ollama.url"

    /// Machine (NLI) verification for Q&A. `false` (default) → page sources, no grounding. `true` → the
    /// per-sentence NLI grounded path (blue verified chips, drop/not-found). INDEPENDENT of the model:
    /// the selected model generates, and this decides whether the answer is NLI-verified. Unset → `false`.
    static var verifyEnabled: Bool {
        get { defaults.object(forKey: verifyEnabledKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: verifyEnabledKey) }
    }

    /// Selected Q&A model id. `"apple"` (default) → Apple Foundation Models on-device; any other value is an
    /// Anthropic model id (e.g. `"claude-opus-4-8"`) → Swift-direct cloud generation. The dynamic model list
    /// (Settings popover) only offers cloud ids while a key is configured; if a stale cloud id is selected
    /// with no key, routing falls back to Apple. Unset → `"apple"`.
    static var selectedModelId: String {
        get { defaults.string(forKey: selectedModelKey) ?? "apple" }
        set { defaults.set(newValue, forKey: selectedModelKey) }
    }

    /// Display name of the selected model (for the answer's "· model ·" marker + the selector button title).
    /// Stored alongside the id when the user picks a model. Unset → "Apple Intelligence".
    static var selectedModelName: String {
        get { defaults.string(forKey: selectedModelNameKey) ?? ModelOption.apple.displayName }
        set { defaults.set(newValue, forKey: selectedModelNameKey) }
    }

    /// Provider of the selected model — drives routing (apple → on-device, anthropic → cloud, ollama → local).
    /// Stored with the id/name when the user picks. Unset → "apple".
    static var selectedModelProvider: String {
        get { defaults.string(forKey: selectedModelProviderKey) ?? ModelProvider.apple.rawValue }
        set { defaults.set(newValue, forKey: selectedModelProviderKey) }
    }

    /// Base URL of the local Ollama server (the model runs in Ollama's process, not Openview's). Default is the
    /// standard local port; editable in Settings for a remote/relocated Ollama.
    static var ollamaURL: String {
        get { defaults.string(forKey: ollamaURLKey) ?? "http://localhost:11434" }
        set { defaults.set(newValue, forKey: ollamaURLKey) }
    }
}
