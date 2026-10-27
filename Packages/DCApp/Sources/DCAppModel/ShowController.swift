// DCAppModel — a running slide show without its windows: DCAnim's show state machine driven by keys, clicks
// and the clock; the transition, the zoom, See All Slides, blank screens, the pen and laser, typed slide numbers,
// the presenter timer and notes size, rehearsed timings and the media cues the steps set off. Port of `Show` in
// deckcraft `crates/ui-egui/src/show.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors);
// the drawing is the Mac app's (DCApp/Show).
import CoreGraphics
import DCAnim
import DCCore
import DCGeometry
import DCModel
import DCRender
import Foundation

/// A key the show reacts to (egui's `Key`, the ones `navigation_key` and `tool_key` match).
public enum ShowKey: Equatable, Sendable {
    case escape, minus, arrowRight, arrowDown, space, pageDown, n, enter, backspace, arrowLeft, arrowUp, pageUp, p, home, end
    case l, a, b, period, w, comma, e, g, z, t, r, openBracket, closeBracket
    case digit(Character)
    case other

    /// A key by name, as the control channel's `ui.key` and egui's `Key::from_name` spell it (`key_from`).
    public init(name: String) {
        let lower = name.lowercased()
        switch lower {
        case "escape", "esc": self = .escape
        case "minus", "-": self = .minus
        case "arrowright", "right": self = .arrowRight
        case "arrowdown", "down": self = .arrowDown
        case "arrowleft", "left": self = .arrowLeft
        case "arrowup", "up": self = .arrowUp
        case "space", " ": self = .space
        case "pagedown": self = .pageDown
        case "pageup": self = .pageUp
        case "enter", "return": self = .enter
        case "backspace": self = .backspace
        case "home": self = .home
        case "end": self = .end
        case "period", ".": self = .period
        case "comma", ",": self = .comma
        case "openbracket", "[": self = .openBracket
        case "closebracket", "]": self = .closeBracket
        case "n": self = .n
        case "p": self = .p
        case "l": self = .l
        case "a": self = .a
        case "b": self = .b
        case "w": self = .w
        case "e": self = .e
        case "g": self = .g
        case "z": self = .z
        case "t": self = .t
        case "r": self = .r
        default:
            let digits = lower.hasPrefix("num") ? String(lower.dropFirst(3)) : lower
            if digits.count == 1, let c = digits.first, c.isASCII, c.isNumber { self = .digit(c) } else { self = .other }
        }
    }
}

/// Modifier keys (`egui::Modifiers`; `command` is ⌘ on the Mac).
public struct ShowMods: Equatable, Sendable {
    public var command = false
    public var ctrl = false
    public var alt = false
    public var shift = false
    public init(command: Bool = false, ctrl: Bool = false, alt: Bool = false, shift: Bool = false) {
        self.command = command
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
    }

    /// No modifier held (`plain`).
    public var plain: Bool { !command && !ctrl && !alt && !shift }
}

/// A black or white screen (`blank`).
public enum ShowBlank: String, Equatable, Sendable {
    case black, white
}

/// A zoomed-in view of the slide: its centre (0–1) and scale (`Zoom`).
public struct ShowZoom: Equatable, Sendable {
    public var nx: Double
    public var ny: Double
    public var scale: Double

    public init(nx: Double, ny: Double, scale: Double) {
        self.nx = nx
        self.ny = ny
        self.scale = scale
    }

    /// The click-zoom at slide point (nx, ny) (`Zoom::at`).
    public static func at(_ nx: Double, _ ny: Double) -> ShowZoom {
        func unit(_ v: Double) -> Double { v.isFinite ? v.clamped(0, 1) : 0.5 }
        return ShowZoom(nx: unit(nx), ny: unit(ny), scale: ShowGeometry.zoomScale)
    }

    public var uv: CGRect { ShowGeometry.zoomUV(nx, ny, scale) }
}

/// Presenter view's elapsed time: pausing freezes the number; the show keeps playing (`PresenterTimer`).
public struct PresenterTimer: Equatable, Sendable {
    var origin: Double
    var frozen = 0.0
    public private(set) var paused = false

    public static func start(_ now: Double) -> PresenterTimer { PresenterTimer(origin: Self.finiteTime(now)) }

    public func elapsed(_ now: Double) -> Double {
        if paused { return Self.finiteSecs(frozen) }
        let dt = now - origin
        return Self.finiteSecs(frozen + (dt.isFinite && dt > 0 ? dt : 0))
    }

    public mutating func toggle(_ now: Double) {
        if paused {
            origin = Self.finiteTime(now)
            paused = false
        } else {
            frozen = elapsed(now)
            paused = true
        }
    }

    /// Zero the elapsed time. A paused timer stays paused at zero.
    public mutating func reset(_ now: Double) {
        frozen = 0
        origin = Self.finiteTime(now)
    }

    static func finiteTime(_ now: Double) -> Double { now.isFinite ? now : 0 }
    static func finiteSecs(_ n: Double) -> Double { n.isFinite && n >= 0 ? n : 0 }

    /// `hh:mm:ss`, at most 99:59:59 (`format_elapsed`).
    public static func format(_ secs: Double) -> String {
        let f = finiteSecs(secs)
        let s = Swift.min(f >= 1e15 ? UInt64.max : UInt64(f), 99 * 3600 + 59 * 60 + 59)
        return String(format: "%02llu:%02llu:%02llu", s / 3600, (s / 60) % 60, s % 60)
    }

    /// The local wall clock, `hh:mm` (`wall_clock`).
    public static func wallClock(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard let h = c.hour, let m = c.minute, (0 ..< 24).contains(h), (0 ..< 60).contains(m) else { return "--:--" }
        return String(format: "%02d:%02d", h, m)
    }
}

/// The transition being played into the current slide (`Transition`). The drawing side keeps the old slide's
/// frame in `old` and the textures it renders for this transition in `cache`.
public struct ShowTransition {
    /// The outgoing slide's frame, taken from `ShowController.frame` (#33: never the new slide's).
    public var old: AnyObject?
    /// The slide left behind (Morph pairs its shapes).
    public var from: Int?
    public var start: Double
    public var kind: String
    public var option: String
    public var dur: Double
    /// Whatever the drawing side keeps for this transition (slide parts, the Morph frame).
    public var cache: AnyObject?

    /// Progress at `now` (0...1).
    public func progress(_ now: Double) -> Double {
        let p = (now - start) / Swift.max(dur, 0.01)
        return p.isFinite ? p.clamped(0, 1) : 1
    }

    public var isMorph: Bool { kind == "morph" && from != nil }
}

/// What a frame of the show was rendered for (`Key`): an unchanged key is not rendered again.
public struct ShowFrameKey: Equatable, Sendable {
    public var slide: Int
    public var step: Int
    public var size: ShowSize
    /// The document it was rendered from (identity of the engine's `DocRef`).
    public var doc: ObjectIdentifier?
    /// Media hidden while not playing.
    public var hidden: [ShapeId]
    /// Clicks played of each triggered animation.
    public var plays: [ShowPlay]
    /// The frames animated GIFs show.
    public var gif: UInt64

    public init(slide: Int, step: Int, size: ShowSize, doc: ObjectIdentifier?, hidden: [ShapeId] = [], plays: [ShowPlay] = [], gif: UInt64 = 0) {
        self.slide = slide
        self.step = step
        self.size = size
        self.doc = doc
        self.hidden = hidden
        self.plays = plays
        self.gif = gif
    }
}

/// A pixel size.
public struct ShowSize: Equatable, Hashable, Sendable {
    public var w: Int
    public var h: Int
    public init(_ w: Int, _ h: Int) {
        self.w = w
        self.h = h
    }
}

/// How far one triggered sequence has played.
public struct ShowPlay: Equatable, Sendable {
    public var trigger: ShapeId
    public var step: Int
    public init(trigger: ShapeId, step: Int) {
        self.trigger = trigger
        self.step = step
    }
}

/// The input state a queued click belongs to (`ShowInputState`).
public struct ShowInputState: Equatable, Sendable {
    public var instance: UInt64
    public var slide: Int
    public var step: Int
    public var ended: Bool
    public var reading: Bool
    public var presenter: Bool
    public var grid: Bool
    public var pen: Bool
    public var laser: Bool
    public var blank: ShowBlank?
    public var zoom: ShowZoom?
    public var zoomArm: Bool
}

/// A running show (`Show`).
@MainActor
public final class ShowController {
    /// Monotonic identity of this show (a new show at the same slide is a new instance).
    public var instance: UInt64 = 0
    public var state: ShowState
    public var reading: Bool
    public var presenter: Bool
    /// Preview from Transitions: ends after the current slide.
    public var previewOnly = false
    /// Play every step automatically (animation preview).
    public var autoplay = false
    public var rehearse = false
    var timelineCache: (Int, Timeline)?
    public internal(set) var stepStart = 0.0
    public internal(set) var slideStart = 0.0
    public internal(set) var stepEnd = 0.0
    public var trans: ShowTransition?
    /// The frame on screen and what it shows; the drawing side stores its texture here.
    public var frame: (key: ShowFrameKey, image: AnyObject)?
    public var blank: ShowBlank?
    /// See All Slides covers the audience screen until a slide is chosen.
    public var grid = false
    /// Presenter view's own See All Slides: the audience keeps the slide.
    public var presenterGrid = false
    /// The next click on the slide zooms in there.
    public var zoomArm = false
    public var zoom: ShowZoom?
    public private(set) var pen = false
    /// A dot following the pointer that leaves no ink (⌘L).
    public private(set) var laser = false
    /// Ink in slide space (0–1), one array per stroke.
    public var strokes: [[CGPoint]] = []
    /// Digits typed for Go to Slide, shown until Enter, Esc or a short pause.
    public internal(set) var goto = ""
    var gotoAt = 0.0
    public internal(set) var started = false
    public internal(set) var showStart = 0.0
    public var timer = PresenterTimer.start(0)
    /// Speaker-notes size in presenter view, in points.
    public internal(set) var notesPx = ShowController.notesDefault
    /// Rehearsed (slide, seconds).
    public internal(set) var timings: [(Int, Double)] = []
    public var lastMove = 0.0
    /// The last trackpad flick or wheel notch, so one gesture turns one page.
    public var lastSwipe = -Double.infinity
    public var ended = false
    /// The slide whose media was last started (auto-play runs once per visit).
    public var mediaSlide: Int?
    /// The slide shown before this one (Last Slide Viewed).
    public internal(set) var lastViewed: Int?
    /// Click areas of slide `.0`: links and shapes.
    var links: (Int, Placed)?
    /// The main step whose media effects are being set off, and how far into it.
    var mediaClock: (Int, Double)?
    /// Media effects set off and not yet carried out: (shape, effect id).
    public var mediaCues: [(ShapeId, String)] = []
    /// Hidden-logic anchor: the last visible show time and the monotonic instant of that frame.
    var hiddenAnchor: (Double, Double)?

    public static let gotoHold = 3.0
    public static let gotoDigits = 4
    public static let notesDefault = 18.0
    public static let notesMin = 12.0
    public static let notesMax = 48.0
    public static let notesStep = 4.0

    /// A show at slide `from` (`Show::new`); an out-of-range slide starts an ended show.
    public init(_ doc: Presentation, from: Int, reading: Bool, presenter: Bool) {
        state = ShowState.startAt(doc, from)
        self.reading = reading
        self.presenter = presenter
    }

    public var inputState: ShowInputState {
        ShowInputState(
            instance: instance, slide: state.slide, step: state.step, ended: ended || state.ended, reading: reading, presenter: presenter,
            grid: grid, pen: pen, laser: laser, blank: blank, zoom: zoom, zoomArm: zoomArm
        )
    }

    // MARK: Clocks

    /// The first visible frame: every clock starts at `now` and an automatic first step plays.
    public func begin(_ doc: Presentation, _ now: Double) {
        guard !started else { return }
        started = true
        slideStart = now
        stepStart = now
        stepEnd = now
        showStart = now
        timer = PresenterTimer.start(now)
        lastMove = now
        afterEnter(doc, now)
    }

    /// The show time for a pass with no visible frame: the last visible time advanced by the monotonic clock
    /// (`hidden_logic_time`).
    public func hiddenLogicTime(_ visibleTime: Double, _ monotonic: Double) -> Double {
        let (base, at) = hiddenAnchor ?? (visibleTime, monotonic)
        return base + Swift.max(monotonic - at, 0)
    }

    /// A visible frame re-anchors the hidden clock (`observe_visible_frame`).
    public func observeVisibleFrame(_ visibleTime: Double, _ monotonic: Double) { hiddenAnchor = (visibleTime, monotonic) }

    /// Whether the show still has time-driven work (`hidden_time_driven`).
    public func timeDriven(_ doc: Presentation) -> Bool {
        started && !ended && (state.playing || trans != nil || autoplay || state.advanceAfter(doc) != nil)
    }

    /// Advance the clocks and automatic steps with no input (`advance_hidden`); false when a preview ends.
    public func advance(_ doc: Presentation, _ now: Double) -> Bool {
        tickTriggers(doc, now)
        expireGoto(now)
        if let tr = trans, now - tr.start >= Swift.max(tr.dur, 0.01) { trans = nil }
        var actions: [ShowAction] = []
        var keep = queueClockActions(doc, now, &actions)
        for a in actions where !apply(a, doc, now) { keep = false }
        if state.playing { cueMedia(doc, state.step, now - stepStart) }
        return keep
    }

    /// The step and auto-advance actions due at `now` (`queue_clock_actions`); false when a preview should close.
    public func queueClockActions(_ doc: Presentation, _ now: Double, _ actions: inout [ShowAction]) -> Bool {
        let (step, playing) = (state.step, state.playing)
        if playing {
            let tStep = now - stepStart
            if tStep >= timeline(doc).stepDuration(step) {
                actions.append(state.stepDone(doc))
                stepEnd = now
            }
        } else if trans == nil {
            let idle = now - Swift.max(stepEnd, slideStart)
            let nSteps = timeline(doc).steps
            let stepDue = autoplay && state.step < nSteps && idle > 0.3
            let holding = grid || presenterGrid || zoom != nil || zoomArm
            if !holding && (stepDue || (!rehearse && state.autoAdvanceDue(doc, idle) && !ended)) {
                actions.append(state.next(doc))
            } else if previewOnly && state.step >= nSteps && idle > 0.8 {
                return false
            }
        }
        return true
    }

    /// True while the pointer moved in the last 2.5 s: the toolbar, media bars and GIF buttons hide after that.
    public func pointerAwake(_ now: Double) -> Bool { now - lastMove < 2.5 }

    // MARK: Pointers

    /// Pen and laser are different pointers: turning one on puts the other away.
    public func setPen(_ on: Bool) {
        pen = on
        if on { laser = false }
    }

    public func setLaser(_ on: Bool) {
        laser = on
        if on { pen = false }
    }

    /// The arrow: no ink and no laser.
    public func arrow() {
        pen = false
        laser = false
    }

    // MARK: Timeline and navigation

    /// The current slide's timeline, built once per slide.
    public func timeline(_ doc: Presentation) -> Timeline {
        let i = state.slide
        if let (k, t) = timelineCache, k == i { return t }
        let t = ShowState.timeline(doc, i)
        timelineCache = (i, t)
        return t
    }

    /// Carry out a navigation answer (`apply`); false when the show (or a preview) should close.
    @discardableResult
    public func apply(_ a: ShowAction, _ doc: Presentation, _ now: Double) -> Bool {
        switch a {
        case .playStep(let k):
            stepStart = now
            mediaClock = (k, -Double.infinity)
        case .finishStep(let n):
            // A step cut short by a click still sets off the media it holds.
            cueMedia(doc, n, Double.infinity)
            stepEnd = now
        case .stepBack:
            mediaClock = nil
            stepEnd = now
        case .slide(let i):
            ended = false
            zoom = nil
            zoomArm = false
            if rehearse { timings.append((timelineCache?.0 ?? i, now - slideStart)) }
            let t = doc.slides.at(i)?.transition
            let (kind, option, dur) = t.map { ($0.kind, $0.option, Double($0.durationMs) / 1000) } ?? ("none", "", 0)
            // Take the old slide's frame rather than sharing it: the new slide gets a frame of its own (#33).
            let taken = frame
            frame = nil
            let from = taken?.key.slide
            if from != i { lastViewed = from }
            trans = kind != "none" && dur > 0 && !doc.show.withoutAnimation
                ? ShowTransition(old: taken?.image, from: from, start: now, kind: kind, option: option, dur: dur, cache: nil)
                : nil
            slideStart = now
            stepStart = now
            stepEnd = now
            mediaClock = nil
            strokes.removeAll()
            if previewOnly { return false }
            afterEnter(doc, now)
        case .end:
            ended = true
            if previewOnly { return false }
        case .exit:
            return false
        case .none_:
            break
        }
        return true
    }

    /// On entering a slide, start the clock of a first step that begins With/After Previous: `ShowState` has
    /// already started it (#631). Autoplay previews start an On Click first step themselves (`after_enter`).
    public func afterEnter(_ doc: Presentation, _ now: Double) {
        var started: Int?
        if state.playing {
            started = state.step
        } else if autoplay, case .playStep(let k) = state.next(doc) {
            started = k
        }
        if let k = started {
            stepStart = now
            mediaClock = (k, -Double.infinity)
        }
    }

    /// Queue the media effects (Play, Pause, Stop) of main step `step` reached since the last call, up to `t`
    /// seconds into it (`cue_media`, #116).
    public func cueMedia(_ doc: Presentation, _ step: Int, _ t: Double) {
        guard let (k, from) = mediaClock else { return }
        if k != step {
            mediaClock = nil
            return
        }
        let slide = doc.slides.at(state.slide)
        for e in timeline(doc).mediaCues(step, from, t) {
            if let a = slide?.animations.at(e.anim) { mediaCues.append((e.shape, a.effect)) }
        }
        mediaClock = t.isFinite ? (k, t) : nil
    }

    /// Advance the clocks of the running triggered animations.
    public func tickTriggers(_ doc: Presentation, _ now: Double) {
        let tl = timeline(doc)
        state.tick(tl, now)
    }

    /// The step clock: seconds into the playing step, 0 at rest.
    public func stepTime(_ now: Double) -> Double { state.playing ? now - stepStart : 0 }

    /// Something on the slide moves this frame (a main step or a triggered animation).
    public var animating: Bool { state.playing || state.triggerPlaying }

    // MARK: Keys

    /// One key in the audience window (`presenter` false) or presenter view (`keyboard`). `handled` tells whether
    /// the show took the key; `keep` is false when the show should close.
    @discardableResult
    public func key(_ k: ShowKey, _ m: ShowMods, _ doc: Presentation, _ now: Double, presenter: Bool) -> (handled: Bool, keep: Bool) {
        var keep = true
        var actions: [ShowAction] = []
        let handled: Bool
        if gridOpen(presenter) && k != .escape && k != .minus {
            // See All Slides takes no other key until a slide is chosen.
            if k == .g && m.plain {
                closeGrid(presenter)
                handled = true
            } else {
                handled = false
            }
        } else {
            handled = navigationKey(doc, k, m, presenter, &keep, &actions) || toolKey(k, m, now, presenter)
        }
        for a in actions where !apply(a, doc, now) { keep = false }
        return (handled, keep)
    }

    func gridOpen(_ presenter: Bool) -> Bool { presenter ? presenterGrid : grid }

    func closeGrid(_ presenter: Bool) {
        if presenter && presenterGrid { presenterGrid = false } else { grid = false }
    }

    /// Keys that move through the show or end it (`navigation_key`).
    func navigationKey(_ doc: Presentation, _ k: ShowKey, _ m: ShowMods, _ presenter: Bool, _ keep: inout Bool, _ actions: inout [ShowAction]) -> Bool {
        switch k {
        case .escape, .minus:
            let cancelled = k == .escape && clearGoto()
            if !cancelled && !backOut(presenter) { keep = false }
        case .arrowRight, .arrowDown, .space, .pageDown, .n:
            if ended { keep = false } else { actions.append(state.next(doc)) }
        case .enter:
            if !goto.isEmpty {
                if let i = takeGoto(), i < doc.slides.count { actions.append(state.goto(doc, i)) }
            } else if ended {
                keep = false
            } else {
                actions.append(state.next(doc))
            }
        case .backspace where !goto.isEmpty:
            goto.removeLast()
        case .arrowLeft, .arrowUp, .backspace, .pageUp:
            ended = false
            actions.append(state.prev(doc))
        case .p where m.command:
            setPen(!pen)
        case .p:
            ended = false
            actions.append(state.prev(doc))
        case .home:
            if let i = state.firstIndex(doc) { actions.append(state.goto(doc, i)) }
        case .end:
            if let i = state.lastIndex(doc) { actions.append(state.goto(doc, i)) }
        default:
            return false
        }
        return true
    }

    /// Pen, laser, blanking, zoom, the timer, note size and typed slide numbers (`tool_key`).
    func toolKey(_ k: ShowKey, _ m: ShowMods, _ now: Double, _ presenter: Bool) -> Bool {
        switch k {
        case .l where m.command: setLaser(!laser)
        case .a where m.command: arrow()
        case .b, .period: toggleBlank(.black)
        case .w, .comma: toggleBlank(.white)
        case .e: strokes.removeAll()
        case .g where m.plain: openGrid(presenter)
        case .z where m.plain: zoomKey()
        case .t where m.plain: timer.toggle(now)
        case .r where m.plain: timer.reset(now)
        case .openBracket where m.plain: nudgeNotes(-Self.notesStep)
        case .closeBracket where m.plain: nudgeNotes(Self.notesStep)
        case .digit(let d): pushSlideNumber(d, now)
        default: return false
        }
        return true
    }

    // MARK: Screens, zoom and the grid

    /// B and W: a black or white screen, or back to the slide (`toggle_blank`).
    public func toggleBlank(_ c: ShowBlank) { blank = blank == c ? nil : c }

    /// G opens See All Slides in the window it was pressed in (#1130).
    public func openGrid(_ presenter: Bool) {
        if presenter { presenterGrid = true } else { grid = true }
    }

    /// Z or the Zoom button: arm a click-to-zoom, or leave a zoom already on.
    public func zoomKey() {
        if zoom != nil || zoomArm {
            dismissZoom()
        } else {
            zoomArm = true
            pen = false
        }
    }

    /// The part of the slide on screen.
    public var zoomUV: CGRect { zoom?.uv ?? ShowGeometry.unitUV }

    /// The toolbar's Zoom button label.
    public var zoomLabel: String {
        zoom != nil ? L10n.text("Zoom on") : zoomArm ? L10n.text("Zoom…")
            : String(localized: "Zoom", bundle: .module, comment: "Zoom into part of the slide")
    }

    /// ⌘/Ctrl+wheel: `lines` notches in (positive) or out around the slide point under `p` (`wheel_zoom`).
    public func wheelZoom(_ srect: CGRect, _ p: CGPoint, _ lines: Double) {
        guard let (nx, ny) = ShowGeometry.normOnSlide(srect, zoomUV, p) else { return }
        let from = zoom?.scale ?? 1
        let scale = Swift.min(from * pow(2, lines / ShowGeometry.wheelNotchesPerDoubling), ShowGeometry.wheelZoomMax)
        guard scale.isFinite else { return }
        zoomArm = false
        if scale <= 1 + 1e-3 {
            zoom = nil
            return
        }
        // The new window keeps (nx, ny) at the same place on the screen.
        let w = 1 / scale
        let fx = Double((p.x - srect.minX) / srect.width)
        let fy = Double((p.y - srect.minY) / srect.height)
        let x = (nx - fx * w).clamped(0, 1 - w)
        let y = (ny - fy * w).clamped(0, 1 - w)
        zoom = ShowZoom(nx: x + w * 0.5, ny: y + w * 0.5, scale: scale)
    }

    /// Esc closes the grid of the window it was pressed in, then a zoom, and only then leaves (`back_out`).
    public func backOut(_ presenter: Bool) -> Bool {
        if presenter && presenterGrid {
            presenterGrid = false
            return true
        }
        if !presenter && grid {
            grid = false
            return true
        }
        return dismissZoom()
    }

    /// Leave a zoom (or an armed one); true when there was one.
    @discardableResult
    public func dismissZoom() -> Bool {
        guard zoom != nil || zoomArm else { return false }
        zoom = nil
        zoomArm = false
        return true
    }

    // MARK: Go to slide, notes

    public func pushSlideNumber(_ digit: Character, _ now: Double) {
        guard digit.isASCII, digit.isNumber, goto.count < Self.gotoDigits else { return }
        goto.append(digit)
        gotoAt = now.isFinite ? now : 0
    }

    /// The typed slide as an index, nil for 0 or nothing; the digits are cleared either way (`take_goto`).
    public func takeGoto() -> Int? {
        let raw = goto
        goto = ""
        guard let n = Int(raw), n > 0 else { return nil }
        return n - 1
    }

    public func expireGoto(_ now: Double) {
        guard !goto.isEmpty, now.isFinite, gotoAt.isFinite else { return }
        if now - gotoAt > Self.gotoHold { goto = "" }
    }

    /// Esc drops a number being typed; true when there was one.
    public func clearGoto() -> Bool {
        guard !goto.isEmpty else { return false }
        goto = ""
        return true
    }

    public func nudgeNotes(_ delta: Double) {
        let next = notesPx + delta
        if next.isFinite { notesPx = next.clamped(Self.notesMin, Self.notesMax) }
    }

    /// Keep the rehearsed time of the slide on screen when the show ends.
    public func closeTimings(_ now: Double) -> [(Int, Double)] {
        timings.append((state.slide, now - slideStart))
        return timings
    }

    // MARK: Clicks on the slide

    /// The slide's click areas, placed once per slide.
    func placed(_ doc: Presentation) -> Placed {
        let i = state.slide
        if let (s, p) = links, s == i { return p }
        let p = placeSlide(doc, i)
        links = (i, p)
        return p
    }

    /// What is under slide point (x, y) on the shown slide (`shapes_under_pointer`).
    public func under(_ doc: Presentation, _ x: Double, _ y: Double, _ now: Double) -> ShowUnder {
        let placed = placed(doc)
        let tl = timeline(doc)
        func inside(_ r: Rect) -> Bool { r.x0 <= x && x <= r.x1 && r.y0 <= y && y <= r.y1 }
        let hits = placed.shapes.map { HitShape(id: $0.id, parent: $0.parent, isGroup: $0.isGroup, link: $0.link?.action, underPointer: inside($0.rect)) }
        let (step, plays, stamps) = (state.step, state.triggerPlays, state.triggerStamps)
        let t = stepTime(now)
        let visible = placed.shapes.map { s -> Bool in
            let a = tl.stateOrdered(s.id, nil, step, t, plays, stamps)
            return a.visible && a.opacity > 0
        }
        var under = ShowUnder(shapes: hits, visible: visible, pick: nil)
        let shown = { (id: ShapeId) in under.isVisible(id) }
        let top = state.top(doc, tl, under.shapes, shown)
        // A hyperlink in text applies when its shape is the one on top.
        let text = placed.links.reversed().first { l in
            guard l.text && inside(l.rect) else { return false }
            var at = top
            for _ in 0 ... under.shapes.count {
                guard let k = at, let h = under.shapes.at(k) else { return false }
                if h.id == l.shape { return true }
                at = h.parent
            }
            return false
        }
        if let l = text {
            under.pick = .text(l.link)
        } else if state.target(doc, tl, under.shapes, shown) != nil {
            under.pick = .shape
        }
        return under
    }

    /// A click on the slide: the shape under the pointer acts, or the background advances (`click_slide`).
    public func clickSlide(_ doc: Presentation, _ under: ShowUnder, _ now: Double) -> Click {
        let tl = timeline(doc)
        return state.click(doc, tl, under.shapes, { under.isVisible($0) }, now, lastViewed)
    }

    // MARK: ui.inspect

    /// `showing_value`: what `ui.inspect` reports while a show runs.
    public func showingValue(nSlides: Int, aspect: Double, full: CGRect, now: Double) -> JSON {
        var o = JSONObject()
        o.set("slide", .integer(state.slide))
        o.set("step", .integer(state.step))
        o.set("ended", .bool(ended))
        o.set("grid", .bool(grid))
        o.set("zoomArm", .bool(zoomArm))
        o.set("blank", blank.map { .string($0.rawValue) } ?? .null)
        o.set("zoom", zoom.map { ["x": .double($0.nx), "y": .double($0.ny), "scale": .double($0.scale)] } ?? .null)
        o.set("presenterPaused", .bool(timer.paused))
        o.set("presenterSecs", .double(timer.elapsed(now)))
        o.set("notesPx", .double(notesPx))
        o.set("custom", state.customName.map(JSON.string) ?? .null)
        o.set("goto", goto.isEmpty ? .null : .string(goto))
        if grid {
            let slides = ShowGeometry.gridIndices(nSlides)
            let cells = ShowGeometry.seeAllCells(full, slides.count, aspect)
            o.set("cells", .array(zip(slides, cells).map { ["slide": .integer($0.0), "x": .double($0.1.midX), "y": .double($0.1.midY)] }))
        }
        return .object(o)
    }
}

/// What a click on the slide acts on (`Pick`).
public enum ShowPick: Equatable {
    /// A hyperlink in text.
    case text(Hyperlink)
    /// A shape with an action or a triggered animation.
    case shape
}

/// The slide's shapes at the pointer, for `ShowState.click` (`Under`).
public struct ShowUnder {
    public var shapes: [HitShape] = []
    /// Whether each of `shapes` is shown (an animation may have hidden it).
    public var visible: [Bool] = []
    public var pick: ShowPick?

    public init(shapes: [HitShape] = [], visible: [Bool] = [], pick: ShowPick? = nil) {
        self.shapes = shapes
        self.visible = visible
        self.pick = pick
    }

    public func isVisible(_ id: ShapeId) -> Bool {
        guard let i = shapes.firstIndex(where: { $0.id == id }) else { return true }
        return visible.at(i) ?? true
    }
}

/// Whether starting the show takes the whole screen: Reading View and "Browsed by an individual" stay in a
/// window (`show_fills_screen`).
public func showFillsScreen(reading: Bool, showType: String) -> Bool { !reading && showType != "browsed" }

/// A shape's animation state for the renderer (`state_for`).
public func showShapeState(_ tl: Timeline, _ id: ShapeId, _ step: Int, _ t: Double, _ plays: [TriggerPlay], _ stamps: [StepStamp]) -> ShapeState {
    let a = tl.stateOrdered(id, nil, step, t, plays, stamps)
    var s = ShapeState()
    s.visible = a.visible
    s.opacity = a.opacity
    s.offset = Vec2(a.offsetX, a.offsetY)
    s.scale = (a.scaleX, a.scaleY)
    s.rotate = a.rotate
    s.clip = a.clip.map { [$0[0], $0[1], $0[2], $0[3]] }
    s.tint = a.tint
    s.paras = tl.paragraphTargets(id).map { p in
        let pa = tl.state(id, p, step, t)
        var ps = ParaState()
        ps.visible = pa.visible
        ps.opacity = pa.opacity
        ps.offset = Vec2(pa.offsetX, pa.offsetY)
        return (p, ps)
    }
    return s
}

/// The shapes of slide `idx` to leave out when drawing what is stacked above the lowest playing video (that
/// video, everything below it and the other videos); empty when nothing is above a video (`below_playing_video`).
public func belowPlayingVideo(_ doc: Presentation, _ idx: Int, _ videos: [ShapeId]) -> [ShapeId] {
    guard let slide = doc.slides.at(idx), let first = slide.shapes.firstIndex(where: { videos.contains($0.id) }) else { return [] }
    if slide.shapes.dropFirst(first + 1).allSatisfy({ videos.contains($0.id) }) { return [] }
    return slide.shapes.enumerated().filter { $0.offset <= first || videos.contains($0.element.id) }.map(\.element.id)
}

/// Media of slide `idx` hidden until it plays, as it is when the slide is entered (`hidden_on_entry`).
public func hiddenOnEntry(_ doc: Presentation, _ idx: Int) -> [ShapeId] {
    MediaHost.slideMedia(doc, idx).filter(\.clip.hideWhileNotPlaying).map(\.id)
}
