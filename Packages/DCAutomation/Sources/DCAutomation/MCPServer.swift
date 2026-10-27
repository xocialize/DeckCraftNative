// DCAutomation — the MCP server: JSON-RPC 2.0 framing and the MCP lifecycle, tools and resources methods,
// forwarding everything to a `Backend`. Port of deckcraft crates/mcp/src/server.rs and lib.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors), on the official MCP Swift SDK.
//
// How the work is split:
//
// - `MCPServer` (an actor) is deckcraft's `Server::handle_line` / `handle`: it parses each line with
//   serde_json's rules (DCCore), answers what isn't a request (parse errors, batches, invalid messages,
//   notifications, responses), and hands each request to an SDK `Server` through an in-memory transport
//   pair, one at a time and in order, as deckcraft's single-threaded loop runs them.
// - The SDK server routes the request to its handler (`initialize`, `ping`, `tools/*`, `resources/*`),
//   whose work is `MCPCore.request` (deckcraft's `Server::request`), run on the `EngineThread`, so the
//   engine has a 32 MiB stack.
// - deckcraft's replies are serde_json `Value`s. The SDK's `Value` and `ID` can't carry all of them
//   faithfully (integer and float are one `.int` after a JSON round trip, `1.0` encodes as `1`, an `id`
//   may be any number), so the request's exact parameters and the handler's exact outcome travel beside
//   the SDK in `Exchange`, and the reply line is written from them with serde_json's layout. Through the
//   SDK alone (no exchange) the handlers still work, on its decoded values.
//
// A request's id goes to the SDK as a sequence number and comes back as the client's own id.
import DCCore
import DCEngine
import Foundation
import MCP
import Synchronization

/// JSON-RPC and MCP error codes deckcraft answers with.
public enum RPCCode {
    public static let parseError: Int64 = -32700
    public static let invalidRequest: Int64 = -32600
    public static let methodNotFound: Int64 = -32601
    public static let invalidParams: Int64 = -32602
    public static let internalError: Int64 = -32603
    public static let resourceNotFound: Int64 = -32002
}

/// A JSON-RPC error: its code and message.
public struct RPCError: Error, Sendable, Equatable {
    public var code: Int64
    public var message: String
    public init(_ code: Int64, _ message: String) {
        self.code = code
        self.message = message
    }
}

public enum MCPProtocol {
    /// The MCP revision deckcraft implements.
    public static let version = "2025-06-18"
    static let supportedVersions = [version, "2025-03-26", "2024-11-05"]
    /// The version deckcraft-cli reports (`serverInfo.version`): the deckcraft this port follows.
    public static let serverVersion = "0.11.1"

    /// Resource URIs.
    public static let documentURI = "deckcraft://document"
    public static let commandsURI = "deckcraft://commands"

    static let instructions = "DeckCraft is a presentation app (a PowerPoint clone). Coordinates are points on the current slide (y down; the default 16:9 slide is 960×540). Every action is a command: find ids and parameters with list_commands and run them with run_command (or several with batch). Typical flow: new_presentation → add_slide {layout:\"titleAndContent\", title, body} → add_shape / add_text_box / insert_picture / insert_chart → inspect_slide to read back ids, boxes and text → render_slide to look at the result. Shape ids are looked up on the current slide. An inserted shape is selected; run_command edit.select {ids:[…]} selects others. format.* acts on the selected text or shapes; shape.fill, shape.line and the other shape commands whose parameters list `ids` act on those shapes, else on the selected ones. Save with save_presentation (.deckcraft or .pptx)."

    /// The methods `MCPCore.request` answers (anything else is "method not found").
    static let methods = ["initialize", "ping", "tools/list", "tools/call", "resources/list", "resources/templates/list", "resources/read"]
}

/// deckcraft's `Server::request` and `notification`: what each MCP method does with the backend. Lives on
/// the server's `EngineThread`.
final class MCPCore {
    let backend: Backend
    var initialized = false

    init(backend: Backend) { self.backend = backend }

    func notification(_ method: String) {
        if method == "notifications/initialized" { initialized = true }
        // `notifications/cancelled`, `progress`, `roots/list_changed` and others are ignored.
    }

    func request(_ method: String, _ params: JSON) -> Result<JSON, RPCError> {
        switch method {
        case "initialize":
            let asked = params.get("protocolVersion")?.asStr ?? MCPProtocol.version
            let version = MCPProtocol.supportedVersions.contains { rustEqual($0, asked) } ? asked : MCPProtocol.version
            let instructions = "\(MCPProtocol.instructions) Backend: \(backend.describe()). Community: \(Links.discord) (Discord), \(Links.appPage) (app page), \(Links.github) (source). The `app.links` command returns these links."
            return .success([
                "protocolVersion": .string(version),
                "capabilities": ["tools": .emptyObject, "resources": .emptyObject],
                "serverInfo": ["name": "deckcraft", "title": "DeckCraft", "version": .string(MCPProtocol.serverVersion), "websiteUrl": .string(Links.appPage)],
                "instructions": .string(instructions),
            ])
        case "ping":
            return .success(.emptyObject)
        case "tools/list":
            return .success(["tools": .array(MCPTools.definitions)])
        case "tools/call":
            guard let name = params.get("name")?.asStr else { return .failure(RPCError(RPCCode.invalidParams, "missing tool `name`")) }
            return .success(MCPTools.call(backend, name, params.get("arguments") ?? .null).toJSON())
        case "resources/list":
            return .success(["resources": [
                [
                    "uri": .string(MCPProtocol.documentURI), "name": "document", "title": "Active document",
                    "description": "Slides (titles, layouts, shapes), sections, theme, media and selection of the active presentation (document.inspect)",
                    "mimeType": "application/json",
                ],
                [
                    "uri": .string(MCPProtocol.commandsURI), "name": "commands", "title": "Commands",
                    "description": "Every command: id, label, menu path, shortcut, params, enabled (engine.commands)", "mimeType": "application/json",
                ],
            ]])
        case "resources/templates/list":
            return .success(["resourceTemplates": []])
        case "resources/read":
            guard let uri = params.get("uri")?.asStr else { return .failure(RPCError(RPCCode.invalidParams, "missing `uri`")) }
            let v: JSON
            do {
                switch uri {
                case MCPProtocol.documentURI: v = try backend.call("document.inspect", .emptyObject)
                case MCPProtocol.commandsURI: v = try backend.call("engine.commands", .emptyObject)
                default: return .failure(RPCError(RPCCode.resourceNotFound, "resource not found: \(uri)"))
                }
            } catch {
                return .failure(RPCError(RPCCode.internalError, error.message))
            }
            return .success(["contents": [["uri": .string(uri), "mimeType": "application/json", "text": .string(v.pretty)]]])
        default:
            return .failure(RPCError(RPCCode.methodNotFound, "method not found: \(method)"))
        }
    }
}

/// The request in flight between the framing and the SDK handler: its exact parameters, and the
/// handler's exact outcome. One at a time.
final class Exchange: Sendable {
    private struct Slot {
        var params: JSON?
        var outcome: Result<JSON, RPCError>?
    }

    private let slot = Mutex(Slot())

    func put(params: JSON) { slot.withLock { $0 = Slot(params: params, outcome: nil) } }
    func takeParams() -> JSON? { slot.withLock { s in defer { s.params = nil }; return s.params } }
    func put(outcome: Result<JSON, RPCError>) { slot.withLock { $0.outcome = outcome } }
    func takeOutcome() -> Result<JSON, RPCError>? { slot.withLock { s in defer { s.outcome = nil }; return s.outcome } }
}

/// The SDK's view of an MCP method deckcraft answers: any JSON in, any JSON out.
protocol DeckcraftMethod: MCP.Method where Parameters == MCP.Value, Result == MCP.Value {}
enum InitializeMethod: DeckcraftMethod { static let name = "initialize" }
enum PingMethod: DeckcraftMethod { static let name = "ping" }
enum ToolsListMethod: DeckcraftMethod { static let name = "tools/list" }
enum ToolsCallMethod: DeckcraftMethod { static let name = "tools/call" }
enum ResourcesListMethod: DeckcraftMethod { static let name = "resources/list" }
enum ResourceTemplatesListMethod: DeckcraftMethod { static let name = "resources/templates/list" }
enum ResourcesReadMethod: DeckcraftMethod { static let name = "resources/read" }

/// Replies from the SDK, handed to whoever waits for the next one.
final class Mailbox: Sendable {
    private struct State {
        var queued: [Data] = []
        var waiting: CheckedContinuation<Data?, Never>?
        var closed = false
    }

    private let state = Mutex(State())

    func put(_ d: Data) {
        let c: CheckedContinuation<Data?, Never>? = state.withLock { s in
            if let w = s.waiting {
                s.waiting = nil
                return w
            }
            s.queued.append(d)
            return nil
        }
        c?.resume(returning: d)
    }

    func close() {
        let c = state.withLock { s in
            s.closed = true
            defer { s.waiting = nil }
            return s.waiting
        }
        c?.resume(returning: nil)
    }

    /// The next reply, nil once the SDK side has closed.
    func take() async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            let ready: Data?? = state.withLock { s in
                if !s.queued.isEmpty { return .some(s.queued.removeFirst()) }
                if s.closed { return .some(nil) }
                s.waiting = c
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }
}

/// An MCP server bound to one backend.
public actor MCPServer {
    let engine: EngineThread
    let core: EngineConfined<MCPCore>
    let exchange = Exchange()
    let mailbox = Mailbox()
    var sdk: Server?
    var client: InMemoryTransport?
    var nextId = 0

    /// A server over `backend`, which it takes over: from now on the backend is used only on the server's
    /// engine thread.
    public init(_ backend: Backend) {
        engine = EngineThread(name: "dc.mcp")
        core = EngineConfined(MCPCore(backend: backend))
    }

    deinit { engine.stop() }

    /// Whether the client has sent `notifications/initialized`.
    public var isInitialized: Bool {
        get async {
            let core = core
            return await engine.run { core.value.initialized } ?? false
        }
    }

    /// Runs `body` with the backend on the engine thread.
    public func withBackend<T: Sendable>(_ body: @escaping @Sendable (Backend) -> T) async -> T? {
        let core = core
        return await engine.run { body(core.value.backend) }
    }

    /// The SDK server and the client end of its transport, started on first use.
    private func connection() async throws -> InMemoryTransport {
        if let client { return client }
        let server = Server(
            name: "deckcraft", version: MCPProtocol.serverVersion, title: "DeckCraft",
            capabilities: Server.Capabilities(resources: .init(), tools: .init())
        )
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverSide)
        // Registered after `start`, so `initialize` and `ping` replace the SDK's defaults.
        await register(InitializeMethod.self, on: server)
        await register(PingMethod.self, on: server)
        await register(ToolsListMethod.self, on: server)
        await register(ToolsCallMethod.self, on: server)
        await register(ResourcesListMethod.self, on: server)
        await register(ResourceTemplatesListMethod.self, on: server)
        await register(ResourcesReadMethod.self, on: server)
        try await clientSide.connect()
        let replies = await clientSide.receive()
        let mailbox = mailbox
        Task {
            do { for try await d in replies { mailbox.put(d) } } catch {}
            mailbox.close()
        }
        sdk = server
        client = clientSide
        return clientSide
    }

    private func register<M: DeckcraftMethod>(_ m: M.Type, on server: Server) async {
        let exchange = exchange, engine = engine, core = core
        await server.withMethodHandler(M.self) { sdkParams in
            let params = exchange.takeParams() ?? JSON(mcp: sdkParams)
            let outcome = await engine.run { core.value.request(M.name, params) }
                ?? .failure(RPCError(RPCCode.internalError, "the MCP server has stopped"))
            exchange.put(outcome: outcome)
            switch outcome {
            case .success(let v): return MCP.Value(json: v)
            case .failure(let e): throw MCPError.serverError(code: Int(e.code), message: e.message)
            }
        }
    }

    /// Stops the SDK server and the engine thread.
    public func stop() async {
        await client?.disconnect()
        await sdk?.stop()
        client = nil
        sdk = nil
        engine.stop()
    }

    static func response(_ id: JSON, _ result: JSON) -> JSON { ["jsonrpc": "2.0", "id": id, "result": result] }

    static func error(_ id: JSON, _ code: Int64, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .integer(code), "message": .string(message)]]
    }

    /// Handle one line; the reply line (nil for notifications and blank lines).
    public func handleLine(_ line: String) async -> String? {
        let text = String(rustTrim(line))
        if text.isEmpty { return nil }
        let reply: JSON?
        switch Result(catching: { () throws(JSONParseError) -> JSON in try JSONParser.parse(text) }) {
        case .success(.array(let batch)):
            // Batches were removed in 2025-06-18; still answer older clients sensibly.
            if batch.isEmpty {
                reply = Self.error(.null, RPCCode.invalidRequest, "empty batch")
            } else {
                var replies: [JSON] = []
                for m in batch {
                    if let r = await handle(m) { replies.append(r) }
                }
                reply = replies.isEmpty ? nil : .array(replies)
            }
        case .success(let msg):
            reply = await handle(msg)
        case .failure(let e):
            reply = Self.error(.null, RPCCode.parseError, "parse error: \(e)")
        }
        return reply?.display
    }

    /// Handle one JSON-RPC message; nil for notifications and responses.
    public func handle(_ msg: JSON) async -> JSON? {
        guard case .object(let raw) = msg else { return Self.error(.null, RPCCode.invalidRequest, "message must be an object") }
        // serde_json's map: each key once, the last one kept.
        let o = JSON.object(raw).canonical
        let id = o.get("id")
        guard let method = o.get("method")?.asStr else {
            // A response to a server→client request (we send none): ignore. Anything else is invalid.
            if o.get("result") != nil || o.get("error") != nil { return nil }
            return Self.error(id ?? .null, RPCCode.invalidRequest, "missing `method`")
        }
        let params = o.get("params") ?? .null
        guard let id else {
            let core = core
            _ = await engine.run { core.value.notification(method) }
            return nil
        }
        guard id.isString || id.isNumber else { return Self.error(.null, RPCCode.invalidRequest, "`id` must be a string or number") }
        switch await request(method, params) {
        case .success(let r): return Self.response(id, r)
        case .failure(let e): return Self.error(id, e.code, e.message)
        }
    }

    /// One request through the SDK server; its exact outcome.
    func request(_ method: String, _ params: JSON) async -> Result<JSON, RPCError> {
        let client: InMemoryTransport
        do { client = try await connection() } catch { return .failure(RPCError(RPCCode.internalError, "the MCP server could not start: \(error)")) }
        nextId += 1
        var message: JSON = ["jsonrpc": "2.0", "id": .integer(nextId), "method": .string(method)]
        if !params.isNull { message.set("params", params) }
        exchange.put(params: params)
        _ = exchange.takeOutcome()
        do {
            try await client.send(Data(message.display.utf8))
        } catch {
            _ = exchange.takeParams()
            return .failure(RPCError(RPCCode.internalError, "the MCP server is not running: \(error)"))
        }
        guard let data = await mailbox.take() else {
            return .failure(RPCError(RPCCode.internalError, "the MCP server has stopped"))
        }
        _ = exchange.takeParams()
        if let outcome = exchange.takeOutcome() { return outcome }
        // The SDK answered by itself: a method no handler takes. deckcraft's own answer says so.
        if !MCPProtocol.methods.contains(method) {
            let core = core
            return await engine.run { core.value.request(method, params) } ?? .failure(RPCError(RPCCode.methodNotFound, "method not found: \(method)"))
        }
        // Anything else the SDK said, as it said it.
        let reply = (try? JSONParser.parse(data)) ?? .null
        if let e = reply.get("error") {
            return .failure(RPCError(e.get("code")?.asI64 ?? RPCCode.internalError, e.get("message")?.asStr ?? "internal error"))
        }
        return .success(reply.get("result") ?? .null)
    }
}

// MARK: - DCCore JSON and the SDK's Value

extension JSON {
    /// The SDK's value as JSON (a whole double stays a float).
    init(mcp v: MCP.Value) {
        switch v {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .int(let i): self = .integer(i)
        case .double(let d): self = .num(d)
        case .string(let s): self = .string(s)
        case .data(let mime, let d): self = .string("data:\(mime ?? "application/octet-stream");base64,\(d.base64EncodedString())")
        case .array(let a): self = .array(a.map { JSON(mcp: $0) })
        case .object(let o):
            let sorted = o.sorted { byteOrder($0.key, $1.key) }
            self = .object(JSONObject(sorted.map { JSONObject.Entry(key: $0.key, value: JSON(mcp: $0.value)) }))
        }
    }
}

extension MCP.Value {
    /// The JSON as the SDK's value (integers beyond `Int` become doubles).
    init(json: JSON) {
        switch json {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .uint(let u): self = Int(exactly: u).map(MCP.Value.int) ?? .double(Double(u))
        case .int(let i): self = Int(exactly: i).map(MCP.Value.int) ?? .double(Double(i))
        case .double(let d): self = d.isFinite ? .double(d) : .null
        case .float(let f): self = f.isFinite ? .double(Double(f)) : .null
        case .string(let s): self = .string(s)
        case .array(let a): self = .array(a.map { MCP.Value(json: $0) })
        case .object(let o):
            var d: [String: MCP.Value] = [:]
            for e in o.entries { d[e.key] = MCP.Value(json: e.value) }
            self = .object(d)
        }
    }
}
