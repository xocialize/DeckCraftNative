// Ported from deckcraft crates/anim/src/tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors): timelines, effects, motion paths, easing, transitions, Morph and the show's navigation.
import DCColor
import DCCore
import DCGeometry
import DCModel
import Foundation
import Testing
@testable import DCAnim

let W = 960.0
let H = 540.0

func shape(_ id: UInt32, _ name: String) -> Shape {
    var s = Shape.default
    s.id = ShapeId(id)
    s.name = name
    s.xfrm = Xfrm(100.0, 100.0, 200.0, 100.0)
    return s
}

func anim(_ shape: UInt32, _ cls: AnimClass, _ effect: String, _ start: AnimStart) -> Animation {
    var a = Animation.default
    a.shape = ShapeId(shape)
    a.class = cls
    a.effect = effect
    a.start = start
    a.durationMs = 1000
    return a
}

func slideWith(_ anims: [Animation]) -> Slide {
    var s = Slide.default
    s.shapes = (1 ... 4).map { shape(UInt32($0), "S\($0)") }
    s.animations = anims
    return s
}

func finite(_ s: AnimState) -> Bool {
    s.opacity.isFinite && s.offsetX.isFinite && s.offsetY.isFinite && s.scaleX.isFinite && s.scaleY.isFinite && s.rotate.isFinite
        && (s.clip.map { c in (0 ..< 4).allSatisfy { c[$0].isFinite } } ?? true)
}

private func covers(_ l: Layer) -> Bool {
    l.source == .new && Swift.abs(l.alpha - 1.0) < 1e-9 && l.quad == corners(fullRect) && l.uv == corners(fullRect)
}

private func coversAtEnd(_ layers: [Layer]) -> Bool { layers.contains(where: covers) }

private func pres(_ n: Int) -> Presentation {
    var p = Presentation.default
    p.slides = (0 ..< n).map { i in
        var s = Slide.default
        s.id = SlideId(1000 + UInt32(i))
        return s
    }
    return p
}

private func textBody(_ s: String) -> TextBody { TextBody.fromText(s) }

private func solid(_ s: Shape, _ r: UInt8) -> Shape {
    var o = s
    o.fill = Fill.solid(ColorRef.rgb(Rgba(r: r, g: 0, b: 0, a: 255)))
    return o
}

private func tr(_ kind: String, _ option: String) -> Transition {
    var t = Transition.default
    t.kind = kind
    t.option = option
    return t
}

@Suite struct TimelineTests {
    @Test func defaultStateIsIdentity() {
        let s = AnimState()
        #expect(s.visible && s.opacity == 1.0 && s.scaleX == 1.0 && s.scaleY == 1.0)
        #expect(s.isIdentity)
    }

    @Test func onClickStartsSteps() {
        let tl = Timeline(
            slideWith([
                anim(1, .entrance, "fade", .onClick), anim(2, .entrance, "fade", .onClick), anim(3, .entrance, "fade", .onClick),
            ]),
            W, H
        )
        #expect(tl.steps == 3)
        #expect(!tl.stepIsAuto(0))
        #expect(Swift.abs(tl.stepDuration(1) - 1.0) < 1e-9)
    }

    @Test func withPreviousJoinsStep() {
        let tl = Timeline(slideWith([anim(1, .entrance, "fade", .onClick), anim(2, .entrance, "fade", .withPrevious)]), W, H)
        #expect(tl.steps == 1)
        let e = tl.effects
        #expect(e[1].step == 0)
        #expect(e[1].start == 0.0)
        #expect(Swift.abs(tl.stepDuration(0) - 1.0) < 1e-9)
    }

    @Test func afterPreviousChains() {
        let tl = Timeline(
            slideWith([
                anim(1, .entrance, "fade", .onClick), anim(2, .entrance, "fade", .afterPrevious), anim(3, .entrance, "fade", .afterPrevious),
            ]),
            W, H
        )
        #expect(tl.steps == 1)
        let e = tl.effects
        #expect(Swift.abs(e[1].start - 1.0) < 1e-9)
        #expect(Swift.abs(e[2].start - 2.0) < 1e-9)
        #expect(Swift.abs(tl.stepDuration(0) - 3.0) < 1e-9)
    }

    @Test func delaysShiftStart() {
        var a = anim(2, .entrance, "fade", .withPrevious)
        a.delayMs = 250
        var b = anim(3, .entrance, "fade", .afterPrevious)
        b.delayMs = 500
        let tl = Timeline(slideWith([anim(1, .entrance, "fade", .onClick), a, b]), W, H)
        let e = tl.effects
        #expect(Swift.abs(e[1].start - 0.25) < 1e-9)
        // After previous: after the latest end (1.25) plus its delay.
        #expect(Swift.abs(e[2].start - 1.75) < 1e-9)
        #expect(Swift.abs(tl.stepDuration(0) - 2.75) < 1e-9)
    }

    @Test func autoFirstStep() {
        let tl = Timeline(slideWith([anim(1, .entrance, "fade", .afterPrevious), anim(2, .entrance, "fade", .onClick)]), W, H)
        #expect(tl.steps == 2)
        #expect(tl.stepIsAuto(0))
        #expect(!tl.stepIsAuto(1))
    }

    @Test func hiddenBeforeEntrance() {
        let tl = Timeline(slideWith([anim(1, .entrance, "fade", .onClick)]), W, H)
        #expect(!tl.state(ShapeId(1), nil, 0, 0.0).visible)
        let mid = tl.state(ShapeId(1), nil, 0, 0.5)
        #expect(mid.visible && mid.opacity > 0.0 && mid.opacity < 1.0)
        let done = tl.state(ShapeId(1), nil, 1, 0.0)
        #expect(done.visible && Swift.abs(done.opacity - 1.0) < 1e-9)
        // Unanimated shapes are untouched.
        #expect(tl.state(ShapeId(2), nil, 0, 0.0).isIdentity)
    }

    @Test func hiddenAfterExit() {
        let tl = Timeline(slideWith([anim(1, .exit, "fadeOut", .onClick)]), W, H)
        #expect(tl.state(ShapeId(1), nil, 0, 0.0).visible)
        let mid = tl.state(ShapeId(1), nil, 0, 0.5)
        #expect(mid.visible && mid.opacity < 1.0)
        #expect(!tl.state(ShapeId(1), nil, 1, 0.0).visible)
        #expect(!tl.state(ShapeId(1), nil, 0, 5.0).visible)
    }

    @Test func entranceThenExit() {
        let tl = Timeline(slideWith([anim(1, .entrance, "appear", .onClick), anim(1, .exit, "disappear", .onClick)]), W, H)
        #expect(!tl.state(ShapeId(1), nil, 0, 0.0).visible)
        #expect(tl.state(ShapeId(1), nil, 1, 0.0).visible)
        #expect(!tl.state(ShapeId(1), nil, 2, 0.0).visible)
    }

    @Test func emphasisReturnsOrPersists() {
        var spin = anim(1, .emphasis, "spin", .onClick)
        spin.amount = 90.0
        let tl = Timeline(slideWith([anim(2, .emphasis, "pulse", .onClick), spin]), W, H)
        let p = tl.state(ShapeId(2), nil, 0, 0.5)
        #expect(p.scaleX > 1.0)
        #expect(tl.state(ShapeId(2), nil, 1, 0.0).isIdentity)
        #expect(Swift.abs(tl.state(ShapeId(1), nil, 2, 0.0).rotate - 90.0) < 1e-9)
    }

    @Test func colorEmphasisTints() {
        var a = anim(1, .emphasis, "fillColor", .onClick)
        a.color = ColorRef.rgb(Rgba.rgb(255, 0, 0))
        let tl = Timeline(slideWith([a]), W, H)
        #expect(tl.state(ShapeId(1), nil, 1, 0.0).tint == Rgba.rgb(255, 0, 0))
    }

    @Test func everyAnimationEvaluatesFinite() {
        for info in animations {
            for o in info.options + [""] {
                var a = anim(1, info.animClass, info.id, .onClick)
                a.option = o
                let tl = Timeline(slideWith([a]), W, H)
                for (step, t) in [(0, 0.0), (0, 0.001), (0, 0.25), (0, 0.5), (0, 0.999), (0, 1.0), (0, 2.0), (1, 0.0)] {
                    let s = tl.state(ShapeId(1), nil, step, t)
                    #expect(finite(s), "\(info.id) \(o) \(step) \(t): \(s)")
                }
                let end = tl.state(ShapeId(1), nil, 1, 0.0)
                switch info.animClass {
                case .entrance: #expect(end.visible && Swift.abs(end.opacity - 1.0) < 1e-9, "\(info.id)")
                case .exit: #expect(!end.visible, "\(info.id)")
                default: break
                }
            }
        }
    }

    @Test func flyStartsOffSlide() {
        var a = anim(1, .entrance, "fly", .onClick)
        a.option = "l"
        let tl = Timeline(slideWith([a]), W, H)
        let s = tl.state(ShapeId(1), nil, 0, 1e-6)
        // Shape at x=100, w=200: must start at or beyond the left edge.
        #expect(100.0 + s.offsetX + 200.0 <= 0.01, "\(s)")
        let e = tl.state(ShapeId(1), nil, 0, 0.999_999)
        #expect(Swift.abs(e.offsetX) < 1.0)
    }

    @Test func wipeClips() throws {
        var a = anim(1, .entrance, "wipe", .onClick)
        a.option = "l"
        let tl = Timeline(slideWith([a]), W, H)
        let c = try #require(tl.state(ShapeId(1), nil, 0, 0.5).clip)
        #expect(c[0] == 0.0 && c[2] > 0.0 && c[2] < 1.0)
    }

    @Test func repeatAndAutoReverseExtendDuration() {
        var a = anim(1, .emphasis, "pulse", .onClick)
        a.repeat = 3
        a.autoReverse = true
        let tl = Timeline(slideWith([a]), W, H)
        #expect(Swift.abs(tl.stepDuration(0) - 6.0) < 1e-9)
        // Until next click: one iteration counts, keeps playing within the step.
        var b = anim(2, .emphasis, "spin", .onClick)
        b.repeat = UInt32.max
        let tl2 = Timeline(slideWith([b]), W, H)
        #expect(Swift.abs(tl2.stepDuration(0) - 1.0) < 1e-9)
        let s = tl2.state(ShapeId(2), nil, 0, 10.5)
        #expect(s.rotate > 0.0 && s.rotate < 360.0)
    }

    @Test func rewindRevertsEntrance() {
        var a = anim(1, .entrance, "fade", .onClick)
        a.rewind = true
        let tl = Timeline(slideWith([a]), W, H)
        #expect(!tl.state(ShapeId(1), nil, 1, 0.0).visible)
    }

    @Test func afterHideOnNextClick() {
        var a = anim(1, .entrance, "fade", .onClick)
        a.after = "hideOnNextClick"
        let tl = Timeline(slideWith([a, anim(2, .entrance, "fade", .onClick)]), W, H)
        #expect(tl.state(ShapeId(1), nil, 0, 5.0).visible)
        #expect(!tl.state(ShapeId(1), nil, 1, 0.0).visible)
    }

    @Test func triggeredSequences() {
        var a = anim(1, .entrance, "fade", .onClick)
        a.trigger = ShapeId(3)
        let tl = Timeline(slideWith([anim(2, .entrance, "fade", .onClick), a]), W, H)
        #expect(tl.steps == 1)
        #expect(tl.triggerShapes == [ShapeId(3)])
        #expect(tl.triggerSteps(ShapeId(3)) == 1)
        // Not played: hidden even after the main sequence.
        #expect(!tl.state(ShapeId(1), nil, 1, 0.0).visible)
        let tp = [TriggerPlay(trigger: ShapeId(3), step: 1, t: 0.0)]
        #expect(tl.stateWith(ShapeId(1), nil, 0, 0.0, tp).visible)
    }

    @Test func textBuildByParagraph() {
        var s = slideWith([])
        s.shapes[0].text = textBody("one\ntwo\nthree")
        var a = anim(1, .entrance, "fade", .onClick)
        a.textBuild = .byParagraph
        s.animations = [a]
        let tl = Timeline(s, W, H)
        let n = tl.paragraphTargets(ShapeId(1)).count
        #expect(n == 3)
        // On click: one click per paragraph.
        #expect(tl.steps == n)
        if n >= 2 {
            #expect(tl.state(ShapeId(1), 0, 1, 0.0).visible)
            #expect(!tl.state(ShapeId(1), 1, 1, 0.0).visible)
        }
        // With previous: staggered within one step.
        a.start = .withPrevious
        s.animations = [a]
        let tl2 = Timeline(s, W, H)
        #expect(tl2.steps == 1)
        let e = tl2.effects
        if e.count >= 2 { #expect(Swift.abs(e[1].start - e[0].start - 0.5) < 1e-9) }
        // The shape itself isn't hidden.
        #expect(tl2.state(ShapeId(1), nil, 0, 0.0).visible)
    }

    @Test func byParagraphGroupsSubBulletsWithTheirParent() {
        var s = slideWith([])
        var body = textBody("one\nsub a\nsub b\ntwo")
        body.paragraphs[1].level = 1
        body.paragraphs[2].level = 1
        s.shapes[0].text = body
        var a = anim(1, .entrance, "fade", .onClick)
        a.textBuild = .byParagraph
        s.animations = [a]
        let tl = Timeline(s, W, H)
        #expect(tl.steps == 2)
        #expect(tl.paragraphTargets(ShapeId(1)) == [0, 1, 2, 3])
        #expect(tl.state(ShapeId(1), 2, 1, 0.0).visible)
        #expect(!tl.state(ShapeId(1), 3, 1, 0.0).visible)
        #expect(!tl.state(ShapeId(1), 1, 0, 0.0).visible)
    }

    @Test func hostileTimesAndDurations() {
        var a = anim(1, .entrance, "fly", .onClick)
        a.durationMs = UInt32.max
        a.delayMs = UInt32.max
        a.repeat = UInt32.max - 1
        a.smoothStart = .nan
        a.smoothEnd = -5.0
        a.bounceEnd = .infinity
        a.amount = .nan
        var b = anim(2, .emphasis, "growShrink", .afterPrevious)
        b.amount = 1e300
        b.durationMs = 0
        let tl = Timeline(slideWith([a, b, anim(99, .path, "customPath", .onClick)]), .nan, -1.0)
        for t in [Double.nan, .infinity, -.infinity, -1.0, 0.0, 1e12, 1e300] {
            for step in [0, 1, 2, 3, Int.max] {
                for id in [UInt32(1), 2, 99] {
                    #expect(finite(tl.state(ShapeId(id), nil, step, t)))
                    #expect(finite(tl.state(ShapeId(id), Int.max, step, t)))
                }
            }
            _ = tl.locate(t)
            _ = tl.stateAt(ShapeId(1), nil, t)
        }
        #expect(tl.stepDuration(Int.max) == 0.0)
    }

    @Test func emptySlide() {
        let tl = Timeline(Slide.default, W, H)
        #expect(tl.steps == 0)
        #expect(tl.isEmpty)
        #expect(tl.state(ShapeId(1), nil, 0, 1.0).isIdentity)
        #expect(tl.locate(5.0) == (0, 0.0))
    }

    @Test func startOfSeeksThePlayAllClockToAnEffect() throws {
        var late = anim(4, .entrance, "fade", .withPrevious)
        late.delayMs = 250
        var triggered = anim(4, .emphasis, "pulse", .onClick)
        triggered.trigger = ShapeId(1)
        let tl = Timeline(
            slideWith([
                anim(1, .entrance, "fade", .onClick), anim(2, .exit, "fadeOut", .onClick), anim(3, .entrance, "fade", .onClick), late,
                triggered,
            ]),
            W, H
        )
        #expect(tl.startOf(0) == 0.0)
        #expect(tl.startOf(2) == 2.0)
        #expect(tl.startOf(3) == 2.25)
        #expect(tl.startOf(4) == nil, "a triggered effect is not on the play-all clock")
        #expect(tl.startOf(9) == nil)
        // Playing from the third effect: what came before has played, the rest has not.
        let at = try #require(tl.startOf(2))
        #expect(tl.stateAt(ShapeId(1), nil, at).visible, "entered before")
        #expect(!tl.stateAt(ShapeId(2), nil, at).visible, "exited before")
        #expect(!tl.stateAt(ShapeId(3), nil, at).visible, "not entered yet")
        #expect(!tl.stateAt(ShapeId(4), nil, at).visible, "not entered yet")
    }

    @Test func locatePlayAllClock() {
        let tl = Timeline(slideWith([anim(1, .entrance, "fade", .onClick), anim(2, .entrance, "fade", .onClick)]), W, H)
        #expect(tl.locate(0.5) == (0, 0.5))
        #expect(tl.locate(1.5) == (1, 0.5))
        #expect(tl.locate(9.0) == (2, 0.0))
        #expect(Swift.abs(tl.totalDuration - 2.0) < 1e-9)
    }

    @Test func motionPathParseAndEval() {
        let p = MotionPath.parse("M 0 0 L 0.25 0 L 0.25 0.25 E")
        #expect(Swift.abs(p.length - 0.5) < 1e-9)
        let (x, y) = p.at(0.5)
        #expect(Swift.abs(x - 0.25) < 1e-9 && Swift.abs(y) < 1e-9)
        let (x1, y1) = p.at(1.0)
        #expect(Swift.abs(x1 - 0.25) < 1e-9 && Swift.abs(y1 - 0.25) < 1e-9)
        // Relative commands and curves.
        let q = MotionPath.parse("m 0 0 l 0.1 0 c 0 0.1 0 0.1 0 0.2 z")
        #expect(q.length > 0.0)
        let c = MotionPath.parse("M0,0C0.1,0,0.2,0.1,0.2,0.2E")
        #expect(c.points.count > 2)
        let e = MotionPath.parse("M 0 0 L 1e-1 -2.5E-1 E")
        let (x2, y2) = e.at(1.0)
        #expect(Swift.abs(x2 - 0.1) < 1e-9 && Swift.abs(y2 + 0.25) < 1e-9)
    }

    @Test func malformedPathsDontTrap() {
        for s in [
            "", "E", "M", "M 0", "L 1 1", "C 1 2 3", "M 0 0 L x y", "M NaN 1 L inf 2", "M 1e400 0 L 0 0", "Z Z Z", "M 0 0 Q", "--..ee",
            "M 0 0 H 1 V 1 h -1 v -1", "😀 M 1 1", "M 0 0 L 0.5 0.5 X 9 9",
        ] {
            let p = MotionPath.parse(s)
            for t in [Double.nan, -1.0, 0.0, 0.5, 1.0, 2.0] {
                let (x, y) = p.at(t)
                #expect(x.isFinite && y.isFinite, "\(s)")
            }
        }
        let big = String(repeating: "L 1 1 ", count: 50_000)
        let p = MotionPath.parse(big)
        #expect(p.points.count <= 20_000)
    }

    @Test func presetPathsMove() {
        for info in animations where info.animClass == .path && info.id != "customPath" {
            for o in info.options + [""] {
                let p = MotionPath.parse(defaultPath(info.id, o))
                #expect(p.length > 0.0, "\(info.id) \(o)")
            }
        }
        var a = anim(1, .path, "lines", .onClick)
        a.option = "right"
        let tl = Timeline(slideWith([a]), W, H)
        let s = tl.state(ShapeId(1), nil, 1, 0.0)
        #expect(Swift.abs(s.offsetX - 0.25 * W) < 1e-6 && Swift.abs(s.offsetY) < 1e-6)
    }

    @Test func customPathOffsetsInPoints() {
        var a = anim(1, .path, "customPath", .onClick)
        a.path = "M 0 0 L 0.5 0.5 E"
        let tl = Timeline(slideWith([a]), W, H)
        let s = tl.state(ShapeId(1), nil, 1, 0.0)
        #expect(Swift.abs(s.offsetX - 480.0) < 1e-6 && Swift.abs(s.offsetY - 270.0) < 1e-6)
    }

    @Test func easingEndpoints() {
        for (a, d, b) in [(0.0, 0.0, 0.0), (0.5, 0.5, 0.0), (0.3, 0.0, 0.0), (0.0, 0.7, 0.0), (0.9, 0.9, 0.0), (0.0, 0.0, 0.3)] {
            #expect(Swift.abs(ease(0.0, a, d, b)) < 1e-9, "\(a) \(d) \(b)")
            #expect(Swift.abs(ease(1.0, a, d, b) - 1.0) < 1e-9, "\(a) \(d) \(b)")
            #expect(ease(0.5, a, d, b).isFinite)
        }
        #expect(ease(.nan, .nan, .nan, .nan).isFinite)
    }

    @Test func composeAndSanitize() {
        let a = AnimState(opacity: 0.5, clip: SIMD4(0.0, 0.0, 0.5, 1.0))
        let b = AnimState(opacity: 0.5, offsetX: 3.0, clip: SIMD4(0.25, 0.0, 1.0, 1.0))
        let c = a.compose(b)
        #expect(Swift.abs(c.opacity - 0.25) < 1e-9 && c.offsetX == 3.0 && c.clip == SIMD4(0.25, 0.0, 0.5, 1.0))
        let bad = AnimState(opacity: .nan, rotate: .infinity, clip: SIMD4(.nan, 2.0, -1.0, 0.5)).sanitized()
        #expect(finite(bad))
    }

    /// #147: exits PowerPoint plays downward leave downward here too.
    @Test func sinkDownAndPeekOutToBottomMoveDown() {
        for (effect, option) in [("sinkDown", ""), ("peekOut", "b"), ("floatOut", "d")] {
            var a = anim(1, .exit, effect, .onClick)
            a.option = option
            let tl = Timeline(slideWith([a]), W, H)
            let s = tl.state(ShapeId(1), nil, 0, 0.5)
            #expect(s.offsetY > 0.0, "\(effect) \(option): \(s)")
        }
    }

    @Test func triggerSequencesKeepFirstAppearanceOrderWhenInterleaved() {
        var anims: [Animation] = []
        for (i, tr) in [UInt32(7), 5, 7, 0, 9, 5].enumerated() {
            var a = anim(1 + UInt32(i) % 4, .entrance, "fade", .onClick)
            a.trigger = tr != 0 ? ShapeId(tr) : nil
            anims.append(a)
        }
        let tl = Timeline(slideWith(anims), W, H)
        #expect(tl.triggerShapes == [ShapeId(7), ShapeId(5), ShapeId(9)])
        #expect(tl.triggerSteps(ShapeId(7)) == 2)
        #expect(tl.triggerSteps(ShapeId(5)) == 2)
        #expect(tl.triggerSteps(ShapeId(9)) == 1)
        #expect(tl.steps == 1)
    }

    @Test func manyDistinctTriggersPastTheEffectCapBuildInOrder() {
        // One sequence per animation: grouping used to rescan every animation per trigger (~1.2e10 steps
        // here), now it is one pass, and nothing past the cap is looked at.
        let n: UInt32 = 110_000
        let anims: [Animation] = (0 ..< n).map { i in
            var a = anim(1, .entrance, "appear", .onClick)
            a.trigger = ShapeId(1000 + i)
            return a
        }
        let tl = Timeline(slideWith(anims), W, H)
        #expect(tl.effects.count == 100_000)
        let shapes = tl.triggerShapes
        #expect(shapes.count == 100_000)
        #expect(shapes.enumerated().allSatisfy { $0.element == ShapeId(1000 + UInt32($0.offset)) })
    }

    @Test func mediaInTheClickSequenceCuesAndDoesNotHoldTheClick() {
        // #116: a video set to play in the click sequence starts with its step, and the step doesn't last as
        // long as the video (the next click goes on while it plays).
        var play = anim(1, .media, "play", .onClick)
        play.durationMs = 5000
        let tl = Timeline(slideWith([play, anim(2, .exit, "fadeOut", .onClick)]), W, H)
        #expect(tl.steps == 2)
        #expect(tl.stepDuration(0) == 0.0)
        let cues = tl.mediaCues(0, -.infinity, 0.0)
        #expect(cues.map(\.shape) == [ShapeId(1)] && cues.map(\.anim) == [0])
        #expect(tl.mediaCues(0, 0.0, .infinity).isEmpty, "set off once")
        #expect(tl.mediaCues(1, -.infinity, .infinity).isEmpty, "only media effects")
        // An After Previous effect still waits for the video.
        let tl2 = Timeline(slideWith([play, anim(2, .entrance, "fade", .afterPrevious)]), W, H)
        #expect(Swift.abs(tl2.stepDuration(0) - 6.0) < 1e-9, "\(tl2.stepDuration(0))")
    }

    @Test func timelineTargetsTheFirstShapeWithADuplicateId() {
        var s = slideWith([anim(7, .entrance, "fade", .onClick)])
        s.shapes[0] = shape(7, "first")
        s.shapes[1] = shape(7, "second")
        s.shapes[0].xfrm = Xfrm(10.0, 10.0, 20.0, 20.0)
        let tl = Timeline(s, W, H)
        #expect(tl.effects.count == 1)
        #expect(tl.steps == 1)
    }

    @Test func manyByParagraphAnimationsOnOneShapeShareParagraphTargets() {
        var s = slideWith([])
        s.shapes[0].text = textBody("one\ntwo\nthree")
        s.animations = (0 ..< 2_000).map { _ in
            var a = anim(1, .path, "customPath", .onClick)
            a.textBuild = .byParagraph
            a.path = "M 0 0 L 0.5 0.5 E"
            return a
        }
        let tl = Timeline(s, W, H)
        #expect(tl.effects.count == 6_000)
        #expect(tl.paragraphTargets(ShapeId(1)) == [0, 1, 2])
    }
}

@Suite struct TransitionLayerTests {
    @Test func everyTransitionFiniteAndComplete() {
        for info in transitions {
            for o in info.options + [""] {
                for t in [0.0, 0.01, 0.25, 0.5, 0.75, 0.99, 1.0] {
                    let ls = transitionLayers(info.id, o, t)
                    #expect(!ls.isEmpty, "\(info.id) \(o) \(t)")
                    #expect(ls.count < 5000, "\(info.id) \(o) \(t)")
                    for l in ls {
                        #expect(l.alpha.isFinite && (0.0 ... 1.0).contains(l.alpha))
                        #expect((l.quad.corners + l.uv.corners).allSatisfy { $0[0].isFinite && $0[1].isFinite })
                        #expect((0 ..< 4).allSatisfy { l.src[$0].isFinite })
                    }
                }
                #expect(coversAtEnd(transitionLayers(info.id, o, 1.0)), "\(info.id) \(o)")
                let start = transitionLayers(info.id, o, 0.0)
                #expect(start.contains { $0.source == .old && $0.alpha == 1.0 }, "\(info.id) \(o)")
            }
        }
    }

    @Test func transitionsHostileT() {
        for info in transitions {
            for t in [Double.nan, .infinity, -.infinity, -5.0, 1e12] {
                #expect(!transitionLayers(info.id, "bogus-option", t).isEmpty)
            }
        }
        #expect(!transitionLayers("no-such-kind", "", 0.5).isEmpty)
    }

    @Test func fadeAndPushShapes() throws {
        let ls = transitionLayers("fade", "smoothly", 0.5)
        #expect(ls.count == 2)
        #expect(ls[1].source == .new)
        #expect(Swift.abs(ls[1].alpha - 0.5) < 1e-9)
        let push = transitionLayers("push", "l", 0.5)
        let new = try #require(push.first { $0.source == .new })
        // Pushing left: the new slide comes from the right.
        #expect(new.quad[0][0] > 0.0)
        let fb = transitionLayers("fade", "throughBlack", 0.25)
        #expect(fb.allSatisfy { $0.source != .new })
    }

    @Test func midTransitionsMixSources() {
        // Most transitions show something of both slides (or black/white) midway.
        for info in transitions where !["none", "cut", "flip"].contains(info.id) {
            let ls = transitionLayers(info.id, "", 0.5)
            #expect(ls.contains { $0.source != .new } || ls.count > 1, "\(info.id)")
        }
    }

    @Test func randomIsDeterministic() {
        #expect(transitionLayers("random", "x", 0.4) == transitionLayers("random", "x", 0.4))
        #expect(transitionLayers("dissolve", "", 0.4) == transitionLayers("dissolve", "", 0.4))
    }

    /// #420: late in the Honeycomb every cell has settled, so the incoming hexagons must cover the whole
    /// slide — the old row count stopped at ~75% of a 16:9 slide and left the bottom black.
    @Test func honeycombCellsReachTheBottomBeforeTheSlideEnds() {
        func sign(_ a: P, _ b: P, _ c: P) -> Double { (a[0] - c[0]) * (b[1] - c[1]) - (b[0] - c[0]) * (a[1] - c[1]) }
        func inside(_ p: P, _ t0: [P]) -> Bool {
            // The dark seams between cells are the effect: at t=0.99 they are ~0.012% of the width open, so a
            // 1% pad forgives them and still fails genuinely uncovered ground.
            let c = P((t0[0][0] + t0[1][0] + t0[2][0]) / 3.0, (t0[0][1] + t0[1][1] + t0[2][1]) / 3.0)
            let t = t0.map { v in P(c[0] + (v[0] - c[0]) * 1.01, c[1] + (v[1] - c[1]) * 1.01) }
            let (d1, d2, d3) = (sign(p, t[0], t[1]), sign(p, t[1], t[2]), sign(p, t[2], t[0]))
            return !((d1 < 0.0 || d2 < 0.0 || d3 < 0.0) && (d1 > 0.0 || d2 > 0.0 || d3 > 0.0))
        }
        for aspect in [16.0 / 9.0, 3.0 / 2.0, 4.0 / 3.0, 11.0 / 8.5, 1.0] {
            // t = 0.99: every cell is settled and the seams are nearly closed.
            let ls = transitionFrame("honeycomb", "", 0.99, aspect)
            let tris = ls.filter { $0.source == .new && $0.alpha >= 1.0 }.map { [$0.quad[0], $0.quad[1], $0.quad[2]] }
            #expect(!tris.isEmpty)
            var sy = 0.0
            var uncovered: [String] = []
            while sy <= 1.0 {
                for sx in [0.0, 0.2, 0.4, 0.6, 0.8, 0.99, 1.0] where !tris.contains(where: { inside(P(sx, sy), $0) }) {
                    uncovered.append("\(sx),\(sy)")
                }
                sy += 0.02
            }
            #expect(uncovered.isEmpty, "honeycomb aspect \(aspect) t=0.99: \(uncovered) uncovered")
        }
    }
}

@Suite struct MorphTests {
    @Test func morphPairsByNameTextAndGeometry() {
        var a = Slide.default
        var b = Slide.default
        a.shapes = [shape(1, "!!Logo"), shape(2, "Title 1"), shape(3, "x"), shape(4, "Rect A")]
        b.shapes = [shape(14, "Rect B"), shape(13, "y"), shape(12, "Title 1"), shape(11, "!!Logo")]
        a.shapes[2].text = textBody("Hello")
        b.shapes[1].text = textBody("Hello")
        let p = morphPairs(a, b)
        #expect(p.contains { $0 == (ShapeId(1), ShapeId(11)) })
        #expect(p.contains { $0 == (ShapeId(2), ShapeId(12)) })
        #expect(p.contains { $0 == (ShapeId(3), ShapeId(13)) })
        #expect(p.contains { $0 == (ShapeId(4), ShapeId(14)) })
        #expect(p.count == 4)
        #expect(morphPairs(Slide.default, b).isEmpty)
    }

    @Test func morphPairsLeavesUnrelatedTextBoxesAlone() {
        // A text box that leaves and an unrelated one that arrives fade in place (#119).
        let p = newPresentation(nil)
        var a = Slide.default
        var b = Slide.default
        func tb(_ id: UInt32, _ name: String, _ x: Double, _ text: String) -> Shape {
            var s = shape(id, name)
            s.xfrm = Xfrm(x, 100.0, 200.0, 100.0)
            s.text = textBody(text)
            return s
        }
        a.shapes = [tb(1, "TextBox 1", 0.0, "Gone")]
        b.shapes = [tb(2, "TextBox 2", 400.0, "New")]
        #expect(morphPairs(a, b).isEmpty)
        let f = morphFrame(p, a, b, 0.5) { _ in false }
        #expect(f.shapes.map(\.0.name) == ["TextBox 1", "TextBox 2"])
        #expect(f.shapes.map { $0.0.xfrm?.x ?? .nan } == [0.0, 400.0])
        // Empty shapes of one kind and geometry still pair, and a named text box keeps its partner.
        a.shapes.append(shape(3, "Rect A"))
        b.shapes.append(shape(4, "Rect B"))
        b.shapes[0].name = "TextBox 1"
        let pairs = morphPairs(a, b)
        #expect(pairs.map(\.0) == [ShapeId(1), ShapeId(3)] && pairs.map(\.1) == [ShapeId(2), ShapeId(4)])
    }

    @Test func morphCropMovesTheImageLinearly() {
        func bx(_ x: Double, _ w: Double) -> Xfrm { Xfrm(x, 0.0, w, 100.0) }
        func near(_ c: [Double], _ want: [Double]) -> Bool { zip(c, want).allSatisfy { Swift.abs($0 - $1) < 1e-9 } }
        // Same box, the crop pans from the left half to the right half of a 200-wide image.
        let c1 = morphCrop([0.0, 0.0, 0.5, 0.0], bx(0.0, 100.0), [0.5, 0.0, 0.0, 0.0], bx(0.0, 100.0), bx(0.0, 100.0), 0.5)
        #expect(near(c1, [0.25, 0.0, 0.25, 0.0]), "\(c1)")
        // The box shrinks over an image that stays put: only the right crop grows.
        let c2 = morphCrop([0.0, 0.0, 0.0, 0.0], bx(0.0, 100.0), [0.0, 0.0, 0.5, 0.0], bx(0.0, 50.0), bx(0.0, 75.0), 0.5)
        #expect(near(c2, [0.0, 0.0, 0.25, 0.0]), "\(c2)")
        // Nothing visible on one side: the crops blend.
        let c3 = morphCrop([0.5, 0.0, 0.5, 0.0], bx(0.0, 100.0), [0.0, 0.0, 0.0, 0.0], bx(0.0, 100.0), bx(0.0, 100.0), 0.5)
        #expect(c3.allSatisfy(\.isFinite) && Swift.abs(c3[0] - 0.25) < 1e-9, "\(c3)")
    }

    @Test func morphFrameMorphsAPictureCrop() throws {
        // A picture recropped on the next slide stays one picture whose crop morphs (#118).
        let p = newPresentation(nil)
        func pic(_ id: UInt32, _ crop: [Double]) -> Shape {
            var s = shape(id, "Picture 1")
            s.kind = .picture(fill: PictureFill(crop: crop))
            return s
        }
        var a = Slide.default
        var b = Slide.default
        a.shapes = [pic(1, [0.0, 0.0, 0.5, 0.0])]
        b.shapes = [pic(2, [0.5, 0.0, 0.0, 0.0])]
        let f = morphFrame(p, a, b, 0.5) { _ in false }
        #expect(f.shapes.count == 1)
        #expect(f.opacity.isEmpty)
        guard case .picture(let fill)? = f.shapes.first?.0.kind else {
            Issue.record("not a picture")
            return
        }
        let want = 0.5 * f.mix
        #expect(Swift.abs(fill.crop[0] - want) < 1e-9 && Swift.abs(fill.crop[2] - (0.5 - want)) < 1e-9, "\(fill.crop)")
        let end = morphFrame(p, a, b, 1.0) { _ in false }
        #expect(end.shapes.first?.0.kind == b.shapes[0].kind)
    }

    @Test func morphXfrmInterpolates() {
        var a = Xfrm(0.0, 0.0, 100.0, 100.0)
        a.rot = 350.0
        var b = Xfrm(100.0, 50.0, 200.0, 100.0)
        b.rot = 10.0
        let m = morphXfrm(a, b, 0.5)
        #expect(Swift.abs(m.x - 50.0) < 1e-9 && Swift.abs(m.w - 150.0) < 1e-9)
        #expect(Swift.abs(m.rot) < 1e-9 || Swift.abs(m.rot - 360.0) < 1e-9, "\(m.rot)")
        #expect(morphXfrm(a, b, 1.0) == b)
        #expect(morphXfrm(a, b, .nan) == a)
        var n = Xfrm()
        n.x = .nan
        n.rot = .infinity
        #expect(morphXfrm(n, b, 0.3).rot.isFinite)
    }

    @Test func morphFrameMovesBlendsAndFades() throws {
        let p = newPresentation(nil)
        var a = Slide.default
        var b = Slide.default
        func moved(_ id: UInt32, _ x: Double) -> Shape {
            var s = shape(id, "Box")
            s.xfrm = Xfrm(x, 100.0, 200.0, 100.0)
            return s
        }
        a.shapes = [solid(moved(1, 0.0), 0), shape(2, "Gone")]
        var new = shape(3, "New")
        new.text = textBody("Hi")
        b.shapes = [solid(moved(1, 400.0), 200), new, shape(4, "Later")]
        let f = morphFrame(p, a, b, 0.5) { $0 == ShapeId(4) }
        #expect(Swift.abs(f.mix - 0.5) < 1e-9)
        // Gone fades out, Box moves halfway and blends red, New fades in, Later stays out.
        #expect(f.shapes.map(\.0.name) == ["Gone", "Box", "New"] && f.shapes.map(\.1) == [true, false, false])
        let m = f.shapes[1].0
        #expect(Swift.abs((m.xfrm?.x ?? .nan) - 200.0) < 1e-9)
        #expect(m.fill == Fill.solid(ColorRef.rgb(Rgba(r: 100, g: 0, b: 0, a: 255))))
        #expect(f.opacityOf(m.id) == 1.0)
        #expect(Swift.abs(f.opacityOf(f.shapes[0].0.id) - 0.5) < 1e-9)
        #expect(Swift.abs(f.opacityOf(f.shapes[2].0.id) - 0.5) < 1e-9)
        // Ids are fresh and unique.
        let ids = Set(f.shapes.map(\.0.id))
        #expect(ids.count == 3)
        #expect(ids.allSatisfy { $0.rawValue > 4 })
        // At the start only the old slide shows.
        let f0 = morphFrame(p, a, b, 0.0) { $0 == ShapeId(4) }
        #expect(f0.shapes.filter { f0.opacityOf($0.0.id) > 0.0 }.allSatisfy { $0.0.name != "New" })
        #expect(morphFrame(p, a, b, .nan) { _ in false }.mix == 0.0)
    }

    @Test func morphFrameCrossFadesChangedContent() {
        let p = newPresentation(nil)
        var a = Slide.default
        var b = Slide.default
        var sa = shape(1, "T")
        sa.text = textBody("Before")
        var sb = shape(1, "T")
        sb.text = textBody("After")
        a.shapes = [sa]
        b.shapes = [sb]
        let f = morphFrame(p, a, b, 0.25) { _ in false }
        // The new text under the fading old one, both on the moving box.
        #expect(f.shapes.count == 2)
        #expect(f.shapes[0].0.text == b.shapes[0].text && !f.shapes[0].1)
        #expect(f.shapes[1].0.text == a.shapes[0].text && f.shapes[1].1)
        let s = f.mix
        #expect(Swift.abs(f.opacityOf(f.shapes[0].0.id) - s) < 1e-9)
        #expect(Swift.abs(f.opacityOf(f.shapes[1].0.id) - (1.0 - s)) < 1e-9)
    }

    @Test func morphFrameListsTextsForWordsAndCharacters() {
        let p = newPresentation(nil)
        var a = Slide.default
        var b = Slide.default
        var sa = shape(1, "T")
        sa.text = textBody("The Science")
        var sb = shape(1, "T")
        sb.text = textBody("Science rocks")
        a.shapes = [sa]
        b.shapes = [sb]
        for (option, want) in [("objects", nil), ("words", false), ("characters", true)] as [(String, Bool?)] {
            b.transition = tr("morph", option)
            let f = morphFrame(p, a, b, 0.5) { _ in false }
            #expect(f.text.first?.chars == want, "\(option)")
            if let m = f.text.first {
                #expect(m.new == f.shapes[0].0.id && m.old == f.shapes[1].0.id)
                #expect(m.from == a.shapes[0].xfrm)
            }
        }
        // Same text: one shape moves, nothing to morph.
        b.shapes[0].text = a.shapes[0].text
        #expect(morphFrame(p, a, b, 0.5) { _ in false }.text.isEmpty)
    }

    @Test func morphFrameMorphsTheOutlineOfAChangedGeometry() {
        let p = newPresentation(nil)
        var a = Slide.default
        var b = Slide.default
        func geo(_ s: Shape, _ g: String) -> Shape {
            var o = s
            o.geom = .preset(g)
            return o
        }
        a.shapes = [solid(geo(shape(1, "Form"), "ellipse"), 0)]
        var star = geo(shape(1, "Form"), "star5")
        star.xfrm = Xfrm(300.0, 100.0, 100.0, 100.0)
        b.shapes = [solid(star, 200)]
        let f = morphFrame(p, a, b, 0.5) { _ in false }
        // One shape: the new one, on the moving box, its colour blending and its outline listed to morph.
        #expect(f.shapes.count == 1)
        let (m, old) = f.shapes[0]
        #expect(!old && m.geom == b.shapes[0].geom)
        #expect(f.opacityOf(m.id) == 1.0)
        #expect(m.fill == Fill.solid(ColorRef.rgb(Rgba(r: 100, g: 0, b: 0, a: 255))))
        #expect(f.paths.count == 1)
        #expect(f.paths.first?.id == m.id)
        #expect(f.paths.first?.from == a.shapes[0].geom)
        #expect(f.paths.first?.fromBox == a.shapes[0].xfrm && f.paths.first?.toBox == b.shapes[0].xfrm)
        // Other adjust values of the same preset morph too.
        b.shapes[0].geom = .preset(name: "ellipse", adj: [1.0])
        #expect(morphFrame(p, a, b, 0.5) { _ in false }.paths.count == 1)
        // The same geometry only moves.
        b.shapes[0].geom = a.shapes[0].geom
        #expect(morphFrame(p, a, b, 0.5) { _ in false }.paths.isEmpty)
        // Another text as well: the two cross-fade as before.
        b.shapes[0].geom = .preset("star5")
        b.shapes[0].text = textBody("Star")
        let f2 = morphFrame(p, a, b, 0.5) { _ in false }
        #expect(f2.paths.isEmpty && f2.shapes.count == 2)
        // Tables and groups have no outline to morph.
        func table(_ g: String) -> Shape {
            var s = geo(shape(1, "Form"), g)
            s.kind = .table(.default)
            return s
        }
        a.shapes = [table("rect")]
        b.shapes = [table("ellipse")]
        #expect(morphFrame(p, a, b, 0.5) { _ in false }.paths.isEmpty)
    }

    /// #316: the same text in two shapes that differ otherwise (a title slide's big centred title, a content
    /// slide's title) morphs word by word with the default Objects option, instead of the old box
    /// cross-fading into the new one.
    @Test func sameTextMorphsEvenByObjects() {
        let p = newPresentation(nil)
        func titled(_ id: UInt32, _ x: Double, _ size: Double, _ text: String) -> Shape {
            var body = textBody(text)
            for i in body.paragraphs.indices {
                for r in body.paragraphs[i].runs.indices { body.paragraphs[i].runs[r].props.size = size }
            }
            var s = shape(id, "Title 1")
            s.xfrm = Xfrm(x, 100.0, 600.0, 120.0)
            s.text = body
            return s
        }
        var a = Slide.default
        var b = Slide.default
        a.shapes = [titled(1, 100.0, 60.0, "TEST")]
        b.shapes = [titled(2, 40.0, 44.0, "TEST")]
        let f = morphFrame(p, a, b, 0.5) { _ in false }
        #expect(f.text.count == 1, "the shared text morphs")
        #expect(f.text.first?.chars == false)
        // Different texts still cross-fade with the Objects option.
        b.shapes = [titled(2, 40.0, 44.0, "Other")]
        #expect(morphFrame(p, a, b, 0.5) { _ in false }.text.isEmpty)
    }
}

@Suite struct ShowTests {
    @Test func showSkipsHiddenSlides() {
        var p = pres(4)
        p.slides[1].hidden = true
        var s = ShowState(p)
        #expect(s.slide == 0)
        var a = s.next(p)
        #expect(a == .slide(2))
        a = s.prev(p)
        #expect(a == .slide(0))
        // Jumping to a hidden slide shows it; next continues after it.
        a = s.goto(p, 1)
        #expect(a == .slide(1))
        a = s.next(p)
        #expect(a == .slide(2))
        a = s.next(p)
        #expect(a == .slide(3))
        a = s.next(p)
        #expect(a == .end)
        a = s.next(p)
        #expect(a == .exit)
        a = s.goto(p, 99)
        #expect(a == .none_)
    }

    @Test func showLoops() {
        var p = pres(3)
        p.show.loopUntilEsc = true
        var s = ShowState(p)
        _ = s.next(p)
        _ = s.next(p)
        var a = s.next(p)
        #expect(a == .slide(0))
        a = s.prev(p)
        #expect(a == .slide(2))
    }

    @Test func showCustomShowAndRange() {
        var p = pres(5)
        p.customShows = [CustomShow(name: "Short", slides: [SlideId(1003), SlideId(1001)])]
        p.show.customShow = "Short"
        #expect(showOrder(p) == [3, 1])
        var s = ShowState(p)
        #expect(s.slide == 3)
        let a = s.next(p)
        #expect(a == .slide(1))
        p.show.customShow = nil
        p.show.range = Pair(2, 4)
        #expect(showOrder(p) == [1, 2, 3])
        p.show.range = Pair(0, 99)
        #expect(showOrder(p) == [0, 1, 2, 3, 4])
    }

    @Test func playingACustomShowStaysOnItsSlides() throws {
        var p = pres(5)
        p.customShows = [CustomShow(name: "Ends", slides: [SlideId(1000), SlideId(1004)])]
        #expect(p.show.customShow == nil)
        var s = try #require(ShowState.playCustom(p, "Ends"), "the show exists")
        #expect(s.customName == "Ends")
        #expect(s.slide == 0)
        #expect(s.peekNext(p) == 4)
        var a = s.next(p)
        #expect(a == .slide(4))
        a = s.next(p)
        #expect(a == .end)
        a = s.prev(p)
        #expect(a == .slide(4))
        a = s.prev(p)
        #expect(a == .slide(0))
        #expect(ShowState.playCustom(p, "Missing") == nil)
        #expect(p.show.customShow == nil, "one-shot playback does not change Set Up")

        p.slides[4].hidden = true
        let only = try #require(ShowState.playCustom(p, "Ends"), "the visible slide remains")
        #expect(only.firstIndex(p) == 0)
        #expect(only.lastIndex(p) == 0)

        var s2 = ShowState(p)
        var fresh = Slide.default
        fresh.id = SlideId(1004)
        p.slides[4] = fresh
        var j = s2.follow(p, .customShow(name: "Ends", returns: true), nil)
        #expect(j == .show(.slide(0)))
        #expect(s2.customName == "Ends")
        a = s2.next(p)
        #expect(a == .slide(4))
        j = s2.follow(p, .customShow(name: "Missing", returns: true), nil)
        #expect(j == .none_)
        #expect(s2.slide == 4, "an unknown custom show leaves the current slide")
    }

    @Test func showStepsThroughBuilds() {
        var p = pres(2)
        p.slides[0].shapes = [shape(1, "A")]
        p.slides[0].animations = [anim(1, .entrance, "fade", .onClick)]
        var s = ShowState(p)
        #expect(!s.playing)
        var a = s.next(p)
        #expect(a == .playStep(0))
        #expect(s.playing)
        a = s.stepDone(p)
        #expect(a == .finishStep(0))
        #expect(s.step == 1)
        a = s.prev(p)
        #expect(a == .stepBack(0))
        a = s.next(p)
        #expect(a == .playStep(0))
        a = s.next(p)
        #expect(a == .finishStep(0))
        a = s.next(p)
        #expect(a == .slide(1))
        // Back to a fully built previous slide.
        a = s.prev(p)
        #expect(a == .slide(0))
        #expect(s.step == 1)
    }

    @Test func showBackLeavesASlideWhoseFirstStepIsAutomatic() {
        // #844: undoing the automatic first step left the slide as before it appeared, and the show played
        // that step again at once, so Back never reached the slide before.
        for start in [AnimStart.withPrevious, .afterPrevious] {
            var p = pres(2)
            p.slides[1].shapes = [shape(1, "A"), shape(2, "B")]
            p.slides[1].animations = [anim(1, .entrance, "fade", start), anim(2, .entrance, "fade", .onClick)]
            var s = ShowState(p)
            var a = s.next(p)
            #expect(a == .slide(1))
            #expect(s.playing, "\(start)")
            // While the automatic step plays.
            a = s.prev(p)
            #expect(a == .slide(0), "\(start)")
            a = s.next(p)
            #expect(a == .slide(1))
            // Once it has played, the click step is undone first, then Back leaves the slide.
            a = s.next(p)
            #expect(a == .playStep(1))
            a = s.stepDone(p)
            #expect(a == .finishStep(1))
            a = s.prev(p)
            #expect(a == .stepBack(1), "\(start)")
            a = s.prev(p)
            #expect(a == .slide(0), "\(start)")
            #expect(s.step == 0 && !s.playing)
        }
    }

    @Test func showAutoAdvance() {
        var p = pres(2)
        var t = Transition.default
        t.advanceAfterMs = 2000
        p.slides[0].transition = t
        let s = ShowState(p)
        #expect(s.advanceAfter(p) == 2.0)
        #expect(!s.autoAdvanceDue(p, 1.0))
        #expect(s.autoAdvanceDue(p, 2.5))
        #expect(!s.autoAdvanceDue(p, .nan))
        p.show.useTimings = false
        #expect(!s.autoAdvanceDue(p, 5.0))
    }

    @Test func showEmptyAndAllHidden() {
        let p = pres(0)
        var s = ShowState(p)
        #expect(s.ended)
        let a = s.next(p)
        #expect(a == .exit)
        _ = s.prev(p)
        var p2 = pres(2)
        for i in p2.slides.indices { p2.slides[i].hidden = true }
        var s2 = ShowState(p2)
        #expect(s2.ended)
        _ = s2.next(p2)
        _ = s2.prev(p2)
    }

    @Test func showFollowsLinks() {
        var p = pres(4)
        p.slides[3].hidden = true
        var s = ShowState(p)
        func follow(_ a: Action, _ last: Int?) -> LinkJump { s.follow(p, a, last) }
        #expect(follow(.slide(slide: SlideId(1002)), nil) == .show(.slide(2)))
        #expect(follow(.previousSlide, nil) == .show(.slide(1)))
        #expect(follow(.nextSlide, nil) == .show(.slide(2)))
        // Last skips the hidden slide; a link to the hidden slide shows it.
        #expect(follow(.lastSlide, nil) == .show(.slide(2)))
        #expect(follow(.slide(slide: SlideId(1003)), nil) == .show(.slide(3)))
        #expect(follow(.firstSlide, nil) == .show(.slide(0)))
        #expect(follow(.lastViewed, 3) == .show(.slide(3)))
        #expect(s.slide == 3)
        #expect(follow(.url(url: "https://example.org"), nil) == .open("https://example.org"))
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "ms-settings:", "smb://host/share", "C:\\Windows\\calc.exe", "../notes.txt", "https:", ""] {
            #expect(follow(.url(url: bad), nil) == .none_, "\(bad) must not open")
        }
        #expect(follow(.url(url: " MAILTO:a@example.org"), nil) == .open("MAILTO:a@example.org"))
        #expect(follow(.endShow, nil) == .exit)
        #expect(follow(.slide(slide: SlideId(9)), nil) == .none_, "a link to a deleted slide does nothing")
        #expect(follow(.lastViewed, nil) == .none_)
        #expect(s.slide == 3)
    }

    /// Zoom with Return to Zoom: after the zoomed slides the show goes back to the zoom slide, fully built;
    /// without it, or after jumping elsewhere, the show carries on in order.
    @Test func showReturnsToTheZoomSlide() {
        let p = pres(6)
        func link(_ to: UInt32, _ last: UInt32?) -> Hyperlink {
            Hyperlink(
                action: .slide(slide: SlideId(1000 + to)), tooltip: "", highlightClick: false, sound: nil, stopSound: false,
                zoomReturn: last.map { SlideId(1000 + $0) }
            )
        }
        var s = ShowState(p)
        // A section zoom on slide 0 for slides 2–3.
        let j = s.followLink(p, link(2, 3), nil)
        #expect(j == .show(.slide(2)))
        var a = s.next(p)
        #expect(a == .slide(3))
        a = s.next(p)
        #expect(a == .slide(0), "back to the zoom")
        #expect(s.step == ShowState.steps(p, 0))
        a = s.next(p)
        #expect(a == .slide(1), "then on in order")
        // Without Return to Zoom the show carries on.
        var s2 = ShowState(p)
        _ = s2.followLink(p, link(4, nil), nil)
        a = s2.next(p)
        #expect(a == .slide(5))
        // Jumping elsewhere (See All Slides, a number) forgets the zoom.
        var s3 = ShowState(p)
        _ = s3.followLink(p, link(2, 2), nil)
        _ = s3.goto(p, 4)
        a = s3.next(p)
        #expect(a == .slide(5))
    }

    @Test func customShowResolvesDuplicateIdsToTheFirstSlide() {
        var p = pres(3)
        p.slides[2].id = p.slides[0].id
        p.customShows = [CustomShow(name: "Dup", slides: [p.slides[0].id, SlideId(1001), SlideId(424_242)])]
        p.show.customShow = "Dup"
        #expect(showOrder(p) == [0, 1])
    }

    @Test func customShowWithManyEntriesResolvesQuickly() {
        var p = pres(20_000)
        let ids = p.slides.map(\.id)
        p.customShows = [CustomShow(name: "All", slides: ids.reversed())]
        p.show.customShow = "All"
        let t = Date()
        let order = showOrder(p)
        #expect(order.count == 20_000)
        #expect(order.first == 19_999)
        #expect(Date().timeIntervalSince(t) < 5)
    }
}
