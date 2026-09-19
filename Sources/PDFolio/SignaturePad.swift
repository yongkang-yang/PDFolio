import AppKit
import PDFolioCore

/// Canvas for drawing a signature, either by dragging with the mouse or
/// trackpad click, or in *trackpad mode*, where the trackpad surface maps
/// directly onto the canvas and a single finger draws without clicking
/// (as in Preview): touch down to draw, lift to move between strokes.
final class SignatureCanvas: NSView {
    private var strokes: [[CGPoint]] = []
    private var current: [CGPoint] = []
    var inkColor: NSColor = .black { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 2.6
    var onChange: (() -> Void)?

    private(set) var isTrackpadMode = false {
        didSet { onTrackpadModeChange?(isTrackpadMode) }
    }
    var onTrackpadModeChange: ((Bool) -> Void)?
    private var drawingTouch: NSObjectProtocol?

    var isEmpty: Bool { strokes.isEmpty && current.isEmpty }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func clear() {
        strokes = []
        current = []
        needsDisplay = true
        onChange?()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        // Baseline guide.
        let guideY = bounds.height * 0.28
        NSColor.separatorColor.setStroke()
        let guide = NSBezierPath()
        guide.move(to: CGPoint(x: 24, y: guideY))
        guide.line(to: CGPoint(x: bounds.width - 24, y: guideY))
        guide.setLineDash([4, 4], count: 2, phase: 0)
        guide.stroke()

        if isEmpty {
            let hint = isTrackpadMode
                ? "Sign with one finger on the trackpad. Press any key when done."
                : "Sign here with your mouse or trackpad"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        }

        if let ctx = NSGraphicsContext.current?.cgContext {
            Self.strokePaths(strokes + [current], in: ctx, color: inkColor.cgColor, width: lineWidth)
        }
    }

    /// Strokes smoothed through segment midpoints (quadratic curves), which
    /// removes the jaggedness of raw pointer samples.
    static func strokePaths(_ strokes: [[CGPoint]], in ctx: CGContext, color: CGColor, width: CGFloat) {
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes where !stroke.isEmpty {
            if stroke.count == 1 {
                let p = stroke[0]
                ctx.fillEllipse(in: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width))
                continue
            }
            ctx.beginPath()
            ctx.move(to: stroke[0])
            for i in 1..<stroke.count - 1 {
                let mid = CGPoint(x: (stroke[i].x + stroke[i + 1].x) / 2, y: (stroke[i].y + stroke[i + 1].y) / 2)
                ctx.addQuadCurve(to: mid, control: stroke[i])
            }
            ctx.addLine(to: stroke[stroke.count - 1])
            ctx.strokePath()
        }
    }

    /// The signature as a trimmed, transparent PNG at 4× resolution.
    func renderPNG() -> Data? {
        let all = strokes + [current]
        guard all.contains(where: { !$0.isEmpty }) else { return nil }
        let scale: CGFloat = 4
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let color = inkColor.usingColorSpace(.sRGB)?.cgColor ?? inkColor.cgColor
        Self.strokePaths(all, in: ctx, color: color, width: lineWidth)
        guard let image = ctx.makeImage() else { return nil }
        return SignatureImage.trimmedPNG(image, padding: Int(lineWidth * scale))
    }

    // MARK: Mouse / click-drag

    override func mouseDown(with event: NSEvent) {
        if isTrackpadMode {
            endTrackpadMode()
            return
        }
        current = [convert(event.locationInWindow, from: nil)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isTrackpadMode else { return }
        current.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isTrackpadMode else { return }
        finishStroke()
    }

    private func finishStroke() {
        if !current.isEmpty {
            strokes.append(current)
            current = []
            onChange?()
        }
        needsDisplay = true
    }

    // MARK: Trackpad mode

    func beginTrackpadMode() {
        guard !isTrackpadMode, let window else { return }
        isTrackpadMode = true
        window.makeFirstResponder(self)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = true
        // Park the pointer over the canvas and detach it from the trackpad so
        // finger movement only draws.
        let center = window.convertPoint(toScreen: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil))
        if let screen = window.screen ?? NSScreen.main {
            CGWarpMouseCursorPosition(CGPoint(x: center.x, y: screen.frame.maxY - center.y))
        }
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        needsDisplay = true
    }

    func endTrackpadMode() {
        guard isTrackpadMode else { return }
        finishStroke()
        drawingTouch = nil
        allowedTouchTypes = []
        wantsRestingTouches = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        isTrackpadMode = false
        needsDisplay = true
    }

    // In trackpad mode any key only ends the mode; it must not also trigger
    // a default button (Return) or cancel the sheet (Escape).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isTrackpadMode {
            endTrackpadMode()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if isTrackpadMode {
            endTrackpadMode()
        } else {
            super.cancelOperation(sender)
        }
    }

    override func keyDown(with event: NSEvent) {
        if isTrackpadMode {
            endTrackpadMode()
        } else {
            super.keyDown(with: event)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endTrackpadMode() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func canvasPoint(for touch: NSTouch) -> CGPoint {
        // Map the trackpad surface onto the canvas, preserving the trackpad's
        // aspect ratio so letters aren't stretched.
        let device = touch.deviceSize
        let aspect = device.height > 0 ? device.width / device.height : 1.5
        let area = PageGeometry.aspectFit(aspect, in: bounds.insetBy(dx: 12, dy: 12))
        let p = touch.normalizedPosition
        return CGPoint(x: area.minX + p.x * area.width, y: area.minY + p.y * area.height)
    }

    override func touchesBegan(with event: NSEvent) {
        guard isTrackpadMode else { return }
        let touches = event.touches(matching: .touching, in: self)
        // Draw only with a single finger; a second finger (e.g. a resting
        // thumb) is ignored rather than drawing a stray line.
        guard drawingTouch == nil, touches.count == 1, let touch = touches.first else { return }
        drawingTouch = touch.identity
        current = [canvasPoint(for: touch)]
        needsDisplay = true
    }

    override func touchesMoved(with event: NSEvent) {
        guard isTrackpadMode, let identity = drawingTouch,
              let touch = event.touches(matching: .touching, in: self).first(where: { $0.identity.isEqual(identity) })
        else { return }
        current.append(canvasPoint(for: touch))
        needsDisplay = true
    }

    override func touchesEnded(with event: NSEvent) {
        guard isTrackpadMode, let identity = drawingTouch,
              event.touches(matching: .ended, in: self).contains(where: { $0.identity.isEqual(identity) })
        else { return }
        drawingTouch = nil
        finishStroke()
    }

    override func touchesCancelled(with event: NSEvent) {
        guard isTrackpadMode else { return }
        drawingTouch = nil
        finishStroke()
    }
}

/// Sheet for creating a new signature.
final class SignaturePadController: NSViewController {
    private let canvas = SignatureCanvas()
    private let trackpadButton = NSButton(title: "Use Trackpad", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save Signature", target: nil, action: nil)
    var onSave: ((Data) -> Void)?

    override func loadView() {
        let title = NSTextField(labelWithString: "New Signature")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: "Draw with the pointer, or choose “Use Trackpad” to sign directly with a finger on the trackpad.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)

        let colors = NSSegmentedControl(labels: ["Black", "Blue"], trackingMode: .selectOne, target: self, action: #selector(colorChanged(_:)))
        colors.selectedSegment = 0

        trackpadButton.target = self
        trackpadButton.action = #selector(toggleTrackpad)
        trackpadButton.image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: nil)
        trackpadButton.imagePosition = .imageLeading

        let clear = NSButton(title: "Clear", target: self, action: #selector(clear))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false

        canvas.onChange = { [weak self] in
            guard let self else { return }
            self.saveButton.isEnabled = !self.canvas.isEmpty
        }
        canvas.onTrackpadModeChange = { [weak self] on in
            self?.trackpadButton.title = on ? "Stop Trackpad (any key)" : "Use Trackpad"
        }

        let tools = NSStackView(views: [colors, trackpadButton, NSView(), clear])
        let buttons = NSStackView(views: [NSView(), cancel, saveButton])
        let stack = NSStackView(views: [title, subtitle, canvas, tools, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        for v in [canvas, tools, buttons, subtitle] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        canvas.heightAnchor.constraint(equalToConstant: 220).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 560).isActive = true
        view = .padded(stack, 20)
    }

    @objc private func colorChanged(_ sender: NSSegmentedControl) {
        canvas.inkColor = sender.selectedSegment == 1
            ? NSColor(srgbRed: 0.08, green: 0.2, blue: 0.62, alpha: 1)
            : .black
    }

    @objc private func toggleTrackpad() {
        canvas.isTrackpadMode ? canvas.endTrackpadMode() : canvas.beginTrackpadMode()
    }

    @objc private func clear() {
        canvas.clear()
    }

    @objc private func cancel() {
        canvas.endTrackpadMode()
        dismiss(nil)
    }

    @objc private func save() {
        canvas.endTrackpadMode()
        guard let png = canvas.renderPNG() else { return }
        onSave?(png)
        dismiss(nil)
    }
}
