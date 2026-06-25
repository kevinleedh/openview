import AppKit
import PDFKit

/// Custom thumbnail sidebar (NSCollectionView) — replaces PDFThumbnailView so we can match Preview
/// exactly: larger page thumbnails with rounded corners + a soft paper shadow, a small page number, and
/// a SELECTED state drawn as a system-accent (blue) rounded rectangle that wraps both the thumbnail and
/// its number (PDFThumbnailView can only draw a gray, focus-dependent selection). Thumbnails generate
/// lazily and cache, so large documents stay responsive.
final class ThumbnailListViewController: NSViewController {

    weak var pdf: PDFViewController? { didSet { observe(); reloadIfReady() } }

    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let thumbCache = NSCache<NSNumber, NSImage>()          // bounded — won't grow without limit on huge PDFs
    private let thumbQueue = DispatchQueue(label: "com.padafa.thumbnails", qos: .userInitiated)  // serial: never hit PDFDocument concurrently
    private let thumbSize = NSSize(width: 140, height: 181)        // larger thumbnails (Preview-like, bigger)

    // Generation token: bumped whenever the document is attached / swapped / cleared (e.g. drive eject →
    // pdfView.document = nil). An off-main render captures the token at dispatch and re-checks it (1) before
    // touching the PDFKit graph and (2) before applying its result; if it changed, the render is dropped.
    // This stops a background page.thumbnail() from racing the main thread's document teardown/swap on the
    // non-thread-safe PDFKit graph (the Stage-3 T1 crash). genLock makes the token safe to read off-main.
    private let genLock = NSLock()
    private var _generation = 0
    private func currentGeneration() -> Int { genLock.lock(); defer { genLock.unlock() }; return _generation }
    private func bumpGeneration() { genLock.lock(); _generation += 1; genLock.unlock() }

    override func loadView() {
        let layout = NSCollectionViewFlowLayout()
        // Height = thumb + blue frame + the page-number row. +31 leaves ~15pt for the 11pt number — just
        // enough for its full line height (top 8 + thumb + gap 4 + ~15 label + bottom 4) without clipping.
        // (+26 clipped it to ~10pt; +36 left too much empty space under the number.)
        layout.itemSize = NSSize(width: thumbSize.width + 14, height: thumbSize.height + 31)
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 6, bottom: 16, right: 6)  // narrow sidebar (166pt), big thumbs

        thumbCache.countLimit = 64                    // ~at most 64 page images resident at once

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.id)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadIfReady()                       // the collection view is set up now → populate if a doc is attached
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Once the view has a real size, make sure items are laid out (the first reload can happen at zero width).
        collectionView.reloadData()
        selectCurrentPage(scroll: false)
    }

    /// Reload after a new document is attached. Safe to call before the view loads (it's a no-op until then).
    func reload() { reloadIfReady() }

    private func reloadIfReady() {
        bumpGeneration()                      // invalidate any in-flight off-main renders against the old doc
        guard isViewLoaded else { return }
        thumbCache.removeAllObjects()
        collectionView.reloadData()
        DispatchQueue.main.async { [weak self] in self?.selectCurrentPage(scroll: false) }
    }

    private func observe() {
        guard let pdf else { return }
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: .PDFViewPageChanged, object: nil)
        nc.removeObserver(self, name: .PDFViewDocumentChanged, object: nil)
        nc.addObserver(self, selector: #selector(pageChanged),
                       name: .PDFViewPageChanged, object: pdf.pdfView)
        // The PDFView swapped or cleared (eject) its document → bump the token + rebuild from the new doc.
        nc.addObserver(self, selector: #selector(documentChanged),
                       name: .PDFViewDocumentChanged, object: pdf.pdfView)
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func pageChanged() { selectCurrentPage(scroll: true) }
    @objc private func documentChanged() { reloadIfReady() }

    private func selectCurrentPage(scroll: Bool) {
        guard isViewLoaded, let doc = pdf?.pdfView.document, let current = pdf?.pdfView.currentPage else { return }
        let index = doc.index(for: current)
        // Validate against the COLLECTION VIEW's current item count — NOT the document's pageCount. Setting
        // pdfView.document synchronously posts .PDFViewPageChanged before this collection view has been
        // reloaded for the new doc, so its item count is still stale (often 0). Scrolling/selecting an
        // out-of-range index path makes NSCollectionView throw (layoutAttributesForItemAtIndexPath:),
        // which AppKit swallows mid-open — the window then never finishes and the app "won't open".
        let itemCount = collectionView.numberOfItems(inSection: 0)
        guard index >= 0, index < itemCount else { return }
        let path = IndexPath(item: index, section: 0)
        if collectionView.selectionIndexPaths != [path] {
            collectionView.selectionIndexPaths = [path]
        }
        if scroll { collectionView.animator().scrollToItems(at: [path], scrollPosition: .centeredVertically) }
    }

    /// Return the cached thumbnail if present; otherwise render it OFF the main thread (so a vector-heavy
    /// page can't stutter the UI) and patch the visible cell in when it's ready. Returns nil on a miss.
    private func thumbnail(_ pageIndex: Int) -> NSImage? {
        let key = NSNumber(value: pageIndex)
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let page = pdf?.pdfView.document?.page(at: pageIndex) else { return nil }
        let size = thumbSize
        let gen = currentGeneration()                 // token captured at dispatch (main thread)
        thumbQueue.async { [weak self] in
            guard let self else { return }
            // Bail BEFORE touching the PDFKit graph if the document was swapped/cleared since dispatch —
            // this is what keeps page.thumbnail() from racing a main-thread document teardown/swap.
            guard self.currentGeneration() == gen else { return }
            let image = page.thumbnail(of: size, for: .mediaBox)
            DispatchQueue.main.async {
                // Discard a result that finished after a document change (don't cache/show a stale page).
                guard self.currentGeneration() == gen else { return }
                self.thumbCache.setObject(image, forKey: key)
                // Only touch the cell if it's still on screen for this index (it may have been recycled).
                let path = IndexPath(item: pageIndex, section: 0)
                if let item = self.collectionView.item(at: path) as? ThumbnailItem {
                    item.configure(image: image, page: pageIndex + 1, thumbSize: size)
                }
            }
        }
        return nil
    }
}

extension ThumbnailListViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        pdf?.pdfView.document?.pageCount ?? 0
    }
    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ThumbnailItem.id, for: indexPath) as! ThumbnailItem
        item.configure(image: thumbnail(indexPath.item), page: indexPath.item + 1, thumbSize: thumbSize)
        return item
    }
}

extension ThumbnailListViewController: NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, let page = pdf?.pdfView.document?.page(at: index) else { return }
        pdf?.pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: CGFloat.greatestFiniteMagnitude)))
    }
}

/// One thumbnail cell: a paper-style page (rounded + soft shadow) with a page number, and a blue
/// accent rounded-rect that wraps the whole cell (thumbnail + number) when selected — matching Preview.
final class ThumbnailItem: NSCollectionViewItem {

    static let id = NSUserInterfaceItemIdentifier("ThumbnailItem")

    private let card = NSView()         // shadow host (not clipped)
    private let thumb = NSImageView()   // the page image (rounded, clipped)
    private let numberLabel = NSTextField(labelWithString: "")
    private var thumbConstraints: [NSLayoutConstraint] = []

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 9                 // the rounded blue selection frame (굴곡)

        card.wantsLayer = true
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.22             // soft "paper" drop shadow
        card.layer?.shadowRadius = 3.5
        card.layer?.shadowOffset = CGSize(width: 0, height: -1)
        card.layer?.masksToBounds = false

        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 3                // subtly rounded page corners
        thumb.layer?.masksToBounds = true
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        thumb.layer?.borderWidth = 0.5
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(thumb)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            thumb.topAnchor.constraint(equalTo: card.topAnchor),
            thumb.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        numberLabel.font = .systemFont(ofSize: 11)
        numberLabel.alignment = .center
        numberLabel.lineBreakMode = .byClipping                 // single line, never wrap/truncate the page number
        numberLabel.setContentCompressionResistancePriority(.required, for: .vertical)  // keep full glyph height
        numberLabel.setContentHuggingPriority(.required, for: .vertical)

        card.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)
        root.addSubview(numberLabel)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            numberLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 4),
            numberLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            numberLabel.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -4),
        ])
        view = root
        applySelection()
    }

    func configure(image: NSImage?, page: Int, thumbSize: NSSize) {
        thumb.image = image
        numberLabel.stringValue = "\(page)"
        NSLayoutConstraint.deactivate(thumbConstraints)
        thumbConstraints = [
            card.widthAnchor.constraint(equalToConstant: thumbSize.width),
            card.heightAnchor.constraint(equalToConstant: thumbSize.height),
        ]
        NSLayoutConstraint.activate(thumbConstraints)
        applySelection()
    }

    override var isSelected: Bool { didSet { applySelection() } }

    private func applySelection() {
        if isSelected {
            view.layer?.backgroundColor = NSColor.controlAccentColor.cgColor   // blue rounded frame wraps all
            numberLabel.textColor = .white
            numberLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        } else {
            view.layer?.backgroundColor = NSColor.clear.cgColor
            numberLabel.textColor = .secondaryLabelColor
            numberLabel.font = .systemFont(ofSize: 11)
        }
    }
}
