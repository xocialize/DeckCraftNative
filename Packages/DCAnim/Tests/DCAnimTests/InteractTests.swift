// Ported from deckcraft crates/anim/src/tests_interact.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors): clicks, triggered animations and what the show remembers about visited slides.
import DCGeometry
import DCModel
import Testing
@testable import DCAnim

private func ishape(_ id: UInt32) -> Shape { shape(id, "S\(id)") }

/// A triggered exit (`Disappear` when `ms` is 0, else a fade out) of `target`, started by clicking `trigger`.
private func exitOnClick(_ trigger: UInt32, _ target: UInt32, _ ms: UInt32) -> Animation {
    var a = Animation.default
    a.shape = ShapeId(target)
    a.class = .exit
    a.effect = ms == 0 ? "disappear" : "fadeOut"
    a.start = .onClick
    a.durationMs = ms
    a.trigger = ShapeId(trigger)
    return a
}

private func islide(_ id: UInt32, _ shapes: [Shape], _ animations: [Animation], _ advanceOnClick: Bool) -> Slide {
    var s = Slide.default
    s.id = SlideId(id)
    s.shapes = shapes
    s.animations = animations
    if !advanceOnClick {
        var t = Transition.default
        t.advanceOnClick = false
        s.transition = t
    }
    return s
}

private func toSlide(_ n: UInt32) -> Action? { .slide(slide: SlideId(n)) }

private func hit(_ id: UInt32, _ link: Action?) -> HitShape {
    HitShape(id: ShapeId(id), parent: nil, isGroup: false, link: link, underPointer: true)
}

private func presOf(_ slides: [Slide], withoutAnimation: Bool = false) -> Presentation {
    var p = Presentation.default
    p.slides = slides
    p.show.withoutAnimation = withoutAnimation
    return p
}

/// Test driver: a show plus the click helpers the slide show window uses.
private struct Run {
    var pres: Presentation
    var show: ShowState
    /// Hit shapes of each slide, back to front.
    var hits: [[HitShape]]
    var now = 0.0

    init(_ pres: Presentation, _ hits: [[HitShape]]) {
        self.pres = pres
        show = ShowState(pres)
        self.hits = hits
    }

    func tl() -> Timeline { ShowState.timeline(pres, show.slide) }

    func visible(_ id: ShapeId) -> Bool {
        let st = show.animState(tl(), id, 0.0)
        return st.visible && st.opacity > 0.0
    }

    func opacity(_ id: UInt32) -> Double { show.animState(tl(), ShapeId(id), 0.0).opacity }

    mutating func click() -> Click {
        let (tl, hits) = (tl(), hits[show.slide])
        let vis = hits.map { ($0.id, visible($0.id)) }
        return show.click(pres, tl, hits, { id in vis.first { $0.0 == id }.map(\.1) ?? true }, now, nil)
    }

    func target() -> Target? {
        show.target(pres, tl(), hits[show.slide]) { visible($0) }
    }

    /// Let `secs` pass on the shown slide, in small frames.
    mutating func wait(_ secs: Double) {
        let end = now + secs
        while now < end - 1e-9 {
            now = Swift.min(now + 0.05, end)
            show.tick(tl(), now)
        }
    }
}

/// The test deck: slide 1 has a text box (3), a linked button that also disappears (2) and a picture on top of
/// both that disappears (4); slide 2 has a button back to slide 1.
private func twoSlides(_ advanceOnClick: Bool) -> Run {
    let s1 = islide(1000, [ishape(3), ishape(2), ishape(4)], [exitOnClick(4, 4, 0), exitOnClick(2, 2, 0)], advanceOnClick)
    let s2 = islide(1001, [ishape(1)], [], advanceOnClick)
    return Run(presOf([s1, s2]), [[hit(3, nil), hit(2, toSlide(1001)), hit(4, nil)], [hit(1, toSlide(1000))]])
}

@Suite struct InteractTests {
    @Test func hiddenShapesStayHiddenWhenTheShowComesBack() {
        var r = twoSlides(false)
        #expect(r.target()?.shape == ShapeId(4), "the picture is on top")
        // Click the picture: it disappears; the button beneath it is now the target.
        var c = r.click()
        #expect(c == .animated)
        #expect(!r.visible(ShapeId(4)))
        #expect(r.target()?.shape == ShapeId(2))
        // Click the button: its animation starts and the link is followed.
        c = r.click()
        #expect(c == .show(.slide(1)))
        #expect(r.show.slide == 1)
        // Slide 2: the button goes back.
        c = r.click()
        #expect(c == .show(.slide(0)))
        #expect(r.show.slide == 0)
        // Both are still gone, and nothing on the slide can be clicked any more.
        #expect(!r.visible(ShapeId(4)) && !r.visible(ShapeId(2)) && r.visible(ShapeId(3)))
        #expect(r.target() == nil)
        // "Advance on click" is off: a click anywhere does nothing, however often.
        for _ in 0 ..< 3 {
            c = r.click()
            #expect(c == .none_)
        }
        #expect(r.show.slide == 0)
    }

    @Test func backgroundClickAdvancesWhenTheSlideAllowsIt() {
        var r = twoSlides(true)
        _ = r.click() // the picture disappears
        _ = r.click() // the button disappears and links to slide 2
        _ = r.click() // the button there links back
        #expect(r.show.slide == 0)
        #expect(r.target() == nil)
        let c = r.click()
        #expect(c == .show(.slide(1)))
    }

    @Test func advanceOnClickOffStillPlaysAnimationSteps() {
        var main = Animation.default
        main.shape = ShapeId(1)
        main.class = .entrance
        main.effect = "fade"
        main.durationMs = 500
        let s1 = islide(1000, [ishape(1)], [main], false)
        let s2 = islide(1001, [], [], false)
        var r = Run(presOf([s1, s2]), [[hit(1, nil)], []])
        // The first click plays the step, the next finishes it; then the slide stays.
        var c = r.click()
        #expect(c == .show(.playStep(0)))
        c = r.click()
        #expect(c == .show(.finishStep(0)))
        c = r.click()
        #expect(c == .none_)
        #expect(r.show.slide == 0)
        // The arrow keys still move on.
        let a = r.show.next(r.pres)
        #expect(a == .slide(1))
    }

    @Test func aShapeWithoutAnActionBlocksTheOneBeneathIt() {
        let s = islide(1000, [ishape(1), ishape(2)], [], true)
        var r = Run(presOf([s, islide(1001, [], [], true)]), [[hit(1, toSlide(1001)), hit(2, nil)], []])
        #expect(r.target() == nil, "the plain shape on top blocks the button")
        // So the click is a background click, not the button's link.
        let c = r.click()
        #expect(c == .show(.slide(1)))
        // Reversed, the button is on top and is the target.
        let s2 = islide(1000, [ishape(2), ishape(1)], [], true)
        let r2 = Run(presOf([s2, islide(1001, [], [], true)]), [[hit(2, nil), hit(1, toSlide(1001))], []])
        #expect(r2.target()?.shape == ShapeId(1))
    }

    @Test func groupsAnswerForTheirChildren() {
        let pres = presOf([islide(1000, [ishape(1)], [], true), islide(1001, [], [], true)])
        func group(_ link: Action?) -> HitShape { HitShape(id: ShapeId(10), parent: nil, isGroup: true, link: link, underPointer: true) }
        let child = HitShape(id: ShapeId(11), parent: 1, isGroup: false, link: nil, underPointer: true)
        // A child of a group with an action acts as the group.
        let r = Run(pres, [[hit(5, nil), group(toSlide(1001)), child], []])
        #expect(r.target()?.shape == ShapeId(10))
        // Empty space inside the box of a group without an action blocks nothing.
        let r2 = Run(pres, [[hit(5, toSlide(1001)), group(nil)], []])
        #expect(r2.target()?.shape == ShapeId(5))
    }

    @Test func pointerOutsideAShapeIsNotOnIt() {
        let pres = presOf([islide(1000, [ishape(1)], [], true)])
        var h = hit(1, toSlide(1000))
        h.underPointer = false
        let r = Run(pres, [[h]])
        #expect(r.target() == nil)
    }

    @Test func eachClickPlaysOneStepOfATriggerAndAClickCompletesAPlayingStep() {
        // Clicking shape 1 fades shape 2 out over 5 s, then shape 3 over 5 s.
        let s = islide(1000, [ishape(1), ishape(2), ishape(3)], [exitOnClick(1, 2, 5000), exitOnClick(1, 3, 5000)], true)
        var r = Run(presOf([s]), [[hit(2, nil), hit(3, nil), hit(1, nil)]])
        #expect(r.target()?.shape == ShapeId(1))
        var c = r.click()
        #expect(c == .animated)
        r.wait(2.0)
        #expect(r.show.triggerPlaying)
        #expect(r.opacity(2) < 1.0 && r.opacity(2) > 0.0, "part way through the fade")
        #expect(r.visible(ShapeId(3)))
        // A click on the shape while its step plays completes the step at once...
        c = r.click()
        #expect(c == .animated)
        #expect(!r.visible(ShapeId(2)) && !r.show.triggerPlaying)
        // ...and the next click plays the next step.
        c = r.click()
        #expect(c == .animated)
        r.wait(5.2)
        #expect(!r.visible(ShapeId(3)))
        // All steps have played, and the shape still answers: its sequence starts over.
        #expect(r.target()?.shape == ShapeId(1))
        c = r.click()
        #expect(c == .animated)
        #expect(r.visible(ShapeId(2)) && r.visible(ShapeId(3)), "the first lap's effects are undone")
        r.wait(5.2)
        #expect(!r.visible(ShapeId(2)) && r.visible(ShapeId(3)))
    }

    @Test func aRingOfTriggersGoesRoundAndRound() {
        // Soccer's score: clicking shape k hides it and shows shape k+1; the last shows the first again.
        let ring: UInt32 = 4
        let anims: [Animation] = (1 ... ring).flatMap { k -> [Animation] in
            var show = Animation.default
            show.shape = ShapeId(k % ring + 1)
            show.class = .entrance
            show.effect = "appear"
            show.start = .withPrevious
            show.durationMs = 0
            show.trigger = ShapeId(k)
            return [exitOnClick(k, k, 0), show]
        }
        let s = islide(1000, (1 ... ring).map(ishape), anims, true)
        var r = Run(presOf([s]), [(1 ... ring).map { hit($0, nil) }])
        func showing(_ r: Run) -> [UInt32] { (1 ... ring).filter { r.visible(ShapeId($0)) } }
        #expect(showing(r) == [1])
        for lap in 0 ..< 3 {
            for k in 1 ... ring {
                #expect(showing(r) == [k], "lap \(lap), before click \(k)")
                #expect(r.target()?.shape == ShapeId(k))
                let c = r.click()
                #expect(c == .animated)
            }
        }
        #expect(showing(r) == [1])
    }

    @Test func aLinkIsFollowedAtOnceAndTheAnimationGoesOnWhereItStopped() {
        // Shape 1 fades shape 4 over 5 s; shape 2 links to slide 2.
        let s1 = islide(1000, [ishape(1), ishape(2), ishape(4)], [exitOnClick(1, 4, 5000)], false)
        let s2 = islide(1001, [ishape(5)], [], false)
        var r = Run(presOf([s1, s2]), [[hit(4, nil), hit(2, toSlide(1001)), hit(1, nil)], [hit(5, toSlide(1000))]])
        // Click the animated shape, wait 2 s, click the link.
        _ = r.click()
        r.wait(2.0)
        #expect(r.show.triggerPlays.first?.t.rounded() == 2.0)
        // The second shape is not over the first one, so click the link directly.
        let tl = r.tl()
        let hits = [hit(2, toSlide(1001))]
        var c = r.show.click(r.pres, tl, hits, { _ in true }, r.now, nil)
        #expect(c == .show(.slide(1)))
        // However long the show stays away, the animation does not run.
        r.wait(60.0)
        c = r.click()
        #expect(c == .show(.slide(0)))
        // Back on the slide it has 3 s left.
        #expect(Swift.abs((r.show.triggerPlays.first?.t ?? .nan) - 2.0) < 0.1)
        #expect(r.show.triggerPlaying)
        r.wait(2.5)
        #expect(r.show.triggerPlaying && r.opacity(4) > 0.0)
        r.wait(1.0)
        #expect(!r.show.triggerPlaying && !r.visible(ShapeId(4)))
    }

    @Test func aShapeWithALinkAndAnAnimationFollowsTheLinkWithoutWaiting() {
        let s1 = islide(1000, [ishape(2)], [exitOnClick(2, 2, 5000)], false)
        let s2 = islide(1001, [ishape(5)], [], false)
        var r = Run(presOf([s1, s2]), [[hit(2, toSlide(1001))], [hit(5, toSlide(1000))]])
        var c = r.click()
        #expect(c == .show(.slide(1)))
        r.wait(30.0)
        c = r.click()
        #expect(c == .show(.slide(0)))
        // The whole animation is still ahead.
        #expect(r.visible(ShapeId(2)) && r.opacity(2) > 0.95)
        #expect(r.show.triggerPlaying)
        r.wait(5.5)
        #expect(!r.visible(ShapeId(2)))
    }

    @Test func aSlideComesBackTheWayItWasLeft() {
        let steps: [Animation] = (1 ... 3).map { i in
            var a = Animation.default
            a.shape = ShapeId(UInt32(i))
            a.class = .entrance
            a.effect = "appear"
            a.durationMs = 0
            return a
        }
        let s1 = islide(1000, [ishape(1), ishape(2), ishape(3)], steps, true)
        let pres = presOf([s1, islide(1001, [], [], true), islide(1002, [], [], true)])
        var s = ShowState(pres)
        _ = s.next(pres)
        _ = s.stepDone(pres)
        #expect(s.step == 1)
        // A link away and back: still after step 1.
        var j = s.follow(pres, .slide(slide: SlideId(1002)), nil)
        #expect(j == .show(.slide(2)))
        j = s.follow(pres, .slide(slide: SlideId(1000)), nil)
        #expect(j == .show(.slide(0)))
        #expect(s.step == 1 && !s.playing)
        // So does the back arrow.
        _ = s.goto(pres, 1)
        var a = s.prev(pres)
        #expect(a == .slide(0))
        #expect(s.step == 1)
        // A slide the show has not been to is entered at its start; going back to one shows it fully built.
        var s2 = ShowState(pres)
        _ = s2.goto(pres, 2)
        a = s2.prev(pres)
        #expect(a == .slide(1))
        #expect(s2.step == ShowState.steps(pres, 1))
    }

    @Test func aPlayingMainStepIsFinishedWhenTheShowLeaves() {
        var an = Animation.default
        an.shape = ShapeId(1)
        an.class = .entrance
        an.effect = "fade"
        an.durationMs = 500
        let pres = presOf([islide(1000, [ishape(1)], [an], true), islide(1001, [], [], true)])
        var s = ShowState(pres)
        let a = s.next(pres)
        #expect(a == .playStep(0))
        _ = s.goto(pres, 1)
        _ = s.goto(pres, 0)
        #expect(s.step == 1 && !s.playing)
    }

    @Test func showWithoutAnimationIgnoresTriggers() {
        let s = islide(1000, [ishape(1), ishape(2)], [exitOnClick(1, 2, 0)], true)
        let r = Run(presOf([s], withoutAnimation: true), [[hit(2, nil), hit(1, nil)]])
        #expect(r.target() == nil)
    }

    @Test func clocksAndPointersWithHostileNumbersAreHarmless() {
        var r = twoSlides(true)
        let tl = r.tl()
        for now in [Double.nan, .infinity, -1.0e300, 1.0e300, 0.0] {
            r.show.tick(tl, now)
            _ = r.show.click(r.pres, tl, [], { _ in true }, now, nil)
        }
        // A parent index that points nowhere, or in a circle, is not followed forever.
        let bad = [
            HitShape(id: ShapeId(1), parent: 7, isGroup: true, link: nil, underPointer: true),
            HitShape(id: ShapeId(2), parent: 2, isGroup: false, link: nil, underPointer: true),
        ]
        #expect(r.show.target(r.pres, tl, bad) { _ in true } == nil)
    }
}
