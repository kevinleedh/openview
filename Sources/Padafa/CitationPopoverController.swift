import AppKit

/// Popover for a MULTI-source citation chip `[p.N +k]` (F4). Clicking such a chip does not jump blindly
/// to the first citation — it opens this popover so the user can choose *which* supporting source to
/// verify. BROWSE the N candidates with ‹ › (preview only — the PDF stays put), then COMMIT by clicking
/// the item or pressing Return, which jumps + highlights it (that item becomes active ✓). Each item is
/// labelled by page + element kind + position on the page so same-page sources are distinguishable.
/// Single-source chips keep their one-click jump and never reach here.
///
/// Content is OPAQUE (controlBackgroundColor): the citation text is a reading surface and must never sit
/// on translucency (CLAUDE.md content-first). One citation shown at a time, paged.
final class CitationPopoverController: NSViewController {

    private let citations: [Citation]
    private let onJump: (Citation) -> Void
    private var index = 0
    private var activeIndex: Int?

    private let indexLabel = NSTextField(labelWithString: "")
    private let prev = NSButton()
    private let next = NSButton()
    private let itemButton = NSButton()

    init(citations: [Citation], onJump: @escaping (Citation) -> Void) {
        self.citations = citations
        self.onJump = onJump
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor   // opaque — no translucency

        prev.title = "‹"; prev.bezelStyle = .rounded; prev.target = self; prev.action = #selector(goPrev)
        next.title = "›"; next.bezelStyle = .rounded; next.target = self; next.action = #selector(goNext)
        indexLabel.alignment = .center
        indexLabel.font = .systemFont(ofSize: 11, weight: .medium)
        indexLabel.textColor = .secondaryLabelColor
        indexLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [prev, indexLabel, next])
        header.orientation = .horizontal
        header.spacing = 6

        itemButton.bezelStyle = .rounded
        itemButton.alignment = .left
        itemButton.target = self
        itemButton.action = #selector(jumpToCurrent)
        itemButton.keyEquivalent = "\r"          // Return commits the currently-browsed item (= click)

        let hint = NSTextField(labelWithString: "Click an item (or press Return) to verify it in the document.")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [header, itemButton, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            itemButton.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        preferredContentSize = NSSize(width: 260, height: 104)
        view = root
        refresh()
    }

    // PREVIEW vs SELECTION are separate (Kev): ‹ › only BROWSE between candidate sources — they update the
    // shown item but DO NOT move the PDF (browsing shouldn't make the page jump around). The user commits
    // by CLICKING the item (or pressing Return), and only THEN does the PDF jump + highlight.
    @objc private func goPrev() { if index > 0 { index -= 1; refresh() } }   // browse only — no jump
    @objc private func goNext() { if index < citations.count - 1 { index += 1; refresh() } }

    @objc private func jumpToCurrent() {                                     // commit: click item / Return
        activeIndex = index
        onJump(citations[index])      // → PDFViewController.jumpHighlight (one active highlight, D2)
        refresh()
    }

    private func refresh() {
        indexLabel.stringValue = "\(index + 1) / \(citations.count)"
        prev.isEnabled = index > 0
        next.isEnabled = index < citations.count - 1
        let check = (activeIndex == index) ? "  ✓" : ""
        itemButton.title = itemLabels[index] + check
    }

    // Distinguishable labels (Kev: three sources all read "p.5 · text" → unpickable). The sidecar's
    // citation JSON carries NO snippet text (only page/type/bbox/origin/parser_page), so we differentiate
    // by POSITION on the page using data already present — no sidecar/grounding change. Computed once.
    private lazy var itemLabels: [String] = makeLabels()

    private func makeLabels() -> [String] {
        var labels = citations.map { c -> String in
            let base = "p.\(c.page) · \(friendlyType(c.type))"
            if let where_ = verticalDescriptor(c) { return "\(base) · \(where_)" }
            return base
        }
        // Guarantee distinctness: if two still collide (same page+type+band), append a 1-based ordinal.
        var counts: [String: Int] = [:]
        labels.forEach { counts[$0, default: 0] += 1 }
        if counts.values.contains(where: { $0 > 1 }) {
            var seen: [String: Int] = [:]
            labels = labels.map { l in
                guard counts[l]! > 1 else { return l }
                seen[l, default: 0] += 1
                return "\(l) (\(seen[l]!))"
            }
        }
        return labels
    }

    /// Where on the page the citation sits (top→bottom), from its bbox + page height — a positional hint
    /// so same-page sources are distinguishable. Returns nil when the parser page size is unavailable.
    private func verticalDescriptor(_ c: Citation) -> String? {
        guard c.bbox.count == 4, c.parser_page.count == 2, c.parser_page[1] > 0 else { return nil }
        let pageHeight = c.parser_page[1]
        let center = (c.bbox[1] + c.bbox[3]) / 2.0
        // Docling bottomLeft origin measures y up from the bottom → flip to a from-the-top fraction.
        let fromTop = (c.origin == "bottomLeft") ? 1.0 - center / pageHeight : center / pageHeight
        switch min(max(fromTop, 0), 1) {
        case ..<0.2:  return "top"
        case ..<0.4:  return "upper"
        case ..<0.6:  return "middle"
        case ..<0.8:  return "lower"
        default:      return "bottom"
        }
    }

    /// Map the citation's element type to a short, user-facing kind. Uses only data already on the
    /// citation — this does NOT touch the grounding/answer pipeline.
    private func friendlyType(_ type: String) -> String {
        switch type {
        case "table", "table_row": return "table"
        case "picture", "figure":  return "figure"
        case "caption":            return "caption"
        default:                   return "text"
        }
    }
}
