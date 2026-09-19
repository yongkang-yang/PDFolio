import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO
import PDFKit
import PDFolioCore
import UniformTypeIdentifiers

// Plain-executable check runner (XCTest isn't available with Command Line
// Tools alone). Run with: swift run -c release pdfolio-checks [--skip-perf]

var failures = 0
var passes = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    if condition() {
        passes += 1
    } else {
        failures += 1
        print("  ✗ \(message)  (\(file):\(line))")
    }
}

func section(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch {
        failures += 1
        print("  ✗ threw: \(error)")
    }
}

func approx(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.02) -> Bool { abs(a - b) <= tolerance }
func approx(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.02) -> Bool {
    approx(a.minX, b.minX, tolerance) && approx(a.minY, b.minY, tolerance)
        && approx(a.maxX, b.maxX, tolerance) && approx(a.maxY, b.maxY, tolerance)
}

func residentMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("pdfolio-checks-\(getpid())")
try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

/// Writes a PDF whose pages each show a large label and have the given size.
func makePDF(_ name: String, pages: Int, size: CGSize, label: String, rotation: Int = 0) -> URL {
    let url = workDir.appendingPathComponent(name)
    var box = CGRect(origin: .zero, size: size)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
    for i in 0..<pages {
        ctx.beginPDFPage(nil)
        let text = NSAttributedString(string: "\(label) page \(i + 1)", attributes: [.init(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(text)
        ctx.textPosition = CGPoint(x: 40, y: size.height / 2)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    if rotation != 0, let doc = PDFDocument(url: url) {
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation = rotation }
        doc.write(to: url)
    }
    return url
}

/// 200×100 signature whose top half is opaque black and bottom half is
/// transparent, so orientation can be read back from rendered pixels.
func makeSignaturePNG() -> Data {
    let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: 200, height: 100))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 50, width: 200, height: 50))
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

/// Renders a page in display orientation and returns the normalized
/// bounding box (bottom-left origin) of its dark pixels inside `region`.
func darkBox(of page: PDFPage, in region: CGRect) -> CGRect? {
    let box = page.bounds(for: .cropBox)
    let display = PageGeometry.displaySize(box: box.size, rotation: page.rotation)
    let w = Int(display.width), h = Int(display.height)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    page.draw(with: .cropBox, to: ctx)
    let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    let rx0 = Int(region.minX * CGFloat(w)), rx1 = Int(region.maxX * CGFloat(w))
    let ry0 = Int(region.minY * CGFloat(h)), ry1 = Int(region.maxY * CGFloat(h))
    for row in 0..<h {
        let y = h - 1 - row  // bitmap memory is top-down
        guard y >= ry0, y < ry1 else { continue }
        for x in max(0, rx0)..<min(w, rx1) where pixels[(row * w + x) * 4] < 60 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { return nil }
    return CGRect(x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
                  width: CGFloat(maxX - minX + 1) / CGFloat(w), height: CGFloat(maxY - minY + 1) / CGFloat(h))
}

// MARK: - Page list

section("PageList move / remove / duplicate / rotate") {
    let s = UUID()
    let refs = (0..<6).map { PageRef(source: s, pageIndex: $0) }
    func order(_ list: PageList) -> [Int] { list.pages.map(\.pageIndex) }

    var list = PageList(pages: refs, sourceOrder: [s])
    list.move(ids: [refs[0].id], toGap: 3)
    check(order(list) == [1, 2, 0, 3, 4, 5], "move single forward into gap 3")

    list = PageList(pages: refs, sourceOrder: [s])
    list.move(ids: [refs[4].id, refs[5].id], toGap: 1)
    check(order(list) == [0, 4, 5, 1, 2, 3], "move block backward")

    list = PageList(pages: refs, sourceOrder: [s])
    list.move(ids: [refs[0].id, refs[2].id, refs[4].id], toGap: 6)
    check(order(list) == [1, 3, 5, 0, 2, 4], "move non-contiguous selection to end keeps relative order")

    list = PageList(pages: refs, sourceOrder: [s])
    list.move(ids: [refs[1].id, refs[3].id], toGap: 2)
    check(order(list) == [0, 1, 3, 2, 4, 5], "move selection into gap inside itself")

    list = PageList(pages: refs, sourceOrder: [s])
    list.remove(ids: [refs[1].id, refs[2].id])
    check(order(list) == [0, 3, 4, 5], "remove")

    list = PageList(pages: refs, sourceOrder: [s])
    let copies = list.duplicate(ids: [refs[1].id, refs[3].id])
    check(order(list) == [0, 1, 2, 3, 1, 3, 4, 5], "duplicate inserts after last selected")
    check(copies.count == 2 && Set(copies).isDisjoint(with: refs.map(\.id)), "duplicates get new ids")

    list = PageList(pages: refs, sourceOrder: [s])
    list.rotate(ids: [refs[0].id], by: -90)
    check(list.pages[0].rotation == 270, "rotate left normalizes to 270")
    list.rotate(ids: [refs[0].id], by: 90)
    list.rotate(ids: [refs[0].id], by: 90)
    check(list.pages[0].rotation == 90, "rotate accumulates")
}

section("PageList file-level ordering") {
    let a = SourceInfo(displayName: "a", origin: .data(Data()), pageCount: 2, colorIndex: 0)
    let b = SourceInfo(displayName: "b", origin: .data(Data()), pageCount: 3, colorIndex: 1)
    var list = PageList()
    list.addSource(a)
    list.addSource(b)
    // Interleave: move b's first page to the front.
    list.move(ids: [list.pages[2].id], toGap: 0)
    list.reorderSources([b.id, a.id])
    check(list.sourceOrder == [b.id, a.id], "source order updated")
    check(list.pages.map(\.source) == [b.id, b.id, b.id, a.id, a.id], "pages regrouped by file")
    check(list.pages.filter { $0.source == b.id }.map(\.pageIndex) == [0, 1, 2], "within-file order kept")

    var inserted = PageList()
    inserted.addSource(a)
    inserted.addSource(b, at: 1)
    check(inserted.pages.map(\.source) == [a.id, b.id, b.id, b.id, a.id], "insert file between pages")
}

// MARK: - Geometry

section("PageGeometry") {
    let r = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
    for rot in [0, 90, 180, 270] {
        let back = PageGeometry.normalizedDisplayToPage(PageGeometry.normalizedPageToDisplay(r, rotation: rot), rotation: rot)
        check(approx(back, r, 1e-9), "round trip at \(rot)")
    }
    // A clockwise quarter turn moves the page's bottom-left corner to the display's top-left.
    let corner = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
    check(approx(PageGeometry.normalizedPageToDisplay(corner, rotation: 90), CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1), 1e-9), "90° corner mapping")
    check(approx(PageGeometry.normalizedPageToDisplay(corner, rotation: 180), CGRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1), 1e-9), "180° corner mapping")
    check(approx(PageGeometry.normalizedPageToDisplay(corner, rotation: 270), CGRect(x: 0.9, y: 0, width: 0.1, height: 0.1), 1e-9), "270° corner mapping")
    let box = CGRect(x: 20, y: 30, width: 600, height: 400)
    for rot in [0, 90, 180, 270] {
        let t = PageGeometry.pageToDisplay(box: box, rotation: rot)
        let mapped = box.applying(t).standardized
        let size = PageGeometry.displaySize(box: box.size, rotation: rot)
        check(approx(mapped, CGRect(origin: .zero, size: size), 1e-9), "absolute transform fills display at \(rot)")
    }
}

// MARK: - Export

let letter = CGSize(width: 612, height: 792)
let wide = CGSize(width: 800, height: 500)
let alphaURL = makePDF("alpha.pdf", pages: 3, size: letter, label: "Alpha")
let betaURL = makePDF("beta.pdf", pages: 2, size: wide, label: "Beta")
let turnedURL = makePDF("turned.pdf", pages: 1, size: letter, label: "Turned", rotation: 90)

let assets = AssetLibrary()
let sigAsset = assets.add(makeSignaturePNG())

func exportScenario(flatten: Bool) throws {
    let alpha = try SourceLoader.makeSource(url: alphaURL, colorIndex: 0)
    let beta = try SourceLoader.makeSource(url: betaURL, colorIndex: 1)
    let turned = try SourceLoader.makeSource(url: turnedURL, colorIndex: 2)
    let sources = [alpha.id: alpha, beta.id: beta, turned.id: turned]
    var list = PageList()
    list.addSource(alpha)
    list.addSource(beta)
    list.addSource(turned)
    // beta p2, alpha p1, alpha p3 (rotated 90), turned p1 (own /Rotate 90), alpha p2 (signed then rotated)
    let p = list.pages
    list.pages = [p[4], p[0], p[2], p[5], p[1]]
    list.rotate(ids: [p[2].id], by: 90)

    // Signature placed while page shown upright; expected dark area = top half of the rect.
    let displayRect = CGRect(x: 0.55, y: 0.1, width: 0.3, height: 0.1)
    list.updateSignatures(pageID: p[0].id, [PlacedSignature(asset: sigAsset, rect: displayRect, rotation: 0)])
    // Signature on a page with its own 90° rotation, placed as the user sees it.
    let turnedDisplay = CGRect(x: 0.05, y: 0.7, width: 0.35, height: 0.1)
    list.updateSignatures(pageID: p[5].id, [PlacedSignature(asset: sigAsset, rect: PageGeometry.normalizedDisplayToPage(turnedDisplay, rotation: 90), rotation: 90)])
    // Signed upright, then the page is rotated: the signature turns with the content.
    list.updateSignatures(pageID: p[1].id, [PlacedSignature(asset: sigAsset, rect: displayRect, rotation: 0)])
    list.rotate(ids: [p[1].id], by: 90)

    let out = workDir.appendingPathComponent(flatten ? "flat.pdf" : "assembled.pdf")
    var progressCalls = 0
    try PDFExporter(sources: sources, assets: assets).export(list.pages, to: out, options: .init(flatten: flatten)) { _, _ in
        progressCalls += 1
        return true
    }
    check(progressCalls == 5, "progress reported per page")

    guard let doc = PDFDocument(url: out) else { check(false, "exported file opens"); return }
    check(doc.pageCount == 5, "page count")
    let texts = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
    check(texts[0].contains("Beta page 2") && texts[1].contains("Alpha page 1") && texts[2].contains("Alpha page 3")
          && texts[3].contains("Turned page 1") && texts[4].contains("Alpha page 2"),
          "order and selectable text preserved: \(texts)")

    func displaySize(_ i: Int) -> CGSize {
        let page = doc.page(at: i)!
        return PageGeometry.displaySize(box: page.bounds(for: .cropBox).size, rotation: page.rotation)
    }
    check(displaySize(0) == wide, "wide page keeps its size")
    check(displaySize(1) == letter, "letter page keeps its size")
    check(displaySize(2) == CGSize(width: 792, height: 612), "workspace rotation applied")
    check(displaySize(3) == CGSize(width: 792, height: 612), "source's own rotation preserved")

    let annotationCount = (0..<doc.pageCount).reduce(0) { $0 + (doc.page(at: $1)?.annotations.count ?? 0) }
    check(annotationCount == (flatten ? 0 : 3), "signature annotations: \(annotationCount)")

    let signed = darkBox(of: doc.page(at: 1)!, in: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.4))
    check(signed.map { approx($0, CGRect(x: 0.55, y: 0.15, width: 0.3, height: 0.05)) } ?? false,
          "upright signature lands in place, top half dark: \(String(describing: signed))")

    let turnedSig = darkBox(of: doc.page(at: 3)!, in: CGRect(x: 0, y: 0.6, width: 0.45, height: 0.3))
    check(turnedSig.map { approx($0, CGRect(x: 0.05, y: 0.75, width: 0.35, height: 0.05)) } ?? false,
          "signature on pre-rotated page upright as placed: \(String(describing: turnedSig))")

    // Rotated 90° clockwise after signing: the rect moves with the content and
    // the image's top (dark half) now faces right.
    let movedRect = PageGeometry.normalizedPageToDisplay(displayRect, rotation: 90)
    let rightHalf = CGRect(x: movedRect.midX, y: movedRect.minY, width: movedRect.width / 2, height: movedRect.height)
    let rotatedSig = darkBox(of: doc.page(at: 4)!, in: movedRect.insetBy(dx: -0.05, dy: -0.05))
    check(rotatedSig.map { approx($0, rightHalf) } ?? false,
          "signature rotates with page: \(String(describing: rotatedSig)) expected \(rightHalf)")
}

section("Export (assembled, movable signatures)") { try exportScenario(flatten: false) }
section("Export (flattened)") { try exportScenario(flatten: true) }

section("Export safety") {
    let alpha = try SourceLoader.makeSource(url: alphaURL, colorIndex: 0)
    var list = PageList()
    list.addSource(alpha)
    let before = try Data(contentsOf: alphaURL)
    do {
        try PDFExporter(sources: [alpha.id: alpha], assets: assets).export(list.pages, to: alphaURL)
        check(false, "exporting over a source must fail")
    } catch ExportError.wouldOverwriteSource {
        check(true, "")
    }
    let after = try Data(contentsOf: alphaURL)
    check(after == before, "source untouched")

    let out = workDir.appendingPathComponent("cancel.pdf")
    do {
        try PDFExporter(sources: [alpha.id: alpha], assets: assets).export(list.pages, to: out) { _, _ in false }
        check(false, "cancel must throw")
    } catch ExportError.cancelled {
        check(!FileManager.default.fileExists(atPath: out.path), "cancelled export leaves no file")
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: workDir.path).filter { $0.hasSuffix(".partial") }
    check(leftovers.isEmpty, "no partial files left behind")
}

section("Image import") {
    let png = workDir.appendingPathComponent("sig.png")
    try makeSignaturePNG().write(to: png)
    let source = try SourceLoader.makeSource(url: png, colorIndex: 0)
    check(source.pageCount == 1, "image becomes one page")
    let doc = SourceLoader.openDocument(source)
    check(doc?.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 200, height: 100), "72-dpi image keeps point size")
}

section("Imported signature cleanup") {
    // Opaque "scan": white paper with a dark stroke in the middle.
    let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.96, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
    ctx.setFillColor(CGColor(red: 0.1, green: 0.15, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 100, y: 80, width: 200, height: 40))
    let png = SignatureImage.pngData(ctx.makeImage()!)!
    let cleaned = SignatureImage.prepareImported(png)
    let image = cleaned.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    check(image != nil, "cleanup produces an image")
    if let image {
        check(image.width == 208 && image.height == 48, "trimmed to the stroke plus padding: \(image.width)x\(image.height)")
        check(image.alphaInfo != .none && image.alphaInfo != .noneSkipLast, "result has alpha")
    }
    check(SignatureImage.prepareImported(Data([1, 2, 3])) == nil, "garbage input is rejected")
}

// MARK: - Performance

if !CommandLine.arguments.contains("--skip-perf") {
    section("Performance: 1000-page document") {
        let baseline = residentMB()
        let start = Date()
        let bigURL = makePDF("big.pdf", pages: 1000, size: letter, label: "Big")
        print(String(format: "  generated 1000 pages in %.2fs", Date().timeIntervalSince(start)))

        var t = Date()
        let big = try SourceLoader.makeSource(url: bigURL, colorIndex: 0)
        let importTime = Date().timeIntervalSince(t)
        print(String(format: "  import: %.3fs", importTime))
        check(importTime < 2, "import 1000 pages under 2s")

        let renderer = ThumbnailRenderer(assets: assets)
        renderer.register(big)
        t = Date()
        for i in 0..<60 {
            _ = renderer.render(source: big.id, pageIndex: i, signatures: [], maxPixelSize: 360)
        }
        let perThumb = Date().timeIntervalSince(t) / 60
        print(String(format: "  thumbnail @360px: %.1f ms each", perThumb * 1000))
        check(perThumb < 0.05, "thumbnail render under 50ms")

        // Scroll the whole document through the renderer like the grid would,
        // keeping only a bounded window of images alive.
        var window: [CGImage] = []
        var peak = residentMB()
        t = Date()
        for i in 0..<1000 {
            if let image = renderer.render(source: big.id, pageIndex: i, signatures: [], maxPixelSize: 360) {
                window.append(image)
                if window.count > 120 { window.removeFirst() }
            }
            if i % 100 == 0 { peak = max(peak, residentMB()) }
        }
        print(String(format: "  rendered all 1000 thumbnails in %.2fs, peak footprint %.0f MB (baseline %.0f MB)",
                     Date().timeIntervalSince(t), peak, baseline))
        check(peak - baseline < 300, "thumbnail pass stays bounded")

        var list = PageList()
        list.addSource(big)
        let ids = Set(list.pages.enumerated().filter { $0.offset % 2 == 0 }.map(\.element.id))
        t = Date()
        list.move(ids: ids, toGap: 1000)
        list.rotate(ids: ids, by: 90)
        let opTime = Date().timeIntervalSince(t)
        print(String(format: "  move + rotate 500 selected pages: %.1f ms", opTime * 1000))
        check(opTime < 0.1, "large selection ops under 100ms")

        for flatten in [false, true] {
            let out = workDir.appendingPathComponent("big-out-\(flatten).pdf")
            t = Date()
            try PDFExporter(sources: [big.id: big], assets: assets).export(list.pages, to: out, options: .init(flatten: flatten))
            let exportTime = Date().timeIntervalSince(t)
            peak = max(peak, residentMB())
            let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            print(String(format: "  export 1000 pages (%@): %.2fs, %.1f MB file, footprint now %.0f MB",
                         flatten ? "flattened" : "assembled", exportTime, Double(size) / 1_048_576, residentMB()))
            check(exportTime < 30, "export under 30s")
            check(PDFDocument(url: out)?.pageCount == 1000, "exported 1000 pages")
        }
    }
}

// `--perf-file <pdf>`: time thumbnails and both export modes on a real file.
if let i = CommandLine.arguments.firstIndex(of: "--perf-file"), i + 1 < CommandLine.arguments.count {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    section("Performance: \(url.lastPathComponent)") {
        let baseline = residentMB()
        let source = try SourceLoader.makeSource(url: url, colorIndex: 0)
        var list = PageList()
        list.addSource(source)
        let renderer = ThumbnailRenderer(assets: assets)
        renderer.register(source)
        var t = Date()
        var window: [CGImage] = []
        var peak = baseline
        for i in 0..<source.pageCount {
            if let image = renderer.render(source: source.id, pageIndex: i, signatures: [], maxPixelSize: 384) {
                window.append(image)
                if window.count > 120 { window.removeFirst() }
            }
            if i % 50 == 0 { peak = max(peak, residentMB()) }
        }
        print(String(format: "  %d thumbnails @384px: %.1f ms each, peak footprint %.0f MB (baseline %.0f MB)",
                     source.pageCount, Date().timeIntervalSince(t) * 1000 / Double(source.pageCount), peak, baseline))
        window.removeAll()
        list.updateSignatures(pageID: list.pages[0].id, [PlacedSignature(asset: sigAsset, rect: CGRect(x: 0.5, y: 0.1, width: 0.3, height: 0.08), rotation: 0)])
        list.rotate(ids: Set(list.pages.prefix(10).map(\.id)), by: 90)
        for flatten in [false, true] {
            let out = workDir.appendingPathComponent("perf-\(flatten).pdf")
            t = Date()
            var exportPeak = residentMB()
            try PDFExporter(sources: [source.id: source], assets: assets).export(list.pages, to: out, options: .init(flatten: flatten)) { done, _ in
                if done % 50 == 0 { exportPeak = max(exportPeak, residentMB()) }
                return true
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            let inBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print(String(format: "  export %@: %.2fs, peak footprint %.0f MB, %.1f MB → %.1f MB",
                         flatten ? "flattened" : "assembled", Date().timeIntervalSince(t), exportPeak,
                         Double(inBytes) / 1_048_576, Double(bytes) / 1_048_576))
            check(PDFDocument(url: out)?.pageCount == source.pageCount, "exported every page")
        }
    }
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
