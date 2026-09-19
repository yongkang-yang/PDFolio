import AppKit
import PDFolioCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [WorkspaceWindowController] = []
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// Files handed over at launch (Finder "Open With", `open -a`), which can
    /// arrive before the first window exists.
    private var pendingURLs: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        launched = true

        let args = CommandLine.arguments.dropFirst()
        let benchmark = args.contains("--scroll-benchmark")
        let argumentFiles = args
            .filter { !$0.hasPrefix("-") && SourceLoader.isSupported(URL(fileURLWithPath: $0)) }
            .map { URL(fileURLWithPath: $0) }
            .filter(SourceLoader.isSupported)

        let controller = newWindow()
        let urls = pendingURLs + argumentFiles
        pendingURLs = []
        if !urls.isEmpty {
            controller.importFiles(urls, atGap: nil)
            controller.workspace.hasUnexportedChanges = false
        }
        if benchmark {
            controller.runScrollBenchmark(quitAfter: args.contains("--quit"))
        }
        if let i = args.firstIndex(of: "--snapshot"), args.index(after: i) < args.endIndex {
            controller.runSnapshot(into: URL(fileURLWithPath: args[args.index(after: i)]))
        }

        // Drop caches (thumbnails and parsed documents are all recreatable)
        // when the system is short on memory.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            self?.windows.forEach { $0.workspace.purgeCaches() }
        }
        source.resume()
        memoryPressure = source
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let supported = urls.filter(SourceLoader.isSupported)
        guard launched else {
            pendingURLs += supported
            return
        }
        let target = (NSApp.keyWindow?.windowController as? WorkspaceWindowController) ?? windows.last ?? newWindow()
        target.importFiles(supported, atGap: nil)
        target.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @discardableResult
    private func newWindow() -> WorkspaceWindowController {
        let controller = WorkspaceWindowController()
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        windows.append(controller)
        if let last = windows.dropLast().last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        controller.showWindow(nil)
        return controller
    }

    @objc func newWorkspace(_ sender: Any?) {
        newWindow()
    }

    @objc func openFiles(_ sender: Any?) {
        let target = (NSApp.keyWindow?.windowController as? WorkspaceWindowController) ?? newWindow()
        target.addFiles(sender)
    }

    // MARK: Menu

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        let appName = "PDFolio"
        submenu(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")
        ])

        submenu("File", [
            item("New Workspace", #selector(newWorkspace(_:)), "n"),
            item("Add Files…", #selector(openFiles(_:)), "o"),
            item("Insert Files After Selection…", #selector(WorkspaceWindowController.insertFiles(_:)), "i", [.command, .shift]),
            .separator(),
            item("Export PDF…", #selector(WorkspaceWindowController.exportPDF(_:)), "e"),
            item("Extract Selected Pages…", #selector(WorkspaceWindowController.extractPages(_:)), "e", [.command, .shift]),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w")
        ])

        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
            item("Delete", #selector(WorkspaceWindowController.delete(_:)), "\u{8}", [])
        ])

        submenu("Pages", [
            item("Rotate Left", #selector(WorkspaceWindowController.rotateLeft(_:)), "l"),
            item("Rotate Right", #selector(WorkspaceWindowController.rotateRight(_:)), "r"),
            item("Duplicate", #selector(WorkspaceWindowController.duplicatePages(_:)), "d"),
            .separator(),
            item("Sign Page…", #selector(WorkspaceWindowController.signPage(_:)), "s", [.command, .shift])
        ])

        submenu("View", [
            item("Fewer Pages per Row", #selector(WorkspaceWindowController.zoomIn(_:)), "+"),
            item("More Pages per Row", #selector(WorkspaceWindowController.zoomOut(_:)), "-"),
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        ])

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }
}
