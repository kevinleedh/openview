import AppKit

/// Minimal AppKit API-key input — the smallest thing that lets a user supply a cloud-model API key (e.g. from
/// the model settings). On save it writes to the Keychain via `Keychain.save`. No longer tied to summarization:
/// the cloud summary path was removed, so a "summarize" request is answered on-device like any other question.
///
/// Framed as a capability ("needs more powerful processing — add a key"), NOT a failure. The USER types
/// the key into the secure field; the app never originates or transmits a key it wasn't given here.
enum APIKeyPrompt {

    /// Present a modal key-input prompt. On Save, store the entered key to the Keychain (account "anthropic").
    /// Returns true only if a non-empty key was saved successfully. Must be called on the main thread.
    @discardableResult
    static func promptAndSave(message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Cloud model API key"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Anthropic API key (sk-ant-…)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field          // typing goes straight into the field

        guard alert.runModal() == .alertFirstButtonReturn else { return false }   // Cancel
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }

        if let err = Keychain.save(key, account: "anthropic") {
            let fail = NSAlert()
            fail.messageText = "Couldn't save the API key"
            fail.informativeText = err
            fail.alertStyle = .warning
            fail.runModal()
            return false
        }
        return true
    }
}
