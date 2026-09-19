import AppKit
import PDFolioCore

enum SourceAction {
    case remove, read, showInFinder, export, moveToTop, moveToBottom, restoreDeletedPages
}

protocol SourceListDelegate: AnyObject {
    func sourceList(_ list: SourceListViewController, didSelect source: SourceID)
    func sourceList(_ list: SourceListViewController, importFiles urls: [URL])
    func sourceList(_ list: SourceListViewController, perform action: SourceAction, on source: SourceID)
}

/// Table that removes the selected file on ⌫.
final class SourceTableView: NSTableView {
    var onDelete: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), selectedRow >= 0 {
            onDelete?(selectedRow)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Sidebar listing imported files. Dragging a file reorders at file level:
/// each file's pages are regrouped into one block in the new order.
final class SourceListViewController: NSViewController {
    private static let rowType = NSPasteboard.PasteboardType("com.yongkang.pdfolio.source")

    let workspace: Workspace
    weak var delegate: SourceListDelegate?
    private let tableView = SourceTableView()
    private var rows: [SourceInfo] = []
    private var pagesInUse: [SourceID: Int] = [:]

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("file"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowHeight = 40
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.rowType, .fileURL])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.onDelete = { [weak self] row in self?.perform(.remove, row: row) }
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let header = NSTextField(labelWithString: "Files")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let hint = NSTextField(wrappingLabelWithString: "Drag files to reorder them as whole blocks. Click a file to select its pages; right-click for more.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let root = NSView()
        for v in [header, scroll, hint] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        view = root
    }

    func reload() {
        rows = workspace.orderedSources
        pagesInUse = workspace.pages.reduce(into: [:]) { $0[$1.source, default: 0] += 1 }
        tableView.reloadData()
    }

    /// The selected file when the sidebar has keyboard focus, so ⌫ (routed
    /// through the Edit menu) removes the file rather than its pages.
    var focusedSource: SourceID? {
        guard view.window?.firstResponder === tableView,
              tableView.selectedRow >= 0, tableView.selectedRow < rows.count
        else { return nil }
        return rows[tableView.selectedRow].id
    }

    private func perform(_ action: SourceAction, row: Int) {
        guard row >= 0, row < rows.count else { return }
        delegate?.sourceList(self, perform: action, on: rows[row].id)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? SourceAction else { return }
        perform(action, row: sender.tag)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        delegate?.sourceList(self, didSelect: rows[row].id)
    }
}

extension SourceListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SourceCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SourceCell ?? SourceCell()
        cell.identifier = id
        let source = rows[row]
        cell.configure(source: source, inUse: pagesInUse[source.id] ?? 0)
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(rows[row].id.uuidString, forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if info.draggingSource as? NSTableView === tableView {
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if info.draggingSource as? NSTableView === tableView {
            guard let idString = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType),
                  let id = UUID(uuidString: idString),
                  let from = rows.firstIndex(where: { $0.id == id })
            else { return false }
            var order = rows.map(\.id)
            order.remove(at: from)
            order.insert(id, at: from < row ? row - 1 : row)
            workspace.reorderSources(order)
            return true
        }
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(SourceLoader.isSupported)
        guard !urls.isEmpty else { return false }
        delegate?.sourceList(self, importFiles: urls)
        return true
    }
}

final class SourceCell: NSTableCellView {
    private let dot = NSView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        for v in [dot, name, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2)
        ])
        textField = name
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(source: SourceInfo, inUse: Int) {
        dot.layer?.backgroundColor = Palette.color(for: source.colorIndex).cgColor
        name.stringValue = source.displayName
        toolTip = source.displayName
        let total = source.pageCount == 1 ? "1 page" : "\(source.pageCount) pages"
        detail.stringValue = inUse == source.pageCount ? total : "\(inUse) of \(total) in use"
    }
}

extension SourceListViewController: NSMenuDelegate {
    /// Builds the right-click menu for the clicked file.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        let source = rows[row]
        let inUse = pagesInUse[source.id] ?? 0
        let missing = source.pageCount - inUse

        func add(_ title: String, _ symbol: String, _ action: SourceAction, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? #selector(menuAction(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.tag = row
            item.representedObject = action
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }

        add("Read This File", "book", .read, enabled: inUse > 0)
        add("Show in Finder", "folder", .showInFinder,
            enabled: source.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        add("Export Only This File…", "square.and.arrow.up", .export, enabled: inUse > 0)
        menu.addItem(.separator())
        add("Move to Top", "arrow.up.to.line", .moveToTop, enabled: row > 0)
        add("Move to Bottom", "arrow.down.to.line", .moveToBottom, enabled: row < rows.count - 1)
        if missing > 0 {
            add(missing == 1 ? "Restore 1 Deleted Page" : "Restore \(missing) Deleted Pages", "arrow.uturn.backward", .restoreDeletedPages)
        }
        menu.addItem(.separator())
        add("Remove from Workspace", "minus.circle", .remove)
        menu.items.last?.keyEquivalent = "\u{8}"
        menu.items.last?.keyEquivalentModifierMask = []
    }
}
