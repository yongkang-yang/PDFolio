import AppKit

// Rendering a page allocates and frees multi-MB decode buffers, and malloc
// keeps the freed ones (dirty, counted against the app) for reuse: about
// 35 MB after one short scanned PDF. The cache can only be turned off from
// the environment, which is read before `main`, so set it and start over.
if getenv("MallocLargeCache") == nil {
    setenv("MallocLargeCache", "0", 1)
    var path = [CChar](repeating: 0, count: Int(PATH_MAX))
    var size = UInt32(path.count)
    if _NSGetExecutablePath(&path, &size) == 0 {
        execv(path, CommandLine.unsafeArgv)
    }
    // If exec fails, carry on with the default allocator settings.
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
