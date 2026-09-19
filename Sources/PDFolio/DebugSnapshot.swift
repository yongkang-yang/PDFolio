import AppKit

/// `--snapshot <dir>`: renders the workspace window (and the signing sheet
/// for the first page) to PNGs, then quits. For checking layout without
/// Screen Recording permission, e.g. from CI or a terminal.
enum DebugSnapshot {
    static func write(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
