// DCEngine — the engine façade: Session, documents, selection, undo history and preferences.
// Port of deckcraft crates/engine/src/lib.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors) at the commit in Tools/oracle/pin.env.
//
// Every user-visible action is a command with a stable id (`slide.new`, `shape.insert`, `text.insert`,
// `format.bold`…) and JSON parameters. The UI, the CLI, the control channel and MCP all go through
// `Session.execute`.
//
// `Arc<Presentation>` becomes `DocRef`, an immutable box: its identity (`===`) is what Rust's
// `Arc::ptr_eq` compares, so "the document changed" and "the document is saved" mean the same here.
import DCColor
import DCCore
import DCGeometry
import DCModel
import Foundation

// MARK: - Errors

public enum EngineError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case disabled(String, String)
    case badParams(cmd: String, msg: String)
    case noDocument
    case other(String)
    /// A password-protected file opened without its password (`file.open {password}`); the host asks for it.
    case passwordRequired(String)
    /// A password-protected file opened with a password that isn't its own.
    case wrongPassword(String)
    /// A failure the command didn't expect (Rust: a caught panic).
    case internalError(String, String)

    public var description: String {
        switch self {
        case .unknownCommand(let id): "unknown command `\(id)`"
        case .disabled(let id, let why): "command `\(id)` is not available right now: \(why)"
        case .badParams(let cmd, let msg): "invalid parameters for `\(cmd)`: \(msg)"
        case .noDocument: "no active presentation"
        case .other(let s): s
        case .passwordRequired(let name): "“\(name)” is password-protected: its password is needed to open it"
        case .wrongPassword(let name): "the password for “\(name)” is incorrect"
        case .internalError(let id, let msg): "internal error in `\(id)` (the presentation was kept as it was): \(msg)"
        }
    }

    /// Any error as an engine error: lower layers' errors become `.other` with their message.
    public static func from(_ e: any Error) -> EngineError {
        if let e = e as? EngineError { return e }
        return .other(String(describing: e))
    }
}

// MARK: - The shared presentation (Arc<Presentation>)

/// A presentation shared between the document, its undo steps and its saved state, as `Arc<Presentation>`
/// is in deckcraft. Identity is what matters: `a === b` is `Arc::ptr_eq`.
public final class DocRef: Sendable {
    public let value: Presentation
    public init(_ value: Presentation) { self.value = value }
}

// MARK: - Selection

/// A text position: (paragraph, char), compared as Rust compares the tuple.
public struct TextPoint: Sendable, Hashable, Comparable {
    public var para: Int
    public var char: Int
    public init(_ para: Int, _ char: Int) {
        self.para = para
        self.char = char
    }

    public static func < (a: TextPoint, b: TextPoint) -> Bool { (a.para, a.char) < (b.para, b.char) }
    public var tuple: TextPos { (para, char) }
    public func toJSON() -> JSON { .array([.integer(para), .integer(char)]) }
    static func from(_ j: JSON?) -> TextPoint? {
        guard let a = j?.asArray, a.count == 2, let p = a[0].asUsize, let c = a[1].asUsize else { return nil }
        return TextPoint(p, c)
    }
}

/// Text being edited in place: a shape's body (or a table cell, or the slide's notes).
public struct TextSel: Sendable, Equatable {
    public var shape: ShapeId
    /// Selection anchor and caret: (paragraph, char).
    public var anchor: TextPoint
    public var caret: TextPoint
    /// Editing a table cell (row, col).
    public var cell: TextPoint?
    /// Editing the slide's speaker notes (shape is ignored).
    public var notes: Bool
    /// The caret position that sits at the end of a wrapped line (after End) rather than at the start
    /// of the next line. Ignored once the caret moves anywhere else.
    public var lineEnd: TextPoint?

    public init(shape: ShapeId = .default, anchor: TextPoint = TextPoint(0, 0), caret: TextPoint = TextPoint(0, 0), cell: TextPoint? = nil, notes: Bool = false, lineEnd: TextPoint? = nil) {
        self.shape = shape
        self.anchor = anchor
        self.caret = caret
        self.cell = cell
        self.notes = notes
        self.lineEnd = lineEnd
    }

    public var isRange: Bool { anchor != caret }
    public var ordered: (TextPoint, TextPoint) { anchor <= caret ? (anchor, caret) : (caret, anchor) }
    /// Is the caret drawn at the end of the line before (upstream), not the start of the next?
    public var atLineEnd: Bool { lineEnd == caret }

    public func toJSON() -> JSON {
        var o = JSONObject()
        o.set("shape", shape.toJSON())
        o.set("anchor", anchor.toJSON())
        o.set("caret", caret.toJSON())
        if let c = cell { o.set("cell", c.toJSON()) }
        o.set("notes", .bool(notes))
        if let l = lineEnd { o.set("lineEnd", l.toJSON()) }
        return .object(o)
    }
}

/// Which shape tree is being edited: slides (normal), or a master/layout (Slide Master view).
public enum Target: Sendable, Hashable {
    case slides
    case master(master: Int)
    case layout(master: Int, layout: Int)
    /// The handout master (View ▸ Handout Master), a page at the notes size.
    case handout
    /// The notes master (View ▸ Notes Master), a page at the notes size.
    case notesMaster

    public static let `default` = Target.slides

    /// A notes-size master page (Handout or Notes Master view).
    public var isPageMaster: Bool { self == .handout || self == .notesMaster }

    public func toJSON() -> JSON {
        switch self {
        case .slides: ["kind": "slides"]
        case .master(let m): ["kind": "master", "master": .integer(m)]
        case .layout(let m, let l): ["kind": "layout", "master": .integer(m), "layout": .integer(l)]
        case .handout: ["kind": "handout"]
        case .notesMaster: ["kind": "notesMaster"]
        }
    }
}

/// Selected table cells: (table, (r0, c0), (r1, c1)).
public struct CellRange: Sendable, Equatable {
    public var table: ShapeId
    public var from: TextPoint
    public var to: TextPoint
    public init(_ table: ShapeId, _ from: TextPoint, _ to: TextPoint) {
        self.table = table
        self.from = from
        self.to = to
    }

    public func toJSON() -> JSON { .array([table.toJSON(), from.toJSON(), to.toJSON()]) }
}

public struct Selection: Sendable, Equatable {
    /// Current slide index.
    public var slide: Int = 0
    /// Slides selected in the thumbnail pane / sorter (includes the current one when non-empty).
    public var slides: [SlideId] = []
    /// Selected shapes on the current slide (top-level or inside groups).
    public var shapes: [ShapeId] = []
    public var text: TextSel?
    /// Selected table cells.
    public var cells: CellRange?
    /// Slide-list range last made with Shift-click: `(anchor, end)`, held as slide ids.
    public var rangeAnchor: (SlideId, SlideId)?
    public var target: Target = .slides

    public init() {}

    public static func == (a: Selection, b: Selection) -> Bool {
        a.slide == b.slide && a.slides == b.slides && a.shapes == b.shapes && a.text == b.text && a.cells == b.cells
            && a.rangeAnchor?.0 == b.rangeAnchor?.0 && a.rangeAnchor?.1 == b.rangeAnchor?.1 && a.target == b.target
    }

    /// serde's `Selection` (camelCase; `rangeAnchor` skipped when absent).
    public func toJSON() -> JSON {
        var o = JSONObject()
        o.set("slide", .integer(slide))
        o.set("slides", slides.toJSON())
        o.set("shapes", shapes.toJSON())
        o.set("text", text?.toJSON() ?? .null)
        o.set("cells", cells?.toJSON() ?? .null)
        if let (a, b) = rangeAnchor { o.set("rangeAnchor", .array([a.toJSON(), b.toJSON()])) }
        o.set("target", target.toJSON())
        return .object(o)
    }
}

// MARK: - History

/// The point type Edit Points remembered for a vertex: (shape, path, index, type).
public struct VertexKind: Sendable, Equatable {
    public var shape: ShapeId
    public var path: Int
    public var index: Int
    public var kind: String
    public init(_ shape: ShapeId, _ path: Int, _ index: Int, _ kind: String) {
        self.shape = shape
        self.path = path
        self.index = index
        self.kind = kind
    }
}

public struct HistoryEntry {
    public var label: String
    public var doc: DocRef
    public var selection: Selection
    /// The point type Edit Points remembered with `doc` (`ToolState.vertexKind`).
    public var vertexKind: VertexKind?

    public init(label: String, doc: DocRef, selection: Selection, vertexKind: VertexKind?) {
        self.label = label
        self.doc = doc
        self.selection = selection
        self.vertexKind = vertexKind
    }
}

public struct History {
    public var undo: [HistoryEntry] = []
    public var redo: [HistoryEntry] = []
    public var limit: Int = 0
    /// Most memory (estimated bytes) the undo steps may keep beyond the current document; 0 means
    /// `undoByteBudget`.
    public var byteLimit: Int = 0
    /// Estimated bytes each undo step keeps that the document after it doesn't share, by the step's
    /// document identity.
    public var costs: [ObjectIdentifier: Int] = [:]

    public init(limit: Int = 0, byteLimit: Int = 0) {
        self.limit = limit
        self.byteLimit = byteLimit
    }
}

/// A live pointer interaction: the document before it began (one undo step at the end).
public struct Interaction {
    public var label: String
    public var doc: DocRef
    public var selection: Selection
    /// The point type Edit Points remembered when it began.
    public var vertexKind: VertexKind?

    public init(label: String, doc: DocRef, selection: Selection, vertexKind: VertexKind?) {
        self.label = label
        self.doc = doc
        self.selection = selection
        self.vertexKind = vertexKind
    }
}

/// Text an input method is composing (#101): its preedit sits in the edited text body, at `start` for
/// `len` characters, until it is committed, replaced or cancelled. The presentation from before it
/// began makes the whole composition one undo step.
public struct Composition {
    /// Where the composed text starts: (paragraph, char).
    public var start: TextPoint
    /// Its length in characters (it never spans paragraphs).
    public var len: Int
    /// The part the input method is converting, relative to `start` (drawn with a thicker line).
    public var active: (Int, Int)?
    /// The formatting the composed text is typed with (as `text.insert` would choose).
    public var props: RunProps?
    /// The presentation and selection before the composition began.
    public var before: DocRef
    public var beforeSelection: Selection

    public init(start: TextPoint, len: Int, active: (Int, Int)?, props: RunProps?, before: DocRef, beforeSelection: Selection) {
        self.start = start
        self.len = len
        self.active = active
        self.props = props
        self.before = before
        self.beforeSelection = beforeSelection
    }
}

// MARK: - Documents

/// A document id unique across processes, not just within this one: recovery entries are named by it in
/// a folder every running instance shares. Ids are this process's random base plus a counter.
private let uidCounter = UIDCounter()

private final class UIDCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt64 = 0
    func take() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let v = next
        next &+= 1
        return v
    }
}

func nextUid() -> UInt64 {
    (Recovery.instanceId() &+ uidCounter.take()) & Recovery.uidMask
}

/// One open presentation with its selection and history. A class, as deckcraft hands out `&mut DocState`.
public final class DocState {
    public var docRef: DocRef
    public var selection: Selection
    public var history: History
    public var path: String?
    public var revision: UInt64
    public var savedDocRef: DocRef
    public var interaction: Interaction?
    public var uid: UInt64
    public var title: String
    /// Fonts the file's text uses that aren't installed, found when it was opened (empty for new
    /// documents); the app mentions them once.
    public var missingFonts: [String]
    /// An input method's composition in progress.
    public var composition: Composition?
    /// Review › Compare in progress: the revised copy.
    public var compare: Compare?
    /// The last Duplicate: where it happened and each original with its copy, so duplicating the copies
    /// again repeats how far they were moved, as in PowerPoint (#966).
    public var lastDuplicate: LastDuplicate?
    /// The list AutoFormat just started from a typed `* ` or `1. `, so Backspace right after can put the
    /// typed text back.
    public var autoList: AutoList?
    /// The password the file was opened with (Docs/plans/Legacy-PPT-and-Encryption.md §4.3). It lives only here, in
    /// memory: never in the presentation, a `.deckcraft`, AutoRecover, the journal or a command's reply.
    public var protection: DocProtection?

    public init(_ doc: Presentation, path: String?, title: String) {
        let r = DocRef(doc)
        docRef = r
        savedDocRef = r
        selection = Selection()
        history = History(limit: 500)
        self.path = path
        revision = 1
        interaction = nil
        uid = nextUid()
        self.title = title
        missingFonts = []
        composition = nil
        compare = nil
        lastDuplicate = nil
        autoList = nil
    }

    /// A copy (Rust's `Clone`): the same shared presentations, its own selection and history.
    public func copy() -> DocState {
        let c = DocState(doc, path: path, title: title)
        c.docRef = docRef
        c.protection = protection
        c.savedDocRef = savedDocRef
        c.selection = selection
        c.history = history
        c.revision = revision
        c.interaction = interaction
        c.uid = uid
        c.missingFonts = missingFonts
        c.composition = composition
        c.compare = compare
        c.lastDuplicate = lastDuplicate
        c.autoList = autoList
        return c
    }

    /// The presentation (`*st.doc`).
    public var doc: Presentation { docRef.value }
    /// The presentation as last saved.
    public var savedDoc: Presentation { savedDocRef.value }

    public var isDirty: Bool { docRef !== savedDocRef }

    /// The file's name without its extension, else the title.
    public var displayTitle: String {
        if let p = path, let stem = Self.fileStem(p) { return stem }
        return title
    }

    /// Rust's `Path::file_stem`: the last component without its final extension (a leading dot is
    /// part of the name).
    static func fileStem(_ path: String) -> String? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = comps.last, last != "..", last != "." else { return nil }
        let name = String(last)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    public var currentSlide: Slide? { doc.slides.at(selection.slide) }

    /// Shapes of the edited tree (current slide, or the master/layout in Slide Master view).
    public var shapes: [Shape] { treeShapes(doc, selection) ?? [] }

    public func shape(_ id: ShapeId) -> Shape? { findShape(shapes, id) }

    public var selectedShapes: [Shape] {
        let all = shapes
        return selection.shapes.compactMap { findShape(all, $0) }
    }
}

/// The last Duplicate's place and pairs (original, copy).
public struct LastDuplicate: Sendable, Equatable {
    public var slide: Int
    public var target: Target
    public var pairs: [(ShapeId, ShapeId)]

    public init(slide: Int, target: Target, pairs: [(ShapeId, ShapeId)]) {
        self.slide = slide
        self.target = target
        self.pairs = pairs
    }

    public static func == (a: LastDuplicate, b: LastDuplicate) -> Bool {
        a.slide == b.slide && a.target == b.target && a.pairs.count == b.pairs.count
            && zip(a.pairs, b.pairs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

// MARK: - Shape trees by target

/// The handout or notes master edited in that view.
public func pageMaster(_ doc: Presentation, _ t: Target) -> Master? {
    switch t {
    case .handout: doc.handoutMaster
    case .notesMaster: doc.notesMaster
    default: nil
    }
}

/// Change the handout or notes master edited in that view; nil when there is none.
@discardableResult
public func mutatePageMaster<R>(_ doc: inout Presentation, _ t: Target, _ body: (inout Master) throws -> R) rethrows -> R? {
    switch t {
    case .handout:
        guard var m = doc.handoutMaster else { return nil }
        doc.handoutMaster = nil
        defer { doc.handoutMaster = m }
        return try body(&m)
    case .notesMaster:
        guard var m = doc.notesMaster else { return nil }
        doc.notesMaster = nil
        defer { doc.notesMaster = m }
        return try body(&m)
    default:
        return nil
    }
}

/// The page being edited: the slide size, or the notes size in Handout Master view.
public func pageSize(_ st: DocState) -> Size {
    st.selection.target.isPageMaster ? st.doc.notesSize : st.doc.slideSize
}

/// The handout or notes master as a one-master presentation at the notes page size, for drawing it with
/// the layout renderer.
public func masterPage(_ doc: Presentation, _ t: Target) -> Presentation? {
    guard let m = pageMaster(doc, t) else { return nil }
    var p = doc
    p.slideSize = doc.notesSize
    p.masters = [m]
    p.slides = []
    return p
}

/// The shapes of the tree `sel` edits (`cmd::current_shapes`), nil when it doesn't exist.
public func treeShapes(_ doc: Presentation, _ sel: Selection) -> [Shape]? {
    switch sel.target {
    case .slides: doc.slides.at(sel.slide)?.shapes
    case .master(let m): doc.masters.at(m)?.shapes
    case .handout, .notesMaster: pageMaster(doc, sel.target)?.shapes
    case .layout(let m, let l): doc.masters.at(m)?.layouts.at(l)?.shapes
    }
}

/// Mutable access to the edited shape tree of a presentation (`shapes_mut`): runs `body` on it and
/// returns its result, or nil (nothing changed) when the tree doesn't exist.
@discardableResult
public func mutateShapes<R>(_ doc: inout Presentation, _ sel: Selection, _ body: (inout [Shape]) throws -> R) rethrows -> R? {
    switch sel.target {
    case .slides:
        guard sel.slide >= 0, sel.slide < doc.slides.count else { return nil }
        return try body(&doc.slides[sel.slide].shapes)
    case .master(let m):
        guard m >= 0, m < doc.masters.count else { return nil }
        return try body(&doc.masters[m].shapes)
    case .handout, .notesMaster:
        return try mutatePageMaster(&doc, sel.target) { try body(&$0.shapes) }
    case .layout(let m, let l):
        guard m >= 0, m < doc.masters.count, l >= 0, l < doc.masters[m].layouts.count else { return nil }
        return try body(&doc.masters[m].layouts[l].shapes)
    }
}

/// `mutateShapes`, or `missing` thrown when the tree doesn't exist (`shapes_mut(..).ok_or_else(..)?`).
@discardableResult
public func withShapes<R>(_ doc: inout Presentation, _ sel: Selection, missing: @autoclosure () -> EngineError, _ body: (inout [Shape]) throws -> R) throws -> R {
    var found = false
    let r = try mutateShapes(&doc, sel) { (shapes: inout [Shape]) throws -> R in
        found = true
        return try body(&shapes)
    }
    guard found, let r else { throw missing() }
    return r
}

/// Change shape `id` anywhere in `shapes` (groups included); nil when there is no such shape
/// (`find_shape_mut`).
@discardableResult
public func withShape<R>(_ shapes: inout [Shape], _ id: ShapeId, _ body: (inout Shape) throws -> R) rethrows -> R? {
    guard let path = shapePath(shapes, id), !path.isEmpty else { return nil }
    return try withShapeAt(&shapes, path[...], body)
}

private func withShapeAt<R>(_ shapes: inout [Shape], _ path: ArraySlice<Int>, _ body: (inout Shape) throws -> R) rethrows -> R? {
    guard let i = path.first, i >= 0, i < shapes.count else { return nil }
    let rest = path.dropFirst()
    if rest.isEmpty { return try body(&shapes[i]) }
    var out: R?
    try shapes[i].mutateChildren { (kids: inout [Shape]) throws in
        out = try withShapeAt(&kids, rest, body)
    }
    return out
}

/// Visit every shape mutably, depth-first (groups included, depth-bounded like `walk`).
public func walkMut(_ shapes: inout [Shape], _ f: (inout Shape) throws -> Void) rethrows {
    func rec(_ v: inout [Shape], _ depth: Int) throws {
        if depth > 64 { return }
        for i in v.indices {
            try f(&v[i])
            if v[i].isGroup {
                try v[i].mutateChildren { (kids: inout [Shape]) throws in try rec(&kids, depth + 1) }
            }
        }
    }
    try rec(&shapes, 0)
}

// MARK: - Preferences

/// The most undo steps `Prefs.undoLimit` can keep.
public let maxUndoLimit = 10_000

/// Engine preferences (the UI keeps its own).
public struct Prefs: Sendable, Equatable {
    public var snapToGrid = true
    public var gridSpacing = 6.0
    public var smartGuides = true
    /// Ctrl+D / Paste offset.
    public var duplicateOffset = 12.0
    public var autocorrect = true
    public var smartQuotes = true
    /// AutoCorrect options (Tools ▸ AutoCorrect).
    public var acTwoInitials = true
    public var acSentenceCaps = true
    public var acDays = true
    public var acCapsLock = true
    public var acFractions = true
    public var acOrdinals = true
    public var acLists = true
    /// Your own "replace … with …" entries; they win over the built-in list.
    public var acEntries: [Pair<String, String>] = []
    /// Built-in entries you deleted.
    public var acRemoved: [String] = []
    public var author = "Presenter"
    public var undoLimit = 500
    /// Minutes between AutoRecover saves of unsaved presentations.
    public var recoveryMinutes = 1.0
    /// The unit the rulers, the Format pane and the size dialogs show; the deck always stores points.
    public var units: DCGeometry.Unit = .inches

    public init() {}

    /// The preferences with every value in a range the editor can use: `prefs.json` is a file on disk,
    /// and a hand-edited or damaged one must not break editing or exhaust memory.
    public func sanitized() -> Prefs {
        var s = self
        let d = Prefs()
        func within(_ v: Double, _ lo: Double, _ hi: Double, _ def: Double) -> Double { v.isFinite ? v.clamped(lo, hi) : def }
        s.gridSpacing = s.gridSpacing.isFinite && s.gridSpacing > 0 ? s.gridSpacing.clamped(0.5, 1000) : d.gridSpacing
        s.duplicateOffset = within(s.duplicateOffset, -1000, 1000, d.duplicateOffset)
        s.undoLimit = min(max(s.undoLimit, 0), maxUndoLimit)
        s.recoveryMinutes = within(s.recoveryMinutes, 0.1, 24 * 60, d.recoveryMinutes)
        if s.author.unicodeScalars.count > 256 {
            var t = String.UnicodeScalarView()
            t.append(contentsOf: s.author.unicodeScalars.prefix(256))
            s.author = String(t)
        }
        return s
    }
}

extension Prefs: JSONCodable {
    public func toJSON() -> JSON {
        var o = JSONObject()
        o.put("snapToGrid", snapToGrid)
        o.put("gridSpacing", gridSpacing)
        o.put("smartGuides", smartGuides)
        o.put("duplicateOffset", duplicateOffset)
        o.put("autocorrect", autocorrect)
        o.put("smartQuotes", smartQuotes)
        o.put("acTwoInitials", acTwoInitials)
        o.put("acSentenceCaps", acSentenceCaps)
        o.put("acDays", acDays)
        o.put("acCapsLock", acCapsLock)
        o.put("acFractions", acFractions)
        o.put("acOrdinals", acOrdinals)
        o.put("acLists", acLists)
        o.put("acEntries", acEntries)
        o.put("acRemoved", acRemoved)
        o.put("author", author)
        o.put("undoLimit", undoLimit)
        o.put("recoveryMinutes", recoveryMinutes)
        o.put("units", units)
        return .object(o)
    }

    /// serde `#[serde(default)]`: a missing field takes its default.
    public init(fromJSON json: JSON) throws(JSONDecodeError) {
        let f = try JSONFields(json, "Prefs")
        let d = Prefs()
        self.init()
        snapToGrid = try f.get("snapToGrid", default: d.snapToGrid)
        gridSpacing = try f.get("gridSpacing", default: d.gridSpacing)
        smartGuides = try f.get("smartGuides", default: d.smartGuides)
        duplicateOffset = try f.get("duplicateOffset", default: d.duplicateOffset)
        autocorrect = try f.get("autocorrect", default: d.autocorrect)
        smartQuotes = try f.get("smartQuotes", default: d.smartQuotes)
        acTwoInitials = try f.get("acTwoInitials", default: d.acTwoInitials)
        acSentenceCaps = try f.get("acSentenceCaps", default: d.acSentenceCaps)
        acDays = try f.get("acDays", default: d.acDays)
        acCapsLock = try f.get("acCapsLock", default: d.acCapsLock)
        acFractions = try f.get("acFractions", default: d.acFractions)
        acOrdinals = try f.get("acOrdinals", default: d.acOrdinals)
        acLists = try f.get("acLists", default: d.acLists)
        acEntries = try f.get("acEntries", default: d.acEntries)
        acRemoved = try f.get("acRemoved", default: d.acRemoved)
        author = try f.get("author", default: d.author)
        undoLimit = try f.get("undoLimit", default: d.undoLimit)
        recoveryMinutes = try f.get("recoveryMinutes", default: d.recoveryMinutes)
        units = try f.get("units", default: d.units)
    }
}

// MARK: - Requests to the UI, media status, clipboard

/// Things a command or tool asks the UI to do (open a dialog, show a pane, start the show…).
public enum UiRequest: Sendable, Equatable {
    case dialog(id: String, params: JSON)
    case pane(id: String)
    case startShow(from: Int)
    case message(text: String)
    case pickFile(purpose: String)
    /// Media playback for the UI host: `action` is `play`, `pause`, `toggle`, `stop` or `seek`; `ms` the
    /// media time to start from / seek to.
    case media(action: String, shape: ShapeId, ms: UInt64?)

    public func toJSON() -> JSON {
        switch self {
        case .dialog(let id, let params): ["kind": "dialog", "id": .string(id), "params": params]
        case .pane(let id): ["kind": "pane", "id": .string(id)]
        case .startShow(let from): ["kind": "startShow", "from": .integer(from)]
        case .message(let text): ["kind": "message", "text": .string(text)]
        case .pickFile(let purpose): ["kind": "pickFile", "purpose": .string(purpose)]
        case .media(let action, let shape, let ms): ["kind": "media", "action": .string(action), "shape": shape.toJSON(), "ms": .opt(ms)]
        }
    }
}

/// Playback state of a media shape as the UI host reports it.
public struct MediaStatus: Sendable, Equatable {
    /// `loading`, `playing`, `paused` or `ended`.
    public var state = ""
    public var positionMs: UInt64 = 0
    public var durationMs: UInt64 = 0
    /// Why the media is silent / blank, when it can't be decoded.
    public var error: String?
    public init() {}
}

/// Clipboard contents copied within the app.
public struct Clipboard {
    public var shapes: [Shape] = []
    public var slides: [Slide] = []
    /// Media the copied shapes/slides reference.
    public var media: [MediaItem] = []
    public var text: TextBody?
    public var plain = ""
    /// The copied shapes' theme colours (colour map applied) and fonts, for Paste Special › Keep Source
    /// Formatting.
    public var sourceTheme: (ColorScheme, FontScheme)?
    /// How many times the shapes were pasted (each paste offsets further).
    public var pastes: UInt32 = 0
    public init() {}
}

/// Formatting picked up by the Format Painter (format.rs `Painted`; declared here because the Session
/// holds it).
public struct Painted: Sendable, Equatable {
    public var run: RunProps?
    public var para: ParaProps?
    public var fill: Fill?
    public var line: Line?
    public var effects: Effects?
    public var style: ShapeStyle?
    public init(run: RunProps? = nil, para: ParaProps? = nil, fill: Fill? = nil, line: Line? = nil, effects: Effects? = nil, style: ShapeStyle? = nil) {
        self.run = run
        self.para = para
        self.fill = fill
        self.line = line
        self.effects = effects
        self.style = style
    }
}

/// A list AutoFormat started: the text being edited right after it, the typed lead with its space, the
/// paragraph's own formatting before, and the revision the change left (text.rs `AutoList`; declared here
/// because `DocState` holds it).
public struct AutoList: Sendable, Equatable {
    public var sel: TextSel
    public var typed: String
    public var props: ParaProps
    public var revision: UInt64
    public init(sel: TextSel, typed: String, props: ParaProps, revision: UInt64) {
        self.sel = sel
        self.typed = typed
        self.props = props
        self.revision = revision
    }
}

// MARK: - Session

public final class Session {
    var docs: [DocState] = []
    var active: Int?
    public var prefs = Prefs()
    public var journal: [(String, JSON)] = []
    public var clipboard = Clipboard()
    public var uiRequests: [UiRequest] = []
    public var tool = ToolState()
    var untitled: UInt32 = 0
    /// Format Painter: copied shape/text formatting and whether it stays on (double-click).
    public var painter: (Painted, Bool)?
    /// Animation Painter: copied shape animations and whether it stays on (double-click).
    public var animPainter: ([Animation], Bool)?
    /// Set as Default Shape: the look new shapes get.
    public var defaultLook: Painted?
    /// Nesting of commands run by commands: only the outermost one is an undo step and a journal entry.
    var depth: UInt32 = 0
    /// Crash-recovery folder (the app sets it; saving or closing a presentation removes its entry).
    public var recoveryDir: URL?
    /// Media playback state, written by the UI host every frame (empty without a host).
    public var mediaStatus: [ShapeId: MediaStatus] = [:]
    /// Animated GIF pictures paused with `media.gifPlay` (the others play).
    public var gifPaused: Set<ShapeId> = []
    /// Text keys follow the Mac (Option+arrows move by word, Cmd+arrows to the line or text ends)
    /// instead of Windows and Linux. This port runs on the Mac.
    public var macKeys = true
    /// Command failures the guard caught (deckcraft counts caught panics; Swift can't catch a trap, so
    /// this stays 0).
    public var panicsCaught: UInt64 = 0
    /// Presentations a host read off the UI thread, waiting for `file.adopt` (by token).
    var loaded: [(UInt64, LoadedFile)] = []
    var nextLoaded: UInt64 = 0
    /// Compositions the application settled itself (see `compositionSettles`).
    var compositionSettlesCount: UInt64 = 0

    /// An empty session with default preferences, clipboard, tool state, and no active document.
    public init() {}

    /// Hand over a presentation read on another thread (`FileCommands.readPresentationFile`);
    /// `file.adopt` with the returned token adds it as a document. Only the latest few wait.
    public func stageLoaded(_ f: LoadedFile) -> UInt64 {
        let keep = 4
        nextLoaded &+= 1
        if loaded.count >= keep { loaded.removeFirst() }
        loaded.append((nextLoaded, f))
        return nextLoaded
    }

    /// The staged presentation for `token`, removed from the session.
    func takeLoaded(_ token: UInt64) -> LoadedFile? {
        guard let i = loaded.firstIndex(where: { $0.0 == token }) else { return nil }
        return loaded.remove(at: i).1
    }

    /// A session with one new presentation open.
    public static func withNew() -> Session {
        let s = Session()
        _ = try? s.execute("file.new", .null)
        return s
    }

    public var documents: [DocState] { docs }
    public var activeIndex: Int? { active }
    public var activeDoc: DocState? { active.flatMap { docs.at($0) } }

    /// The active document, or `.noDocument`.
    public func doc() throws(EngineError) -> DocState {
        guard let d = activeDoc else { throw .noDocument }
        return d
    }

    /// The active document to change (the same object as `doc()`; kept for the Rust call sites).
    public func docMut() throws(EngineError) -> DocState { try doc() }

    public func setActive(_ i: Int) {
        let was = activeDoc?.uid
        if i >= 0 && i < docs.count { active = i }
        forgetVertexKindUnless(was)
    }

    @discardableResult
    public func addDocument(_ d: DocState) -> Int {
        let was = activeDoc?.uid
        docs.append(d)
        active = docs.count - 1
        forgetVertexKindUnless(was)
        return docs.count - 1
    }

    public func closeDocument(_ i: Int) {
        let was = activeDoc?.uid
        if i >= 0 && i < docs.count {
            let d = docs.remove(at: i)
            if let dir = recoveryDir { Recovery.discard(dir, d.uid) }
            active = docs.isEmpty ? nil : min(i, docs.count - 1)
        }
        forgetVertexKindUnless(was)
    }

    /// The point type Edit Points remembers names a shape of the active document, and another document
    /// can have a shape with the same id: a change of active document forgets it.
    private func forgetVertexKindUnless(_ was: UInt64?) {
        if activeDoc?.uid != was { tool.vertexKind = nil }
    }

    public func nextUntitled() -> String {
        untitled &+= 1
        return "Presentation\(untitled)"
    }

    /// Run command `id`. Errors from lower layers come back as `EngineError.other`; a failed command
    /// leaves the presentation as it was.
    public func execute(_ id: String, _ params: JSON = .null) throws(EngineError) -> JSON {
        do {
            return try guarded(id) { s in try s.executeUnguarded(id, params) }
        } catch {
            throw EngineError.from(error)
        }
    }

    /// Resolve and run a command, settling composition first, checking eligibility, rolling back a failed
    /// outer command, and committing the resulting undo entry or journal record.
    private func executeUnguarded(_ id: String, _ params: JSON) throws -> JSON {
        guard let spec = findCommand(id) else { throw EngineError.unknownCommand(id) }
        // Any other edit (or a click, a key, undo) settles an input method's composition first.
        if depth == 0 && (spec.journal || spec.undoable) && id != "text.compose" && id != "text.commit" {
            settleComposition()
        }
        if let e = spec.enabled(self) {
            let named = (e == Cmd.nothingSelected || e == Cmd.selectTwo) && (params.get("ids") != nil || params.get("id") != nil)
            if !named { throw EngineError.disabled(id, e) }
        }
        let before = activeDoc.map { ($0.uid, $0.docRef, $0.selection) }
        let vertexKind = tool.vertexKind
        let outer = depth == 0
        depth += 1
        let result: JSON
        do {
            result = try spec.run(self, params)
            depth -= 1
        } catch {
            depth -= 1
            // A command made of several edits can fail after some of them went through; the outermost
            // one puts the presentation back, so a failed command changes nothing.
            if outer, let (uid, old, sel) = before, let st = activeDoc, st.uid == uid, old !== st.docRef {
                st.docRef = old
                st.selection = sel
                st.revision += 1
            }
            if outer { tool.vertexKind = vertexKind }
            throw error
        }
        if let st = activeDoc { clampSelection(st) }
        if let (uid, old, sel) = before, let st = activeDoc, st.uid == uid, old !== st.docRef, st.interaction == nil,
           spec.undoable, outer {
            pushUndo(st, HistoryEntry(label: spec.label, doc: old, selection: sel, vertexKind: vertexKind))
        }
        if spec.journal && outer {
            // A password stays out of the journal.
            var recorded = params
            if case .object(var o) = params, o["password"] != nil {
                o.remove("password")
                recorded = .object(o)
            }
            journal.append((id, recorded))
            if journal.count > 10_000 { journal.removeFirst(1000) }
        }
        return result
    }

    public func commands() -> [CommandInfo] {
        CommandSpecs.all.map { $0.info(self) }
    }

    /// Mutate the active presentation (copy-on-write) and bump the revision.
    @discardableResult
    public func edit<T>(_ f: (inout Presentation, inout Selection) throws -> T) throws -> T {
        let st = try docMut()
        var doc = st.doc
        var sel = st.selection
        let r = try f(&doc, &sel)
        Connect.reroute(&doc, sel)
        st.docRef = DocRef(doc)
        st.selection = sel
        st.revision += 1
        return r
    }

    /// Keep an input method's composition as it stands (#101): its text stays and the whole composition
    /// becomes one undo step. Nothing happens without one.
    public func endComposition() {
        let vertexKind = tool.vertexKind
        guard let st = activeDoc, let c = st.composition else { return }
        st.composition = nil
        if c.before !== st.docRef {
            pushUndo(st, HistoryEntry(label: "Type Text", doc: c.before, selection: c.beforeSelection, vertexKind: vertexKind))
        }
    }

    /// Settle a composition because the application did something else (a click, a key, a command, a
    /// target change) rather than because the input method committed it.
    public func settleComposition() {
        if activeDoc?.composition != nil { compositionSettlesCount &+= 1 }
        endComposition()
    }

    /// How many compositions the application settled itself (clicks, keys, other commands).
    public var compositionSettles: UInt64 { compositionSettlesCount }

    /// Change only the selection (no undo step).
    public func select(_ f: (Presentation, inout Selection) throws -> Void) throws {
        let st = try docMut()
        let doc = st.doc
        // A caret placed anywhere starts downstream; only End puts it back at a line's end.
        st.selection.text?.lineEnd = nil
        func owner(_ sel: Selection) -> OwnerKey? {
            sel.text.map { OwnerKey(slide: sel.slide, target: sel.target, shape: $0.shape, cell: $0.cell, notes: $0.notes) }
        }
        let before = owner(st.selection)
        var sel = st.selection
        try f(doc, &sel)
        st.selection = sel
        clampSelection(st)
        st.revision += 1
        // A composition belongs to the text body it began in: leaving that body settles it.
        if st.composition != nil && owner(st.selection) != before { settleComposition() }
    }

    private struct OwnerKey: Equatable {
        var slide: Int
        var target: Target
        var shape: ShapeId
        var cell: TextPoint?
        var notes: Bool
    }
}

/// Keep the selection pointing at things that exist.
func clampSelection(_ st: DocState) {
    let doc = st.doc
    let n = doc.slides.count
    if n == 0 {
        st.selection.slide = 0
    } else if st.selection.slide >= n || st.selection.slide < 0 {
        st.selection.slide = n - 1
    }
    let tree = treeShapes(doc, st.selection) ?? []
    st.selection.shapes = st.selection.shapes.filter { findShape(tree, $0) != nil }
    if let t = st.selection.text, !t.notes, findShape(tree, t.shape) == nil {
        st.selection.text = nil
    }
    st.selection.slides = st.selection.slides.filter { doc.slide($0) != nil }
    switch st.selection.target {
    case .master(let m) where m >= doc.masters.count:
        st.selection.target = .slides
    case .handout, .notesMaster:
        if pageMaster(doc, st.selection.target) == nil { st.selection.target = .slides }
    case .layout(let m, let l):
        if doc.masters.at(m).map({ l >= $0.layouts.count }) ?? true { st.selection.target = .slides }
    default:
        break
    }
}

// MARK: - Undo cost

/// Default for `History.byteLimit`.
public let undoByteBudget = 256 << 20

/// A rough size of a shape in memory: the struct, its text and kept XML, its children.
private func shapeCost(_ sh: Shape, _ depth: Int) -> Int {
    let text = sh.text.map { t in t.paragraphs.reduce(0) { $0 + 96 + $1.runs.reduce(0) { $0 + 128 + $1.text.utf8.count } } } ?? 0
    let kids = depth < 64 ? sh.children.reduce(0) { $0 + shapeCost($1, depth + 1) } : 0
    return 768 + text + (sh.rawExt?.utf8.count ?? 0) + kids
}

private func shapesCost(_ shapes: [Shape]) -> Int { shapes.reduce(0) { $0 + shapeCost($1, 0) } }

/// Estimated bytes `doc` keeps alive that `newer` doesn't share: its slides, masters and media that
/// aren't shared. deckcraft compares `Arc` addresses; Swift's values have none, so a slide, master or
/// media item counts as shared when `newer` holds an equal one with the same id (equal arrays compare by
/// identity first, so this is cheap for what an edit didn't touch).
public func undoCost(_ doc: Presentation, _ newer: Presentation) -> Int {
    var slides: [SlideId: [Int]] = [:]
    for (i, s) in newer.slides.enumerated() { slides[s.id, default: []].append(i) }
    var n = 64 * doc.slides.count
    for s in doc.slides {
        let shared = slides[s.id]?.contains { newer.slides[$0] == s } ?? false
        if !shared { n += 512 + shapesCost(s.shapes) }
    }
    for m in doc.masters where !newer.masters.contains(where: { $0.id == m.id && $0 == m }) {
        n += 4096 + shapesCost(m.shapes) + m.layouts.reduce(0) { $0 + 512 + shapesCost($1.shapes) }
    }
    for m in doc.media where !newer.media.contains(where: { $0.id == m.id && $0.data == m.data }) {
        n += m.data.count
    }
    return n
}

/// Push an undo step: clears redo, keeps at most `limit` steps and at most the byte budget of memory.
func pushUndo(_ st: DocState, _ e: HistoryEntry) {
    st.history.costs[ObjectIdentifier(e.doc)] = undoCost(e.doc.value, st.doc)
    st.history.undo.append(e)
    st.history.redo.removeAll()
    if st.history.undo.count > max(st.history.limit, 1) { st.history.undo.removeFirst() }
    // Memory too: drop the oldest steps while the kept ones pass the budget (the newest always stays).
    let budget = st.history.byteLimit == 0 ? undoByteBudget : st.history.byteLimit
    func cost(_ e: HistoryEntry) -> Int { st.history.costs[ObjectIdentifier(e.doc)] ?? 0 }
    var total = st.history.undo.reduce(0) { $0 + cost($1) }
    var drop = 0
    while total > budget && drop + 1 < st.history.undo.count {
        total -= cost(st.history.undo[drop])
        drop += 1
    }
    if drop > 0 { st.history.undo.removeFirst(drop) }
    // Costs of steps that are gone (dropped, or redo steps cleared above).
    if st.history.costs.count > st.history.undo.count + 16 {
        let live = Set((st.history.undo + st.history.redo).map { ObjectIdentifier($0.doc) })
        st.history.costs = st.history.costs.filter { live.contains($0.key) }
    }
}
