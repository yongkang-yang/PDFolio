import AppKit
import PDFolioCore

enum Palette {
    /// Tag colors that tell source files apart once their pages are mixed.
    static let sourceColors: [NSColor] = [
        .systemBlue, .systemOrange, .systemGreen, .systemPink,
        .systemPurple, .systemTeal, .systemYellow, .systemRed, .systemIndigo, .systemBrown
    ]

    static func color(for index: Int) -> NSColor {
        sourceColors[index % sourceColors.count]
    }
}

/// Draws one page thumbnail. The image is set as layer contents (no extra
/// backing store per cell) and workspace rotation is a layer transform, so
/// rotating never re-renders.
final class ThumbnailView: NSView {
    private let pageLayer = CALayer()
    private var displayAspect: CGFloat = 612.0 / 792.0
    private var rotation = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        pageLayer.backgroundColor = NSColor.white.cgColor
        pageLayer.contentsGravity = .resize
        pageLayer.shadowColor = NSColor.black.cgColor
        pageLayer.shadowOpacity = 0.22
        pageLayer.shadowRadius = 3
        pageLayer.shadowOffset = CGSize(width: 0, height: -1)
        pageLayer.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        pageLayer.borderWidth = 0.5
        pageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        layer?.addSublayer(pageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// `displaySize` is the page size after workspace rotation; `rotation`
    /// is the workspace rotation applied on top of the rendered image.
    func configure(displaySize: CGSize, rotation: Int) {
        displayAspect = displaySize.height > 0 ? displaySize.width / displaySize.height : 1
        self.rotation = rotation
        needsLayout = true
    }

    func setImage(_ image: CGImage?) {
        pageLayer.contents = image
    }

    /// The page's on-screen rect, in this view's coordinates.
    var pageFrame: CGRect {
        PageGeometry.aspectFit(displayAspect, in: bounds.insetBy(dx: 4, dy: 4))
    }

    override func layout() {
        super.layout()
        let fit = pageFrame
        // The layer holds the unrotated image; size it in that orientation and
        // rotate it into place around its center.
        let quarter = rotation % 180 != 0
        pageLayer.bounds = CGRect(
            x: 0, y: 0,
            width: quarter ? fit.height : fit.width,
            height: quarter ? fit.width : fit.height
        )
        pageLayer.position = CGPoint(x: fit.midX, y: fit.midY)
        // Positive rotation is clockwise on screen; in this flipped view a
        // positive angle already turns clockwise.
        pageLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180))
        pageLayer.shadowPath = CGPath(rect: pageLayer.bounds, transform: nil)
    }
}

final class PageItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PageItem")

    let thumbnail = ThumbnailView()
    private let numberLabel = NSTextField(labelWithString: "")
    private let tagDot = NSView()
    private let selectionLayer = CALayer()
    private(set) var pendingKey: String?
    var pageID: UUID?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        selectionLayer.cornerRadius = 8
        selectionLayer.borderWidth = 0
        root.layer?.addSublayer(selectionLayer)

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.alignment = .center
        numberLabel.lineBreakMode = .byTruncatingMiddle

        tagDot.wantsLayer = true
        tagDot.layer?.cornerRadius = 3.5

        for v in [thumbnail, numberLabel, tagDot] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            thumbnail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            thumbnail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            thumbnail.bottomAnchor.constraint(equalTo: numberLabel.topAnchor, constant: -4),
            numberLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor, constant: 6),
            numberLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
            numberLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -24),
            tagDot.widthAnchor.constraint(equalToConstant: 7),
            tagDot.heightAnchor.constraint(equalToConstant: 7),
            tagDot.centerYAnchor.constraint(equalTo: numberLabel.centerYAnchor),
            tagDot.trailingAnchor.constraint(equalTo: numberLabel.leadingAnchor, constant: -5)
        ])
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.frame = view.bounds.insetBy(dx: 1, dy: 1)
        CATransaction.commit()
    }

    func configure(number: Int, source: SourceInfo?, sourcePageNumber: Int, displaySize: CGSize, rotation: Int) {
        numberLabel.stringValue = "\(number)"
        numberLabel.toolTip = source.map { "\($0.displayName) — page \(sourcePageNumber)" }
        view.toolTip = numberLabel.toolTip
        tagDot.layer?.backgroundColor = Palette.color(for: source?.colorIndex ?? 0).cgColor
        thumbnail.configure(displaySize: displaySize, rotation: rotation)
    }

    func setPending(_ key: String?) {
        pendingKey = key
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        let on = isSelected || highlightState == .forSelection
        selectionLayer.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : nil
        selectionLayer.borderColor = NSColor.controlAccentColor.cgColor
        selectionLayer.borderWidth = on ? 2 : 0
        numberLabel.textColor = on ? .controlAccentColor : .secondaryLabelColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.setImage(nil)
        pageID = nil
        pendingKey = nil
    }
}
