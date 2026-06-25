import AppKit

/// App lifecycle for the document shell. We deliberately do NOT implement `application(_:open:)` — with
/// the PDF type declared in Info.plist (NSDocumentClass), the shared `NSDocumentController` opens Finder
/// double-clicks / 'Open With → Padafa' automatically. We add only a headless launch convenience
/// (`open Padafa.app --args <file.pdf>`) and a Preview-style "present the open panel when launched with
/// nothing" so the user never faces a blank window — plus quit/volume hygiene.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = NSDocumentController.shared          // ensure the document machinery is alive

        // Foundation probe (console): build identity + Keychain r/w on the ad-hoc-signed bundle.
        // OFF the main thread: the data-returning keychain read is ACL-gated, and after a dev re-sign
        // (new ad-hoc cdhash) it can pop a modal securityd consent prompt — synchronously on main that
        // would BLOCK launch before any window appears. It only logs, so nothing depends on it inline.
        // (Mirrors the sidecar probe, which already runs off-main.)
        DispatchQueue.global(qos: .utility).async { FoundationCheck.runKeychainCheck() }

        // Warm the retrieval embedder (compiling the e5 Core ML model is the cost) OFF-main at launch, so the
        // first document open doesn't hitch on it. Best-effort; the index path + ingest both resolve the same
        // cached `Embeddings.current` instance later.
        DispatchQueue.global(qos: .utility).async { Embeddings.prewarm() }

        // TEMPORARY (F8 Stage-1 verification): when launched with PADAFA_FM_SELFTEST=1, auto-run the
        // Foundation Models summarize probe so it can be verified headlessly (logs the result to the
        // console). The work is detached, so it logs even while the empty-launch Open panel is up.
        // Stage 3 removes this along with the Debug menu probe.
        if ProcessInfo.processInfo.environment["PADAFA_FM_SELFTEST"] == "1" {
            runSummarizeSelfTest(nil)
        }
        // TEMPORARY (F8 Stage-2b verification): show the cloud API-key input prompt on demand, so it can be
        // screenshotted WITHOUT removing any real Keychain key. Replaced by the real settings UI (4b).
        if ProcessInfo.processInfo.environment["PADAFA_KEYPROMPT_DEBUG"] == "1" {
            DispatchQueue.main.async {
                _ = APIKeyPrompt.promptAndSave(message:
                    "This document is large and needs more powerful processing. Enter an API key to summarize it with a cloud model.")
            }
        }

        // If a PDF was passed via `--args`, open it and DON'T present the panel — the open is async, so
        // checking `documents.isEmpty` on the next tick would race (it can still be empty) and pop a
        // spurious Open panel over the document. Only fall back when no arg opened anything.
        if !openFromArguments() {
            // Defer one runloop tick so a pending Finder open-event (handled by the document controller)
            // can create its document first; only then run F1. (Preview-style: never a blank window.)
            DispatchQueue.main.async {
                if NSDocumentController.shared.documents.isEmpty {
                    self.reopenLastDocumentOrShowPanel()
                }
            }
        }

        // CRITICAL for the open-with-URL path: a process launched in the background (launchd / `open`
        // without focus) is not frontmost, so NSDocument's `display:true` orderFront cannot raise the
        // window above other apps — the window exists but is never seen. Activation is process-level and
        // persists, so one call here brings the document window (or the Open panel) to the front.
        NSApp.activate(ignoringOtherApps: true)

        observeVolumeUnmounts()
        warnIfRunningFromRemovableVolume()
    }

    /// Safety net: the dominant crash was the executable itself running from the external SSD (SIGBUS when
    /// the volume drops). make_app.sh now installs to ~/Applications; if a stale SSD copy is launched
    /// anyway, say so loudly rather than letting it crash later.
    private func warnIfRunningFromRemovableVolume() {
        let path = Bundle.main.bundleURL.path
        guard path.hasPrefix("/Volumes/") else { return }
        NSLog("[Padafa] WARNING: running from %@ (a removable volume). If it unmounts the app will crash (SIGBUS).", path)
        let alert = NSAlert()
        alert.messageText = "Running from a removable drive"
        alert.informativeText = "Padafa is running from:\n\(path)\n\nIf that drive disconnects, the app will crash. Reinstall to your internal disk by running ./make_app.sh, then launch from ~/Applications."
        alert.alertStyle = .warning
        alert.runModal()
    }

    // Stay alive after the document window closes so the app can re-present the panel (single-doc viewer).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    // No untitled/blank document on launch or Dock-reopen — we always open a real PDF or show the panel.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    // Dock-icon click while running with no window (e.g. after ⌘W) must recover, not dead-end. Since
    // applicationShouldOpenUntitledFile is false (no blank docs), route the windowless reopen to the
    // Open panel — Preview-style. (CLAUDE.md F1: closing the PDF returns to the open flow.)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && NSDocumentController.shared.documents.isEmpty {
            NSDocumentController.shared.openDocument(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    // Open the first valid PDF passed via `--args` (single-active-document viewer — never fan out into
    // multiple windows). Existence-checked so stray `.pdf`-suffixed tokens never reach the controller.
    // Returns true if an open was initiated, so the caller can skip the empty-launch panel.
    @discardableResult
    private func openFromArguments() -> Bool {
        let pdfs = CommandLine.arguments.dropFirst().filter { $0.lowercased().hasSuffix(".pdf") }
        for path in pdfs {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSLog("[Padafa] open failed for \(path): \(error.localizedDescription)") }
            }
            return true   // single document — open only the first valid file
        }
        return false
    }

    /// F1: on a no-argument launch, auto-reopen the SINGLE most-recently-opened PDF — this is the explicit
    /// replacement for macOS multi-window restoration (disabled via `window.isRestorable = false`), so the
    /// app comes back to exactly one document, not every window that was open at quit. Falls back to the
    /// standard Open panel when there's no reachable recent document (cancel → no blank window).
    private func reopenLastDocumentOrShowPanel() {
        let dc = NSDocumentController.shared
        if let last = dc.recentDocumentURLs.first, (try? last.checkResourceIsReachable()) == true {
            dc.openDocument(withContentsOf: last, display: true) { _, _, error in
                if error != nil { dc.openDocument(nil) }   // recent exists but unreadable → Open panel
            }
        } else {
            dc.openDocument(nil)                            // no recent (or unreachable drive) → Open panel
        }
    }

    // MARK: – Removable-volume resilience (the PDFs live on an external SSD)

    /// When a volume is about to unmount, proactively release any open document whose source PDF lives on
    /// it. The PDF may be memory-mapped; once the backing vnode is gone, the next page fault is a SIGBUS we
    /// can't catch. Releasing the document/PDFView reference first turns a hard crash into a clean message.
    // Volumes we've already shown the "disconnected" alert for this unmount, so will/didUnmount don't
    // double-alert. Cleared when the volume remounts so a later eject alerts again.
    private var alertedVolumePaths = Set<String>()

    private func observeVolumeUnmounts() {
        let nc = NSWorkspace.shared.notificationCenter
        // Both notifications, for graceful (will) AND surprise (did) removal — deduped in the handler.
        nc.addObserver(self, selector: #selector(volumeWillUnmount(_:)),
                       name: NSWorkspace.willUnmountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumeWillUnmount(_:)),
                       name: NSWorkspace.didUnmountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumeDidMount(_:)),
                       name: NSWorkspace.didMountNotification, object: nil)
    }

    @objc private func volumeDidMount(_ note: Notification) {
        if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            alertedVolumePaths.remove(url.standardizedFileURL.path)
        }
    }

    @objc private func volumeWillUnmount(_ note: Notification) {
        guard let volURL = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        let volPath = volURL.standardizedFileURL.path
        var hit = false
        for case let doc as PadafaDocument in NSDocumentController.shared.documents {
            guard let docPath = doc.fileURL?.standardizedFileURL.path,
                  docPath == volPath || docPath.hasPrefix(volPath + "/") else { continue }
            hit = true
            for case let wc as DocumentWindowController in doc.windowControllers {
                wc.releaseForVolumeLoss()           // idempotent — safe on both will & did
            }
        }
        // Alert at most once per unmount: will + did fire the same handler. insert().inserted is false
        // the second time, so only the first shows the modal.
        guard hit, alertedVolumePaths.insert(volPath).inserted else { return }
        let alert = NSAlert()
        alert.messageText = "The drive was disconnected"
        alert.informativeText = "The PDF lived on a removable drive that was ejected. Reconnect the drive and reopen the document to continue."
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc func runFoundationSelfTest(_ sender: Any?) {
        FoundationCheck.runInteractive()
    }

    /// TEMPORARY F8 Stage-1 probe (Debug menu): confirm Apple Foundation Models is reachable from this
    /// app and returns a summary for a hardcoded short text. Logs to the console AND shows an alert so the
    /// result is visible either way. This is throwaway — Stage 3 replaces it with the real AI-panel UI.
    /// Completely separate from the Python sidecar / grounded Q&A path.
    @objc func runSummarizeSelfTest(_ sender: Any?) {
        let sample = """
        Apple Silicon Macs run an on-device large language model as part of Apple Intelligence. \
        Because it runs locally, requests do not leave the device, which protects privacy and works \
        offline. The model is small compared with cloud systems, so it is best suited to focused tasks \
        such as summarizing, rewriting, and extracting short pieces of text rather than open-ended chat.
        """
        guard #available(macOS 26, *) else {
            NSLog("[Padafa][F8] Foundation Models unavailable: macOS < 26")
            Self.presentSummary(title: "Foundation Models unavailable",
                                body: SummarizationAvailability.unsupportedOS.message)
            return
        }
        let avail = SummarizationService.availability()
        NSLog("[Padafa][F8] availability = \(avail)")
        // Detached so model inference runs OFF the main thread (no UI beachball) and still completes/logs
        // even if a modal (e.g. the empty-launch Open panel) is up — `respond` is nonisolated(nonsending).
        Task.detached {
            do {
                let summary = try await SummarizationService.summarize(sample)
                NSLog("[Padafa][F8] summary OK (%d chars): %@", summary.count, summary)
                await MainActor.run {
                    Self.presentSummary(title: "Foundation Models summary", body: summary)
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                NSLog("[Padafa][F8] summary ERROR: %@", msg)
                await MainActor.run {
                    Self.presentSummary(title: "Foundation Models error", body: msg)
                }
            }
        }
    }

    /// Temporary helper for the F8 probe — shows the result/error in a modal alert (removed with the probe).
    private static func presentSummary(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.runModal()
    }
}
