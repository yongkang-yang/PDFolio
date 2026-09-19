import AppKit
import PDFolioCore

/// Lazily renders and caches grid thumbnails.
///
/// - Rendering happens on one background queue with its own documents.
/// - Only pages whose cells are currently on screen are rendered: a request
///   is dropped if its cell scrolled away before its turn came.
/// - Images are held in an `NSCache` with a byte budget, so off-screen
///   thumbnails are released under pressure or when the budget is exceeded.
/// - Sizes snap to a few buckets so pinch-zooming reuses renders.
final class ThumbnailCache {
    static let byteBudget = 48 * 1024 * 1024
    private static let buckets: [CGFloat] = [128, 192, 256, 384, 512, 768, 1024]

    private let cache = NSCache<NSString, CGImageBox>()
    private let queue = DispatchQueue(label: "PDFolio.thumbnails", qos: .userInitiated)
    private let renderer: ThumbnailRenderer

    private let wantedLock = NSLock()
    private var wanted: Set<String> = []
    private var callbacks: [String: [(CGImage) -> Void]] = [:]

    init(assets: AssetLibrary) {
        renderer = ThumbnailRenderer(assets: assets)
        cache.totalCostLimit = Self.byteBudget
    }

    func register(_ source: SourceInfo) {
        queue.async { [renderer] in renderer.register(source) }
    }

    static func bucket(for pixels: CGFloat) -> CGFloat {
        buckets.first { $0 >= pixels } ?? buckets.last!
    }

    static func key(for ref: PageRef, bucket: CGFloat) -> String {
        var key = "\(ref.source.uuidString)/\(ref.pageIndex)/\(Int(bucket))"
        for s in ref.signatures {
            key += "/\(s.asset.uuidString)@\(s.rect.minX),\(s.rect.minY),\(s.rect.width),\(s.rect.height),\(s.rotation)"
        }
        return key
    }

    func cached(_ ref: PageRef, bucket: CGFloat) -> CGImage? {
        cache.object(forKey: Self.key(for: ref, bucket: bucket) as NSString)?.image
    }

    /// Asks for a render; `completion` runs on the main thread. Returns the
    /// request key so the caller can cancel it when the cell goes away.
    @discardableResult
    func request(_ ref: PageRef, bucket: CGFloat, completion: @escaping (CGImage) -> Void) -> String {
        let key = Self.key(for: ref, bucket: bucket)
        if let image = cache.object(forKey: key as NSString)?.image {
            completion(image)
            return key
        }
        let alreadyQueued = callbacks[key] != nil
        callbacks[key, default: []].append(completion)
        wantedLock.lock()
        wanted.insert(key)
        wantedLock.unlock()
        guard !alreadyQueued else { return key }

        let source = ref.source, index = ref.pageIndex, signatures = ref.signatures
        queue.async { [weak self] in
            guard let self else { return }
            self.wantedLock.lock()
            let stillWanted = self.wanted.contains(key)
            self.wantedLock.unlock()
            // A cancelled-then-re-requested key can be queued twice; the second
            // job finds the first one's result in the cache.
            let image = stillWanted
                ? self.cache.object(forKey: key as NSString)?.image ?? self.renderer.render(source: source, pageIndex: index, signatures: signatures, maxPixelSize: bucket)
                : nil
            DispatchQueue.main.async {
                let waiting = self.callbacks.removeValue(forKey: key) ?? []
                self.wantedLock.lock()
                self.wanted.remove(key)
                self.wantedLock.unlock()
                guard let image else { return }
                self.cache.setObject(CGImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
                waiting.forEach { $0(image) }
            }
        }
        return key
    }

    /// Called when a cell leaves the screen before its thumbnail arrived.
    func cancel(_ key: String) {
        callbacks.removeValue(forKey: key)
        wantedLock.lock()
        wanted.remove(key)
        wantedLock.unlock()
    }

    func purge() {
        cache.removeAllObjects()
        queue.async { [renderer] in renderer.purge() }
    }
}

final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
