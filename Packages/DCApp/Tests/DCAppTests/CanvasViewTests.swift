// DCAppTests — the canvas in a window made in-process: where the slide goes and how it zooms, drawing,
// keys and text through AppKit's own calls (`keyDown`, `NSTextInputClient`), the context menu, the
// Eyedropper, and what `ui.inspect` reports. Behaviour from deckcraft `crates/ui-egui/src/canvas.rs`,
// `eyedropper_tests.rs`, `ime_tests.rs` and `lib.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCGeometry
import DCModel
import Foundation
import Testing
@testable import DCApp

@MainActor
@Suite struct CanvasViewTests {
    /// An app with one presentation (a blank slide, a red rectangle at 100,100 200×100, selected) shown by a
    /// canvas in a 1000×700 window. Documents aren't synced to windows of their own.
    @MainActor struct Fixture {
        let app: AppController
        let doc: PresentationDocument
        let vc: CanvasViewController
        let window: NSWindow
        var model: AppModel { app.model }
        var canvas: CanvasView { vc.canvas }

        init(zoom: Double? = nil) {
            _ = NSApplication.shared
            app = AppController()
            app.syncSuspended += 1
            app.model.ui = UiState()
            app.model.ui.zoom = zoom
            app.model.run("file.new")
            app.model.run("slide.layout", ["layout": "blank"])
            app.model.run("shape.insert", ["preset": "rect", "rect": [100, 100, 200, 100]])
            app.model.run("shape.fill", ["color": "#ff0000"])
            doc = PresentationDocument(adopting: app.model.session.activeDoc?.uid ?? 0)
            vc = CanvasViewController(document: doc)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            vc.view.frame = window.contentView?.bounds ?? .zero
            window.contentView = vc.view
            vc.view.layoutSubtreeIfNeeded()
            vc.refresh()
            window.makeFirstResponder(vc.canvas)
        }

        /// The view point of slide point (x, y).
        func at(_ x: Double, _ y: Double) -> CGPoint { canvas.xf?.toView(Point(x, y)) ?? .zero }

        func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
        }

        func key(_ chars: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
        }

        var selected: Shape? { model.session.activeDoc?.selectedShapes.first }
    }

    // canvas.rs: layout — the slide fits the canvas with a margin, centred; `ui.inspect` reports it.
    @Test func theSlideFitsAndInspectReportsIt() throws {
        let f = Fixture()
        let l = try #require(f.canvas.layoutInfo)
        let viewport = try #require(f.canvas.viewportInfo()).size
        #expect(abs(l.slideRect.midX - viewport.width / 2) < 1 && abs(l.slideRect.midY - viewport.height / 2) < 1)
        #expect(l.slideRect.minX >= CanvasLayout.margin - 0.5 || l.slideRect.minY >= CanvasLayout.margin - 0.5)
        #expect(f.model.canvasScale == l.scale, "Zoom In/Out start from the canvas's scale")
        let rect = try #require(f.app.inspectors["slideRect"]?().asArray)
        #expect(rect.count == 4 && abs((rect[2].asF64 ?? 0) - l.slideRect.width) < 0.5)
        #expect(f.app.inspectors["canvasRect"]?().asArray?.count == 4)
        #expect(f.app.inspectors["canvas"]?()["scale"]?.asF64 == l.scale)
    }

    // canvas.rs: zoom_commands_keep_the_middle_of_the_view; scroll_bars_pan_a_zoomed_slide (native scroll bars)
    @Test func zoomingPastTheWindowScrollsAndKeepsTheMiddle() throws {
        let f = Fixture()
        let clip = f.vc.scroll.contentView
        let mid = CGPoint(x: clip.bounds.width / 2, y: clip.bounds.height / 2)
        let before = try #require(f.canvas.xf).toSlide(mid)
        for _ in 0 ..< 3 {
            f.model.run("view.zoomIn")
            f.vc.refresh()
        }
        let l = try #require(f.canvas.layoutInfo)
        #expect(l.overflow(clip.bounds.size).width > 0, "the document grows past the window")
        #expect(f.canvas.frame.size == l.documentSize)
        let now = try #require(f.canvas.xf).toSlide(CGPoint(x: mid.x + clip.bounds.minX, y: mid.y + clip.bounds.minY))
        #expect(abs(now.x - before.x) < 1.5 && abs(now.y - before.y) < 1.5, "\(now) vs \(before)")
        f.model.run("view.fit")
        f.vc.refresh()
        #expect(f.canvas.layoutInfo?.overflow(clip.bounds.size) == .zero)
    }

    /// The slide is drawn (a recording of it, replayed), and View › Grayscale takes its colour out.
    @Test func theSlideIsDrawnAndGrayscaleTakesItsColourOut() throws {
        let f = Fixture()
        func pixel(_ x: Double, _ y: Double) throws -> NSColor {
            let p = f.at(x, y)
            let rep = try #require(f.canvas.bitmapImageRepForCachingDisplay(in: f.canvas.bounds))
            f.canvas.cacheDisplay(in: f.canvas.bounds, to: rep)
            let scale = Double(rep.pixelsWide) / f.canvas.bounds.width
            return try #require(rep.colorAt(x: Int(p.x * scale), y: Int(p.y * scale))?.usingColorSpace(.sRGB))
        }
        let red = try pixel(200, 150)
        #expect(red.redComponent > 0.8 && red.redComponent - red.greenComponent > 0.5, "the rectangle is red: \(red)")
        let page = try pixel(600, 400)
        #expect(page.redComponent > 0.9 && page.greenComponent > 0.9, "the slide is white: \(page)")
        f.model.ui.grayscale = true
        f.canvas.needsDisplay = true
        let grey = try pixel(200, 150)
        #expect(abs(grey.redComponent - grey.greenComponent) < 0.05, "grey: \(grey)")
    }

    /// Keys the canvas owns go to `Session.key`: arrows nudge, Option nudges a point, Escape deselects.
    @Test func keysGoToTheEngine() throws {
        let f = Fixture()
        let x0 = try #require(f.selected?.xfrm?.x)
        f.canvas.keyDown(with: try #require(f.key("\u{F703}", code: 124)))
        #expect(f.selected?.xfrm?.x == x0 + 6)
        f.canvas.keyDown(with: try #require(f.key("\u{F702}", code: 123, .option)))
        #expect(f.selected?.xfrm?.x == x0 + 5)
        f.canvas.keyDown(with: try #require(f.key("\u{1B}", code: 53)))
        #expect(f.model.session.activeDoc?.selection.shapes.isEmpty == true)
    }

    /// Typing through the text system: on the selected shape it starts editing and replaces the text; an
    /// input method's marked text shows in place and commits as one step; the candidate window is at the
    /// insertion point, inside the window.
    @Test func textInputThroughNSTextInputClient() throws {
        let f = Fixture()
        let id = try #require(f.selected?.id)
        f.canvas.insertText("Hi", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.model.session.activeDoc?.shape(id)?.text?.text == "Hi")
        #expect(f.canvas.selectedRange() == NSRange(location: 2, length: 0))
        f.canvas.setMarkedText(NSAttributedString(string: "한"), selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.canvas.hasMarkedText())
        #expect(f.canvas.markedRange() == NSRange(location: 2, length: 1))
        #expect(f.canvas.attributedSubstring(forProposedRange: NSRange(location: 0, length: 3), actualRange: nil)?.string == "Hi한")
        let r = f.canvas.firstRect(forCharacterRange: NSRange(location: 3, length: 0), actualRange: nil)
        #expect(r.height > 0 && f.window.frame.insetBy(dx: -1, dy: -1).contains(r.origin), "\(r) in \(f.window.frame)")
        f.canvas.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!f.canvas.hasMarkedText())
        #expect(f.model.session.activeDoc?.shape(id)?.text?.text == "Hi한")
        // The caret is the system's insertion point, on the caret line.
        f.canvas.updateCaret()
        #expect(!f.canvas.caret.isHidden)
        #expect(f.canvas.caret.frame.height > 0)
        // ⌃A is the Mac's line start in text; Enter goes to the engine.
        f.canvas.doCommand(by: #selector(NSResponder.moveToBeginningOfLine(_:)))
        #expect(f.model.session.activeDoc?.selection.text?.caret == TextPoint(0, 0))
        // Services: the selected text goes out, text comes back in its place.
        f.model.run("text.selectAll")
        #expect(f.canvas.validRequestor(forSendType: .string, returnType: .string) as? CanvasView === f.canvas)
        let pb = NSPasteboard(name: NSPasteboard.Name("dc-canvas-test-\(UUID().uuidString)"))
        #expect(f.canvas.writeSelection(to: pb, types: [.string]))
        #expect(pb.string(forType: .string) == "Hi한")
        pb.clearContents()
        pb.setString("Bye", forType: .string)
        #expect(f.canvas.readSelection(from: pb))
        #expect(f.model.session.activeDoc?.shape(id)?.text?.text == "Bye")
        pb.releaseGlobally()
    }

    /// A right click opens deckcraft's menu for what is selected.
    @Test func theContextMenuOffersTheObjectsItems() throws {
        let f = Fixture()
        let e = try #require(f.event(.rightMouseDown, f.at(200, 150)))
        let menu = try #require(f.canvas.menu(for: e))
        let titles = menu.items.map(\.title)
        #expect(Array(titles.prefix(3)) == ["Cut", "Copy", "Paste"])
        #expect(titles.contains("Edit Text") && titles.contains("Format Shape…") && titles.contains("Bring to Front"))
        // Choosing an item runs it.
        let lock = try #require(menu.items.first { $0.title == "Lock" } as? CanvasMenu.ActionItem)
        lock.performCanvasAction(nil)
        #expect(f.selected?.locked == true)
    }

    // eyedropper_tests.rs: a_click_on_the_slide_takes_the_colour_under_it_and_nothing_else_happens,
    // and Escape cancels; a click off the slide cancels without picking.
    @Test func theEyedropperTakesTheColourUnderAClick() throws {
        let f = Fixture()
        f.model.run("edit.deselect")
        var taken: String?
        #expect(CanvasFeature.eyedropper { taken = $0 })
        #expect(f.canvas.eyedropper != nil)
        #expect(f.model.status?.hasPrefix("Eyedropper") == true)
        f.canvas.mouseDown(with: try #require(f.event(.leftMouseDown, f.at(150, 150))))
        #expect(taken == "FF0000")
        #expect(f.canvas.eyedropper == nil, "one click ends it")
        #expect(f.model.session.activeDoc?.selection.shapes.isEmpty == true, "the click didn't select anything")
        // Escape cancels.
        f.canvas.beginEyedropper(.color { taken = $0 })
        f.canvas.keyDown(with: try #require(f.key("\u{1B}", code: 53)))
        #expect(f.canvas.eyedropper == nil)
        // A click off the slide cancels and picks nothing.
        taken = nil
        f.canvas.beginEyedropper(.color { taken = $0 })
        let off = CGPoint(x: (f.canvas.layoutInfo?.slideRect.minX ?? 30) - 10, y: 5)
        f.canvas.mouseDown(with: try #require(f.event(.leftMouseDown, off)))
        #expect(f.canvas.eyedropper == nil && taken == nil)
    }

    /// With no slides, a click on the canvas adds the first one.
    @Test func aClickOnAnEmptyPresentationAddsTheFirstSlide() throws {
        let f = Fixture()
        f.model.run("slide.delete")
        #expect(f.model.session.activeDoc?.doc.slides.isEmpty == true)
        f.vc.refresh()
        f.canvas.mouseDown(with: try #require(f.event(.leftMouseDown, CGPoint(x: 400, y: 300))))
        #expect(f.model.session.activeDoc?.doc.slides.count == 1)
    }

    /// The rulers take 16-point strips when shown, and the tab selector cycles the kind of stop.
    @Test func rulersTakeTheirStrips() throws {
        let f = Fixture()
        #expect(f.vc.rulers.isHidden)
        f.model.run("view.ruler", ["on": true])
        f.vc.refresh()
        #expect(!f.vc.rulers.isHidden)
        #expect(f.vc.scroll.frame.minX == CanvasStyle.ruler && f.vc.scroll.frame.minY == CanvasStyle.ruler)
        #expect(f.vc.rulers.hitTest(CGPoint(x: 500, y: 5)) === f.vc.rulers, "the top strip takes the pointer")
        #expect(f.vc.rulers.hitTest(CGPoint(x: 500, y: 300)) == nil, "the canvas under it keeps it")
        let corner = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: f.vc.rulers.convert(CGPoint(x: 8, y: 8), to: nil), modifierFlags: [],
                                                     timestamp: 0, windowNumber: f.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        f.vc.rulers.mouseDown(with: corner)
        #expect(f.vc.rulers.kind == 1, "Center Tab")
    }

    /// A dropped outline's text, RTF through the system's reader.
    @Test func droppedOutlinesAreRead() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dc-canvas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let md = dir.appending(path: "o.md")
        try Data("# One\n- a".utf8).write(to: md)
        #expect(CanvasView.outlineText(md) == "# One\n- a")
        let rtf = dir.appending(path: "o.rtf")
        let data = try NSAttributedString(string: "Title\nPoint").data(from: NSRange(location: 0, length: 11), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: rtf)
        #expect(CanvasView.outlineText(rtf)?.hasPrefix("Title\nPoint") == true)
    }
}
