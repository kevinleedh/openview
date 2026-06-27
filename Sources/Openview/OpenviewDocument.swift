import AppKit
import PDFKit

/// The PDF as the document model — Preview's exact shape (`PDFDocument` wrapped in an `NSDocument`).
/// `@objc(OpenviewDocument)` exposes the unqualified Obj-C name referenced by Info.plist's NSDocumentClass.
/// Supports text-markup editing: highlight/underline/strikethrough annotations are added to `pdfDocument`
/// and serialized back into the PDF on ⌘S (`data(ofType:)` → `dataRepresentation()`), so Preview and other
/// viewers see them too. Explicit-save only (no autosave-in-place of the user's source file).
@objc(OpenviewDocument)
final class OpenviewDocument: NSDocument {

    private(set) var pdfDocument: PDFDocument?

    /// Strip transient (non-user) annotations just before serializing — wired by the window controller to the
    /// PDFViewController so a verification citation highlight isn't baked into the saved file.
    var prepareForSave: (() -> Void)?

    /// The AI-panel chat to persist, queried on save (wired by the window controller). Saved to a sidecar in
    /// `write(to:)` — i.e. only on an actual ⌘S — so "Don't Save" keeps the last-saved chat (or none).
    var currentChat: (() -> [ChatTurn])?

    /// Chat loaded from the sidecar on open; handed to the window controller to re-render in the panel.
    private(set) var loadedChat: [ChatTurn] = []

    /// The SOURCE url captured at read time. The chat sidecar is keyed by THIS in both load and save — NOT by
    /// `write(to:)`'s url (which during a safe-save is a temp path, so it would key differently than the reopen).
    private var chatKeyURL: URL?

    // Explicit ⌘S only — never silently rewrite the user's source PDF in place. (isDocumentEdited is left to
    // NSDocument's change-count machinery so the edited dot + save-on-close prompt work after markup edits.)
    override class var autosavesInPlace: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        // On a removable/external volume, PDFDocument(url:) memory-maps the file — if the volume later
        // unmounts, the next page fault is an uncatchable SIGBUS. Read such files fully into RAM instead
        // (PDFDocument(data:) holds no file mapping), trading a little memory for crash-safety. Internal
        // volumes keep the efficient mmap path.
        let doc: PDFDocument?
        if Self.isRemovable(url) {
            let data = try Data(contentsOf: url, options: [])      // no .mappedIfSafe → real copy in RAM
            doc = PDFDocument(data: data)
        } else {
            doc = PDFDocument(url: url)
        }
        guard let doc else {
            throw NSError(domain: "Openview", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This document could not be opened.",
                NSLocalizedRecoverySuggestionErrorKey: "The file may be corrupt or not a valid PDF."
            ])
        }
        pdfDocument = doc
        chatKeyURL = url                                       // key the chat sidecar by the source path
        loadedChat = ChatStore.load(for: url)                 // restore the saved chat (if any) for this PDF
    }

    /// True if the URL lives on a non-internal (removable/external/network) volume.
    private static func isRemovable(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsRemovableKey])
        else { return false }
        if let internalVol = v.volumeIsInternal { return !internalVol }
        return v.volumeIsRemovable ?? false
    }

    override func makeWindowControllers() {
        let controller = DocumentWindowController()
        addWindowController(controller)
        // Pass the source fileURL explicitly: for a removable-volume PDF loaded via PDFDocument(data:), the
        // PDFDocument's own documentURL is nil, so the window controller needs the NSDocument's fileURL to
        // create the grounding (Q&A) engine (otherwise AI features are dead on external drives).
        controller.loadDocument(pdfDocument, fileURL: fileURL, chat: loadedChat)
    }

    /// Serialize the in-memory PDFDocument (including the markup annotations) back to PDF data. `dataRepresentation()`
    /// writes the text-markup annotations into the file, so they reopen identically here and in Preview.
    override func data(ofType typeName: String) throws -> Data {
        prepareForSave?()                                       // drop transient (citation) annotations first
        guard let data = pdfDocument?.dataRepresentation() else {
            throw NSError(domain: "Openview", code: NSFileWriteUnknownError, userInfo: [
                NSLocalizedDescriptionKey: "The document could not be saved."
            ])
        }
        return data
    }

    /// Persist the AI-panel chat alongside the PDF on an actual save (⌘S / Save As). Because this only runs when
    /// the document is written, "Don't Save" never updates the sidecar — the chat follows the document's save
    /// semantics. The chat is keyed by the destination `url`, so Save As carries it to the new file's key.
    override func write(to url: URL, ofType typeName: String) throws {
        try super.write(to: url, ofType: typeName)             // writes the PDF (markup) via data(ofType:)
        // Key by the captured source url (not `url`, which is a temp path during a safe-save) so the reopen finds it.
        ChatStore.save(currentChat?() ?? [], for: chatKeyURL ?? fileURL ?? url)
    }
}
