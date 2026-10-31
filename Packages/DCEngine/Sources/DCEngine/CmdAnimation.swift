// DCEngine — the `animation` command module: the Animations tab and the Animation Pane.
// Port of deckcraft crates/engine/src/cmd/animation.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCModel

public enum AnimationCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd(
                "animation.set",
                "Animation Styles",
                ["Animations", "Animation"],
                nil,
                "{effect: fade|fly|zoom|wipe|appear|spin|pulse|fadeOut|lines|… (animation.list), class?: entrance|emphasis|exit|path, option?, path?: [[x,y],…] or OOXML string, closed?: bool, ids?} — replaces the shapes' animations. path (motion paths): points in slide points, as offsets from where the shape sits, or the OOXML path string (slide fractions) animation.get answers",
                Cmd.hasSelection,
                set
            ),
            .cmd(
                "animation.add",
                "Add Animation",
                ["Animations", "Advanced Animation"],
                nil,
                "{effect, class?, option?, path?: [[x,y],…] or OOXML string, closed?: bool, start?: onClick|withPrevious|afterPrevious, duration?: ms, delay?: ms, ids?} → {count, path?}",
                Cmd.hasSelection,
                add
            ),
            .cmd("animation.remove", "Remove Animation", ["Animation Pane"], nil, "{index} | {ids? (all of the shapes' animations)}", Cmd.hasSlide, remove),
            .cmd("animation.move", "Reorder Animation", ["Animations", "Timing"], nil, "{index, to}", Cmd.hasSlide, moveAnim),
            .cmd(
                "animation.timing",
                "Timing",
                ["Animations", "Timing"],
                nil,
                "{index? (else selected shapes), start?: onClick|withPrevious|afterPrevious, duration?: ms, delay?: ms, repeat?: n, rewind?: bool, trigger?: shape id | null}",
                Cmd.hasSlide,
                timing
            ),
            .cmd(
                "animation.options",
                "Effect Options",
                ["Animations", "Animation"],
                nil,
                "{option?, textBuild?: asOne|byParagraph|byWord|byLetter, path?: [[x,y],…] or OOXML string, closed?: bool, index?}",
                Cmd.hasSlide,
                options
            ),
            .cmd("animation.clear", "Remove All Animations", [], nil, "{index?: slide}", Cmd.hasSlide, clear),
            .noundo(
                "animation.painter",
                "Animation Painter",
                ["Animations", "Advanced Animation"],
                "Alt+Shift+C",
                "{sticky?: bool, id?}",
                Cmd.hasSelection,
                painterPick
            ),
            .cmd("animation.painterApply", "Apply Animation", [], "Alt+Shift+V", "{ids?}", Cmd.hasSelection, painterApply),
            .query("animation.list", "Animation Gallery", [], nil, "{} → [{id, label, class, options}]", Cmd.always, list),
            .query("animation.get", "Animations on Slide", [], nil, "{slide?} → [animation]", Cmd.hasSlide, get),
        ]
    }

    static func classOf(_ s: String?) -> AnimClass? {
        s.map { c in
            switch c {
            case "emphasis", "emph": .emphasis
            case "exit": .exit
            case "path", "motion", "motionPath": .path
            case "media": .media
            default: .entrance
            }
        }
    }

    static func startOf(_ s: String) -> AnimStart {
        switch s {
        case "withPrevious", "with": .withPrevious
        case "afterPrevious", "after": .afterPrevious
        default: .onClick
        }
    }

    private static func bytesEqual(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }

    /// The effect option `given` as one of `allowed`. Besides the stored codes ("b", "lt", "u", …) it takes
    /// the direction words people type: "fromBottom", "bottom", "fromTopLeft", "upRight". nil when it
    /// matches none of them: the renderer reads direction codes letter by letter, so an unchecked
    /// "fromBottom" would fly in from the right and the bottom.
    static func resolveOption(_ allowed: [String], _ given: String) -> String? {
        if allowed.isEmpty || allowed.contains(where: { bytesEqual($0, given) }) { return given }
        let low = rustASCIILowercase(given)
        if let o = allowed.first(where: { bytesEqual(rustASCIILowercase($0), low) }) { return o }
        var rest = Array(low.utf8)
        if rest.starts(with: Array("from".utf8)) { rest.removeFirst(4) }
        while let f = rest.first, f == UInt8(ascii: "-") || f == UInt8(ascii: "_") || f == UInt8(ascii: " ") { rest.removeFirst() }
        // Direction words in order, each as both its edge letter and its arrow letter.
        let words: [(String, (Character, Character))] = [
            ("bottom", ("b", "d")),
            ("down", ("b", "d")),
            ("top", ("t", "u")),
            ("up", ("t", "u")),
            ("left", ("l", "l")),
            ("right", ("r", "r")),
            ("-", ("-", "-")),
            ("_", ("-", "-")),
        ]
        var dirs: [(Character, Character)] = []
        while !rest.isEmpty {
            guard let (w, d) = words.first(where: { rest.starts(with: Array($0.0.utf8)) }) else { return nil }
            if d.0 != "-" { dirs.append(d) }
            rest.removeFirst(w.utf8.count)
        }
        if dirs.isEmpty || dirs.count > 2 { return nil }
        var cands: [String] = []
        for pick in [{ (d: (Character, Character)) in d.0 }, { (d: (Character, Character)) in d.1 }] {
            let code = String(dirs.map(pick))
            let rev = String(code.reversed())
            cands.append(code)
            cands.append(rev)
        }
        return cands.first { c in allowed.contains { bytesEqual($0, c) } }
    }

    /// Rust's `{:?}` of a `&[&str]`.
    private static func debugList(_ v: [String]) -> String {
        "[" + v.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }

    static func build(_ p: JSON, _ slide: (Double, Double)) throws -> Animation {
        guard let effect = Cmd.strParam(p, "effect") else { throw Cmd.bad("animation", "missing `effect`") }
        let cls = classOf(Cmd.strParam(p, "class"))
        let found: AnimationInfo? = if let c = cls { animationInfo(effect, c) } else { DCModel.animations.first { bytesEqual($0.id, effect) } }
        guard let info = found else { throw Cmd.bad("animation", "unknown effect `\(effect)`") }
        var a = Animation.default
        a.class = info.animClass
        a.effect = info.id
        if let o = Cmd.strParam(p, "option") {
            guard let r = resolveOption(info.options, o) else {
                throw Cmd.bad("animation", "option `\(o)` is not one of \(debugList(info.options)) for `\(info.id)`")
            }
            a.option = r
        } else {
            a.option = info.options.first ?? ""
        }
        a.durationMs = p.get("duration")?.asU64.map { UInt32(min($0, 600_000)) } ?? info.defaultDurationMs
        a.delayMs = p.get("delay")?.asU64.map { UInt32(min($0, 600_000)) } ?? 0
        a.presetId = info.presetId
        if let st = Cmd.strParam(p, "start") { a.start = startOf(st) }
        if a.class == .path {
            a.path = try pathParam(p, slide) ?? defaultPath(a.effect, a.option)
        } else if p.get("path") != nil {
            throw Cmd.bad("animation", "`path` only fits a motion path (class `path`)")
        }
        if a.effect == "spin" { a.amount = 360.0 }
        if a.effect == "growShrink" { a.amount = 1.5 }
        return a
    }

    /// Most points of a motion path given as an array, and longest path string given as text.
    static let maxPathPoints = 1_000
    static let maxPathText = 16 * 1024
    /// Largest offset of a point, in slide points; anything beyond is not a place on any slide.
    static let maxPathOffset = 1.0e6

    /// A number of a path string: slide fractions, rounded to 6 places.
    static func pathNum(_ v: Double) -> String {
        var t = Substring(rustFixed(v, places: 6))
        while t.hasSuffix("0") { t = t.dropLast() }
        while t.hasSuffix(".") { t = t.dropLast() }
        return t == "-0" || t.isEmpty ? "0" : String(t)
    }

    /// Does a raw motion path string draw: only commands and numbers, every number finite, and at least
    /// two points? (A lone `e`, or `1e999`, would play as an empty or partial path.)
    static func rawPathDraws(_ text: String) -> Bool {
        let cs = Array(text.unicodeScalars)
        func at(_ i: Int) -> Unicode.Scalar? { i < cs.count ? cs[i] : nil }
        func digit(_ c: Unicode.Scalar?) -> Bool { c.map { $0 >= "0" && $0 <= "9" } ?? false }
        var i = 0
        var nums = 0
        while let c = at(i) {
            if digit(c) || c == "." || ((c == "-" || c == "+") && (digit(at(i + 1)) || at(i + 1) == ".")) {
                let start = i
                i += 1
                while digit(at(i)) || at(i) == "." { i += 1 }
                if at(i) == "e" || at(i) == "E" {
                    let n1 = at(i + 1) ?? " "
                    if digit(n1) || ((n1 == "-" || n1 == "+") && digit(at(i + 2))) {
                        i += 2
                        while digit(at(i)) { i += 1 }
                    }
                }
                let tok = String(String.UnicodeScalarView(cs[start ..< min(i, cs.count)]))
                guard let v = Double(tok), v.isFinite else { return false }
                nums += 1
            } else if " ,MmLlCcQqHhVvZzE".unicodeScalars.contains(c) {
                i += 1
            } else {
                return false
            }
        }
        return nums >= 4
    }

    /// The motion path `path` asks for, as the OOXML path string animations store: either points
    /// (`[[x, y], …]`, slide points as offsets from where the shape sits, joined by lines, `closed?` to
    /// return to the first) or that string itself.
    static func pathParam(_ p: JSON, _ slide: (Double, Double)) throws -> String? {
        guard let v = p.get("path") else { return nil }
        func refuse(_ why: String) -> EngineError { Cmd.bad("animation", "`path` \(why)") }
        switch v {
        case .string(let text):
            let allowed = " .+-eE,MmLlCcQqHhVvZz".unicodeScalars
            let ok = text.utf8.count <= maxPathText
                && text.unicodeScalars.contains { $0 >= "0" && $0 <= "9" }
                && text.unicodeScalars.allSatisfy { ($0 >= "0" && $0 <= "9") || allowed.contains($0) }
                && rawPathDraws(text)
            if !ok { throw refuse("string must be an OOXML motion path such as `M 0 0 L 0.25 0 E` (at most 16 KiB)") }
            return text
        case .array(let points):
            if !(2 ... maxPathPoints).contains(points.count) { throw refuse("needs 2 to \(maxPathPoints) points") }
            if !(slide.0.isFinite && slide.1.isFinite && slide.0 > 0 && slide.1 > 0) {
                throw refuse("can't be placed: the slide has no size")
            }
            var out = ""
            for (k, pt) in points.enumerated() {
                guard let a = pt.asArray, a.count == 2, let x = a[0].asF64, let y = a[1].asF64,
                      Swift.abs(x) <= maxPathOffset, Swift.abs(y) <= maxPathOffset else {
                    throw refuse("point \(k) must be [x, y], two finite numbers within ±\(maxPathOffset.rustDisplay) points")
                }
                out += "\(k == 0 ? "M" : "L") \(pathNum(x / slide.0)) \(pathNum(y / slide.1)) "
            }
            if p.get("closed")?.asBool == true { out += "Z " }
            out += "E"
            return out
        default:
            throw refuse("must be [[x, y], …] or an OOXML path string")
        }
    }

    /// The slide's width and height in points.
    static func slideExtent(_ s: Session) throws -> (Double, Double) {
        let size = try s.doc().doc.slideSize
        return (size.width, size.height)
    }

    /// Default motion paths, in slide-fraction units relative to the shape's position.
    public static func defaultPath(_ effect: String, _ option: String) -> String {
        let (dx, dy): (Double, Double) = switch option {
        case "up": (0.0, -0.25)
        case "right": (0.25, 0.0)
        case "left": (-0.25, 0.0)
        default: (0.0, 0.25)
        }
        func f(_ v: Double) -> String { v.rustDisplay }
        switch effect {
        case "arcs":
            return "M 0 0 C \(f(dx * 0.1 + dy * 0.5)) \(f(dy * 0.1 - dx * 0.5)) \(f(dx * 0.9 + dy * 0.5)) \(f(dy * 0.9 - dx * 0.5)) \(f(dx)) \(f(dy)) E"
        case "turns":
            return "M 0 0 L \(f(dx * 0.5)) \(f(dy * 0.5)) C \(f(dx)) \(f(dy * 0.5)) \(f(dx)) \(f(dy * 0.75)) \(f(dx)) \(f(dy)) E"
        case "shapes":
            return "M 0 0 C 0.1 0 0.1 0.15 0 0.15 C -0.1 0.15 -0.1 0 0 0 Z E"
        case "loops":
            return "M 0 0 C 0.1 -0.1 0.2 0.1 0.1 0.1 C 0 0.1 0.1 -0.1 0.25 0 E"
        default:
            return presetPath(effect) ?? "M 0 0 L \(f(dx)) \(f(dy)) E"
        }
    }

    /// The selection's slide, or `bad(cmd, "no slide")`.
    private static func slideIndex(_ doc: Presentation, _ sel: Selection, _ cmd: String) throws -> Int {
        guard doc.slides.indices.contains(sel.slide) else { throw Cmd.bad(cmd, "no slide") }
        return sel.slide
    }

    @Sendable static func set(_ s: Session, _ p: JSON) throws -> JSON {
        let ids = try Cmd.targets(s, p)
        let a = try build(p, slideExtent(s))
        return try s.edit { doc, sel in
            let i = try slideIndex(doc, sel, "animation.set")
            // Replace each shape's animations, keeping their place in the sequence.
            var out: [Animation] = []
            var placed: [ShapeId] = []
            for x in doc.slides[i].animations {
                if ids.contains(x.shape) {
                    if !placed.contains(x.shape) {
                        placed.append(x.shape)
                        var y = a
                        y.shape = x.shape
                        y.start = x.start
                        out.append(y)
                    }
                } else {
                    out.append(x)
                }
            }
            for id in ids where !placed.contains(id) {
                var y = a
                y.shape = id
                out.append(y)
            }
            if a.effect == "none" { out.removeAll { ids.contains($0.shape) } }
            doc.slides[i].animations = out
            return ["count": .integer(out.count)]
        }
    }

    @Sendable static func add(_ s: Session, _ p: JSON) throws -> JSON {
        let ids = try Cmd.targets(s, p)
        let a = try build(p, slideExtent(s))
        let path = a.path
        return try s.edit { doc, sel in
            let i = try slideIndex(doc, sel, "animation.add")
            for (k, id) in ids.enumerated() {
                var x = a
                x.shape = id
                if k > 0 { x.start = .withPrevious }
                doc.slides[i].animations.append(x)
            }
            if let path { return ["count": .integer(doc.slides[i].animations.count), "path": .string(path)] }
            return ["count": .integer(doc.slides[i].animations.count)]
        }
    }

    @Sendable static func remove(_ s: Session, _ p: JSON) throws -> JSON {
        let index = try Cmd.optUsizeParam(p, "index", "animation.remove")
        let ids = index == nil ? try Cmd.targets(s, p) : []
        try s.edit { doc, sel in
            let i = try slideIndex(doc, sel, "animation.remove")
            if let k = index {
                guard k < doc.slides[i].animations.count else { throw Cmd.bad("animation.remove", "no such animation") }
                doc.slides[i].animations.remove(at: k)
            } else {
                doc.slides[i].animations.removeAll { ids.contains($0.shape) }
            }
        }
        return Cmd.ok()
    }

    @Sendable static func moveAnim(_ s: Session, _ p: JSON) throws -> JSON {
        guard let from = try Cmd.optUsizeParam(p, "index", "animation.move") else { throw Cmd.bad("animation.move", "missing `index`") }
        guard let to = Cmd.usizeParam(p, "to") else { throw Cmd.bad("animation.move", "missing `to`") }
        try s.edit { doc, sel in
            let i = try slideIndex(doc, sel, "animation.move")
            guard from < doc.slides[i].animations.count else { throw Cmd.bad("animation.move", "no such animation") }
            let a = doc.slides[i].animations.remove(at: from)
            doc.slides[i].animations.insert(a, at: min(to, doc.slides[i].animations.count))
        }
        return Cmd.ok()
    }

    static func eachTarget(_ s: Session, _ p: JSON, _ f: (inout Animation) -> Void) throws -> JSON {
        let index = try Cmd.optUsizeParam(p, "index", "animation")
        let ids = index == nil ? try Cmd.targets(s, p) : []
        return try s.edit { doc, sel in
            let i = try slideIndex(doc, sel, "animation")
            var n = 0
            for k in doc.slides[i].animations.indices {
                if index == k || (index == nil && ids.contains(doc.slides[i].animations[k].shape)) {
                    f(&doc.slides[i].animations[k])
                    n += 1
                }
            }
            if n == 0 { throw Cmd.bad("animation", "no animation to change (select an animated object or give `index`)") }
            return ["changed": .integer(n)]
        }
    }

    @Sendable static func timing(_ s: Session, _ p: JSON) throws -> JSON {
        let start = Cmd.strParam(p, "start").map(startOf)
        let dur = p.get("duration")?.asU64.map { UInt32(min($0, 600_000)) }
        let delay = p.get("delay")?.asU64.map { UInt32(min($0, 600_000)) }
        let repeatCount = p.get("repeat")?.asU64.map { UInt32(min($0, UInt64(UInt32.max))) }
        let rewind = Cmd.boolParam(p, "rewind")
        let trigger: ShapeId?? = p.get("trigger").map { $0.asU32.map(ShapeId.init) }
        return try eachTarget(s, p) { a in
            if let x = start { a.start = x }
            if let x = dur { a.durationMs = x }
            if let x = delay { a.delayMs = x }
            if let x = repeatCount { a.repeat = x }
            if let x = rewind { a.rewind = x }
            if let t = trigger { a.trigger = t }
        }
    }

    @Sendable static func options(_ s: Session, _ p: JSON) throws -> JSON {
        let option = Cmd.strParam(p, "option")
        let buildMode: TextBuild? = Cmd.strParam(p, "textBuild").map { b in
            switch b {
            case "byParagraph": .byParagraph
            case "byWord": .byWord
            case "byLetter": .byLetter
            default: .asOne
            }
        }
        let path = try pathParam(p, slideExtent(s))
        return try eachTarget(s, p) { a in
            if let path, a.class == .path { a.path = path }
            if let o = option {
                // Each target takes the option in its own effect's terms; one it has no such option for
                // keeps its own.
                let allowed = animationInfo(a.effect, a.class)?.options ?? []
                if let o = resolveOption(allowed, o) {
                    if a.class == .path && path == nil { a.path = defaultPath(a.effect, o) }
                    a.option = o
                }
            }
            if let b = buildMode { a.textBuild = b }
        }
    }

    @Sendable static func clear(_ s: Session, _ p: JSON) throws -> JSON {
        let i = try Cmd.optUsizeParam(p, "index", "animation.clear") ?? s.doc().selection.slide
        try s.edit { doc, _ in
            if doc.slides.indices.contains(i) { doc.slides[i].animations.removeAll() }
        }
        return Cmd.ok()
    }

    @Sendable static func list(_ s: Session, _ p: JSON) throws -> JSON {
        .array(DCModel.animations.map { a in
            ["id": .string(a.id), "label": .string(a.label), "class": .string(a.animClass.xml), "options": .array(a.options.map { .string($0) })]
        })
    }

    @Sendable static func get(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let i = Cmd.usizeParam(p, "slide") ?? st.selection.slide
        guard let sl = st.doc.slides.at(i) else { throw Cmd.bad("animation.get", "no such slide") }
        return sl.animations.toJSON()
    }

    @Sendable static func painterPick(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        guard let id = try Cmd.idParam(p, "id", "animation.painter") ?? st.selection.shapes.first else {
            throw Cmd.bad("animation.painter", "select an animated shape first")
        }
        guard let sl = st.currentSlide else { throw Cmd.bad("animation.painter", "no slide") }
        let anims = sl.animations.filter { $0.shape == id }
        if anims.isEmpty { throw Cmd.bad("animation.painter", "shape \(id) has no animations to copy") }
        let sticky = Cmd.boolOr(p, "sticky", false)
        s.animPainter = (anims, sticky)
        return ["armed": true, "count": .integer(anims.count)]
    }

    @Sendable static func painterApply(_ s: Session, _ p: JSON) throws -> JSON {
        guard let (painted, sticky) = s.animPainter else {
            throw Cmd.bad("animation.painterApply", "pick animations with the Animation Painter first")
        }
        if !sticky { s.animPainter = nil }
        let ids = try Cmd.targets(s, p)
        if ids.isEmpty { throw Cmd.bad("animation.painterApply", "no target shapes selected") }
        return try s.edit { doc, sel in
            let i = try slideIndex(doc, sel, "animation.painterApply")
            // As in PowerPoint, painting replaces the target's own animations (painting a shape onto itself
            // doesn't double them). A paragraph effect keeps its paragraph only if the target has that
            // paragraph; otherwise it animates the whole shape.
            doc.slides[i].animations.removeAll { ids.contains($0.shape) }
            var added = 0
            for id in ids {
                let paras = findShape(doc.slides[i].shapes, id)?.text?.paragraphs.count ?? 0
                for a in painted {
                    var cloned = a
                    cloned.shape = id
                    if let k = cloned.paragraph, Int(k) >= paras { cloned.paragraph = nil }
                    doc.slides[i].animations.append(cloned)
                    added += 1
                }
            }
            return ["applied": .integer(added)]
        }
    }
}
