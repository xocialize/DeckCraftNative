// DCAutomationTests — JSON-RPC framing, the MCP lifecycle and resources, as deckcraft's server answers
// them (crates/mcp/src/server.rs, MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The
// expected lines are deckcraft-cli 0.11.1's own replies to the same lines, byte for byte.
import DCCore
@testable import DCAutomation
import DCEngine
import Foundation
import Testing

@Suite("MCP framing (deckcraft-mcp server.rs)")
struct FramingTests {
    @Test("Replies are deckcraft's, byte for byte", arguments: [
        (#"{"jsonrpc":"2.0","id":3,"method":"nope"}"#, #"{"error":{"code":-32601,"message":"method not found: nope"},"id":3,"jsonrpc":"2.0"}"#),
        ("not json", #"{"error":{"code":-32700,"message":"parse error: expected ident at line 1 column 2"},"id":null,"jsonrpc":"2.0"}"#),
        (#"{"id":1.5,"method":"ping"}"#, #"{"id":1.5,"jsonrpc":"2.0","result":{}}"#),
        ("[]", #"{"error":{"code":-32600,"message":"empty batch"},"id":null,"jsonrpc":"2.0"}"#),
        (#"[{"jsonrpc":"2.0","id":7,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#, #"[{"id":7,"jsonrpc":"2.0","result":{}}]"#),
        (#"{"jsonrpc":"2.0","id":8,"method":"resources/read","params":{"uri":"x"}}"#, #"{"error":{"code":-32002,"message":"resource not found: x"},"id":8,"jsonrpc":"2.0"}"#),
        (#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{}}"#, #"{"error":{"code":-32602,"message":"missing tool `name`"},"id":9,"jsonrpc":"2.0"}"#),
        (#"{"x":1}"#, #"{"error":{"code":-32600,"message":"missing `method`"},"id":null,"jsonrpc":"2.0"}"#),
        (#"{"id":null,"method":"ping"}"#, #"{"error":{"code":-32600,"message":"`id` must be a string or number"},"id":null,"jsonrpc":"2.0"}"#),
        ("5", #"{"error":{"code":-32600,"message":"message must be an object"},"id":null,"jsonrpc":"2.0"}"#),
        (#"{"jsonrpc":"2.0","id":"s","method":"resources/templates/list"}"#, #"{"id":"s","jsonrpc":"2.0","result":{"resourceTemplates":[]}}"#),
        (#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"inspect_document","arguments":{}}}"#,
         #"{"id":2,"jsonrpc":"2.0","result":{"content":[{"text":"command `document.inspect` is not available right now: no presentation open","type":"text"}],"isError":true}}"#),
        (#"{"jsonrpc":"2.0","id":18446744073709551615,"method":"ping"}"#, #"{"id":18446744073709551615,"jsonrpc":"2.0","result":{}}"#),
        (#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope"}}"#,
         #"{"id":4,"jsonrpc":"2.0","result":{"content":[{"text":"unknown tool `nope`","type":"text"}],"isError":true}}"#),
    ])
    func reply(_ line: String, _ expected: String) async {
        let s = headless()
        #expect(await s.handleLine(line) == expected)
        await s.stop()
    }

    @Test func notificationsResponsesAndBlankLinesGetNoReply() async {
        let s = headless()
        #expect(await s.handleLine("   ") == nil)
        #expect(await s.handleLine(#"{"jsonrpc":"2.0","id":1,"result":{}}"#) == nil)
        #expect(await s.handleLine(#"{"jsonrpc":"2.0","id":1,"error":{"code":1,"message":"x"}}"#) == nil)
        #expect(await s.isInitialized == false)
        #expect(await s.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await s.isInitialized)
        // A batch of notifications alone gets no reply.
        #expect(await s.handleLine(#"[{"jsonrpc":"2.0","method":"notifications/cancelled"}]"#) == nil)
        await s.stop()
    }

    @Test func initializeNegotiatesTheVersion() async {
        let s = headless()
        for (asked, answered) in [("2025-06-18", "2025-06-18"), ("2025-03-26", "2025-03-26"), ("2024-11-05", "2024-11-05"), ("1999-01-01", "2025-06-18")] {
            let r = await call(s, 1, "initialize", ["protocolVersion": .string(asked)])
            #expect(r.get("result")?.get("protocolVersion")?.asStr == answered)
        }
        let r = await call(s, 1, "initialize", .null)
        let result = r.get("result") ?? .null
        #expect(result.get("protocolVersion") == "2025-06-18")
        #expect(result.get("capabilities") == j(#"{"resources": {}, "tools": {}}"#))
        #expect(result.get("serverInfo") == j(#"{"name": "deckcraft", "title": "DeckCraft", "version": "0.11.1", "websiteUrl": "https://getartcraft.com/apps/deckcraft"}"#))
        let instructions = result.get("instructions")?.asStr ?? ""
        #expect(instructions.contains("Backend: headless (in-process engine; no window)."))
        #expect(instructions.hasSuffix("The `app.links` command returns these links."))
        await s.stop()
    }

    @Test func resourcesReadThroughTheBackend() async {
        let s = headless()
        let list = await call(s, 1, "resources/list", .emptyObject)
        let uris = (list.get("result")?.get("resources")?.asArray ?? []).compactMap { $0.get("uri")?.asStr }
        #expect(uris == ["deckcraft://document", "deckcraft://commands"])
        // No presentation: the document resource is an internal error with the engine's message.
        var r = await call(s, 2, "resources/read", ["uri": "deckcraft://document"])
        #expect(r.get("error") == j(#"{"code": -32603, "message": "command `document.inspect` is not available right now: no presentation open"}"#))
        await tool(s, "new_presentation", .emptyObject)
        r = await call(s, 3, "resources/read", ["uri": "deckcraft://commands"])
        let content = r.get("result")?.get("contents")?.at(0) ?? .null
        #expect(content.get("mimeType") == "application/json")
        let commands = (try? JSONParser.parse(content.get("text")?.asStr ?? "")) ?? .null
        #expect(commands.asArray?.count == commandSpecs().count)
        #expect(content.get("text")?.asStr?.hasPrefix("[\n  {\n    \"enabled\": ") == true, "pretty JSON as serde_json writes it")
        r = await call(s, 4, "resources/read", .emptyObject)
        #expect(r.get("error") == j(#"{"code": -32602, "message": "missing `uri`"}"#))
        await s.stop()
    }

    @Test func prettyJSONIsSerdes() {
        #expect(JSON.emptyObject.pretty == "{}")
        #expect(JSON.array([]).pretty == "[]")
        #expect(j(#"{"b": [1, {"c": []}], "a": {"x": 1.0}}"#).pretty == "{\n  \"a\": {\n    \"x\": 1.0\n  },\n  \"b\": [\n    1,\n    {\n      \"c\": []\n    }\n  ]\n}")
    }

    @Test func linesAreReadAsRustReadsThem() throws {
        let r = LineReader(bytes: Array("a\r\nb\n\nlast".utf8), chunk: 2)
        #expect(try r.readLine(maximum: 100) == "a")
        #expect(try r.readLine(maximum: 100) == "b")
        #expect(try r.readLine(maximum: 100) == "")
        #expect(try r.readLine(maximum: 100) == "last")
        #expect(try r.readLine(maximum: 100) == nil)
        let bad = LineReader(bytes: [0x61, 0xFF, 0x0A])
        #expect(throws: IOFailure("stream did not contain valid UTF-8")) { try bad.readLine(maximum: 100) }
        let long = LineReader(bytes: Array(repeating: 0x61, count: 50) + [0x0A])
        #expect(throws: IOFailure.self) { try long.readLine(maximum: 10) }
    }

    @Test func serveAnswersEachLineInOrder() async throws {
        let s = headless()
        let input = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"new_presentation","arguments":{}}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add_slide","arguments":{"title":"Two"}}}
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"inspect_slide","arguments":{}}}

        """
        let out = Collected()
        try await s.serve(LineReader(bytes: Array(input.utf8), chunk: 7)) { (bytes: [UInt8]) throws(IOFailure) in out.append(bytes) }
        let lines = out.text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines.map { (try? JSONParser.parse($0))?.get("id")?.asU64 } == [1, 2, 3])
        #expect(lines.last?.contains(#"\"title\": \"Two\""#) == true)
        await s.stop()
    }
}

/// Bytes a test's writer collected.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    func append(_ b: [UInt8]) {
        lock.lock()
        bytes += b
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
