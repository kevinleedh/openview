import AppKit
import PDFKit

/// Horizontal text-style bar for the selected freeText box (Apple Preview-style): Font · Size · B/I/U · Color ·
/// Alignment. Hosted as a TOP bar under the toolbar (like the search-results bar), shown while a text box is
/// selected. Each control mutates the annotation in place and calls `onChange` for redraw + dirty. New symbol;
/// the AI / grounding path is untouched.
final class TextStyleBarController: NSViewController {

    /// Called after any control edits the annotation → redraw + updateChangeCount.
    var onChange: ((PDFAnnotation) -> Void)?
    /// Underline can't be baked into a PDFKit freeText (no per-run attributes), so it's applied to the live
    /// editing overlay only — the controller forwards the toggle here.
    var onUnderlineChange: ((Bool) -> Void)?

    private weak var annotation: PDFAnnotation?

    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let biuSegment = NSSegmentedControl()
    private let colorWell = NSColorWell()
    private let alignSegment = NSSegmentedControl()

    // A short curated list that resolves on macOS (avoids names NSFont(name:) can't build).
    private static let fontFamilies = ["Helvetica", "Helvetica Neue", "Arial", "Times New Roman", "Courier New", "Menlo"]

    override func loadView() {
        fontPopup.addItems(withTitles: Self.fontFamilies)
        fontPopup.target = self; fontPopup.action = #selector(applyFont)
        fontPopup.controlSize = .small
        fontPopup.widthAnchor.constraint(equalToConstant: 132).isActive = true

        sizeField.stringValue = "17"
        sizeField.controlSize = .small
        sizeField.alignment = .right
        sizeField.target = self; sizeField.action = #selector(applySize)
        sizeField.widthAnchor.constraint(equalToConstant: 38).isActive = true
        sizeStepper.minValue = 6; sizeStepper.maxValue = 144; sizeStepper.increment = 1; sizeStepper.doubleValue = 17
        sizeStepper.target = self; sizeStepper.action = #selector(stepSize)
        sizeStepper.controlSize = .small

        biuSegment.segmentCount = 3
        biuSegment.trackingMode = .selectAny                      // B / I / U toggle independently
        biuSegment.segmentStyle = .texturedRounded
        for (i, name) in ["bold", "italic", "underline"].enumerated() {
            biuSegment.setImage(NSImage(systemSymbolName: name, accessibilityDescription: name), forSegment: i)
            biuSegment.setWidth(26, forSegment: i)
        }
        biuSegment.target = self; biuSegment.action = #selector(applyTraits)

        colorWell.target = self; colorWell.action = #selector(applyColor)
        colorWell.widthAnchor.constraint(equalToConstant: 36).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 20).isActive = true

        alignSegment.segmentCount = 4
        alignSegment.trackingMode = .selectOne
        alignSegment.segmentStyle = .texturedRounded
        for (i, name) in ["text.alignleft", "text.aligncenter", "text.alignright", "text.justify"].enumerated() {
            alignSegment.setImage(NSImage(systemSymbolName: name, accessibilityDescription: name), forSegment: i)
            alignSegment.setWidth(26, forSegment: i)
        }
        alignSegment.selectedSegment = 0
        alignSegment.target = self; alignSegment.action = #selector(applyAlignment)

        let sizeGroup = NSStackView(views: [sizeField, sizeStepper])
        sizeGroup.spacing = 2; sizeGroup.alignment = .centerY
        let row = NSStackView(views: [fontPopup, sizeGroup, biuSegment, colorWell, alignSegment])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        // Toolbar-style translucent bar with a hairline bottom separator (matches the search-results bar).
        let bar = NSVisualEffectView()
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.addSubview(row)
        let sep = NSBox(); sep.boxType = .separator; sep.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(sep)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: bar.topAnchor, constant: 5),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bar.bottomAnchor, constant: -5),
            sep.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        view = bar
    }

    /// Bind the bar to a freeText box (reflect its current attributes into the controls).
    func present(for a: PDFAnnotation) {
        loadViewIfNeeded()
        annotation = a
        syncControls(from: a)
    }

    func clearAnnotation() { annotation = nil }

    // MARK: – Reflect the annotation's current attributes into the controls.

    private func syncControls(from a: PDFAnnotation) {
        let font = a.font ?? NSFont(name: "Helvetica", size: 17)!
        let family = font.familyName ?? "Helvetica"
        if fontPopup.itemTitles.contains(family) { fontPopup.selectItem(withTitle: family) }
        sizeField.stringValue = String(Int(font.pointSize.rounded()))
        sizeStepper.doubleValue = Double(font.pointSize)
        let traits = NSFontManager.shared.traits(of: font)
        biuSegment.setSelected(traits.contains(.boldFontMask), forSegment: 0)
        biuSegment.setSelected(traits.contains(.italicFontMask), forSegment: 1)
        biuSegment.setSelected(false, forSegment: 2)
        colorWell.color = a.fontColor ?? .systemRed
        switch a.alignment {
        case .center:    alignSegment.selectedSegment = 1
        case .right:     alignSegment.selectedSegment = 2
        case .justified: alignSegment.selectedSegment = 3
        default:         alignSegment.selectedSegment = 0
        }
    }

    // MARK: – Actions (mutate the annotation, then notify).

    @objc private func applyFont()  { rebuildFont() }
    @objc private func applyTraits() {
        rebuildFont()
        onUnderlineChange?(biuSegment.isSelected(forSegment: 2))      // U → editing overlay only (bake limitation)
    }
    @objc private func applySize()  { sizeStepper.doubleValue = sizeField.doubleValue; rebuildFont() }
    @objc private func stepSize()   { sizeField.stringValue = String(Int(sizeStepper.doubleValue)); rebuildFont() }

    private func rebuildFont() {
        guard let a = annotation else { return }
        let family = fontPopup.titleOfSelectedItem ?? "Helvetica"
        let size = CGFloat(max(6, sizeField.doubleValue == 0 ? 17 : sizeField.doubleValue))
        let fm = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if biuSegment.isSelected(forSegment: 0) { traits.insert(.boldFontMask) }
        if biuSegment.isSelected(forSegment: 1) { traits.insert(.italicFontMask) }
        let font = fm.font(withFamily: family, traits: traits, weight: traits.contains(.boldFontMask) ? 9 : 5, size: size)
            ?? NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size)
        a.font = font
        onChange?(a)
    }

    @objc private func applyColor() {
        guard let a = annotation else { return }
        a.fontColor = colorWell.color
        onChange?(a)
    }

    @objc private func applyAlignment() {
        guard let a = annotation else { return }
        switch alignSegment.selectedSegment {
        case 1:  a.alignment = .center
        case 2:  a.alignment = .right
        case 3:  a.alignment = .justified
        default: a.alignment = .left
        }
        onChange?(a)
    }
}

/// Selection chrome over a freeText box: an accent border + two side handles. Drag the body to MOVE, a side
/// handle to RESIZE width; double-click edits; Delete removes. Lives as a subview of the PDFView at the box's
/// view-space frame (expanded by `inset` so the handles sit just outside the text). New symbol.
final class TextBoxSelectionView: NSView {

    static let inset: CGFloat = 6                       // how far the chrome extends beyond the text rect
    var onGeometryChange: (() -> Void)?                // frame moved/resized → caller writes annotation.bounds
    var onDoubleClick: (() -> Void)?
    var onDelete: (() -> Bool)?

    private let r: CGFloat = 5                          // handle radius
    private enum Mode { case none, move, left, right }
    private var mode: Mode = .none
    private var startMouse: NSPoint = .zero
    private var startFrame: NSRect = .zero

    override var isFlipped: Bool { false }              // match the non-flipped PDFView
    override var acceptsFirstResponder: Bool { true }   // receive Delete

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: box); border.lineWidth = 1; border.stroke()
        for c in [leftHandle, rightHandle] {
            let dot = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            NSColor.controlAccentColor.setFill(); dot.fill()
            NSColor.white.setStroke(); dot.lineWidth = 1; dot.stroke()
        }
    }

    private var leftHandle: NSPoint  { NSPoint(x: Self.inset, y: bounds.midY) }
    private var rightHandle: NSPoint { NSPoint(x: bounds.maxX - Self.inset, y: bounds.midY) }
    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: r * 2, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.maxX - r * 2, y: 0, width: r * 2, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(bounds.insetBy(dx: r * 2, dy: 0), cursor: .openHand)
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { onDoubleClick?(); return }
        let p = convert(e.locationInWindow, from: nil)
        startMouse = e.locationInWindow
        startFrame = frame
        if hypot(p.x - leftHandle.x, p.y - leftHandle.y) <= r * 2 { mode = .left }
        else if hypot(p.x - rightHandle.x, p.y - rightHandle.y) <= r * 2 { mode = .right }
        else { mode = .move }
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with e: NSEvent) {
        guard mode != .none else { return }
        let dx = e.locationInWindow.x - startMouse.x
        let dy = e.locationInWindow.y - startMouse.y
        var f = startFrame
        switch mode {
        case .move:  f.origin.x += dx; f.origin.y += dy
        case .left:  let w = max(40, startFrame.width - dx); f.origin.x = startFrame.maxX - w; f.size.width = w
        case .right: f.size.width = max(40, startFrame.width + dx)
        case .none:  break
        }
        frame = f
        window?.invalidateCursorRects(for: self)
        onGeometryChange?()
    }

    override func mouseUp(with e: NSEvent) { mode = .none; onGeometryChange?() }

    override func keyDown(with e: NSEvent) {
        if (e.keyCode == 51 || e.keyCode == 117), onDelete?() == true { return }   // delete / forward-delete
        super.keyDown(with: e)
    }
}
