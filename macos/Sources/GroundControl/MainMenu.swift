import AppKit
import GroundControlCore

/// The menu bar, built in code (there is no nib). Standard items target the responder
/// chain so the web view's text fields get Copy/Paste/Undo; the app's own items target
/// the delegate directly, and are named so nothing in the chain shadows them (WKWebView
/// itself answers `reload:`, hence `reloadDashboard:`).
@MainActor
enum MainMenu {
    static func make(delegate: AppDelegate) -> NSMenu {
        let bar = NSMenu()

        let app = submenu(in: bar, title: "Ground Control")
        add(app, "About Ground Control", #selector(AppDelegate.showAbout(_:)), "", target: delegate)
        app.addItem(.separator())
        add(app, "Hide Ground Control", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "")
        app.addItem(.separator())
        add(app, "Quit Ground Control", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu(in: bar, title: "File")
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu(in: bar, title: "Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let view = submenu(in: bar, title: "View")
        for (index, tab) in DashboardTab.allCases.enumerated() {
            add(view, tab.title, #selector(AppDelegate.showTab(_:)), tab.keyEquivalent, target: delegate)
                .tag = index
        }
        view.addItem(.separator())
        add(view, "Reload", #selector(AppDelegate.reloadDashboard(_:)), "r", target: delegate)
        view.addItem(.separator())
        add(view, "Actual Size", #selector(AppDelegate.actualSize(_:)), "0", target: delegate)
        add(view, "Zoom In", #selector(AppDelegate.zoomIn(_:)), "=", target: delegate)
        add(view, "Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-", target: delegate)
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        // No shortcut on Restart: ⇧⌘R means "hard reload" in every browser, and this one
        // takes the user's always-on server down for a few seconds.
        let server = submenu(in: bar, title: "Server")
        add(server, "Restart Server", #selector(AppDelegate.restartServer(_:)), "", target: delegate)
        add(server, "Show Server Log", #selector(AppDelegate.showServerLog(_:)), "", target: delegate)
        server.addItem(.separator())
        add(server, "Open in Browser", #selector(AppDelegate.openInBrowser(_:)), "o", [.command, .shift],
            target: delegate)

        let window = submenu(in: bar, title: "Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "")
        NSApp.windowsMenu = window

        let help = submenu(in: bar, title: "Help")
        add(help, "Ground Control on GitHub", #selector(AppDelegate.openRepository(_:)), "", target: delegate)
        NSApp.helpMenu = help

        return bar
    }

    private static func submenu(in bar: NSMenu, title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        bar.addItem(item)
        return menu
    }

    @discardableResult
    private static func add(
        _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
        return item
    }
}
