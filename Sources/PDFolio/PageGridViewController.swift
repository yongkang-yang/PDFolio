import AppKit
import PDFolioCore
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    static let pdfolioPage = NSPasteboard.PasteboardType("com.yongkang.pdfolio.page")
}

protocol PageGridDelegate: AnyObject {
    func pageGrid(_ grid: PageGridViewController, openPage id: UUID)
    func pageGrid(_ grid: PageGridViewController, importFiles urls: [URL], atGap gap: Int?)
    func pageGridSelectionDidChange(_ grid: PageGridViewController)
    func pageGridZoomDidChange(_ grid: PageGridViewController)
}

/// Collection view with the trackpad and keyboard shortcuts for organizing.
final class PageCollectionView: NSCollectionView {
    weak var grid: PageGridViewController?

    override var acceptsFirstResponder: Bool { true }

    // Pinch: resize thumbnails.
    override func magnify(with event: NSEvent) {
        grid?.zoom(by: 1 + event.magnification)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if let indexPath = indexPathForItem(at: point) {
                grid?.openPage(at: indexPath.item)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            grid?.deleteSelection()
        case 36, 76: // return, enter
            if let first = grid?.selectedIndices.first {
                grid?.openPage(at: first)
            }
        default:
            super.keyDown(with: event)
        }
    }
}

final class PageGridViewController: NSViewController {
    static let minZoom: CGFloat = 90
    static let maxZoom: CGFloat = 420

    let workspace: Workspace
    weak var delegate: PageGridDelegate?

    private(set) var collectionView: PageCollectionView!
    private var scrollView: NSScrollView!
    private let layout = NSCollectionViewFlowLayout()
    private let emptyState = EmptyStateView()

    /// Thumbnail width in points.
    private(set) var zoom: CGFloat = 170 {
        didSet { applyZoom() }
    }

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
        if let saved = UserDefaults.standard.object(forKey: "thumbnailZoom") as? CGFloat {
            zoom = min(max(saved, Self.minZoom), Self.maxZoom)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 18, left: 18, bottom: 24, right: 18)

        collectionView = PageCollectionView()
        collectionView.grid = self
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PageItem.self, forItemWithIdentifier: PageItem.identifier)
        collectionView.registerForDraggedTypes([.pdfolioPage, .fileURL])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.setDraggingSourceOperationMask([], forLocal: false)

        scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true

        // Catches file drops outside the collection view's items (e.g. on the
        // empty state before anything has been imported).
        let root = FileDropView()
        root.onDrop = { [weak self] urls in
            guard let self else { return }
            self.delegate?.pageGrid(self, importFiles: urls, atGap: nil)
        }
        for v in [scrollView!, emptyState] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40)
        ])
        view = root
        applyZoom()
        updateEmptyState()
    }

    // MARK: Data

    func reload(keepingSelection selection: Set<UUID>? = nil) {
        let keep = selection ?? selectedIDs
        collectionView.reloadData()
        updateEmptyState()
        select(keep, scroll: false)
    }

    private func updateEmptyState() {
        emptyState.isHidden = !workspace.pages.isEmpty
    }

    /// Selection by page id. Tracked separately from the collection view's
    /// index paths, which point at the wrong pages as soon as an edit
    /// reorders the list.
    private(set) var selectedIDs: Set<UUID> = []

    var selectedIndices: [Int] {
        workspace.pages.indices.filter { selectedIDs.contains(workspace.pages[$0].id) }
    }

    private func syncSelectionFromView() {
        selectedIDs = Set(collectionView.selectionIndexPaths.compactMap {
            $0.item < workspace.pages.count ? workspace.pages[$0.item].id : nil
        })
        delegate?.pageGridSelectionDidChange(self)
    }

    func select(_ ids: Set<UUID>, scroll: Bool = true) {
        let paths = Set(workspace.pages.indices
            .filter { ids.contains(workspace.pages[$0].id) }
            .map { IndexPath(item: $0, section: 0) })
        collectionView.selectionIndexPaths = paths
        selectedIDs = Set(paths.map { workspace.pages[$0.item].id })
        if scroll, let first = paths.min() {
            collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
        }
        delegate?.pageGridSelectionDidChange(self)
    }

    // MARK: Actions invoked by gestures and keys

    func openPage(at index: Int) {
        guard index < workspace.pages.count else { return }
        delegate?.pageGrid(self, openPage: workspace.pages[index].id)
    }

    func rotateSelection(by degrees: Int) {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        workspace.apply(degrees > 0 ? "Rotate Right" : "Rotate Left") { $0.rotate(ids: ids, by: degrees) }
    }

    func deleteSelection() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        let next = selectedIndices.first ?? 0
        workspace.apply(ids.count == 1 ? "Delete Page" : "Delete Pages") { $0.remove(ids: ids) }
        if !workspace.pages.isEmpty {
            select([workspace.pages[min(next, workspace.pages.count - 1)].id], scroll: false)
        }
    }

    // MARK: Zoom

    func zoom(by factor: CGFloat) {
        setZoom(zoom * factor)
    }

    func setZoom(_ value: CGFloat) {
        zoom = min(max(value, Self.minZoom), Self.maxZoom)
        UserDefaults.standard.set(zoom, forKey: "thumbnailZoom")
        delegate?.pageGridZoomDidChange(self)
    }

    private func applyZoom() {
        // Keep the page at the top of the viewport anchored while resizing.
        let anchor = collectionView?.indexPathsForVisibleItems().min()
        layout.itemSize = NSSize(width: zoom + 12, height: (zoom * 1.3).rounded() + 28)
        guard let collectionView else { return }
        layout.invalidateLayout()
        if let anchor {
            collectionView.scrollToItems(at: [anchor], scrollPosition: .top)
        }
        // Visible cells may now need a sharper render.
        for case let item as PageItem in collectionView.visibleItems() {
            if let path = collectionView.indexPath(for: item) {
                loadThumbnail(for: item, at: path.item)
            }
        }
    }

    private var thumbnailBucket: CGFloat {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return ThumbnailCache.bucket(for: zoom * 1.3 * scale)
    }

    private func loadThumbnail(for item: PageItem, at index: Int) {
        let ref = workspace.pages[index]
        let bucket = thumbnailBucket
        if let image = workspace.thumbnails.cached(ref, bucket: bucket) {
            item.thumbnail.setImage(image)
            return
        }
        // Show any smaller render we already have while the sharp one loads.
        if let fallback = ThumbnailCache.bucketsBelow(bucket).lazy.compactMap({ self.workspace.thumbnails.cached(ref, bucket: $0) }).first {
            item.thumbnail.setImage(fallback)
        }
        let pageID = ref.id
        let key = workspace.thumbnails.request(ref, bucket: bucket) { [weak item] image in
            guard let item, item.pageID == pageID else { return }
            item.thumbnail.setImage(image)
            item.setPending(nil)
        }
        item.setPending(key)
    }

    /// Scrolls through the whole grid and back, then reports memory. Used by
    /// the `--scroll-benchmark` launch argument to catch cache regressions.
    func runScrollBenchmark(completion: @escaping (String) -> Void) {
        let clip = scrollView.contentView
        let total = collectionView.frame.height - clip.bounds.height
        guard total > 0 else { completion("nothing to scroll"); return }
        var y: CGFloat = 0
        var direction: CGFloat = 1
        var peak = MemoryStats.footprintMB()
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            y += direction * 90
            if y >= total { y = total; direction = -1 }
            clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
            self.scrollView.reflectScrolledClipView(clip)
            peak = max(peak, MemoryStats.footprintMB())
            if direction < 0 && y <= 0 {
                timer.invalidate()
                completion(String(format: "scrolled %d pages down and up in %.1fs, peak footprint %.0f MB, now %.0f MB",
                                  self.workspace.pages.count, Date().timeIntervalSince(start), peak, MemoryStats.footprintMB()))
            }
        }
    }
}

extension ThumbnailCache {
    static func bucketsBelow(_ bucket: CGFloat) -> [CGFloat] {
        [768, 512, 384, 256, 192, 128].filter { $0 < bucket }
    }
}

// MARK: - Data source & delegate

extension PageGridViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        workspace.pages.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PageItem.identifier, for: indexPath) as! PageItem
        let ref = workspace.pages[indexPath.item]
        item.pageID = ref.id
        item.configure(
            number: indexPath.item + 1,
            source: workspace.sources[ref.source],
            sourcePageNumber: ref.pageIndex + 1,
            displaySize: workspace.displaySize(of: ref),
            rotation: ref.rotation
        )
        loadThumbnail(for: item, at: indexPath.item)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        if let item = item as? PageItem, let key = item.pendingKey {
            workspace.thumbnails.cancel(key)
            item.setPending(nil)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        syncSelectionFromView()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        syncSelectionFromView()
    }

    // MARK: Drag source

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(workspace.pages[indexPath.item].id.uuidString, forType: .pdfolioPage)
        return item
    }

    // MARK: Drop target

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        // Always drop into the gap between pages, never onto one.
        if proposedDropOperation.pointee == .on {
            proposedDropOperation.pointee = .before
        }
        if draggingInfo.draggingSource as? NSCollectionView === collectionView {
            return .move
        }
        return importableURLs(from: draggingInfo).isEmpty ? [] : .copy
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        let gap = indexPath.item
        if draggingInfo.draggingSource as? NSCollectionView === collectionView {
            let ids = Set(draggingInfo.draggingPasteboard.pasteboardItems?
                .compactMap { $0.string(forType: .pdfolioPage).flatMap(UUID.init(uuidString:)) } ?? [])
            guard !ids.isEmpty else { return false }
            workspace.apply(ids.count == 1 ? "Move Page" : "Move Pages") { $0.move(ids: ids, toGap: gap) }
            select(ids, scroll: false)
            return true
        }
        let urls = importableURLs(from: draggingInfo)
        guard !urls.isEmpty else { return false }
        delegate?.pageGrid(self, importFiles: urls, atGap: gap)
        return true
    }

    private func importableURLs(from info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter(SourceLoader.isSupported)
    }
}

// MARK: - Empty state

final class EmptyStateView: NSStackView {
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 10
        let image = NSImageView(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!)
        image.symbolConfiguration = .init(pointSize: 44, weight: .light)
        image.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: "Drop PDFs or images here")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let subtitle = NSTextField(wrappingLabelWithString: "Reorder pages by dragging. Pinch to resize thumbnails, double-click a page to sign it.")
        subtitle.alignment = .center
        subtitle.textColor = .tertiaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.preferredMaxLayoutWidth = 320
        let button = NSButton(title: "Add Files…", target: nil, action: #selector(WorkspaceWindowController.addFiles(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .large
        addArrangedSubview(image)
        addArrangedSubview(title)
        addArrangedSubview(subtitle)
        setCustomSpacing(16, after: subtitle)
        addArrangedSubview(button)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Only the button is interactive; drags and clicks elsewhere fall through
    // to the drop target behind.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : nil
    }
}

/// A view that accepts PDFs and images dragged from Finder.
final class FileDropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func urls(from info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter(SourceLoader.isSupported)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = urls(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
