// DCAutomationTests — engine commands that automation runs get a large stack. Thirty-two nested groups (the
// most `arrange.group` makes) take more stack than a Swift concurrency thread's 512 KiB in a debug build:
// the shape-tree walks, the renderer and the saved file's coder recurse once per level. The MCP server
// and the control channel run the engine on an `EngineThread` (32 MiB), so these calls, made from Swift
// Testing's concurrency threads, would crash without it.
import DCCore
@testable import DCAutomation
import DCEngine
import Foundation
import Testing

@Suite("Large stacks for the engine")
struct LargeStackTests {
    @Test func thirtyTwoNestedGroupsThroughMCP() async throws {
        let s = headless()
        await tool(s, "new_presentation", .emptyObject)
        await tool(s, "add_slide", j(#"{"layout": "blank"}"#))
        var g = (await tool(s, "insert_table", j(#"{"rows": 2, "cols": 2}"#))).get("id") ?? .null
        for _ in 0 ..< ArrangeCommands.maxGroupDepth {
            let r = (await tool(s, "add_shape", j(#"{"preset": "rect", "x": 10, "y": 10, "w": 20, "h": 20, "text": "deep"}"#))).get("id") ?? .null
            await tool(s, "select", ["ids": [g, r]])
            g = (await tool(s, "run_command", j(#"{"command": "arrange.group"}"#))).get("id") ?? .null
        }
        let sl = await tool(s, "inspect_slide", .emptyObject)
        #expect(shapes(sl).count == 1)
        // Draw it, save and reopen it in both formats, copy and paste it, ungroup it.
        let r = await call(s, 3, "tools/call", j(#"{"name": "render_slide", "arguments": {"scale": 0.5}}"#))
        #expect(r.get("result")?.get("content")?.at(0)?.get("type") == "image")
        let dir = scratch("deep")
        defer { try? FileManager.default.removeItem(at: dir) }
        for ext in ["deckcraft", "pptx"] {
            let path = dir.appending(path: "deep.\(ext)").path
            await tool(s, "save_presentation", ["path": .string(path)])
            await tool(s, "open_presentation", ["path": .string(path)])
            await tool(s, "go_to_slide", j(#"{"index": 1}"#))
            let back = await tool(s, "inspect_slide", .emptyObject)
            #expect(shapes(back).count == 1, "\(ext)")
        }
        await tool(s, "select", ["ids": [g]])
        await tool(s, "run_command", j(#"{"command": "edit.copy"}"#))
        await tool(s, "run_command", j(#"{"command": "edit.paste"}"#))
        await tool(s, "run_command", j(#"{"command": "arrange.ungroup"}"#))
        _ = await tool(s, "inspect_document", .emptyObject)
        await s.stop()
    }

    @Test func thirtyTwoNestedGroupsThroughTheControlChannel() async {
        let channel = ControlChannel(HeadlessControlHost(Session.withNew()))
        func run(_ id: String, _ params: JSON) -> JSON { channel.call("engine.execute", ["command": .string(id), "params": params]).get("result") ?? .null }
        _ = run("slide.new", j(#"{"layout": "blank"}"#))
        var g = run("insert.table", j(#"{"rows": 2, "cols": 2}"#)).get("id") ?? .null
        for _ in 0 ..< ArrangeCommands.maxGroupDepth {
            let r = run("shape.insert", j(#"{"preset": "rect", "rect": [10, 10, 20, 20], "text": "deep"}"#)).get("id") ?? .null
            _ = run("edit.select", ["ids": [g, r]])
            g = run("arrange.group", .emptyObject).get("id") ?? .null
        }
        #expect(g != .null)
        #expect(channel.call("ui.render", j(#"{"scale": 0.5}"#)).get("ok") == true)
        #expect(channel.call("document.inspect", .emptyObject).get("ok") == true)
        let bytes = run("file.saveBytes", j(#"{"format": "pptx"}"#))
        #expect((bytes.get("bytes")?.asU64 ?? 0) > 0)
    }

    @Test func theEngineThreadHasALargeStack() async {
        let engine = EngineThread()
        let size = await engine.run { Thread.current.stackSize }
        #expect(size == EngineThread.stackSize)
        #expect(EngineThread.onLargeStack { Thread.current.stackSize } == EngineThread.stackSize)
        // Work runs in the order it was submitted.
        let order = await withTaskGroup(of: Void.self) { _ in
            await engine.run { (0 ..< 5).map { $0 } }
        }
        #expect(order == [0, 1, 2, 3, 4])
        engine.stop()
        #expect(await engine.run { 1 } == nil, "a stopped thread runs nothing")
    }
}
