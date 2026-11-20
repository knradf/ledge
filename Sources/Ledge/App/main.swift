import AppKit

// Accessory app: no Dock icon, no menu bar, never takes focus. Settings
// makes it a regular app while open; the menu is for then.
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.mainMenu = {
    let main = NSMenu()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide Ledge", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Ledge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    for menu in [appMenu, editMenu, windowMenu] {
        let item = NSMenuItem()
        item.submenu = menu
        main.addItem(item)
    }
    app.windowsMenu = windowMenu
    return main
}()
app.run()
