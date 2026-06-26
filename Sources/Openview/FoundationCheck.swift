import AppKit
import Foundation
import NaturalLanguage
import Security

/// Foundation probes for the migration doc's "known re-setup risks":
///   1. Keychain — not just "can we call SecItem", but does an item written by one launch SURVIVE into
///      a later launch of the same ad-hoc-signed binary (the doc's real concern: a rebuild changes the
///      signature and orphans items). The probe is persistence-aware: it reads first, and only seeds
///      when nothing is found — so the second launch demonstrates real survival, and the first launch
///      after a rebuild surfaces orphaning instead of masking it.
///   2. Embedding — the on-device `NLEmbedding` sentence model that powers retrieval (the Python+ML sidecar
///      was removed). The probe confirms the asset loads and produces a vector, so a build/OS without it is
///      diagnosable here rather than at first question.
/// Keychain runs on launch (instant, console). The embedding probe is on-demand (Debug ▸ Run Foundation
/// Self-Test).
enum FoundationCheck {

    // MARK: – Keychain persistence (login keychain, no entitlements)

    private static let keychainBase: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.openview.app.selftest",
        kSecAttrAccount as String: "stage1",
    ]
    private static let keychainExpected = Data("openview-stage1-probe".utf8)

    @discardableResult
    static func runKeychainCheck() -> Bool {
        let (ok, detail) = keychainCheck()
        NSLog("[Openview] Keychain self-test → %@ (%@)", ok ? "PASS" : "FAIL", detail)
        return ok
    }

    /// Read-first, seed-if-absent, NEVER delete — so survival across relaunch is observable.
    private static func keychainCheck() -> (Bool, String) {
        var read = keychainBase
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne

        var existing: CFTypeRef?
        let readStatus = SecItemCopyMatching(read as CFDictionary, &existing)
        if readStatus == errSecSuccess {
            // An item from a PRIOR launch is readable — the survival evidence the migration doc wants.
            let matches = (existing as? Data) == keychainExpected
            return (matches, "survived prior launch (read=0, match=\(matches))")
        }

        // Not found → first run, or a rebuild's new ad-hoc cdhash orphaned the old item. Seed it and
        // confirm we can read back what we just wrote (in-process sanity). It persists for next launch.
        var add = keychainBase
        add[kSecValueData as String] = keychainExpected
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        var seeded: CFTypeRef?
        let reReadStatus = SecItemCopyMatching(read as CFDictionary, &seeded)
        let ok = addStatus == errSecSuccess && reReadStatus == errSecSuccess && (seeded as? Data) == keychainExpected
        let cause = readStatus == errSecItemNotFound ? "first run or rebuild-orphaned" : "read=\(readStatus)"
        return (ok, "seeded this launch (\(cause)); add=\(addStatus) reread=\(reReadStatus)")
    }

    // MARK: – NLEmbedding (on-device retrieval embedder) probe

    /// Confirm the on-device sentence embedder loads and vectorizes — the retrieval backend that replaced the
    /// Python+ML sidecar. A build/OS without the asset is reported here, not at the first question.
    static func runEmbeddingProbe() -> (Bool, String) {
        guard let emb = NLEmbedding.sentenceEmbedding(for: .english) else {
            return (false, "NLEmbedding.sentenceEmbedding(.english) unavailable on this OS build — retrieval will degrade to BM25-only")
        }
        guard let v = emb.vector(for: "The quick brown fox jumps over the lazy dog."), !v.isEmpty else {
            return (false, "sentence model loaded but produced no vector")
        }
        return (true, "NLEmbedding OK — \(emb.dimension)-d English sentence embeddings")
    }

    // MARK: – Interactive (Debug menu)

    static func runInteractive() {
        let (kOK, kDetail) = keychainCheck()
        NSLog("[Openview] Keychain → %@ (%@)", kOK ? "PASS" : "FAIL", kDetail)
        let (eOK, eDetail) = runEmbeddingProbe()
        NSLog("[Openview] Embedding → %@ (%@)", eOK ? "PASS" : "FAIL", eDetail)
        let alert = NSAlert()
        alert.messageText = "Foundation Self-Test"
        alert.informativeText = """
        Keychain r/w: \(kOK ? "✅ PASS" : "❌ FAIL")
        \(kDetail)

        On-device embedding (NLEmbedding): \(eOK ? "✅ PASS" : "❌ FAIL")
        \(eDetail)
        """
        alert.alertStyle = (kOK && eOK) ? .informational : .warning
        alert.runModal()
    }
}
