// dccliTests — `dccli mcp` end to end: the built binary spawned and spoken to over stdio, beside the
// oracle's `deckcraft-cli mcp`, through the MCP Swift SDK's own client, against a fake app on a loopback
// control port, and with engine work deep enough to need the engine thread's stack.
import DCAutomation
import DCCore
import DCEngine
import Darwin
import Foundation
import MCP
import System
import Testing

/// A JSON-RPC request line.
func rpc(_ id: Int, _ method: String, _ params: JSON? = nil) -> String {
    var o: JSON = ["jsonrpc": "2.0", "id": .integer(id), "method": .string(method)]
    if let params { o.set("params", params) }
    return o.display
}

/// A `tools/call` request line.
func toolCall(_ id: Int, _ name: String, _ args: String = "{}") -> String {
    rpc(id, "tools/call", ["name": .string(name), "arguments": (try? JSONParser.parse(args)) ?? .emptyObject])
}

/// Which binary a session runs.
enum Side { case ours, oracle }

/// Lines in, one reply per line out.
func session(_ side: Side, _ args: [String] = [], _ lines: [String]) throws -> (Ran, [String]) {
    let input = Data((lines.joined(separator: "\n") + "\n").utf8)
    let r = side == .ours ? try dccli(["mcp"] + args, input: input) : try oracle(["mcp"] + args, input: input)
    return (r, r.stdout.components(separatedBy: "\n").filter { !$0.isEmpty })
}

/// A reply's tool result text, parsed when it is JSON.
func toolText(_ line: String) -> JSON {
    let v = (try? JSONParser.parse(line)) ?? .null
    let text = v.get("result")?.get("content")?.asArray?.first { $0.get("type") == "text" }?.get("text")?.asStr ?? ""
    return (try? JSONParser.parse(text)) ?? .string(text)
}

func isToolError(_ line: String) -> Bool { (try? JSONParser.parse(line))?.get("result")?.get("isError") == true }

/// A fake DeckCraft app on a loopback control port: the app's own control server, its requests answered by a
/// control channel over a headless session.
final class FakeApp: Sendable {
    let channel = ControlChannel(HeadlessControlHost(Session.withNew()))
    let server: ControlServer
    var port: UInt16 { server.port }

    init() throws { server = try channel.serve() }

    func stop() { server.stop() }
}

@Suite("dccli mcp, end to end", .enabled(if: Binaries.haveDccli, "dccli isn't built"))
struct MCPProcessTests {
    /// A session an agent might run, every reply deterministic (no pictures, no pointer).
    static func agentSession(_ dir: URL) -> [String] {
        [
            rpc(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": .emptyObject, "clientInfo": ["name": "t", "version": "1"]]),
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            rpc(2, "tools/list"),
            rpc(3, "resources/list"),
            toolCall(4, "inspect_document"),
            toolCall(5, "new_presentation", #"{"theme": "Harbor"}"#),
            toolCall(6, "add_slide", #"{"layout": "titleAndContent", "title": "Highlights", "body": "Revenue up\n\tNew markets\nCosts down"}"#),
            toolCall(7, "add_shape", #"{"preset": "roundRect", "x": 600, "y": 300, "w": 200, "h": 100, "text": "Goal", "fill": "accent2", "line": "none"}"#),
            toolCall(8, "add_text_box", ##"{"x": 40, "y": 400, "w": 300, "text": "Note\nTwo", "size": 18, "color": "#336699", "align": "center"}"##),
            toolCall(9, "insert_table", #"{"rows": 2, "cols": 3, "data": [["a", "b", "c"], ["1", "2", "3"]], "x": 40, "y": 40, "w": 400, "h": 100}"#),
            toolCall(10, "insert_chart", #"{"type": "pie", "categories": ["A", "B"], "series": [{"name": "S", "values": [3, 5]}]}"#),
            toolCall(11, "inspect_slide"),
            toolCall(12, "batch", #"{"commands": [{"command": "slide.new"}, {"command": "no.such"}, {"command": "slide.new"}], "keepGoing": true}"#),
            toolCall(13, "batch", #"{"commands": [{"command": "slide.new"}, {"command": "no.such"}, {"command": "slide.new"}]}"#),
            toolCall(14, "go_to_slide", #"{"index": 99}"#),
            toolCall(15, "set_text", #"{"id": 999999, "text": "x"}"#),
            toolCall(16, "list_commands", #"{"filter": "THEME"}"#),
            toolCall(17, "select_tool", #"{"tool": "highlighter"}"#),
            toolCall(18, "call_app", #"{"method": "ui.inspect"}"#),
            toolCall(19, "call_app", #"{"method": "ui.click", "params": {"x": 1, "y": 1}}"#),
            toolCall(20, "key", #"{"key": "z", "mods": {"cmd": true}}"#),
            toolCall(21, "type_text", #"{"text": "abc"}"#),
            toolCall(22, "screenshot"),
            toolCall(23, "insert_chart", #"{"type": "column", "data": [1]}"#),
            toolCall(24, "save_presentation", #"{"path": "\#(dir.path)/deck.deckcraft"}"#),
            toolCall(25, "export", #"{"path": "\#(dir.path)/deck.docx", "format": "docx"}"#),
            toolCall(26, "open_presentation", #"{"path": "\#(dir.path)/deck.deckcraft"}"#),
            rpc(27, "resources/read", ["uri": "deckcraft://document"]),
            rpc(28, "resources/read", ["uri": "deckcraft://commands"]),
            rpc(29, "ping"),
            rpc(30, "nope"),
            "not json",
            "[]",
            toolCall(31, "run_command", #"{"command": "shape.inspect", "params": {"id": 1.5}}"#),
            toolCall(32, "new_presentation", #"{"blank": true}"#),
            toolCall(33, "inspect_slide"),
        ]
    }

    @Test("A session's replies are the oracle's, byte for byte", .enabled(if: Binaries.haveOracle, "the oracle isn't built"))
    func sessionMatchesTheOracle() throws {
        // Both write their files in the same folder, one after the other.
        let dir = scratch("mcp-session")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lines = Self.agentSession(dir)
        let (a, ours) = try session(.ours, [], lines)
        try? FileManager.default.removeItem(at: dir.appending(path: "deck.deckcraft"))
        let (b, theirs) = try session(.oracle, [], lines)
        #expect(a.code == 0 && b.code == 0, "\(a.stderr)\(b.stderr)")
        #expect(ours.count == theirs.count, "\(ours.count) replies, the oracle's \(theirs.count)")
        // A saved file's size is DCZip's deflate, not deckcraft's (the presentation inside is the same).
        func masked(_ line: String) -> String { line.replacingOccurrences(of: #"\\"bytes\\": \d+"#, with: "<bytes>", options: .regularExpression) }
        for (i, (x, y)) in zip(ours.map(masked), theirs.map(masked)).enumerated() where x != y {
            Issue.record("reply \(i + 1):\n  ours:   \(x.prefix(600))\n  oracle: \(y.prefix(600))")
        }
        #expect(a.stderr == b.stderr)
    }

    @Test("Pictures come back as images, as the oracle's do")
    func renderSlideIsAnImage() throws {
        let lines = [toolCall(1, "render_slide"), toolCall(2, "new_presentation"), toolCall(3, "render_slide", #"{"scale": 0.5, "edit": true}"#),
                     toolCall(4, "render_slide", #"{"slide": 3}"#)]
        let (r, out) = try session(.ours, [], lines)
        #expect(r.code == 0 && out.count == 4)
        #expect(isToolError(out[0]) && toolText(out[0]) == "no presentation open")
        let v = (try? JSONParser.parse(out[2])) ?? .null
        let content = v.get("result")?.get("content")?.asArray ?? []
        #expect(content.first?.get("type") == "image" && content.first?.get("mimeType") == "image/png")
        let png = Data(base64Encoded: content.first?.get("data")?.asStr ?? "") ?? Data()
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(content.last?.get("text") == #"{"height":270,"slide":0,"width":480}"#)
        #expect(isToolError(out[3]) && toolText(out[3]) == "no slide 3")
    }

    @Test("The MCP Swift SDK's client works with dccli over stdio")
    func sdkClientOverStdio() async throws {
        let exe = try #require(Binaries.dccli)
        let toServer = Pipe(), fromServer = Pipe()
        let p = Process()
        p.executableURL = URL(filePath: exe)
        p.arguments = ["mcp", "--sample"]
        p.standardInput = toServer
        p.standardOutput = fromServer
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer {
            try? toServer.fileHandleForWriting.close()
            p.waitUntilExit()
        }
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor)
        )
        let client = Client(name: "dccli-tests", version: "1.0")
        let initialized = try await client.connect(transport: transport)
        #expect(initialized.serverInfo.name == "deckcraft")
        #expect(initialized.serverInfo.title == "DeckCraft")
        #expect(initialized.protocolVersion == "2025-06-18", "deckcraft answers its own version to a newer client")
        #expect(initialized.instructions?.contains("Backend: headless") == true)
        let (tools, _) = try await client.listTools()
        #expect(tools.map(\.name) == MCPTools.definitions.compactMap { $0.get("name")?.asStr })
        #expect(tools.first { $0.name == "export" }?.annotations.readOnlyHint == false)
        let (content, isError) = try await client.callTool(name: "inspect_document", arguments: [:])
        #expect(isError == false)
        guard case .text(let text, _, _)? = content.first else {
            Issue.record("no text: \(content)")
            return
        }
        #expect(text.contains("\"Northern Lights\""), "the sample deck is open")
        let (picture, _) = try await client.callTool(name: "render_slide", arguments: ["scale": .double(0.25)])
        guard case .image(let data, let mime, _, _)? = picture.first else {
            Issue.record("no image: \(picture)")
            return
        }
        #expect(mime == "image/png" && !data.isEmpty)
        let (_, refused) = try await client.callTool(name: "go_to_slide", arguments: ["index": .int(99)])
        #expect(refused == true)
        let contents = try await client.readResource(uri: "deckcraft://commands")
        #expect(contents.count == 1)
        await client.disconnect()
    }

    @Test("Thirty-two nested groups go through the process: the engine has its large stack")
    func deepGroups() throws {
        let dir = scratch("mcp-deep")
        defer { try? FileManager.default.removeItem(at: dir) }
        var commands: [JSON] = [["command": "slide.new", "params": ["layout": "blank"]], ["command": "insert.table", "params": ["rows": 2, "cols": 2]]]
        for _ in 0 ..< ArrangeCommands.maxGroupDepth {
            commands += [
                ["command": "shape.insert", "params": ["preset": "rect", "rect": [10, 10, 20, 20], "text": "deep"]],
                ["command": "edit.selectAll"], ["command": "arrange.group"],
            ]
        }
        let lines = [
            toolCall(1, "new_presentation"),
            rpc(2, "tools/call", ["name": "batch", "arguments": ["commands": .array(commands)]]),
            toolCall(3, "inspect_slide"),
            toolCall(4, "render_slide", #"{"scale": 0.5}"#),
            toolCall(5, "save_presentation", #"{"path": "\#(dir.path)/deep.pptx"}"#),
            toolCall(6, "open_presentation", #"{"path": "\#(dir.path)/deep.pptx"}"#),
            toolCall(7, "save_presentation", #"{"path": "\#(dir.path)/deep.deckcraft"}"#),
            toolCall(8, "open_presentation", #"{"path": "\#(dir.path)/deep.deckcraft"}"#),
            toolCall(9, "go_to_slide", #"{"index": 1}"#),
            toolCall(10, "inspect_slide"),
            toolCall(11, "run_command", #"{"command": "edit.selectAll"}"#),
            toolCall(12, "run_command", #"{"command": "edit.copy"}"#),
            toolCall(13, "run_command", #"{"command": "edit.paste"}"#),
            toolCall(14, "inspect_document"),
        ]
        let (r, out) = try session(.ours, [], lines)
        #expect(r.code == 0, "exit \(r.code): \(r.stderr)")
        #expect(out.count == lines.count)
        for (i, line) in out.enumerated() { #expect(!isToolError(line), "reply \(i + 1): \(line.prefix(300))") }
        let groups = toolText(out[1]).asArray?.filter { $0.get("command") == "arrange.group" }.count
        #expect(groups == ArrangeCommands.maxGroupDepth)
        #expect(toolText(out[9]).get("shapes")?.asArray?.count == 1, "one group, 32 deep, after a .pptx and a .deckcraft round trip")
    }

    @Test("The automation roots confine the server's files")
    func automationRoots() throws {
        let dir = scratch("mcp-roots")
        defer { try? FileManager.default.removeItem(at: dir) }
        let read = dir.appending(path: "in"), write = dir.appending(path: "out")
        try FileManager.default.createDirectory(at: read, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: write, withIntermediateDirectories: true)
        let lines = [
            toolCall(1, "new_presentation"),
            toolCall(2, "save_presentation", #"{"path": "\#(write.path)/ok.deckcraft"}"#),
            toolCall(3, "save_presentation", #"{"path": "\#(dir.path)/outside.deckcraft"}"#),
            toolCall(4, "open_presentation", #"{"path": "\#(write.path)/ok.deckcraft"}"#),
            toolCall(5, "export", #"{"path": "\#(write.path)/../escape.pdf"}"#),
        ]
        let (r, out) = try session(.ours, ["--automation-read-root", read.path, "--automation-write-root", write.path], lines)
        #expect(r.code == 0)
        #expect(r.stderr.hasPrefix("deckcraft-cli: files confined: read root "), "\(r.stderr)")
        #expect(!isToolError(out[1]) && FileManager.default.fileExists(atPath: write.appending(path: "ok.deckcraft").path))
        #expect(isToolError(out[2]) && toolText(out[2]).asStr?.contains("outside the write root") == true, "\(out[2])")
        #expect(isToolError(out[3]), "the write root grants no read access: \(out[3])")
        #expect(isToolError(out[4]) && !FileManager.default.fileExists(atPath: dir.appending(path: "escape.pdf").path))
        if Binaries.haveOracle {
            let (b, theirs) = try session(.oracle, ["--automation-read-root", read.path, "--automation-write-root", write.path], lines)
            #expect(r.stderr == b.stderr)
            #expect(Array(out.dropFirst(2)) == Array(theirs.dropFirst(2)), "the refusals are the oracle's")
        }
    }

    @Test("`mcp --connect` and `app` drive a running app through its control port")
    func connectedToAnApp() throws {
        let app = try FakeApp()
        defer { app.stop() }
        let lines = [
            rpc(1, "initialize", ["protocolVersion": "2025-06-18"]),
            toolCall(2, "add_shape", ##"{"preset": "star5", "x": 10, "y": 10, "w": 100, "h": 100, "fill": "#ff0000"}"##),
            toolCall(3, "inspect_slide"),
            toolCall(4, "screenshot"),
            toolCall(5, "call_app", #"{"method": "ui.inspect"}"#),
            toolCall(6, "pointer", #"{"events": [{"kind": "down", "x": 1, "y": 1}]}"#),
        ]
        let (r, out) = try session(.ours, ["--connect", "\(app.port)"], lines)
        #expect(r.code == 0, "\(r.stderr)")
        let instructions = ((try? JSONParser.parse(out[0]))?.get("result")?.get("instructions")?.asStr) ?? ""
        #expect(instructions.contains("Backend: connected to the DeckCraft app at 127.0.0.1:\(app.port)."))
        #expect(!isToolError(out[1]), "\(out[1])")
        #expect(toolText(out[2]).display.contains("star5"), "\(out[2].prefix(400))")
        #expect(isToolError(out[3]), "the fake app has no window: \(out[3])")
        #expect(toolText(out[4]).get("headless") == true)
        #expect(!isToolError(out[5]) && toolText(out[5]).get("result") == ["hit": .null], "the pointer drives the app's session: \(out[5])")
        // The fake app's session holds what the agent made.
        let doc = app.channel.call("document.inspect", .emptyObject)
        #expect(doc.get("ok") == true)
        // `app` sends one request.
        var a = try dccli(["app", "--port", "\(app.port)", "slide.new", #"{"layout":"blank"}"#])
        #expect(a.code == 0 && (try? JSONParser.parse(a.stdout))?.get("index") == 1, "\(a.stdout)\(a.stderr)")
        a = try dccli(["app", "--port", "\(app.port)", "--method", "document.inspect"])
        #expect(a.code == 0 && (try? JSONParser.parse(a.stdout))?.get("slides")?.asArray?.count == 2)
        a = try dccli(["app", "--port", "\(app.port)", "--method", "ui.click", "{}"])
        #expect(a.code == 1 && a.stderr.hasPrefix("deckcraft-cli: `ui.click`: it needs the desktop app"), "\(a.stderr)")
        a = try dccli(["app", "--port", "\(app.port)", "slide.new", "{bad"])
        #expect(a.code == 1 && a.stderr == "deckcraft-cli: bad JSON: key must be a string at line 1 column 2\n", "\(a.stderr)")
        if Binaries.haveOracle {
            // The oracle's `app` against a fresh fake app prints the same.
            let other = try FakeApp()
            defer { other.stop() }
            let fresh = try FakeApp()
            defer { fresh.stop() }
            for args in [["slide.new", #"{"layout":"blank"}"#], ["--method", "document.inspect"], ["--method", "ui.click", "{}"], ["--method", "engine.commands"]] {
                let x = try dccli(["app", "--port", "\(fresh.port)"] + args)
                let y = try oracle(["app", "--port", "\(other.port)"] + args)
                #expect(x.code == y.code && x.stdout == y.stdout && x.stderr == y.stderr, "\(args)\n\(x.stdout)\(x.stderr)\n---\n\(y.stdout)\(y.stderr)")
            }
        }
    }
}
