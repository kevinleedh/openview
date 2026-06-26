import AppKit

/// Render the Markdown the LLM emits into an `NSAttributedString` for the answer text views. Handles INLINE
/// **bold** / *italic* / `code` (via Foundation's Markdown parser) plus line-level bullets ("- " / "* " / "+ "
/// → "•") and ATX headers ("# "…"### "). Uses the system font and a caller-supplied color so it adapts to
/// Light/Dark automatically. Parses per LINE so it stays cheap enough to run on every streaming snapshot, and
/// so a mid-stream unclosed `**` only affects the current line (it shows literally until its pair arrives).
enum Markdown {

    static func attributed(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(line(raw, size: size, color: color))
        }
        return out
    }

    /// One line: peel a leading bullet / header marker, then inline-parse the remainder.
    private static func line(_ raw: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let leading = String(raw.prefix { $0 == " " })
        let body = raw.drop { $0 == " " }
        var rest = String(body)
        var bullet: String? = nil
        var headerSize = size
        var headerBold = false

        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            bullet = leading + "•  "
            rest = String(body.dropFirst(2))
        } else if body.hasPrefix("### ") { rest = String(body.dropFirst(4)); headerSize = size + 1; headerBold = true }
        else if body.hasPrefix("## ")    { rest = String(body.dropFirst(3)); headerSize = size + 2; headerBold = true }
        else if body.hasPrefix("# ")     { rest = String(body.dropFirst(2)); headerSize = size + 3; headerBold = true }

        let inline = inlineAttributed(rest, size: headerSize, color: color, baseBold: headerBold)
        guard let prefix = bullet else { return inline }
        let result = NSMutableAttributedString(string: prefix,
            attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
        result.append(inline)
        return result
    }

    /// Inline-only Markdown → attributed, converting bold/italic/code intents to real fonts.
    private static func inlineAttributed(_ s: String, size: CGFloat, color: NSColor, baseBold: Bool) -> NSAttributedString {
        let base = baseBold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        let plain = NSAttributedString(string: s, attributes: [.font: base, .foregroundColor: color])
        guard let parsed = try? AttributedString(markdown: s, options: .init(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)) else { return plain }

        let ns = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let full = NSRange(location: 0, length: ns.length)
        ns.addAttribute(.font, value: base, range: full)
        ns.addAttribute(.foregroundColor, value: color, range: full)
        ns.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            let intent: InlinePresentationIntent
            if let i = value as? InlinePresentationIntent { intent = i }
            else if let n = value as? NSNumber { intent = InlinePresentationIntent(rawValue: n.uintValue) }
            else if let n = value as? UInt { intent = InlinePresentationIntent(rawValue: n) }
            else { return }
            var font = base
            if intent.contains(.stronglyEmphasized) { font = NSFont.boldSystemFont(ofSize: size) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if intent.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
            ns.addAttribute(.font, value: font, range: range)
        }
        return ns
    }
}
