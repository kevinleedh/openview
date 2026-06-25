import AppKit
import PDFKit

/// The PDF as the document model — Preview's exact shape (`PDFDocument` wrapped in an `NSDocument`).
/// `@objc(PadafaDocument)` exposes the unqualified Obj-C name referenced by Info.plist's NSDocumentClass.
/// Supports text-markup editing: highlight/underline/strikethrough annotations are added to `pdfDocument`
/// and serialized back into the PDF on ⌘S (`data(ofType:)` → `dataRepresentation()`), so Preview and other
/// viewers see them too. Explicit-save only (no autosave-in-place of the user's source file).
@objc(PadafaDocument)
final class PadafaDocument: NSDocument {

    private(set) var pdfDocument: PDFDocument?

    /// Strip transient (non-user) annotations just before serializing — wired by the window controller to the
    /// PDFViewController so a verification citation highlight isn't baked into the saved file.
    var prepareForSave: (() -> Void)?

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
            throw NSError(domain: "Padafa", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This document could not be opened.",
                NSLocalizedRecoverySuggestionErrorKey: "The file may be corrupt or not a valid PDF."
            ])
        }
        pdfDocument = doc
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
        // create the grounding/summarize engine (otherwise AI features are dead on external drives).
        controller.loadDocument(pdfDocument, fileURL: fileURL)
    }

    /// Serialize the in-memory PDFDocument (including the markup annotations) back to PDF data. `dataRepresentation()`
    /// writes the text-markup annotations into the file, so they reopen identically here and in Preview.
    override func data(ofType typeName: String) throws -> Data {
        prepareForSave?()                                       // drop transient (citation) annotations first
        guard let data = pdfDocument?.dataRepresentation() else {
            throw NSError(domain: "Padafa", code: NSFileWriteUnknownError, userInfo: [
                NSLocalizedDescriptionKey: "The document could not be saved."
            ])
        }
        return data
    }
}
