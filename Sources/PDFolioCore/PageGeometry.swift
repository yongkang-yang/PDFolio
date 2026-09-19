import CoreGraphics

/// Conversions between a page's own coordinate space (its unrotated crop box,
/// as PDF content and annotations use) and its *display* space (the page as
/// shown after a clockwise rotation, origin at the bottom-left corner, which
/// is also what `PDFPage.draw(with:to:)` renders into).
public enum PageGeometry {
    public static func displaySize(box: CGSize, rotation: Int) -> CGSize {
        normalizedRotation(rotation) % 180 == 0
            ? box
            : CGSize(width: box.height, height: box.width)
    }

    /// Maps absolute page-space points in `box` to display space for the
    /// given total clockwise rotation.
    public static func pageToDisplay(box: CGRect, rotation: Int) -> CGAffineTransform {
        let x0 = box.minX, y0 = box.minY, w = box.width, h = box.height
        switch normalizedRotation(rotation) {
        case 90:
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -y0, ty: x0 + w)
        case 180:
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: x0 + w, ty: y0 + h)
        case 270:
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: y0 + h, ty: -x0)
        default:
            return CGAffineTransform(translationX: -x0, y: -y0)
        }
    }

    /// Normalized page-space rect (0...1 within the crop box) to a normalized
    /// display-space rect.
    public static func normalizedPageToDisplay(_ rect: CGRect, rotation: Int) -> CGRect {
        rect.applying(pageToDisplay(box: CGRect(x: 0, y: 0, width: 1, height: 1), rotation: rotation))
            .standardized
    }

    public static func normalizedDisplayToPage(_ rect: CGRect, rotation: Int) -> CGRect {
        rect.applying(pageToDisplay(box: CGRect(x: 0, y: 0, width: 1, height: 1), rotation: rotation).inverted())
            .standardized
    }

    public static func denormalize(_ rect: CGRect, in box: CGRect) -> CGRect {
        CGRect(
            x: box.minX + rect.minX * box.width,
            y: box.minY + rect.minY * box.height,
            width: rect.width * box.width,
            height: rect.height * box.height
        )
    }

    /// Draws a signature image into a context whose current transform is the
    /// page's own coordinate space (`box` is the page's crop box). The image
    /// is drawn upright relative to the rotation it was placed at.
    public static func drawSignature(_ image: CGImage, _ signature: PlacedSignature, box: CGRect, in context: CGContext) {
        let placement = pageToDisplay(box: box, rotation: signature.rotation)
        let displayRect = denormalize(signature.rect, in: box).applying(placement).standardized
        context.saveGState()
        context.concatenate(placement.inverted())
        context.interpolationQuality = .high
        context.draw(image, in: displayRect)
        context.restoreGState()
    }

    /// Largest rect with `aspect` (width / height) centered in `bounds`.
    public static func aspectFit(_ aspect: CGFloat, in bounds: CGRect) -> CGRect {
        guard aspect > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        var size = CGSize(width: bounds.width, height: bounds.width / aspect)
        if size.height > bounds.height {
            size = CGSize(width: bounds.height * aspect, height: bounds.height)
        }
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
