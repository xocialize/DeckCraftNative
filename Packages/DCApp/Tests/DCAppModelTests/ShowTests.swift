// DCAppModelTests — the slide show without a window: navigation, keys, the grid, zoom, blank screens, the pen and
// laser, typed slide numbers, the presenter timer and notes, clocks, transitions, media cues, clicks, wheels and
// the frames rendered for the show. Ported from the tests of deckcraft `crates/ui-egui/src/show.rs` (names in
// camelCase), at the level the Mac app exposes them: `ShowController` and `ShowCoordinator` instead of an egui
// harness.
import CoreGraphics
import DCAnim
import DCColor
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DCRender
import Foundation
import Testing
@testable import DCAppModel

@MainActor
@Suite struct ShowTests {
    /// A session with `extra` slides added after the first.
    static func session(_ extra: Int, layout: String? = nil) -> Session {
        let s = Session.withNew()
        for _ in 0 ..< extra { _ = try? s.execute("slide.new", layout.map { ["layout": .string($0)] } ?? .emptyObject) }
        return s
    }

    static func doc(_ s: Session) -> Presentation { s.activeDoc?.doc ?? Presentation.default }

    /// A coordinator over `s` with presenter view off and the show started at `from` (the first frame at `t0`).
    static func running(_ s: Session, from: Int = 0, presenter: Bool = false, t0: Double = 10) -> ShowCoordinator {
        let m = AppModel(session: s)
        m.ui.presenterView = presenter
        let c = ShowCoordinator(model: m)
        c.startShow(from: from, reading: false)
        _ = c.tick(t0)
        return c
    }

    // show.rs: shapes_above_a_playing_video_are_the_overlay (#1005)
    @Test func shapesAboveAPlayingVideoAreTheOverlay() throws {
        let s = Session.withNew()
        for _ in 0 ..< 3 { _ = try s.execute("shape.insert", ["preset": "rect", "rect": [0, 0, 100, 100]]) }
        var doc = Self.doc(s)
        let keep = doc.slides[0].shapes.count - 3
        doc.slides[0].shapes.removeFirst(keep)
        let ids = doc.slides[0].shapes.map(\.id)
        doc.slides[0].shapes[1].kind = .media(MediaClip(video: true))
        // Video in the middle: the shape above it is drawn over it.
        #expect(belowPlayingVideo(doc, 0, [ids[1]]) == [ids[0], ids[1]])
        // Video on top: nothing above it.
        doc.slides[0].shapes.swapAt(1, 2)
        #expect(belowPlayingVideo(doc, 0, [ids[1]]).isEmpty)
        #expect(belowPlayingVideo(doc, 0, []).isEmpty)
    }

    // show.rs: a_still_cursor_hides_over_a_clickable_shape (#968)
    @Test func aStillCursorHidesOverAClickableShape() throws {
        let s = Session.withNew()
        let size = Self.doc(s).slideSize
        let r = try s.execute("shape.insert", ["preset": "rect", "rect": [0, 0, .double(size.width), .double(size.height)]])
        _ = try s.execute("insert.hyperlink", ["url": "https://example.org", "ids": [r["id"] ?? .null]])
        let c = Self.running(s)
        let full = CGRect(x: 0, y: 0, width: 1000, height: 700)
        c.show?.lastMove = 10
        #expect(c.cursor(CGPoint(x: 500, y: 350), full, 10.5) == .pointingHand)
        #expect(c.cursor(CGPoint(x: 500, y: 350), full, 13) == .hidden, "still for 3 s: hidden")
    }

    // show.rs: presenter_all_slides_does_not_cover_the_audience_screen (#1130)
    @Test func presenterAllSlidesDoesNotCoverTheAudienceScreen() throws {
        let c = Self.running(Self.session(1), presenter: true)
        let sh = try #require(c.show)
        sh.presenterGrid.toggle()
        #expect(sh.presenterGrid, "the grid opens in the Presenter View")
        #expect(!sh.grid, "the audience screen keeps showing the slide")
        let esc = c.key(.escape, ShowMods(), presenter: true, now: 11)
        #expect(!sh.presenterGrid, "Esc closes the Presenter View grid")
        #expect(esc.keep, "and does not end the show")
        _ = c.key(.g, ShowMods(), presenter: true, now: 11)
        #expect(sh.presenterGrid, "G in Presenter View opens its own grid")
        #expect(!sh.grid)
        _ = c.key(.g, ShowMods(), presenter: true, now: 11)
        #expect(!sh.presenterGrid, "G again closes it")
    }

    // show.rs: presenter_navigation_uses_its_own_keyboard_events
    @Test func presenterNavigationUsesItsOwnKeyboardEvents() throws {
        let c = Self.running(Self.session(2), presenter: true)
        let sh = try #require(c.show)
        for (k, slide) in [(ShowKey.arrowRight, 1), (.arrowLeft, 0), (.space, 1), (.pageDown, 2), (.pageUp, 1), (.home, 0), (.end, 2)] {
            _ = c.key(k, ShowMods(), presenter: true, now: 11)
            #expect(sh.state.slide == slide, "presenter key \(k)")
        }
        _ = c.key(.arrowRight, ShowMods(), presenter: true, now: 11)
        #expect(sh.ended)
        _ = c.key(.arrowLeft, ShowMods(), presenter: true, now: 11)
        #expect(!sh.ended)
        #expect(sh.state.slide == 2, "back from the end screen restores the last slide")
        _ = c.key(.arrowRight, ShowMods(), presenter: true, now: 11)
        #expect(sh.ended)
        #expect(c.navigate(false, now: 11))
        #expect(!sh.ended, "the presenter Previous button also leaves the end screen")
        _ = c.key(.home, ShowMods(), presenter: true, now: 11)
        #expect(c.navigate(true, now: 11))
        #expect(sh.state.slide == 1)
        _ = c.key(.space, ShowMods(), presenter: true, now: 11)
        #expect(sh.state.slide == 2)
        #expect(!sh.ended)
        let esc = c.key(.escape, ShowMods(), presenter: true, now: 11)
        #expect(!esc.keep, "Escape from Presenter View ends the show")
    }

    // show.rs: slideshow_navigation_advances_once_with_presenter_view
    @Test func slideshowNavigationAdvancesOnceWithPresenterView() throws {
        let c = Self.running(Self.session(2), presenter: true)
        let sh = try #require(c.show)
        _ = c.key(.arrowRight, ShowMods(), presenter: false, now: 11)
        #expect(sh.state.slide == 1, "one key advances one slide")
        _ = c.key(.end, ShowMods(), presenter: false, now: 11)
        _ = c.key(.arrowRight, ShowMods(), presenter: false, now: 11)
        #expect(sh.ended)
        let r = c.key(.escape, ShowMods(), presenter: false, now: 11)
        #expect(!r.keep)
        c.endShow()
        #expect(c.show == nil)
    }

    // show.rs: the_prefetched_frame_is_the_frame_shown_on_entry
    @Test func thePrefetchedFrameIsTheFrameShownOnEntry() throws {
        let s = Session.withNew()
        _ = try s.execute("slide.new", ["title": "Second"])
        let doc = Self.doc(s)
        let size = ShowSize(96, 54)
        let p = ShowPrefetch.start(doc, nil, 1, size)
        #expect(p.key == ShowFrameKey(slide: 1, step: 0, size: size, doc: nil))
        let got = p.pending.wait()
        let want = ShowRender.frame(doc, 1, ShowState.timeline(doc, 1), 0, 0, size, hidden: [])
        #expect(got.width == want.width && got.height == want.height)
        #expect(got.pixels == want.pixels)
    }

    // show.rs: an_animation_frame_over_the_kept_backdrop_matches_a_full_render
    @Test func anAnimationFrameOverTheKeptBackdropMatchesAFullRender() throws {
        let s = Session.withNew()
        let r = try s.execute("shape.insert", ["preset": "star5", "rect": [100, 100, 300, 200]])
        _ = try s.execute("animation.set", ["effect": "fade", "ids": [r["id"] ?? .null]])
        var doc = Self.doc(s)
        // A glowing master graphic under the animated star.
        var deco = try #require(doc.slides[0].shapes.last)
        deco.id = ShapeId(9000)
        deco.xfrm = deco.xfrm.map { var x = $0; x.x -= 60; x.y += 40; return x }
        var fx = Effects.default
        fx.glow = Glow(color: .rgb(Rgba(r: 0, g: 120, b: 255, a: 255)), radius: 12)
        deco.effects = fx
        doc.masters[0].shapes.append(deco)
        let size = ShowSize(480, 270)
        let ref = DocRef(doc)
        let key = ShowBackKey(slide: 0, size: size, doc: ObjectIdentifier(ref))
        let cache = ShowBackdrop()
        cache.prefetch(doc, ref, key)
        let back = cache.get(doc, ref, key)
        let tl = ShowState.timeline(doc, 0)
        #expect(!tl.isEmpty)
        let fast = ShowRender.frame(doc, 0, tl, 0, 0.25, size, hidden: [], backdrop: back)
        let full = ShowRender.frame(doc, 0, tl, 0, 0.25, size, hidden: [])
        #expect(fast.pixels.count == full.pixels.count)
        let worst = zip(fast.pixels, full.pixels).map { Swift.abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 2, "frames differ by up to \(worst)")
        // The backdrop is kept, not rendered again; another document under the same key gets its own.
        #expect(cache.get(doc, ref, key) == back)
        var edited = doc
        edited.masters[0].shapes.removeLast()
        let other = DocRef(edited)
        #expect(cache.get(edited, other, ShowBackKey(slide: 0, size: size, doc: ObjectIdentifier(other))) != back)
    }

    // show.rs: a_transition_keeps_the_old_slide_in_its_own_texture (#33)
    @Test func aTransitionKeepsTheOldSlideInItsOwnTexture() throws {
        let s = Self.session(1)
        _ = try s.execute("transition.set", ["kind": "fade", "index": 1])
        let doc = Self.doc(s)
        let sh = ShowController(doc, from: 0, reading: false, presenter: false)
        let red = NSObject()
        sh.frame = (ShowFrameKey(slide: 0, step: 0, size: ShowSize(1, 1), doc: nil), red)
        #expect(sh.apply(.slide(1), doc, 0))
        let tr = try #require(sh.trans, "the fade plays")
        #expect(tr.old === red)
        #expect(tr.from == 0)
        #expect(sh.frame == nil, "the new slide gets a texture of its own instead of overwriting the old one")
    }

    // show.rs: media_in_the_click_sequence_plays_with_its_step (#116)
    @Test func mediaInTheClickSequencePlaysWithItsStep() throws {
        let s = Session.withNew()
        var doc = Self.doc(s)
        let id = doc.slides[0].shapes[0].id
        func play(_ delay: UInt32) -> Animation {
            var a = Animation.default
            a.shape = id
            a.class = .media
            a.effect = "play"
            a.durationMs = 5000
            a.delayMs = delay
            return a
        }
        doc.slides[0].animations = [play(0), play(2000)]
        let sh = ShowController(doc, from: 0, reading: false, presenter: false)
        #expect(sh.apply(.slide(0), doc, 0))
        let a = sh.state.next(doc)
        #expect(a == .playStep(0))
        #expect(sh.apply(a, doc, 1))
        sh.cueMedia(doc, 0, 0)
        sh.cueMedia(doc, 0, 0.5)
        #expect(sh.mediaCues.map(\.0) == [id] && sh.mediaCues.map(\.1) == ["play"])
        sh.mediaCues.removeAll()
        #expect(sh.timeline(doc).stepDuration(0) == 0)
        #expect(sh.apply(sh.state.stepDone(doc), doc, 1))
        #expect(sh.mediaCues.isEmpty, "set off once")
        let b = sh.state.next(doc)
        #expect(b == .playStep(1))
        #expect(sh.apply(b, doc, 2))
        sh.cueMedia(doc, 1, 0.5)
        #expect(sh.mediaCues.isEmpty)
        #expect(sh.apply(sh.state.stepDone(doc), doc, 2.6))
        #expect(sh.mediaCues.map(\.0) == [id], "cutting the step short still sets it off")
        sh.mediaCues.removeAll()
        #expect(sh.apply(sh.state.prev(doc), doc, 3))
        sh.cueMedia(doc, 1, 9)
        #expect(sh.mediaCues.isEmpty, "going back sets nothing off")
    }

    // show.rs: the_laser_and_the_pen_are_not_on_together
    @Test func theLaserAndThePenAreNotOnTogether() {
        let sh = ShowController(Presentation.default, from: 0, reading: false, presenter: false)
        sh.setLaser(true)
        #expect(sh.laser && !sh.pen)
        sh.setPen(true)
        #expect(sh.pen && !sh.laser)
        sh.setLaser(true)
        sh.arrow()
        #expect(!sh.laser && !sh.pen)
        sh.setLaser(false)
        #expect(!sh.laser)
    }

    static func deckWithFirstAnimation(_ start: AnimStart) -> Presentation {
        var doc = doc(session(1))
        var a = Animation.default
        a.shape = doc.slides[1].shapes[0].id
        a.start = start
        a.durationMs = 3000
        doc.slides[1].animations = [a]
        return doc
    }

    // show.rs: a_first_animation_after_or_with_previous_plays_when_the_slide_appears (#631)
    @Test func aFirstAnimationAfterOrWithPreviousPlaysWhenTheSlideAppears() {
        for start in [AnimStart.afterPrevious, .withPrevious] {
            let doc = Self.deckWithFirstAnimation(start)
            let sh = ShowController(doc, from: 1, reading: false, presenter: false)
            sh.afterEnter(doc, 5)
            #expect(sh.state.step == 0 && sh.state.playing, "\(start) from the start")
            #expect(sh.stepStart == 5)
            let sh2 = ShowController(doc, from: 0, reading: false, presenter: false)
            let a = sh2.state.next(doc)
            #expect(a == .slide(1))
            #expect(sh2.apply(a, doc, 7))
            #expect(sh2.state.step == 0 && sh2.state.playing, "\(start) on arrival")
        }
        let doc = Self.deckWithFirstAnimation(.onClick)
        let sh = ShowController(doc, from: 1, reading: false, presenter: false)
        sh.afterEnter(doc, 5)
        #expect(sh.state.step == 0 && !sh.state.playing)
        #expect(sh.state.next(doc) == .playStep(0))
    }

    // show.rs: zoom_stays_on_the_slide_and_the_grid_hits_a_thumbnail
    @Test func zoomStaysOnTheSlideAndTheGridHitsAThumbnail() throws {
        let uv = ShowGeometry.zoomUV(0.5, 0.5, 2)
        #expect(Swift.abs(uv.minX - 0.25) < 1e-4 && Swift.abs(uv.minY - 0.25) < 1e-4)
        #expect(Swift.abs(uv.width - 0.5) < 1e-4)
        let corner = ShowGeometry.zoomUV(0, 0, 2)
        #expect(corner.origin == .zero)
        #expect(corner.maxX <= 1 && corner.maxY <= 1)
        let full = CGRect(x: 0, y: 0, width: 1728, height: 1084)
        let cells = ShowGeometry.seeAllCells(full, 7, 16.0 / 9.0)
        #expect(cells.count == 7)
        for (i, a) in cells.enumerated() {
            #expect(full.contains(a), "cell \(i) leaves the window")
            for b in cells.dropFirst(i + 1) {
                let o = a.intersection(b)
                #expect(o.isNull || o.width < 1 || o.height < 1, "thumbnails overlap \(a) \(b)")
            }
        }
        #expect(ShowGeometry.seeAllHit(full, 7, 16.0 / 9.0, CGPoint(x: cells[3].midX, y: cells[3].midY)) == 3)
        #expect(ShowGeometry.seeAllHit(full, 7, 16.0 / 9.0, CGPoint(x: 2, y: 2)) == nil)
        let srect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let mid = try #require(ShowGeometry.normOnSlide(srect, ShowGeometry.unitUV, CGPoint(x: 110, y: 70)))
        #expect(mid.0 == 0.5 && mid.1 == 0.5)
        let back = try #require(ShowGeometry.normOnSlide(srect, ShowGeometry.zoomUV(0.5, 0.5, 2), CGPoint(x: 110, y: 70)))
        #expect(Swift.abs(back.0 - 0.5) < 1e-3 && Swift.abs(back.1 - 0.5) < 1e-3)
    }

    static func near(_ a: Double, _ b: Double) -> Bool { Swift.abs(a - b) < 1e-3 }

    // show.rs: wheel_zoom_keeps_the_point_under_the_pointer_and_stops_at_4x (#1286)
    @Test func wheelZoomKeepsThePointUnderThePointerAndStopsAt4x() throws {
        let sh = ShowController(Presentation.default, from: 0, reading: false, presenter: false)
        let srect = CGRect(x: 40, y: 30, width: 320, height: 180)
        let p = CGPoint(x: 40 + 320 * 0.2, y: 30 + 180 * 0.3)
        sh.wheelZoom(srect, p, 4)
        var z = try #require(sh.zoom, "zoomed in")
        #expect(Self.near(z.scale, 2), "four notches double, got \(z.scale)")
        let uv = sh.zoomUV
        #expect(Self.near(uv.width, 0.5) && Self.near(uv.height, 0.5))
        #expect(Self.near(uv.minX, 0.2 - 0.5 * 0.2) && Self.near(uv.minY, 0.3 - 0.5 * 0.3))
        var under = try #require(ShowGeometry.normOnSlide(srect, uv, p))
        #expect(Self.near(under.0, 0.2) && Self.near(under.1, 0.3))
        sh.wheelZoom(srect, p, 2)
        z = try #require(sh.zoom)
        #expect(Self.near(z.scale, pow(2, 1.5)))
        under = try #require(ShowGeometry.normOnSlide(srect, sh.zoomUV, p))
        #expect(Self.near(under.0, 0.2) && Self.near(under.1, 0.3))
        sh.wheelZoom(srect, p, 40)
        z = try #require(sh.zoom)
        #expect(Self.near(z.scale, 4), "capped at 4×")
        #expect(Self.near(sh.zoomUV.width, 0.25))
        sh.wheelZoom(srect, p, -7)
        #expect(sh.zoom != nil, "one notch short of the whole slide is still zoomed")
        sh.wheelZoom(srect, p, -1)
        #expect(sh.zoom == nil, "back to the whole slide leaves the zoom")
        #expect(sh.zoomUV == ShowGeometry.unitUV)
        sh.wheelZoom(srect, p, -3)
        #expect(sh.zoom == nil)
        sh.wheelZoom(srect, CGPoint(x: 10, y: 10), 4)
        #expect(sh.zoom == nil, "off the slide the wheel does not zoom")
        sh.zoomArm = true
        sh.wheelZoom(srect, p, 4)
        #expect(!sh.zoomArm && sh.zoom != nil, "an armed click-zoom gives way to the wheel")
    }

    // show.rs: wheel_zoom_reads_only_the_wheel_with_ctrl_or_cmd and
    // ctrl_wheel_zooms_the_show_and_the_plain_wheel_turns_the_page (#1286). The Mac view reads ⌘/Ctrl from the
    // scroll event and hands the coordinator zoom lines or a flick; a pinch never reaches it.
    @Test func ctrlWheelZoomsTheShowAndThePlainWheelTurnsThePage() throws {
        let c = Self.running(Self.session(2))
        let sh = try #require(c.show)
        let full = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let centre = CGPoint(x: 500, y: 350)
        _ = c.scroll(centre, full, zoomLines: 4, flick: (0, 0), now: 11)
        #expect(sh.state.slide == 0, "the zoom wheel does not turn the page")
        #expect(Self.near(sh.zoom?.scale ?? 0, 2))
        _ = c.scroll(centre, full, zoomLines: -4, flick: (0, 0), now: 11)
        #expect(sh.state.slide == 0)
        #expect(sh.zoom == nil, "back to the whole slide")
        _ = c.scroll(centre, full, zoomLines: nil, flick: (0, -120), now: 12)
        #expect(sh.state.slide == 1, "the plain wheel turns the page")
        _ = c.scroll(centre, full, zoomLines: nil, flick: (0, -120), now: 12.1)
        #expect(sh.state.slide == 1, "one gesture turns one page")
        #expect(ShowCoordinator.pageFlick((0, 10)) == nil, "a nudge under 18 points is ignored")
        #expect(ShowCoordinator.pageFlick((30, -20)) == false, "the stronger axis wins")
        #expect(ShowCoordinator.pageFlick((0, -19)) == true)
    }

    // show.rs: escape_only_closes_the_grid_of_its_own_window
    @Test func escapeOnlyClosesTheGridOfItsOwnWindow() {
        let doc = Self.doc(Self.session(1))
        let sh = ShowController(doc, from: 0, reading: false, presenter: true)
        sh.presenterGrid = true
        #expect(!sh.backOut(false), "audience Esc leaves the show, the Presenter View grid stays")
        #expect(sh.presenterGrid)
        #expect(sh.backOut(true))
        #expect(!sh.presenterGrid)
        sh.grid = true
        #expect(!sh.backOut(true), "Presenter View Esc does not close the audience grid")
        #expect(sh.grid)
        #expect(sh.backOut(false))
        #expect(!sh.grid)
    }

    // show.rs: escape_leaves_the_grid_then_the_zoom_and_blank_toggles
    @Test func escapeLeavesTheGridThenTheZoomAndBlankToggles() {
        let doc = Self.doc(Self.session(1))
        let sh = ShowController(doc, from: 0, reading: false, presenter: true)
        sh.grid = true
        sh.zoom = .at(0.2, 0.3)
        #expect(sh.backOut(false))
        #expect(!sh.grid)
        #expect(sh.zoom != nil, "closing the grid leaves the zoom")
        #expect(sh.backOut(false))
        #expect(sh.zoom == nil)
        #expect(!sh.backOut(false))
        sh.zoomKey()
        #expect(sh.zoomArm)
        sh.zoomKey()
        #expect(!sh.zoomArm)
        sh.toggleBlank(.black)
        #expect(sh.blank == .black)
        sh.toggleBlank(.white)
        #expect(sh.blank == .white)
        sh.toggleBlank(.white)
        #expect(sh.blank == nil)
        sh.zoom = .at(0.4, 0.6)
        #expect(sh.apply(.slide(1), doc, 1))
        #expect(sh.zoom == nil, "a new slide is shown whole")
    }

    // show.rs: presenter_notes_keep_bullets_numbers_and_bold (#1128)
    @Test func presenterNotesKeepBulletsNumbersAndBold() throws {
        func point(_ text: String, _ bullet: Bullet) -> Paragraph {
            var p = Paragraph(level: 1, runs: [Run(text)])
            p.props.bullet = bullet
            return p
        }
        let num = Bullet.autoNum(scheme: "arabicPeriod", startAt: 1)
        var bold = RunProps()
        bold.bold = true
        let notes = TextBody(paragraphs: [
            Paragraph(runs: [Run.with("Opening", bold)]), point("Welcome", .char(char: "•")), point("Agenda", num), point("Demo", num),
        ])
        let paras = try #require(ShowNotes.paragraphs(notes, size: 24))
        #expect(paras.map(\.marker) == [nil, "•", "1.", "2."])
        #expect(paras[0].runs.first?.bold == true && paras[0].runs.first?.size == 24, "bold runs stay bold at the pane's size")
        #expect(paras[2].runs.first?.bold == false && paras[2].runs.first?.text == "Agenda")
        #expect(ShowNotes.paragraphs(TextBody(), size: 24) == nil, "No notes.")
    }

    // show.rs: hidden_logic_advances_the_show_and_visible_frames_reanchor
    @Test func hiddenLogicAdvancesTheShowAndVisibleFramesReanchor() {
        let doc = Self.doc(Self.session(1))
        let sh = ShowController(doc, from: 0, reading: false, presenter: true)
        sh.begin(doc, 10)
        let t0 = 1000.0
        sh.observeVisibleFrame(10, t0)
        #expect(sh.hiddenLogicTime(10, t0) == 10, "the first hidden tick starts at the last visible time")
        let hidden = sh.hiddenLogicTime(10, t0 + 2)
        #expect(Swift.abs(hidden - 12) < 1e-9)
        #expect(Swift.abs(sh.timer.elapsed(hidden) - 2) < 1e-9, "presenter time keeps running")
        #expect(Swift.abs(sh.stepStart - 10) < 1e-9, "the clock origin is not shifted")
        #expect(Swift.abs(sh.hiddenLogicTime(10, t0 + 5) - 15) < 1e-9, "repeated hidden ticks do not stack a pause")
        sh.observeVisibleFrame(20, t0 + 10)
        #expect(sh.hiddenLogicTime(20, t0 + 10) == 20, "a visible frame re-anchors")
    }

    // show.rs: presenter_timer_pauses_resets_and_notes_size_clamps
    @Test func presenterTimerPausesResetsAndNotesSizeClamps() {
        var t = PresenterTimer.start(10)
        #expect(Swift.abs(t.elapsed(12.5) - 2.5) < 1e-9)
        t.toggle(15)
        #expect(t.paused)
        #expect(Swift.abs(t.elapsed(100) - 5) < 1e-9)
        t.reset(100)
        #expect(t.paused)
        #expect(t.elapsed(200) == 0)
        t.toggle(200)
        #expect(!t.paused)
        #expect(Swift.abs(t.elapsed(203) - 3) < 1e-9)
        t.reset(203)
        #expect(!t.paused)
        #expect(Swift.abs(t.elapsed(204) - 1) < 1e-9)
        #expect(PresenterTimer.start(.nan).elapsed(.infinity) == 0)
        #expect(PresenterTimer.format(3661.4) == "01:01:01")
        #expect(PresenterTimer.format(-1) == "00:00:00")
        #expect(PresenterTimer.format(.nan) == "00:00:00")
        #expect(PresenterTimer.format(1e300) == "99:59:59")
        let clock = PresenterTimer.wallClock()
        #expect(clock == "--:--" || (clock.count == 5 && Array(clock)[2] == ":"))
        let doc = Self.doc(Self.session(1))
        let sh = ShowController(doc, from: 0, reading: false, presenter: true)
        #expect(sh.notesPx == ShowController.notesDefault)
        sh.nudgeNotes(ShowController.notesStep)
        #expect(sh.notesPx == 22)
        sh.nudgeNotes(1000)
        #expect(sh.notesPx == ShowController.notesMax)
        sh.nudgeNotes(-1000)
        #expect(sh.notesPx == ShowController.notesMin)
        sh.nudgeNotes(.nan)
        #expect(sh.notesPx == ShowController.notesMin)
        let v = sh.showingValue(nSlides: 1, aspect: 16.0 / 9.0, full: CGRect(x: 0, y: 0, width: 100, height: 100), now: 0)
        #expect(v["presenterPaused"]?.asBool == false)
        #expect(v["notesPx"]?.asF64 == ShowController.notesMin)
    }

    // show.rs: a_typed_slide_number_jumps_and_then_expires
    @Test func aTypedSlideNumberJumpsAndThenExpires() {
        let doc = Self.doc(Self.session(1))
        let sh = ShowController(doc, from: 0, reading: false, presenter: false)
        sh.pushSlideNumber("1", 10)
        sh.pushSlideNumber("2", 10.2)
        #expect(sh.goto == "12")
        #expect(sh.takeGoto() == 11)
        #expect(sh.goto.isEmpty)
        sh.pushSlideNumber("0", 1)
        #expect(sh.takeGoto() == nil, "slide 0 is not a slide")
        sh.pushSlideNumber("4", 5)
        sh.expireGoto(7)
        #expect(sh.goto == "4")
        sh.expireGoto(8.1)
        #expect(sh.goto.isEmpty)
        sh.pushSlideNumber("9", 0)
        #expect(sh.clearGoto())
        #expect(!sh.clearGoto())
        for _ in 0 ..< 6 { sh.pushSlideNumber("9", 1) }
        #expect(sh.goto.count == ShowController.gotoDigits)
        sh.pushSlideNumber("a", 1)
        let digits = sh.goto.allSatisfy { $0.isNumber }
        #expect(digits)
        // Number + Enter jumps.
        _ = sh.clearGoto()
        _ = sh.key(.digit("2"), ShowMods(), doc, 2, presenter: false)
        _ = sh.key(.enter, ShowMods(), doc, 2, presenter: false)
        #expect(sh.state.slide == 1)
    }

    // show.rs: browsed_by_an_individual_stays_in_a_window
    @Test func browsedByAnIndividualStaysInAWindow() {
        #expect(!showFillsScreen(reading: false, showType: "browsed"))
        #expect(!showFillsScreen(reading: true, showType: "speaker"))
        #expect(showFillsScreen(reading: false, showType: "speaker"))
        #expect(showFillsScreen(reading: false, showType: "kiosk"))
    }

    // show.rs: the_next_preview_fits_its_column_whatever_the_slide_shape; texture_limit_tests.rs:
    // presenter_view_keeps_a_portrait_next_slide_in_its_column
    @Test func theNextPreviewFitsItsColumnWhateverTheSlideShape() throws {
        let right = CGRect(x: 700, y: 100, width: 400, height: 600)
        let s = Session.withNew()
        for (w, h) in [(72, 4032), (4032, 72), (960, 540)] {
            _ = try s.execute("design.slideSize", ["w": .integer(w), "h": .integer(h)])
            let r = ShowGeometry.nextRect(right, Self.doc(s))
            #expect(right.insetBy(dx: -0.01, dy: -0.01).contains(r), "\(w)x\(h): \(r)")
            let aspect = r.height / r.width
            #expect(Swift.abs(aspect - Double(h) / Double(w)) / (Double(h) / Double(w)) < 0.01, "\(w)x\(h): \(r)")
        }
        #expect(ShowGeometry.nextRect(right, Self.doc(s)).width == 400, "16:9 still takes the column's full width")
    }

    // show.rs: back_leaves_a_slide_whose_first_animation_is_with_previous (#844)
    @Test func backLeavesASlideWhoseFirstAnimationIsWithPrevious() throws {
        let s = Self.session(1)
        let id = Self.doc(s).slides[1].shapes[0].id
        _ = try s.execute("animation.add", ["effect": "fade", "class": "entrance", "ids": [.integer(Int(id.rawValue))], "start": "withPrevious", "duration": 500])
        let c = Self.running(s)
        let sh = try #require(c.show)
        var now = 10.0
        _ = c.key(.arrowRight, ShowMods(), presenter: false, now: now)
        // The first step plays by itself and ends (0.5 s; a frame is 0.25 s).
        for _ in 0 ..< 8 {
            now += 0.25
            _ = c.tick(now)
        }
        #expect(sh.state.slide == 1 && sh.state.step == 1 && !sh.state.playing, "on slide 2, fully built")
        for _ in 0 ..< 5 {
            _ = c.key(.arrowLeft, ShowMods(), presenter: false, now: now)
            now += 0.25
            _ = c.tick(now)
            now += 0.25
            _ = c.tick(now)
        }
        #expect(sh.state.slide == 0, "five Backs leave slide 2 (step \(sh.state.step), playing \(sh.state.playing))")
    }

    // show.rs: input_state_tracks_the_modes_that_move_show_click_targets
    @Test func inputStateTracksTheModesThatMoveShowClickTargets() {
        let sh = ShowController(Self.doc(Session.withNew()), from: 0, reading: false, presenter: false)
        let base = sh.inputState
        #expect(sh.inputState == base)
        sh.instance += 1
        #expect(sh.inputState != base, "a new show instance is a new input target")
        sh.instance = base.instance
        sh.reading = true
        #expect(sh.inputState != base, "the reading layout moves the slide")
        sh.reading = false
        sh.presenter = true
        #expect(sh.inputState != base)
        sh.presenter = false
        sh.grid = true
        #expect(sh.inputState != base)
        sh.grid = false
        sh.setPen(true)
        #expect(sh.inputState != base)
        sh.setPen(false)
        sh.setLaser(true)
        #expect(sh.inputState != base)
        sh.setLaser(false)
        sh.zoomArm = true
        #expect(sh.inputState != base)
        sh.zoomArm = false
        sh.zoom = .at(0.25, 0.75)
        #expect(sh.inputState != base)
        sh.zoom = nil
        sh.blank = .black
        #expect(sh.inputState != base)
    }

    // MARK: Beyond show.rs's tests

    /// `show.start` and its siblings through `ShowCoordinator.command` (`run_ui`'s arms, `show_from`).
    @Test func showCommandsStartEndAndValidate() throws {
        let s = Self.session(2)
        let m = AppModel(session: s)
        let c = ShowCoordinator(model: m)
        var started = 0, ended = 0
        c.onShowStarted = { _ in started += 1 }
        c.onShowEnded = { ended += 1 }
        guard case .failure(let e)? = c.command("show.start", ["from": 9]) else { Issue.record("expected an error"); return }
        #expect(e.message == "no slide 9")
        #expect(c.show == nil, "a bad index never plays slide 0")
        guard case .failure? = c.command("show.start", ["from": -1]) else { Issue.record("expected an error"); return }
        _ = try #require(c.command("show.start", ["from": 2])).get()
        #expect(c.show?.state.slide == 2 && started == 1)
        _ = try #require(c.command("show.end", .emptyObject)).get()
        #expect(c.show == nil && ended == 1)
        #expect(m.session.activeDoc?.selection.slide == 2, "the editor is left on the last slide shown")
        _ = try #require(c.command("view.reading", .emptyObject)).get()
        #expect(c.show?.reading == true && c.show?.presenter == false)
        c.endShow()
        #expect(c.request(.startShow(from: 1)))
        #expect(c.show?.state.slide == 1)
        #expect(!c.request(.message(text: "hi")))
        c.endShow()
        _ = try #require(c.command("show.start", ["preview": true])).get()
        #expect(c.show?.previewOnly == true && c.show?.reading == true)
        c.endShow()
        #expect(c.command("view.normal", .emptyObject) == nil)
    }

    /// Play from Start begins at the first slide the show plays (hidden slides skipped); custom shows play their
    /// own slides.
    @Test func showStartIndexAndCustomShows() throws {
        let s = Self.session(2)
        _ = try s.execute("slide.go", ["index": 0])
        _ = try s.execute("slide.hide", .emptyObject)
        let m = AppModel(session: s)
        let c = ShowCoordinator(model: m)
        #expect(c.showStartIndex == 1)
        _ = try s.execute("show.customShow", ["name": "Short", "slides": [2]])
        c.startCustomShow("Short", reading: false)
        #expect(c.show?.state.slide == 2)
        #expect(c.show?.state.customName == "Short")
        c.endShow()
        c.startCustomShow("Missing", reading: false)
        #expect(c.show == nil)
    }

    /// Rehearse Timings records each slide's time with `transition.timing` when the show ends.
    @Test func rehearsedTimingsAreRecorded() throws {
        let s = Self.session(1)
        let m = AppModel(session: s)
        let c = ShowCoordinator(model: m)
        c.startShow(from: 0, reading: false, rehearse: true)
        let start = ShowCoordinator.now()
        _ = c.tick(start)
        _ = c.key(.arrowRight, ShowMods(), presenter: false, now: start + 2)
        c.endShow()
        let doc = Self.doc(s)
        #expect(doc.slides[0].transition?.advanceAfterMs.map { Swift.abs(Int($0) - 2000) < 50 } == true)
        #expect(m.status == "Slide timings recorded.")
    }

    /// Keys by name, as the control channel's `ui.key` sends them.
    @Test func keysByName() {
        #expect(ShowKey(name: "ArrowRight") == .arrowRight)
        #expect(ShowKey(name: "right") == .arrowRight)
        #expect(ShowKey(name: "Escape") == .escape)
        #expect(ShowKey(name: "esc") == .escape)
        #expect(ShowKey(name: "B") == .b)
        #expect(ShowKey(name: "7") == .digit("7"))
        #expect(ShowKey(name: "Num3") == .digit("3"))
        #expect(ShowKey(name: "Return") == .enter)
        #expect(ShowKey(name: "F5") == .other)
    }

    /// B/W screens, the pen and laser with ⌘, grid and zoom keys, the timer and notes keys.
    @Test func toolKeys() {
        let doc = Self.doc(Self.session(1))
        let sh = ShowController(doc, from: 0, reading: false, presenter: false)
        _ = sh.key(.b, ShowMods(), doc, 1, presenter: false)
        #expect(sh.blank == .black)
        _ = sh.key(.period, ShowMods(), doc, 1, presenter: false)
        #expect(sh.blank == nil)
        _ = sh.key(.comma, ShowMods(), doc, 1, presenter: false)
        #expect(sh.blank == .white)
        _ = sh.key(.p, ShowMods(command: true), doc, 1, presenter: false)
        #expect(sh.pen)
        _ = sh.key(.l, ShowMods(command: true), doc, 1, presenter: false)
        #expect(sh.laser && !sh.pen)
        #expect(!sh.key(.l, ShowMods(), doc, 1, presenter: false).handled, "plain L is not the laser")
        _ = sh.key(.a, ShowMods(command: true), doc, 1, presenter: false)
        #expect(!sh.laser)
        _ = sh.key(.g, ShowMods(), doc, 1, presenter: false)
        #expect(sh.grid)
        #expect(!sh.key(.arrowRight, ShowMods(), doc, 1, presenter: false).handled, "the grid takes no other key")
        _ = sh.key(.escape, ShowMods(), doc, 1, presenter: false)
        #expect(!sh.grid)
        _ = sh.key(.z, ShowMods(), doc, 1, presenter: false)
        #expect(sh.zoomArm)
        _ = sh.key(.t, ShowMods(), doc, 1, presenter: false)
        #expect(sh.timer.paused)
        _ = sh.key(.closeBracket, ShowMods(), doc, 1, presenter: false)
        #expect(sh.notesPx == 22)
    }

    /// The display the show plays on and presenter view's (gap #9, closed with `NSScreen`).
    @Test func showDisplays() {
        let one = [ShowScreen(name: "Built-in", main: true)]
        #expect(ShowDisplays.choose(one, preference: nil, presenterView: true) == (0, nil), "one display: the show alone")
        let two = [ShowScreen(name: "Built-in", main: true), ShowScreen(name: "Projector", main: false)]
        #expect(ShowDisplays.choose(two, preference: nil, presenterView: true) == (1, 0))
        #expect(ShowDisplays.choose(two, preference: nil, presenterView: false) == (1, nil))
        #expect(ShowDisplays.choose(two, preference: ShowDisplays.primary, presenterView: true) == (0, 1))
        #expect(ShowDisplays.choose(two, preference: "Projector", presenterView: true) == (1, 0))
        #expect(ShowDisplays.choose(two, preference: "Gone", presenterView: true) == (1, 0))
        #expect(ShowDisplays.choose([], preference: nil, presenterView: true) == (nil, nil))
    }

    /// The canvas animation preview (`animation.preview`): it plays the current slide, from an effect, and stops
    /// when the slide changes; Escape and `{on: false}` stop it (lib.rs: animation_preview_plays_on_the_canvas_then_stops).
    @Test func animationPreviewPlaysOnTheCanvasThenStops() throws {
        let s = Session.withNew()
        let m = AppModel(session: s)
        let c = ShowCoordinator(model: m)
        let none = try #require(c.command("animation.preview", .emptyObject)).get()
        #expect(none["playing"]?.asBool == false)
        #expect(m.status == "This slide has no animations")
        let r = try s.execute("shape.insert", ["preset": "rect", "rect": [100, 100, 200, 100]])
        _ = try s.execute("animation.set", ["effect": "fade", "ids": [r["id"] ?? .null]])
        let started = try #require(c.command("animation.preview", .emptyObject)).get()
        #expect(started["playing"]?.asBool == true)
        #expect(c.show == nil, "preview stays on the editor canvas")
        #expect(c.tickAnimPreview(100))
        #expect(c.tickAnimPreview(100.2))
        #expect(Swift.abs((c.animPreview?.elapsed ?? 0) - 0.2) < 1e-9)
        #expect(!c.tickAnimPreview(200), "the preview ends after the sequence and its hold")
        _ = try #require(c.command("animation.preview", .emptyObject)).get()
        #expect(c.animPreview != nil)
        _ = try #require(c.command("animation.preview", ["on": false])).get()
        #expect(c.animPreview == nil)
        guard case .failure? = c.command("animation.preview", ["from": 7]) else { Issue.record("expected an error"); return }
        _ = try #require(c.command("animation.preview", .emptyObject)).get()
        _ = try s.execute("slide.new", .emptyObject)
        #expect(!c.tickAnimPreview(300), "a slide change stops it")
        // A preview frame hides an entrance until it plays.
        let tl = ShowState.timeline(Self.doc(s), 0)
        let shape = ShapeId(UInt32(r["id"]?.asU64 ?? 0))
        #expect(ShowCoordinator.previewState(tl, shape, 0).opacity < 0.05 || !ShowCoordinator.previewState(tl, shape, 0).visible)
        #expect(ShowCoordinator.previewState(tl, shape, 10).opacity == 1)
    }

    /// Frame sizes stay within the GPU's limit, keeping their shape (textures.rs:
    /// render_sizes_and_pictures_shrink_to_the_limit_keeping_their_shape; texture_limit_tests.rs).
    @Test func renderSizesShrinkToTheLimitKeepingTheirShape() {
        #expect(ShowRender.fitSize(1920, 1080) == ShowSize(1920, 1080))
        #expect(ShowRender.fitSize(0, 0) == ShowSize(1, 1))
        let big = ShowRender.fitSize(40000, 20000, 16000)
        #expect(big == ShowSize(16000, 8000))
        let tall = ShowRender.fitSize(480, 480 * 56, 16000)
        #expect(tall.h == 16000 && tall.w >= 1)
    }
}
