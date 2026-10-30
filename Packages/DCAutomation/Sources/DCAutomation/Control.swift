// DCAutomation — programmatic control of the running app (agents, tests, MCP `--connect`): the JSON
// control channel's requests, replies and dispatch. Port of deckcraft crates/ui-egui/src/control.rs (MIT
// OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors): the protocol and every method that
// needs no window are here; the methods that drive the window (`ui.click`, `ui.set`, dialogs,
// screenshots, the slide show, quitting…) are the app's, behind `ControlHost` (Wave 5).
//
// Methods (JSON lines over the host's transport, see deckcraft's docs/control-protocol.md):
// - `engine.execute {command, params}` / `ui.menu.invoke {command, params}` / `command`: run any command
// - `engine.commands`: engine and UI commands with enablement; `document.inspect`; `ui.inspect`
// - `ui.pointer {events:[{kind, x, y, mods?, pressure?}], mods?}`: drive the active tool in slide points
// - `ui.key {key, shift?, alt?, cmd?}` / `ui.text {text}`: keyboard through the engine
// - `ui.tool.select {tool, preset?}`; `ui.render {slide?, scale?, edit?, path?}`: one slide as PNG
// - `app.open {path}` / `app.save {path?}` / `app.export {path, …}`
// - everything else (`ui.ime`, `ui.move`/`click`/`drag`, `ui.set`, `ui.dialog.*`, `ui.screenshot`,
//   `ui.resize`, `ui.focus`, `show.*`, `app.quit`) through `ControlHost.handleUI`.
import DCCore
import DCEngine
import Foundation
import Synchronization

/// Queued, not yet run.
public let controlPending: UInt8 = 0
/// The app has started it: it will answer.
public let controlTaken: UInt8 = 1
/// Its sender gave up waiting (the reply timeout expired): it is dropped unrun.
public let controlAbandoned: UInt8 = 2

/// Who has a request: pending, taken (the app runs it) or abandoned (the sender gave up on it, so the app
/// must not run it late: deckcraft issue #719).
public final class ControlState: Sendable {
    let value = Atomic<UInt8>(controlPending)
    public init() {}
    public var current: UInt8 { value.load(ordering: .sequentiallyConsistent) }
}

/// Where a request's reply goes: one reply, waited for with a timeout (Rust's `mpsc` channel).
public final class ControlReply: Sendable {
    private let slot = Mutex<JSON?>(nil)
    private let ready = DispatchSemaphore(value: 0)

    public init() {}

    /// Send the reply (a second one is dropped).
    public func send(_ v: JSON) {
        let first = slot.withLock { s -> Bool in
            if s != nil { return false }
            s = v
            return true
        }
        if first { ready.signal() }
    }

    /// The reply, waiting up to `timeout` seconds; nil when none came.
    public func wait(timeout: Double) -> JSON? {
        if ready.wait(timeout: .now() + timeout) == .timedOut { return nil }
        ready.signal()
        return slot.withLock { $0 }
    }
}

/// One decoded control request.
public struct ControlRequest: Sendable {
    public var method: String
    public var params: JSON
    public var reply: ControlReply
    public var state: ControlState

    /// A pending request and where its reply will arrive.
    public static func make(_ method: String, _ params: JSON) -> (ControlRequest, ControlReply) {
        let reply = ControlReply()
        return (ControlRequest(method: method, params: params, reply: reply, state: ControlState()), reply)
    }

    /// Claim the request for running; false when its sender already gave up on it.
    public func take() -> Bool {
        state.value.compareExchange(expected: controlPending, desired: controlTaken, ordering: .sequentiallyConsistent).exchanged
            || state.value.load(ordering: .sequentiallyConsistent) == controlTaken
    }

    /// Give up on the request; false when the app has already started it (it will answer).
    public static func abandon(_ state: ControlState) -> Bool {
        state.value.compareExchange(expected: controlPending, desired: controlAbandoned, ordering: .sequentiallyConsistent).exchanged
            || state.value.load(ordering: .sequentiallyConsistent) == controlAbandoned
    }
}

/// What handling a request came to: a reply, or a screenshot the window has to take first.
public enum ControlOutcome: Sendable, Equatable {
    case done(JSON)
    case screenshot(path: String?)
}

/// The app behind the control channel: the session it edits and the methods only a window can answer.
public protocol ControlHost: AnyObject {
    /// The engine session.
    var session: Session { get }
    /// Run a command, the app's own UI commands included (`SlideApp::run`).
    func run(_ id: String, _ params: JSON) throws(AutomationError) -> JSON
    /// The app's UI commands as `engine.commands` lists them (`{id, label, shortcut, params, enabled, ui}`).
    var uiCommands: [JSON] { get }
    /// Points per screen point of the canvas, for the pointer's hit tolerance.
    var canvasScale: Double { get }
    /// Write a file the way the app writes (`services.write`).
    func write(_ path: String, _ bytes: [UInt8]) throws(AutomationError)
    /// Open a presentation (`app.open`), with the password of a password-protected one.
    func open(_ path: String, password: String?, modifyPassword: String?) throws(AutomationError)
    /// A key the window takes before the engine (the slide show, the canvas animation preview); nil to let
    /// the engine have it.
    func interceptKey(_ key: String) -> ControlOutcome?
    /// `ui.inspect`.
    func inspect() -> JSON
    /// A method that drives the window; nil when the host doesn't know it either.
    func handleUI(_ method: String, _ params: JSON) -> ControlOutcome?
}

public enum Control {
    static func ok(_ v: JSON) -> ControlOutcome { .done(["ok": true, "result": v]) }
    static func err(_ e: String) -> ControlOutcome { .done(["ok": false, "error": .string(e)]) }
    static func wrap(_ body: () throws(AutomationError) -> JSON) -> ControlOutcome {
        do { return ok(try body()) } catch { return err(error.message) }
    }

    /// `engine.commands`: the engine's and the app's commands.
    public static func allCommands(_ host: ControlHost) -> JSON {
        .array(host.session.commands().map { $0.toJSON() } + host.uiCommands)
    }

    /// Dispatch one decoded control request and return an outcome for its caller to reply with.
    public static func handle(_ host: ControlHost, _ method: String, _ p: JSON) -> ControlOutcome {
        func s(_ k: String) -> String? { p.get(k)?.asStr }
        let session = host.session
        switch method {
        case "engine.execute", "ui.menu.invoke", "command":
            guard let id = s("command") ?? s("id") else { return err("missing `command`") }
            let params = p.get("params").flatMap { $0.isNull ? nil : $0 } ?? .emptyObject
            return wrap { () throws(AutomationError) -> JSON in try host.run(id, params) }
        case "engine.commands":
            return ok(allCommands(host))
        case "document.inspect":
            return wrap { () throws(AutomationError) -> JSON in try host.run("document.inspect", .emptyObject) }
        case "ui.inspect":
            return ok(host.inspect())
        case "ui.pointer":
            guard let events = p.get("events")?.asArray else { return err("missing `events`") }
            let base = p.get("mods").map(ControlInput.mods) ?? Mods()
            var last = JSON.null
            for e in events {
                do {
                    let ev = try ControlInput.pointerEvent(
                        e, base: base, tol: 4 / host.canvasScale.rustMax(0.05),
                        kindError: { "unknown pointer kind `\($0)`" }, xyError: { _ in "pointer events need x and y" }
                    )
                    last = try drivePointer(session, ev)
                } catch {
                    return err(error.message)
                }
            }
            return ok(["result": last, "selection": session.activeDoc.map { $0.selection.toJSON() } ?? .null])
        case "ui.key":
            guard let k = s("key") else { return err("missing `key`") }
            if let o = host.interceptKey(k) { return o }
            return wrap { () throws(AutomationError) -> JSON in
                do throws(EngineError) { return try session.key(k, ControlInput.mods(p)) } catch { throw AutomationError(error.description) }
            }
        case "ui.text":
            guard let t = s("text") else { return err("missing `text`") }
            return wrap { () throws(AutomationError) -> JSON in
                do throws(EngineError) { return try session.typeText(t) } catch { throw AutomationError(error.description) }
            }
        case "ui.tool.select":
            guard let name = s("tool") else { return err("missing `tool`") }
            guard let k = ControlInput.toolKind(name, s("preset"), extraNames: false) else { return err("unknown tool `\(name)`") }
            session.setTool(k)
            return ok(["tool": .string(name)])
        case "ui.render":
            guard let d = session.activeDoc else { return err("no presentation open") }
            let i = p.get("slide")?.asUsize ?? d.selection.slide
            if i >= d.doc.slides.count { return err("no slide \(i)") }
            let (png, w, h) = FileCommands.renderPNG(d.doc, i, p.get("scale")?.asF64 ?? 1, p.get("edit")?.asBool ?? false)
            if let path = s("path") {
                do { try host.write(path, png) } catch { return err(error.message) }
                return ok(["path": .string(path), "width": .integer(w), "height": .integer(h)])
            }
            return ok(["png": .string(Cmd.base64Encode(png)), "width": .integer(w), "height": .integer(h), "slide": .integer(i)])
        case "app.open":
            guard let path = s("path") else { return err("missing `path`") }
            return wrap { () throws(AutomationError) -> JSON in
                try host.open(path, password: s("password"), modifyPassword: s("modifyPassword"))
                return .null
            }
        case "app.save":
            return wrap { () throws(AutomationError) -> JSON in try host.run("file.save", p) }
        case "app.export":
            return wrap { () throws(AutomationError) -> JSON in try host.run("file.export", p) }
        default:
            return host.handleUI(method, p) ?? err("unknown method `\(method)`")
        }
    }
}

/// Runs control requests on an `EngineThread` (32 MiB stack), one at a time and in order, skipping the ones
/// their senders abandoned. The host is used only there.
public final class ControlChannel: Sendable {
    let engine: EngineThread
    let host: EngineConfined<ControlHost>

    /// A channel over `host`, which it takes over.
    public init(_ host: ControlHost) {
        engine = EngineThread(name: "dc.control")
        self.host = EngineConfined(host)
    }

    deinit { engine.stop() }

    /// Queue `request`; its reply is sent when it has run. A screenshot outcome is answered with an
    /// error here: taking one is the window's job.
    public func submit(_ request: ControlRequest) {
        let host = host
        _ = Task.detached { [engine] in
            await engine.run {
                guard request.take() else { return }
                switch Control.handle(host.value, request.method, request.params) {
                case .done(let v): request.reply.send(v)
                case .screenshot: request.reply.send(["ok": false, "error": .string("`ui.screenshot`: \(needsApp)")])
                }
            }
        }
    }

    /// Run one request and wait for its reply (`timeout` seconds; the request is abandoned when it expires
    /// before it started, and its outcome is unknown when it had).
    public func call(_ method: String, _ params: JSON, timeout: Double = 60) -> JSON {
        let (req, reply) = ControlRequest.make(method, params)
        let host = host
        let started = engine.sync { () -> Bool in
            guard req.take() else { return false }
            switch Control.handle(host.value, req.method, req.params) {
            case .done(let v): req.reply.send(v)
            case .screenshot: req.reply.send(["ok": false, "error": .string("`ui.screenshot`: \(needsApp)")])
            }
            return true
        }
        if started == nil { return ["ok": false, "error": "the control channel has stopped"] }
        return reply.wait(timeout: timeout) ?? ["ok": false, "error": "timeout"]
    }
}

/// A `ControlHost` with no window: the session alone. Window methods are refused, as the MCP server's
/// headless backend refuses them.
public final class HeadlessControlHost: ControlHost {
    public let session: Session
    public init(_ session: Session = Session()) { self.session = session }

    public func run(_ id: String, _ params: JSON) throws(AutomationError) -> JSON {
        defer { session.uiRequests.removeAll() }
        do { return try session.execute(id, params) } catch { throw AutomationError(error.description) }
    }

    public var uiCommands: [JSON] { [] }
    public var canvasScale: Double { 1 }

    public func write(_ path: String, _ bytes: [UInt8]) throws(AutomationError) {
        do { try IO.writeFile(path, bytes) } catch { throw AutomationError(error.description) }
    }

    public func open(_ path: String, password: String?, modifyPassword: String?) throws(AutomationError) {
        var p: JSON = ["path": .string(path)]
        if let password { p.set("password", .string(password)) }
        if let modifyPassword { p.set("modifyPassword", .string(modifyPassword)) }
        _ = try run("file.open", p)
    }

    public func interceptKey(_ key: String) -> ControlOutcome? { nil }

    public func inspect() -> JSON { ["headless": true, "tool": ControlInput.toolJSON(session.tool.kind)] }

    public func handleUI(_ method: String, _ params: JSON) -> ControlOutcome? {
        if method.hasPrefix("ui.") || method.hasPrefix("app.") || method.hasPrefix("show.") { return Control.err("`\(method)`: \(needsApp)") }
        return nil
    }
}
