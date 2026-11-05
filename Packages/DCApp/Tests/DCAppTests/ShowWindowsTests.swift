// DCAppTests — the show's windows: a windowed show opens, draws through DCShow's renderer and closes.
import AppKit
import DCAppModel
import DCEngine
import DCShow
import Foundation
import Testing
@testable import DCApp

@MainActor
@Suite(.serialized) struct ShowWindowsTests {
    /// A windowed show opens, draws and closes; Escape in its window ends it (show.rs's keyboard path, through
    /// the window's key handler) and the editor is left on the last slide.
    @Test func aWindowedShowOpensAndEscapeEndsIt() throws {
        guard let metal = ShowMetal.shared else { return }
        _ = NSApplication.shared
        let s = Session.withNew()
        _ = try s.execute("slide.new", .emptyObject)
        let m = AppModel(session: s)
        m.ui.presenterView = true
        let c = ShowCoordinator(model: m)
        let w = ShowWindows(coord: c, metal: metal)
        c.onShowStarted = { sh in
            w.windowedNext = true
            w.open(sh)
        }
        c.onShowEnded = { w.close() }
        c.startShow(from: 0, reading: false)
        #expect(w.audience != nil)
        #expect(w.presenterWindow != nil, "windowed: presenter view opens in its own window")
        let view = try #require(w.showView)
        view.tick()
        #expect(view.snapshot() != nil)
        w.presenter?.refresh()
        #expect(w.presenter?.counter == "Slide 1 of 2")
        func key(_ code: UInt16, _ chars: String) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.audience?.windowNumber ?? 0, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code
            )
        }
        if let right = key(124, "") { #expect(w.key(right, presenter: false)) }
        #expect(c.show?.state.slide == 1)
        if let b = key(11, "b") { #expect(w.key(b, presenter: true)) }
        #expect(c.show?.blank == .black, "presenter view's keys drive the show too")
        if let esc = key(53, "\u{1b}") { #expect(w.key(esc, presenter: false)) }
        #expect(c.show == nil)
        #expect(w.audience == nil && w.presenterWindow == nil)
        #expect(s.activeDoc?.selection.slide == 1)
    }
}
