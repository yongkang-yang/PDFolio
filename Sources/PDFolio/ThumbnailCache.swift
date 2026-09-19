import AppKit
import PDFolioCore

/// Lazily renders and caches grid thumbnails.
///
/// - Rendering runs in parallel on a few background workers (one per
///   performance core, up to 4), each with its own documents, since PDFKit
///   documents can't be shared across threads. Scanned pages cost tens of
///   milliseconds each, so this is what makes a newly added file fill in fast.
/// - Only pages whose cells are currently on screen are rendered: a request
///   is dropped if its cell scrolled away before its turn came.
/// - Images are held in an `NSCache` with a byte budget, so off-screen
///   thumbnails are released under pressure or when the budget is exceeded.
/// - Sizes snap to a few buckets so pinch-zooming reuses renders.
final class ThumbnailCache {
    static let byteBudget = 48 * 1024 * 1024
    // Up to 2048 px for one page per row on a large Retina window.
    private static let buckets: [CGFloat] = [128, 192, 256, 384, 512, 768, 1024, 1536, 2048]

    private let cache = NSCache<NSString, CGImageBox>()
    private let queue = OperationQueue()
    /// Renderers not currently in use. There are as many renderers as
    /// concurrent operations, so a running operation always finds one.
    private var idleRenderers: [ThumbnailRenderer]
    private let rendererLock = NSLock()
    /// Main thread only.
    private var sources: [SourceID: SourceInfo] = [:]

    private let wantedLock = NSLock()
    private var wanted: Set<String> = []
    private var callbacks: [String: [(CGImage) -> Void]] = [:]

    init(assets: AssetLibrary) {
        let performanceCores = (try? Self.sysctlInt("hw.perflevel0.physicalcpu")) ?? ProcessInfo.processInfo.activeProcessorCount / 2
        let workers = min(max(performanceCores, 2), 4)
        idleRenderers = (0..<workers).map { _ in ThumbnailRenderer(assets: assets) }
        queue.maxConcurrentOperationCount = workers
        queue.qualityOfService = .userInitiated
        queue.name = "PDFolio.thumbnails"
        cache.totalCostLimit = Self.byteBudget
    }

    private static func sysctlInt(_ name: String) throws -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { throw CocoaError(.featureUnsupported) }
        return Int(value)
    }

    func register(_ source: SourceInfo) {
        sources[source.id] = source
    }

    private func withRenderer<T>(_ body: (ThumbnailRenderer) -> T) -> T {
        rendererLock.lock()
        let renderer = idleRenderers.removeLast()
        rendererLock.unlock()
        defer {
            rendererLock.lock()
            idleRenderers.append(renderer)
            rendererLock.unlock()
        }
        return body(renderer)
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

        guard let source = sources[ref.source] else { return key }
        let index = ref.pageIndex, signatures = ref.signatures
        queue.addOperation { [weak self] in
            guard let self else { return }
            self.wantedLock.lock()
            let stillWanted = self.wanted.contains(key)
            self.wantedLock.unlock()
            // A cancelled-then-re-requested key can be queued twice; the second
            // job finds the first one's result in the cache.
            let image = stillWanted
                ? self.cache.object(forKey: key as NSString)?.image ?? self.withRenderer {
                    $0.render(source: source, pageIndex: index, signatures: signatures, maxPixelSize: bucket)
                }
                : nil
            DispatchQueue.main.async {
                let waiting = self.callbacks.removeValue(forKey: key) ?? []
                self.wantedLock.lock()
                self.wanted.remove(key)
                self.wantedLock.unlock()
                self.releaseDocumentsWhenIdle()
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

    private var idlePurgeScheduled = false

    /// Once a burst of rendering is done (e.g. scrolling stopped), drop the
    /// renderers' documents so their cached decoded page images are freed.
    private func releaseDocumentsWhenIdle() {
        guard queue.operationCount == 0, !idlePurgeScheduled else { return }
        idlePurgeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.idlePurgeScheduled = false
            guard self.queue.operationCount == 0 else { return }
            self.queue.addBarrierBlock {
                self.rendererLock.lock()
                self.idleRenderers.forEach { $0.purge() }
                self.rendererLock.unlock()
            }
        }
    }

    func purge() {
        cache.removeAllObjects()
        // Only idle renderers can be touched; the barrier waits until all are.
        queue.addBarrierBlock { [weak self] in
            guard let self else { return }
            self.rendererLock.lock()
            self.idleRenderers.forEach { $0.purge() }
            self.rendererLock.unlock()
        }
    }
}

final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
