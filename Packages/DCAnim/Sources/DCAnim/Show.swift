// DCAnim — slide show navigation: click steps, slide order (hidden slides, custom shows, ranges), loop and
// automatic advance. Port of deckcraft crates/anim/src/show.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
import DCCore
import DCModel

// Which links the show opens on a click; PDF export writes the same ones (deckcraft re-exports it here).
@_exported import func DCModel.safeURL

/// What the UI should do after a navigation call.
public enum ShowAction: Sendable, Equatable {
    /// Nothing changed (e.g. back on the first slide).
    case none_
    /// Start playing main step `n` of the current slide (clock from 0).
    case playStep(Int)
    /// Step `n` jumped to its end (it was playing); nothing plays now.
    case finishStep(Int)
    /// Went back before step `n` (showing the state before it).
    case stepBack(Int)
    /// Moved to slide index `n` (play its transition; `ShowState.playing` tells whether step 0 starts by
    /// itself).
    case slide(Int)
    /// Past the last slide: show the end screen.
    case end
    /// Leave the show (next on the end screen).
    case exit
}

/// What a clicked link does in the show (`ShowState.follow`).
public enum LinkJump: Sendable, Equatable {
    /// Navigation inside the show (already applied to the state).
    case show(ShowAction)
    /// Open this URL (`http`, `https` or `mailto`, see `safeURL`) outside the show.
    case open(String)
    /// End the show.
    case exit
    /// Nothing to follow.
    case none_
}

/// Where a slide show is. Besides the current position it remembers what was played on every slide the show
/// has visited (main steps, triggered sequences), so a slide reached again by a link or the arrow keys looks
/// the way it was left, as in PowerPoint.
public struct ShowState: Sendable, Equatable {
    /// Index into `presentation.slides`.
    public var slide = 0
    /// Main step that plays next or is playing; `== steps` when the slide is fully built.
    public var step = 0
    /// Step `step` is playing (its clock runs). With `step`, gives `Timeline.state(.., step, t)`.
    public var playing = false
    /// On the end screen.
    public var ended = false
    /// The show has entered a slide (so `slide` and `step` are meaningful and can be saved).
    private var active = false
    /// The time of the last `tick` (seconds), for the triggered animations' clocks.
    var lastNow: Double?
    /// What was played on each visited slide (index into `presentation.slides`).
    var runs: [Int: SlideRun] = [:]
    /// One-shot visit order (Custom Show from the dialog or a click). nil uses `showOrder`.
    private var order: [Int]?
    /// Name of the custom show being played, when there is one.
    private var custom: String?
    /// Return to Zoom: (zoom slide, last zoomed slide). Advancing past the last zoomed slide goes back to
    /// the zoom slide, fully built.
    public var zoom: (back: Int, until: Int)?

    public init() {}

    public static func == (a: ShowState, b: ShowState) -> Bool {
        a.slide == b.slide && a.step == b.step && a.playing == b.playing && a.ended == b.ended && a.active == b.active
            && a.lastNow == b.lastNow && a.runs == b.runs && a.order == b.order && a.custom == b.custom
            && a.zoom?.back == b.zoom?.back && a.zoom?.until == b.zoom?.until
    }
}

/// Index of each slide by id (the first slide wins a duplicate id), so resolving a custom show costs the sum
/// of its two lists, not their product.
private func slideIndices(_ pres: Presentation) -> [SlideId: Int] {
    var map: [SlideId: Int] = [:]
    map.reserveCapacity(pres.slides.count)
    for (i, s) in pres.slides.enumerated() where map[s.id] == nil { map[s.id] = i }
    return map
}

/// Slide indices the show visits in order: the custom show or range from Set Up Slide Show, minus hidden
/// slides.
public func showOrder(_ pres: Presentation) -> [Int] {
    let n = pres.slides.count
    let base: [Int]
    if let name = pres.show.customShow, let cs = pres.customShows.first(where: { rustEqual($0.name, name) }) {
        let index = slideIndices(pres)
        base = cs.slides.compactMap { index[$0] }
    } else if let r = pres.show.range {
        let a = Int(Swift.max(r.a, 1)) - 1
        let b = Swift.min(Int(r.b), n)
        base = a < b ? Array(a ..< b) : []
    } else {
        base = Array(0 ..< n)
    }
    return base.filter { i in pres.slides.at(i).map { !$0.hidden } ?? false }
}

/// Visible slides of custom show `name`, in that show's order.
private func customIndices(_ pres: Presentation, _ name: String) -> [Int]? {
    guard let cs = pres.customShows.first(where: { rustEqual($0.name, name) }) else { return nil }
    let index = slideIndices(pres)
    let order = cs.slides.compactMap { index[$0] }.filter { i in pres.slides.at(i).map { !$0.hidden } ?? false }
    return order.isEmpty ? nil : order
}

private func looping(_ pres: Presentation) -> Bool {
    pres.show.loopUntilEsc || pres.show.showType == "kiosk"
}

extension ShowState {
    /// Start at the first slide of the show order.
    public init(_ pres: Presentation) {
        if let i = showOrder(pres).first {
            self = ShowState.startAt(pres, i)
        } else {
            self.init()
            ended = true
        }
    }

    /// Start at slide `i` (hidden slides allowed: "from current slide").
    public static func startAt(_ pres: Presentation, _ i: Int) -> ShowState {
        var s = ShowState()
        if i >= 0 && i < pres.slides.count {
            s.enter(pres, i)
        } else {
            s.ended = true
        }
        if let name = pres.show.customShow { s.custom = name }
        return s
    }

    /// Play custom show `name` from its first slide, without changing Set Up Slide Show. nil when that show
    /// is missing or has no visible slides.
    public static func playCustom(_ pres: Presentation, _ name: String) -> ShowState? {
        guard let order = customIndices(pres, name), let first = order.first else { return nil }
        var s = ShowState.startAt(pres, first)
        s.order = order
        s.custom = name
        return s
    }

    /// Name of the custom show this playback is limited to.
    public var customName: String? {
        guard let c = custom, !c.isEmpty else { return nil }
        return c
    }

    /// The slide that follows the current one in this show.
    public func peekNext(_ pres: Presentation) -> Int? { nextIndex(pres) }

    public func firstIndex(_ pres: Presentation) -> Int? { visit(pres).first }

    public func lastIndex(_ pres: Presentation) -> Int? { visit(pres).last }

    private func visit(_ pres: Presentation) -> [Int] {
        if let order { return order.filter { i in pres.slides.at(i).map { !$0.hidden } ?? false } }
        return showOrder(pres)
    }

    /// The timeline of slide `i`.
    public static func timeline(_ pres: Presentation, _ i: Int) -> Timeline {
        guard let s = pres.slides.at(i) else { return Timeline() }
        return Timeline(s, pres.slideSize.width, pres.slideSize.height)
    }

    /// Main steps of slide `i` (0 with Show without animation).
    public static func steps(_ pres: Presentation, _ i: Int) -> Int {
        pres.show.withoutAnimation ? 0 : timeline(pres, i).steps
    }

    /// Save what was played on the current slide before the show moves away from it. A main step that is
    /// playing is taken to its end. Triggered animations keep their place: their clock only runs while the
    /// slide is shown, and they go on from there when the show comes back.
    private mutating func leave(_ pres: Presentation) {
        if !active { return }
        let done = playing ? step + 1 : step
        let st = Swift.min(done, ShowState.steps(pres, slide))
        runs[slide, default: SlideRun()].step = st
        playing = false
    }

    /// Show slide `i`: as it was left when the show has been there before, otherwise from the start.
    private mutating func enter(_ pres: Presentation, _ i: Int) {
        leave(pres)
        active = true
        slide = i
        ended = false
        // Time spent elsewhere never counts for this slide's triggered animations.
        lastNow = nil
        let steps = ShowState.steps(pres, i)
        var run = runs[i] ?? SlideRun()
        if run.visited {
            step = Swift.min(run.step, steps)
            playing = false
        } else {
            run.visited = true
            step = 0
            playing = !pres.show.withoutAnimation && ShowState.timeline(pres, i).stepIsAuto(0)
        }
        runs[i] = run
    }

    private func nextIndex(_ pres: Presentation) -> Int? {
        let order = visit(pres)
        if let p = order.firstIndex(of: slide) { return order.at(p + 1) }
        return order.first { $0 > slide }
    }

    private func prevIndex(_ pres: Presentation) -> Int? {
        let order = visit(pres)
        if let p = order.firstIndex(of: slide) { return p > 0 ? order.at(p - 1) : nil }
        return order.last { $0 < slide }
    }

    /// Click / → / Space: finish the playing step, else play the next step, else go to the next slide.
    public mutating func next(_ pres: Presentation) -> ShowAction {
        if pres.slides.isEmpty {
            ended = true
            return .exit
        }
        if ended { return .exit }
        if playing { return stepDone(pres) }
        let steps = ShowState.steps(pres, slide)
        if step < steps {
            playing = true
            return .playStep(step)
        }
        if let z = zoom, z.until == slide, z.back >= 0, z.back < pres.slides.count {
            let back = z.back
            zoom = nil
            enter(pres, back)
            step = ShowState.steps(pres, back)
            playing = false
            return .slide(back)
        }
        if let i = nextIndex(pres) {
            enter(pres, i)
            return .slide(i)
        }
        if looping(pres) {
            if let i = visit(pres).first {
                enter(pres, i)
                return .slide(i)
            }
            ended = true
            return .end
        }
        ended = true
        playing = false
        return .end
    }

    /// The playing step reached its end (the UI's clock passed `stepDuration`).
    public mutating func stepDone(_ pres: Presentation) -> ShowAction {
        if !playing { return .none_ }
        let n = step
        playing = false
        step = Swift.min(step + 1, ShowState.steps(pres, slide))
        return .finishStep(n)
    }

    /// ← / Backspace: undo the last step, else go to the previous slide fully built. An automatic first step
    /// (With/After Previous) is part of the slide appearing, so it is never undone.
    public mutating func prev(_ pres: Presentation) -> ShowAction {
        if ended {
            ended = false
            if slide >= pres.slides.count { return .none_ }
            step = ShowState.steps(pres, slide)
            playing = false
            return .slide(slide)
        }
        // #844: undoing the automatic first step left the slide as before it appeared, and the show played
        // the step again at once, so Back never got past the slide.
        let undo: Int? = playing ? step : (step > 0 ? step - 1 : nil)
        let autoFirst = undo == 0 && !pres.show.withoutAnimation && ShowState.timeline(pres, slide).stepIsAuto(0)
        if let k = undo, !autoFirst {
            playing = false
            step = k
            return .stepBack(k)
        }
        let target: Int?
        if let i = prevIndex(pres) {
            target = i
        } else if looping(pres) {
            target = visit(pres).last.flatMap { $0 != slide ? $0 : nil }
        } else {
            target = nil
        }
        guard let i = target else { return .none_ }
        // A slide the show has been to looks as it was left; one it has not been to is shown fully built.
        let seen = runs[i]?.visited ?? false
        enter(pres, i)
        if !seen {
            step = ShowState.steps(pres, i)
            playing = false
        }
        return .slide(i)
    }

    /// Jump to slide `i` (number + Enter, See All Slides); hidden slides are shown when jumped to.
    public mutating func goto(_ pres: Presentation, _ i: Int) -> ShowAction {
        if i < 0 || i >= pres.slides.count { return .none_ }
        zoom = nil
        enter(pres, i)
        return .slide(i)
    }

    /// Follow a clicked hyperlink or shape action. `lastViewed` is the slide shown before the current one
    /// (Last Slide Viewed). Moves to slide targets; everything else is for the UI.
    public mutating func follow(_ pres: Presentation, _ action: Action, _ lastViewed: Int?) -> LinkJump {
        let target: Int?
        switch action {
        case .url(let url):
            return safeURL(url) ? .open(String(rustTrim(url))) : .none_
        case .endShow:
            return .exit
        case .slide(let id):
            target = pres.slides.firstIndex { $0.id == id }
        case .nextSlide:
            target = nextIndex(pres)
        case .previousSlide:
            target = prevIndex(pres)
        case .firstSlide:
            target = visit(pres).first
        case .lastSlide:
            target = visit(pres).last
        case .lastViewed:
            target = lastViewed
        case .customShow(let name, _):
            guard let order = customIndices(pres, name), let i = order.first else { return .none_ }
            self.order = order
            custom = name
            return .show(goto(pres, i))
        case .program, .playMedia:
            // Programs and media actions aren't followed.
            target = nil
        }
        guard let i = target else { return .none_ }
        return .show(goto(pres, i))
    }

    /// Follow a clicked link, honouring a zoom's Return to Zoom (see `Hyperlink.zoomReturn`).
    public mutating func followLink(_ pres: Presentation, _ link: Hyperlink, _ lastViewed: Int?) -> LinkJump {
        let from = slide
        let jump = follow(pres, link.action, lastViewed)
        if let id = link.zoomReturn, let until = pres.slides.firstIndex(where: { $0.id == id }), case .show(.slide) = jump {
            zoom = (from, until)
        }
        return jump
    }

    /// Seconds after which the current slide advances by itself (Advance Slide ▸ After), when the show uses
    /// timings.
    public func advanceAfter(_ pres: Presentation) -> Double? {
        if !pres.show.useTimings || ended { return nil }
        return pres.slides.at(slide)?.transition?.advanceAfterMs.map { Double($0) / 1000.0 }
    }

    /// Should the show advance now, `elapsed` seconds after the slide appeared? Waits for the slide's
    /// animations: auto-advance happens once nothing plays and the time is up; remaining click steps play
    /// automatically with timings.
    public func autoAdvanceDue(_ pres: Presentation, _ elapsed: Double) -> Bool {
        guard let after = advanceAfter(pres) else { return false }
        return !playing && elapsed.isFinite && elapsed >= after
    }
}
