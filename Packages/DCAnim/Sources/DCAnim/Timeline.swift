// DCAnim — a slide's animation sequence: click steps, effect start times and per-shape state over time.
// Port of deckcraft crates/anim/src/timeline.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel

/// Delay between paragraphs of a by-paragraph build that isn't on click (seconds).
let paragraphStagger = 0.5
private let maxEffects = 100_000
private let maxIterations = 1.0e6

/// Which sequence an effect belongs to (deckcraft's `Sequence`).
public enum AnimSequence: Sendable, Hashable {
    /// The slide's main click sequence.
    case main
    /// An interactive sequence started by clicking this shape.
    case trigger(ShapeId)
}

/// Timing of one (sub-)effect, for the Animation Pane timeline and the UI.
public struct EffectTiming: Sendable, Equatable {
    /// Index into `slide.animations`.
    public var anim: Int
    /// Animated shape and paragraph (nil = the whole shape).
    public var shape: ShapeId
    public var paragraph: Int?
    public var sequence: AnimSequence
    /// Click step within its sequence.
    public var step: Int
    /// Start within the step (seconds, delay included).
    public var start: Double
    /// One iteration (seconds).
    public var duration: Double
    /// Repeat count (fractional allowed); 1 = once.
    public var iterations: Double
    /// Repeats until the next click.
    public var untilNextClick: Bool
    public var autoReverse: Bool
    public var rewind: Bool
    /// Time from start to end (all iterations, reverse included; one iteration if until-click).
    public var span: Double
    public var animClass: AnimClass
}

/// Playhead of a triggered sequence: `step` clicks on the trigger fully played, the current one playing
/// for `t` seconds.
public struct TriggerPlay: Sendable, Equatable {
    public var trigger: ShapeId
    public var step: Int
    public var t: Double

    public init(trigger: ShapeId, step: Int, t: Double) {
        self.trigger = trigger
        self.step = step
        self.t = t
    }
}

/// When a step of a triggered sequence was started, counted in started steps on the slide. Effects of
/// different triggers apply in this order, so that a shape hidden by one trigger and shown again by another
/// ends up as the later of the two left it.
public struct StepStamp: Sendable, Equatable {
    public var trigger: ShapeId
    public var step: Int
    public var at: UInt64

    public init(trigger: ShapeId, step: Int, at: UInt64) {
        self.trigger = trigger
        self.step = step
        self.at = at
    }
}

private struct StepInfo: Sendable {
    var auto = false
    var duration = 0.0
}

private enum After: Sendable {
    case none_
    case hide
    case hideOnNextClick
    case dim(Rgba)
}

/// The spec is a class so every paragraph effect of one animation shares it (a large motion path is not
/// copied per paragraph), as the Rust's `Arc`.
private final class SharedSpec: Sendable {
    let spec: EffectSpec
    init(_ spec: EffectSpec) { self.spec = spec }
}

private struct Effect: Sendable {
    var timing: EffectTiming
    var spec: SharedSpec
    var after: After
}

/// A slide's animations laid out in time.
public struct Timeline: Sendable {
    private var effectList: [Effect] = []
    private var main: [StepInfo] = []
    private var triggers: [(ShapeId, [StepInfo])] = []
    /// Base fill colour per shape (for colour emphasis).
    private var colors: [(ShapeId, Rgba)] = []
    /// By-paragraph builds animate first-level paragraphs; deeper paragraphs follow their parent:
    /// (shape, member paragraph, owner paragraph).
    private var groups: [(ShapeId, Int, Int)] = []

    public init() {}

    public static var `default`: Timeline { Timeline() }
}

private enum Status {
    case notStarted
    case active(Double)
    case done
}

/// The default theme's colours (`builtin_color_schemes().first()`), built once.
private let defaultScheme: ColorScheme? = builtinColorSchemes().first

private func secs(_ ms: UInt32) -> Double { Double(ms) / 1000.0 }

private func finiteOr(_ v: Double, _ d: Double) -> Double { v.isFinite ? v : d }

private func sanitizeXfrm(_ x: Xfrm, _ sw: Double, _ sh: Double) -> Xfrm {
    var o = x
    o.x = finiteOr(x.x, 0.0).clamped(-1.0e7, 1.0e7)
    o.y = finiteOr(x.y, 0.0).clamped(-1.0e7, 1.0e7)
    o.w = finiteOr(x.w, sw / 2.0).clamped(0.0, 1.0e7)
    o.h = finiteOr(x.h, sh / 2.0).clamped(0.0, 1.0e7)
    return o
}

private struct GroupKey: Hashable {
    var shape: ShapeId
    var member: Int
    var owner: Int
}

extension Timeline {
    /// Build the timeline of `slide` (slide size in points). Placeholders without their own box get a
    /// centred default box; colours resolve against the default theme.
    public init(_ slide: Slide, _ slideW: Double, _ slideH: Double) {
        self.init(slide, slideW, slideH, scheme: nil, xfrmOf: { _ in nil })
    }

    /// Build with a colour scheme for theme colours and a lookup for shape boxes (placeholders inherit
    /// their box from the layout; the lookup wins over `shape.xfrm`).
    public init(_ slide: Slide, _ slideW: Double, _ slideH: Double, scheme schemeIn: ColorScheme?, xfrmOf: (ShapeId) -> Xfrm?) {
        self.init()
        let sw = finiteOr(slideW, 960.0).clamped(1.0, 1.0e7)
        let sh = finiteOr(slideH, 540.0).clamped(1.0, 1.0e7)
        let scheme = schemeIn ?? defaultScheme
        func resolve(_ c: ColorRef) -> Rgba {
            if let s = scheme { return c.resolve(s, nil) }
            if case .rgb(let rgb) = c.base { return rgb }
            return Rgba.rgb(0x15, 0x60, 0x82)
        }
        let accent = scheme.map { $0.get(.accent1) } ?? Rgba.rgb(0x15, 0x60, 0x82)

        if slide.animations.isEmpty { return }
        // Every shape by id, built once: resolving each animation's target by tree search would cost
        // shapes x animations.
        let shapes = shapeIndex(slide.shapes)
        // Paragraph targets of each shape, worked out for its first by-paragraph animation only.
        var paraCache: [ShapeId: [Int?]] = [:]
        // Group the animations by sequence in one pass, sequences in order of first appearance (main
        // first), so many distinct triggers cost linear work, not a scan per trigger.
        var seqs: [(AnimSequence, [Int])] = [(.main, [])]
        var seqIndex: [AnimSequence: Int] = [.main: 0]
        for (ai, a) in slide.animations.enumerated() {
            let s: AnimSequence = a.trigger.map { .trigger($0) } ?? .main
            let i: Int
            if let k = seqIndex[s] {
                i = k
            } else {
                seqs.append((s, []))
                i = seqs.count - 1
                seqIndex[s] = i
            }
            if seqs.indices.contains(i) { seqs[i].1.append(ai) }
        }
        // Paragraph groups already recorded (the list itself keeps their order).
        var grouped = Set<GroupKey>()
        for (seq, members) in seqs {
            if effectList.count >= maxEffects { break }
            var steps: [StepInfo] = []
            var groupBegin = 0.0
            var maxEnd = 0.0
            for ai in members {
                guard let a = slide.animations.at(ai) else { continue }
                if effectList.count >= maxEffects { break }
                let shape = shapes[a.shape]
                // Paragraph targets of this animation.
                let paras: [Int?]
                if let p = a.paragraph {
                    paras = [Int(p)]
                } else if a.textBuild == .byParagraph {
                    if let cached = paraCache[a.shape] {
                        paras = cached
                    } else {
                        var v: [Int?] = []
                        if let t = shape?.text {
                            for (i, role) in paragraphBuildRoles(t).enumerated() {
                                switch role {
                                case .top: v.append(i)
                                case .member(let o):
                                    if grouped.insert(GroupKey(shape: a.shape, member: i, owner: o)).inserted {
                                        groups.append((a.shape, i, o))
                                    }
                                case .unowned: break
                                }
                            }
                        }
                        if v.isEmpty { v.append(nil) }
                        paraCache[a.shape] = v
                        paras = v
                    }
                } else {
                    paras = [nil]
                }
                let xf0 = xfrmOf(a.shape) ?? shape?.xfrm ?? Xfrm(sw / 4.0, sh / 4.0, sw / 2.0, sh / 2.0)
                let xf = sanitizeXfrm(xf0, sw, sh)
                let spec = SharedSpec(buildSpec(a, xf, sw, sh, resolve))
                let dur = secs(a.durationMs)
                let delay = secs(a.delayMs)
                let untilNextClick = a.repeat == UInt32.max
                let iterations = untilNextClick || a.repeat <= 1 ? 1.0 : Double(a.repeat).rustMin(maxIterations)
                let span = dur * (a.autoReverse ? 2.0 : 1.0) * iterations
                let after: After = switch a.after {
                case "hide"?: .hide
                case "hideOnNextClick"?: .hideOnNextClick
                case let c?: Rgba.fromHex(c).map { .dim($0) } ?? .none_
                case nil: .none_
                }
                var firstStart = 0.0
                for (k, para) in paras.enumerated() {
                    var mode: AnimStart = k == 0 ? a.start : (a.start == .onClick ? .onClick : .withPrevious)
                    let firstOfSeq = steps.isEmpty
                    if firstOfSeq, case .trigger = seq { mode = .onClick }
                    switch mode {
                    case .onClick:
                        steps.append(StepInfo(auto: false, duration: 0.0))
                        groupBegin = 0.0
                        maxEnd = 0.0
                    case .withPrevious:
                        if firstOfSeq { steps.append(StepInfo(auto: true, duration: 0.0)) }
                    case .afterPrevious:
                        if firstOfSeq { steps.append(StepInfo(auto: true, duration: 0.0)) }
                        groupBegin = maxEnd
                    }
                    let start = k > 0 && a.start != .onClick ? firstStart + Double(k) * paragraphStagger : groupBegin + delay
                    if k == 0 { firstStart = start }
                    let end = start + span
                    maxEnd = maxEnd.rustMax(end)
                    let step = Swift.max(steps.count - 1, 0)
                    if !steps.isEmpty {
                        // Media plays on by itself once started: it holds back an After Previous effect
                        // (`maxEnd`), but not the next click (#116).
                        let last = steps.count - 1
                        steps[last].duration = steps[last].duration.rustMax(a.class == .media ? start : end)
                    }
                    effectList.append(Effect(
                        timing: EffectTiming(
                            anim: ai, shape: a.shape, paragraph: para, sequence: seq, step: step, start: start, duration: dur,
                            iterations: iterations, untilNextClick: untilNextClick, autoReverse: a.autoReverse, rewind: a.rewind,
                            span: span, animClass: a.class
                        ),
                        spec: spec,
                        after: after
                    ))
                }
            }
            switch seq {
            case .main: main = steps
            case .trigger(let s): triggers.append((s, steps))
            }
        }
        // Base colours of animated shapes.
        var colored = Set<ShapeId>()
        for e in effectList {
            let id = e.timing.shape
            if !colored.insert(id).inserted { continue }
            let c: Rgba = if case .solid(let color)? = shapes[id]?.fill { resolve(color) } else { accent }
            colors.append((id, c))
        }
    }

    /// Number of steps in the main sequence (clicks, plus an automatic first step when the first effect
    /// starts with/after previous).
    public var steps: Int { main.count }

    /// Does main step `i` start by itself (no click), as the slide appears?
    public func stepIsAuto(_ i: Int) -> Bool { main.at(i)?.auto ?? false }

    /// Duration of main step `i` in seconds (0 when out of range).
    public func stepDuration(_ i: Int) -> Double { main.at(i)?.duration ?? 0.0 }

    /// Media effects (Play, Pause, Stop) of main step `step` that start after `from` and by `to` seconds
    /// into it, in order: what a show running the step from `from` to `to` sets off.
    public func mediaCues(_ step: Int, _ from: Double, _ to: Double) -> [EffectTiming] {
        effectList.map(\.timing)
            .filter { $0.animClass == .media && $0.sequence == .main && $0.step == step && $0.start > from && $0.start <= to }
            .stableSorted { $0.start.totalLess($1.start) }
    }

    /// Total duration of the main sequence played without pauses.
    public var totalDuration: Double { main.reduce(-0.0) { $0 + $1.duration } }

    /// Map a time on the "play everything" clock to `(step, t)` for `state`.
    public func locate(_ time: Double) -> (Int, Double) {
        var t = finiteOr(time, 0.0).rustMax(0.0)
        for (i, s) in main.enumerated() {
            if t < s.duration || (t == 0.0 && s.duration == 0.0 && i == 0) { return (i, t) }
            t -= s.duration
        }
        return (main.count, 0.0)
    }

    /// Where effect `anim` (index into `slide.animations`) starts on the play-everything clock: Animation
    /// Pane ▸ Play From. nil for a triggered effect or one that isn't on the slide.
    public func startOf(_ anim: Int) -> Double? {
        var best: EffectTiming?
        for e in effectList.map(\.timing) where e.anim == anim && e.sequence == .main {
            guard let b = best else {
                best = e
                continue
            }
            if e.step < b.step || (e.step == b.step && e.start.totalLess(b.start)) { best = e }
        }
        guard let e = best else { return nil }
        let before = main.prefix(e.step).reduce(-0.0) { $0 + $1.duration }
        return before + e.start
    }

    /// Shapes that start an interactive sequence when clicked.
    public var triggerShapes: [ShapeId] { triggers.map(\.0) }

    /// Steps (clicks on the trigger) of a triggered sequence.
    public func triggerSteps(_ trigger: ShapeId) -> Int { triggers.first { $0.0 == trigger }?.1.count ?? 0 }

    public func triggerStepDuration(_ trigger: ShapeId, _ i: Int) -> Double {
        triggers.first { $0.0 == trigger }?.1.at(i)?.duration ?? 0.0
    }

    /// All effect timings in sequence order.
    public var effects: [EffectTiming] { effectList.map(\.timing) }

    /// Is anything animated on this slide?
    public var isEmpty: Bool { effectList.isEmpty }

    /// Paragraph indices of `shape` animated separately (by-paragraph builds).
    public func paragraphTargets(_ shape: ShapeId) -> [Int] {
        var v: [Int] = effectList.filter { $0.timing.shape == shape }.compactMap(\.timing.paragraph)
        let owned = v
        v.append(contentsOf: groups.filter { $0.0 == shape && owned.contains($0.2) }.map(\.1))
        v.sort()
        var out: [Int] = []
        for x in v where out.last != x { out.append(x) }
        return out
    }

    /// Shapes with any effect.
    public var animatedShapes: [ShapeId] {
        var v: [ShapeId] = []
        var seen = Set<ShapeId>()
        for e in effectList where seen.insert(e.timing.shape).inserted { v.append(e.timing.shape) }
        return v
    }

    /// State of `shape` (or of one of its paragraphs, `para`) when `step` main steps have been fully played
    /// and step `step` has been playing for `t` seconds (`t <= 0`: not started; `step >= steps`: everything
    /// done). Paragraph states are relative to the shape's own state (compose them). Triggered sequences are
    /// considered not played.
    public func state(_ shape: ShapeId, _ para: Int?, _ step: Int, _ t: Double) -> AnimState {
        stateWith(shape, para, step, t, [])
    }

    /// `state` with the playheads of triggered sequences.
    public func stateWith(_ shape: ShapeId, _ para: Int?, _ step: Int, _ t: Double, _ triggers: [TriggerPlay]) -> AnimState {
        stateOrdered(shape, para, step, t, triggers, [])
    }

    /// `stateWith` applying the effects of triggered sequences in the order their steps were started
    /// (`stamps`), after those of the main sequence. Without stamps they apply in Animation Pane order.
    public func stateOrdered(
        _ shape: ShapeId, _ para0: Int?, _ step: Int, _ t: Double, _ triggers: [TriggerPlay], _ stamps: [StepStamp]
    ) -> AnimState {
        let para = para0.map { p in groups.first { $0.0 == shape && $0.1 == p }?.2 ?? p }
        let baseColor = colors.first { $0.0 == shape }?.1 ?? Rgba.rgb(0x15, 0x60, 0x82)
        var st = AnimState()
        // Initial visibility comes from the first effect in the Animation Pane order.
        var ordered = effectList.filter { $0.timing.shape == shape && $0.timing.paragraph == para }
            .stableSorted { $0.timing.anim < $1.timing.anim }
        if let e0 = ordered.first, e0.timing.animClass == .entrance { st.visible = false }
        // Then play in time order: main sequence first, then triggered sequences as they were clicked.
        if !stamps.isEmpty {
            func when(_ e: Effect) -> UInt64 {
                switch e.timing.sequence {
                case .main: return 0
                case .trigger(let tr):
                    guard let s = stamps.first(where: { $0.trigger == tr && $0.step == e.timing.step }) else { return UInt64.max }
                    let (v, o) = s.at.addingReportingOverflow(1)
                    return o ? UInt64.max : v
                }
            }
            ordered = ordered.stableSorted { a, b in
                let (wa, wb) = (when(a), when(b))
                return wa != wb ? wa < wb : a.timing.anim < b.timing.anim
            }
        }
        for e in ordered {
            let (pstep, pt): (Int, Double)
            switch e.timing.sequence {
            case .main: (pstep, pt) = (step, t)
            case .trigger(let tr):
                if let p = triggers.first(where: { $0.trigger == tr }) { (pstep, pt) = (p.step, p.t) } else { (pstep, pt) = (0, 0.0) }
            }
            let cur = st.tint ?? baseColor
            let revert = e.timing.rewind || e.timing.autoReverse
            switch status(e.timing, pstep, pt) {
            case .notStarted:
                break
            case .active(let p):
                if e.timing.animClass == .entrance || e.timing.animClass == .exit { st.visible = true }
                st = st.compose(e.spec.spec.eval(p, cur))
            case .done:
                switch e.timing.animClass {
                case .entrance: st.visible = !revert
                case .exit: st.visible = revert
                case .emphasis where !revert, .path where !revert:
                    st = st.compose(e.spec.spec.endState(cur))
                default: break
                }
                switch e.after {
                case .hide: st.visible = false
                case .hideOnNextClick where pstep > e.timing.step: st.visible = false
                case .dim(let c) where pstep > e.timing.step: st.tint = c
                default: break
                }
            }
        }
        return st.sanitized()
    }

    /// State on the "play everything" clock (Animation Pane ▸ Play All, preview).
    public func stateAt(_ shape: ShapeId, _ para: Int?, _ time: Double) -> AnimState {
        let (s, t) = locate(time)
        return state(shape, para, s, t)
    }
}

private func status(_ e: EffectTiming, _ step: Int, _ t0: Double) -> Status {
    if e.step < step { return .done }
    if e.step > step { return .notStarted }
    let t = finiteOr(t0, 0.0)
    if t <= 0.0 { return .notStarted }
    let local = t - e.start
    if local < 0.0 { return .notStarted }
    let dur = e.duration
    if dur.isNaN || dur <= 0.0 || !dur.isFinite { return .done }
    if !e.untilNextClick && local >= e.span { return .done }
    let period = e.autoReverse ? 2.0 * dur : dur
    let c0 = local.rem(period)
    let c = c0.isFinite ? c0 : 0.0
    let p = c > dur ? 2.0 - c / dur : c / dur
    return .active(p.clamped(0.0, 1.0))
}

/// Shapes by id in the order `Slide.shape` searches (a shape before its children, groups at most 64 deep);
/// the first shape with an id wins a duplicate.
private func shapeIndex(_ shapes: [Shape]) -> [ShapeId: Shape] {
    var out: [ShapeId: Shape] = [:]
    func walk(_ shapes: [Shape], _ depth: Int) {
        if depth > 64 { return }
        for s in shapes {
            if out[s.id] == nil { out[s.id] = s }
            walk(s.children, depth + 1)
        }
    }
    walk(shapes, 0)
    return out
}

private func buildSpec(_ a: Animation, _ xf: Xfrm, _ sw: Double, _ sh: Double, _ resolve: (ColorRef) -> Rgba) -> EffectSpec {
    let effect = a.class == .exit ? exitBase(a.effect) : a.effect
    let path = a.class == .path ? motionPath(a.effect, a.option, a.path) : nil
    return EffectSpec(
        animClass: a.class,
        effect: effect,
        // Sink Down is Rise Up played backwards, leaving downward.
        option: a.effect == "sinkDown" ? "d" : a.option,
        accel: a.smoothStart,
        decel: a.smoothEnd,
        bounce: a.bounceEnd,
        amount: a.amount,
        color: a.color.map(resolve),
        path: path,
        xf: xf,
        slideW: sw,
        slideH: sh
    )
}
