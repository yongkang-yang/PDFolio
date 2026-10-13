import AppKit
import PDFKit
import PDFolioCore

/// Everything one window is organizing: the imported sources, the page
/// sequence, and the signature images placed on pages. All page edits go
/// through `apply`, which records the previous `PageList` for undo.
final class Workspace {
    enum Change {
        case pages
        case sources
    }

    private(set) var sources: [SourceID: SourceInfo] = [:]
    private(set) var list = PageList()
    let assets = AssetLibrary()
    let undoManager = UndoManager()
    let thumbnails: ThumbnailCache

    /// Set after any edit, cleared by a successful full export.
    var hasUnexportedChanges = false

    private var observers: [(Change) -> Void] = []
    /// Each source page's crop-box size and own rotation, read once per
    /// source. The grid and the reader only need these numbers, so no parsed
    /// document stays in memory for them.
    private var geometry: [SourceID: [(size: CGSize, rotation: Int)]] = [:]

    init() {
        thumbnails = ThumbnailCache(assets: assets)
    }

    var pages: [PageRef] { list.pages }

    var orderedSources: [SourceInfo] {
        list.sourceOrder.compactMap { sources[$0] }
    }

    func observe(_ handler: @escaping (Change) -> Void) {
        observers.append(handler)
    }

    private func notify(_ change: Change) {
        observers.forEach { $0(change) }
    }

    // MARK: Editing

    /// Applies an undoable edit to the page list.
    func apply(_ actionName: String, _ edit: (inout PageList) -> Void) {
        let before = list
        edit(&list)
        guard list != before else { return }
        registerUndo(restoring: before, actionName: actionName)
        hasUnexportedChanges = true
        notify(.pages)
    }

    private func registerUndo(restoring previous: PageList, actionName: String) {
        undoManager.registerUndo(withTarget: self) { workspace in
            let current = workspace.list
            workspace.list = previous
            workspace.registerUndo(restoring: current, actionName: actionName)
            workspace.hasUnexportedChanges = true
            workspace.notify(.pages)
            workspace.notify(.sources)
        }
        undoManager.setActionName(actionName)
    }

    /// Registers new sources and inserts their pages at `gap` (or appends).
    /// Returns the new page ids.
    @discardableResult
    func add(_ newSources: [SourceInfo], at gap: Int? = nil) -> [UUID] {
        guard !newSources.isEmpty else { return [] }
        for source in newSources {
            sources[source.id] = source
            thumbnails.register(source)
        }
        var inserted: [UUID] = []
        apply(newSources.count == 1 ? "Add \(newSources[0].displayName)" : "Add Files") { list in
            var position = gap
            for source in newSources {
                let ids = list.addSource(source, at: position)
                inserted += ids
                position = position.map { $0 + ids.count }
            }
        }
        notify(.sources)
        return inserted
    }

    func reorderSources(_ order: [SourceID]) {
        apply("Reorder Files") { $0.reorderSources(order) }
        notify(.sources)
    }

    var nextColorIndex: Int { sources.count }

    // MARK: Page info

    /// A page from a freshly opened document, for the signing view. The page
    /// keeps its document alive, so it is released along with the view.
    func pdfPage(for ref: PageRef) -> PDFPage? {
        guard let info = sources[ref.source] else { return nil }
        return SourceLoader.openDocument(info)?.page(at: ref.pageIndex)
    }

    private func pageGeometry(of ref: PageRef) -> (size: CGSize, rotation: Int)? {
        if geometry[ref.source] == nil, let info = sources[ref.source] {
            geometry[ref.source] = autoreleasepool {
                guard let doc = SourceLoader.openDocument(info) else { return [] }
                return (0..<doc.pageCount).map { index in
                    guard let page = doc.page(at: index) else { return (CGSize(width: 612, height: 792), 0) }
                    return (page.bounds(for: .cropBox).size, page.rotation)
                }
            }
        }
        guard let pages = geometry[ref.source], pages.indices.contains(ref.pageIndex) else { return nil }
        return pages[ref.pageIndex]
    }

    /// The page's size as displayed, including workspace rotation.
    func displaySize(of ref: PageRef) -> CGSize {
        guard let page = pageGeometry(of: ref) else { return CGSize(width: 612, height: 792) }
        return PageGeometry.displaySize(box: page.size, rotation: page.rotation + ref.rotation)
    }

    func sourceRotation(of ref: PageRef) -> Int {
        pageGeometry(of: ref)?.rotation ?? 0
    }

    func purgeCaches() {
        thumbnails.purge()
    }
}
