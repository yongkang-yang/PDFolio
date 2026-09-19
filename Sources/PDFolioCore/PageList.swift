import Foundation

/// The ordered page sequence being organized, plus the file-level order of the
/// sources that feed it. A plain value type, so undo is just "restore the
/// previous value" and every operation here can be checked without any UI.
public struct PageList: Equatable {
    public var pages: [PageRef]
    public var sourceOrder: [SourceID]

    public init(pages: [PageRef] = [], sourceOrder: [SourceID] = []) {
        self.pages = pages
        self.sourceOrder = sourceOrder
    }

    public func indices(of ids: Set<UUID>) -> [Int] {
        pages.indices.filter { ids.contains(pages[$0].id) }
    }

    /// Appends every page of a newly imported source, or inserts them at
    /// `index` when given (e.g. a file dropped between two pages).
    public mutating func addSource(_ source: SourceInfo, at index: Int? = nil) -> [UUID] {
        if !sourceOrder.contains(source.id) {
            sourceOrder.append(source.id)
        }
        let newPages = (0..<source.pageCount).map { PageRef(source: source.id, pageIndex: $0) }
        insert(newPages, at: index ?? pages.count)
        return newPages.map(\.id)
    }

    public mutating func insert(_ newPages: [PageRef], at index: Int) {
        let clamped = max(0, min(index, pages.count))
        pages.insert(contentsOf: newPages, at: clamped)
    }

    /// Moves the given pages, keeping their relative order, so they land in
    /// the gap that was at `gapIndex` before the move (0 = before the first
    /// page, `pages.count` = after the last). This is the index a drop
    /// indicator between two thumbnails naturally reports.
    public mutating func move(ids: Set<UUID>, toGap gapIndex: Int) {
        let moving = pages.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        let removedBeforeGap = pages[..<max(0, min(gapIndex, pages.count))]
            .filter { ids.contains($0.id) }
            .count
        pages.removeAll { ids.contains($0.id) }
        insert(moving, at: gapIndex - removedBeforeGap)
    }

    public mutating func remove(ids: Set<UUID>) {
        pages.removeAll { ids.contains($0.id) }
    }

    /// Rotates by a multiple of 90° (positive = clockwise).
    public mutating func rotate(ids: Set<UUID>, by degrees: Int) {
        for i in pages.indices where ids.contains(pages[i].id) {
            pages[i].rotation = normalizedRotation(pages[i].rotation + degrees)
        }
    }

    /// Inserts a copy of the selection right after the last selected page and
    /// returns the copies' ids.
    @discardableResult
    public mutating func duplicate(ids: Set<UUID>) -> [UUID] {
        let selected = indices(of: ids)
        guard let last = selected.last else { return [] }
        let copies = selected.map { pages[$0].duplicated() }
        insert(copies, at: last + 1)
        return copies.map(\.id)
    }

    /// Reorders the file-level list and regroups pages to match: each file's
    /// pages become one contiguous block in the new file order, keeping
    /// their relative order within the file.
    public mutating func reorderSources(_ newOrder: [SourceID]) {
        let known = Set(sourceOrder)
        let order = newOrder.filter { known.contains($0) }
            + sourceOrder.filter { !newOrder.contains($0) }
        sourceOrder = order
        var buckets: [SourceID: [PageRef]] = [:]
        for page in pages {
            buckets[page.source, default: []].append(page)
        }
        pages = order.flatMap { buckets[$0] ?? [] }
    }

    /// Removes a file from the workspace: all of its pages (including
    /// duplicates) and its entry in the file order.
    public mutating func removeSource(_ id: SourceID) {
        pages.removeAll { $0.source == id }
        sourceOrder.removeAll { $0 == id }
    }

    /// Moves a file to the front or back of the file order, regrouping pages
    /// the same way dragging it in the sidebar does.
    public mutating func moveSource(_ id: SourceID, toFront: Bool) {
        guard sourceOrder.contains(id) else { return }
        let others = sourceOrder.filter { $0 != id }
        reorderSources(toFront ? [id] + others : others + [id])
    }

    /// Page indices of a file that no longer appear in the workspace.
    public func missingPageIndices(of source: SourceInfo) -> [Int] {
        let present = Set(pages.filter { $0.source == source.id }.map(\.pageIndex))
        return (0..<source.pageCount).filter { !present.contains($0) }
    }

    /// Puts a file's deleted pages back, each right after the closest earlier
    /// page of the same file that is still present (or before the closest
    /// later one), so they return to their original place in the file's
    /// run of pages. Returns the restored pages' ids.
    @discardableResult
    public mutating func restoreMissingPages(of source: SourceInfo) -> [UUID] {
        var restored: [UUID] = []
        for index in missingPageIndices(of: source) {
            let page = PageRef(source: source.id, pageIndex: index)
            let sameFile = pages.indices.filter { pages[$0].source == source.id }
            if let before = sameFile.last(where: { pages[$0].pageIndex < index }) {
                pages.insert(page, at: before + 1)
            } else if let after = sameFile.first(where: { pages[$0].pageIndex > index }) {
                pages.insert(page, at: after)
            } else {
                pages.append(page)
            }
            restored.append(page.id)
        }
        if !restored.isEmpty, !sourceOrder.contains(source.id) {
            sourceOrder.append(source.id)
        }
        return restored
    }

    public mutating func updateSignatures(pageID: UUID, _ signatures: [PlacedSignature]) {
        guard let i = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[i].signatures = signatures
    }
}
