import CoreGraphics
import Foundation
import PDFKit

/// Renders small page images for the grid. Pages are drawn in their source
/// orientation; workspace rotation is applied by the view at display time, so
/// rotating a page never needs a re-render.
///
/// Not thread-safe: use each renderer from one thread at a time. It keeps
/// its own `PDFDocument` per source, separate from the UI's, so several
/// renderers can work in parallel.
public final class ThumbnailRenderer {
    private var documents: [SourceID: PDFDocument] = [:]
    private let assets: AssetLibrary
    /// PDFKit keeps each drawn page's decoded images cached in its document
    /// (tens of MB per scanned page), so documents are reopened after this
    /// many renders. Opening is cheap; parsing is lazy.
    private static let rendersPerDocumentLifetime = 8
    private var rendersSinceOpen = 0

    public init(assets: AssetLibrary) {
        self.assets = assets
    }

    /// Drops parsed documents; they reopen lazily on the next render. Call
    /// under memory pressure.
    public func purge() {
        documents.removeAll()
        rendersSinceOpen = 0
    }

    /// Renders a page so its longest displayed side is `maxPixelSize` pixels.
    public func render(source info: SourceInfo, pageIndex: Int, signatures: [PlacedSignature], maxPixelSize: CGFloat) -> CGImage? {
        defer {
            rendersSinceOpen += 1
            if rendersSinceOpen >= Self.rendersPerDocumentLifetime { purge() }
        }
        return autoreleasepool {
            if documents[info.id] == nil {
                documents[info.id] = SourceLoader.openDocument(info)
            }
            guard let page = documents[info.id]?.page(at: pageIndex) else { return nil }

            let box = page.bounds(for: .cropBox)
            let display = PageGeometry.displaySize(box: box.size, rotation: page.rotation)
            guard display.width > 0, display.height > 0 else { return nil }
            let scale = maxPixelSize / max(display.width, display.height)
            let width = max(1, Int((display.width * scale).rounded()))
            let height = max(1, Int((display.height * scale).rounded()))

            guard let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .medium
            ctx.scaleBy(x: CGFloat(width) / display.width, y: CGFloat(height) / display.height)
            page.draw(with: .cropBox, to: ctx)

            if !signatures.isEmpty {
                ctx.concatenate(PageGeometry.pageToDisplay(box: box, rotation: page.rotation))
                for signature in signatures {
                    if let image = assets.image(signature.asset) {
                        PageGeometry.drawSignature(image, signature, box: box, in: ctx)
                    }
                }
            }
            return ctx.makeImage()
        }
    }
}
