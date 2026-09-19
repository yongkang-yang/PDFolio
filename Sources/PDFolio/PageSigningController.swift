import AppKit
import PDFKit
import PDFolioCore

/// Shows one page at full fidelity and lets the user place, move, resize and
/// remove signatures on it.
///
/// The page is drawn as vector content straight from PDFKit each time the
/// view draws, so it stays sharp at any zoom without holding a large bitmap.
final class PageSigningView: NSView {
    private let page: PDFPage
    private let extraRotation: Int
    private let assets: AssetLibrary
    var signatures: [PlacedSignature] { didSet { needsDisplay = true; onChange?() } }
    var selectedID: UUID? { didSet { needsDisplay = true; onChange?() } }
    var onChange: (() -> Void)?

    private enum DragMode {
        case move(start: CGPoint, original: CGRect)
        /// Resizing with the given corner; `anchor` is the opposite corner.
        case resize(anchor: CGPoint, aspect: CGFloat)
    }
    private var drag: DragMode?
    private static let handleSize: CGFloat = 9

    init(page: PDFPage, extraRotation: Int, signatures: [PlacedSignature], assets: AssetLibrary) {
        self.page = page
        self.extraRotation = extraRotation
        self.signatures = signatures
        self.assets = assets
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    var totalRotation: Int { normalizedRotation(page.rotation + extraRotation) }
    var box: CGRect { page.bounds(for: .cropBox) }
    var displaySize: CGSize { PageGeometry.displaySize(box: box.size, rotation: totalRotation) }

    // MARK: Coordinates

    /// A signature's rect in this view's coordinates.
    private func viewRect(for signature: PlacedSignature) -> CGRect {
        let r = PageGeometry.normalizedPageToDisplay(signature.rect, rotation: totalRotation)
        return CGRect(x: r.minX * bounds.width, y: r.minY * bounds.height, width: r.width * bounds.width, height: r.height * bounds.height)
    }

    private func setViewRect(_ rect: CGRect, for id: UUID) {
        guard let i = signatures.firstIndex(where: { $0.id == id }), bounds.width > 0, bounds.height > 0 else { return }
        let normalized = CGRect(x: rect.minX / bounds.width, y: rect.minY / bounds.height,
                                width: rect.width / bounds.width, height: rect.height / bounds.height)
        signatures[i].rect = PageGeometry.normalizedDisplayToPage(normalized, rotation: totalRotation)
    }

    private func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill()
        bounds.fill()

        let display = displaySize
        ctx.saveGState()
        ctx.scaleBy(x: bounds.width / display.width, y: bounds.height / display.height)
        let ownRotation = page.rotation
        page.rotation = totalRotation
        page.draw(with: .cropBox, to: ctx)
        page.rotation = ownRotation
        ctx.concatenate(PageGeometry.pageToDisplay(box: box, rotation: totalRotation))
        for signature in signatures {
            if let image = assets.image(signature.asset) {
                PageGeometry.drawSignature(image, signature, box: box, in: ctx)
            }
        }
        ctx.restoreGState()

        if let selected = signatures.first(where: { $0.id == selectedID }) {
            let rect = viewRect(for: selected)
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2))
            outline.lineWidth = 1.5
            outline.setLineDash([5, 3], count: 2, phase: 0)
            outline.stroke()
            for corner in corners(of: rect.insetBy(dx: -2, dy: -2)) {
                let handle = NSBezierPath(ovalIn: CGRect(x: corner.x - Self.handleSize / 2, y: corner.y - Self.handleSize / 2,
                                                         width: Self.handleSize, height: Self.handleSize))
                NSColor.white.setFill()
                handle.fill()
                handle.lineWidth = 1.5
                handle.stroke()
            }
        }
    }

    // MARK: Interaction

    override func resetCursorRects() {
        for signature in signatures {
            addCursorRect(viewRect(for: signature), cursor: .openHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if let selected = signatures.first(where: { $0.id == selectedID }) {
            let rect = viewRect(for: selected)
            let outer = rect.insetBy(dx: -2, dy: -2)
            let cs = corners(of: outer)
            if let hit = cs.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= Self.handleSize }) {
                let anchor = cs[3 - hit]  // opposite corner
                drag = .resize(anchor: anchor, aspect: rect.width / max(rect.height, 1))
                return
            }
        }
        // Topmost (last drawn) signature under the pointer wins.
        if let hit = signatures.last(where: { viewRect(for: $0).insetBy(dx: -4, dy: -4).contains(point) }) {
            selectedID = hit.id
            drag = .move(start: point, original: viewRect(for: hit))
            NSCursor.closedHand.push()
        } else {
            selectedID = nil
            drag = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = selectedID, let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case let .move(start, original):
            var rect = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            // Keep the signature on the page.
            rect.origin.x = min(max(rect.minX, 0), bounds.width - rect.width)
            rect.origin.y = min(max(rect.minY, 0), bounds.height - rect.height)
            setViewRect(rect, for: id)
        case let .resize(anchor, aspect):
            let clamped = CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
            var width = max(abs(clamped.x - anchor.x), 24)
            var height = width / aspect
            if height < abs(clamped.y - anchor.y) {
                height = max(abs(clamped.y - anchor.y), 24 / aspect)
                width = height * aspect
            }
            let x = clamped.x < anchor.x ? anchor.x - width : anchor.x
            let y = clamped.y < anchor.y ? anchor.y - height : anchor.y
            setViewRect(CGRect(x: x, y: y, width: width, height: height).insetBy(dx: 2, dy: 2), for: id)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .move = drag { NSCursor.pop() }
        drag = nil
        window?.invalidateCursorRects(for: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelected()
        } else if let id = selectedID, let arrow = arrowOffset(event), let sig = signatures.first(where: { $0.id == id }) {
            setViewRect(viewRect(for: sig).offsetBy(dx: arrow.x, dy: arrow.y), for: id)
        } else {
            super.keyDown(with: event)
        }
    }

    private func arrowOffset(_ event: NSEvent) -> CGPoint? {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: return CGPoint(x: -step, y: 0)
        case 124: return CGPoint(x: step, y: 0)
        case 125: return CGPoint(x: 0, y: -step)
        case 126: return CGPoint(x: 0, y: step)
        default: return nil
        }
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        signatures.removeAll { $0.id == id }
        selectedID = nil
        window?.invalidateCursorRects(for: self)
    }

    /// Places a new signature, about a third of the page wide, in the lower
    /// right area where signatures usually go.
    func place(asset: AssetID) {
        let aspect = assets.aspectRatio(asset)
        let display = displaySize
        let widthPts = min(display.width * 0.32, 240)
        let heightPts = widthPts / aspect
        let normalized = CGRect(
            x: 0.62 - widthPts / display.width / 2,
            y: 0.14,
            width: widthPts / display.width,
            height: heightPts / display.height
        )
        let signature = PlacedSignature(
            asset: asset,
            rect: PageGeometry.normalizedDisplayToPage(normalized, rotation: totalRotation),
            rotation: totalRotation
        )
        signatures.append(signature)
        selectedID = signature.id
        window?.invalidateCursorRects(for: self)
    }
}

/// Sheet for signing one page: the page on the left, saved signatures on the
/// right.
final class PageSigningController: NSViewController {
    private let workspace: Workspace
    private let pageRef: PageRef
    private let pageView: PageSigningView
    private let scrollView = NSScrollView()
    private let library = NSStackView()
    private let deleteButton = NSButton(title: "Remove Signature", target: nil, action: nil)
    private var storeObserver: NSObjectProtocol?
    var onDone: (([PlacedSignature]) -> Void)?

    init?(workspace: Workspace, pageID: UUID) {
        guard let ref = workspace.pages.first(where: { $0.id == pageID }),
              let page = workspace.pdfPage(for: ref)
        else { return nil }
        self.workspace = workspace
        self.pageRef = ref
        pageView = PageSigningView(page: page, extraRotation: ref.rotation, signatures: ref.signatures, assets: workspace.assets)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    override func loadView() {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let pageArea = CGSize(width: min(900, screen.width - 420), height: min(1000, screen.height - 160))

        // Page, fit to the available area; pinch to zoom further.
        let display = pageView.displaySize
        let fit = min(pageArea.width / display.width, pageArea.height / display.height) * 0.94
        pageView.frame = CGRect(origin: .zero, size: CGSize(width: display.width * fit, height: display.height * fit))
        let container = CenteringClipView()
        scrollView.contentView = container
        scrollView.documentView = pageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 6
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalToConstant: pageArea.width).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: pageArea.height).isActive = true

        pageView.onChange = { [weak self] in self?.updateButtons() }

        // Library panel.
        let title = NSTextField(labelWithString: "Signatures")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "Click a signature to place it, then drag to move and drag a corner to resize. Pinch to zoom the page.")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor

        library.orientation = .vertical
        library.alignment = .leading
        library.spacing = 8
        let libraryScroll = NSScrollView()
        let flipped = FlippedView()
        flipped.addSubview(library)
        library.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            library.topAnchor.constraint(equalTo: flipped.topAnchor),
            library.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            library.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            library.bottomAnchor.constraint(equalTo: flipped.bottomAnchor)
        ])
        libraryScroll.documentView = flipped
        libraryScroll.hasVerticalScroller = true
        libraryScroll.drawsBackground = false
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.widthAnchor.constraint(equalTo: libraryScroll.contentView.widthAnchor).isActive = true

        let newButton = NSButton(title: "New Signature…", target: self, action: #selector(newSignature))
        newButton.image = NSImage(systemSymbolName: "signature", accessibilityDescription: nil)
        newButton.imagePosition = .imageLeading
        let importButton = NSButton(title: "Import Image…", target: self, action: #selector(importSignature))
        importButton.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        importButton.imagePosition = .imageLeading

        let side = NSStackView(views: [title, help, newButton, importButton, libraryScroll])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 10
        side.setCustomSpacing(14, after: help)
        side.setCustomSpacing(14, after: importButton)
        side.widthAnchor.constraint(equalToConstant: 250).isActive = true
        for v in [help, libraryScroll, newButton, importButton] {
            v.widthAnchor.constraint(equalTo: side.widthAnchor).isActive = true
        }

        let main = NSStackView(views: [scrollView, side])
        main.orientation = .horizontal
        main.alignment = .top
        main.spacing = 18

        deleteButton.target = self
        deleteButton.action = #selector(deleteSignature)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [deleteButton, NSView(), cancel, done])

        let root = NSStackView(views: [main, buttons])
        buttons.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        root.orientation = .vertical
        root.spacing = 14
        view = .padded(root, 20)

        reloadLibrary()
        storeObserver = NotificationCenter.default.addObserver(forName: SignatureStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadLibrary()
        }
        updateButtons()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(pageView)
    }

    private func updateButtons() {
        deleteButton.isEnabled = pageView.selectedID != nil
    }

    private func reloadLibrary() {
        library.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let saved = SignatureStore.shared.signatures
        if saved.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "No saved signatures yet.")
            empty.textColor = .tertiaryLabelColor
            library.addArrangedSubview(empty)
        }
        for signature in saved {
            let tile = SignatureTile(signature: signature)
            tile.onPick = { [weak self] in self?.place(signature.data) }
            tile.onDelete = { SignatureStore.shared.delete(signature) }
            library.addArrangedSubview(tile)
            tile.widthAnchor.constraint(equalTo: library.widthAnchor).isActive = true
        }
    }

    private func place(_ png: Data) {
        guard !png.isEmpty else { return }
        pageView.place(asset: workspace.assets.add(png))
        view.window?.makeFirstResponder(pageView)
    }

    @objc private func newSignature() {
        let pad = SignaturePadController()
        pad.onSave = { [weak self] png in
            _ = try? SignatureStore.shared.add(png: png)
            self?.place(png)
        }
        presentAsSheet(pad)
    }

    @objc private func importSignature() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
        panel.message = "Choose an image of your signature. Transparent PNGs work best; a white paper background is removed automatically."
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url),
                  let png = SignatureImage.prepareImported(data)
            else { return }
            _ = try? SignatureStore.shared.add(png: png)
            self?.place(png)
        }
    }

    /// Places a generated scribble (not saved to the library), for snapshots.
    func debugPlaceSampleSignature() {
        let ctx = CGContext(data: nil, width: 600, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let points: [CGPoint] = stride(from: 0.0, through: 1.0, by: 0.01).map { (t: Double) -> CGPoint in
            let x: Double = 30 + t * 540
            let y: Double = 100 + sin(t * 19) * 50 * (1 - t * 0.5)
            return CGPoint(x: x, y: y)
        }
        SignatureCanvas.strokePaths([points], in: ctx, color: CGColor(red: 0.08, green: 0.2, blue: 0.62, alpha: 1), width: 7)
        if let image = ctx.makeImage(), let png = SignatureImage.trimmedPNG(image) {
            place(png)
        }
    }

    @objc private func deleteSignature() {
        pageView.deleteSelected()
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    @objc private func done() {
        onDone?(pageView.signatures)
        dismiss(nil)
    }
}

/// A saved signature in the library. Click to place; right-click to delete.
final class SignatureTile: NSView {
    var onPick: (() -> Void)?
    var onDelete: (() -> Void)?
    private let imageView = NSImageView()
    private var hovering = false { didSet { updateAppearance() } }

    init(signature: SignatureStore.Signature) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        imageView.image = signature.image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            heightAnchor.constraint(equalToConstant: 72)
        ])
        let menu = NSMenu()
        menu.addItem(withTitle: "Delete Signature", action: #selector(deleteClicked), keyEquivalent: "").target = self
        self.menu = menu
        toolTip = "Click to place on the page"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance() {
        // Signatures are dark ink, so tiles stay light in dark mode too.
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderColor = (hovering ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = hovering ? 2 : 1
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() }
    }

    @objc private func deleteClicked() { onDelete?() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Keeps a smaller-than-viewport document centered, like Preview.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width {
            rect.origin.x = (doc.frame.width - rect.width) / 2
        }
        if rect.height > doc.frame.height {
            rect.origin.y = (doc.frame.height - rect.height) / 2
        }
        return rect
    }
}

extension NSView {
    /// Wraps `content` with fixed margins expressed as constraints, so a
    /// sheet sizes itself to include them (a stack view's `edgeInsets` alone
    /// aren't reliably counted when a sheet window is sized).
    static func padded(_ content: NSView, _ inset: CGFloat) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset)
        ])
        return container
    }
}
