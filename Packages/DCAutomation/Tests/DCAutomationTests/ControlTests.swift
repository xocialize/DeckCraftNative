// DCAutomationTests — the control channel's protocol and the methods it answers without a window. Port of
// the tests in deckcraft crates/ui-egui/src/control.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors); `screenshot_reply_is_path_only_or_explicitly_inline` belongs with the window's
// capture (Wave 5).
import DCCore
@testable import DCAutomation
import DCEngine
import Foundation
import Testing

/// serde_json `Value` equality: maps compare without regard to key order.
func same(_ a: JSON, _ b: JSON) -> Bool { a.canonical == b.canonical }

@Suite("Control channel (ui-egui control.rs)")
struct ControlTests {
    /// `take` and `abandon` are exclusive: whoever wins, the request runs at most once (#719).
    @Test func takeAndAbandonAreExclusive() {
        var (req, _) = ControlRequest.make("m", .emptyObject)
        #expect(req.take(), "a pending request is taken")
        #expect(!ControlRequest.abandon(req.state), "a taken request is not abandoned")
        #expect(req.take(), "a taken request stays taken")

        (req, _) = ControlRequest.make("m", .emptyObject)
        #expect(ControlRequest.abandon(req.state), "a pending request is abandoned")
        #expect(!req.take(), "an abandoned request is never taken")
        #expect(ControlRequest.abandon(req.state), "abandoning twice stays abandoned")
    }

    @Test func engineMethodsAnswerInTheEnvelope() {
        let channel = ControlChannel(HeadlessControlHost(Session.withNew()))
        let added = channel.call("engine.execute", j(#"{"command": "slide.new", "params": {"layout": "blank"}}"#))
        #expect(added.get("ok") == true && added.get("result")?.get("index") == 1, "\(added.display)")
        #expect(channel.call("command", j(#"{"id": "slide.go", "params": null}"#)).get("ok") == false, "no index: refused by the command")
        #expect(same(channel.call("engine.execute", .emptyObject), j(#"{"ok": false, "error": "missing `command`"}"#)))
        #expect(same(channel.call("engine.execute", j(#"{"command": "no.such"}"#)), j(#"{"ok": false, "error": "unknown command `no.such`"}"#)))
        #expect(channel.call("engine.commands", .emptyObject).get("result")?.asArray?.count == commandSpecs().count)
        #expect(channel.call("document.inspect", .emptyObject).get("result")?.get("slides")?.asArray?.count == 2)
        #expect(same(channel.call("no.such", .emptyObject), j(#"{"ok": false, "error": "unknown method `no.such`"}"#)))
        #expect(channel.call("ui.click", j(#"{"x": 1, "y": 1}"#)).get("ok") == false)
    }

    @Test func pointerKeysToolsAndRender() throws {
        let channel = ControlChannel(HeadlessControlHost(Session.withNew()))
        #expect(same(channel.call("ui.pointer", .emptyObject), j(#"{"ok": false, "error": "missing `events`"}"#)))
        #expect(same(channel.call("ui.pointer", j(#"{"events": [{"kind": "hover", "x": 1, "y": 2}]}"#)), j(#"{"ok": false, "error": "unknown pointer kind `hover`"}"#)))
        #expect(same(channel.call("ui.pointer", j(#"{"events": [{"kind": "down", "x": 1}]}"#)), j(#"{"ok": false, "error": "pointer events need x and y"}"#)))
        #expect(same(channel.call("ui.tool.select", j(#"{"tool": "star5"}"#)), j(#"{"ok": true, "result": {"tool": "star5"}}"#)))
        #expect(same(channel.call("ui.inspect", .emptyObject), j(#"{"ok": true, "result": {"headless": true, "tool": {"kind": "shape", "preset": "star5"}}}"#)))
        // The MCP server's extra spellings are its own.
        #expect(same(channel.call("ui.tool.select", j(#"{"tool": "arrow"}"#)), j(#"{"ok": false, "error": "unknown tool `arrow`"}"#)))
        #expect(channel.call("ui.tool.select", j(#"{"tool": "pen"}"#)).get("ok") == true)
        #expect(channel.call("ui.key", j(#"{"key": "z", "cmd": true}"#)).get("ok") == false, "nothing to undo")
        let r = channel.call("ui.render", j(#"{"scale": 0.25}"#))
        #expect(r.get("result")?.get("width") == 240)
        #expect(r.get("result")?.get("slide") == 0)
        #expect(same(channel.call("ui.render", j(#"{"slide": 5}"#)), j(#"{"ok": false, "error": "no slide 5"}"#)))
        let dir = scratch("control")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "s.png").path
        #expect(same(channel.call("ui.render", ["path": .string(path)]), ["ok": true, "result": ["path": .string(path), "width": 960, "height": 540]]))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func abandonedRequestsNeverRun() {
        let session = Session.withNew()
        let channel = ControlChannel(HeadlessControlHost(session))
        let (req, reply) = ControlRequest.make("engine.execute", j(#"{"command": "slide.new"}"#))
        #expect(ControlRequest.abandon(req.state))
        channel.submit(req)
        #expect(reply.wait(timeout: 0.5) == nil, "an abandoned request gets no reply")
        // The channel is serial: this one runs after the abandoned one was skipped.
        #expect(channel.call("document.inspect", .emptyObject).get("result")?.get("slides")?.asArray?.count == 1)
    }
}
