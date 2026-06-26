import AppKit

/// The 2-pane reading layout (CLAUDE.md): center source PDF (fixed, never collapsed) | right AI panel
/// (collapsible, expanded by default). A third LEFT item — the on-demand thumbnails/TOC/search-results
/// sidebar — is collapsed by default and revealed from the view-options menu / ⌘F.
final class MainSplitViewController: NSSplitViewController {

    let sidebar = SidebarViewController()
    let pdf = PDFViewController()
    let ai = AIPanelViewController()

    private var sidebarItem: NSSplitViewItem!
    private var aiItem: NSSplitViewItem!

    // Center = [search control bar (top, hidden) | PDF]. The bar appears only in search mode. Two
    // alternative top constraints for the PDF: pinned to the container top (normal — full-bleed under the
    // toolbar, unchanged) or under the bar (search). We toggle them in setSearchBarVisible.
    private var pdfTopToContainer: NSLayoutConstraint!
    private var pdfTopToBar: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()

        let sb = NSSplitViewItem(sidebarWithViewController: sidebar)
        sb.minimumThickness = 166           // narrow, fixed width — big thumbnails fill it with tight padding
        sb.maximumThickness = 166
        sb.canCollapse = true
        sb.isCollapsed = true                                   // left = on-demand (hidden by default)
        addSplitViewItem(sb)
        sidebarItem = sb
        sidebar.loadViewIfNeeded()                              // build sidebar.searchBar before we host it

        // Center container hosting the search bar above the PDF (Preview's 2-pane search layout).
        let centerContainer = NSViewController()
        let cv = NSView()
        centerContainer.view = cv
        centerContainer.addChild(pdf)
        let bar = sidebar.searchBar
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        pdf.view.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(pdf.view)
        cv.addSubview(bar)
        pdfTopToContainer = pdf.view.topAnchor.constraint(equalTo: cv.topAnchor)
        pdfTopToBar = pdf.view.topAnchor.constraint(equalTo: bar.bottomAnchor)
        NSLayoutConstraint.activate([
            // Bar sits in the SAFE AREA (below the unified toolbar) so its controls are clickable, never
            // tucked under the titlebar (the prior fullSizeContentView click-blocking bug).
            bar.topAnchor.constraint(equalTo: cv.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            pdf.view.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            pdf.view.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            pdf.view.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            pdfTopToContainer,                                  // normal mode: PDF full-bleed under the toolbar
        ])

        let center = NSSplitViewItem(viewController: centerContainer)
        center.canCollapse = false                              // the reading surface never collapses
        center.holdingPriority = NSLayoutConstraint.Priority(249) // lowest → center absorbs window resize
        addSplitViewItem(center)

        let inspector = NSSplitViewItem(viewController: ai)
        inspector.minimumThickness = 280
        inspector.canCollapse = true
        inspector.isCollapsed = false                           // AI panel expanded by default
        addSplitViewItem(inspector)
        aiItem = inspector

        sidebar.attach(pdf)                                     // wire thumbnails/TOC/results to the PDFView

        // Floating "Ask" on a PDF text selection → quote it into the AI panel (reveal the panel if collapsed).
        pdf.onAskSelection = { [weak self] text in
            guard let self else { return }
            if self.aiItem.isCollapsed { self.aiItem.animator().isCollapsed = false }
            self.ai.loadViewIfNeeded()
            self.ai.insertQuotation(text)
        }
    }

    // MARK: – AI panel

    var isAIPanelCollapsed: Bool { aiItem.isCollapsed }
    func toggleAIPanel() { aiItem.animator().isCollapsed.toggle() }

    // MARK: – Left sidebar

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }

    func showSidebar(_ mode: SidebarViewController.Mode) {
        sidebar.mode = mode
        setSearchBarVisible(mode == .searchResults)            // the center bar shows only in search mode
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
    }

    func hideSidebar() {
        setSearchBarVisible(false)
        if !sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = true }
    }

    /// Show/hide the center document-top search bar, swapping the PDF's top constraint so the PDF is
    /// full-bleed under the toolbar normally and sits below the bar in search mode.
    private func setSearchBarVisible(_ visible: Bool) {
        guard sidebar.searchBar.isHidden == visible else { return }   // no-op if already in that state
        if visible {
            pdfTopToContainer.isActive = false
            pdfTopToBar.isActive = true
        } else {
            pdfTopToBar.isActive = false
            pdfTopToContainer.isActive = true
        }
        sidebar.searchBar.isHidden = !visible
    }
}
