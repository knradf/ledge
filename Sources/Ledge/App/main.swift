import AppKit

// Accessory app: no Dock icon, no menu bar, never takes focus.
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
