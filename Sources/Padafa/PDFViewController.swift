import AppKit
import PDFKit
import PadafaKit

/// Receives viewer-state changes so the toolbar can update WITHOUT any view re-render in the scroll
/// path. (In the old SwiftUI build, publishing these re-ran `ContentView.body` mid-glide and fought the
/// momentum animation. Here they are plain label writes — cheap, no layout cascade.)
/// A PDFView that forwards live appearance changes. PDFView caches its `backgroundColor` and won't
/// re-resolve a dynamic system color on a Light↔Dark switch, so the controller re-applies it here.
/// `viewDidChangeEffectiveAppearance` exists on NSView (not NSViewController), hence this thin subclass.
final class CanvasPDFView: PDFView {
    var onAppearanceChange: (() -> Void)?
    // Markup hooks (Preview-style highlight/underline/strikethrough + text boxes). All optional — nil = plain viewer.
    var onMarkupMouseDown: ((NSEvent) -> Bool)?       // return true to CONSUME (text-box select / re-edit)
    var onMarkupMouseDragged: ((NSEvent) -> Bool)?    // return true to CONSUME (text-box move)
    var onMarkupMouseUp: (() -> Void)?
    var onMarkupDeleteKey: (() -> Bool)?              // return true if an annotation was deleted (consume the key)
    var onMarkupContextMenu: ((NSEvent) -> NSMenu?)?  // non-nil menu = a markup was right-clicked

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func mouseDown(with event: NSEvent) {
        if onMarkupMouseDown?(event) == true { return }   // consumed (text-box insert / re-edit) → no text selection
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if onMarkupMouseDragged?(event) == true { return }   // consumed (moving a text box) → no text selection
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)                    // let PDFKit finalize the drag selection first
        onMarkupMouseUp?()                            // then commit a highlight / finish a box move
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117,    // delete (backspace) / forward-delete
           onMarkupDeleteKey?() == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let m = onMarkupContextMenu?(event) { return m }
        return super.menu(for: event)
    }
}

/// A text-markup style applied as a real `PDFAnnotation` (serialized into the PDF on save → visible in
/// Preview and every viewer). New symbol; nothing else changes.
enum MarkupType {
    case highlight, underline, strikethrough
    var subtype: PDFAnnotationSubtype {
        switch self {
        case .highlight:     return .highlight
        case .underline:     return .underline
        case .strikethrough: return .strikeOut
        }
    }
}

/// The active markup tool — a single state so turning one tool on turns the others off (Preview model).
/// .select = drag selects text (Ask pill); .highlighter = drag marks/toggles; .text = click drops a text box.
enum MarkupTool { case select, highlighter, text }

extension PDFAnnotation {
    /// True if this is a text-markup annotation of the given subtype (`type` returns e.g. "Highlight", no slash).
    func isMarkup(_ subtype: PDFAnnotationSubtype) -> Bool {
        let want = subtype.rawValue.hasPrefix("/") ? String(subtype.rawValue.dropFirst()) : subtype.rawValue
        return (type ?? "") == want
    }
}

/// Apple-Preview highlighter palette (alpha 1 — the `.highlight` subtype renders its own translucency).
enum MarkupPalette {
    static let yellow = NSColor(srgbRed: 1.00, green: 0.90, blue: 0.32, alpha: 1)
    static let green  = NSColor(srgbRed: 0.62, green: 0.87, blue: 0.42, alpha: 1)
    static let blue   = NSColor(srgbRed: 0.49, green: 0.78, blue: 0.99, alpha: 1)
    static let pink   = NSColor(srgbRed: 0.99, green: 0.51, blue: 0.62, alpha: 1)
    static let purple = NSColor(srgbRed: 0.78, green: 0.58, blue: 0.93, alpha: 1)
    static let swatches: [(name: String, color: NSColor)] =
        [("Yellow", yellow), ("Green", green), ("Blue", blue), ("Pink", pink), ("Purple", purple)]
}

protocol PDFViewControllerDelegate: AnyObject {
    func pdfViewControllerDidUpdatePageLabel(_ vc: PDFViewController, label: String)
    func pdfViewControllerDidUpdateZoom(_ vc: PDFViewController, percent: Int)
    func pdfViewControllerDidUpdateSearch(_ vc: PDFViewController, count: Int, position: String)
}

/// Hosts `PDFView` **directly** as an AppKit view (no `NSViewRepresentable`, no SwiftUI). This is the
/// thesis of the rewrite (migration_appkit.md): with the view in a plain `NSViewController`, nothing in
/// our code re-renders during scroll, so PDFView's native momentum rides AppKit's responder chain
/// untouched. Owns all imperative viewer ops (zoom, page label, in-document find) ported from the prior
/// build's `PDFController`, surfacing changes to the toolbar via `delegate`.
final class PDFViewController: NSViewController, NSTextViewDelegate {

    let pdfView = CanvasPDFView()
    weak var delegate: PDFViewControllerDelegate?

    /// Delivers PDF-selected text to the AI panel when the floating "Ask" pill is tapped (the user then types
    /// their own question — never auto-sent). Wired in MainSplitViewController. New symbol; no existing
    /// signature changes.
    var onAskSelection: ((String) -> Void)?

    private(set) var matches: [PDFSelection] = []
    private var matchIndex = 0
    private var pageLabelWork: DispatchWorkItem?
    private var activeCitation: (page: PDFPage, annotation: PDFAnnotation)?
    private var askScrollObserved = false

    // MARK: – Markup state (Preview-style highlight / underline / strikethrough + text boxes)
    var activeMarkup: MarkupType = .highlight
    var activeColor: NSColor = MarkupPalette.yellow
    /// Single tool state (replaces the old isHighlighterModeOn Bool) — one tool on turns the others off.
    private(set) var currentTool: MarkupTool = .select
    private var selectedMarkup: PDFAnnotation?                  // last markup the user clicked → Delete target
    private var selectedTextAnnotation: PDFAnnotation?         // selected freeText box → Delete + style bar
    private var selectionView: TextBoxSelectionView?          // move/resize chrome over the selected box
    private var draggingBox: PDFAnnotation?                   // box being moved in a single click-drag gesture
    private var dragBoxStartBounds: CGRect = .zero
    private var dragBoxStartMouse: NSPoint = .zero
    private var editingOverlay: NSTextView?                    // inline editor over a text box (reliable typing)
    private var editingAnnotation: PDFAnnotation?
    private lazy var textStyleBar = TextStyleBarController()    // top font/size/B-I-U/color/align bar
    /// → NSDocument.updateChangeCount(.changeDone); wired by the window controller. Marks the PDF dirty.
    var onMarkupChange: (() -> Void)?
    /// → toolbar tool-button states (highlighter segment + T button); wired by the window controller.
    var onToolChange: ((MarkupTool) -> Void)?

    /// Small floating pill shown just under a drag selection; tap → quote the selection into the AI panel.
    private lazy var askButton: NSButton = {
        let b = NSButton(title: "Ask", target: self, action: #selector(askButtonTapped))
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 11
        b.attributedTitle = NSAttributedString(string: "Ask", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        b.shadow = shadow
        b.isHidden = true
        return b
    }()

    override func loadView() {
        pdfView.autoScales = true                              // fit width, scale with the window
        pdfView.displayMode = .singlePageContinuous           // fixed continuous scroll (CLAUDE.md Viewer)
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true                     // soft drop shadow around each page (Preview-style)
        pdfView.onAppearanceChange = { [weak self] in self?.applyCanvasBackground() }  // re-resolve on Light↔Dark
        applyCanvasBackground()                               // Preview-style canvas (see the method)
        // The PDFView IS the controller's view — the most direct host possible. As a split item's view,
        // AppKit sizes it via constraints; nothing in our code participates in layout during scroll.
        view = pdfView

        // Markup (Preview-style) event hooks: drag-up commits/toggles a highlight; mousedown drops a text box
        // (text tool) / re-edits or selects one / records a deletion target; Delete removes; right-click → menu.
        pdfView.onMarkupMouseUp = { [weak self] in self?.handleMarkupMouseUp() }
        pdfView.onMarkupMouseDown = { [weak self] event in self?.handleMarkupMouseDown(event) ?? false }
        pdfView.onMarkupMouseDragged = { [weak self] event in self?.handleMarkupMouseDragged(event) ?? false }
        pdfView.onMarkupDeleteKey = { [weak self] in self?.deleteSelectedAnnotation() ?? false }
        pdfView.onMarkupContextMenu = { [weak self] event in self?.markupContextMenu(for: event) }

        // The text style bar mutates the selected freeText annotation; reflect it on screen and mark dirty.
        textStyleBar.onChange = { [weak self] annotation in
            guard let self, let page = annotation.page else { return }
            self.pdfView.setNeedsDisplay(self.pdfView.convert(annotation.bounds, from: page))
            self.editingOverlay.map { self.syncOverlay($0, to: annotation) }   // mirror onto the live editor too
            self.onMarkupChange?()
        }
        textStyleBar.onUnderlineChange = { [weak self] on in
            guard let tv = self?.editingOverlay else { return }                // overlay-only (PDFKit bake limit)
            let range = NSRange(location: 0, length: (tv.string as NSString).length)
            let value = on ? NSUnderlineStyle.single.rawValue : 0
            tv.textStorage?.addAttribute(.underlineStyle, value: value, range: range)
            tv.typingAttributes[.underlineStyle] = value
        }

        // The text style bar is a TOP bar under the toolbar (like the search-results bar), hidden until a text
        // box is selected.
        let styleBar = textStyleBar.view
        styleBar.translatesAutoresizingMaskIntoConstraints = false
        styleBar.isHidden = true
        pdfView.addSubview(styleBar)
        NSLayoutConstraint.activate([
            styleBar.topAnchor.constraint(equalTo: pdfView.safeAreaLayoutGuide.topAnchor),
            styleBar.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
            styleBar.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
            styleBar.heightAnchor.constraint(equalToConstant: 44),
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        nc.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: pdfView)
        nc.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: pdfView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Preview-style canvas: the semantic "behind the page" system color — bright/near-white in Light,
    /// dark in Dark. Resolve it under the view's CURRENT effective appearance so PDFView gets the right
    /// concrete color (a plain `pdfView.backgroundColor = .underPageBackgroundColor` would stick at
    /// whatever appearance was active when first assigned and never darken on a live Light→Dark switch).
    private func applyCanvasBackground() {
        var color = NSColor.underPageBackgroundColor
        pdfView.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.underPageBackgroundColor.usingColorSpace(.deviceRGB) ?? color
        }
        pdfView.backgroundColor = color
    }

    /// Show a parsed PDF, starting at the top of page 1.
    func load(_ document: PDFDocument?) {
        guard let document else { return }
        closeSearch()
        pdfView.document = document
        if let first = document.page(at: 0) {
            pdfView.go(to: PDFDestination(page: first, at: NSPoint(x: 0, y: CGFloat.greatestFiniteMagnitude)))
        }
        applyPageLabel()
        scaleChanged()
    }

    /// Detach the document (e.g. the backing volume vanished): drop the possibly memory-mapped
    /// PDFDocument so no further page render can fault on an unmapped vnode.
    func clear() {
        closeSearch()
        activeCitation = nil
        pdfView.document = nil
        applyPageLabel()
    }

    var hasOutline: Bool { pdfView.document?.outlineRoot != nil }

    // MARK: – Page indicator + zoom (observed, scroll-safe)

    @objc private func pageChanged() { schedulePageLabel() }

    @objc private func scaleChanged() {
        let percent = Int((pdfView.scaleFactor * 100).rounded())
        delegate?.pdfViewControllerDidUpdateZoom(self, percent: percent)
        syncTextChromeToViewport()                                // keep the box editor/handles aligned + sized to the new zoom
    }

    /// Re-anchor the text-box editor (and rescale its zoom-dependent font) or the selection handles when the
    /// page moves/zooms under them, so they don't drift off the box.
    private func syncTextChromeToViewport() {
        if let tv = editingOverlay, let a = editingAnnotation, let page = a.page {
            tv.frame = pdfView.convert(a.bounds, from: page)
            tv.font = overlayFont(for: a)
        } else if selectedTextAnnotation != nil {
            repositionSelectionChrome()
        }
    }

    // During a momentum glide the current page crosses boundaries rapidly. Setting an NSTextField does
    // not re-render a view tree (unlike the SwiftUI build), but we still coalesce the updates so the
    // indicator settles once rather than thrashing — purely cosmetic smoothing, never blocking scroll.
    private func schedulePageLabel() {
        pageLabelWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyPageLabel() }
        pageLabelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func applyPageLabel() {
        guard let doc = pdfView.document, let cur = pdfView.currentPage else {
            delegate?.pdfViewControllerDidUpdatePageLabel(self, label: "")
            return
        }
        delegate?.pdfViewControllerDidUpdatePageLabel(self, label: "Page \(doc.index(for: cur) + 1) of \(doc.pageCount)")
    }

    /// Switch the page display mode (Continuous / Single / Two Pages). Continuous is the verified default;
    /// the non-continuous paged modes are user-selectable per the view-options scroll-mode group.
    /// We drive `displayMode` DIRECTLY and deliberately do NOT call `usePageViewController(_:)` — that mode
    /// ignores `displayMode` (forces single-page-continuous) and would break the 4-mode switcher. Driving
    /// displayMode directly also preserves PDFKit's built-in page-flip slide transition in the paged modes
    /// (Single/Two Pages), which matches Preview — do not disable it.
    func setDisplayMode(_ mode: PDFDisplayMode) {
        pdfView.displayMode = mode
    }

    func zoomIn()     { pdfView.scaleFactor = min(pdfView.scaleFactor * 1.2, pdfView.maxScaleFactor); scaleChanged() }
    func zoomOut()    { pdfView.scaleFactor = max(pdfView.scaleFactor / 1.2, pdfView.minScaleFactor); scaleChanged() }
    func actualSize() { pdfView.scaleFactor = 1.0; scaleChanged() }

    /// Rotate ONLY the current (visible) page 90° counter-clockwise (left) — matches Preview, which rotates
    /// the page you're looking at, not the whole document (the prior whole-document loop was the bug). PDFKit
    /// `rotation` is an absolute property and normalizes negatives to 0/90/180/270 on its own; it's recorded
    /// in the page's /Rotate (so it would persist on save), but this pass only applies+renders it — the save
    /// pipeline / save→reopen persistence is a separate step. Other pages are left untouched.
    func rotateLeft() {
        guard let page = pdfView.currentPage else { return }
        page.rotation = page.rotation - 90        // PDFKit normalizes negative rotations to 0/90/180/270
        pdfView.layoutDocumentView()              // re-layout/re-render this page only
    }

    // MARK: – ⌘F in-document find (highlight, count, next/prev) — PDFKit built-in

    @discardableResult
    func search(_ text: String) -> [PDFSelection] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let doc = pdfView.document else { closeSearch(); return [] }
        clearSelection()
        matches = doc.findString(trimmed, withOptions: [.caseInsensitive])
        matchIndex = 0
        if !matches.isEmpty { focusMatch() }
        notifySearch()
        return matches
    }

    func searchNext() {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + 1) % matches.count
        focusMatch(); notifySearch()
    }

    func searchPrev() {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex - 1 + matches.count) % matches.count
        focusMatch(); notifySearch()
    }

    /// Jump to a specific match index (used by the search-results sidebar list).
    func focusMatch(at index: Int) {
        guard matches.indices.contains(index) else { return }
        matchIndex = index
        focusMatch(); notifySearch()
    }

    func closeSearch() {
        clearSelection()
        matches = []
        matchIndex = 0
        notifySearch()
    }

    private func focusMatch() {
        guard matches.indices.contains(matchIndex) else { return }
        let sel = matches[matchIndex]
        sel.color = .systemYellow                              // search highlight = yellow (distinct from blue citations)
        pdfView.setCurrentSelection(sel, animate: true)
        pdfView.scrollSelectionToVisible(nil)
    }

    private func clearSelection() { pdfView.setCurrentSelection(nil, animate: false) }

    private func notifySearch() {
        let position = matches.isEmpty ? "" : "\(matchIndex + 1) of \(matches.count)"
        delegate?.pdfViewControllerDidUpdateSearch(self, count: matches.count, position: position)
    }

    // MARK: – Citation jump + highlight (F4 — the verification moment)

    /// Convert a citation's parser bbox via CoordinateAdapter (the y-flip), jump there, and draw the
    /// system-accent (blue) citation highlight. One active at a time (spec D2) — distinct from the
    /// yellow search highlight. This is the proven F4 path ported from the prior build (IoU 0.931).
    func jumpHighlight(_ c: Citation) {
        guard c.bbox.count == 4, let page = pdfView.document?.page(at: c.page - 1) else { return }
        let mediaBox = page.bounds(for: .mediaBox)
        let origin = CoordOrigin(rawValue: c.origin) ?? .topLeft
        let box = ParserBBox(l: c.bbox[0], t: c.bbox[1], r: c.bbox[2], b: c.bbox[3], origin: origin)
        let rect: CGRect
        if c.parser_page.count == 2, c.parser_page[0] > 0, c.parser_page[1] > 0 {
            rect = CoordinateAdapter.toPDFKitRect(
                box,
                parserPageSize: CGSize(width: c.parser_page[0], height: c.parser_page[1]),
                pdfkitPageSize: CGSize(width: mediaBox.width, height: mediaBox.height))
        } else {
            rect = CoordinateAdapter.toPDFKitRect(box, pageHeight: mediaBox.height)
        }
        if let active = activeCitation { active.page.removeAnnotation(active.annotation) }   // one active (D2)
        let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        annotation.color = NSColor.systemBlue.withAlphaComponent(0.35)
        page.addAnnotation(annotation)
        activeCitation = (page, annotation)
        pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: rect.minX, y: rect.maxY)))
        pdfView.go(to: rect, on: page)

        // ── F4 instrumentation (logging ONLY — no behaviour change) — one line per chip click. ──
        // Decoder: mirrored y = y-flip sign · constant translation = origin · wrong size/pos at zoom =
        // scale not applied · drift on back pages = page-offset accumulation · wrong page = off-by-one.
        let viewSpaceRect = pdfView.convert(rect, from: page)
        let docVisible = pdfView.documentView?.visibleRect ?? .zero
        NSLog("[F4] cite page=%d (1-based) → PDFKit idx=%d (0-based) | origin=%@ rawBBox=%@ parser_page=%@ | mediaBox=%.1f×%.1f | pageSpaceRect=%@ | scale=%.3f docVisibleOrigin=%@ | viewSpaceRect=%@",
              c.page, c.page - 1, c.origin, "\(c.bbox)", "\(c.parser_page)",
              mediaBox.width, mediaBox.height, NSStringFromRect(rect),
              pdfView.scaleFactor, NSStringFromPoint(docVisible.origin), NSStringFromRect(viewSpaceRect))
    }

    // MARK: – "Ask" floating button on text selection → quote into the AI panel

    /// PDFViewSelectionChanged: show a floating "Ask" pill just ABOVE the start of a non-empty drag selection,
    /// hide it otherwise. Skipped while a ⌘F search is active so it doesn't clutter match navigation.
    @objc private func selectionChanged() {
        guard currentTool == .select,                              // highlighter/text modes never show the Ask pill
              matches.isEmpty,
              let sel = pdfView.currentSelection,
              let s = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              let page = sel.pages.first else { hideAskButton(); return }
        let firstLine = sel.selectionsByLine().first ?? sel
        let rectOnPage = firstLine.bounds(for: page)
        let rectInView = pdfView.convert(rectOnPage, from: page)
        positionAskButton(above: rectInView)
        ensureSelectionScrollObserved()
    }

    /// Place the pill just ABOVE the selection's first line. PDFView is non-flipped (origin bottom-left), so
    /// "above" means a LARGER y (rect.maxY is the line's TOP edge). Re-set the accent fill on each show so it
    /// resolves under the current appearance.
    private func positionAskButton(above rect: NSRect) {
        if askButton.superview == nil { pdfView.addSubview(askButton) }
        let size = NSSize(width: 54, height: 22)
        var origin = NSPoint(x: rect.minX, y: rect.maxY + 6)
        origin.x = min(max(4, origin.x), max(4, pdfView.bounds.maxX - size.width - 4))
        origin.y = min(origin.y, pdfView.bounds.maxY - size.height - 4)
        askButton.frame = NSRect(origin: origin, size: size)
        askButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        askButton.isHidden = false
        pdfView.addSubview(askButton, positioned: .above, relativeTo: nil)   // keep on top of the document
    }

    private func hideAskButton() { askButton.isHidden = true }

    /// Tap → clean the selection (PDFKit inserts a \n at each line break) and hand it to the AI panel, which
    /// inserts it as a quotation and focuses its input. The selection highlight is left intact.
    @objc private func askButtonTapped() {
        let raw = pdfView.currentSelection?.string ?? ""
        let text = raw.replacingOccurrences(of: "\n", with: " ")
                      .trimmingCharacters(in: .whitespacesAndNewlines)
        hideAskButton()
        guard !text.isEmpty else { return }
        onAskSelection?(text)
    }

    /// Lazily observe the internal document clip view so any scroll hides the (now-stale-positioned) pill.
    /// PDFView keeps its scroller as an internal subview (it isn't in an enclosingScrollView), so reach it there.
    private func ensureSelectionScrollObserved() {
        guard !askScrollObserved,
              let clip = pdfView.subviews.compactMap({ $0 as? NSScrollView }).first?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(selectionViewportMoved),
                                               name: NSView.boundsDidChangeNotification, object: clip)
        askScrollObserved = true
    }

    @objc private func selectionViewportMoved() { hideAskButton(); syncTextChromeToViewport() }

    // MARK: – Text markup (highlight / underline / strikethrough) → real PDF annotations, saved with the doc

    /// Apply markup to the current selection — ONE annotation PER LINE (via `selectionsByLine()`) so a
    /// multi-line selection doesn't collapse into one big rectangle (matches Preview). TOGGLE semantics: a line
    /// already marked with the SAME subtype + SAME color is REMOVED (effect off); same subtype different color is
    /// RE-COLORED; otherwise a new annotation is added. All serialized into the PDF on save; marks doc dirty.
    func applyMarkup(_ type: MarkupType, color: NSColor) {
        guard let sel = pdfView.currentSelection else { return }
        let subtype = type.subtype
        var changed = false
        for line in sel.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let lineBounds = line.bounds(for: page)
            let hit = page.annotations.first {
                $0.isMarkup(subtype) && $0.bounds.intersects(lineBounds) && Self.overlapRatio($0.bounds, lineBounds) > 0.55
            }
            if let a = hit {
                if Self.colorsApproxEqual(a.color, color) { page.removeAnnotation(a) }   // same → toggle off
                else { a.color = color }                                                 // recolor in place
            } else {
                let a = PDFAnnotation(bounds: lineBounds, forType: subtype, withProperties: nil)
                a.color = color
                page.addAnnotation(a)
            }
            changed = true
        }
        pdfView.clearSelection()
        if changed { onMarkupChange?() }
    }

    /// intersection area ÷ lineBounds area — how much an existing annotation covers this line.
    private static func overlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, b.width > 0, b.height > 0 else { return 0 }
        return (inter.width * inter.height) / (b.width * b.height)
    }

    /// Per-channel RGBA equality within ~0.02 (markup colors are fixed palette shades).
    private static func colorsApproxEqual(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02 && abs(a.alphaComponent - b.alphaComponent) < 0.02
    }

    /// Pen segment toggle: .highlighter ↔ .select. Turning it ON with a live selection marks immediately.
    func toggleHighlighterMode() {
        setTool(currentTool == .highlighter ? .select : .highlighter)
        if currentTool == .highlighter, hasNonEmptySelection { applyMarkup(activeMarkup, color: activeColor) }
    }

    /// T button: drop a NEW text box in the CENTRE of the visible area and start editing immediately (no
    /// second click). Stays in .select so the box can then be moved/resized.
    func insertTextBoxInView() {
        setTool(.select)
        let center = NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        guard let page = pdfView.page(for: center, nearest: true) else { return }
        let p = pdfView.convert(center, to: page)
        let bounds = CGRect(x: p.x - 60, y: p.y - 9, width: 120, height: 18)
        let a = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        a.contents = "Text"
        a.font = NSFont(name: "Helvetica", size: 10)               // default insert size (page-space points)
        a.fontColor = .systemRed
        a.color = .clear
        a.alignment = .left
        page.addAnnotation(a)
        onMarkupChange?()
        selectTextAnnotation(a)
        beginEditing(a)
    }

    /// Switch tools (mutually exclusive). Commits any in-progress edit; leaving .select deselects text boxes.
    private func setTool(_ tool: MarkupTool) {
        guard tool != currentTool else { return }
        finishEditing()
        if tool != .select { deselectTextAnnotation(); hideAskButton() }
        currentTool = tool
        onToolChange?(tool)
    }

    /// Color menu pick (Preview): a color implies the highlight style; apply to any live selection at once.
    func setMarkupColor(_ color: NSColor) {
        activeColor = color
        activeMarkup = .highlight
        if hasNonEmptySelection { applyMarkup(activeMarkup, color: activeColor) }
    }

    /// Style menu pick (Highlight / Underline / Strikethrough): set the style; apply to any live selection.
    func setMarkupType(_ type: MarkupType) {
        activeMarkup = type
        if hasNonEmptySelection { applyMarkup(activeMarkup, color: activeColor) }
    }

    private var hasNonEmptySelection: Bool {
        guard let s = pdfView.currentSelection?.string else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// mouse-up: finish a text-box move, or commit/toggle a highlighter drag.
    private func handleMarkupMouseUp() {
        if draggingBox != nil { draggingBox = nil; onMarkupChange?(); return }
        guard currentTool == .highlighter, hasNonEmptySelection else { return }
        applyMarkup(activeMarkup, color: activeColor)
    }

    /// MOUSE-DOWN router (the box's own selection chrome handles clicks once a box is already selected, so this
    /// fires for highlighter drags, clicks on an UNSELECTED box, and clicks on empty space).
    /// Highlighter → let the drag paint. Select + box → select it (+ arm a move; double-click edits). Empty →
    /// deselect + record a markup-deletion target. Returns true to CONSUME (so a box click doesn't text-select).
    private func handleMarkupMouseDown(_ event: NSEvent) -> Bool {
        if currentTool == .highlighter { selectedMarkup = nil; return false }
        if let box = freeTextAnnotation(at: event) {
            selectTextAnnotation(box)
            selectedMarkup = nil
            if event.clickCount == 2 { beginEditing(box); draggingBox = nil; return true }
            draggingBox = box                                     // arm a single-gesture move
            dragBoxStartBounds = box.bounds
            dragBoxStartMouse = pdfView.convert(event.locationInWindow, from: nil)
            return true
        }
        deselectTextAnnotation()
        selectedMarkup = markupAnnotation(at: event)
        return false
    }

    /// Drag a freeText box (single gesture, in view space → page space via the scale factor; both are y-up).
    private func handleMarkupMouseDragged(_ event: NSEvent) -> Bool {
        guard let box = draggingBox else { return false }
        let cur = pdfView.convert(event.locationInWindow, from: nil)
        let scale = max(pdfView.scaleFactor, 0.0001)
        var b = dragBoxStartBounds
        b.origin.x += (cur.x - dragBoxStartMouse.x) / scale
        b.origin.y += (cur.y - dragBoxStartMouse.y) / scale
        box.bounds = b
        repositionSelectionChrome()
        pdfView.setNeedsDisplay(pdfView.bounds)
        return true
    }

    /// Delete the selected freeText box first, else the selected markup. Either marks the document dirty.
    private func deleteSelectedAnnotation() -> Bool {
        if let a = selectedTextAnnotation, let page = a.page {
            page.removeAnnotation(a)
            deselectTextAnnotation()
            onMarkupChange?()
            return true
        }
        guard let a = selectedMarkup, let page = a.page else { return false }
        page.removeAnnotation(a)
        selectedMarkup = nil
        onMarkupChange?()
        return true
    }

    /// Right-click on a markup → a one-item "Remove Highlight" menu (Preview). Returns nil elsewhere so the
    /// default PDFView context menu (Copy, etc.) is used.
    private func markupContextMenu(for event: NSEvent) -> NSMenu? {
        guard let ann = markupAnnotation(at: event) else { return nil }
        selectedMarkup = ann
        let menu = NSMenu()
        let item = NSMenuItem(title: "Remove Highlight", action: #selector(removeMarkupFromMenu), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func removeMarkupFromMenu() { _ = deleteSelectedAnnotation() }

    /// The user-markup annotation under an event's location, or nil. Excludes the transient F4 citation
    /// highlight (managed separately, not user markup).
    private func markupAnnotation(at event: NSEvent) -> PDFAnnotation? {
        let viewPt = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: viewPt, nearest: true) else { return nil }
        let pagePt = pdfView.convert(viewPt, to: page)
        guard let ann = page.annotation(at: pagePt) else { return nil }
        if let active = activeCitation, active.annotation === ann { return nil }   // citation, not user markup
        return ["Highlight", "Underline", "StrikeOut"].contains(ann.type ?? "") ? ann : nil
    }

    /// Strip transient (non-user) annotations before the document serializes, so a verification citation
    /// highlight isn't baked into the saved PDF. Called by PadafaDocument.data(ofType:).
    func prepareForSave() {
        finishEditing()                                            // commit any in-progress text-box edit first
        if let active = activeCitation {
            active.page.removeAnnotation(active.annotation)
            activeCitation = nil
        }
    }

    // MARK: – Text boxes (freeText annotations): insert · inline edit · style

    /// The freeText box under an event's location, or nil.
    private func freeTextAnnotation(at event: NSEvent) -> PDFAnnotation? {
        let viewPt = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: viewPt, nearest: true) else { return nil }
        let pagePt = pdfView.convert(viewPt, to: page)
        guard let ann = page.annotation(at: pagePt) else { return nil }
        return (ann.type ?? "") == "FreeText" ? ann : nil
    }

    /// Select a box: show its move/resize chrome and the top style bar.
    private func selectTextAnnotation(_ a: PDFAnnotation) {
        selectedTextAnnotation = a
        showSelectionChrome(for: a)
        showTextStyleBar(for: a)
    }

    private func deselectTextAnnotation() {
        selectedTextAnnotation = nil
        removeSelectionChrome()
        hideTextStyleBar()
    }

    /// Add the accent border + side handles over the box (a subview of the PDFView, below the top style bar).
    private func showSelectionChrome(for a: PDFAnnotation) {
        removeSelectionChrome()
        guard let page = a.page else { return }
        let rect = pdfView.convert(a.bounds, from: page).insetBy(dx: -TextBoxSelectionView.inset, dy: -TextBoxSelectionView.inset)
        let sv = TextBoxSelectionView(frame: rect)
        sv.onGeometryChange = { [weak self] in
            guard let self, let box = self.selectedTextAnnotation, let page = box.page, let sv = self.selectionView else { return }
            box.bounds = self.pdfView.convert(sv.frame.insetBy(dx: TextBoxSelectionView.inset, dy: TextBoxSelectionView.inset), to: page)
            self.onMarkupChange?()
            self.pdfView.setNeedsDisplay(self.pdfView.bounds)
        }
        sv.onDoubleClick = { [weak self, weak a] in if let a { self?.beginEditing(a) } }
        sv.onDelete = { [weak self] in self?.deleteSelectedAnnotation() ?? false }
        pdfView.addSubview(sv, positioned: .below, relativeTo: textStyleBar.view)
        selectionView = sv
        ensureSelectionScrollObserved()                           // so scrolling re-anchors the chrome to the box
    }

    private func removeSelectionChrome() {
        selectionView?.removeFromSuperview()
        selectionView = nil
    }

    /// Keep the chrome aligned with the box (during a single-gesture move).
    private func repositionSelectionChrome() {
        guard let box = selectedTextAnnotation, let page = box.page, let sv = selectionView else { return }
        sv.frame = pdfView.convert(box.bounds, from: page).insetBy(dx: -TextBoxSelectionView.inset, dy: -TextBoxSelectionView.inset)
    }

    /// Inline editing via an NSTextView overlay (PDFKit's own freeText inline editing is unreliable; an overlay
    /// guarantees "click → type"). The handles are hidden while typing; the baked text is hidden behind it.
    private func beginEditing(_ a: PDFAnnotation) {
        finishEditing()
        removeSelectionChrome()
        guard let page = a.page else { return }
        let rectInView = pdfView.convert(a.bounds, from: page)
        let scale = max(pdfView.scaleFactor, 0.0001)
        let tv = NSTextView(frame: rectInView)
        tv.string = a.contents ?? ""
        tv.font = overlayFont(for: a)                              // page-pt font × zoom → matches the baked text
        tv.textColor = a.fontColor ?? .systemRed
        tv.alignment = a.alignment
        tv.isRichText = false
        tv.drawsBackground = false                                // edit IN PLACE (no white field — Preview-style)
        tv.textContainerInset = NSSize(width: 2 * scale, height: 2 * scale)
        tv.textContainer?.lineFragmentPadding = 0
        tv.delegate = self
        tv.wantsLayer = true
        tv.layer?.borderWidth = 1                                  // thin accent outline = the editing affordance
        tv.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        a.contents = ""                                            // hide the baked text behind the overlay
        pdfView.addSubview(tv, positioned: .below, relativeTo: textStyleBar.view)
        pdfView.window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        editingOverlay = tv
        editingAnnotation = a
        showTextStyleBar(for: a)
    }

    /// The overlay must render at the SAME on-screen size as the baked freeText, which PDFKit draws at the
    /// annotation's page-space point size scaled by the current zoom. So scale the font by `scaleFactor`.
    private func overlayFont(for a: PDFAnnotation) -> NSFont {
        let base = a.font ?? NSFont(name: "Helvetica", size: 17)!
        let size = base.pointSize * max(pdfView.scaleFactor, 0.0001)
        return NSFont(descriptor: base.fontDescriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    /// Commit the overlay's text into the annotation and tear it down. `reselect` re-shows the chrome (after a
    /// Return/Esc commit — the box stays selected); it's left off when the user clicked away (then a deselect
    /// follows). Safe to call when idle.
    private func finishEditing(reselect: Bool = false) {
        guard let tv = editingOverlay, let a = editingAnnotation else { return }
        editingOverlay = nil; editingAnnotation = nil             // clear first → no re-entry from textDidEndEditing
        a.contents = tv.string.isEmpty ? "Text" : tv.string
        tv.removeFromSuperview()
        onMarkupChange?()
        if let page = a.page { pdfView.setNeedsDisplay(pdfView.convert(a.bounds, from: page)) }
        if reselect, selectedTextAnnotation === a { showSelectionChrome(for: a) }
    }

    /// Mirror an annotation's font/color/alignment onto the live editing overlay (called when the style bar edits).
    private func syncOverlay(_ tv: NSTextView, to a: PDFAnnotation) {
        guard editingAnnotation === a else { return }
        tv.font = overlayFont(for: a)                              // keep the zoom-scaled size in sync
        tv.textColor = a.fontColor
        tv.alignment = a.alignment
    }

    private func showTextStyleBar(for a: PDFAnnotation) {
        textStyleBar.present(for: a)
        textStyleBar.view.isHidden = false
    }

    private func hideTextStyleBar() {
        textStyleBar.view.isHidden = true
        textStyleBar.clearAnnotation()
    }

    // NSTextViewDelegate — overlay editor: plain Return commits (stays selected), Shift+Return = newline,
    // Esc commits; focus loss commits (the box then deselects via the click-away).
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === editingOverlay else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            finishEditing(reselect: true); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishEditing(reselect: true); return true }
        return false
    }

    func textDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSTextView) === editingOverlay { finishEditing(reselect: false) }
    }

    // MARK: – Outline / search-result page grouping (for the left sidebar)

    /// Flattened table-of-contents items with indentation depth.
    var outlineItems: [(depth: Int, outline: PDFOutline)] {
        guard let root = pdfView.document?.outlineRoot else { return [] }
        var out: [(Int, PDFOutline)] = []
        func walk(_ o: PDFOutline, _ depth: Int) {
            for i in 0..<o.numberOfChildren {
                if let child = o.child(at: i) { out.append((depth, child)); walk(child, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }

    func go(to outline: PDFOutline) { if let dest = outline.destination { pdfView.go(to: dest) } }

    /// Search matches grouped by page (for a scannable results list): (pageIndex, [matchIndices]).
    var searchGroups: [(page: Int, matchIndices: [Int])] {
        guard let doc = pdfView.document else { return [] }
        var byPage: [Int: [Int]] = [:]
        var order: [Int] = []
        for (i, sel) in matches.enumerated() {
            guard let page = sel.pages.first else { continue }
            let p = doc.index(for: page)
            if byPage[p] == nil { order.append(p) }
            byPage[p, default: []].append(i)
        }
        return order.sorted().map { (page: $0, matchIndices: byPage[$0]!) }
    }

    func previewText(forMatch i: Int) -> String {
        guard matches.indices.contains(i), let ctx = matches[i].copy() as? PDFSelection else { return "" }
        ctx.extend(atStart: 30); ctx.extend(atEnd: 30)
        return (ctx.string ?? matches[i].string ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
