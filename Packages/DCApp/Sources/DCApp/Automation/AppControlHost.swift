// DCApp — the control channel's window side: the app as a `ControlHost`, the loopback server's wiring, and
// screenshots. Ports the window arms of `handle` and `inspect` in deckcraft `crates/ui-egui/src/control.rs`,
// `save_screenshot`, and the capture rules of `capture.rs` (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). The server itself is DCAutomation's `ControlServer` (`control_server.rs`).
import AppKit
import DCAppModel
import DCAutomation
import DCCore
import DCEngine
import DCRender

/// The app as the control channel sees it. Every call arrives on the main thread (`AutomationFeature`
/// drains the server there); a call from anywhere else is refused rather than trusted.
final class AppControlHost: ControlHost {
    private static let offMain = AutomationError("the control channel runs on the main thread")

    /// The app's one session (`AppModel.session`, which never changes).
    let session: Session

    init(session: Session) { self.session = session }

    func run(_ id: String, _ params: JSON) throws(AutomationError) -> JSON {
        guard Thread.isMainThread else { throw Self.offMain }
        let r: Result<JSON, CommandError> = MainActor.assumeIsolated {
            AppController.shared?.model.run(id, params) ?? .failure("the app isn't running")
        }
        switch r {
        case .success(let v): return v
        case .failure(let e): throw AutomationError(e.message)
        }
    }

    /// `all_commands`' UI half: `{id, label, shortcut, params, enabled: true, ui: true}`.
    var uiCommands: [JSON] {
        UICommands.all.map {
            ["id": .string($0.id), "label": .string($0.label), "shortcut": $0.shortcut.map(JSON.string) ?? .null,
             "params": .string($0.params), "enabled": true, "ui": true]
        }
    }

    var canvasScale: Double {
        guard Thread.isMainThread else { return 1 }
        return MainActor.assumeIsolated {
            guard let m = AppController.shared?.model else { return 1 }
            return m.ui.zoom ?? m.canvasScale
        }
    }

    func write(_ path: String, _ bytes: [UInt8]) throws(AutomationError) {
        do { try Data(bytes).write(to: URL(filePath: path)) } catch { throw AutomationError(error.localizedDescription) }
    }

    func open(_ path: String, password: String?) throws(AutomationError) {
        guard Thread.isMainThread else { throw Self.offMain }
        let r: String? = MainActor.assumeIsolated {
            // Nothing the control channel opens waits for a person: the password comes with the request or the
            // error goes back (PasswordPrompt).
            PasswordPrompt.supplied = password
            PasswordPrompt.interactive = false
            defer {
                PasswordPrompt.supplied = nil
                PasswordPrompt.interactive = true
            }
            let url = URL(filePath: path)
            let controller = NSDocumentController.shared
            if let open = controller.document(for: url) {
                open.showWindows()
                return nil
            }
            do {
                let type = try controller.typeForContents(of: url)
                let d = try controller.makeDocument(withContentsOf: url, ofType: type)
                controller.addDocument(d)
                d.makeWindowControllers()
                d.showWindows()
                controller.noteNewRecentDocument(d)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if let r { throw AutomationError(r) }
    }

    func interceptKey(_ key: String) -> ControlOutcome? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            for f in AppController.shared?.keyInterceptors ?? [] { if let o = f(key) { return o } }
            return nil
        }
    }

    func inspect() -> JSON {
        guard Thread.isMainThread else { return .null }
        return MainActor.assumeIsolated { Self.inspectOnMain() }
    }

    func handleUI(_ method: String, _ params: JSON) -> ControlOutcome? {
        guard Thread.isMainThread else { return .done(["ok": false, "error": .string(Self.offMain.message)]) }
        return MainActor.assumeIsolated { Self.handleOnMain(method, params) }
    }

    // MARK: On the main thread

    /// `inspect`: deckcraft's keys, then whatever the app's areas add (`AppController.inspect`).
    @MainActor static func inspectOnMain() -> JSON {
        guard let app = AppController.shared else { return .null }
        let m = app.model
        let window = keyDocumentWindow()
        let size = window?.contentView?.bounds.size ?? .zero
        var o = JSONObject()
        o.set("ui", uiJSON(m.ui))
        o.set("tool", ControlInput.toolJSON(m.session.tool.kind))
        o.set("window", [.double(size.width), .double(size.height)])
        o.set("canvasRect", .null)
        o.set("slideRect", .null)
        o.set("canvasScale", .double(m.ui.zoom ?? m.canvasScale))
        o.set("dialog", .null)
        o.set("home", false)
        o.set("backstage", .null)
        o.set("showing", .null)
        o.set("animPreview", .null)
        o.set("documents", .array(m.session.documents.map {
            ["title": .string($0.title), "dirty": .bool($0.isDirty), "path": $0.path.map(JSON.string) ?? .null,
             "protected": .bool($0.protection != nil)]
        }))
        o.set("status", m.status.map(JSON.string) ?? .null)
        o.set("perf", ["frameMs": 0.0, "renderMs": 0.0, "fps": 0.0])
        for (k, f) in app.inspectors { o.set(k, f()) }
        return .object(o)
    }

    /// `UiState` as `ui.inspect` and `ui.set` answer it (serde's camelCase keys).
    @MainActor static func uiJSON(_ ui: UiState) -> JSON {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        guard let data = try? enc.encode(ui), let v = try? JSONParser.parse([UInt8](data)) else { return .null }
        return v
    }

    @MainActor static func handleOnMain(_ method: String, _ p: JSON) -> ControlOutcome? {
        guard let app = AppController.shared else { return nil }
        if let h = app.controlHandlers[method] { return h(p) }
        let m = app.model
        func ok(_ v: JSON) -> ControlOutcome { .done(["ok": true, "result": v]) }
        func err(_ e: String) -> ControlOutcome { .done(["ok": false, "error": .string(e)]) }
        switch method {
        case "ui.screenshot":
            return .screenshot(path: p["path"]?.asStr)
        case "ui.set":
            if let l = p["layout"] {
                // The window layout, as View › Ribbon and Settings set it (the alpha gate runs in both, R4).
                guard let name = l.asStr, let layout = WindowLayout(rawValue: name) else { return err("layout is ribbon or mac") }
                m.run("view.ribbon", ["on": .bool(layout == .ribbon)])
            }
            if let t = p["tab"]?.asStr {
                m.ui.tab = t
                m.ui.ribbonCollapsed = false
            }
            if let pane = p["pane"] { m.ui.pane = pane.asStr }
            if let v = p["view"]?.asStr {
                m.ui.view = switch v {
                case "sorter": .sorter
                case "outline": .outline
                case "notesPage": .notesPage
                default: .normal
                }
            }
            if let z = p["zoom"] {
                m.ui.zoom = z.asF64.map { Double(Float($0)) }.flatMap { $0.isFinite && $0 > 0 ? min(max($0, UiState.zoomRange.lowerBound), UiState.zoomRange.upperBound) : nil }
            }
            if let d = p["dark"]?.asBool { m.run("view.dark", ["on": .bool(d)]) }
            if let n = p["notes"]?.asBool { m.ui.notes = n }
            if let c = p["ribbonCollapsed"]?.asBool { m.ui.ribbonCollapsed = c }
            if let ft = p["formatTab"]?.asStr { m.ui.formatTab = ft }
            m.changed()
            return ok(uiJSON(m.ui))
        case "ui.resize":
            guard let w = p["width"]?.asF64, let h = p["height"]?.asF64, w.isFinite, h.isFinite, w > 0, h > 0 else {
                return err("missing width/height")
            }
            keyDocumentWindow()?.setContentSize(NSSize(width: min(w, 16384), height: min(h, 16384)))
            return ok(.null)
        case "ui.key":
            // A key press sent to the key window, as the keyboard sends it (R3's keyboard checks): `key` is a
            // character or one of the names below, `modifiers` any of command, option, shift, control.
            guard let key = p["key"]?.asStr, let window = keyDocumentWindow() else { return err("missing key") }
            let named: [String: (UInt16, Int)] = [
                "tab": (48, 0x09), "return": (36, 0x0D), "space": (49, 0x20), "escape": (53, 0x1B), "delete": (51, 0x7F),
                "left": (123, NSLeftArrowFunctionKey), "right": (124, NSRightArrowFunctionKey),
                "down": (125, NSDownArrowFunctionKey), "up": (126, NSUpArrowFunctionKey), "f1": (122, NSF1FunctionKey),
            ]
            var flags: NSEvent.ModifierFlags = []
            for m in p["modifiers"]?.asArray ?? [] {
                switch m.asStr {
                case "command": flags.insert(.command)
                case "option": flags.insert(.option)
                case "shift": flags.insert(.shift)
                case "control": flags.insert(.control)
                default: break
                }
            }
            let code: UInt16
            let chars: String
            if let (c, u) = named[key.lowercased()], let scalar = Unicode.Scalar(u) {
                code = c
                chars = String(Character(scalar))
                if u >= 0xF700 { flags.insert([.function, .numericPad]) }
            } else if key.count == 1 {
                code = 0
                chars = key
            } else {
                return err("unknown key \(key)")
            }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
                window.sendEvent(e)
            }
            return ok(.null)
        case "ui.focus":
            NSApp.activate()
            keyDocumentWindow()?.makeKeyAndOrderFront(nil)
            return ok(.null)
        case "ui.move", "ui.click", "ui.drag":
            guard let x = p["x"]?.asF64, let y = p["y"]?.asF64 else { return err("missing x/y") }
            guard let window = keyDocumentWindow() else { return err("no window") }
            var events: [NSEvent] = []
            let point = { (x: Double, y: Double) in windowPoint(window, x, y) }
            if method == "ui.move" {
                events += mouse(.mouseMoved, point(x, y), window, 0)
            } else if method == "ui.click" {
                let right = ["right", "secondary"].contains(p["button"]?.asStr ?? "")
                let count = Int(min(max(p["count"]?.asU64 ?? 1, 1), 3))
                for k in 1 ... count {
                    events += mouse(right ? .rightMouseDown : .leftMouseDown, point(x, y), window, k)
                    events += mouse(right ? .rightMouseUp : .leftMouseUp, point(x, y), window, k)
                }
            } else {
                guard let tx = p["toX"]?.asF64, let ty = p["toY"]?.asF64 else { return err("missing toX/toY") }
                let steps = Int(min(max(p["steps"]?.asU64 ?? 8, 1), 120))
                events += mouse(.leftMouseDown, point(x, y), window, 1)
                for k in 1 ... steps {
                    let a = Double(k) / Double(steps)
                    events += mouse(.leftMouseDragged, point(x + (tx - x) * a, y + (ty - y) * a), window, 1)
                }
                events += mouse(.leftMouseUp, point(tx, ty), window, 1)
            }
            for e in events { window.sendEvent(e) }
            return ok(["queued": .integer(events.count)])
        case "show.start":
            return wrap(m.run(p["reading"]?.asBool == true ? "view.reading" : "show.start", p))
        case "show.end":
            return wrap(m.run("show.end"))
        case "app.quit":
            if p["save"]?.asBool == true {
                for d in app.documents where d.isDocumentEdited { d.save(nil) }
            }
            // Automation quits without asking: open dialogs and sheets close first (AppKit won't terminate
            // with a sheet attached), and edits are dropped.
            _ = app.controlHandlers["ui.dialog.close"]?(.object(JSONObject()))
            for w in NSApp.windows {
                while let sheet = w.attachedSheet { w.endSheet(sheet) }
            }
            if NSApp.modalWindow != nil { NSApp.abortModal() }
            for d in app.documents { d.updateChangeCount(.changeCleared) }
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return ok(.null)
        default:
            return nil
        }
    }

    @MainActor static func wrap(_ r: Result<JSON, CommandError>) -> ControlOutcome {
        switch r {
        case .success(let v): .done(["ok": true, "result": v])
        case .failure(let e): .done(["ok": false, "error": .string(e.message)])
        }
    }

    /// The window automation acts on: the key document window, else the front one.
    @MainActor static func keyDocumentWindow() -> NSWindow? {
        if let w = NSApp.keyWindow, w.windowController is DocumentWindowController { return w }
        return NSApp.orderedWindows.first { $0.windowController is DocumentWindowController } ?? NSApp.keyWindow ?? NSApp.windows.first
    }

    /// A control-channel point (content coordinates, y down) in the window's base coordinates.
    @MainActor static func windowPoint(_ w: NSWindow, _ x: Double, _ y: Double) -> NSPoint {
        let h = w.contentView?.bounds.height ?? w.frame.height
        return NSPoint(x: x, y: h - y)
    }

    @MainActor static func mouse(_ type: NSEvent.EventType, _ at: NSPoint, _ w: NSWindow, _ clicks: Int) -> [NSEvent] {
        let e = NSEvent.mouseEvent(
            with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1
        )
        return e.map { [$0] } ?? []
    }
}
