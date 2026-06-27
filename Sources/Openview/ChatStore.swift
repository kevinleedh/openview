import Foundation
import CryptoKit

/// One saved Q&A turn: the user's question + the answer's markdown text. Persisted so the chat survives
/// reopening the document — but ONLY when the user SAVES (⌘S): the sidecar is written from
/// `OpenviewDocument.write(to:)`, so "Don't Save" leaves the last-saved chat (or none) untouched, matching the
/// document's save semantics.
struct ChatTurn: Codable {
    let question: String
    let answer: String
}

/// Per-document chat persistence. Stored as JSON in Application Support, keyed by a hash of the PDF's full path
/// (the same scheme as the retrieval index) — NOT inside the PDF: PDFKit drops custom metadata keys on
/// `dataRepresentation()` (measured), and a hidden annotation would leak into other viewers. Consequence: the
/// chat lives on THIS Mac and is path-keyed, so moving/renaming the PDF orphans it (harmless — reopens empty).
enum ChatStore {

    static func load(for pdfURL: URL) -> [ChatTurn] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path(for: pdfURL))),
              let turns = try? JSONDecoder().decode([ChatTurn].self, from: data) else { return [] }
        return turns
    }

    /// Write the chat for `pdfURL`. An empty chat removes the file so a reopen is clean (no stale turns).
    static func save(_ turns: [ChatTurn], for pdfURL: URL) {
        let p = path(for: pdfURL)
        do {
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            guard !turns.isEmpty else { try? FileManager.default.removeItem(atPath: p); return }
            try JSONEncoder().encode(turns).write(to: URL(fileURLWithPath: p), options: .atomic)
        } catch {
            NSLog("[chat] save failed: %@", error.localizedDescription)
        }
    }

    private static func path(for pdfURL: URL) -> String {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))?
            .appendingPathComponent("Openview/chat", isDirectory: true)
            ?? fm.temporaryDirectory.appendingPathComponent("Openview/chat", isDirectory: true)
        let canonical = pdfURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let base = pdfURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(base)-\(key).json").path
    }
}
