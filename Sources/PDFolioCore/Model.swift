import CoreGraphics
import Foundation

public typealias SourceID = UUID
public typealias AssetID = UUID

/// Where a source document's bytes come from. Imported PDFs stay on disk and
/// are never written to; imported images are converted to a one-page PDF held
/// in memory.
public enum SourceOrigin: Equatable {
    case file(URL)
    case data(Data)
}

/// An imported document. Sources are only ever appended to a workspace's
/// registry, never removed, so undo snapshots only need to cover the page list.
public struct SourceInfo: Identifiable, Equatable {
    public let id: SourceID
    public var displayName: String
    public var origin: SourceOrigin
    /// The file this source was imported from, also for images (whose
    /// pages are converted to in-memory PDF data).
    public var fileURL: URL?
    public var pageCount: Int
    public var password: String?
    /// Index into the UI's tag palette so pages from the same file are
    /// visually grouped once they're interleaved with other files.
    public var colorIndex: Int

    public init(
        id: SourceID = UUID(),
        displayName: String,
        origin: SourceOrigin,
        fileURL: URL? = nil,
        pageCount: Int,
        password: String? = nil,
        colorIndex: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.origin = origin
        self.fileURL = fileURL ?? { if case .file(let url) = origin { return url } else { return nil } }()
        self.pageCount = pageCount
        self.password = password
        self.colorIndex = colorIndex
    }
}

/// A signature placed on a page. It is attached to the page *content*: `rect`
/// is normalized (0...1) in the source page's unrotated crop box with a
/// bottom-left origin, so rotating the page later carries the signature along
/// with the content, the same as rotating a signed sheet of paper.
public struct PlacedSignature: Identifiable, Equatable {
    public let id: UUID
    public var asset: AssetID
    public var rect: CGRect
    /// The page's total clockwise display rotation when the signature was
    /// placed; the image is drawn upright when the page is shown at this
    /// rotation.
    public var rotation: Int

    public init(id: UUID = UUID(), asset: AssetID, rect: CGRect, rotation: Int) {
        self.id = id
        self.asset = asset
        self.rect = rect
        self.rotation = normalizedRotation(rotation)
    }
}

/// One page in the workspace: a reference into a source document plus the
/// edits applied to it. No page content or image data is copied.
public struct PageRef: Identifiable, Equatable {
    public let id: UUID
    public var source: SourceID
    public var pageIndex: Int
    /// Extra clockwise rotation on top of the source page's own rotation.
    /// Always one of 0, 90, 180, 270.
    public var rotation: Int
    public var signatures: [PlacedSignature]

    public init(
        id: UUID = UUID(),
        source: SourceID,
        pageIndex: Int,
        rotation: Int = 0,
        signatures: [PlacedSignature] = []
    ) {
        self.id = id
        self.source = source
        self.pageIndex = pageIndex
        self.rotation = rotation
        self.signatures = signatures
    }

    /// A copy with a fresh identity, for duplicating a page.
    public func duplicated() -> PageRef {
        PageRef(
            source: source,
            pageIndex: pageIndex,
            rotation: rotation,
            signatures: signatures.map { PlacedSignature(asset: $0.asset, rect: $0.rect, rotation: $0.rotation) }
        )
    }
}

public func normalizedRotation(_ degrees: Int) -> Int {
    let r = degrees % 360
    return r < 0 ? r + 360 : r
}
