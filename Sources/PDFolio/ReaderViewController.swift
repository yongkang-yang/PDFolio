import AppKit
import PDFKit
import PDFolioCore

protocol ReaderDelegate: AnyObject {
    func reader(_ reader: ReaderViewController, didShowPage id: UUID)
    func readerDidRequestExit(_ reader: ReaderViewController)
}

/// Source documents for the reader, opened when reading starts and released
/// when it ends. PDFKit caches decoded page images inside a document (tens of
/// MB per scanned page), so after drawing a handful of distinct pages the
/// documents are released and reopened on demand, which is cheap.
private final class ReaderPages {
    private let workspace: Workspace
    private var documents: [SourceID: PDFDocument] = [:]
    private var pagesDrawn = Set<String>()
    private var releaseScheduled = false
    private static let pagesPerDocumentLifetime = 6

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func page(for ref: PageRef) -> PDFPage? {
        if documents[ref.source] == nil, let info = workspace.sources[ref.source] {
            documents[ref.source] = SourceLoader.openDocument(info)
        }
        pagesDrawn.insert("\(ref.source)/\(ref.pageIndex)")
        if pagesDrawn.count >= Self.pagesPerDocumentLifetime, !releaseScheduled {
            // Release after the current drawing pass, not in the middle of it.
            releaseScheduled = true
            DispatchQueue.main.async { [weak self] in self?.releaseAll() }
        }
        return documents[ref.source]?.page(at: ref.pageIndex)
    }

    func releaseAll() {
        documents.removeAll()
        pagesDrawn.removeAll()
        releaseScheduled = false
    }
}

/// All pages stacked vertically, fit to the width of the window. Pages are
/// drawn as vector content, and only within the rect AppKit asks for, so
/// memory tracks the visible area rather than the document.
private final class ReaderDocumentView: NSView {
    static let margin: CGFloat = 24
    static let gap: CGFloat = 16

    var pages: ReaderPages?
    var assets: AssetLibrary?
    private(set) var refs: [PageRef] = []
    /// Page sizes as displayed (after rotation), in points.
    private var displaySizes: [CGSize] = []
    private var totalRotations: [Int] = []
    private(set) var frames: [CGRect] = []
    var onKey: ((NSEvent) -> Bool)?
    var onDoubleClick: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    func setPages(_ refs: [PageRef], displaySizes: [CGSize], totalRotations: [Int]) {
        self.refs = refs
        self.displaySizes = displaySizes
        self.totalRotations = totalRotations
    }

    /// Lays pages out for a viewport `width` points wide (at 1× zoom).
    func layout(forWidth width: CGFloat) {
        let widest = displaySizes.map(\.width).max() ?? 612
        let scale = max(0.1, (width - 2 * Self.margin) / widest)
        var y = Self.margin
        frames = displaySizes.map { size in
            let w = (size.width * scale).rounded(), h = (size.height * scale).rounded()
            let frame = CGRect(x: ((width - w) / 2).rounded(), y: y, width: w, height: h)
            y += h + Self.gap
            return frame
        }
        setFrameSize(NSSize(width: width, height: y - Self.gap + Self.margin))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let pages else { return }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        for (i, frame) in frames.enumerated() where frame.insetBy(dx: -8, dy: -8).intersects(dirtyRect) {
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.white.setFill()
            frame.fill()
            NSGraphicsContext.restoreGraphicsState()

            guard let page = pages.page(for: refs[i]) else { continue }
            let rotation = totalRotations[i]
            let box = page.bounds(for: .cropBox)
            let display = PageGeometry.displaySize(box: box.size, rotation: rotation)
            ctx.saveGState()
            ctx.clip(to: frame)
            // This view is flipped; PDF drawing expects y up.
            ctx.translateBy(x: frame.minX, y: frame.maxY)
            ctx.scaleBy(x: frame.width / display.width, y: -frame.height / display.height)
            let ownRotation = page.rotation
            page.rotation = rotation
            page.draw(with: .cropBox, to: ctx)
            page.rotation = ownRotation
            if !refs[i].signatures.isEmpty, let assets {
                ctx.concatenate(PageGeometry.pageToDisplay(box: box, rotation: rotation))
                for signature in refs[i].signatures {
                    if let image = assets.image(signature.asset) {
                        PageGeometry.drawSignature(image, signature, box: box, in: ctx)
                    }
                }
            }
            ctx.restoreGState()
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true {
            super.keyDown(with: event)
        }
    }

    // Double-click goes back to organizing, mirroring the double-click that
    // started reading.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}

/// Scroll view that turns a horizontal two-finger swipe into one page turn
/// per gesture; vertical scrolling and pinch-to-zoom behave normally.
private final class ReaderScrollView: NSScrollView {
    var onSwipe: ((_ forward: Bool) -> Void)?
    private var swipeDistance: CGFloat = 0
    private var swipeTurned = false

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, magnification <= 1.01,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || swipeDistance != 0
        else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase == .began {
            swipeDistance = 0
            swipeTurned = false
        }
        swipeDistance += event.scrollingDeltaX
        if !swipeTurned, abs(swipeDistance) > 60 {
            swipeTurned = true
            // Natural scrolling: fingers moving left reveal the next page.
            onSwipe?(swipeDistance < 0)
        }
        if event.phase == .ended || event.phase == .cancelled {
            swipeDistance = 0
            swipeTurned = false
        }
    }
}

/// Reading mode: the workspace's pages as they will export (rotations and
/// signatures included), stacked for continuous reading with page turning.
///
/// Drawn by a lightweight custom view rather than `PDFView`, which loads a
/// machine-learning model and large caches it never releases (about 150-300
/// MB even for a short text PDF).
final class ReaderViewController: NSViewController {
    let workspace: Workspace
    weak var delegate: ReaderDelegate?

    private let scrollView = ReaderScrollView()
    private let documentView = ReaderDocumentView()
    private let pageLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private var pages: ReaderPages?
    private var currentIndex = 0
    private var layoutWidth: CGFloat = 0
    /// Set while the reader scrolls to a page itself, so the resulting
    /// bounds change doesn't re-derive the page from the scroll position
    /// (the last pages can't scroll to the top of the viewport).
    private var isJumping = false
    private var boundsObserver: NSObjectProtocol?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    override func loadView() {
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 4
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.drawsBackground = true
        scrollView.onSwipe = { [weak self] forward in
            forward ? self?.nextPage() : self?.previousPage()
        }
        documentView.assets = workspace.assets
        documentView.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        documentView.onDoubleClick = { [weak self] in self?.exitReader() }

        let back = NSButton(title: "Pages", image: NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)!,
                            target: self, action: #selector(exitReader))
        back.bezelStyle = .accessoryBarAction
        back.toolTip = "Back to all pages (Esc)"

        for (button, symbol, action, tip) in [
            (previousButton, "chevron.left", #selector(previousPage), "Previous page (←)"),
            (nextButton, "chevron.right", #selector(nextPage), "Next page (→)")
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pageLabel.alignment = .center

        let separator = NSBox()
        separator.boxType = .separator

        let controls = NSStackView(views: [back, separator, previousButton, pageLabel, nextButton])
        controls.spacing = 6
        controls.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        separator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true

        // Floating pill at the bottom, like Preview's page controls.
        let hud = NSVisualEffectView()
        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 16
        hud.layer?.masksToBounds = true
        controls.translatesAutoresizingMaskIntoConstraints = false
        hud.addSubview(controls)

        let root = NSView()
        for v in [scrollView, hud] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controls.topAnchor.constraint(equalTo: hud.topAnchor),
            controls.bottomAnchor.constraint(equalTo: hud.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: hud.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: hud.trailingAnchor),
            hud.heightAnchor.constraint(equalToConstant: 32),
            hud.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        view = root

        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            self?.updateCurrentPage()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Re-fit to the window width when it changes (zoom is separate).
        let width = scrollView.contentView.frame.width
        if abs(width - layoutWidth) > 0.5, !documentView.refs.isEmpty {
            let keep = currentIndex
            relayout()
            scroll(toPage: keep)
        }
    }

    var currentPageID: UUID? {
        currentIndex < documentView.refs.count ? documentView.refs[currentIndex].id : nil
    }

    /// Loads the workspace's current pages and shows `id`, or the page
    /// closest to where the reader was if `id` no longer exists.
    func show(pageID id: UUID?) {
        let previousIndex = currentIndex
        if pages == nil { pages = ReaderPages(workspace: workspace) }
        documentView.pages = pages
        let refs = workspace.pages
        documentView.setPages(
            refs,
            displaySizes: refs.map { workspace.displaySize(of: $0) },
            totalRotations: refs.map { normalizedRotation(workspace.sourceRotation(of: $0) + $0.rotation) }
        )
        relayout()
        let index = id.flatMap { id in refs.firstIndex { $0.id == id } } ?? min(previousIndex, max(refs.count - 1, 0))
        scroll(toPage: index)
    }

    /// Releases the reader's documents when leaving reading mode.
    func close() {
        documentView.setPages([], displaySizes: [], totalRotations: [])
        documentView.pages = nil
        pages?.releaseAll()
        pages = nil
        scrollView.magnification = 1
        relayout()
    }

    func focus() {
        view.window?.makeFirstResponder(documentView)
    }

    private func relayout() {
        layoutWidth = scrollView.contentView.frame.width
        documentView.layout(forWidth: max(layoutWidth, 200))
    }

    // MARK: Navigation

    private func scroll(toPage index: Int) {
        guard index >= 0, index < documentView.frames.count else { return }
        let frame = documentView.frames[index]
        let clip = scrollView.contentView
        let maxY = max(0, documentView.frame.height - clip.bounds.height)
        isJumping = true
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, frame.minY - ReaderDocumentView.gap), maxY)))
        scrollView.reflectScrolledClipView(clip)
        isJumping = false
        setCurrentPage(index)
    }

    /// After the user scrolls: the current page is the one covering the
    /// upper part of the viewport.
    private func updateCurrentPage() {
        let frames = documentView.frames
        guard !isJumping, !frames.isEmpty else { return }
        let visible = scrollView.contentView.bounds
        let probe = visible.minY + visible.height * 0.33
        let index = frames.firstIndex { $0.maxY + ReaderDocumentView.gap / 2 >= probe } ?? frames.count - 1
        if index != currentIndex { setCurrentPage(index) }
    }

    private func setCurrentPage(_ index: Int) {
        let frames = documentView.frames
        guard !frames.isEmpty else {
            pageLabel.stringValue = ""
            return
        }
        currentIndex = index
        pageLabel.stringValue = "\(index + 1) / \(frames.count)"
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index < frames.count - 1
        if let id = currentPageID {
            delegate?.reader(self, didShowPage: id)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: exitReader()                               // escape
        case 123, 116: previousPage()                       // left arrow, page up
        case 124, 121: nextPage()                           // right arrow, page down
        case 115: scroll(toPage: 0)                         // home
        case 119: scroll(toPage: documentView.frames.count - 1) // end
        default: return false
        }
        return true
    }

    @objc private func previousPage() {
        // If the current page's top is scrolled past, go to its top first.
        let top = documentView.frames.indices.contains(currentIndex) ? documentView.frames[currentIndex].minY : 0
        if scrollView.contentView.bounds.minY > top - ReaderDocumentView.gap + 1 {
            scroll(toPage: currentIndex)
        } else {
            scroll(toPage: max(currentIndex - 1, 0))
        }
    }

    @objc private func nextPage() {
        scroll(toPage: min(currentIndex + 1, documentView.frames.count - 1))
    }

    @objc private func exitReader() { delegate?.readerDidRequestExit(self) }

    /// Renders the reader into a PNG, for `--snapshot`.
    func debugSnapshot(to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
