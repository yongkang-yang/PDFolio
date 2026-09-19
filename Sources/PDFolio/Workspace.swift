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
    /// PDFKit documents for main-thread use (page sizes, the signing view).
    private var documents: [SourceID: PDFDocument] = [:]

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

    func document(for source: SourceID) -> PDFDocument? {
        if let doc = documents[source] { return doc }
        guard let info = sources[source], let doc = SourceLoader.openDocument(info) else { return nil }
        documents[source] = doc
        return doc
    }

    func pdfPage(for ref: PageRef) -> PDFPage? {
        document(for: ref.source)?.page(at: ref.pageIndex)
    }

    /// The page's size as displayed, including workspace rotation.
    func displaySize(of ref: PageRef) -> CGSize {
        guard let page = pdfPage(for: ref) else { return CGSize(width: 612, height: 792) }
        return PageGeometry.displaySize(
            box: page.bounds(for: .cropBox).size,
            rotation: page.rotation + ref.rotation
        )
    }

    func sourceRotation(of ref: PageRef) -> Int {
        pdfPage(for: ref)?.rotation ?? 0
    }

    func purgeCaches() {
        documents.removeAll()
        thumbnails.purge()
    }
}
