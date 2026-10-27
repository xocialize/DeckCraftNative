// DCModel — the DeckCraft document model's behaviour: shapes, slides, masters and the presentation.
// Port of deckcraft crates/model/src/lib.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). The types themselves are generated into Types.generated.swift.
//
// A `Presentation` has slide masters (each with a theme and layouts) and slides. Each slide uses a
// layout; placeholders on a slide inherit position, formatting and text styles from the matching
// placeholder on its layout and master (`Resolve.swift`). Swift arrays of value types give the
// copy-on-write sharing deckcraft gets from `Arc`, so an undo snapshot copies only what changed.
import DCColor
import DCCore
import DCGeometry

public enum ModelError: Error, Sendable, Equatable, CustomStringConvertible {
    case noSlide(String)
    case noShape(ShapeId)
    case noLayout(LayoutId)
    case invalid(String)

    public var description: String {
        switch self {
        case .noSlide(let s): "no slide \(s)"
        case .noShape(let id): "no shape \(id)"
        case .noLayout(let id): "no layout \(id)"
        case .invalid(let s): s
        }
    }
}

/// Recursion bound for walking group trees, as in deckcraft.
let maxShapeDepth = 64

extension PhType {
    public var xml: String {
        switch self {
        case .title: "title"
        case .ctrTitle: "ctrTitle"
        case .subTitle: "subTitle"
        case .body: "body"
        case .obj: "obj"
        case .chart: "chart"
        case .table: "tbl"
        case .clipArt: "clipArt"
        case .diagram: "dgm"
        case .media: "media"
        case .picture: "pic"
        case .date: "dt"
        case .footer: "ftr"
        case .slideNum: "sldNum"
        case .header: "hdr"
        case .slideImage: "sldImg"
        }
    }

    public static func fromXML(_ s: String) -> PhType {
        switch s {
        case "title": .title
        case "ctrTitle": .ctrTitle
        case "subTitle": .subTitle
        case "obj": .obj
        case "chart": .chart
        case "tbl": .table
        case "clipArt": .clipArt
        case "dgm": .diagram
        case "media": .media
        case "pic": .picture
        case "dt": .date
        case "ftr": .footer
        case "sldNum": .slideNum
        case "hdr": .header
        case "sldImg": .slideImage
        default: .body
        }
    }

    public var isTitle: Bool { self == .title || self == .ctrTitle }

    /// The prompt shown in an empty placeholder in Normal view.
    public var prompt: String {
        switch self {
        case .title, .ctrTitle: "Click to add title"
        case .subTitle: "Click to add subtitle"
        case .body, .obj: "Click to add text"
        case .chart: "Click icon to add chart"
        case .table: "Click icon to add table"
        case .diagram: "Click icon to add SmartArt graphic"
        case .media: "Click icon to add media"
        case .picture, .clipArt: "Click icon to add picture"
        case .date: "Date"
        case .footer: "Footer"
        case .slideNum: "‹#›"
        case .header: "Header"
        case .slideImage: ""
        }
    }

    /// Footer-row placeholders are not shown on slides unless the deck turns them on.
    public var isFooterKind: Bool { [.date, .footer, .slideNum, .header].contains(self) }
}

extension Geom {
    public static var `default`: Geom { .preset(name: "rect", adj: []) }

    public static func preset(_ name: String) -> Geom { .preset(name: name, adj: []) }

    public var presetName: String? {
        if case .preset(let name, _) = self { return name }
        return nil
    }
}

extension CustomPath {
    public static var `default`: CustomPath { CustomPath(w: 0, h: 0, d: "", fill: .norm, stroke: true) }
}

/// True when every sample is the placeholder `0.5` written before a device reported pressure. Those
/// strokes were drawn at `InkStroke.width` and still are.
public func inkPressureIsLegacy(_ points: [Triple<Double, Double, Float>]) -> Bool {
    !points.isEmpty && points.allSatisfy { Swift.abs($0.c - 0.5) <= 1.0e-3 }
}

/// Width of one ink sample. `pressure` of 1 is the pen width. A legacy flat stroke (`legacy`) draws at
/// the pen width. A missing reading draws at the pen width too. A light touch stays visible (at least
/// 8% of the pen).
public func inkSampleWidth(_ pen: Double, _ pressure: Float, _ legacy: Bool) -> Double {
    let pen = pen.isFinite ? Swift.abs(pen) : 0.0
    if legacy { return pen }
    let p = pressure.isFinite ? pressure.clamped(0.08, 1.0) : 1.0
    return pen * Double(p)
}

extension Shape {
    public static var `default`: Shape {
        Shape(
            id: ShapeId(0), name: "", xfrm: nil, kind: .shape, geom: .default, ph: nil, fill: nil, line: nil,
            effects: nil, style: nil, text: nil, hidden: false, locked: false, textBox: false, descr: "", title: "",
            decorative: false, click: nil, hover: nil, tags: [], rawExt: nil, diagram: nil
        )
    }

    /// A stand-in shape for laying out one table cell's `body`: a table, so the cell's text takes the
    /// master's other-text style as PowerPoint's does.
    public static func tableCell(_ body: TextBody) -> Shape {
        var s = Shape.default
        s.text = body
        s.kind = .table(.default)
        return s
    }

    public var isPlaceholder: Bool { ph != nil }
    public var phType: PhType? { ph?.kind }

    public var isGroup: Bool {
        if case .group = kind { return true }
        return false
    }

    public var children: [Shape] {
        if case .group(let children, _) = kind { return children }
        return []
    }

    /// Changes a group's children in place; nil (and no change) when this isn't a group.
    @discardableResult
    public mutating func mutateChildren<R>(_ body: (inout [Shape]) throws -> R) rethrows -> R? {
        guard case .group(var children, let child) = kind else { return nil }
        kind = .shape // release the payload so `children` is uniquely referenced while it changes
        defer { kind = .group(children: children, child: child) }
        return try body(&children)
    }

    /// Is this a line-like shape (no area)?
    public var isLine: Bool {
        if case .connector = kind { return true }
        return geom.presetName.map(Preset.isLineLike) ?? false
    }

    public var kindName: String {
        switch kind {
        case .shape where ph != nil: "placeholder"
        case .shape where textBox: "textBox"
        case .shape: "shape"
        case .picture: "picture"
        case .group: "group"
        case .connector: "connector"
        case .table: "table"
        case .chart: "chart"
        case .media(let m) where m.video: "video"
        case .media: "audio"
        case .ink: "ink"
        case .model3d: "model"
        case .opaque: "object"
        }
    }
}

/// Walk shapes depth-first (groups included), with each shape's depth.
public func walk(_ shapes: [Shape], _ f: (Shape, Int) throws -> Void) rethrows {
    func rec(_ shapes: [Shape], _ depth: Int) throws {
        if depth > maxShapeDepth { return }
        for s in shapes {
            try f(s, depth)
            try rec(s.children, depth + 1)
        }
    }
    try rec(shapes, 0)
}

public func findShape(_ shapes: [Shape], _ id: ShapeId) -> Shape? {
    func rec(_ shapes: [Shape], _ depth: Int) -> Shape? {
        if depth > maxShapeDepth { return nil }
        for s in shapes {
            if s.id == id { return s }
            if let f = rec(s.children, depth + 1) { return f }
        }
        return nil
    }
    return rec(shapes, 0)
}

/// The index path to shape `id`: its index in `shapes`, then in each group down to it.
public func shapePath(_ shapes: [Shape], _ id: ShapeId) -> [Int]? {
    func rec(_ shapes: [Shape], _ depth: Int) -> [Int]? {
        if depth > maxShapeDepth { return nil }
        for (i, s) in shapes.enumerated() {
            if s.id == id { return [i] }
            if let sub = rec(s.children, depth + 1) { return [i] + sub }
        }
        return nil
    }
    return rec(shapes, 0)
}

/// Runs `body` on the list that `path` (all but its last index) leads to.
private func mutateList<R>(_ shapes: inout [Shape], _ path: ArraySlice<Int>, _ body: (inout [Shape]) throws -> R) rethrows -> R? {
    guard let first = path.first else { return try body(&shapes) }
    guard shapes.indices.contains(first) else { return nil }
    return try shapes[first].mutateChildren { try mutateList(&$0, path.dropFirst(), body) } ?? nil
}

/// deckcraft's `find_shape_mut`: runs `body` on the shape `id` in place; nil when there's none.
@discardableResult
public func mutateShape<R>(_ shapes: inout [Shape], _ id: ShapeId, _ body: (inout Shape) throws -> R) rethrows -> R? {
    guard let path = shapePath(shapes, id), let last = path.last else { return nil }
    return try mutateList(&shapes, path.dropLast()[...]) { list in
        list.indices.contains(last) ? try body(&list[last]) : nil
    } ?? nil
}

/// deckcraft's `sibling_list_mut`: runs `body` on the list holding `id` among its siblings — the tree's
/// top level, or a group's children; nil when `id` isn't in the tree.
@discardableResult
public func mutateSiblings<R>(_ shapes: inout [Shape], _ id: ShapeId, _ body: (inout [Shape]) throws -> R) rethrows -> R? {
    guard let path = shapePath(shapes, id) else { return nil }
    return try mutateList(&shapes, path.dropLast()[...], body)
}

/// The group directly holding `id`: `.some(nil)` for a top-level shape, nil when absent.
public func parentOf(_ shapes: [Shape], _ id: ShapeId) -> ShapeId?? {
    func rec(_ shapes: [Shape], _ parent: ShapeId?, _ depth: Int) -> ShapeId?? {
        if depth > maxShapeDepth { return nil }
        for s in shapes {
            if s.id == id { return .some(parent) }
            if let f = rec(s.children, s.id, depth + 1) { return f }
        }
        return nil
    }
    return rec(shapes, nil, 0)
}

extension Slide {
    public static var `default`: Slide {
        Slide(
            id: SlideId(0), layout: LayoutId(0), name: "", shapes: [], background: nil, hidden: false,
            showMasterShapes: true, transition: nil, animations: [], notes: .default, comments: [],
            colorMap: nil, tags: [], rawExt: nil
        )
    }

    public func shape(_ id: ShapeId) -> Shape? { findShape(shapes, id) }

    @discardableResult
    public mutating func mutateShape<R>(_ id: ShapeId, _ body: (inout Shape) throws -> R) rethrows -> R? {
        try DCModel.mutateShape(&shapes, id, body)
    }

    /// The slide's title text (first title placeholder), for thumbnails, outline and navigation.
    public var title: String {
        shapes.first { $0.phType?.isTitle ?? false }?.text.map { $0.text.replacingOccurrences(of: "\u{0B}", with: " ") } ?? ""
    }

    public var notesText: String { notes.text }
}

extension LayoutType {
    public var xml: String {
        switch self {
        case .title: "title"
        case .titleAndContent: "obj"
        case .sectionHeader: "secHead"
        case .twoContent: "twoObj"
        case .comparison: "twoTxTwoObj"
        case .titleOnly: "titleOnly"
        case .blank: "blank"
        case .contentWithCaption: "objTx"
        case .pictureWithCaption: "picTx"
        case .titleAndVerticalText: "vertTx"
        case .verticalTitleAndText: "vertTitleAndTx"
        case .custom: "cust"
        }
    }

    public static func fromXML(_ s: String) -> LayoutType {
        switch s {
        case "title": .title
        case "obj", "tx": .titleAndContent
        case "secHead": .sectionHeader
        case "twoObj", "twoColTx": .twoContent
        case "twoTxTwoObj": .comparison
        case "titleOnly": .titleOnly
        case "blank": .blank
        case "objTx": .contentWithCaption
        case "picTx": .pictureWithCaption
        case "vertTx": .titleAndVerticalText
        case "vertTitleAndTx": .verticalTitleAndText
        default: .custom
        }
    }
}

extension Master {
    public func layout(_ id: LayoutId) -> Layout? { layouts.first { $0.id == id } }

    public func mapSlot(_ slot: SchemeSlot) -> SchemeSlot { DCModel.mapSlot(colorMap, slot) }

    public var scheme: ColorScheme { scheme(with: colorMap) }

    public func scheme(with map: [Pair<String, String>]) -> ColorScheme {
        var s = theme.colors
        if map.isEmpty { return s }
        let base = theme.colors
        for (alias, slot) in [(SchemeSlot.bg1, SchemeSlot.lt1), (.tx1, .dk1), (.bg2, .lt2), (.tx2, .dk2)] {
            s.set(slot, base.get(DCModel.mapSlot(map, alias)))
        }
        return s
    }
}

public func mapSlot(_ map: [Pair<String, String>], _ slot: SchemeSlot) -> SchemeSlot {
    let key: String
    switch slot {
    case .bg1: key = "bg1"
    case .tx1: key = "tx1"
    case .bg2: key = "bg2"
    case .tx2: key = "tx2"
    default: return slot
    }
    if let v = map.first(where: { $0.a == key }), let s = SchemeSlot.fromXML(v.b) { return s }
    switch slot {
    case .bg1: return .lt1
    case .tx1: return .dk1
    case .bg2: return .lt2
    default: return .dk2
    }
}

extension ShowSettings {
    public static var `default`: ShowSettings {
        ShowSettings(
            showType: "speaker", loopUntilEsc: false, withoutNarration: false, withoutAnimation: false,
            useTimings: true, range: nil, customShow: nil, penColor: .rgb(0xFF, 0x00, 0x00),
            laserColor: .rgb(0xFF, 0x00, 0x00), showMediaControls: true
        )
    }
}

extension EmbeddedFont {
    public var faces: [MediaId?] { [regular, bold, italic, boldItalic] }
}

/// deckcraft's `lenient_size`: a slide or notes size whose sides may be missing or not numbers
/// (each such side reads as NaN, which the format's checks then repair). An absent key keeps the
/// presentation's default.
func lenientSize(_ json: JSON?, default fallback: Size) throws(JSONDecodeError) -> Size {
    guard let json else { return fallback }
    func side(_ k: String) -> Double {
        switch json[k] {
        case .double(let d): d
        case .float(let f): Double(f)
        case .uint(let u): Double(u)
        case .int(let i): Double(i)
        default: .nan
        }
    }
    return Size(side("width"), side("height"))
}

extension Presentation {
    public static var `default`: Presentation { newPresentation(nil) }

    public mutating func allocId() -> UInt32? {
        let (next, overflow) = Swift.max(nextId, 1).addingReportingOverflow(1)
        if overflow { return nil }
        nextId = next
        return next
    }

    public mutating func fixNextId() {
        var m = nextId
        for s in slides {
            m = Swift.max(m, s.id.rawValue)
            walk(s.shapes) { sh, _ in m = Swift.max(m, sh.id.rawValue) }
        }
        for ma in masters {
            m = Swift.max(m, ma.id.rawValue)
            walk(ma.shapes) { sh, _ in m = Swift.max(m, sh.id.rawValue) }
            for l in ma.layouts {
                m = Swift.max(m, l.id.rawValue)
                walk(l.shapes) { sh, _ in m = Swift.max(m, sh.id.rawValue) }
            }
        }
        for md in media { m = Swift.max(m, md.id.rawValue) }
        for extra in [notesMaster, handoutMaster].compactMap({ $0 }) {
            m = Swift.max(m, extra.id.rawValue)
            walk(extra.shapes) { sh, _ in m = Swift.max(m, sh.id.rawValue) }
        }
        nextId = m
    }

    public func slideIndex(_ id: SlideId) -> Int? { slides.firstIndex { $0.id == id } }
    public func slide(_ id: SlideId) -> Slide? { slides.first { $0.id == id } }

    @discardableResult
    public mutating func mutateSlide<R>(_ id: SlideId, _ body: (inout Slide) throws -> R) rethrows -> R? {
        guard let i = slideIndex(id) else { return nil }
        return try body(&slides[i])
    }

    public func slide(at i: Int) -> Slide? { slides.at(i) }

    public func layout(_ id: LayoutId) -> (master: Master, layout: Layout)? {
        for m in masters {
            if let l = m.layout(id) { return (m, l) }
        }
        return nil
    }

    public func masterFor(_ slide: Slide) -> (master: Master, layout: Layout?)? {
        if let (m, l) = layout(slide.layout) { return (m, l) }
        return masters.first.map { ($0, $0.layouts.first) }
    }

    public var firstMaster: Master? { masters.first }

    public func media(_ id: MediaId) -> MediaItem? { media.first { $0.id == id } }

    public mutating func addMedia(_ name: String, _ contentType: String, _ data: [UInt8]) -> MediaId? {
        if let m = media.first(where: { $0.data.count == data.count && $0.data == data }) { return m.id }
        guard let raw = allocId() else { return nil }
        let id = MediaId(raw)
        media.append(MediaItem(id: id, name: name, contentType: contentType, data: data, link: nil))
        return id
    }

    public func sectionOf(_ slide: SlideId) -> Int? { sections.firstIndex { $0.slides.contains(slide) } }

    public func slideNumber(_ index: Int) -> UInt32 {
        let i = UInt32(exactly: index) ?? .max
        let (v, overflow) = firstSlideNumber.addingReportingOverflow(i)
        return overflow ? .max : v
    }

    public func validate() -> [String] {
        var out: [String] = []
        var seen = Set<SlideId>()
        for s in slides {
            if !seen.insert(s.id).inserted { out.append("duplicate slide id \(s.id)") }
            if layout(s.layout) == nil { out.append("slide \(s.id) uses missing layout \(s.layout)") }
            var ids = Set<ShapeId>()
            walk(s.shapes) { sh, _ in
                if !ids.insert(sh.id).inserted { out.append("slide \(s.id): duplicate shape id \(sh.id)") }
            }
        }
        return out
    }
}
