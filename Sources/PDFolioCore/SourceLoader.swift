import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum SourceLoaderError: LocalizedError {
    case unreadable(URL)
    case locked(URL)
    case wrongPassword(URL)
    case empty(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "“\(url.lastPathComponent)” isn’t a PDF or image that can be opened."
        case .locked(let url): return "“\(url.lastPathComponent)” is password protected."
        case .wrongPassword(let url): return "The password for “\(url.lastPathComponent)” is incorrect."
        case .empty(let url): return "“\(url.lastPathComponent)” has no pages."
        }
    }
}

public enum SourceLoader {
    /// Imported images are scaled down so their longest side is at most this
    /// many points (A4's long side), so a phone photo inserted between letter
    /// pages doesn't become a poster-sized page.
    public static let maxImagePageSide: CGFloat = 842

    public static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .pdf)
    }

    public static func isSupported(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf" || isImage(url)
    }

    /// Builds a source from a file. Throws `.locked` when a password is needed
    /// and none (or `.wrongPassword` when a wrong one) was supplied.
    public static func makeSource(url: URL, password: String? = nil, colorIndex: Int) throws -> SourceInfo {
        if isImage(url) {
            let data = try pdfData(fromImageAt: url)
            return SourceInfo(
                displayName: url.lastPathComponent,
                origin: .data(data),
                fileURL: url,
                pageCount: 1,
                colorIndex: colorIndex
            )
        }
        guard let doc = PDFDocument(url: url) else { throw SourceLoaderError.unreadable(url) }
        if doc.isLocked {
            guard let password else { throw SourceLoaderError.locked(url) }
            guard doc.unlock(withPassword: password) else { throw SourceLoaderError.wrongPassword(url) }
        }
        guard doc.pageCount > 0 else { throw SourceLoaderError.empty(url) }
        return SourceInfo(
            displayName: url.lastPathComponent,
            origin: .file(url),
            pageCount: doc.pageCount,
            password: password,
            colorIndex: colorIndex
        )
    }

    /// Opens a new, independent `PDFDocument` for a source. PDFKit documents
    /// aren't safe to share across threads, so each consumer (UI, thumbnail
    /// renderer, exporter) opens its own.
    public static func openDocument(_ source: SourceInfo) -> PDFDocument? {
        let doc: PDFDocument?
        switch source.origin {
        case .file(let url): doc = PDFDocument(url: url)
        case .data(let data): doc = PDFDocument(data: data)
        }
        if let doc, doc.isLocked, let password = source.password {
            doc.unlock(withPassword: password)
        }
        return doc
    }

    /// Wraps an image in a one-page PDF, honoring EXIF orientation and DPI.
    public static func pdfData(fromImageAt url: URL) throws -> Data {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pxW = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let pxH = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { throw SourceLoaderError.unreadable(url) }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pxW, pxH)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw SourceLoaderError.unreadable(url)
        }
        let dpi = (props[kCGImagePropertyDPIWidth] as? CGFloat).flatMap { $0 > 0 ? $0 : nil } ?? 72
        var size = CGSize(width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
        let longest = max(size.width, size.height)
        if longest > maxImagePageSide {
            let s = maxImagePageSide / longest
            size = CGSize(width: size.width * s, height: size.height * s)
        }
        return pdfData(pageSize: size) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
        }
    }

    static func pdfData(pageSize: CGSize, draw: (CGContext) -> Void) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return Data() }
        ctx.beginPDFPage(nil)
        draw(ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
