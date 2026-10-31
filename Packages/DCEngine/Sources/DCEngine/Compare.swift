// DCEngine — Review › Compare: the differences between the open presentation and a revised copy of it,
// slide by slide, and accepting a revised slide into the open one or rejecting it.
// Port of deckcraft crates/engine/src/compare.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). The data types were declared by the core (`DocState` holds a `Compare`); the diff,
// `ChangeKey.of`, accept and reject follow them (the text agent, Wave 4).
import DCCore
import DCGeometry
import DCModel

/// The revised presentation a document is being compared with.
public struct Compare {
    public var name: String
    public var revised: DocRef
    /// Slides match by position (the decks shared no slide id when the compare started); fixed for the
    /// session so accepting slides doesn't switch the matching half way.
    public var byPosition: Bool
    /// Revisions rejected: no longer listed and never accepted, the open deck left as it is.
    public var rejected: Set<ChangeKey>

    public init(name: String, revised: DocRef, byPosition: Bool, rejected: Set<ChangeKey> = []) {
        self.name = name
        self.revised = revised
        self.byPosition = byPosition
        self.rejected = rejected
    }
}

/// What a revision is about, stable while slides move: the open slide (for changed and deleted) and the
/// revised slide (for changed and inserted).
public struct ChangeKey: Sendable, Hashable {
    public var kind: ChangeKind
    public var open: SlideId?
    public var revised: Int?

    public init(kind: ChangeKind, open: SlideId?, revised: Int?) {
        self.kind = kind
        self.open = open
        self.revised = revised
    }
}

public enum ChangeKind: String, Sendable, Hashable {
    /// Only in the revised deck.
    case inserted
    /// Only in the open deck.
    case deleted
    /// In both, different.
    case changed
}

// MARK: - The diff, accepting and rejecting (the rest of compare.rs)

extension ChangeKey {
    /// The key of `change`, a revision of `doc` (`ChangeKey::of`).
    public static func of(_ doc: Presentation, _ change: Change) -> ChangeKey {
        let open: SlideId? = switch change.kind {
        case .inserted: nil
        case .changed, .deleted: doc.slides.at(change.slide)?.id
        }
        return ChangeKey(kind: change.kind, open: open, revised: change.revised)
    }
}

/// One slide-level revision.
public struct Change: Sendable, Equatable {
    public var kind: ChangeKind
    /// Index in the open deck (for inserted: where it would go).
    public var slide: Int
    /// The editor's number of that slide (`slide` + 1).
    public var number: Int
    /// Which side has it alone: `deck` (the open presentation; accepting deletes it) or `file` (the
    /// compared file; accepting adds it). Absent when both have it and differ.
    public var onlyIn: String?
    /// Index in the revised deck (none for deleted).
    public var revised: Int?
    /// What differs, readable: `Title 1: text`, `Picture 3 inserted`, `notes`…
    public var details: [String]

    public init(kind: ChangeKind, slide: Int, number: Int, onlyIn: String?, revised: Int?, details: [String]) {
        self.kind = kind
        self.slide = slide
        self.number = number
        self.onlyIn = onlyIn
        self.revised = revised
        self.details = details
    }

    /// serde's `Change` (camelCase; `onlyIn` left out when absent).
    public func toJSON() -> JSON {
        var o: JSON = [
            "kind": .string(kind.rawValue), "slide": .integer(slide), "number": .integer(number),
            "revised": revised.map { JSON.integer($0) } ?? .null, "details": .array(details.map(JSON.string)),
        ]
        if let onlyIn, case .object(var obj) = o {
            obj.set("onlyIn", .string(onlyIn))
            o = .object(obj)
        }
        return o
    }
}

/// Review › Compare: the differences between the open presentation and a revised copy of it, slide by
/// slide, and accepting a revised slide into the open one. Slides match by id (a revised copy of the same
/// deck keeps them); when the two decks share no slide id at all, by position. Shapes match by id, then by
/// name.
public enum Comparing {
    static let maxDetails = 50

    /// The revisions still to review: `diff` without the rejected ones (`pending`).
    public static func pending(_ doc: Presentation, _ c: Compare) -> [Change] {
        diff(doc, c.revised.value, c.byPosition).filter { !isRejected(doc, c, $0) }
    }

    /// Whether `ch` was rejected. Positional matching re-pairs slides by index when the open deck gains or
    /// loses a slide; the revised index stays put, so any rejected key for the same revised slide counts.
    static func isRejected(_ doc: Presentation, _ c: Compare, _ ch: Change) -> Bool {
        if c.rejected.contains(ChangeKey.of(doc, ch)) { return true }
        if !c.byPosition { return false }
        switch ch.kind {
        case .deleted:
            let open = doc.slides.at(ch.slide)?.id
            return open != nil && c.rejected.contains { $0.open == open }
        default:
            return ch.revised != nil && c.rejected.contains { $0.revised == ch.revised }
        }
    }

    /// Whether `cur` and `rev` share no slide id (then slides match by position).
    public static func unrelated(_ cur: Presentation, _ rev: Presentation) -> Bool {
        let ids = Set(rev.slides.map(\.id))
        return !cur.slides.contains { ids.contains($0.id) }
    }

    /// Slide pairs (open index, revised index).
    static func pairs(_ cur: Presentation, _ rev: Presentation, _ byPosition: Bool) -> [(Int, Int)] {
        if byPosition { return (0 ..< min(cur.slides.count, rev.slides.count)).map { ($0, $0) } }
        var revIds: [SlideId: Int] = [:]
        for (i, s) in rev.slides.enumerated() { revIds[s.id] = i }
        return cur.slides.enumerated().compactMap { i, s in revIds[s.id].map { (i, $0) } }
    }

    public static func diff(_ cur: Presentation, _ rev: Presentation, _ byPosition: Bool) -> [Change] {
        let pairs = pairs(cur, rev, byPosition)
        let curMatched = Set(pairs.map(\.0))
        let revMatched = Set(pairs.map(\.1))
        var out: [Change] = []
        for (i, j) in pairs {
            guard let a = cur.slides.at(i), let b = rev.slides.at(j) else { continue }
            let details = slideDetails(cur, a, rev, b)
            if !details.isEmpty { out.append(Change(kind: .changed, slide: i, number: i &+ 1, onlyIn: nil, revised: j, details: details)) }
        }
        for (i, s) in cur.slides.enumerated() where !curMatched.contains(i) {
            out.append(Change(kind: .deleted, slide: i, number: i &+ 1, onlyIn: "deck", revised: nil, details: [slideTitle(s)]))
        }
        for (j, s) in rev.slides.enumerated() where !revMatched.contains(j) {
            // After the open slide that matches the revised slide before it.
            let at = (0 ..< j).reversed().lazy.compactMap { k in pairs.first { $0.1 == k }.map { $0.0 + 1 } }.first ?? 0
            out.append(Change(kind: .inserted, slide: at, number: at &+ 1, onlyIn: "file", revised: j, details: [slideTitle(s)]))
        }
        // A stable sort, as Rust's `sort_by_key`.
        return out.enumerated().sorted { x, y in
            let kx = (x.element.slide, x.element.revised ?? 0)
            let ky = (y.element.slide, y.element.revised ?? 0)
            return kx != ky ? kx < ky : x.offset < y.offset
        }.map(\.element)
    }

    static func slideTitle(_ s: Slide) -> String {
        let t = s.shapes.first { $0.ph.map { $0.kind == .title || $0.kind == .ctrTitle } ?? false }?.text?.text ?? ""
        let trimmed = String(rustTrim(t))
        return trimmed.isEmpty ? "Untitled slide" : String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(60)))
    }

    static func shapeLabel(_ s: Shape) -> String {
        rustTrim(s.name).isEmpty ? "Shape \(s.id.rawValue)" : s.name
    }

    /// A shape without its ids, for comparing across decks.
    static func plainShape(_ s: Shape) -> Shape {
        var c = s
        func rec(_ sh: inout Shape, _ depth: Int) {
            sh.id = ShapeId(0)
            if depth < 64 { sh.mutateChildren { for i in $0.indices { rec(&$0[i], depth + 1) } } }
        }
        rec(&c, 0)
        return c
    }

    /// The box a shape is drawn with: its own, else the one it inherits from its layout or master
    /// placeholder (`ctx`).
    static func drawnBox(_ ctx: Resolve.Ctx?, _ s: Shape) -> Xfrm? {
        s.xfrm ?? ctx.map { Resolve.xfrm($0, s) }
    }

    /// The rotation and flips a shape is drawn with (none without a box).
    static func turn(_ ctx: Resolve.Ctx?, _ s: Shape) -> (rot: Double, flipH: Bool, flipV: Bool) {
        drawnBox(ctx, s).map { ($0.rot, $0.flipH, $0.flipV) } ?? (0, false, false)
    }

    static func shapeDetails(_ cp: Presentation, _ ca: Resolve.Ctx?, _ a: Shape, _ rp: Presentation, _ cb: Resolve.Ctx?, _ b: Shape, _ out: inout [String]) {
        let label = shapeLabel(b)
        func text(_ s: Shape) -> String { s.text?.text ?? "" }
        var what: [String] = []
        if !rustEqual(text(a), text(b)) {
            what.append("text")
        } else if a.text != b.text {
            what.append("text formatting")
        }
        // Boxes as drawn: a stored box equal to the inherited one is no change.
        if let x = drawnBox(ca, a), let y = drawnBox(cb, b) {
            if (x.x != y.x || x.y != y.y) && (x.w == y.w && x.h == y.h) {
                what.append("moved")
            } else if x.w != y.w || x.h != y.h {
                what.append("resized")
            }
        }
        // Rotation and flips are reported alongside a move or resize, not hidden behind it. No stored
        // box means the inherited one (the layout's or master's), as the shape is drawn.
        let (ta, tb) = (turn(ca, a), turn(cb, b))
        if ta.rot != tb.rot { what.append("rotated") }
        if ta.flipH != tb.flipH || ta.flipV != tb.flipV { what.append("flipped") }
        if a.geom != b.geom { what.append("shape") }
        if a.fill != b.fill || a.line != b.line || a.style != b.style || a.effects != b.effects { what.append("formatting") }
        func pic(_ p: Presentation, _ s: Shape) -> [UInt8]? {
            if case .picture(let fill) = s.kind { return p.media(fill.media)?.data }
            return nil
        }
        if pic(cp, a) != pic(rp, b) { what.append("picture") }
        // Anything the checks above do not cover (alt text, hidden, a link…) is reported too, also beside
        // them: the fields they compared are left out of this comparison.
        var (x, y) = (plainShape(a), plainShape(b))
        func strip(_ z: inout Shape) {
            z.text = nil
            z.xfrm = nil
            z.geom = .default
            z.fill = nil
            z.line = nil
            z.style = nil
            z.effects = nil
        }
        strip(&x)
        strip(&y)
        if case .picture = x.kind, case .picture = y.kind {
            x.kind = .shape
            y.kind = .shape
        }
        if x != y { what.append("properties") }
        if !what.isEmpty { out.append("\(label): \(what.joined(separator: ", "))") }
    }

    static func slideDetails(_ cp: Presentation, _ a: Slide, _ rp: Presentation, _ b: Slide) -> [String] {
        var out: [String] = []
        var used = Set<Int>()
        let (ca, cb) = (Resolve.Ctx.forSlide(cp, a), Resolve.Ctx.forSlide(rp, b))
        for sa in a.shapes {
            let k = b.shapes.firstIndex { $0.id == sa.id }
                ?? b.shapes.indices.first { !used.contains($0) && b.shapes[$0].name == sa.name && !b.shapes[$0].name.isEmpty }
            if let k, !used.contains(k) {
                used.insert(k)
                if let sb = b.shapes.at(k) { shapeDetails(cp, ca, sa, rp, cb, sb, &out) }
            } else {
                out.append("\(shapeLabel(sa)) deleted (only in the deck)")
            }
        }
        for (k, sb) in b.shapes.enumerated() where !used.contains(k) {
            out.append("\(shapeLabel(sb)) inserted (only in the file)")
        }
        func order(_ s: Slide) -> [String] { s.shapes.map(\.name) }
        if out.isEmpty && order(a) != order(b) { out.append("order of objects") }
        func layoutName(_ p: Presentation, _ s: Slide) -> String? { p.layout(s.layout)?.layout.name }
        if layoutName(cp, a) != layoutName(rp, b) { out.append("layout") }
        if !rustEqual(a.notes.text, b.notes.text) { out.append("notes") }
        if a.transition != b.transition { out.append("transition") }
        let animDiffer = a.animations.count != b.animations.count || zip(a.animations, b.animations).contains { x, y in
            x.effect != y.effect || x.class != y.class || x.start != y.start || x.durationMs != y.durationMs || x.delayMs != y.delayMs
        }
        if animDiffer { out.append("animations") }
        if a.background != b.background { out.append("background") }
        if a.hidden != b.hidden { out.append(b.hidden ? "hidden" : "shown") }
        return Array(out.prefix(maxDetails))
    }

    static func maxShapeId(_ shapes: [Shape]) -> UInt32 {
        var m: UInt32 = 0
        walk(shapes) { s, _ in m = max(m, s.id.rawValue) }
        return m
    }

    /// The revised slide made to live in `doc`: its media copied over (remapped on an id clash), shape ids
    /// kept unless another slide of `doc` uses them (then fresh, animations following), and its layout
    /// matched by id, then by name, then the first layout. An error when `doc` has used every object id
    /// (#407) (`adopt`).
    public static func adopt(_ doc: inout Presentation, _ rev: Presentation, _ slide: Slide, _ replacing: SlideId?) throws -> Slide {
        var sl = slide
        // Media.
        var mediaMap: [MediaId: MediaId] = [:]
        for id in MediaRefs.slideMedia(sl) {
            guard let m = rev.media(id) else { continue }
            if let x = doc.media(id) {
                if x.data == m.data { continue }
                guard let new = doc.addMedia(m.name, m.contentType, m.data) else { throw Cmd.bad("review.accept", Cmd.noIdSpace) }
                mediaMap[id] = new
            } else {
                // Keeps the revision's id, so later ids must start past it.
                doc.media.append(m)
                doc.nextId = max(doc.nextId, id.rawValue)
            }
        }
        // Shape ids used elsewhere in the open deck.
        var taken = Set<UInt32>()
        for s in doc.slides where s.id != replacing {
            walk(s.shapes) { x, _ in taken.insert(x.id.rawValue) }
        }
        var idMap: [ShapeId: ShapeId] = [:]
        func rec(_ shapes: inout [Shape], _ depth: Int) throws {
            if depth > 64 { return }
            for i in shapes.indices {
                if taken.contains(shapes[i].id.rawValue) {
                    guard let n = doc.allocId() else { throw Cmd.bad("review.accept", Cmd.noIdSpace) }
                    let new = ShapeId(n)
                    idMap[shapes[i].id] = new
                    shapes[i].id = new
                }
                var failure: (any Error)?
                shapes[i].mutateChildren { kids in
                    do { try rec(&kids, depth + 1) } catch { failure = error }
                }
                if let failure { throw failure }
            }
        }
        try rec(&sl.shapes, 0)
        MediaRefs.VisitMut.slide(&sl) { m in
            if let n = mediaMap[m] { m = n }
        }
        for i in sl.animations.indices {
            if let n = idMap[sl.animations[i].shape] { sl.animations[i].shape = n }
            if let t = sl.animations[i].trigger, let n = idMap[t] { sl.animations[i].trigger = n }
        }
        doc.nextId = max(doc.nextId, maxShapeId(sl.shapes))
        // Layout.
        if doc.layout(sl.layout) == nil {
            let name = rev.layout(slide.layout)?.layout.name
            let byName = name.flatMap { n in doc.masters.lazy.flatMap(\.layouts).first { $0.name == n }?.id }
            sl.layout = byName ?? doc.masters.first?.layouts.first?.id ?? LayoutId(0)
        }
        // A placeholder without a box of its own is drawn with its layout's; where this deck's layout
        // draws it otherwise (placed or turned differently), the file's box is stored on it, so the
        // accepted slide looks as the file does and compares equal to it.
        if let file = Resolve.Ctx.forSlide(rev, slide), let here = Resolve.Ctx.forSlide(doc, sl) {
            let boxes: [Xfrm?] = zip(slide.shapes, sl.shapes).map { f, h in
                let want = Resolve.xfrm(file, f)
                return h.xfrm == nil && Resolve.xfrm(here, h) != want ? want : nil
            }
            for (i, b) in zip(sl.shapes.indices, boxes) where b != nil { sl.shapes[i].xfrm = b }
        }
        if let id = replacing {
            sl.id = id
        } else {
            if doc.slides.contains(where: { $0.id == sl.id }) || sl.id.rawValue == 0 {
                guard let n = doc.allocId() else { throw Cmd.bad("review.accept", Cmd.noIdSpace) }
                sl.id = SlideId(n)
            }
            doc.nextId = max(doc.nextId, sl.id.rawValue)
        }
        return sl
    }

    /// Apply `change` (from `diff` of `doc` against `rev`) to `doc`. Returns the slide index to show (nil
    /// when the change no longer applies) (`accept`).
    public static func accept(_ doc: inout Presentation, _ rev: Presentation, _ change: Change) throws -> Int? {
        switch change.kind {
        case .changed:
            guard let b = change.revised.flatMap({ rev.slides.at($0) }), let id = doc.slides.at(change.slide)?.id else { return nil }
            let sl = try adopt(&doc, rev, b, id)
            guard doc.slides.indices.contains(change.slide) else { return nil }
            doc.slides[change.slide] = sl
            return change.slide
        case .inserted:
            guard let b = change.revised.flatMap({ rev.slides.at($0) }) else { return nil }
            let sl = try adopt(&doc, rev, b, nil)
            let at = min(change.slide, doc.slides.count)
            doc.slides.insert(sl, at: at)
            return at
        case .deleted:
            if change.slide >= doc.slides.count || doc.slides.count <= 1 { return nil }
            doc.slides.remove(at: change.slide)
            return min(change.slide, max(doc.slides.count - 1, 0))
        }
    }
}
