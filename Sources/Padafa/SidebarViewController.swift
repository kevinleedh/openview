import AppKit
import PDFKit

/// The on-demand LEFT panel (a collapsible sidebar split item, hidden by default). One slot shared by
/// all panels — Thumbnails / Table of Contents / Highlights and Notes / Bookmarks / Contact Sheet — plus
/// the transient ⌘F Search Results (a rich list: thumbnail + snippet, counts, Sort By, prev/next, Done).
/// Driven by the view-options menu (radio) and by ⌘F. Highlights / Bookmarks / Contact Sheet are scaffolds
/// for now (content is a follow-up); they exist so the menu↔slot switching works today.
final class SidebarViewController: NSViewController {

    enum Mode { case thumbnails, toc, searchResults, highlights, bookmarks, contactSheet }
    var mode: Mode = .thumbnails { didSet { applyMode() } }

    weak var pdf: PDFViewController?
    var onDone: (() -> Void)?                       // search-results "Done" → restore the previous panel

    // Panels.
    private let thumbnailList = ThumbnailListViewController()   // custom thumbnails (Preview-style selection)
    private let tocTable = NSTableView()
    private let tocScroll = NSScrollView()
    private let highlightsPanel = NSView()
    private let bookmarksPanel = NSView()
    private let contactSheetPanel = NSView()

    // Search-results: the rich list stays in this left panel; the CONTROL BAR (counts · Sort By · ‹ › ·
    // Done) is vended via `searchBar` and hosted across the top of the document area (Preview's 2-pane
    // layout) by MainSplitViewController — not crammed into this narrow sidebar.
    private let resultsPanel = NSView()
    private let resultsTable = NSTableView()
    private let resultsScroll = NSScrollView()
    let searchBar = NSView()                        // hosted in the center (document) area, not the sidebar
    private let countsLabel = NSTextField(labelWithString: "")
    private let sortControl = NSSegmentedControl(labels: ["Search Rank", "Page Order"],
                                                 trackingMode: .selectOne, target: nil, action: nil)

    private enum SortMode { case searchRank, pageOrder }
    private var sortMode: SortMode = .pageOrder
    private var searchTerm = ""
    private let thumbCache = NSCache<NSNumber, NSImage>()       // bounded — search-result row thumbnails
    private var resultRows: [(matchIndex: Int, page: Int, preview: String)] = []

    func attach(_ pdf: PDFViewController) {
        self.pdf = pdf
        thumbnailList.loadViewIfNeeded()    // ensure the collection view + data source exist before data arrives
        thumbnailList.pdf = pdf             // didSet → reload
        thumbCache.removeAllObjects()
        refresh()
    }

    func setSearchTerm(_ term: String) { searchTerm = term }

    // MARK: – Layout

    override func loadView() {
        let root = NSView()

        addChild(thumbnailList)                                     // custom NSCollectionView thumbnails

        configure(tocTable, in: tocScroll, action: #selector(tocClicked))
        configure(resultsTable, in: resultsScroll, action: #selector(resultClicked))
        resultsTable.rowHeight = 66

        addPlaceholder(to: highlightsPanel, "Highlights and Notes", "Highlights and notes will appear here.")
        addPlaceholder(to: bookmarksPanel, "Bookmarks", "Bookmarked pages will appear here.")
        addPlaceholder(to: contactSheetPanel, "Contact Sheet", "A grid of all pages will appear here.")

        buildSearchBar()        // the control bar — hosted in the center area by MainSplitViewController
        buildResultsList()      // the results list — fills this sidebar panel

        for sub in [thumbnailList.view, tocScroll, resultsPanel, highlightsPanel, bookmarksPanel, contactSheetPanel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
            NSLayoutConstraint.activate([
                sub.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                // Pin the TOP to the safe area, not the raw top: in a fullSizeContentView window the sidebar
                // extends under the titlebar/toolbar, which would otherwise sit over (and intercept clicks
                // to) the fixed search-results header controls (Sort By / ‹ › / Done).
                sub.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
                sub.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        view = root
        applyMode()
    }

    /// The Preview-style search CONTROL BAR — a single horizontal row spanning the top of the document
    /// area: `Sort By [Search Rank | Page Order]  …  N matches · Found on M pages  ‹  ›  Done`. Built here
    /// (this VC owns the search state/actions) but hosted in the center by MainSplitViewController.
    private func buildSearchBar() {
        searchBar.wantsLayer = true

        countsLabel.font = .systemFont(ofSize: 11)
        countsLabel.textColor = .secondaryLabelColor
        countsLabel.lineBreakMode = .byTruncatingTail

        sortControl.segmentStyle = .rounded
        sortControl.controlSize = .regular
        sortControl.selectedSegment = 1                 // Page Order default
        sortControl.target = self
        sortControl.action = #selector(sortChanged)

        let sortByLabel = NSTextField(labelWithString: "Sort By:")
        sortByLabel.font = .systemFont(ofSize: 11)
        sortByLabel.textColor = .secondaryLabelColor

        let prev = navButton("chevron.up", #selector(prevResult))
        let next = navButton("chevron.down", #selector(nextResult))
        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded
        done.controlSize = .regular

        let spacer = NSView()                           // expands → Sort By stays left; counts/‹›/Done go right
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [sortByLabel, sortControl, spacer, countsLabel, prev, next, done])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        searchBar.addSubview(row)
        searchBar.addSubview(separator)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: searchBar.topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -7),
            separator.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: searchBar.bottomAnchor),
        ])
    }

    /// The rich results list fills this sidebar panel (the control bar lives in the center now).
    private func buildResultsList() {
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsPanel.addSubview(resultsScroll)
        NSLayoutConstraint.activate([
            resultsScroll.topAnchor.constraint(equalTo: resultsPanel.topAnchor),
            resultsScroll.leadingAnchor.constraint(equalTo: resultsPanel.leadingAnchor),
            resultsScroll.trailingAnchor.constraint(equalTo: resultsPanel.trailingAnchor),
            resultsScroll.bottomAnchor.constraint(equalTo: resultsPanel.bottomAnchor),
        ])
    }

    private func navButton(_ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                         target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.imagePosition = .imageOnly
        return b
    }

    private func configure(_ table: NSTableView, in scroll: NSScrollView, action: Selector) {
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.style = .sourceList
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = action
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
    }

    private func addPlaceholder(to container: NSView, _ title: String, _ subtitle: String) {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 12, weight: .semibold); t.textColor = .secondaryLabelColor; t.alignment = .center
        let s = NSTextField(labelWithString: subtitle)
        s.font = .systemFont(ofSize: 11); s.textColor = .tertiaryLabelColor; s.alignment = .center
        s.lineBreakMode = .byWordWrapping; s.maximumNumberOfLines = 0
        let stack = NSStackView(views: [t, s])
        stack.orientation = .vertical; stack.spacing = 4; stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
        ])
    }

    private func applyMode() {
        thumbnailList.view.isHidden = mode != .thumbnails
        tocScroll.isHidden = mode != .toc
        resultsPanel.isHidden = mode != .searchResults
        highlightsPanel.isHidden = mode != .highlights
        bookmarksPanel.isHidden = mode != .bookmarks
        contactSheetPanel.isHidden = mode != .contactSheet
    }

    // MARK: – Data

    func refresh() {
        guard let pdf else { resultRows = []; countsLabel.stringValue = ""; tocTable.reloadData(); resultsTable.reloadData(); return }
        var rows = pdf.searchGroups.flatMap { group in
            group.matchIndices.map { (matchIndex: $0, page: group.page + 1, preview: pdf.previewText(forMatch: $0)) }
        }
        switch sortMode {
        case .pageOrder:
            rows.sort { ($0.page, $0.matchIndex) < ($1.page, $1.matchIndex) }
        case .searchRank:
            // "Rank" proxy: pages with the most matches first (PDFKit has no relevance score), then page.
            var perPage: [Int: Int] = [:]
            for r in rows { perPage[r.page, default: 0] += 1 }
            rows.sort { a, b in
                let ca = perPage[a.page] ?? 0, cb = perPage[b.page] ?? 0
                if ca != cb { return ca > cb }
                return (a.page, a.matchIndex) < (b.page, b.matchIndex)
            }
        }
        resultRows = rows
        let pageCount = Set(rows.map { $0.page }).count
        countsLabel.stringValue = rows.isEmpty
            ? "No matches"
            : "\(rows.count) match\(rows.count == 1 ? "" : "es")  ·  Found on \(pageCount) page\(pageCount == 1 ? "" : "s")"
        tocTable.reloadData()
        resultsTable.reloadData()
    }

    private func thumbnail(forPage page1Based: Int) -> NSImage? {
        let key = NSNumber(value: page1Based)
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let page = pdf?.pdfView.document?.page(at: page1Based - 1) else { return nil }
        let img = page.thumbnail(of: NSSize(width: 44, height: 57), for: .mediaBox)
        thumbCache.setObject(img, forKey: key)
        return img
    }

    /// Snippet with each occurrence of the search term emphasised (bold + accent).
    private func highlightedSnippet(_ preview: String) -> NSAttributedString {
        let base = NSMutableAttributedString(string: preview, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
        ])
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return base }
        let ns = preview as NSString
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.location < ns.length {
            let found = ns.range(of: term, options: .caseInsensitive, range: searchRange)
            if found.location == NSNotFound { break }
            base.addAttributes([.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                .foregroundColor: NSColor.controlAccentColor], range: found)
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        return base
    }

    // MARK: – Actions

    @objc private func sortChanged() {
        sortMode = sortControl.selectedSegment == 0 ? .searchRank : .pageOrder
        refresh()
    }
    @objc private func prevResult() { pdf?.searchPrev() }
    @objc private func nextResult() { pdf?.searchNext() }
    @objc private func doneClicked() { onDone?() }

    @objc private func tocClicked() {
        let row = tocTable.clickedRow
        guard let pdf, pdf.outlineItems.indices.contains(row) else { return }
        pdf.go(to: pdf.outlineItems[row].outline)
    }

    @objc private func resultClicked() {
        let row = resultsTable.clickedRow
        guard resultRows.indices.contains(row) else { return }
        pdf?.focusMatch(at: resultRows[row].matchIndex)
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === tocTable ? (pdf?.outlineItems.count ?? 0) : resultRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === tocTable {
            let id = NSUserInterfaceItemIdentifier("toc")
            let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
                let f = NSTextField(labelWithString: ""); f.identifier = id
                f.lineBreakMode = .byTruncatingTail; f.font = .systemFont(ofSize: 11)
                return f
            }()
            if let items = pdf?.outlineItems, items.indices.contains(row) {
                let item = items[row]
                field.stringValue = String(repeating: "  ", count: item.depth) + (item.outline.label ?? "")
            }
            return field
        }

        // Rich search-result row: thumbnail + highlighted snippet + page.
        guard resultRows.indices.contains(row) else { return nil }
        let r = resultRows[row]
        let thumb = NSImageView()
        thumb.image = thumbnail(forPage: r.page)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        thumb.layer?.borderWidth = 1
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.widthAnchor.constraint(equalToConstant: 44).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: 57).isActive = true

        let snippet = NSTextField(labelWithAttributedString: highlightedSnippet(r.preview))
        snippet.lineBreakMode = .byTruncatingTail
        snippet.maximumNumberOfLines = 2
        snippet.cell?.wraps = true
        let pageLabel = NSTextField(labelWithString: "Page \(r.page)")
        pageLabel.font = .systemFont(ofSize: 10)
        pageLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [snippet, pageLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let rowStack = NSStackView(views: [thumb, textStack])
        rowStack.orientation = .horizontal
        rowStack.alignment = .top
        rowStack.spacing = 8
        rowStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        return rowStack
    }
}
