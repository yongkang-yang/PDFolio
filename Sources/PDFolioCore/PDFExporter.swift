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
    /// Output size after which a flattened export starts a new chunk (see
    /// `writeFlattened`). Exposed so checks can force several chunks.
    public var flattenChunkBytes = 32 * 1024 * 1024
    /// Memory growth after which a flattened export starts a new chunk.
    public var flattenChunkMemoryGrowth = 64 * 1024 * 1024

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
        let output = try assembleDocument(pages, progress: progress)
        guard output.write(to: url) else { throw ExportError.writeFailed(url) }
    }

    /// Builds the page sequence as one in-memory document, exactly as the
    /// default export writes it. Pages reference the source documents' content
    /// rather than copying or rendering it, so this is cheap even for large
    /// workspaces; the reading view displays it directly.
    public func assembleDocument(_ pages: [PageRef], progress: ((Int, Int) -> Bool)? = nil) throws -> PDFDocument {
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
        return output
    }

    /// Flattened path: redraws each page into a PDF context. Page content is
    /// replayed as vector drawing, not rasterized.
    ///
    /// A `CGPDFContext` holds on to data proportional to everything written
    /// until it is closed, and drawing pages makes PDFKit cache decoded images
    /// in the source documents; for scans that is tens of MB per page. So the
    /// output is written in chunks, closing the context and reopening the
    /// sources whenever a chunk reaches `flattenChunkBytes` of output or the
    /// process has grown by `flattenChunkMemoryGrowth` since the chunk
    /// started. Light documents never hit either limit, so shared images
    /// stay shared in one chunk. The chunks are
    /// then joined by copying pages (which doesn't decode anything). Most
    /// documents fit in one chunk and are written exactly as before.
    private func writeFlattened(_ pages: [PageRef], to url: URL, progress: ((Int, Int) -> Bool)?) throws {
        var chunks: [URL] = []
        defer {
            if chunks.count > 1 { chunks.forEach { try? FileManager.default.removeItem(at: $0) } }
        }
        var writer: ChunkWriter?
        var chunkStartFootprint = 0

        for (i, ref) in pages.enumerated() {
            if writer == nil {
                let chunkURL = chunks.isEmpty ? url : url.appendingPathExtension("chunk\(chunks.count)")
                guard let next = ChunkWriter(url: chunkURL) else { throw ExportError.writeFailed(url) }
                writer = next
                chunks.append(chunkURL)
                chunkStartFootprint = MemoryFootprint.bytes()
            }
            let context = writer!.context
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
            let chunkFull = writer!.bytesWritten >= flattenChunkBytes
                || MemoryFootprint.bytes() - chunkStartFootprint >= flattenChunkMemoryGrowth
            if chunkFull, i < pages.count - 1 {
                writer!.close()
                writer = nil
                openDocuments.removeAll()
            }
            if let progress, !progress(i + 1, pages.count) {
                writer?.close()
                throw ExportError.cancelled
            }
        }
        writer?.close()
        writer = nil

        guard chunks.count > 1 else { return }
        // The first chunk was written at `url`; move it aside and join.
        let first = url.appendingPathExtension("chunk0")
        try FileManager.default.moveItem(at: url, to: first)
        chunks[0] = first
        let output = PDFDocument()
        for chunk in chunks {
            guard let document = PDFDocument(url: chunk) else { throw ExportError.writeFailed(url) }
            for index in 0..<document.pageCount {
                try autoreleasepool {
                    guard let page = document.page(at: index)?.copy() as? PDFPage else { throw ExportError.writeFailed(url) }
                    output.insert(page, at: output.pageCount)
                }
            }
        }
        guard output.write(to: url) else { throw ExportError.writeFailed(url) }
    }
}

/// A PDF context writing to a file through a callback consumer that counts
/// the bytes written, so a flattened export knows when to start a new chunk.
private final class ChunkWriter {
    let context: CGContext
    private let state: State
    private var closed = false

    private final class State {
        let file: UnsafeMutablePointer<FILE>
        var bytes = 0
        init(file: UnsafeMutablePointer<FILE>) { self.file = file }
    }

    var bytesWritten: Int { state.bytes }

    init?(url: URL) {
        guard let file = fopen(url.path, "wb") else { return nil }
        let state = State(file: file)
        var callbacks = CGDataConsumerCallbacks(
            putBytes: { info, buffer, count in
                let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
                let written = fwrite(buffer, 1, count, state.file)
                state.bytes += written
                return written
            },
            releaseConsumer: { info in
                let state = Unmanaged<State>.fromOpaque(info!).takeRetainedValue()
                fclose(state.file)
            }
        )
        guard let consumer = CGDataConsumer(info: Unmanaged.passRetained(state).toOpaque(), cbks: &callbacks),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            fclose(file)
            return nil
        }
        self.state = state
        self.context = context
    }

    func close() {
        guard !closed else { return }
        closed = true
        context.closePDF()
        fflush(state.file)
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
