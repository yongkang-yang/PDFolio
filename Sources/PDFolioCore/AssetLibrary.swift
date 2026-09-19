import CoreGraphics
import Foundation
import ImageIO

/// Signature images used by a workspace, keyed by asset id. A placed signature
/// references an asset here rather than the saved-signature library, so
/// deleting a saved signature never breaks a page it was already placed on.
///
/// Thread-safe: the UI, the thumbnail renderer and the exporter all read it.
public final class AssetLibrary: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [AssetID: Data] = [:]
    private var images: [AssetID: CGImage] = [:]

    public init() {}

    /// Adds PNG (or any ImageIO-readable) data and returns its asset id.
    /// Identical data is stored once.
    @discardableResult
    public func add(_ imageData: Data) -> AssetID {
        lock.lock()
        defer { lock.unlock() }
        if let existing = data.first(where: { $0.value == imageData })?.key {
            return existing
        }
        let id = AssetID()
        data[id] = imageData
        return id
    }

    public func image(_ id: AssetID) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = images[id] { return cached }
        guard let bytes = data[id],
              let src = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        images[id] = image
        return image
    }

    public func aspectRatio(_ id: AssetID) -> CGFloat {
        guard let image = image(id), image.height > 0 else { return 3 }
        return CGFloat(image.width) / CGFloat(image.height)
    }
}
