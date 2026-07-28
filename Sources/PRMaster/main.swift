import AppKit

// `.accessory` alongside LSUIElement in Info.plist: the plist governs a launched
// bundle, this covers running the binary directly during development.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
