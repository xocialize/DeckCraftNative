// DCAutomationTests — an agent builds a small deck entirely through MCP and checks its work only through
// MCP. Port of deckcraft crates/mcp/src/tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors): every test, through `MCPServer.handleLine`, the path a stdio line takes (the SDK server
// and the engine thread included).
import DCCore
@testable import DCAutomation
import DCEngine
import Foundation
import Testing

/// `json!(…)` from JSON text.
func j(_ text: String) -> JSON { (try? JSONParser.parse(text).canonical) ?? .null }

/// One request through the server; its parsed reply.
func call(_ s: MCPServer, _ id: Int, _ method: String, _ params: JSON, sourceLocation: SourceLocation = #_sourceLocation) async -> JSON {
    let line: JSON = ["jsonrpc": "2.0", "id": .integer(id), "method": .string(method), "params": params]
    guard let out = await s.handleLine(line.display) else {
        Issue.record("\(method): no response", sourceLocation: sourceLocation)
        return .null
    }
    do { return try JSONParser.parse(out) } catch {
        Issue.record("\(method): not JSON: \(out)", sourceLocation: sourceLocation)
        return .null
    }
}

/// A tool call that must succeed; its text parsed as JSON (or the text itself).
@discardableResult
func tool(_ s: MCPServer, _ name: String, _ args: JSON, sourceLocation: SourceLocation = #_sourceLocation) async -> JSON {
    let r = await call(s, 9, "tools/call", ["name": .string(name), "arguments": args], sourceLocation: sourceLocation)
    let res = r.get("result") ?? .null
    #expect(res.get("isError") == .bool(false), "\(name) failed: \(res.display)", sourceLocation: sourceLocation)
    let text = (res.get("content")?.asArray ?? []).first { $0.get("type")?.asStr == "text" }?.get("text")?.asStr ?? ""
    return (try? JSONParser.parse(text)) ?? .string(text)
}

/// The first content block's text of a tool call's result.
func firstText(_ r: JSON) -> String { r.get("result")?.get("content")?.at(0)?.get("text")?.asStr ?? "" }

func headless() -> MCPServer { MCPServer(Headless()) }

func shapes(_ v: JSON) -> [JSON] { v.get("shapes")?.asArray ?? [] }

func scratch(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "dcautomation-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0 ... .max))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("MCP server (deckcraft-mcp tests.rs)")
struct MCPServerTests {
    @Test func handshakeAndToolList() async {
        let s = headless()
        let r = await call(s, 1, "initialize", j(#"{"protocolVersion": "2025-06-18"}"#))
        #expect(r.get("result")?.get("serverInfo")?.get("name") == "deckcraft")
        let tools = await call(s, 2, "tools/list", .emptyObject)
        let names = (tools.get("result")?.get("tools")?.asArray ?? []).compactMap { $0.get("name")?.asStr }
        for n in ["run_command", "render_slide", "add_slide", "add_shape", "pointer", "inspect_slide"] {
            #expect(names.contains(n), "\(n)")
        }
        // Garbage never panics.
        #expect(await s.handleLine("not json") != nil)
        #expect(await s.handleLine("{}") != nil)
        await s.stop()
    }

    @Test func agentBuildsADeck() async {
        let s = headless()
        await tool(s, "new_presentation", j(#"{"theme": "Harbor"}"#))
        _ = await tool(s, "inspect_document", .emptyObject)
        let titleId = (await tool(s, "inspect_slide", .emptyObject)).get("shapes")?.at(0)?.get("id")?.asU64 ?? 0
        await tool(s, "set_text", ["id": .integer(titleId), "text": "Quarterly Review"])
        await tool(s, "add_slide", j(#"{"layout": "titleAndContent", "title": "Highlights", "body": "Revenue up\n\tNew markets\nCosts down"}"#))
        let shape = await tool(s, "add_shape", j(#"{"preset": "roundRect", "x": 600, "y": 300, "w": 200, "h": 100, "text": "Goal", "fill": "accent2"}"#))
        let sid = shape.get("id")?.asU64 ?? 0
        await tool(s, "run_command", ["command": "shape.rotate", "params": ["id": .integer(sid), "deg": 10]])
        // Drag the shape with the pointer.
        await tool(s, "pointer", j(#"{"events": [{"kind": "down", "x": 700, "y": 350}, {"kind": "drag", "x": 650, "y": 330}, {"kind": "up", "x": 650, "y": 330}]}"#))
        await tool(s, "insert_chart", j(#"{"type": "pie", "categories": ["A", "B"], "series": [{"name": "S", "values": [3, 5]}]}"#))
        let sl = await tool(s, "inspect_slide", .emptyObject)
        #expect(sl.get("title") == "Highlights")
        let goal = shapes(sl).first { $0.get("id")?.asU64 == sid } ?? .null
        #expect(goal.get("text") == "Goal")
        #expect(goal.get("rotation")?.asF64 == 10.0)
        #expect((goal.get("box")?.at(0)?.asF64 ?? 600) < 600.0, "moved left: \(goal.display)")
        #expect(shapes(sl).contains { $0.get("kind") == "chart" })
        let doc = await tool(s, "inspect_document", .emptyObject)
        #expect(doc.get("slides")?.asArray?.count == 2)
        #expect(doc.get("theme") == "Harbor")
        // Look at it.
        let r = await call(s, 10, "tools/call", j(#"{"name": "render_slide", "arguments": {"scale": 0.25}}"#))
        #expect(r.get("result")?.get("content")?.at(0)?.get("type") == "image")
        // Keyboard: select the shape, delete it, undo.
        await tool(s, "select", ["ids": [.integer(sid)]])
        await tool(s, "key", j(#"{"key": "Delete"}"#))
        let n1 = shapes(await tool(s, "inspect_slide", .emptyObject)).count
        await tool(s, "key", j(#"{"key": "z", "mods": {"cmd": true}}"#))
        let n2 = shapes(await tool(s, "inspect_slide", .emptyObject)).count
        #expect(n2 == n1 + 1)
        await s.stop()
    }

    @Test func setTextUnknownIdIsError() async {
        let s = headless()
        await tool(s, "new_presentation", j(#"{"theme": "Harbor"}"#))
        let titleId = (await tool(s, "inspect_slide", .emptyObject)).get("shapes")?.at(0)?.get("id")?.asU64 ?? 0
        await tool(s, "select", ["ids": [.integer(titleId)]])
        // -1 and 2^32 are not shape ids; they must not fall back to the selection.
        for bad in [j("999999"), j("-1"), j("4294967296")] {
            let r = await call(s, 1, "tools/call", ["name": "set_text", "arguments": ["id": bad, "text": "x"]])
            #expect(r.get("result")?.get("isError") == true, "\(bad.display): \(r.display)")
        }
        // A real id, and a just-created shape, still work; omitting id still uses the selection.
        await tool(s, "set_text", ["id": .integer(titleId), "text": "Real"])
        let sid = (await tool(s, "add_shape", j(#"{"preset": "rect", "x": 10, "y": 10, "w": 50, "h": 50}"#))).get("id")?.asU64 ?? 0
        await tool(s, "set_text", ["id": .integer(sid), "text": "Fresh"])
        await tool(s, "select", ["ids": [.integer(titleId)]])
        await tool(s, "set_text", j(#"{"text": "Selected"}"#))
        let sl = await tool(s, "inspect_slide", .emptyObject)
        func textOf(_ id: UInt64) -> JSON? { shapes(sl).first { $0.get("id")?.asU64 == id }?.get("text") }
        #expect(textOf(sid) == "Fresh")
        #expect(textOf(titleId) == "Selected")
        await s.stop()
    }

    @Test func invalidIdNeverFallsBackToSelection() async {
        let s = headless()
        await tool(s, "new_presentation", j(#"{"theme": "Harbor"}"#))
        let titleId = (await tool(s, "inspect_slide", .emptyObject)).get("shapes")?.at(0)?.get("id")?.asU64 ?? 0
        await tool(s, "select", ["ids": [.integer(titleId)]])
        for cmd in ["text.edit", "text.get", "shape.inspect", "table.selectCells", "arrange.reorder"] {
            for bad in [j("-1"), j("1.5"), j(#""7""#), j("4294967296")] {
                let r = await call(s, 1, "tools/call", ["name": "run_command", "arguments": ["command": .string(cmd), "params": ["id": bad, "index": 0]]])
                #expect(r.get("result")?.get("isError") == true, "\(cmd) \(bad.display): \(r.display)")
            }
        }
        // Absent id still means the selection, and a real id still works.
        await tool(s, "run_command", j(#"{"command": "text.get", "params": {}}"#))
        await tool(s, "run_command", ["command": "text.get", "params": ["id": .integer(titleId)]])
        await tool(s, "run_command", ["command": "shape.inspect", "params": ["id": .integer(titleId)]])
        await s.stop()
    }

    @Test func unknownToolArgumentsAreRefused() async {
        let s = headless()
        await tool(s, "new_presentation", .emptyObject)
        func charts(_ v: JSON) -> Int { shapes(v).filter { $0.get("kind") == "chart" }.count }
        let before = charts(await tool(s, "inspect_slide", .emptyObject))
        var r = await call(s, 2, "tools/call", j(#"{"name": "insert_chart", "arguments": {"type": "column", "data": [["x", "A"], ["q1", 1]]}}"#))
        #expect(r.get("result")?.get("isError") == true)
        var msg = firstText(r)
        #expect(msg.contains("unknown argument \"data\"") && msg.contains("categories") && msg.contains("series"), "\(msg)")
        #expect(charts(await tool(s, "inspect_slide", .emptyObject)) == before, "a refused call inserts nothing")
        r = await call(s, 3, "tools/call", j(#"{"name": "list_commands", "arguments": {"query": "theme", "limit": 1}}"#))
        #expect(r.get("result")?.get("isError") == true)
        msg = firstText(r)
        #expect(msg.contains("unknown arguments \"limit\", \"query\"") && msg.contains("filter"), "\(msg)")
        // The command's own parameters stay inside `params`.
        await tool(s, "run_command", j(#"{"command": "slide.new", "params": {"layout": "blank"}}"#))
        let tools = await call(s, 4, "tools/list", .emptyObject)
        let chart = (tools.get("result")?.get("tools")?.asArray ?? []).first { $0.get("name") == "insert_chart" }
        #expect(chart?.get("inputSchema")?.get("additionalProperties") == false)
        await s.stop()
    }

    @Test func errorsAreReportedNotPanics() async {
        let s = headless()
        var r = await call(s, 1, "tools/call", j(#"{"name": "run_command", "arguments": {"command": "no.such"}}"#))
        #expect(r.get("result")?.get("isError") == true)
        r = await call(s, 2, "tools/call", j(#"{"name": "screenshot", "arguments": {}}"#))
        #expect(r.get("result")?.get("isError") == true)
        r = await call(s, 3, "tools/call", j(#"{"name": "add_shape", "arguments": {"preset": "rect"}}"#))
        #expect(r.get("result")?.get("isError") == true)
        await s.stop()
    }

    @Test func goToSlideOutOfRangeIsError() async {
        let s = headless()
        await tool(s, "new_presentation", j(#"{"theme": "Harbor"}"#))
        await tool(s, "add_slide", j(#"{"layout": "titleAndContent", "title": "Second", "body": "x"}"#))
        // Boundaries stay valid: first and last slide.
        await tool(s, "go_to_slide", j(#"{"index": 0}"#))
        await tool(s, "go_to_slide", j(#"{"index": 1}"#))
        #expect((await tool(s, "inspect_slide", .emptyObject)).get("title") == "Second")
        for bad in [j("2"), j("99")] {
            let r = await call(s, 1, "tools/call", ["name": "go_to_slide", "arguments": ["index": bad]])
            #expect(r.get("result")?.get("isError") == true, "\(bad.display): \(r.display)")
            #expect((await tool(s, "inspect_slide", .emptyObject)).get("title") == "Second", "failed go_to_slide must not move")
        }
        await s.stop()
    }

    private func exportTool(_ s: MCPServer) async -> JSON {
        let tools = await call(s, 1, "tools/list", .emptyObject)
        return (tools.get("result")?.get("tools")?.asArray ?? []).first { $0.get("name") == "export" } ?? .null
    }

    @Test func exportToolListsPdfAndItsOptions() async throws {
        let s = headless()
        let export = await exportTool(s)
        #expect(export.get("description")?.asStr?.contains("pdf") == true, "\(export.display)")
        let props = export.get("inputSchema")?.get("properties") ?? .null
        let formats = props.get("format")?.get("enum")?.asArray ?? []
        for f in ["png", "jpeg", "pptx", "deckcraft", "outline", "pdf"] {
            #expect(formats.contains(.string(f)), "format \(f)")
        }
        #expect(props.get("layout")?.get("enum") == j(#"["slides", "notes", "handouts"]"#))
        #expect(props.get("perPage")?.get("enum") == j("[1, 2, 3, 4, 6, 9]"))
        for p in ["dpi", "slides", "includeHidden", "textLayer", "frame", "paper", "orientation"] {
            #expect(props.get(p) != nil, "\(p)")
        }
        // What the schema describes is accepted.
        let dir = scratch("export")
        defer { try? FileManager.default.removeItem(at: dir) }
        await tool(s, "new_presentation", .emptyObject)
        for layout in ["slides", "notes", "handouts"] {
            let path = dir.appending(path: "\(layout).pdf").path
            await tool(s, "export", ["path": .string(path), "format": "pdf", "layout": .string(layout), "perPage": 3, "paper": "a4", "orientation": "landscape"])
            let bytes = try [UInt8](Data(contentsOf: URL(filePath: path)))
            #expect(bytes.starts(with: Array("%PDF".utf8)), "\(layout)")
        }
        await s.stop()
    }

    @Test func exportRejectsUnknownFormat() async {
        let s = headless()
        await tool(s, "new_presentation", j(#"{"theme": "Harbor"}"#))
        let path = FileManager.default.temporaryDirectory.appending(path: "deckcraft-mcp-unknown-format-\(ProcessInfo.processInfo.processIdentifier).docx").path
        try? FileManager.default.removeItem(atPath: path)
        let r = await call(s, 1, "tools/call", ["name": "export", "arguments": ["path": .string(path), "format": "docx"]])
        #expect(r.get("result")?.get("isError") == true, "\(r.display)")
        #expect(firstText(r).contains("docx"), "\(r.display)")
        #expect(!FileManager.default.fileExists(atPath: path), "nothing may be written for an unknown format")
        await s.stop()
    }

    @Test func exportToolListsGifAndItsOptions() async throws {
        let s = headless()
        let export = await exportTool(s)
        #expect(export.get("description")?.asStr?.contains("gif") == true)
        let props = export.get("inputSchema")?.get("properties") ?? .null
        #expect(props.get("format")?.get("enum")?.asArray?.contains("gif") == true)
        #expect(props.get("width")?.get("oneOf")?.at(1)?.get("enum") == j(#"["small", "medium", "large", "extraLarge"]"#))
        for p in ["secondsPerSlide", "loop", "slides", "includeHidden"] {
            #expect(props.get(p) != nil, "\(p)")
        }
        // What the schema describes is accepted, and bad values are tool errors, not crashes.
        let dir = scratch("gif")
        defer { try? FileManager.default.removeItem(at: dir) }
        await tool(s, "new_presentation", .emptyObject)
        for width in [JSON.string("small"), 200] {
            let path = dir.appending(path: "deck.gif").path
            await tool(s, "export", ["path": .string(path), "width": width, "secondsPerSlide": 2, "loop": false, "slides": [0]])
            let bytes = try [UInt8](Data(contentsOf: URL(filePath: path)))
            #expect(bytes.starts(with: Array("GIF89a".utf8)), "\(width.display)")
        }
        let r = await call(s, 9, "tools/call", ["name": "export", "arguments": ["path": .string(dir.appending(path: "bad.gif").path), "width": 0]])
        #expect(r.get("result")?.get("isError") == true, "\(r.display)")
        await s.stop()
    }
}
