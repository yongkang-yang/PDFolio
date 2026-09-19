import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Preparing signature images for placement.
public enum SignatureImage {
    /// Normalizes an imported signature: images without real transparency
    /// (e.g. a JPEG photo of a signature on paper) get their light background
    /// keyed out, then empty margins are trimmed. Returns PNG data.
    public static func prepareImported(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              var bitmap = RGBABitmap(image)
        else { return nil }
        if !bitmap.hasTransparency {
            bitmap.keyOutLightBackground()
        }
        guard let trimmed = bitmap.trimmed(padding: 4) else { return nil }
        return pngData(trimmed)
    }

    /// Trims empty margins from a drawn signature and encodes it as PNG.
    public static func trimmedPNG(_ image: CGImage, padding: Int = 6) -> Data? {
        guard let bitmap = RGBABitmap(image), let trimmed = bitmap.trimmed(padding: padding) else { return nil }
        return pngData(trimmed)
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// Premultiplied RGBA8 pixels, top row first.
struct RGBABitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
    }

    var hasTransparency: Bool {
        stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 250 }
    }

    /// Maps luminance to alpha: paper-white becomes transparent, ink stays
    /// opaque, with a soft ramp in between so strokes keep smooth edges. Kept
    /// ink is darkened slightly so faint pen strokes stay legible, and keeps
    /// its hue (a blue-ink signature stays blue).
    mutating func keyOutLightBackground(transparentAbove high: Double = 0.82, opaqueBelow low: Double = 0.45) {
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let alpha = min(1, max(0, (high - luminance) / (high - low)))
            let darken = 0.6 * alpha  // stored premultiplied
            pixels[i] = UInt8(r * darken * 255)
            pixels[i + 1] = UInt8(g * darken * 255)
            pixels[i + 2] = UInt8(b * darken * 255)
            pixels[i + 3] = UInt8(alpha * 255)
        }
    }

    /// Crops to the bounding box of visible pixels plus `padding`.
    func trimmed(padding: Int, alphaThreshold: UInt8 = 8) -> CGImage? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > alphaThreshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        minX = max(0, minX - padding); minY = max(0, minY - padding)
        maxX = min(width - 1, maxX + padding); maxY = min(height - 1, maxY + padding)
        let w = maxX - minX + 1, h = maxY - minY + 1
        var cropped = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            let from = ((minY + row) * width + minX) * 4
            cropped.replaceSubrange(row * w * 4..<(row + 1) * w * 4, with: pixels[from..<from + w * 4])
        }
        return cropped.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }
}
