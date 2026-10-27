// DCAutomation — an in-process engine session that answers the engine-level control-channel methods
// itself, rendering slides with DCRender, so agents can build layouts and look at them without a window.
// Port of deckcraft crates/mcp/src/headless.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCEngine
import DCGeometry
import DCRender

/// Hint appended to errors for methods that need a window.
let needsApp = "it needs the desktop app: start `deckcraft --control 7979` and run the MCP server with `deckcraft-cli mcp --connect 7979`"

/// The pointer, keyboard and tool vocabulary of the control channel (`ui.pointer`, `ui.key`,
/// `ui.tool.select`), shared by the headless backend and the app's control channel.
public enum ControlInput {
    /// A pointer event kind by its control-channel name.
    public static func pointerKind(_ k: String) -> PointerKind? {
        switch k {
        case "down": .down
        case "drag": .drag
        case "up": .up
        case "move": .move
        case "doubleclick", "dblclick": .doubleClick
        case "tripleclick": .tripleClick
        case "contextclick", "rightclick": .contextClick
        default: nil
        }
    }

    /// `{shift?, alt?, cmd?, ctrl?}` (ctrl is cmd).
    public static func mods(_ p: JSON) -> Mods {
        func b(_ n: String) -> Bool { p.get(n)?.asBool ?? false }
        return Mods(shift: b("shift"), alt: b("alt"), cmd: b("cmd") || b("ctrl"))
    }

    /// A tool name (`select`, `textBox`, `shape`, `pen`, `highlighter`, `eraser`, or a preset or freeform
    /// tool's name) as a `ToolKind`. `arrow` and `textbox` are the MCP server's extra spellings
    /// (`extraNames`); the app's control channel doesn't take them.
    public static func toolKind(_ name: String, _ preset: String?, extraNames: Bool = true) -> ToolKind? {
        switch name {
        case "select", "selection": return .select
        case "arrow" where extraNames: return .select
        case "textBox", "text": return .textBox
        case "textbox" where extraNames: return .textBox
        case "shape": return .shape(preset: preset ?? "rect")
        case "pen": return .ink(mode: "pen", color: .black, width: 2)
        case "highlighter": return .ink(mode: "highlighter", color: .rgb(255, 230, 0), width: 10)
        case "eraser": return .ink(mode: "eraser", color: .black, width: 2)
        default:
            if Preset.info(name) != nil || Tools.isFreeformTool(name) { return .shape(preset: name) }
            return nil
        }
    }

    /// serde's `ToolKind` (`tag = "kind"`, camelCase).
    public static func toolJSON(_ k: ToolKind) -> JSON {
        var o = JSONObject()
        switch k {
        case .select: o.set("kind", "select")
        case .shape(let preset):
            o.set("kind", "shape")
            o.set("preset", .string(preset))
        case .textBox: o.set("kind", "textBox")
        case .ink(let mode, let color, let width):
            o.set("kind", "ink")
            o.set("mode", .string(mode))
            o.set("color", color.toJSON())
            o.set("width", .num(width))
        }
        return .object(o)
    }

    /// One event of a `ui.pointer` request, as the control channel reads it: `kindError` names the error
    /// for an unknown kind and `xyError` the one for missing coordinates (true: `x` is missing); `tol` is
    /// the hit tolerance and `base` the request's modifiers.
    static func pointerEvent(_ e: JSON, base: Mods, tol: Double, kindError: (String) -> String, xyError: (Bool) -> String) throws(AutomationError) -> PointerEvent {
        let name = e.get("kind")?.asStr ?? ""
        guard let kind = pointerKind(name) else { throw AutomationError(kindError(name)) }
        guard let x = e.get("x")?.asF64 else { throw AutomationError(xyError(true)) }
        guard let y = e.get("y")?.asF64 else { throw AutomationError(xyError(false)) }
        var ev = PointerEvent()
        ev.kind = kind
        ev.x = x
        ev.y = y
        ev.mods = e.get("mods").map(mods) ?? base
        ev.tol = tol
        ev.pressure = e.get("pressure")?.asF64.map { Float($0) }
        return ev
    }
}

/// Feeds one pointer event to the session's active tool (deckcraft `Session::pointer`); an engine error
/// becomes the request's error, as `e.to_string()` does in deckcraft. The control channel's `ui.pointer` and
/// the MCP `pointer` tool both come through here.
func drivePointer(_ s: Session, _ ev: PointerEvent) throws(AutomationError) -> JSON {
    do throws(EngineError) {
        return try s.pointer(ev)
    } catch {
        throw AutomationError(error.description)
    }
}

/// Headless backend: a `Session` rendering slides on the CPU. Confined to one thread at a time.
public final class Headless: Backend {
    public let session: Session
    var roots: AutomationRoots?

    /// An empty session (no presentation open).
    public init() {
        session = Session()
    }

    /// A session with a fresh presentation.
    public static func withDocument() -> Headless {
        let h = Headless(session: Session.withNew())
        return h
    }

    init(session: Session) { self.session = session }

    /// Confine every file the session's commands read and write to `roots` (`dccli mcp
    /// --automation-read-root … --automation-write-root …`).
    @discardableResult
    public func withAutomationRoots(_ roots: AutomationRoots?) -> Headless {
        self.roots = roots
        return self
    }

    func exec(_ id: String, _ params: JSON) throws(AutomationError) -> JSON {
        defer { session.uiRequests.removeAll() }
        do {
            return try session.execute(id, params)
        } catch {
            let uiOnly = ["app.", "view.", "window.", "ui."].contains { id.hasPrefix($0) }
            if uiOnly && findCommand(id) == nil { throw AutomationError("`\(id)` is a UI command; \(needsApp)") }
            throw AutomationError(error.description)
        }
    }

    func pointer(_ p: JSON) throws(AutomationError) -> JSON {
        guard let events = p.get("events")?.asArray else { throw AutomationError("missing `events`") }
        let base = p.get("mods").map(ControlInput.mods) ?? Mods()
        if session.activeDoc == nil { throw AutomationError("no presentation open (use new_presentation first)") }
        var last = JSON.null
        for e in events {
            let ev = try ControlInput.pointerEvent(
                e, base: base, tol: 3,
                kindError: { "unknown pointer kind `\($0)` (down|drag|up|move|doubleclick|tripleclick|contextclick)" },
                xyError: { $0 ? "pointer event needs `x`" : "pointer event needs `y`" }
            )
            last = try drivePointer(session, ev)
        }
        session.uiRequests.removeAll()
        return ["result": last, "selection": session.activeDoc.map { $0.selection.toJSON() } ?? .null]
    }

    func render(_ p: JSON) throws(AutomationError) -> JSON {
        guard let st = session.activeDoc else { throw AutomationError("no presentation open") }
        let i = p.get("slide")?.asUsize ?? st.selection.slide
        if i >= st.doc.slides.count { throw AutomationError("no slide \(i)") }
        let scale = (p.get("scale")?.asF64 ?? 1).clamped(0.05, 8)
        var opts = RenderOpts(scale: scale)
        opts.edit = p.get("edit")?.asBool ?? false
        let img = renderSlide(st.doc, i, opts)
        let png = ImageEncoding.png(img, dpi: ImageEncoding.dpiForScale(scale))
        if let path = p.get("path")?.asStr {
            do { try IO.writeFile(path, png) } catch { throw AutomationError(error.description) }
            return ["path": .string(path), "width": .integer(img.width), "height": .integer(img.height)]
        }
        return ["png": .string(Cmd.base64Encode(png)), "width": .integer(img.width), "height": .integer(img.height), "slide": .integer(i)]
    }

    public func call(_ method: String, _ params: JSON) throws(AutomationError) -> JSON {
        let r: Result<JSON, AutomationError> = FileAccess.confine(roots) {
            Result { () throws(AutomationError) -> JSON in try answer(method, params) }
        }
        return try r.get()
    }

    public var hasUI: Bool { false }

    public func describe() -> String { "headless (in-process engine; no window)" }

    func answer(_ method: String, _ p: JSON) throws(AutomationError) -> JSON {
        func str(_ k: String) -> String? { p.get(k)?.asStr }
        switch method {
        case "engine.execute", "command", "ui.menu.invoke":
            guard let id = str("command") ?? str("id") else { throw AutomationError("missing `command`") }
            let cp = p.get("params").flatMap { $0.isNull ? nil : $0 } ?? .emptyObject
            return try exec(id, cp)
        case "engine.commands":
            return .array(session.commands().map { $0.toJSON() })
        case "document.inspect":
            return try exec("document.inspect", .emptyObject)
        case "ui.pointer":
            return try pointer(p)
        case "ui.key":
            guard let key = str("key") else { throw AutomationError("missing `key`") }
            do { return try session.key(key, ControlInput.mods(p)) } catch { throw AutomationError(error.description) }
        case "ui.text":
            guard let t = str("text") else { throw AutomationError("missing `text`") }
            do { return try session.typeText(t) } catch { throw AutomationError(error.description) }
        case "ui.tool.select":
            guard let name = str("tool") else { throw AutomationError("missing `tool`") }
            guard let kind = ControlInput.toolKind(name, str("preset")) else { throw AutomationError("unknown tool `\(name)`") }
            session.setTool(kind)
            return ["tool": .string(name)]
        case "ui.render", "app.renderSlide":
            return try render(p)
        case "app.open":
            return try exec("file.open", p)
        case "app.save":
            return try exec("file.save", p)
        case "app.export":
            return try exec("file.export", p)
        case "ui.inspect":
            return ["headless": true, "tool": ControlInput.toolJSON(session.tool.kind)]
        case let m where m.hasPrefix("ui.") || m.hasPrefix("app."):
            throw AutomationError("`\(m)`: \(needsApp)")
        default:
            throw AutomationError("unknown method `\(method)`")
        }
    }
}
