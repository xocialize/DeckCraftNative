// DCApp — the menu bar, built from `MenuTree` (deckcraft's `menu_tree`) with each item's key equivalent
// taken from the registry's shortcut, and enabled by the command's own `enabled` check.
import AppKit
import DCAppModel
import DCCore
import DCEngine

@MainActor
enum MenuBuilder {
    static func mainMenu(target: AppController) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(target: target)))
        for m in MenuTree.menus {
            let menu = NSMenu(title: L10n.menuTitle(m.title))
            for e in m.entries {
                switch e {
                case .separator: menu.addItem(.separator())
                case .command(let label, let id): menu.addItem(item(L10n.menuTitle(label), id, target: target))
                }
            }
            if m.title == "Help" { NSApp.helpMenu = menu }
            main.addItem(submenu(menu))
            if m.title == "Slide Show" { main.addItem(submenu(windowMenu())) }
        }
        return main
    }

    /// A command's menu item: the command id rides in `representedObject`.
    static func item(_ label: String, _ id: String, target: AppController) -> NSMenuItem {
        let item = NSMenuItem(title: label, action: #selector(AppController.runCommand(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = id
        if let s = shortcut(for: id), let (key, mods) = keyEquivalent(s) {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mods
        }
        return item
    }

    /// The registry's shortcut for an engine or UI command.
    static func shortcut(for id: String) -> Shortcut? {
        let text = findCommand(id)?.shortcut ?? UICommands.find(id)?.shortcut
        return text.flatMap(Shortcut.init)
    }

    /// AppKit's key equivalent for a shortcut.
    static func keyEquivalent(_ s: Shortcut) -> (String, NSEvent.ModifierFlags)? {
        var mods: NSEvent.ModifierFlags = []
        if s.cmd { mods.insert(.command) }
        if s.shift { mods.insert(.shift) }
        if s.alt { mods.insert(.option) }
        if s.ctrl { mods.insert(.control) }
        let named: [String: Int] = [
            "F1": NSF1FunctionKey, "F2": NSF2FunctionKey, "F3": NSF3FunctionKey, "F4": NSF4FunctionKey, "F5": NSF5FunctionKey,
            "F6": NSF6FunctionKey, "F7": NSF7FunctionKey, "F8": NSF8FunctionKey, "F9": NSF9FunctionKey, "F10": NSF10FunctionKey,
            "F11": NSF11FunctionKey, "F12": NSF12FunctionKey, "Up": NSUpArrowFunctionKey, "Down": NSDownArrowFunctionKey,
            "Left": NSLeftArrowFunctionKey, "Right": NSRightArrowFunctionKey, "Home": NSHomeFunctionKey, "End": NSEndFunctionKey,
            "PageUp": NSPageUpFunctionKey, "PageDown": NSPageDownFunctionKey,
        ]
        let key: String
        if s.key.count == 1 {
            key = s.key
        } else if let code = named[s.key], let scalar = Unicode.Scalar(code) {
            key = String(Character(scalar))
        } else {
            switch s.key {
            case "Enter": key = "\r"
            case "Tab": key = "\t"
            case "Space": key = " "
            case "Escape": key = "\u{1b}"
            case "Delete", "Backspace": key = "\u{8}"
            default: return nil
            }
        }
        return (key, mods)
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func appMenu(target: AppController) -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let m = NSMenu(title: name)
        m.addItem(item(String(localized: "About \(name)", bundle: .module, comment: "App menu; %@ is the app name"), "app.about", target: target))
        m.addItem(.separator())
        m.addItem(item(String(localized: "Settings…", bundle: .module, comment: "App menu"), "app.preferences", target: target))
        m.addItem(.separator())
        let services = NSMenuItem(title: String(localized: "Services", bundle: .module, comment: "App menu"), action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: String(localized: "Services", bundle: .module, comment: "App menu"))
        NSApp.servicesMenu = services.submenu
        m.addItem(services)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: String(localized: "Hide \(name)", bundle: .module, comment: "App menu; %@ is the app name"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let others = NSMenuItem(title: String(localized: "Hide Others", bundle: .module, comment: "App menu"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        m.addItem(others)
        m.addItem(NSMenuItem(title: String(localized: "Show All", bundle: .module, comment: "App menu"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: String(localized: "Quit \(name)", bundle: .module, comment: "App menu; %@ is the app name"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: String(localized: "Window", bundle: .module, comment: "The Window menu"))
        m.addItem(NSMenuItem(title: String(localized: "Minimize", bundle: .module, comment: "Window menu"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        m.addItem(NSMenuItem(title: String(localized: "Zoom", bundle: .module, comment: "Window menu: zoom the window"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: String(localized: "Bring All to Front", bundle: .module, comment: "Window menu"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = m
        return m
    }
}

extension AppController: NSMenuItemValidation {
    /// Enabled when the command's own `enabled` check passes (engine commands) or always (UI commands).
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(runCommand(_:)), let id = item.representedObject as? String else { return true }
        if id == "file.new" || id == "app.openDialog" || id == "app.about" || id == "app.preferences" { return true }
        // View › Ribbon shows whether the window has the ribbon.
        if id == "view.ribbon" { item.state = model.ui.layout == .ribbon ? .on : .off }
        // Collapse the Ribbon (⌘F1) is ticked while minimised; it and Move Focus to the Ribbon (F6) only have a
        // ribbon to act on in its layout.
        if id == "view.collapseRibbon" || id == "view.focusRibbon" {
            if id == "view.collapseRibbon" { item.state = model.ui.ribbonCollapsed ? .on : .off }
            return model.ui.layout == .ribbon
        }
        if UICommands.contains(id) { return true }
        guard let spec = findCommand(id) else { return false }
        return spec.enabled(model.session) == nil
    }
}
