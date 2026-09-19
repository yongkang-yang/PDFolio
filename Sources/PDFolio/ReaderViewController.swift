import AppKit
import PDFKit
import PDFolioCore

protocol ReaderDelegate: AnyObject {
    func reader(_ reader: ReaderViewController, didShowPage id: UUID)
    func readerDidRequestExit(_ reader: ReaderViewController)
}

/// PDF view with page-turning keys and a horizontal swipe to turn pages.
final class ReaderPDFView: PDFView {
    var onExit: (() -> Void)?
    private var swipeDistance: CGFloat = 0
    private var swipeTurned = false

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // escape
            onExit?()
        case 123, 116: // left arrow, page up
            goToPreviousPage(nil)
        case 124, 121: // right arrow, page down
            goToNextPage(nil)
        case 115: // home
            goToFirstPage(nil)
        case 119: // end
            goToLastPage(nil)
        default:
            super.keyDown(with: event)
        }
    }

    // Two-finger horizontal swipe turns one page per gesture; vertical
    // scrolling keeps its normal continuous behavior.
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas,
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
            // Natural scrolling: fingers moving left (negative delta) reveal
            // the next page, like turning a page in a book.
            swipeDistance < 0 ? goToNextPage(nil) : goToPreviousPage(nil)
        }
        if event.phase == .ended || event.phase == .cancelled {
            swipeDistance = 0
            swipeTurned = false
        }
    }
}

/// Reading mode: the workspace's pages as they will export (rotations and
/// signatures included), shown full size with page turning.
final class ReaderViewController: NSViewController {
    let workspace: Workspace
    weak var delegate: ReaderDelegate?

    private let pdfView = ReaderPDFView()
    private let pageLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    /// Page ids in the order of the displayed document.
    private var pageIDs: [UUID] = []
    /// Keeps the source documents the displayed pages were copied from open.
    private var exporter: PDFExporter?
    private var pageObserver: NSObjectProtocol?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
    }

    override func loadView() {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.onExit = { [weak self] in
            guard let self else { return }
            self.delegate?.readerDidRequestExit(self)
        }

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
        for v in [pdfView, hud] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: root.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controls.topAnchor.constraint(equalTo: hud.topAnchor),
            controls.bottomAnchor.constraint(equalTo: hud.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: hud.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: hud.trailingAnchor),
            hud.heightAnchor.constraint(equalToConstant: 32),
            hud.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        view = root

        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.pageChanged()
        }
    }

    var currentPageID: UUID? {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return nil }
        let index = document.index(for: page)
        return index < pageIDs.count ? pageIDs[index] : nil
    }

    /// Rebuilds the displayed document from the workspace and shows `id`, or
    /// the page closest to where the reader was if `id` no longer exists.
    func show(pageID id: UUID?) {
        let previousIndex = currentPageID.flatMap { pageIDs.firstIndex(of: $0) } ?? 0
        let pages = workspace.pages
        let exporter = PDFExporter(sources: workspace.sources, assets: workspace.assets)
        guard let document = try? exporter.assembleDocument(pages) else { return }
        self.exporter = exporter
        pageIDs = pages.map(\.id)
        pdfView.document = document

        let index = id.flatMap { pageIDs.firstIndex(of: $0) } ?? min(previousIndex, max(pageIDs.count - 1, 0))
        if let page = document.page(at: index) {
            pdfView.go(to: page)
        }
        pageChanged()
    }

    /// Releases the displayed document when leaving reading mode.
    func close() {
        pdfView.document = nil
        pageIDs = []
        exporter = nil
    }

    func focus() {
        view.window?.makeFirstResponder(pdfView)
    }

    private func pageChanged() {
        guard let document = pdfView.document, let page = pdfView.currentPage else {
            pageLabel.stringValue = ""
            return
        }
        let index = document.index(for: page)
        pageLabel.stringValue = "\(index + 1) / \(document.pageCount)"
        previousButton.isEnabled = pdfView.canGoToPreviousPage
        nextButton.isEnabled = pdfView.canGoToNextPage
        if let id = currentPageID {
            delegate?.reader(self, didShowPage: id)
        }
    }

    @objc private func previousPage() { pdfView.goToPreviousPage(nil) }
    @objc private func nextPage() { pdfView.goToNextPage(nil) }
    @objc private func exitReader() { delegate?.readerDidRequestExit(self) }

    /// Renders the reader into a PNG, for `--snapshot`.
    func debugSnapshot(to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
