// DCAppModel — the Animation Pane without a window: the advanced timeline's bars, ruler and drag-to-retime
// arithmetic, the pane's rows, and which effect Play From starts at. Port of deckcraft
// `crates/ui-egui/src/animtimeline.rs` and the logic of `animation` in `panes.rs` (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import DCAnim
import DCCore
import DCEngine
import DCModel

public enum AnimTimeline {
    /// Drags snap to this step (milliseconds), like PowerPoint's 0.05 s granularity.
    public static let snapMs: UInt32 = 50
    /// Shortest duration a drag can produce (milliseconds).
    public static let minDurationMs: UInt32 = 50
    /// Upper bound for delay and duration, matching `animation.timing`'s clamp.
    public static let maxMs: UInt32 = 600_000
    static let minPPS = 8.0
    static let maxPPS = 120.0

    /// One effect row of the timeline (the first paragraph of a by-paragraph build).
    public struct Bar: Sendable, Equatable {
        /// Index into `slide.animations`.
        public var anim: Int
        /// Click step in the main sequence, nil for a triggered sequence.
        public var step: Int?
        /// Start within the step, delay included (seconds).
        public var start: Double
        /// Start to end, all repeats included (seconds).
        public var span: Double

        public init(anim: Int, step: Int?, start: Double, span: Double) {
            self.anim = anim
            self.step = step
            self.start = start
            self.span = span
        }
    }

    /// One timed effect as the timeline reads it (`EffectTiming`'s fields the bars use).
    public struct Effect: Sendable, Equatable {
        public var anim: Int
        public var step: Int?
        public var start: Double
        public var span: Double
        public init(anim: Int, step: Int?, start: Double, span: Double) {
            self.anim = anim
            self.step = step
            self.start = start
            self.span = span
        }

        public init(_ e: EffectTiming) {
            anim = e.anim
            if case .main = e.sequence { step = e.step } else { step = nil }
            start = e.start
            span = e.span
        }
    }

    /// `bars`: one bar per animation, in `slide.animations` order; animations without timing get nil.
    public static func bars(_ count: Int, _ effects: [Effect]) -> [Bar?] {
        var out = [Bar?](repeating: nil, count: Swift.max(count, 0))
        for e in effects {
            guard out.indices.contains(e.anim), out[e.anim] == nil else { continue }
            let start = e.start.isFinite ? Swift.max(e.start, 0) : 0
            let span = e.span.isFinite ? Swift.max(e.span, 0) : 0
            out[e.anim] = Bar(anim: e.anim, step: e.step, start: start, span: span)
        }
        return out
    }

    /// `ruler_seconds`: the longest bar end, at least one second, rounded up.
    public static func rulerSeconds(_ bars: [Bar?]) -> UInt32 {
        let end = bars.compactMap { $0 }.map { $0.start + $0.span }.reduce(1.0) { Swift.max($0, $1) }
        let s = Swift.min(end.rounded(.up), Double(maxMs / 1000))
        return s.isFinite && s >= 1 ? UInt32(s) : 1
    }

    /// `pixels_per_second`: so `seconds` fit in `width`.
    public static func pixelsPerSecond(_ width: Double, _ seconds: UInt32) -> Double {
        let secs = Double(Swift.max(seconds, 1))
        let pps = width.isFinite ? width / secs : minPPS
        return Swift.min(Swift.max(pps, minPPS), maxPPS)
    }

    static func snap(_ ms: Double) -> UInt32 {
        guard ms.isFinite, ms > 0 else { return 0 }
        let snapped = (ms / Double(snapMs)).rounded() * Double(snapMs)
        return snapped >= Double(maxMs) ? maxMs : UInt32(snapped)
    }

    static func deltaMs(_ dx: Double, _ pps: Double) -> Double {
        guard dx.isFinite, pps.isFinite, pps > 0 else { return 0 }
        return dx / pps * 1000
    }

    /// `dragged_delay`: the new delay after dragging a bar's body `dx` points.
    public static func draggedDelay(_ delayMs: UInt32, _ dx: Double, _ pps: Double) -> UInt32 {
        snap(Double(delayMs) + deltaMs(dx, pps))
    }

    /// `dragged_duration`: the new duration after dragging a bar's right edge `dx` points. The bar shows
    /// all repeats, so the edge moves `factor` times as fast as one iteration.
    public static func draggedDuration(_ durationMs: UInt32, _ dx: Double, _ pps: Double, _ factor: Double) -> UInt32 {
        let f = factor.isFinite && factor >= 1 ? factor : 1
        return Swift.max(snap(Double(durationMs) + deltaMs(dx, pps) / f), minDurationMs)
    }

    /// `label`: the bar's tooltip.
    public static func label(_ bar: Bar) -> String {
        L10n.text("Start: \(rustFixed(bar.start, places: 2))s, End: \(rustFixed(bar.start + bar.span, places: 2))s")
    }
}

/// The Animation Pane's rows for the current slide.
public struct AnimPaneRow: Sendable, Equatable {
    public var index: Int
    public var shape: ShapeId
    public var name: String
    public var animClass: AnimClass
    public var effect: String
    /// The click number shown for an On Click effect (empty otherwise).
    public var click: String
    public var bar: AnimTimeline.Bar?
    public var durationMs: UInt32
    public var delayMs: UInt32
    public var repeatForever: Bool
    public var start: AnimStart
    public var trigger: ShapeId?
}

public struct AnimPane: Sendable {
    public var rows: [AnimPaneRow] = []
    public var seconds: UInt32 = 1
    /// Seconds into the play-all clock where each effect starts (nil for a triggered one).
    public var starts: [Double?] = []

    public init() {}

    /// The pane for the active document's current slide.
    public init(_ st: DocState) {
        guard let slide = st.currentSlide else { return }
        let tl = Timeline(slide, st.doc.slideSize.width, st.doc.slideSize.height)
        let anims = slide.animations
        let bars = AnimTimeline.bars(anims.count, tl.effects.map(AnimTimeline.Effect.init))
        seconds = AnimTimeline.rulerSeconds(bars)
        starts = anims.indices.map { tl.startOf($0) }
        var names: [ShapeId: String] = [:]
        walk(st.shapes) { s, _ in if names[s.id] == nil { names[s.id] = s.name } }
        var click = 0
        for (i, a) in anims.enumerated() {
            if a.start == .onClick { click += 1 }
            rows.append(AnimPaneRow(
                index: i, shape: a.shape, name: names[a.shape] ?? L10n.text("Shape \(String(describing: a.shape))"), animClass: a.class, effect: a.effect,
                click: a.start == .onClick ? "\(click)" : "", bar: bars.at(i) ?? nil, durationMs: a.durationMs,
                delayMs: a.delayMs, repeatForever: a.repeat == UInt32.max, start: a.start, trigger: a.trigger
            ))
        }
    }

    /// Play From's effect: the one last clicked in the pane when it belongs to a selected shape and is on
    /// the click sequence, else the first such effect of the selection; nil means Play All.
    public func playFrom(pick: Int?, selected: [ShapeId]) -> Int? {
        func eligible(_ i: Int) -> Bool {
            guard let r = rows.at(i), selected.contains(r.shape) else { return false }
            return (starts.at(i) ?? nil) != nil
        }
        if let p = pick, eligible(p) { return p }
        return rows.indices.first(where: eligible)
    }

    /// The Play button's label and `animation.preview` parameters.
    public static func playButton(playing: Bool, from: Int?) -> (label: String, params: JSON) {
        switch (playing, from) {
        case (true, _): (L10n.text("Stop"), ["on": false])
        case (false, let i?): (L10n.text("Play From"), ["on": true, "from": .integer(i)])
        case (false, nil): (L10n.text("Play All"), ["on": true])
        }
    }
}

/// The Animations and Transitions ribbon tabs' choices without a window (`ribbon.rs`).
public enum InspectorMotion {
    /// The quick gallery of the Animations tab.
    public static let quickEffects: Set<String> = ["appear", "fade", "fly", "float", "split", "wipe", "zoom", "pulse", "spin", "growShrink", "fadeOut", "flyOut", "lines"]

    /// `marked_options`: each option and whether it is the stored one.
    public static func marked(_ options: [String], _ current: String?) -> [(String, Bool)] {
        options.map { ($0, current == $0) }
    }

    /// `transition_effect_rows`.
    public static func transitionEffectRows(_ kind: String, _ current: String?) -> [(String, Bool)] {
        marked(transitions.first { $0.id == kind }?.options ?? [], current)
    }

    /// `animation_effect_rows`.
    public static func animationEffectRows(_ effect: String, _ cls: AnimClass, _ current: String?) -> [(String, Bool)] {
        marked(animationInfo(effect, cls)?.options ?? [], current)
    }

    /// `text_build_id`.
    public static func textBuildId(_ b: TextBuild) -> String { b.rawValue }

    /// `option_label`: an animation option's name ("l" → "From Left", "fromBottom" → "From Bottom").
    public static func optionLabel(_ o: String) -> String {
        switch o {
        case "l": return L10n.text("From Left")
        case "r": return L10n.text("From Right")
        case "u": return L10n.text("From Top")
        case "d": return L10n.text("From Bottom")
        case "horz": return L10n.text("Horizontal")
        case "vert": return L10n.text("Vertical")
        case "in": return L10n.text("In")
        case "out": return L10n.text("Out")
        default:
            var s = ""
            for (i, c) in o.enumerated() {
                if i == 0 { s += c.uppercased() } else if c.isUppercase { s += " " + String(c) } else { s.append(c) }
            }
            return s
        }
    }

    public static func className(_ c: AnimClass) -> String {
        switch c {
        case .entrance: L10n.text("Entrance")
        case .emphasis: L10n.text("Emphasis")
        case .exit: L10n.text("Exit")
        case .path: L10n.text("Motion Paths")
        case .media: L10n.text("Media")
        }
    }

    public static let starts: [(String, String)] = [(L10n.text("On Click"), "onClick"), (L10n.text("With Previous"), "withPrevious"), (L10n.text("After Previous"), "afterPrevious")]

    public static func startLabel(_ s: AnimStart) -> String {
        switch s {
        case .onClick: L10n.text("On Click")
        case .withPrevious: L10n.text("With Previous")
        case .afterPrevious: L10n.text("After Previous")
        }
    }

    /// Seconds in a spinner → `animation.timing` / `transition.timing` milliseconds.
    public static func ms(_ seconds: Double) -> JSON {
        guard seconds.isFinite else { return 0 }
        return .integer(UInt64(Swift.min((Swift.max(seconds, 0) * 1000).rounded(), 1e12)))
    }
}
