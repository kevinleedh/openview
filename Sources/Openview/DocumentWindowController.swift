import AppKit
import PDFKit

/// Owns the document window (programmatic — no nib): the 2-pane split layout as contentViewController,
/// plus the viewing toolbar. The toolbar is PURE system AppKit — `NSToolbarItem` / `NSToolbarItemGroup`
/// / `NSSearchToolbarItem` / `NSSharingServicePickerToolbarItem` — so macOS renders the Liquid Glass
/// pills automatically and each segment/control IS the hit target. No custom glass is drawn and no
/// buttons are layered on a pill (that was the prior bug). Viewing-only: no markup/edit tools (CLAUDE.md).
///
/// Liquid Glass grouping (WWDC25 "Build an AppKit app with the new design", session 310): NSToolbar puts
/// glass behind items automatically; AppKit groups adjacent bordered buttons onto one glass pill;
/// segmented controls / search / sharing items get their own glass element; `isBordered = false` removes
/// glass (used for non-interactive content). We do not hand-draw any of it.
final class DocumentWindowController: NSWindowController {

    private var splitVC: MainSplitViewController { contentViewController as! MainSplitViewController }
    private var engine: DocumentEngine?
    private var searchItem: NSSearchToolbarItem?
    private var zoomOutItem: NSToolbarItem?
    private var zoomActualItem: NSToolbarItem?
    private var zoomInItem: NSToolbarItem?
    private weak var sidebarMenu: NSMenu?
    private weak var markupSegment: NSSegmentedControl?   // highlighter | chevron-menu (Preview-style pill)
    private weak var markupMenu: NSMenu?                 // color + style menu (checkmarks via menuNeedsUpdate)

    // The view-options sidebar radio group — always exactly one selected. Search results are a transient
    // overlay that shares the slot but does NOT change this selection (Done restores the selected panel).
    private enum SidebarSelection { case hidden, thumbnails, toc, highlights, bookmarks, contactSheet }
    private var sidebarSelection: SidebarSelection = .hidden   // sidebar starts collapsed → Hide Sidebar ✓

    // A SECOND, independent radio group: the page display mode. Continuous is the verified default.
    private enum DisplayModeSelection { case continuous, single, twoPages }
    private var displayModeSelection: DisplayModeSelection = .continuous

    private enum ItemID {
        static let sidebar  = NSToolbarItem.Identifier("sidebar")
        // Zoom is THREE separate bordered buttons (not one NSToolbarItemGroup): AppKit auto-groups adjacent
        // bordered items onto one glass pill (so it still looks like Preview's −/1/+), but separate items
        // overflow CLEANLY into the » menu when the window narrows — a group instead collapses into a janky
        // chevron-pulldown (the "zoom looks weird when small" bug).
        static let zoomOut    = NSToolbarItem.Identifier("zoomOut")
        static let zoomActual = NSToolbarItem.Identifier("zoomActual")
        static let zoomIn     = NSToolbarItem.Identifier("zoomIn")
        static let rotate   = NSToolbarItem.Identifier("rotate")
        static let markup   = NSToolbarItem.Identifier("markup")
        static let text     = NSToolbarItem.Identifier("text")
        static let info     = NSToolbarItem.Identifier("info")
        static let share    = NSToolbarItem.Identifier("share")
        static let search   = NSToolbarItem.Identifier("search")
        static let aiToggle = NSToolbarItem.Identifier("aiToggle")
    }

    convenience init() {
        // Open at a MEDIUM size relative to the screen (not tiny, not full-screen). Capped so it stays "medium"
        // on large displays and shrinks to fit small laptops. Only the DEFAULT — the autosaved frame (below)
        // takes over once the user resizes.
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(1180, visible.width * 0.76)
        let h = min(820, visible.height * 0.86)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.minSize = NSSize(width: 760, height: 520)
        window.title = "Openview"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        // Opt OUT of macOS window state restoration: it reopens EVERY window that was open at quit, which
        // breaks the single-active-document invariant (v0). The "reopen last PDF" feature (F1) is provided
        // explicitly by AppDelegate via recentDocumentURLs — a SINGLE document — not by this OS mechanism.
        window.isRestorable = false
        window.toolbarStyle = .unified                 // title + glass toolbar share the titlebar (Preview-style)

        self.init(window: window)
        contentViewController = MainSplitViewController()
        splitVC.pdf.delegate = self
        splitVC.sidebar.onDone = { [weak self] in self?.endSearch() }   // search-results "Done" → restore panel

        let toolbar = NSToolbar(identifier: "OpenviewViewingToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        // Setting `contentViewController` above resized the window DOWN to the split view's small fitting size
        // (more so now that the AI panel is collapsed by default), which `center()` would then preserve and
        // autosave as "small". Restore the intended MEDIUM content size here, after the content view is in place;
        // the autosaved frame (if any) overrides it below.
        window.setContentSize(NSSize(width: w, height: h))

        // Bumped to .v3 so a stale (tiny) saved frame from earlier builds is dropped once → reopens at the
        // medium default above, then persists the user's choice from there.
        let autosaveName = "OpenviewDocumentWindow.v3"
        // Only a *visible* sibling window counts as occupying the saved frame — otherwise a second open
        // would cascade off a closed window's stale name. (close() frees the window; the check must look
        // at what's actually on screen, not every window AppKit still tracks.)
        let nameTaken = NSApp.windows.contains { $0.isVisible && $0.frameAutosaveName == autosaveName }
        if nameTaken {
            window.cascadeTopLeft(from: NSPoint(x: 40, y: 40))
        } else {
            if !window.setFrameUsingName(autosaveName) { window.center() }
            window.setFrameAutosaveName(autosaveName)
        }
        // A frame restored onto a since-disconnected display would strand the window off-screen (looks
        // like "the app won't open"). If it doesn't intersect any current screen, recenter.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.center()
        }
    }

    /// Load a parsed PDF into the viewer, title the window (title + proxy icon via representedURL), and
    /// start the grounding engine. The "Page n of N" subtitle is bound live by the PDFViewController delegate.
    func loadDocument(_ document: PDFDocument?, fileURL: URL? = nil, chat: [ChatTurn] = []) {
        splitVC.pdf.load(document)
        splitVC.sidebar.refresh()

        // Markup ↔ document wiring: each markup edit marks the PDF dirty (⌘S persists it); the pen button
        // reflects highlighter mode; transient citation highlights are stripped just before serialization.
        splitVC.pdf.onMarkupChange = { [weak self] in (self?.document as? NSDocument)?.updateChangeCount(.changeDone) }
        splitVC.pdf.onToolChange = { [weak self] tool in self?.updateToolButtons(tool) }
        (self.document as? OpenviewDocument)?.prepareForSave = { [weak self] in self?.splitVC.pdf.prepareForSave() }

        // Chat ↔ document wiring: a completed Q&A marks the doc dirty (so ⌘S / the close prompt persists it),
        // the document queries the panel for the chat to save, and any previously-saved chat is re-rendered now.
        splitVC.ai.onChatChanged = { [weak self] in (self?.document as? NSDocument)?.updateChangeCount(.changeDone) }
        (self.document as? OpenviewDocument)?.currentChat = { [weak self] in self?.splitVC.ai.currentChat() ?? [] }
        splitVC.ai.restoreChat(chat)
        // Prefer the NSDocument's fileURL. A PDF on a removable/external volume is loaded via
        // PDFDocument(data:) (the SIGBUS crash-fix), so its `documentURL` is NIL — relying on that would skip
        // engine creation and leave ALL AI features (Q&A) dead for every external-drive PDF.
        // `fileURL` is always present once the document is opened; documentURL is the fallback.
        if let url = fileURL ?? document?.documentURL {
            window?.title = url.deletingPathExtension().lastPathComponent
            window?.representedURL = url               // proxy icon + title menu (NSDocument default machinery)
            let engine = DocumentEngine(pdf: splitVC.pdf, ai: splitVC.ai)
            self.engine = engine
            engine.start(pdfURL: url)
        }
    }

    /// The source volume vanished (external SSD ejected). Drop the engine and the possibly memory-mapped
    /// PDFDocument so no later page fault can SIGBUS on an unmapped vnode; the window stays open empty.
    func releaseForVolumeLoss() {
        engine = nil
        splitVC.pdf.clear()
        splitVC.sidebar.refresh()
        window?.subtitle = ""
    }

    // MARK: – Menu / toolbar actions (reached via the responder chain)

    @objc func hideSidebar(_ sender: Any?)         { selectSidebar(.hidden) }
    @objc func showThumbnails(_ sender: Any?)      { selectSidebar(.thumbnails) }
    @objc func showTableOfContents(_ sender: Any?) { selectSidebar(.toc) }
    @objc func showHighlights(_ sender: Any?)      { selectSidebar(.highlights) }
    @objc func showBookmarks(_ sender: Any?)       { selectSidebar(.bookmarks) }
    @objc func showContactSheet(_ sender: Any?)    { selectSidebar(.contactSheet) }

    /// Apply a radio selection: collapse for .hidden, otherwise show the matching panel in the left slot.
    private func selectSidebar(_ selection: SidebarSelection) {
        sidebarSelection = selection
        switch selection {
        case .hidden:       splitVC.hideSidebar()
        case .thumbnails:   splitVC.showSidebar(.thumbnails)
        case .toc:          splitVC.showSidebar(.toc)
        case .highlights:   splitVC.showSidebar(.highlights)
        case .bookmarks:    splitVC.showSidebar(.bookmarks)
        case .contactSheet: splitVC.showSidebar(.contactSheet)
        }
    }

    @objc func setContinuousScroll(_ sender: Any?) { selectDisplayMode(.continuous) }
    @objc func setSinglePage(_ sender: Any?)       { selectDisplayMode(.single) }
    @objc func setTwoPages(_ sender: Any?)         { selectDisplayMode(.twoPages) }

    /// Apply a page display mode. ⚠️ Reverses CLAUDE.md's continuous-only decision: the non-continuous
    /// paged modes (.singlePage/.twoUp) re-expose PDFKit's baked-in snapping — needs a hands-on feel check.
    private func selectDisplayMode(_ selection: DisplayModeSelection) {
        displayModeSelection = selection
        switch selection {
        case .continuous: splitVC.pdf.setDisplayMode(.singlePageContinuous)   // verified default — no regression
        case .single:     splitVC.pdf.setDisplayMode(.singlePage)
        case .twoPages:   splitVC.pdf.setDisplayMode(.twoUp)                   // NOT .twoUpContinuous (paged)
        }
    }
    @objc func zoomIn(_ sender: Any?)              { splitVC.pdf.zoomIn() }
    @objc func zoomOut(_ sender: Any?)             { splitVC.pdf.zoomOut() }
    @objc func actualSize(_ sender: Any?)          { splitVC.pdf.actualSize() }
    @objc func toggleAIPanel(_ sender: Any?)       { splitVC.toggleAIPanel() }
    @objc func rotateDocument(_ sender: Any?)      { splitVC.pdf.rotateLeft() }

    // Markup (Preview-style). Pen segment toggles drag-to-highlight; T toggles the text-box tool; the chevron
    // menu sets color/style and applies to a live selection.
    @objc func toggleHighlighter(_ sender: Any?)   { splitVC.pdf.toggleHighlighterMode() }
    @objc func insertTextBox(_ sender: Any?)       { splitVC.pdf.insertTextBoxInView() }
    @objc private func markupSegmentClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            splitVC.pdf.toggleHighlighterMode()
        } else if sender.selectedSegment == 1, let menu = markupMenu {
            menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.maxX - 24, y: sender.bounds.maxY + 4), in: sender)
        }
    }
    /// Reflect the active tool on the toolbar: tint the highlighter segment when on. (T inserts directly — it's
    /// a momentary button, no persistent state.)
    private func updateToolButtons(_ tool: MarkupTool) {
        let cfg = NSImage.SymbolConfiguration(paletteColors: [tool == .highlighter ? .controlAccentColor : .labelColor])
        markupSegment?.setImage(safeSymbol("highlighter", "pencil.tip", "Highlight").withSymbolConfiguration(cfg), forSegment: 0)
    }
    @objc func pickMarkupColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        splitVC.pdf.setMarkupColor(color)
    }
    @objc func setMarkupHighlightStyle(_ sender: Any?)     { splitVC.pdf.setMarkupType(.highlight) }
    @objc func setMarkupUnderlineStyle(_ sender: Any?)     { splitVC.pdf.setMarkupType(.underline) }
    @objc func setMarkupStrikethroughStyle(_ sender: Any?) { splitVC.pdf.setMarkupType(.strikethrough) }


    @objc func showInfo(_ sender: Any?) {
        guard let doc = splitVC.pdf.pdfView.document else { return }
        let size = doc.page(at: 0)?.bounds(for: .mediaBox).size
        let alert = NSAlert()
        alert.messageText = window?.title ?? "Document"
        var lines = ["\(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s")"]
        if let size { lines.append(String(format: "Page size: %.0f × %.0f pt", size.width, size.height)) }
        if let url = doc.documentURL { lines.append(url.path) }
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc func performFind(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
        if let field = searchItem?.searchField { window?.makeFirstResponder(field) }
    }

    // Return in the search field advances to the next match (re-runs the search only if nothing found yet).
    @objc private func searchEnter(_ sender: NSSearchField) {
        if splitVC.pdf.matches.isEmpty { searchFieldChanged(sender) } else { splitVC.pdf.searchNext() }
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        let text = sender.stringValue
        splitVC.sidebar.setSearchTerm(text)         // for snippet highlighting in the results list
        _ = splitVC.pdf.search(text)
        splitVC.sidebar.refresh()
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            splitVC.showSidebar(.searchResults)     // transient overlay — does NOT change the radio selection
        } else {
            selectSidebar(sidebarSelection)         // cleared → restore the selected panel (or collapse)
        }
    }

    /// "Done" in the search-results list: clear the query, drop highlights, restore the selected panel.
    private func endSearch() {
        searchItem?.searchField.stringValue = ""
        splitVC.sidebar.setSearchTerm("")
        splitVC.pdf.closeSearch()
        splitVC.sidebar.refresh()
        selectSidebar(sidebarSelection)
    }

    private func safeSymbol(_ name: String, _ fallback: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: description)
            ?? NSImage()
    }
}

// MARK: – PDFViewController delegate (live, no re-render in the scroll path)

extension DocumentWindowController: PDFViewControllerDelegate {
    func pdfViewControllerDidUpdatePageLabel(_ vc: PDFViewController, label: String) {
        window?.subtitle = label                              // "Page n of N" under the title (Preview-style)
    }
    func pdfViewControllerDidUpdateZoom(_ vc: PDFViewController, percent: Int) {
        // No numeric readout (Preview's zoom group is icon-only); just refresh the segment enabled states.
        updateZoomSegments()
    }
    func pdfViewControllerDidUpdateSearch(_ vc: PDFViewController, count: Int, position: String) {
        searchItem?.searchField.placeholderString = count == 0 ? "Search" : position
    }
}

// MARK: – NSToolbar (pure system items → automatic Liquid Glass)

extension DocumentWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The sidebar item sits BEFORE .sidebarTrackingSeparator → AppKit places it in the sidebar's
        // titlebar area (leading, before the title), exactly as Preview/Finder/Mail do. The title and
        // the rest of the controls render after the separator (the content area).
        // Preview-style: controls LEFT-aligned after the title, then a flexible gap, then search + AI on the
        // right. When the window narrows, the trailing controls collapse into the standard » overflow menu
        // (instead of being pushed off / the zoom group self-collapsing). The zoom trio is adjacent (one pill);
        // a `.space` separates it from rotate.
        [ItemID.sidebar, .sidebarTrackingSeparator,
         ItemID.zoomOut, ItemID.zoomActual, ItemID.zoomIn, .space, ItemID.rotate, .space,
         ItemID.markup, ItemID.text, .space, ItemID.info, ItemID.share,
         .flexibleSpace, ItemID.search, ItemID.aiToggle]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.sidebar, .sidebarTrackingSeparator, ItemID.zoomOut, ItemID.zoomActual, ItemID.zoomIn,
         ItemID.rotate, ItemID.markup, ItemID.text, ItemID.info, ItemID.share, ItemID.search, ItemID.aiToggle,
         .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ItemID.sidebar:  return makeSidebarItem()
        case ItemID.zoomOut:    return makeZoomButton(ItemID.zoomOut, "minus.magnifyingglass", "minus",
                                                      "Zoom Out", #selector(zoomOut(_:)))
        case ItemID.zoomActual: return makeZoomButton(ItemID.zoomActual, "1.magnifyingglass", "magnifyingglass",
                                                      "Actual Size", #selector(actualSize(_:)))
        case ItemID.zoomIn:     return makeZoomButton(ItemID.zoomIn, "plus.magnifyingglass", "plus",
                                                      "Zoom In", #selector(zoomIn(_:)))
        case ItemID.rotate:   return makeButton(ItemID.rotate, "rotate.left", "arrow.counterclockwise",
                                                "Rotate Left", #selector(rotateDocument(_:)))
        case ItemID.markup:      return makeMarkupItem()
        case ItemID.text:        return makeTextItem()
        case ItemID.info:     return makeButton(ItemID.info, "info", "info.circle",
                                                "Get Info", #selector(showInfo(_:)))
        case ItemID.share:    return makeShareItem()
        case ItemID.search:   return makeSearchItem()
        // Official Apple Intelligence SF Symbol (macOS 26+); `safeSymbol` falls back to "sparkles" where it's
        // absent, so the button is never blank. NOT a hand-drawn glow image — the system symbol or sparkles.
        case ItemID.aiToggle: return makeButton(ItemID.aiToggle, "apple.intelligence", "sparkles",
                                                "AI Panel", #selector(toggleAIPanel(_:)))
        default:              return nil
        }
    }

    // Sidebar / view-options: a pull-down (icon + chevron) glass pill — the system NSMenuToolbarItem.
    private func makeSidebarItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: ItemID.sidebar)
        item.label = "View"
        item.image = safeSymbol("sidebar.left", "sidebar.leading", "View options")
        let menu = NSMenu()
        menu.delegate = self                                  // → menuNeedsUpdate keeps exactly one ✓
        // A mutually-exclusive radio group (Preview's sidebar menu). Order MUST match `radioOrder` below.
        menu.addItem(withTitle: "Hide Sidebar", action: #selector(hideSidebar(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Thumbnails", action: #selector(showThumbnails(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Table of Contents", action: #selector(showTableOfContents(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Highlights and Notes", action: #selector(showHighlights(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Bookmarks", action: #selector(showBookmarks(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Contact Sheet", action: #selector(showContactSheet(_:)), keyEquivalent: "")
        // Second radio group — page display mode (independent of the sidebar group above).
        menu.addItem(.separator())
        menu.addItem(withTitle: "Continuous Scroll", action: #selector(setContinuousScroll(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Single Page", action: #selector(setSinglePage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Two Pages", action: #selector(setTwoPages(_:)), keyEquivalent: "")
        for mi in menu.items { mi.target = self }
        item.menu = menu
        sidebarMenu = menu
        return item
    }

    // Zoom: three separate bordered buttons (out · actual size · in). Adjacent bordered items auto-group onto
    // one glass pill (Preview's −/1/+ look), but as SEPARATE items they overflow cleanly into the » menu when
    // the window narrows — an NSToolbarItemGroup instead collapses into a janky chevron-pulldown. We drive each
    // button's enabled state ourselves, so autovalidation is off (it would otherwise keep them all enabled).
    private func makeZoomButton(_ id: NSToolbarItem.Identifier, _ symbol: String, _ fallback: String,
                                _ label: String, _ action: Selector) -> NSToolbarItem {
        let item = makeButton(id, symbol, fallback, label, action)
        item.autovalidates = false
        switch id {
        case ItemID.zoomOut:    zoomOutItem = item
        case ItemID.zoomActual: zoomActualItem = item
        case ItemID.zoomIn:     zoomInItem = item
        default: break
        }
        updateZoomSegments()
        return item
    }

    /// Enable/disable the zoom buttons to mirror Preview: actual-size off at 100%, zoom out off at the
    /// minimum scale, zoom in off at the maximum scale.
    private func updateZoomSegments() {
        let view = splitVC.pdf.pdfView
        let scale = view.scaleFactor
        zoomOutItem?.isEnabled    = scale > view.minScaleFactor + 0.001
        zoomActualItem?.isEnabled = abs(scale - 1.0) > 0.001
        zoomInItem?.isEnabled     = scale < view.maxScaleFactor - 0.001
    }

    // Single glass button: system-rendered (image + action + isBordered). AppKit auto-groups adjacent
    // bordered buttons onto one pill; the `.space` between rotate and info keeps rotate its own pill.
    private func makeButton(_ id: NSToolbarItem.Identifier, _ symbol: String, _ fallback: String,
                            _ label: String, _ action: Selector,
                            config: NSImage.SymbolConfiguration? = nil) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        var image = safeSymbol(symbol, fallback, label)
        if let config { image = image.withSymbolConfiguration(config) ?? image }
        item.image = image
        item.label = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.isBordered = true                          // → system glass; the item is the hit target
        return item
    }

    // Markup: ONE Preview-style pill — segment 0 = highlighter (toggles the tool), segment 1 = chevron that
    // drops the color & style menu. Replaces the old separate pen button + palette drop-down.
    private func makeMarkupItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.markup)
        let seg = NSSegmentedControl()
        seg.segmentCount = 2
        seg.trackingMode = .momentary
        seg.segmentStyle = .rounded
        seg.setImage(safeSymbol("highlighter", "pencil.tip", "Highlight"), forSegment: 0)
        let chevron = safeSymbol("chevron.down", "chevron.down", "Color & style")
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        seg.setImage(chevron, forSegment: 1)
        seg.setWidth(34, forSegment: 0)
        seg.setWidth(22, forSegment: 1)
        seg.setMenu(colorStyleMenu(), forSegment: 1)    // chevron click → pull-down menu
        seg.target = self
        seg.action = #selector(markupSegmentClicked(_:))
        markupSegment = seg
        item.view = seg
        item.label = "Highlight"
        item.toolTip = "Highlight (drag over text). Arrow → color & style."
        return item
    }

    // T (text box): a momentary button — drops a text box in the centre of the visible area and edits it.
    private func makeTextItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.text)
        item.image = safeSymbol("character.textbox", "textformat", "Text")
        item.label = "Text"
        item.toolTip = "Text — add a text box in view"
        item.target = self
        item.action = #selector(insertTextBox(_:))
        item.isBordered = true
        return item
    }

    // Color (5 swatches) + style (Highlight / Underline / Strikethrough). Each applies to a live selection.
    // Checkmarks for the active color/style are kept in menuNeedsUpdate.
    private func colorStyleMenu() -> NSMenu {
        let menu = NSMenu()
        for swatch in MarkupPalette.swatches {
            let mi = NSMenuItem(title: swatch.name, action: #selector(pickMarkupColor(_:)), keyEquivalent: "")
            mi.target = self
            mi.image = Self.swatchImage(swatch.color)
            mi.representedObject = swatch.color
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        for (title, action) in [("Highlight", #selector(setMarkupHighlightStyle(_:))),
                                ("Underline", #selector(setMarkupUnderlineStyle(_:))),
                                ("Strikethrough", #selector(setMarkupStrikethroughStyle(_:)))] {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        menu.delegate = self
        markupMenu = menu
        return menu
    }

    /// A small rounded color chip for the markup color menu items.
    private static func swatchImage(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3, yRadius: 3).fill()
        image.unlockFocus()
        return image
    }

    private func makeShareItem() -> NSToolbarItem {
        let item = NSSharingServicePickerToolbarItem(itemIdentifier: ItemID.share)   // native share + glass
        item.toolTip = "Share"
        item.delegate = self
        return item
    }

    private func makeSearchItem() -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: ItemID.search)
        item.searchField.target = self
        item.searchField.action = #selector(searchEnter(_:))      // Return → next match
        item.searchField.sendsWholeSearchString = false
        item.searchField.sendsSearchStringImmediately = false
        item.searchField.delegate = self                          // live search as you type
        searchItem = item
        return item
    }
}

// MARK: – Native share

extension DocumentWindowController: NSSharingServicePickerToolbarItemDelegate {
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        window?.representedURL.map { [$0] } ?? []
    }
}

// MARK: – Live search (highlight as you type)

extension DocumentWindowController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        searchFieldChanged(field)
    }
}

// MARK: – View-options radio state (exactly one ✓, always)

extension DocumentWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === markupMenu { updateMarkupMenuChecks(menu); return }
        guard menu === sidebarMenu else { return }
        // Two independent radio groups (separator-agnostic — keyed by action). Each keeps exactly one ✓.
        for item in menu.items {
            switch item.action {
            case #selector(hideSidebar(_:)):          item.state = sidebarSelection == .hidden ? .on : .off
            case #selector(showThumbnails(_:)):       item.state = sidebarSelection == .thumbnails ? .on : .off
            case #selector(showTableOfContents(_:)):  item.state = sidebarSelection == .toc ? .on : .off
            case #selector(showHighlights(_:)):       item.state = sidebarSelection == .highlights ? .on : .off
            case #selector(showBookmarks(_:)):        item.state = sidebarSelection == .bookmarks ? .on : .off
            case #selector(showContactSheet(_:)):     item.state = sidebarSelection == .contactSheet ? .on : .off
            case #selector(setContinuousScroll(_:)):  item.state = displayModeSelection == .continuous ? .on : .off
            case #selector(setSinglePage(_:)):        item.state = displayModeSelection == .single ? .on : .off
            case #selector(setTwoPages(_:)):          item.state = displayModeSelection == .twoPages ? .on : .off
            default: break
            }
        }
    }

    /// ✓ the active color swatch and the active style row in the markup pull-down.
    private func updateMarkupMenuChecks(_ menu: NSMenu) {
        let pdf = splitVC.pdf
        let active = pdf.activeColor.usingColorSpace(.sRGB)
        for item in menu.items {
            if let c = (item.representedObject as? NSColor)?.usingColorSpace(.sRGB), let active {
                let same = abs(c.redComponent - active.redComponent) < 0.02 && abs(c.greenComponent - active.greenComponent) < 0.02
                    && abs(c.blueComponent - active.blueComponent) < 0.02
                item.state = same ? .on : .off
            } else {
                switch item.action {
                case #selector(setMarkupHighlightStyle(_:)):     item.state = pdf.activeMarkup == .highlight ? .on : .off
                case #selector(setMarkupUnderlineStyle(_:)):     item.state = pdf.activeMarkup == .underline ? .on : .off
                case #selector(setMarkupStrikethroughStyle(_:)): item.state = pdf.activeMarkup == .strikethrough ? .on : .off
                default: break
                }
            }
        }
    }
}
