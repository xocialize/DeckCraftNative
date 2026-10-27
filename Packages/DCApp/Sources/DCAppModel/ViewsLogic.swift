// DCAppModel — the window-free logic of the Views area: the navigator's and the Slide Sorter's rows and
// drops, section folding, New Window's state, the status bar's texts and zoom slider, and the outline.
// Ports of `groups`, `drop_slot`, `move_dest` (deckcraft `crates/ui-egui/src/sorter.rs`), the drop
// arithmetic of `thumbs.rs`, `command`/`shift`/`window_title` (`doc_window.rs`), the status bar's texts
// (`status.rs`, `selected_language` in `dialogs.rs`) and `outline_estimate`/`outline_slide` (`sorter.rs`)
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCEngine
import DCModel
import Foundation

// MARK: Sections and drops

public enum SorterLogic {
    /// `groups`: each section's slides in the section's order, then the slides that belong to none. With
    /// no sections, one group of every slide.
    public static func groups(_ doc: Presentation) -> [(section: Int?, slides: [Int])] {
        if doc.sections.isEmpty { return [(nil, Array(doc.slides.indices))] }
        var index: [SlideId: Int] = [:]
        for (i, s) in doc.slides.enumerated() where index[s.id] == nil { index[s.id] = i }
        var seen = [Bool](repeating: false, count: doc.slides.count)
        var out: [(Int?, [Int])] = []
        out.reserveCapacity(doc.sections.count + 1)
        for (si, sec) in doc.sections.enumerated() {
            var slides: [Int] = []
            for id in sec.slides {
                if let i = index[id], i < seen.count, !seen[i] {
                    seen[i] = true
                    slides.append(i)
                }
            }
            out.append((si, slides))
        }
        let rest = seen.indices.filter { !seen[$0] }
        if !rest.isEmpty { out.append((nil, rest)) }
        return out
    }

    /// `drop_slot`: the gap a drag at `y` lands in, given the header centres top to bottom (0 = before the
    /// first, `count` = after the last).
    public static func dropSlot(_ centers: [Double], _ y: Double) -> Int {
        centers.firstIndex { y < $0 } ?? centers.count
    }

    /// `move_dest`: the `to` of `slide.move` / `section.move` for an item at `from` dropped in gap `slot`;
    /// nil when it would stay where it is (the gap before it or just after it).
    public static func moveDest(_ from: Int, _ slot: Int) -> Int? {
        if slot == from || slot == from + 1 { return nil }
        return slot > from ? slot - 1 : slot
    }
}

/// A folded section, keyed by its document and its first slide, so moving a section doesn't fold another
/// (`sorter::State::collapsed`). An empty section has nothing to fold.
public struct FoldKey: Hashable, Sendable {
    public var uid: UInt64
    public var firstSlide: UInt32
    public init(uid: UInt64, firstSlide: UInt32) {
        self.uid = uid
        self.firstSlide = firstSlide
    }
}

/// One row of the slide navigator: a section bar or a slide.
public enum NavigatorRow: Equatable, Sendable {
    case section(index: Int, name: String, count: Int, folded: Bool, first: UInt32?)
    case slide(index: Int)

    public var slideIndex: Int? {
        if case .slide(let i) = self { return i }
        return nil
    }
}

public enum NavigatorLogic {
    /// The navigator's rows: a bar per section (with its slide count), then its slides unless folded.
    public static func rows(_ doc: Presentation, uid: UInt64, folded: Set<FoldKey>) -> [NavigatorRow] {
        var out: [NavigatorRow] = []
        out.reserveCapacity(doc.slides.count + doc.sections.count)
        for g in SorterLogic.groups(doc) {
            if let si = g.section, let sec = doc.sections.at(si) {
                let first = sec.slides.first?.rawValue
                let isFolded = first.map { folded.contains(FoldKey(uid: uid, firstSlide: $0)) } ?? false
                out.append(.section(index: si, name: sec.name, count: sec.slides.count, folded: isFolded, first: first))
                if isFolded { continue }
            }
            for i in g.slides { out.append(.slide(index: i)) }
        }
        return out
    }

    /// What a click on slide `index` runs (`thumbs.rs`, `place_slides`): Shift selects the range from the
    /// anchor (⌘⇧ keeps what is selected), ⌘ adds the slide, a plain click goes to it.
    public static func click(_ doc: Presentation, index: Int, shift: Bool, command: Bool) -> (id: String, params: JSON)? {
        guard let slide = doc.slides.at(index) else { return nil }
        if shift { return ("slide.selectRange", ["to": .integer(index), "add": .bool(command)]) }
        if command { return ("slide.selectSlides", ["ids": .array([.integer(slide.id.rawValue)]), "add": true]) }
        return ("slide.go", ["index": .integer(index)])
    }

    /// Whether slide `index` is drawn selected: the current slide or one of the selected slides.
    public static func isSelected(_ st: DocState, _ index: Int) -> Bool {
        guard st.selection.target == .slides else { return false }
        if index == st.selection.slide { return true }
        guard let id = st.doc.slides.at(index)?.id else { return false }
        return st.selection.slides.contains(id)
    }

    /// Whether a slide has a transition or animations (the navigator's star).
    public static func hasAnimation(_ s: Slide) -> Bool {
        !s.animations.isEmpty || (s.transition.map { $0.kind != "none" } ?? false)
    }
}

// MARK: New Window (`doc_window.rs`)

/// The extra window: the presentation it shows (by uid) and its own slide.
public struct DocWindowState: Equatable, Sendable {
    public var uid: UInt64
    public var slide: Int
    public init(uid: UInt64, slide: Int) {
        self.uid = uid
        self.slide = slide
    }
}

public enum DocWindowLogic {
    /// `window_title`.
    public static func title(_ name: String) -> String { "\(name):2" }

    /// `shift`: `slide` moved by `delta`, kept within the deck.
    public static func shift(_ slide: Int, _ delta: Int64, _ n: Int) -> Int {
        if n <= 0 { return 0 }
        let last = Int64(n - 1)
        let (sum, overflow) = Int64(clamping: slide).addingReportingOverflow(delta)
        let v = overflow ? (delta < 0 ? 0 : last) : Swift.min(Swift.max(sum, 0), last)
        return Int(v)
    }

    /// `command` (`view.newWindow`): `{on: false}` closes the window; `{slide}` or `{delta}` move only that
    /// window. Returns the new state (nil = closed) and the answer.
    public static func command(_ p: JSON, current: DocWindowState?, active: DocState?) -> Result<(DocWindowState?, JSON), CommandError> {
        if p["on"]?.asBool == false { return .success((nil, ["open": false])) }
        guard let st = active else { return .failure("New Window needs an open presentation") }
        let n = st.doc.slides.count
        if n == 0 { return .failure("New Window needs a slide") }
        let uid = st.uid
        var slide = current.flatMap { $0.uid == uid ? $0.slide : nil } ?? Swift.min(st.selection.slide, n - 1)
        if let i = p["slide"]?.asU64 { slide = Int(clamping: i) }
        if let d = p["delta"]?.asI64 { slide = shift(slide, d, n) }
        if slide >= n { slide = n - 1 }
        let answer: JSON = [
            "open": true, "window": 2, "slide": .integer(slide), "slides": .integer(n), "title": .string(title(st.displayTitle)),
        ]
        return .success((DocWindowState(uid: uid, slide: slide), answer))
    }
}

// MARK: Status bar (`status.rs`)

public enum StatusLogic {
    /// The slide counter: "Slide n of m", or "Slide Master" in a master view.
    public static func slideText(_ st: DocState) -> String {
        let n = st.doc.slides.count
        switch st.selection.target {
        case .slides: return L10n.text("Slide \(Swift.min(st.selection.slide + 1, Swift.max(n, 1))) of \(n)")
        case .master, .layout: return L10n.text("Slide Master")
        case .handout: return L10n.text("Handout Master")
        case .notesMaster: return L10n.text("Notes Master")
        }
    }

    /// `selected_language`: the proofing language of the text at the caret, else of the first selected
    /// shape's first run, and whether that text is marked not to be checked.
    public static func selectedLanguage(_ st: DocState?) -> (lang: String, noProof: Bool) {
        guard let st else { return ("en-US", false) }
        func run(_ sh: Shape, _ at: TextPoint?) -> RunProps? {
            guard let t = sh.text else { return nil }
            if let at {
                guard let para = t.paragraphs.at(at.para) else { return nil }
                var n = 0
                for r in para.runs {
                    n += r.charLen
                    if at.char <= n { return r.props }
                }
                return para.runs.last?.props
            }
            return t.paragraphs.lazy.flatMap(\.runs).first?.props
        }
        let props: RunProps?
        if let t = st.selection.text, !t.notes, t.cell == nil {
            props = st.shape(t.shape).flatMap { run($0, t.caret) }
        } else {
            props = st.selection.shapes.first.flatMap { st.shape($0) }.flatMap { run($0, nil) }
        }
        return (props?.lang ?? "en-US", props?.noProof == true)
    }

    /// A language tag's name ("English (United States)"), or the tag when the system has none.
    public static func languageName(_ tag: String, locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: tag) ?? tag
    }

    /// The zoom slider's range (`status.rs`: 10 %–400 %, logarithmic), as the slider's own value.
    public static let sliderRange: ClosedRange<Double> = log(UiState.zoomRange.lowerBound) ... log(UiState.zoomRange.upperBound)

    /// The slider position for a zoom (1 = 100 %).
    public static func sliderValue(_ zoom: Double) -> Double {
        let z = zoom.isFinite ? Swift.min(Swift.max(zoom, UiState.zoomRange.lowerBound), UiState.zoomRange.upperBound) : 1
        return log(z)
    }

    /// The zoom percentage for a slider position.
    public static func percent(_ slider: Double) -> Double {
        let v = slider.isFinite ? Swift.min(Swift.max(slider, sliderRange.lowerBound), sliderRange.upperBound) : 0
        return (exp(v) * 100).rounded()
    }

    /// The Slide Sorter's thumbnail size range (`sorter_zoom`, 0.5–3).
    public static let sorterZoomRange: ClosedRange<Double> = 0.5 ... 3

    /// Spelling problems on the current slide (shapes and notes), for the status bar's proofing mark.
    public static func spellingIssues(_ slide: Slide, _ defaultLang: String = "en-US", limit: Int = 100) -> Int {
        var n = 0
        func check(_ paras: [Paragraph]) {
            for p in paras where n < limit && !p.isEmpty { n += Spell.misspelt(p, defaultLang, []).count }
        }
        func walk(_ shapes: [Shape], _ depth: Int) {
            guard depth < 32 else { return }
            for sh in shapes where n < limit {
                if let t = sh.text { check(t.paragraphs) }
                walk(sh.children, depth + 1)
            }
        }
        walk(slide.shapes, 0)
        check(slide.notes.paragraphs)
        return Swift.min(n, limit)
    }
}

// MARK: Outline view (`outline_pane`)

/// One slide in the outline: its title (and the shape holding it) and its other text, a block per shape.
public struct OutlineEntry: Equatable, Sendable {
    public var index: Int
    public var slide: SlideId
    public var title: String
    public var titleShape: ShapeId?
    public var bodies: [(shape: ShapeId, text: String)]

    public static func == (a: OutlineEntry, b: OutlineEntry) -> Bool {
        a.index == b.index && a.slide == b.slide && a.title == b.title && a.titleShape == b.titleShape
            && a.bodies.map(\.shape) == b.bodies.map(\.shape) && a.bodies.map(\.text) == b.bodies.map(\.text)
    }
}

public enum OutlineLogic {
    /// `outline_slide`'s content for slide `index`: the title placeholder's text and each other shape's
    /// non-empty text, one line per paragraph with a tab per level (what `text.set` reads back).
    public static func entry(_ doc: Presentation, _ index: Int) -> OutlineEntry? {
        guard let s = doc.slides.at(index) else { return nil }
        let isTitle: (Shape) -> Bool = { $0.phType?.isTitle == true }
        let titleShape = s.shapes.first(where: isTitle)?.id
        var bodies: [(ShapeId, String)] = []
        for sh in s.shapes where !isTitle(sh) {
            guard let tb = sh.text, !tb.isEmpty else { continue }
            bodies.append((sh.id, bodyText(tb)))
        }
        return OutlineEntry(index: index, slide: s.id, title: s.title, titleShape: titleShape, bodies: bodies)
    }

    /// A text body as outline text: paragraphs on lines, a tab per indent level.
    public static func bodyText(_ tb: TextBody) -> String {
        tb.paragraphs.map { String(repeating: "\t", count: Int($0.level)) + $0.text }.joined(separator: "\n")
    }

    /// `outline_estimate`: a slide's outline height before it has been laid out (title row plus a line per
    /// paragraph), in points.
    public static func estimate(_ s: Slide) -> Double {
        let lines = s.shapes.filter { $0.phType?.isTitle != true }.compactMap(\.text).filter { !$0.isEmpty }
            .reduce(0) { $0 + Swift.max($1.paragraphs.count, 1) }
        return 30 + Double(lines) * 19
    }
}

// MARK: Thumbnails

/// Thumbnails by slide, each kept with the slide and master values it was drawn from, so an edit (to the
/// slide or its master) is seen without comparing pixels (`textures.rs`' `thumb`, keyed by value rather
/// than by `Arc` address). At most `limit` entries; the least recently used `evict` go first.
public final class ThumbCache<Image> {
    struct Entry {
        var slide: Slide
        var master: Master?
        var width: Int
        var image: Image
        var stamp: UInt64
    }

    private var entries: [SlideId: Entry] = [:]
    private var clock: UInt64 = 0
    public let limit: Int
    public let evict: Int
    /// Thumbnails drawn so far (`thumb_renders`).
    public private(set) var renders: UInt64 = 0

    public init(limit: Int = 600, evict: Int = 200) {
        self.limit = Swift.max(1, limit)
        self.evict = Swift.min(Swift.max(1, evict), self.limit)
    }

    /// Thumbnails held (`thumb_count`).
    public var count: Int { entries.count }

    /// The thumbnail of `slide` drawn `width` pixels wide with `master`: `fresh` when it is up to date,
    /// otherwise the stale image (if any) to show while a new one is drawn.
    public func lookup(_ slide: Slide, master: Master?, width: Int) -> (image: Image?, fresh: Bool) {
        clock &+= 1
        guard var e = entries[slide.id] else { return (nil, false) }
        e.stamp = clock
        entries[slide.id] = e
        let fresh = e.width == width && e.slide == slide && e.master == master
        return (e.image, fresh)
    }

    /// Keep a thumbnail drawn from `slide` and `master`.
    public func store(_ image: Image, slide: Slide, master: Master?, width: Int) {
        clock &+= 1
        renders &+= 1
        entries[slide.id] = Entry(slide: slide, master: master, width: width, image: image, stamp: clock)
        if entries.count > limit {
            let oldest = entries.sorted { $0.value.stamp < $1.value.stamp }.prefix(evict).map(\.key)
            for k in oldest { entries.removeValue(forKey: k) }
        }
    }

    public func removeAll() { entries.removeAll() }
}
