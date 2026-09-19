import CoreGraphics
import Foundation
import PDFKit

public struct ExportOptions: Equatable {
    /// Bake signatures (and any existing annotations) into the page content
    /// so they can't be moved or deleted in another PDF editor. Page content
    /// stays vector; interactive elements such as links and form fields
    /// become static.
    public var flatten: Bool

    public init(flatten: Bool = false) {
        self.flatten = flatten
    }
}

public enum ExportError: LocalizedError {
    case noPages
    case wouldOverwriteSource(URL)
    case sourceUnavailable(String)
    case writeFailed(URL)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noPages: return "There are no pages to export."
        case .wouldOverwriteSource(let url): return "“\(url.lastPathComponent)” is one of the imported files. Choose a different name — source files are never modified."
        case .sourceUnavailable(let name): return "“\(name)” could not be read. It may have been moved or deleted."
        case .writeFailed(let url): return "Couldn’t write “\(url.lastPathComponent)”."
        case .cancelled: return "Export was cancelled."
        }
    }
}

/// Writes a page sequence to a new PDF. Opens its own documents, so it can run
/// off the main thread while the UI keeps using its own copies.
public final class PDFExporter {
    private let sources: [SourceID: SourceInfo]
    private let assets: AssetLibrary
    private var openDocuments: [SourceID: PDFDocument] = [:]

    public init(sources: [SourceID: SourceInfo], assets: AssetLibrary) {
        self.sources = sources
        self.assets = assets
    }

    /// `progress` receives (pages done, total) and returns false to cancel.
    public func export(
        _ pages: [PageRef],
        to url: URL,
        options: ExportOptions = .init(),
        progress: ((Int, Int) -> Bool)? = nil
    ) throws {
        guard !pages.isEmpty else { throw ExportError.noPages }
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        for case .file(let sourceURL) in sources.values.map(\.origin)
        where sourceURL.standardizedFileURL.resolvingSymlinksInPath() == target {
            throw ExportError.wouldOverwriteSource(url)
        }

        // Write next to the destination and swap in at the end, so a failed or
        // cancelled export never leaves a half-written file behind.
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        defer {
            try? FileManager.default.removeItem(at: temp)
            openDocuments.removeAll()
        }
        if options.flatten {
            try writeFlattened(pages, to: temp, progress: progress)
        } else {
            try writeAssembled(pages, to: temp, progress: progress)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }

    private func sourcePage(_ ref: PageRef) throws -> PDFPage {
        guard let info = sources[ref.source] else { throw ExportError.sourceUnavailable("?") }
        if openDocuments[ref.source] == nil {
            openDocuments[ref.source] = SourceLoader.openDocument(info)
        }
        guard let page = openDocuments[ref.source]?.page(at: ref.pageIndex) else {
            throw ExportError.sourceUnavailable(info.displayName)
        }
        return page
    }

    /// Default path: copies the original page objects into a new document,
    /// so content, fonts, links and existing annotations are preserved as-is.
    /// Signatures become stamp annotations with an embedded appearance.
    private func writeAssembled(_ pages: [PageRef], to url: URL, progress: ((Int, Int) -> Bool)?) throws {
        let output = PDFDocument()
        for (i, ref) in pages.enumerated() {
            try autoreleasepool {
                guard let page = try sourcePage(ref).copy() as? PDFPage else {
                    throw ExportError.sourceUnavailable(sources[ref.source]?.displayName ?? "?")
                }
                page.rotation = normalizedRotation(page.rotation + ref.rotation)
                let box = page.bounds(for: .cropBox)
                for signature in ref.signatures {
                    guard let image = assets.image(signature.asset) else { continue }
                    page.addAnnotation(SignatureAnnotation(image: image, signature: signature, box: box))
                }
                output.insert(page, at: output.pageCount)
            }
            if let progress, !progress(i + 1, pages.count) { throw ExportError.cancelled }
        }
        guard output.write(to: url) else { throw ExportError.writeFailed(url) }
    }

    /// Flattened path: redraws each page into a streaming PDF context. Page
    /// content is replayed as vector drawing, not rasterized; only one page is
    /// in flight at a time.
    private func writeFlattened(_ pages: [PageRef], to url: URL, progress: ((Int, Int) -> Bool)?) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw ExportError.writeFailed(url)
        }
        defer { context.closePDF() }
        for (i, ref) in pages.enumerated() {
            try autoreleasepool {
                let page = try sourcePage(ref)
                let originalRotation = page.rotation
                defer { page.rotation = originalRotation }
                page.rotation = normalizedRotation(originalRotation + ref.rotation)

                let box = page.bounds(for: .cropBox)
                var mediaBox = CGRect(origin: .zero, size: PageGeometry.displaySize(box: box.size, rotation: page.rotation))
                let pageInfo = [kCGPDFContextMediaBox as String: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)]
                context.beginPDFPage(pageInfo as CFDictionary)
                page.draw(with: .cropBox, to: context)
                context.saveGState()
                context.concatenate(PageGeometry.pageToDisplay(box: box, rotation: page.rotation))
                for signature in ref.signatures {
                    guard let image = assets.image(signature.asset) else { continue }
                    PageGeometry.drawSignature(image, signature, box: box, in: context)
                }
                context.restoreGState()
                context.endPDFPage()
            }
            if let progress, !progress(i + 1, pages.count) { throw ExportError.cancelled }
        }
    }
}

/// A stamp annotation that draws a signature image. PDFKit records the drawing
/// as the annotation's appearance stream when the document is written, so
/// other PDF readers show it without knowing about this subclass.
final class SignatureAnnotation: PDFAnnotation {
    private let image: CGImage
    private let signature: PlacedSignature
    private let box: CGRect

    init(image: CGImage, signature: PlacedSignature, box: CGRect) {
        self.image = image
        self.signature = signature
        self.box = box
        let bounds = PageGeometry.denormalize(signature.rect, in: box)
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        contents = "Signature"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        PageGeometry.drawSignature(image, signature, box: self.box, in: context)
    }
}
