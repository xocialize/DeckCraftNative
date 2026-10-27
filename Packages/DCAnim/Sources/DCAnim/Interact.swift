// DCAnim — clicks in a slide show: which shape a click lands on, what it starts (a triggered animation, a
// link, the next step) and what the show remembers about each slide it has visited. Port of deckcraft
// crates/anim/src/interact.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// The rules follow PowerPoint, as observed on its slide show:
// - the topmost visible shape under the pointer decides; a shape without an action on top of one with an
//   action blocks it (the click then counts as a click on the background);
// - a shape with a triggered animation plays the next step of it per click, and starts over once all its
//   steps have played; clicking it while a step plays completes the step at once;
// - a shape with a link and a triggered animation follows the link at once. The animation's clock runs only
//   while its slide is shown, so it goes on where it stopped when the show returns;
// - with "advance on click" off a click never leaves the slide, but it still plays animation steps;
// - a slide the show returns to (link or arrow keys) looks as it was left.
import DCCore
import DCModel

/// What was played on one slide.
struct SlideRun: Sendable, Equatable {
    /// The show has been on this slide.
    var visited = false
    /// Main-sequence steps played when the show left the slide.
    var step = 0
    /// Triggered sequences started by clicks.
    var triggers: [TriggerRun] = []
    /// Steps of triggered sequences started so far (the stamps of `StepStamp`).
    var clock: UInt64 = 0
}

/// Progress of one triggered sequence.
struct TriggerRun: Sendable, Equatable {
    var shape: ShapeId
    /// Clicks whose step has played to its end.
    var done: Int
    /// Seconds the current step has played; nil when no step is playing.
    var elapsed: Double?
    /// When each step of this run was started, by step.
    var stamps: [UInt64]
}

/// One shape of the slide for hit testing, in drawing order (back to front; a group before its children),
/// with whether the pointer is inside its box.
public struct HitShape: Sendable, Equatable {
    public var id: ShapeId
    /// Index of the enclosing group in the same list.
    public var parent: Int?
    public var isGroup: Bool
    /// The shape's own action.
    public var link: Action?
    public var underPointer: Bool

    public init(id: ShapeId, parent: Int? = nil, isGroup: Bool = false, link: Action? = nil, underPointer: Bool = true) {
        self.id = id
        self.parent = parent
        self.isGroup = isGroup
        self.link = link
        self.underPointer = underPointer
    }
}

/// What the pointer is over: a shape that does something when clicked.
public struct Target: Sendable, Equatable {
    public var shape: ShapeId
    public var link: Action?

    public init(shape: ShapeId, link: Action? = nil) {
        self.shape = shape
        self.link = link
    }
}

/// What a click did.
public enum Click: Sendable, Equatable {
    /// Nothing happened.
    case none_
    /// A triggered animation started or was completed: redraw.
    case animated
    /// Navigation inside the show (already applied to the state).
    case show(ShowAction)
    /// Open this URL outside the show.
    case open(String)
    /// End the show.
    case exit

    public init(_ j: LinkJump) {
        switch j {
        case .show(let a): self = .show(a)
        case .open(let u): self = .open(u)
        case .exit: self = .exit
        case .none_: self = .none_
        }
    }
}

private func finiteOrZero(_ v: Double) -> Double { v.isFinite ? v : 0.0 }

extension ShowState {
    private func animated(_ pres: Presentation) -> Bool { !pres.show.withoutAnimation }

    /// Does clicking `shape` start a triggered sequence? A sequence can be started again once it has played
    /// to its end.
    private func triggerLive(_ pres: Presentation, _ tl: Timeline, _ shape: ShapeId) -> Bool {
        animated(pres) && tl.triggerSteps(shape) > 0
    }

    /// The playheads of the current slide's triggered sequences at the last tick, for `Timeline.stateWith`.
    public var triggerPlays: [TriggerPlay] {
        guard let r = runs[slide] else { return [] }
        return r.triggers.map { TriggerPlay(trigger: $0.shape, step: $0.done, t: $0.elapsed ?? 0.0) }
    }

    /// When the steps of the current slide's triggered sequences were started.
    public var triggerStamps: [StepStamp] {
        guard let r = runs[slide] else { return [] }
        return r.triggers.flatMap { t in t.stamps.enumerated().map { StepStamp(trigger: t.shape, step: $0.offset, at: $0.element) } }
    }

    /// Is a triggered animation of the current slide playing (so the picture changes every frame)?
    public var triggerPlaying: Bool {
        runs[slide]?.triggers.contains { $0.elapsed != nil } ?? false
    }

    /// Animation state of `shape` on the current slide: main step `step` with `tMain` seconds played, plus
    /// the triggered sequences.
    public func animState(_ tl: Timeline, _ shape: ShapeId, _ tMain: Double) -> AnimState {
        tl.stateOrdered(shape, nil, step, tMain, triggerPlays, triggerStamps)
    }

    /// Advance the clock of the playing triggered animations to `now` (seconds, any steady clock) and
    /// complete the steps that reached their end. `.animated` when the picture changed.
    @discardableResult
    public mutating func tick(_ tl: Timeline, _ now: Double) -> Click {
        let dt: Double = if let last = lastNow, now.isFinite { (now - last).clamped(0.0, 3600.0) } else { 0.0 }
        if now.isFinite { lastNow = now }
        guard var run = runs[slide] else { return .none_ }
        var changed = false
        for k in run.triggers.indices {
            guard let e0 = run.triggers[k].elapsed else { continue }
            let e = finiteOrZero(e0) + dt
            if e >= tl.triggerStepDuration(run.triggers[k].shape, run.triggers[k].done) {
                run.triggers[k].done += 1
                run.triggers[k].elapsed = nil
                changed = true
            } else {
                run.triggers[k].elapsed = e
            }
        }
        runs[slide] = run
        return changed ? .animated : .none_
    }

    /// Index of the topmost shape a click lands on: the front-most one under the pointer that is shown. A
    /// group without an action does not count; its children and the space inside its box are not it.
    public func top(_ pres: Presentation, _ tl: Timeline, _ shapes: [HitShape], _ visible: (ShapeId) -> Bool) -> Int? {
        func shown(_ i0: Int) -> Bool {
            // A shape is shown when it and the groups around it are.
            var i = i0
            for _ in 0 ... shapes.count {
                guard let h = shapes.at(i) else { return false }
                if !visible(h.id) { return false }
                guard let p = h.parent else { return true }
                i = p
            }
            return false
        }
        for i in shapes.indices.reversed() {
            let h = shapes[i]
            if h.underPointer && !(h.isGroup && !interactive(pres, tl, h)) && shown(i) { return i }
        }
        return nil
    }

    private func interactive(_ pres: Presentation, _ tl: Timeline, _ h: HitShape) -> Bool {
        h.link != nil || triggerLive(pres, tl, h.id)
    }

    /// The shape under the pointer that a click would act on, nil when a click would be a click on the
    /// background. `visible` tells whether a shape is currently shown (not yet entered or already exited
    /// shapes cannot be clicked).
    public func target(_ pres: Presentation, _ tl: Timeline, _ shapes: [HitShape], _ visible: (ShapeId) -> Bool) -> Target? {
        // The topmost shape, or the group it is in, that has an action. A shape without one blocks what
        // lies beneath it.
        var at = top(pres, tl, shapes, visible)
        for _ in 0 ... shapes.count {
            guard let i = at, let h = shapes.at(i) else { return nil }
            if interactive(pres, tl, h) { return Target(shape: h.id, link: h.link) }
            at = h.parent
        }
        return nil
    }

    /// A mouse click. `shapes` and `visible` describe what is under the pointer (see `target`); `lastViewed`
    /// is the slide shown before this one.
    public mutating func click(
        _ pres: Presentation, _ tl: Timeline, _ shapes: [HitShape], _ visible: (ShapeId) -> Bool, _ now: Double, _ lastViewed: Int?
    ) -> Click {
        tick(tl, now)
        if ended { return .none_ }
        guard let t = target(pres, tl, shapes, visible) else { return backgroundClick(pres) }
        var animatedNow = false
        if triggerLive(pres, tl, t.shape) {
            var run = runs[slide] ?? SlideRun()
            let at: Int
            if let p = run.triggers.firstIndex(where: { $0.shape == t.shape }) {
                at = p
            } else {
                run.triggers.append(TriggerRun(shape: t.shape, done: 0, elapsed: nil, stamps: []))
                at = run.triggers.count - 1
            }
            let (s, o) = run.clock.addingReportingOverflow(1)
            let stamp = o ? UInt64.max : s
            if run.triggers.indices.contains(at) {
                if run.triggers[at].elapsed != nil {
                    // A click on a shape whose step is playing completes the step.
                    run.triggers[at].done += 1
                    run.triggers[at].elapsed = nil
                } else {
                    if run.triggers[at].done >= tl.triggerSteps(t.shape) {
                        // All steps have played: the sequence starts over.
                        run.triggers[at].done = 0
                        run.triggers[at].stamps.removeAll()
                    }
                    run.triggers[at].stamps.append(stamp)
                    run.clock = stamp
                    if tl.triggerStepDuration(t.shape, run.triggers[at].done) > 0.0 {
                        run.triggers[at].elapsed = 0.0
                    } else {
                        run.triggers[at].done += 1
                    }
                }
                animatedNow = true
            }
            runs[slide] = run
        }
        if let a = t.link {
            // The link is followed at once, whatever the animation still has to play.
            return Click(follow(pres, a, lastViewed))
        }
        return animatedNow ? .animated : .none_
    }

    /// A click that is on no shape with an action: next animation step, then next slide, unless the slide
    /// has "advance on click" off, which leaves only the animation steps.
    private mutating func backgroundClick(_ pres: Presentation) -> Click {
        let advance = pres.slides.at(slide)?.transition.map(\.advanceOnClick) ?? true
        let stepsLeft = playing || step < ShowState.steps(pres, slide)
        return advance || stepsLeft ? .show(next(pres)) : .none_
    }
}
