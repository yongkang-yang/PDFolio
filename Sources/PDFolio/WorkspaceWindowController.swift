import AppKit
import PDFolioCore
import UniformTypeIdentifiers

/// One workspace window: file sidebar, page grid, toolbar, and the import /
/// export / signing flows.
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    let workspace = Workspace()
    private let grid: PageGridViewController
    private let sidebar: SourceListViewController
    private let split = NSSplitViewController()
    private let zoomSlider = NSSlider(value: 170, minValue: Double(PageGridViewController.minZoom),
                                      maxValue: Double(PageGridViewController.maxZoom), target: nil, action: nil)
    var onClose: (() -> Void)?

    init() {
        grid = PageGridViewController(workspace: workspace)
        sidebar = SourceListViewController(workspace: workspace)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "PDFolio"
        window.minSize = NSSize(width: 640, height: 420)
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("WorkspaceWindow")
        super.init(window: window)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: grid)
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1180, height: 780))
        if window.frameAutosaveName.isEmpty || !window.setFrameUsingName("WorkspaceWindow") {
            window.center()
        }
        window.delegate = self

        let toolbar = NSToolbar(identifier: "Workspace")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        grid.delegate = self
        sidebar.delegate = self
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomSliderChanged(_:))
        zoomSlider.doubleValue = Double(grid.zoom)

        workspace.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .pages:
                self.grid.reload()
                self.sidebar.reload()
                self.updateTitle()
            case .sources:
                self.sidebar.reload()
            }
        }
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Title / state

    private func updateTitle() {
        guard let window else { return }
        let pages = workspace.pages.count
        let files = workspace.sources.count
        if pages == 0 {
            window.subtitle = ""
        } else {
            let selected = grid.selectedIDs.count
            var parts = ["\(files) \(files == 1 ? "file" : "files")", "\(pages) \(pages == 1 ? "page" : "pages")"]
            if selected > 0 { parts.append("\(selected) selected") }
            window.subtitle = parts.joined(separator: " · ")
        }
        window.isDocumentEdited = workspace.hasUnexportedChanges && pages > 0
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        workspace.undoManager
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard workspace.hasUnexportedChanges, !workspace.pages.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Close without exporting?"
        alert.informativeText = "Your page arrangement and signatures haven’t been exported. Your original files are unchanged either way."
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Without Exporting").hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.export(pages: nil, closeAfter: true)
            case .alertThirdButtonReturn:
                self?.workspace.hasUnexportedChanges = false
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: Import

    @objc func addFiles(_ sender: Any?) {
        chooseFiles(message: "Choose PDFs or images to add.") { [weak self] urls in
            self?.importFiles(urls, atGap: nil)
        }
    }

    @objc func insertFiles(_ sender: Any?) {
        let gap = grid.selectedIndices.last.map { $0 + 1 }
        chooseFiles(message: gap == nil ? "Choose PDFs or images to add." : "Choose PDFs or images to insert after the selected page.") { [weak self] urls in
            self?.importFiles(urls, atGap: gap)
        }
    }

    private func chooseFiles(message: String, completion: @escaping ([URL]) -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .image]
        panel.message = message
        panel.beginSheetModal(for: window) { response in
            if response == .OK { completion(panel.urls) }
        }
    }

    /// Imports files, asking for passwords where needed, and inserts all of
    /// their pages as one undoable step.
    func importFiles(_ urls: [URL], atGap gap: Int?) {
        var loaded: [SourceInfo] = []
        var errors: [String] = []
        for url in urls where SourceLoader.isSupported(url) {
            var password: String?
            while true {
                do {
                    loaded.append(try SourceLoader.makeSource(url: url, password: password,
                                                              colorIndex: workspace.nextColorIndex + loaded.count))
                    break
                } catch SourceLoaderError.locked(let u), SourceLoaderError.wrongPassword(let u) {
                    guard let entered = askPassword(for: u, retry: password != nil) else { break }
                    password = entered
                } catch {
                    errors.append(error.localizedDescription)
                    break
                }
            }
        }
        let ids = workspace.add(loaded, at: gap)
        if !ids.isEmpty {
            grid.select(Set(ids))
        }
        if !errors.isEmpty, let window {
            let alert = NSAlert()
            alert.messageText = errors.count == 1 ? "A file couldn’t be added" : "Some files couldn’t be added"
            alert.informativeText = errors.joined(separator: "\n")
            alert.beginSheetModal(for: window)
        }
    }

    private func askPassword(for url: URL, retry: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = retry ? "Incorrect password for “\(url.lastPathComponent)”" : "“\(url.lastPathComponent)” is password protected"
        alert.informativeText = "Enter the password to open it. The file itself stays unchanged."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Skip")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: Page actions

    @objc func rotateLeft(_ sender: Any?) { grid.rotateSelection(by: -90) }
    @objc func rotateRight(_ sender: Any?) { grid.rotateSelection(by: 90) }
    @objc func delete(_ sender: Any?) { grid.deleteSelection() }

    @objc func duplicatePages(_ sender: Any?) {
        let ids = grid.selectedIDs
        guard !ids.isEmpty else { return }
        var copies: [UUID] = []
        workspace.apply(ids.count == 1 ? "Duplicate Page" : "Duplicate Pages") { copies = $0.duplicate(ids: ids) }
        grid.select(Set(copies))
    }

    override func selectAll(_ sender: Any?) {
        grid.select(Set(workspace.pages.map(\.id)), scroll: false)
    }

    @objc func signPage(_ sender: Any?) {
        guard let index = grid.selectedIndices.first else { return }
        openSigning(pageID: workspace.pages[index].id)
    }

    private func openSigning(pageID: UUID) {
        guard let controller = PageSigningController(workspace: workspace, pageID: pageID) else { return }
        controller.onDone = { [weak self] signatures in
            guard let self else { return }
            let hadSignatures = !(self.workspace.pages.first { $0.id == pageID }?.signatures.isEmpty ?? true)
            self.workspace.apply(signatures.isEmpty && hadSignatures ? "Remove Signature" : "Sign Page") {
                $0.updateSignatures(pageID: pageID, signatures)
            }
        }
        split.presentAsSheet(controller)
    }

    // MARK: Zoom

    @objc func zoomIn(_ sender: Any?) { grid.zoom(by: 1.2) }
    @objc func zoomOut(_ sender: Any?) { grid.zoom(by: 1 / 1.2) }

    @objc private func zoomSliderChanged(_ sender: NSSlider) {
        grid.setZoom(CGFloat(sender.doubleValue))
    }

    // MARK: Export

    @objc func exportPDF(_ sender: Any?) { export(pages: nil, closeAfter: false) }

    @objc func extractPages(_ sender: Any?) {
        let selected = grid.selectedIndices.map { workspace.pages[$0] }
        guard !selected.isEmpty else { return }
        export(pages: selected, closeAfter: false)
    }

    /// Exports `pages` (or the whole workspace) through a save panel with a
    /// flatten option, running the write in the background with progress.
    private func export(pages subset: [PageRef]?, closeAfter: Bool) {
        guard let window else { return }
        let pages = subset ?? workspace.pages
        guard !pages.isEmpty else { NSSound.beep(); return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultExportName(extracting: subset != nil)
        let flatten = NSButton(checkboxWithTitle: "Flatten signatures so they can’t be moved or removed", target: nil, action: nil)
        flatten.state = UserDefaults.standard.bool(forKey: "flattenOnExport") ? .on : .off
        let note = NSTextField(wrappingLabelWithString: "Page content stays vector. Flattening also makes links and form fields static.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 380
        let accessory = NSStackView(views: [flatten, note])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 4
        accessory.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        panel.accessoryView = accessory

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(flatten.state == .on, forKey: "flattenOnExport")
            self.runExport(pages, to: url, options: ExportOptions(flatten: flatten.state == .on), isFull: subset == nil, closeAfter: closeAfter)
        }
    }

    private func defaultExportName(extracting: Bool) -> String {
        if extracting { return "Extracted Pages.pdf" }
        let names = workspace.orderedSources.map { ($0.displayName as NSString).deletingPathExtension }
        if names.count == 1, let name = names.first { return "\(name) (edited).pdf" }
        return "Combined.pdf"
    }

    private func runExport(_ pages: [PageRef], to url: URL, options: ExportOptions, isFull: Bool, closeAfter: Bool) {
        guard let window else { return }
        let progress = ExportProgressController(total: pages.count)
        // Only show the progress sheet if the export takes noticeable time.
        var sheetShown = false
        let showTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            sheetShown = true
            window.contentViewController?.presentAsSheet(progress)
        }

        let exporter = PDFExporter(sources: workspace.sources, assets: workspace.assets)
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error> = Result {
                try exporter.export(pages, to: url, options: options) { done, total in
                    DispatchQueue.main.async { progress.update(done: done, total: total) }
                    return !progress.isCancelled
                }
            }
            DispatchQueue.main.async {
                showTimer.invalidate()
                if sheetShown { progress.dismiss(nil) }
                switch result {
                case .success:
                    NSLog("PDFolio: exported %d pages in %.2fs (flatten: %@), footprint %.0f MB",
                          pages.count, Date().timeIntervalSince(started), options.flatten ? "yes" : "no", MemoryStats.footprintMB())
                    if isFull {
                        self.workspace.hasUnexportedChanges = false
                        self.updateTitle()
                    }
                    if closeAfter { window.close() }
                case .failure(ExportError.cancelled):
                    break
                case .failure(let error):
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
    }

    // MARK: Validation

    private func isEnabled(_ action: Selector?) -> Bool {
        let hasSelection = !grid.selectedIDs.isEmpty
        switch action {
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)), #selector(delete(_:)),
             #selector(duplicatePages(_:)), #selector(extractPages(_:)):
            return hasSelection
        case #selector(signPage(_:)):
            return grid.selectedIDs.count == 1
        case #selector(exportPDF(_:)), #selector(selectAll(_:)):
            return !workspace.pages.isEmpty
        default:
            return true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isEnabled(menuItem.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isEnabled(item.action)
    }

    // MARK: Toolbar

    private enum Item {
        static let add = NSToolbarItem.Identifier("add")
        static let rotateLeft = NSToolbarItem.Identifier("rotateLeft")
        static let rotateRight = NSToolbarItem.Identifier("rotateRight")
        static let duplicate = NSToolbarItem.Identifier("duplicate")
        static let delete = NSToolbarItem.Identifier("delete")
        static let insert = NSToolbarItem.Identifier("insert")
        static let extract = NSToolbarItem.Identifier("extract")
        static let sign = NSToolbarItem.Identifier("sign")
        static let zoom = NSToolbarItem.Identifier("zoom")
        static let export = NSToolbarItem.Identifier("export")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Item.add, .flexibleSpace,
         Item.rotateLeft, Item.rotateRight, Item.duplicate, Item.delete, .space,
         Item.insert, Item.extract, .space, Item.sign, .flexibleSpace, Item.zoom, Item.export]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector, _ tip: String) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = tip
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
            item.target = self
            item.isBordered = true
            return item
        }
        switch id {
        case Item.add: return button("Add Files", "plus", #selector(addFiles(_:)), "Add PDFs or images (⌘O)")
        case Item.rotateLeft: return button("Rotate Left", "rotate.left", #selector(rotateLeft(_:)), "Rotate selected pages left (⌘L)")
        case Item.rotateRight: return button("Rotate Right", "rotate.right", #selector(rotateRight(_:)), "Rotate selected pages right (⌘R)")
        case Item.duplicate: return button("Duplicate", "plus.square.on.square", #selector(duplicatePages(_:)), "Duplicate selected pages (⌘D)")
        case Item.delete: return button("Delete", "trash", #selector(delete(_:)), "Delete selected pages (⌫)")
        case Item.insert: return button("Insert", "doc.badge.plus", #selector(insertFiles(_:)), "Insert a PDF or image after the selection (⇧⌘I)")
        case Item.extract: return button("Extract", "square.and.arrow.up.on.square", #selector(extractPages(_:)), "Save selected pages as a new PDF (⇧⌘E)")
        case Item.sign: return button("Sign", "signature", #selector(signPage(_:)), "Add a signature to the selected page (⇧⌘S)")
        case Item.zoom:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Thumbnail Size"
            item.paletteLabel = "Thumbnail Size"
            zoomSlider.controlSize = .small
            zoomSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
            item.view = zoomSlider
            item.toolTip = "Thumbnail size — or pinch on the trackpad"
            return item
        case Item.export:
            let item = button("Export", "square.and.arrow.up", #selector(exportPDF(_:)), "Export as one PDF (⌘E)")
            if #available(macOS 26.0, *) { item.style = .prominent }
            return item
        default:
            return nil
        }
    }

    // MARK: Benchmark / snapshots

    func runSnapshot(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let window = self.window, let first = self.workspace.pages.first else { return }
            // Exercise a few edits so the snapshot shows real state.
            self.grid.select([first.id])
            self.rotateRight(nil)
            if self.workspace.pages.count > 3 {
                self.grid.select([self.workspace.pages[1].id, self.workspace.pages[3].id], scroll: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                DebugSnapshot.write(window, to: directory.appendingPathComponent("workspace.png"))
                self.openSigning(pageID: self.workspace.pages[1].id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let sheet = window.attachedSheet,
                       let signing = sheet.contentViewController as? PageSigningController {
                        signing.debugPlaceSampleSignature()
                        DebugSnapshot.write(sheet, to: directory.appendingPathComponent("signing.png"))
                        signing.dismiss(nil)
                    }
                    let pad = SignaturePadController()
                    self.split.presentAsSheet(pad)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if let sheet = window.attachedSheet {
                            DebugSnapshot.write(sheet, to: directory.appendingPathComponent("pad.png"))
                        }
                        pad.dismiss(nil)
                        self.workspace.hasUnexportedChanges = false
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    func runScrollBenchmark(quitAfter: Bool) {
        // Let the window lay out and first thumbnails load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let before = MemoryStats.footprintMB()
            self.grid.runScrollBenchmark { report in
                let message = String(format: "PDFolio benchmark: footprint before scroll %.0f MB; %@", before, report)
                print(message)
                NSLog("%@", message)
                if quitAfter {
                    self.workspace.hasUnexportedChanges = false
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

extension WorkspaceWindowController: PageGridDelegate, SourceListDelegate {
    func pageGrid(_ grid: PageGridViewController, openPage id: UUID) {
        openSigning(pageID: id)
    }

    func pageGrid(_ grid: PageGridViewController, importFiles urls: [URL], atGap gap: Int?) {
        importFiles(urls, atGap: gap)
    }

    func pageGridSelectionDidChange(_ grid: PageGridViewController) {
        updateTitle()
        window?.toolbar?.validateVisibleItems()
    }

    func pageGridZoomDidChange(_ grid: PageGridViewController) {
        zoomSlider.doubleValue = Double(grid.zoom)
    }

    func sourceList(_ list: SourceListViewController, didSelect source: SourceID) {
        grid.select(Set(workspace.pages.filter { $0.source == source }.map(\.id)))
        window?.makeFirstResponder(grid.collectionView)
    }

    func sourceList(_ list: SourceListViewController, importFiles urls: [URL]) {
        importFiles(urls, atGap: nil)
    }
}

/// Progress sheet for long exports.
final class ExportProgressController: NSViewController {
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Exporting…")
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    init(total: Int) {
        super.init(nibName: nil, bundle: nil)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(total)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 10
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
        label.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        view = .padded(stack, 20)
    }

    func update(done: Int, total: Int) {
        bar.doubleValue = Double(done)
        label.stringValue = "Exporting page \(done) of \(total)…"
    }

    @objc private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}
