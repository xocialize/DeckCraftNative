// DCEngine — the command registry and the helpers every command module shares. Ids follow PowerPoint's
// ribbon and menu structure.
// Port of deckcraft crates/engine/src/cmd/mod.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// Rust's `crate::cmd::*` free functions are `Cmd.*` here; the `cmd!` macro's three kinds are
// `CommandSpec.cmd` (journaled, undoable), `.query` (neither) and `.noundo` (journaled only).
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCRender
import DCText

/// Runs a command: the session and the parameters in, the answer out.
public typealias CommandRun = @Sendable (Session, JSON) throws -> JSON
/// Says why a command is unavailable right now, nil when it is available (Rust: `Err(reason)` / `Ok(())`).
public typealias CommandEnabled = @Sendable (Session) -> String?

public struct CommandSpec: Sendable {
    public let id: String
    public let label: String
    /// Where it lives: `["Home", "Font"]` (ribbon tab and group) or `["Arrange"]` (menu).
    public let menu: [String]
    public let shortcut: String?
    /// The parameters as `describe` and `commands` show them, read by `Cmd.parseParams`: `?` marks an
    /// optional key, a spaced ` | ` separates alternative sets of keys (so alternative values are written
    /// unspaced, `ms|null`), `(…)` is a remark and `→` starts the answer.
    public let params: String
    public let enabled: CommandEnabled
    public let run: CommandRun
    public let journal: Bool
    public let undoable: Bool

    public init(id: String, label: String, menu: [String], shortcut: String?, params: String, enabled: @escaping CommandEnabled, run: @escaping CommandRun, journal: Bool, undoable: Bool) {
        self.id = id
        self.label = label
        self.menu = menu
        self.shortcut = shortcut
        self.params = params
        self.enabled = enabled
        self.run = run
        self.journal = journal
        self.undoable = undoable
    }

    /// `cmd!(…)`: journaled and undoable.
    public static func cmd(_ id: String, _ label: String, _ menu: [String], _ shortcut: String?, _ params: String, _ enabled: @escaping CommandEnabled, _ run: @escaping CommandRun) -> CommandSpec {
        CommandSpec(id: id, label: label, menu: menu, shortcut: shortcut, params: params, enabled: enabled, run: run, journal: true, undoable: true)
    }

    /// `cmd!(query …)`: neither journaled nor undoable.
    public static func query(_ id: String, _ label: String, _ menu: [String], _ shortcut: String?, _ params: String, _ enabled: @escaping CommandEnabled, _ run: @escaping CommandRun) -> CommandSpec {
        CommandSpec(id: id, label: label, menu: menu, shortcut: shortcut, params: params, enabled: enabled, run: run, journal: false, undoable: false)
    }

    /// `cmd!(noundo …)`: journaled, not undoable.
    public static func noundo(_ id: String, _ label: String, _ menu: [String], _ shortcut: String?, _ params: String, _ enabled: @escaping CommandEnabled, _ run: @escaping CommandRun) -> CommandSpec {
        CommandSpec(id: id, label: label, menu: menu, shortcut: shortcut, params: params, enabled: enabled, run: run, journal: true, undoable: false)
    }

    /// What the command acts on, for `describe`. Holds because `Session.execute` skips the selection
    /// check when `id` or `ids` is given.
    public func actsOn() -> String? {
        let keys = (try? Cmd.paramKeys(params)) ?? []
        let named: String? = keys.contains("ids") ? "the shapes in `ids`" : keys.contains("id") ? "the shape in `id`" : nil
        guard let reason = enabled(Session.withNew()) else { return nil }
        switch (reason, named) {
        case (Cmd.selectTextOrShape, _): return "Acts on the selected text or shapes."
        case (Cmd.nothingSelected, .some(let n)): return "Acts on \(n), else on the selected shapes."
        case (Cmd.nothingSelected, nil): return "Acts on the selected shapes."
        case (Cmd.selectTwo, .some(let n)): return "Acts on two or more shapes: \(n), else the selected ones."
        case (Cmd.selectTwo, nil): return "Acts on two or more selected shapes."
        case (Cmd.noTextPoint, _): return "Acts on the text being edited; text.edit starts editing a shape's text."
        default: return nil
        }
    }

    public func info(_ s: Session) -> CommandInfo {
        let e = enabled(s)
        return CommandInfo(id: id, label: label, menu: menu, shortcut: shortcut, params: params, enabled: e == nil, disabledReason: e)
    }
}

public struct CommandInfo: Sendable, Equatable {
    public var id: String
    public var label: String
    public var menu: [String]
    public var shortcut: String?
    public var params: String
    public var enabled: Bool
    public var disabledReason: String?

    /// serde's `CommandInfo` (field names as in Rust: `disabled_reason`, skipped when absent).
    public func toJSON() -> JSON {
        var o = JSONObject()
        o.set("id", .string(id))
        o.set("label", .string(label))
        o.set("menu", menu.toJSON())
        o.set("shortcut", .opt(shortcut))
        o.set("params", .string(params))
        o.set("enabled", .bool(enabled))
        if let r = disabledReason { o.set("disabled_reason", .string(r)) }
        return .object(o)
    }
}

/// The registry: every module's commands in deckcraft's fixed module order, so `commands` lists them in
/// the same order.
public enum CommandSpecs {
    public static let all: [CommandSpec] = {
        var v: [CommandSpec] = []
        v += FileCommands.specs()
        v += EditCommands.specs()
        v += SlideCommands.specs()
        v += ReuseCommands.specs()
        v += InsertCommands.specs()
        v += SmartArtCommands.specs()
        v += ShapeCommands.specs()
        v += BackgroundCommands.specs()
        v += PictureStyleCommands.specs()
        v += RecolorCommands.specs()
        v += ArrangeCommands.specs()
        v += SelectionCommands.specs()
        v += MergeCommands.specs()
        v += PointsCommands.specs()
        v += TextCommands.specs()
        v += FormatCommands.specs()
        v += DesignCommands.specs()
        v += IdeasCommands.specs()
        v += TransitionCommands.specs()
        v += AnimationCommands.specs()
        v += TableCommands.specs()
        v += FindCommands.specs()
        v += ReviewCommands.specs()
        v += InspectCommands.specs()
        v += MediaCommands.specs()
        v += ArtisticCommands.specs()
        v += ZoomCommands.specs()
        v += CompressCommands.specs()
        return v
    }()

    /// The first spec with each id (`find_command` takes the first match).
    static let byId: [String: Int] = {
        var m: [String: Int] = [:]
        for (i, c) in all.enumerated() where m[c.id] == nil { m[c.id] = i }
        return m
    }()
}

/// `command_specs()`.
public func commandSpecs() -> [CommandSpec] { CommandSpecs.all }

/// `find_command(id)`.
public func findCommand(_ id: String) -> CommandSpec? {
    CommandSpecs.byId[id].map { CommandSpecs.all[$0] }
}

/// One top-level parameter of a params doc.
public struct Param: Sendable, Equatable {
    public var name: String
    public var optional: Bool
    /// What the doc says of it: its values, unit or remark (`rect|roundRect|…`, `[x,y,w,h] pt`).
    public var about: String
    /// An alternative to the parameter before it in the same object (`color? | none?`).
    public var or: Bool
    /// Which of the doc's alternative objects it belongs to: `{index} | {id}` puts id in object 1.
    public var object: Int

    public init(name: String, optional: Bool, about: String, or: Bool, object: Int) {
        self.name = name
        self.optional = optional
        self.about = about
        self.or = or
        self.object = object
    }
}

public struct ParamDocError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

/// The helpers command modules share (Rust `crate::cmd::*`).
public enum Cmd {
    // MARK: Enabled predicates and their reasons

    public static let nothingSelected = "nothing selected"
    public static let selectTwo = "select two or more objects"
    public static let noTextPoint = "no text insertion point"
    public static let selectTextOrShape = "select text or a shape"
    /// The deck has used every object id (a hostile file can arrive that way): it cannot grow, and
    /// growing would duplicate ids (#407).
    public static let noIdSpace = "the presentation has used every object id and can hold no more"

    @Sendable public static func always(_ s: Session) -> String? { nil }

    @Sendable public static func hasDoc(_ s: Session) -> String? {
        s.activeDoc == nil ? "no presentation open" : nil
    }

    @Sendable public static func hasSlide(_ s: Session) -> String? {
        if let e = hasDoc(s) { return e }
        if let d = s.activeDoc, !d.doc.slides.isEmpty || d.selection.target != .slides { return nil }
        return "no slides"
    }

    @Sendable public static func hasSelection(_ s: Session) -> String? {
        if let e = hasDoc(s) { return e }
        return s.activeDoc.map { !$0.selection.shapes.isEmpty } == true ? nil : nothingSelected
    }

    @Sendable public static func hasTwo(_ s: Session) -> String? {
        if let e = hasDoc(s) { return e }
        return (s.activeDoc?.selection.shapes.count ?? 0) >= 2 ? nil : selectTwo
    }

    @Sendable public static func hasText(_ s: Session) -> String? {
        if let e = hasDoc(s) { return e }
        return s.activeDoc?.selection.text != nil ? nil : noTextPoint
    }

    /// Text editing or selected shapes (formatting commands apply to either).
    @Sendable public static func hasTextOrShapes(_ s: Session) -> String? {
        if let e = hasDoc(s) { return e }
        if let d = s.activeDoc, d.selection.text != nil || !d.selection.shapes.isEmpty { return nil }
        return selectTextOrShape
    }

    @Sendable public static func canUndo(_ s: Session) -> String? {
        s.activeDoc.map { !$0.history.undo.isEmpty } == true ? nil : "nothing to undo"
    }

    @Sendable public static func canRedo(_ s: Session) -> String? {
        s.activeDoc.map { !$0.history.redo.isEmpty } == true ? nil : "nothing to redo"
    }

    // MARK: The params doc grammar

    /// The distinct top-level parameter names of a params doc.
    static func paramKeys(_ doc: String) throws(ParamDocError) -> [String] {
        var keys: [String] = []
        for p in try parseParams(doc) where !keys.contains(p.name) { keys.append(p.name) }
        return keys
    }

    /// The top-level parameters of a params doc: `{preset, rect?: [x,y,w,h] pt} | {id}` gives preset, rect
    /// (optional, `[x,y,w,h] pt`) and id (in the second object). Text after `→` is the result and is
    /// skipped. Errs where the doc strays from that grammar. Offsets are UTF-8 bytes, as in Rust.
    public static func parseParams(_ full: String) throws(ParamDocError) -> [Param] {
        let fullBytes = Array(full.utf8)
        let arrow = Array("→".utf8)
        var cut = fullBytes.count
        if fullBytes.count >= arrow.count {
            for i in 0 ... (fullBytes.count - arrow.count) where Array(fullBytes[i ..< i + arrow.count]) == arrow {
                cut = i
                break
            }
        }
        let bytes = Array(fullBytes[..<cut])
        func text(_ a: Int, _ b: Int) -> String {
            guard a >= 0, b <= bytes.count, a <= b else { return "" }
            return String(decoding: bytes[a ..< b], as: UTF8.self)
        }
        // (byte offset, scalar)
        var chars: [(Int, Unicode.Scalar)] = []
        var off = 0
        for c in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            chars.append((off, c))
            off += String(c).utf8.count
        }
        var params: [Param] = []
        var open: [Unicode.Scalar] = []
        var expectKey = false
        var or = false
        var objects = 0
        var aboutFrom: Int?
        var prev: Unicode.Scalar = " "
        func endAbout(_ to: Int) {
            if let f = aboutFrom, !params.isEmpty {
                params[params.count - 1].about = String(rustTrim(text(f, to)))
            }
            aboutFrom = nil
        }
        func isAlpha(_ c: Unicode.Scalar) -> Bool { c.isASCII && (("a" ... "z").contains(c) || ("A" ... "Z").contains(c)) }
        func isAlnum(_ c: Unicode.Scalar) -> Bool { isAlpha(c) || ("0" ... "9").contains(c) }
        var k = 0
        while k < chars.count {
            let (i, c) = chars[k]
            k += 1
            let inObject = open == ["{"]
            if c == "{" || c == "[" || c == "(" {
                open.append(c)
                if open == ["{"] {
                    expectKey = true
                    objects += 1
                    or = false
                }
            } else if c == "}" || c == "]" || c == ")" {
                if inObject { endAbout(i) }
                _ = open.popLast()
            } else if c == ",", inObject {
                endAbout(i)
                expectKey = true
            } else if c == "|", inObject, prev == " ", k < chars.count, chars[k].1 == " " {
                endAbout(i)
                expectKey = true
                or = true
            } else if inObject, expectKey, isAlpha(c) || c == "_" {
                var end = i + String(c).utf8.count
                while k < chars.count, isAlnum(chars[k].1) || chars[k].1 == "_" {
                    end = chars[k].0 + String(chars[k].1).utf8.count
                    k += 1
                }
                let after = text(end, bytes.count)
                let rest = rustTrimStart(Substring(String(String.UnicodeScalarView(after.unicodeScalars.drop { $0 == "?" }))))
                let at = bytes.count - rest.utf8.count
                switch rest.unicodeScalars.first {
                case ":": aboutFrom = at + 1
                case "(": aboutFrom = at
                case ",", "}", "|": aboutFrom = nil
                default:
                    let shown = String(String.UnicodeScalarView(rest.unicodeScalars.prefix(12)))
                    throw ParamDocError(message: "`\(text(i, end))` is followed by `\(shown)`")
                }
                params.append(Param(name: text(i, end), optional: after.utf8.first == UInt8(ascii: "?"), about: "", or: or, object: max(objects - 1, 0)))
                or = false
                expectKey = false
            } else if inObject, expectKey, !c.properties.isWhitespace {
                throw ParamDocError(message: "expected a key at `\(text(i, bytes.count))`")
            }
            prev = c
        }
        return params
    }

    /// The command palette runs a command with `{}`. True when the params doc names a value that call
    /// would have to supply (`path`, `rows`, `path? | data`), so the palette must not offer it.
    public static func needsArguments(_ params: String) -> Bool {
        let input = params.components(separatedBy: "→").first ?? params
        guard let start = input.firstIndex(of: "{") else { return false }
        let inside = String(input[input.index(after: start)...])
        let body = inside.components(separatedBy: "}").first ?? inside
        return splitFields(body).contains { fieldRequires(String(rustTrim($0))) }
    }

    private static func splitFields(_ s: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        var depth = 0
        var quote = false
        for c in s.unicodeScalars {
            if quote {
                if c == "\"" { quote = false }
                cur.append(c)
                continue
            }
            switch c {
            case "\"": quote = true
            case "[", "(": depth += 1
            case "]", ")": depth = max(depth - 1, 0)
            case "," where depth == 0:
                out.append(String(cur))
                cur = String.UnicodeScalarView()
                continue
            default: break
            }
            cur.append(c)
        }
        out.append(String(cur))
        return out
    }

    /// A field needs a value unless every alternative (`path? | data`) is an optional parameter.
    private static func fieldRequires(_ field: String) -> Bool {
        if field.isEmpty { return false }
        let alts: [String] = field.contains(" | ")
            ? field.components(separatedBy: " | ").map { String(rustTrim($0)) }.filter { !$0.isEmpty }
            : [field]
        var saw = false
        var allOptional = true
        for alt in alts {
            guard let optional = paramOptional(alt) else { continue }
            saw = true
            allOptional = allOptional && optional
        }
        return saw && !allOptional
    }

    /// true when `alt` starts with an optional parameter name, false when required.
    private static func paramOptional(_ alt: String) -> Bool? {
        let a = rustTrim(alt)
        let scalars = Array(a.unicodeScalars)
        let nameEnd = scalars.firstIndex { !($0.isASCII && ($0.properties.isAlphabetic || ("0" ... "9").contains($0))) } ?? scalars.count
        guard nameEnd > 0, let first = scalars.first, first.isASCII, first.properties.isAlphabetic else { return nil }
        let rest = rustTrimStart(Substring(String(String.UnicodeScalarView(scalars[nameEnd...]))))
        if rest.unicodeScalars.first == "?" { return true }
        if rest.isEmpty || rest.unicodeScalars.first == ":" { return false }
        return nil
    }

    // MARK: Param helpers

    public static func bad(_ cmd: String, _ msg: String) -> EngineError { .badParams(cmd: cmd, msg: msg) }

    public static func f64Param(_ p: JSON, _ key: String) -> Double? {
        p.get(key)?.asF64.flatMap { $0.isFinite ? $0 : nil }
    }

    public static func f64Or(_ p: JSON, _ key: String, _ def: Double) -> Double { f64Param(p, key) ?? def }

    public static func boolParam(_ p: JSON, _ key: String) -> Bool? { p.get(key)?.asBool }

    public static func boolOr(_ p: JSON, _ key: String, _ def: Bool) -> Bool { boolParam(p, key) ?? def }

    public static func strParam(_ p: JSON, _ key: String) -> String? { p.get(key)?.asStr }

    public static func usizeParam(_ p: JSON, _ key: String) -> Int? { p.get(key)?.asUsize }

    /// An index param: nil when absent (callers may fall back to the selection), an error when present
    /// but not a valid index (negative, non-integer), so a bad index never acts on the selection.
    public static func optUsizeParam(_ p: JSON, _ key: String, _ cmd: String) throws -> Int? {
        guard let v = p.get(key), !v.isNull else { return nil }
        guard let i = v.asUsize else { throw bad(cmd, "`\(key)` is not a valid index: \(v.display)") }
        return i
    }

    /// A shape id param: nil when absent, an error when present but not a valid id (negative,
    /// non-integer, beyond `u32`), so a bad id never edits the selection.
    public static func idParam(_ p: JSON, _ key: String, _ cmd: String) throws -> ShapeId? {
        guard let v = p.get(key), !v.isNull else { return nil }
        guard let i = v.asU32 else { throw bad(cmd, "`\(key)` is not a valid shape id: \(v.display)") }
        return ShapeId(i)
    }

    public static func idsParam(_ p: JSON, _ key: String) -> [ShapeId]? {
        p.get(key)?.asArray.map { $0.compactMap(\.asU32).map(ShapeId.init) }
    }

    /// `[x, y, w, h]` in points.
    public static func rectParam(_ p: JSON, _ key: String) -> Xfrm? {
        guard let a = p.get(key)?.asArray else { return nil }
        func f(_ i: Int) -> Double? { a.at(i)?.asF64.flatMap { $0.isFinite ? $0 : nil } }
        guard let x = f(0), let y = f(1), let w = f(2), let h = f(3) else { return nil }
        return Xfrm(x, y, abs(w), abs(h))
    }

    public static func withParam(_ p: JSON, _ key: String, _ v: JSON) -> JSON {
        var m = p.asObject ?? JSONObject()
        m.set(key, v)
        return .object(m)
    }

    /// Targets: `ids` / `id` params, else the selection.
    public static func targets(_ s: Session, _ p: JSON) throws -> [ShapeId] {
        if let a = p.get("ids")?.asArray, let v = a.first(where: { $0.asU32 == nil }) {
            throw bad("shape", "`ids` has an invalid shape id: \(v.display)")
        }
        if let ids = idsParam(p, "ids"), !ids.isEmpty { return ids }
        if let id = try idParam(p, "id", "shape") { return [id] }
        return try s.doc().selection.shapes
    }

    public static func ok() -> JSON { .null }

    /// Parse a colour param: `"#RRGGBB"`, `"accent1"`…, or `{"scheme":"accent2","lumMod":75000}`. A preset
    /// or system colour keeps its base: `{"preset":"red"}`, `{"system":"windowText","last":"#000000"}`.
    public static func colorParam(_ p: JSON, _ key: String) -> ColorRef? {
        p.get(key).flatMap(colorValue)
    }

    public static func colorValue(_ v: JSON) -> ColorRef? {
        switch v {
        case .string(let s):
            if let slot = SchemeSlot.fromXML(s) { return .scheme(slot) }
            if let c = Rgba.fromHex(s) { return .rgb(c) }
            return presetColor(s).map(ColorRef.rgb)
        case .object(let o):
            var c: ColorRef
            if let s = o["scheme"]?.asStr {
                guard let slot = SchemeSlot.fromXML(s) else { return nil }
                c = .scheme(slot)
            } else if let name = o["preset"]?.asStr {
                guard isPresetColorName(name) else { return nil }
                c = ColorRef(base: .preset(name: name), mods: [])
            } else if let name = o["system"]?.asStr {
                guard isSystemColorName(name), let hex = o["last"]?.asStr, let last = Rgba.fromHex(hex) else { return nil }
                c = ColorRef(base: .system(name: name, last: last), mods: [])
            } else {
                guard let hex = o["rgb"]?.asStr, let rgb = Rgba.fromHex(hex) else { return nil }
                c = .rgb(rgb)
            }
            // serde_json's map iterates its keys sorted.
            guard case .object(let sorted) = JSON.object(o).canonical else { return c }
            for e in sorted.entries {
                let val = e.value.asI64.flatMap { Int32(exactly: $0) }
                if let t = ColorTransform.fromXML(e.key, val) { c.mods.append(t) }
            }
            return c
        default:
            return nil
        }
    }

    /// Look a shape up by id in the edited tree.
    public static func shapeOf(_ s: Session, _ id: ShapeId) throws -> Shape {
        guard let sh = try s.doc().shape(id) else { throw EngineError.other("no shape \(id)") }
        return sh
    }

    /// Effective box of a shape (placeholders inherit theirs). A table's box is at least as tall as its
    /// rows are drawn (rows grow to fit their text), so handles and hit tests match what is shown.
    public static func xfrmOf(_ doc: Presentation, _ sel: Selection, _ shape: Shape) -> Xfrm {
        var x = shape.xfrm ?? ctxXfrm(doc, sel, shape)
        if case .table(let t) = shape.kind {
            let drawn = tableDrawnHeights(doc, sel, t).reduce(0, +)
            if drawn.isFinite && drawn > x.h { x.h = drawn }
        }
        return x
    }

    /// Row heights of table `t` as drawn: a stored height is a minimum, rows grow to fit their text.
    public static func tableDrawnHeights(_ doc: Presentation, _ sel: Selection, _ t: Table) -> [Double] {
        if let ctx = TextCommands.ctxFor(doc, sel) {
            return TableRender.rowHeights(ctx, t, NoFields())
        }
        return t.rows.map(\.height)
    }

    private static func ctxXfrm(_ doc: Presentation, _ sel: Selection, _ shape: Shape) -> Xfrm {
        let x: Xfrm? = switch sel.target {
        case .slides: doc.slides.at(sel.slide).flatMap { Resolve.Ctx.forSlide(doc, $0) }.map { Resolve.xfrm($0, shape) }
        case .master(let m): doc.masters.at(m).map { Resolve.xfrm(Resolve.Ctx.forMaster(doc, $0), shape) }
        case .handout, .notesMaster: pageMaster(doc, sel.target).map { Resolve.xfrm(Resolve.Ctx.forMaster(doc, $0), shape) }
        case .layout(let m, let l):
            doc.masters.at(m).flatMap { ma in ma.layouts.at(l).map { Resolve.xfrm(Resolve.Ctx.forLayout(doc, ma, $0), shape) } }
        }
        return x ?? Xfrm()
    }

    /// Run `f` on each target shape (copy-on-write), materialising inherited boxes first.
    public static func editShapes(_ s: Session, _ p: JSON, _ cmd: String, _ f: (inout Shape) throws -> Void) throws -> JSON {
        let ids = try targets(s, p)
        if ids.isEmpty { throw bad(cmd, "no shapes selected") }
        return try s.edit { doc, sel in
            let tree = currentShapes(doc, sel) ?? []
            let boxes: [(ShapeId, Xfrm)] = ids.compactMap { id in findShape(tree, id) }.map { ($0.id, xfrmOf(doc, sel, $0)) }
            let n = try withShapes(&doc, sel, missing: bad(cmd, "no slide")) { shapes in
                var n = 0
                for id in ids {
                    try withShape(&shapes, id) { sh in
                        if sh.xfrm == nil { sh.xfrm = boxes.first { $0.0 == id }?.1 }
                        try f(&sh)
                        n += 1
                    }
                }
                return n
            }
            if n == 0 { throw bad(cmd, "no such shape") }
            return .integer(n)
        }
    }

    /// `editShapes` for edits a locked object refuses (move, size, rotate, flip, reshape, crop): locked
    /// targets are left out, and when every target is locked nothing changes.
    public static func editGeometry(_ s: Session, _ p: JSON, _ cmd: String, _ f: (inout Shape) throws -> Void) throws -> JSON {
        let ids = try targets(s, p)
        let st = try s.doc()
        let free = ids.filter { !(st.shape($0)?.locked ?? false) }.map(\.rawValue)
        if !ids.isEmpty && free.isEmpty { throw bad(cmd, "the object is locked") }
        return try editShapes(s, withParam(p, "ids", free.toJSON()), cmd, f)
    }

    /// The shapes of the edited tree (`current_shapes`).
    public static func currentShapes(_ doc: Presentation, _ sel: Selection) -> [Shape]? { treeShapes(doc, sel) }

    public static func currentNames(_ doc: Presentation, _ sel: Selection) -> Set<String> {
        Set((currentShapes(doc, sel) ?? []).map(\.name))
    }

    // MARK: Base64

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    /// Base64 (standard alphabet) for binary payloads in JSON params and results.
    public static func base64Encode(_ data: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity((data.count + 2) / 3 * 4)
        var i = 0
        while i < data.count {
            let n = min(3, data.count - i)
            let b0 = UInt32(data[i])
            let b1 = n > 1 ? UInt32(data[i + 1]) : 0
            let b2 = n > 2 ? UInt32(data[i + 2]) : 0
            let v = (b0 << 16) | (b1 << 8) | b2
            for (k, shift) in [18, 12, 6, 0].enumerated() {
                out.append(k <= n ? alphabet[Int((v >> UInt32(shift)) & 63)] : UInt8(ascii: "="))
            }
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func base64Decode(_ s: String) -> [UInt8]? {
        var text = Substring(s)
        if let r = s.range(of: "base64,") { text = s[r.upperBound...] }
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count / 4 * 3)
        var acc: UInt32 = 0
        var bits = 0
        for c in text.utf8 {
            let v: UInt32
            switch c {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"): v = UInt32(c - UInt8(ascii: "A"))
            case UInt8(ascii: "a") ... UInt8(ascii: "z"): v = UInt32(c - UInt8(ascii: "a")) + 26
            case UInt8(ascii: "0") ... UInt8(ascii: "9"): v = UInt32(c - UInt8(ascii: "0")) + 52
            case UInt8(ascii: "+"), UInt8(ascii: "-"): v = 62
            case UInt8(ascii: "/"), UInt8(ascii: "_"): v = 63
            case UInt8(ascii: "="), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: " "): continue
            default: return nil
            }
            acc = (acc << 6) | v
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> UInt32(bits)) & 0xff))
            }
        }
        return out
    }
}
