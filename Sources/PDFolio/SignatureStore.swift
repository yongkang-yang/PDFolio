import AppKit

/// Saved signatures, stored locally as PNG files in
/// ~/Library/Application Support/PDFolio/Signatures. Nothing leaves the Mac.
final class SignatureStore {
    static let shared = SignatureStore()
    static let didChange = Notification.Name("SignatureStoreDidChange")

    struct Signature: Identifiable {
        let id: String
        let url: URL
        let image: NSImage
        var data: Data { (try? Data(contentsOf: url)) ?? Data() }
    }

    private let directory: URL
    private(set) var signatures: [Signature] = []

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("PDFolio/Signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    private func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        signatures = urls
            .filter { $0.pathExtension == "png" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b
            }
            .compactMap { url in
                NSImage(contentsOf: url).map { Signature(id: url.lastPathComponent, url: url, image: $0) }
            }
    }

    @discardableResult
    func add(png: Data) throws -> Signature? {
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        try png.write(to: url, options: .atomic)
        reload()
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return signatures.first { $0.url == url }
    }

    func delete(_ signature: Signature) {
        try? FileManager.default.removeItem(at: signature.url)
        reload()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
