// DCAppTests — the control channel's window side. Ported from deckcraft `crates/ui-egui/src/control.rs`'s
// tests; `capture.rs`' tests check egui's screenshot budget and settle passes, which AppKit and
// ScreenCaptureKit do differently (see Packages/DCApp/PORT-NOTES.md, Automation).
import AppKit
import DCCore
import DCEngine
import Foundation
import Testing
@testable import DCApp

@MainActor
@Suite struct AutomationTests {
    /// A 2×2 image of one colour, as the Rust test fills one.
    private func image() throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32
        ))
        for x in 0 ..< 2 { for y in 0 ..< 2 { rep.setColor(NSColor(red: 1 / 255, green: 2 / 255, blue: 3 / 255, alpha: 1), atX: x, y: y) } }
        return rep
    }

    // control.rs: screenshot_reply_is_path_only_or_explicitly_inline
    @Test func screenshotReplyIsPathOnlyOrExplicitlyInline() throws {
        let rep = try image()
        let path = FileManager.default.temporaryDirectory.appending(path: "dc-shot-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let pathReply = AutomationFeature.encode(rep, path)
        #expect(pathReply["ok"]?.asBool == true, "\(pathReply)")
        #expect(pathReply["result"]?["png"] == nil, "a path reply never builds base64")
        let png = try [UInt8](Data(contentsOf: URL(filePath: path)))
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "the writer gets a PNG")

        let inline = AutomationFeature.encode(rep, nil)
        #expect(inline["ok"]?.asBool == true, "\(inline)")
        let text = try #require(inline["result"]?["png"]?.asStr)
        #expect(Cmd.base64Decode(text) == png, "the inline reply is the same PNG")
    }

    @Test func uiCommandsAreListedAsDeckcraftDoes() {
        let host = AppControlHost(session: Session())
        let first = host.uiCommands.first
        #expect(first?["id"]?.asStr == "view.normal")
        #expect(first?["ui"]?.asBool == true)
        #expect(first?["enabled"]?.asBool == true)
        // deckcraft's 51, view.ribbon (the ribbon layout, R1 of Docs/plans/Ribbon-and-StartScreen.md),
        // view.handoutSlides (Slides Per Page, R2) and view.focusRibbon (F6, R3).
        #expect(host.uiCommands.count == 54)
    }

    @Test func windowPointsAreYDown() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        #expect(AppControlHost.windowPoint(w, 10, 20) == NSPoint(x: 10, y: 280))
    }
}
