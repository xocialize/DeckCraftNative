// DCEngine — the `shape` command module: Shape Format (position and size, rotation, flips, geometry, fill,
// outline, effects, styles, names and alt text), pictures' crop and corrections, connectors, freeforms, Ink
// to Shape and media playback options.
// Port of deckcraft crates/engine/src/cmd/shape.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel

public enum ShapeCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd("shape.connect", "Connect Shapes", [], nil, "{from: shape id, to: shape id, fromSite?, toSite?: site index (default: the closest pair), id?: existing line to glue (else a new connector), preset?: straightConnector1|bentConnector3|curvedConnector3} → {id}", Cmd.hasSlide, connect),
            .cmd("shape.freeform", "Freeform", ["Insert", "Shapes"], nil, "{points: [[x, y], …] slide pt (≥ 2), closed?: bool (filled shape), smooth?: bool (curve through the points)} → {id}", Cmd.hasSlide, freeform),
            .cmd("draw.inkToShape", "Ink to Shape", ["Draw", "Convert"], nil, "{} → {shapes: [ids], kept: n} turns recognisable ink strokes on the slide into lines, rectangles, ellipses and triangles", Cmd.hasSlide, inkToShape),
            .query("shape.sites", "Connection Sites", [], nil, "{id} → [[x, y]] connection sites in slide points", Cmd.hasSlide, sites),
            .cmd("shape.move", "Move", [], nil, "{dx?: pt (relative), dy?: pt (relative), ids?} | {x?: pt (absolute), y?: pt (absolute), ids?}", Cmd.hasSelection, moveBy),
            .cmd("shape.resize", "Size", ["Shape Format", "Size"], nil, "{w?: pt, h?: pt, lockAspect?: bool, ids?}", Cmd.hasSelection, resize),
            .cmd("shape.setBounds", "Position and Size", [], nil, "{x, y, w, h, ids?}", Cmd.hasSelection, setBounds),
            .cmd("shape.rotate", "Rotation", ["Shape Format", "Arrange", "Rotate"], nil, "{deg?: absolute, by?: relative, ids?, gesture?: move|end}", Cmd.hasSelection, rotate),
            .cmd("shape.sizePosition", "Size and Position…", ["Shape Format", "Size"], nil, "{x?, y?: pt, w?, h?: pt, rot?: deg, scaleW?, scaleH?: percent of the current size (100 = unchanged), lockAspect?: bool, ids?} — with none of those keys, opens the dialog", Cmd.hasSelection, sizePosition),
            .cmd("shape.flip", "Flip", ["Shape Format", "Arrange", "Rotate"], nil, "{axis: horizontal|vertical, ids?}", Cmd.hasSelection, flip),
            .cmd("shape.adjust", "Adjust Shape", [], nil, "{index, value (file units), ids?}", Cmd.hasSelection, adjust),
            .cmd("shape.change", "Change Shape", ["Shape Format", "Insert Shapes", "Edit Shape"], nil, "{preset, ids?}", Cmd.hasSelection, change),
            .cmd("shape.smoothCorners", "Smooth Corners", ["Shape Format", "Insert Shapes", "Edit Shape"], nil, "{smoothing: 0..100 (%), radius?: pt (default: the rounded rectangle's own), ids?} → rectangle outline with smoothed (squircle) corners", Cmd.hasSelection, smoothCorners),
            .cmd("shape.fill", "Shape Fill", ["Shape Format", "Shape Styles"], nil, "{color? | none?: true | gradient?: {stops: [[pos, color]], angle?, kind?: linear|radial} | picture?: base64 | pattern?: {preset, fg, bg} | transparency?: 0..1 | reset?: true, ids?}; pictureProps?: {tile?: bool, offsetX?, offsetY?: pt, scaleX?, scaleY?: 0..10, align?: tl|t|tr|l|ctr|r|bl|b|br, mirror?: none|x|y|xy, stretch?: [l, t, r, b] fractions, rotateWithShape?: bool} adjusts a picture fill; a group also formats its members", Cmd.hasSelection, fill),
            .cmd("shape.line", "Shape Outline", ["Shape Format", "Shape Styles"], nil, "{color?, none?, width?: pt, dash?: solid|dot|dash|lgDash|dashDot|sysDot|sysDash, cap?: flat|round|square, join?: round|bevel|miter, compound?: single|double|thickThin|thinThick|triple, head?: none|triangle|stealth|diamond|oval|arrow, tail?, headSize?: sm|med|lg, tailSize?, reset?, ids?}; a group also formats its members", Cmd.hasSelection, line),
            .cmd("shape.effects", "Shape Effects", ["Shape Format", "Shape Styles"], nil, "{shadow?: none|outer|inner|perspective|{color, blur, dist, dir}, glow?: none|{color, radius}, softEdges?: pt, reflection?: none|tight|half|full, bevel?: none|circle|…, threeD?: {camera?: preset, rotX?, rotY?, rotZ?: deg, z?: pt, bevelTop?, bevelBottom?: none|circle|…, bevelTopW?, bevelTopH?, bevelBottomW?, bevelBottomH?, depth?, contour?: pt, material?, lighting?, reset?: true}, shadowProps?: {color?, transparency?: 0..1, blur?: pt, dist?: pt, dir?: deg}, glowProps?: {color?, transparency?, radius?: pt}, reflectionProps?: {transparency?, size?: 0..1, dist?: pt, blur?: pt}, reset?, ids?} (the *Props keys adjust the current effect, adding a default one when there is none)", Cmd.hasSelection, effects),
            .cmd("shape.quickStyle", "Quick Styles", ["Home", "Drawing"], nil, "{index: 0..41 (theme style row×accent), ids?}", Cmd.hasSelection, quickStyle),
            .cmd("shape.rename", "Rename", ["Selection Pane"], nil, "{name, id?}", Cmd.hasSelection, rename),
            .cmd("shape.altText", "Alt Text", ["Shape Format", "Accessibility"], nil, "{text, decorative?: bool, ids?}", Cmd.hasSelection, altText),
            .cmd("shape.visible", "Show/Hide", ["Selection Pane"], nil, "{visible?: bool, ids?}", Cmd.hasSelection, visible),
            .cmd("shape.lock", "Lock", ["Selection Pane"], nil, "{locked?: bool (default: toggle), ids?} (a group locks or unlocks with everything in it)", Cmd.hasSelection, lock),
            .cmd("shape.setDefault", "Set as Default Shape", [], nil, "{}", Cmd.hasSelection, setDefault),
            .cmd("picture.crop", "Crop", ["Picture Format", "Size"], nil, "{left?: fraction 0..1, top?: fraction 0..1, right?: fraction 0..1, bottom?: fraction 0..1, ids?}", Cmd.hasSelection, crop),
            .cmd("picture.adjust", "Corrections", ["Picture Format", "Adjust"], nil, "{brightness?: -1..1, contrast?: -1..1, saturation?: 0..4, grayscale?: bool, transparency?: 0..1, reset?: bool, ids?}", Cmd.hasSelection, pictureAdjust),
            .cmd("picture.reset", "Reset Picture", ["Picture Format", "Adjust"], nil, "{ids?}", Cmd.hasSelection, pictureReset),
            .cmd("picture.change", "Change Picture", ["Picture Format", "Adjust"], nil, "{path? | data: base64, name?, ids?}", Cmd.hasSelection, pictureChange),
            .cmd("media.options", "Playback", ["Playback"], nil, "{autoplay?, loop?, rewind?, acrossSlides?, hide?, fullScreen?, volume?: 0..1, trimStart?: ms, trimEnd?: ms, fadeIn?: ms, fadeOut?: ms, ids?}", Cmd.hasSelection, mediaOptions),
        ]
    }

    // MARK: Position and size

    static let sizePos = "shape.sizePosition"
    /// Smallest and largest side the dialog will write, in points (220 in).
    static let minPt = 0.01
    static let maxPt = 15_840.0
    static let posLimit = 100_000.0
    static let maxScale = 10_000.0

    /// Keeps a side length in `0...maxPt` so a huge value cannot exhaust memory when rendering. An overflow
    /// to infinity lands on the limit; NaN becomes 0.
    static func clampSide(_ v: Double) -> Double { v.isNaN ? 0 : v.clamped(0, maxPt) }

    /// Keeps a coordinate within `±posLimit`.
    static func clampPos(_ v: Double) -> Double { v.isNaN ? 0 : v.clamped(-posLimit, posLimit) }

    @Sendable static func moveBy(_ s: Session, _ p: JSON) throws -> JSON {
        let (dx, dy) = (Cmd.f64Param(p, "dx"), Cmd.f64Param(p, "dy"))
        let (ax, ay) = (Cmd.f64Param(p, "x"), Cmd.f64Param(p, "y"))
        return try Cmd.editGeometry(s, p, "shape.move") { sh in
            guard var x = sh.xfrm else { return }
            x.x = clampPos((ax ?? x.x) + (dx ?? 0))
            x.y = clampPos((ay ?? x.y) + (dy ?? 0))
            sh.xfrm = x
        }
    }

    @Sendable static func resize(_ s: Session, _ p: JSON) throws -> JSON {
        let w = Cmd.f64Param(p, "w").map { $0.rustMax(0) }
        let h = Cmd.f64Param(p, "h").map { $0.rustMax(0) }
        let lock = Cmd.boolOr(p, "lockAspect", false)
        return try Cmd.editGeometry(s, p, "shape.resize") { sh in
            guard var x = sh.xfrm else { return }
            let ar = x.h > 0 ? x.w / x.h : 1
            let (cx, cy) = (x.x + x.w / 2, x.y + x.h / 2)
            if let w, lock {
                x.w = w
                x.h = ar > 0 ? w / ar : x.h
            } else if w == nil, let h, lock {
                x.h = h
                x.w = h * ar
            } else {
                x.w = w ?? x.w
                x.h = h ?? x.h
            }
            x.w = clampSide(x.w)
            x.h = clampSide(x.h)
            // Rotated shapes resize about their centre; others keep the top-left.
            if x.rot != 0 {
                x.x = clampPos(cx - x.w / 2)
                x.y = clampPos(cy - x.h / 2)
            }
            sh.xfrm = x
        }
    }

    @Sendable static func setBounds(_ s: Session, _ p: JSON) throws -> JSON {
        try Cmd.editGeometry(s, p, "shape.setBounds") { sh in
            guard var x = sh.xfrm else { return }
            x.x = clampPos(Cmd.f64Param(p, "x") ?? x.x)
            x.y = clampPos(Cmd.f64Param(p, "y") ?? x.y)
            x.w = clampSide(Cmd.f64Param(p, "w") ?? x.w)
            x.h = clampSide(Cmd.f64Param(p, "h") ?? x.h)
            sh.xfrm = x
        }
    }

    struct SizeSpec {
        var x: Double?
        var y: Double?
        var w: Double?
        var h: Double?
        var rot: Double?
        var scaleW: Double?
        var scaleH: Double?
        var lock: Bool

        var widthSet: Bool { w != nil || scaleW != nil }
        var heightSet: Bool { h != nil || scaleH != nil }
        var any: Bool { x != nil || y != nil || widthSet || heightSet || rot != nil }
    }

    static func finiteKey(_ p: JSON, _ key: String) throws -> Double? {
        guard let v = p.get(key), !v.isNull else { return nil }
        guard let n = v.asF64, n.isFinite else { throw Cmd.bad(sizePos, "`\(key)` must be a finite number") }
        return n
    }

    static func inRange(_ v: Double?, _ key: String, _ lo: Double, _ hi: Double) throws -> Double? {
        if let n = v, !(n >= lo && n <= hi) { throw Cmd.bad(sizePos, "`\(key)` is out of range") }
        return v
    }

    static func sizeSpec(_ p: JSON) throws -> SizeSpec {
        let lock: Bool
        switch p.get("lockAspect") {
        case nil, .null?: lock = false
        case .bool(let b)?: lock = b
        default: throw Cmd.bad(sizePos, "`lockAspect` must be true or false")
        }
        return SizeSpec(
            x: try inRange(finiteKey(p, "x"), "x", -posLimit, posLimit),
            y: try inRange(finiteKey(p, "y"), "y", -posLimit, posLimit),
            w: try inRange(finiteKey(p, "w"), "w", minPt, maxPt),
            h: try inRange(finiteKey(p, "h"), "h", minPt, maxPt),
            rot: try finiteKey(p, "rot"),
            scaleW: try inRange(finiteKey(p, "scaleW"), "scaleW", Double.leastNormalMagnitude, maxScale),
            scaleH: try inRange(finiteKey(p, "scaleH"), "scaleH", Double.leastNormalMagnitude, maxScale),
            lock: lock
        )
    }

    static func normDeg(_ r: Double) -> Double {
        let r = r.rem(360)
        return r < 0 ? r + 360 : r
    }

    /// Width wins when both sides are set with the aspect locked, matching `shape.resize`.
    static func applySize(_ x: inout Xfrm, _ spec: SizeSpec) {
        let ar = x.h > 0 ? x.w / x.h : 1
        var nw = x.w
        var nh = x.h
        if let p = spec.scaleW { nw = x.w * p / 100 }
        if let p = spec.scaleH { nh = x.h * p / 100 }
        if let w = spec.w { nw = w }
        if let h = spec.h { nh = h }
        if spec.lock && (spec.widthSet || spec.heightSet) {
            if spec.widthSet {
                nh = ar > 0 ? nw / ar : nh
            } else {
                nw = nh * ar
            }
        }
        x.w = nw.clamped(minPt, maxPt)
        x.h = nh.clamped(minPt, maxPt)
        if let px = spec.x { x.x = px }
        if let py = spec.y { x.y = py }
        if let r = spec.rot { x.rot = normDeg(r) }
    }

    @Sendable static func sizePosition(_ s: Session, _ p: JSON) throws -> JSON {
        let spec = try sizeSpec(p)
        if !spec.any {
            let st = try s.doc()
            guard let id = try Cmd.targets(s, p).first else { throw Cmd.bad(sizePos, "nothing selected") }
            guard let sh = st.shape(id) else { throw Cmd.bad(sizePos, "no such shape") }
            let x = Cmd.xfrmOf(st.doc, st.selection, sh)
            s.uiRequests.append(.dialog(id: "sizePosition", params: [
                "x": .num(x.x), "y": .num(x.y), "w": .num(x.w), "h": .num(x.h), "rot": .num(x.rot),
                "scaleW": .num(100), "scaleH": .num(100), "lockAspect": false,
            ]))
            return .null
        }
        let ids = try Cmd.targets(s, p)
        let st = try s.doc()
        let free = ids.filter { !(st.shape($0)?.locked ?? false) }
        if !ids.isEmpty && free.isEmpty { throw Cmd.bad(sizePos, "the object is locked") }
        let changed = free.contains { id in
            guard let sh = st.shape(id) else { return false }
            var x = Cmd.xfrmOf(st.doc, st.selection, sh)
            let before = x
            applySize(&x, spec)
            return x != before
        }
        if !changed { return .null }
        return try Cmd.editGeometry(s, p, sizePos) { sh in
            guard var x = sh.xfrm else { return }
            applySize(&x, spec)
            sh.xfrm = x
        }
    }

    @Sendable static func rotate(_ s: Session, _ p: JSON) throws -> JSON {
        // A trackpad twist sends many small steps. `gesture: move` keeps them as one undo; `gesture: end`
        // commits that step and does not rotate again.
        if p.get("gesture")?.asStr == "end" {
            s.commitNamed("Rotation")
            return .emptyObject
        }
        if p.get("gesture")?.asStr == "move" { s.begin("Rotation") }
        let (abs, by) = (Cmd.f64Param(p, "deg"), Cmd.f64Param(p, "by"))
        return try Cmd.editGeometry(s, p, "shape.rotate") { sh in
            guard var x = sh.xfrm else { return }
            let r = (abs ?? x.rot) + (by ?? 0)
            x.rot = (r.rem(360) + 360).rem(360)
            sh.xfrm = x
        }
    }

    @Sendable static func flip(_ s: Session, _ p: JSON) throws -> JSON {
        let v = (Cmd.strParam(p, "axis") ?? "horizontal").hasPrefix("v")
        return try Cmd.editGeometry(s, p, "shape.flip") { sh in
            guard var x = sh.xfrm else { return }
            if v { x.flipV.toggle() } else { x.flipH.toggle() }
            // `Xfrm.affine` flips first and rotates second; a true mirror also negates the rotation.
            x.rot = (360 - x.rotNorm).rem(360)
            sh.xfrm = x
        }
    }

    @Sendable static func adjust(_ s: Session, _ p: JSON) throws -> JSON {
        let i = min(Cmd.usizeParam(p, "index") ?? 0, 16)
        guard let v = Cmd.f64Param(p, "value") else { throw Cmd.bad("shape.adjust", "missing `value`") }
        return try Cmd.editGeometry(s, p, "shape.adjust") { sh in
            guard case .preset(let name, var adj) = sh.geom else { return }
            let defaults = Preset.info(name)?.defaults ?? []
            while adj.count <= i { adj.append(defaults.at(adj.count) ?? 0) }
            adj[i] = v
            sh.geom = .preset(name: name, adj: adj)
        }
    }

    /// Rectangles and rounded rectangles become custom geometry whose corners are smoothed (`Squircle`);
    /// the radius is the rounded rectangle's own unless `radius` says.
    @Sendable static func smoothCorners(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "shape.smoothCorners"
        guard let sm = Cmd.f64Param(p, "smoothing") else { throw Cmd.bad(cmd, "missing `smoothing` (0–100)") }
        let smoothing = sm.clamped(0, 100) / 100
        let radius = Cmd.f64Param(p, "radius").map { $0.rustMax(0) }
        return try Cmd.editGeometry(s, p, cmd) { sh in
            guard let x = sh.xfrm else { throw Cmd.bad(cmd, "the shape has no size of its own") }
            let ss = x.w.rustMin(x.h).rustMax(0)
            var own: Double?
            switch sh.geom {
            case .preset(let name, let adj) where name == "roundRect": own = ss * (adj.first ?? 16667).clamped(0, 50000) / 100_000
            case .preset(let name, _) where name == "rect": own = ss * 16667 / 100_000
            default: own = nil
            }
            // A custom outline qualifies only when it is a squircle this command drew with `radius`
            // (re-smoothing as the slider moves), never an arbitrary freeform.
            var custom = false
            if case .custom(let paths) = sh.geom, let r = radius, paths.count == 1, let only = paths.first {
                custom = (0 ... 100).contains { k in rustEqual(Squircle.pathD(only.w, only.h, r, Double(k) / 100), only.d) }
            }
            let r: Double
            if let rr = radius, own != nil || custom {
                r = rr
            } else if radius == nil, let o = own {
                r = o
            } else {
                throw Cmd.bad(cmd, "only rectangles, rounded rectangles and shapes already smoothed with this `radius` can be smoothed")
            }
            var path = CustomPath.default
            path.w = x.w
            path.h = x.h
            path.d = Squircle.pathD(x.w, x.h, r, smoothing)
            sh.geom = .custom(paths: [path])
        }
    }

    @Sendable static func change(_ s: Session, _ p: JSON) throws -> JSON {
        guard let name = Cmd.strParam(p, "preset") else { throw Cmd.bad("shape.change", "missing `preset`") }
        guard let info = Preset.info(name) else { throw Cmd.bad("shape.change", "unknown preset `\(name)`") }
        return try Cmd.editGeometry(s, p, "shape.change") { sh in sh.geom = .preset(info.name) }
    }

    // MARK: Fill

    /// `{stops: [[pos 0–1, color], …], kind?: linear|radial|rectangular|path, angle?: deg (linear),
    /// focus?: [l, t, r, b] fractions (radial/rectangular/path: where the first stop sits),
    /// rotateWithShape?}` (`gradient_param`).
    static func gradientParam(_ v: JSON) -> Gradient? {
        guard let arr = v.get("stops")?.asArray else { return nil }
        var stops: [GradientStop] = arr.compactMap { s in
            guard let a = s.asArray, let pos = a.first?.asF64, let c = a.at(1).flatMap(Cmd.colorValue) else { return nil }
            return GradientStop(pos: pos.clamped(0, 1), color: c)
        }
        if stops.count < 2 { return nil }
        let focus: [Double] = {
            guard let a = v.get("focus")?.asArray else { return nil }
            func f(_ i: Int) -> Double? { a.at(i)?.asF64.flatMap { $0.isFinite ? $0.clamped(0, 1) : nil } }
            guard let l = f(0), let t = f(1), let r = f(2), let b = f(3) else { return nil }
            return [l, t, r, b]
        }() ?? [0.5, 0.5, 0.5, 0.5]
        // `sort_by(total_cmp)`: stable, −0 before +0.
        stops = stops.enumerated().sorted { a, b in
            let (x, y) = (a.element.pos, b.element.pos)
            if x != y { return x < y }
            if x.sign != y.sign { return x.sign == .minus }
            return a.offset < b.offset
        }.map(\.element)
        let shape: GradientShape
        switch v.get("kind")?.asStr {
        case "radial"?, "circle"?: shape = .path(path: "circle", focus: focus)
        case "rectangular"?, "rect"?: shape = .path(path: "rect", focus: focus)
        case "path"?, "shape"?: shape = .path(path: "shape", focus: focus)
        default:
            let angle = v.get("angle")?.asF64.flatMap { $0.isFinite ? $0 : nil } ?? 90
            shape = .linear(angle: ThreeDCommands.remEuclid(angle, 360), scaled: false)
        }
        return Gradient(stops: stops, shape: shape, rotateWithShape: v.get("rotateWithShape")?.asBool ?? true, tile: [0, 0, 0, 0])
    }

    /// Fill and outline apply to a group's visible members as well as its container. Other edits (notably
    /// geometry) still target only the selected shape. The whole traversal stays in one edit.
    static func editGroupAppearance(_ s: Session, _ p: JSON, _ cmd: String, _ f: (inout Shape) throws -> Void) throws -> JSON {
        func apply(_ sh: inout Shape, _ depth: Int) throws {
            if depth > 64 { return }
            try f(&sh)
            try sh.mutateChildren { children in
                for i in children.indices { try apply(&children[i], depth + 1) }
            }
        }
        return try Cmd.editShapes(s, p, cmd) { try apply(&$0, 0) }
    }

    /// The fill a `shape.fill` request sets: `.some(nil)` clears it, `.some(fill)` sets it, and nil leaves
    /// it as it is.
    static func requestedFill(_ s: Session, _ p: JSON) throws -> Fill?? {
        if Cmd.boolOr(p, "reset", false) { return .some(nil) }
        if Cmd.boolOr(p, "none", false) { return .some(.none_) }
        if let c = Cmd.colorParam(p, "color") { return .some(.solid(c)) }
        if let g = p.get("gradient") {
            guard let gradient = gradientParam(g) else {
                throw Cmd.bad("shape.fill", "gradient needs at least two `stops`: [[0, \"#fff\"], [1, \"#000\"]]")
            }
            return .some(.gradient(gradient))
        }
        if let pt = p.get("pattern") {
            return .some(.pattern(PatternFill(
                preset: pt.get("preset")?.asStr ?? "pct50",
                fg: pt.get("fg").flatMap(Cmd.colorValue) ?? .scheme(.accent1),
                bg: pt.get("bg").flatMap(Cmd.colorValue) ?? .scheme(.bg1)
            )))
        }
        if let pic = p.get("picture") {
            let (name, bytes) = try InsertCommands.mediaBytes(Cmd.withParam(p, "data", pic), "shape.fill")
            let ct = InsertCommands.contentType(name, bytes)
            let media = try s.edit { doc, _ in
                guard let m = doc.addMedia(name, ct, bytes) else { throw Cmd.bad("shape.fill", Cmd.noIdSpace) }
                return m
            }
            return .some(.picture(PictureFill(media: media)))
        }
        return nil
    }

    /// The effective fill of each targeted shape, for a transparency change on an inherited (style) fill.
    static func inheritedFills(_ s: Session, _ p: JSON) throws -> [ShapeId: Fill?] {
        let st = try s.doc()
        let ctx = TextCommands.ctxFor(st.doc, st.selection)
        var fills: [ShapeId: Fill?] = [:]
        for id in try Cmd.targets(s, p) {
            guard let sh = st.shape(id) else { continue }
            walk([sh]) { sh, _ in
                let fill: Fill? = ctx.flatMap { c in
                    let (f, ph) = Resolve.fill(c, sh)
                    return f.map { f in
                        if case .solid(let color) = f { return .solid(.rgb(c.color(color, ph))) }
                        return f
                    }
                }
                fills[sh.id] = .some(fill)
            }
        }
        return fills
    }

    /// Applies a `shape.fill` request to one shape: the fill, then its picture options, then transparency.
    static func applyFill(_ sh: inout Shape, _ newFill: Fill??, _ picProps: JSON?, _ transparency: Double?, _ inherited: [ShapeId: Fill?]) {
        if let f = newFill { sh.fill = f }
        if let pp = picProps, case .picture(var pf)? = sh.fill {
            pictureProps(&pf, pp)
            sh.fill = .picture(pf)
        }
        if let t = transparency, case .picture(var pf)? = sh.fill {
            let a = 1 - t.clamped(0, 1)
            pf.alpha = a < 1 ? a : nil
            sh.fill = .picture(pf)
            return
        }
        if let t = transparency {
            let base = sh.fill ?? (inherited[sh.id] ?? nil)
            if case .solid(var color)? = base {
                color.mods.removeAll { if case .alpha = $0 { return true } else { return false } }
                if t > 0 { color.mods.append(.alpha(Int32(rustCast: ((1 - t.clamped(0, 1)) * 100_000).rounded()))) }
                sh.fill = .solid(color)
            }
        }
    }

    @Sendable static func fill(_ s: Session, _ p: JSON) throws -> JSON {
        let newFill = try requestedFill(s, p)
        let transparency = Cmd.f64Param(p, "transparency")
        let picProps = p.get("pictureProps").flatMap { $0.isObject ? $0 : nil }
        if newFill == nil && transparency == nil && picProps == nil {
            throw Cmd.bad("shape.fill", "give `color`, `none`, `gradient`, `pattern`, `picture`, `pictureProps`, `transparency` or `reset`")
        }
        // Transparency on an inherited (style) fill needs the effective colour.
        let inherited = try inheritedFills(s, p)
        return try editGroupAppearance(s, p, "shape.fill") { applyFill(&$0, newFill, picProps, transparency, inherited) }
    }

    /// Applies Format Shape ▸ Picture or texture fill options to a picture fill.
    static func pictureProps(_ pf: inout PictureFill, _ pp: JSON) {
        func f(_ k: String) -> Double? { pp.get(k)?.asF64.flatMap { $0.isFinite ? $0 : nil } }
        if let up = pp.get("rotateWithShape")?.asBool { pf.upright = !up }
        switch pp.get("tile")?.asBool {
        case true?:
            if case .tile = pf.mode {} else { pf.mode = .tile(tx: 0, ty: 0, sx: 1, sy: 1, flip: "none", align: "tl") }
        case false?:
            if case .stretch = pf.mode {} else { pf.mode = .default }
        default: break
        }
        switch pf.mode {
        case .tile(var tx, var ty, var sx, var sy, var flip, var align):
            if let v = f("offsetX") { tx = v.clamped(-4000, 4000) }
            if let v = f("offsetY") { ty = v.clamped(-4000, 4000) }
            if let v = f("scaleX") { sx = v.clamped(0.01, 10) }
            if let v = f("scaleY") { sy = v.clamped(0.01, 10) }
            if let m = pp.get("mirror")?.asStr, ["none", "x", "y", "xy"].contains(where: { rustEqual($0, m) }) { flip = m }
            if let a = pp.get("align")?.asStr, ["tl", "t", "tr", "l", "ctr", "r", "bl", "b", "br"].contains(where: { rustEqual($0, a) }) {
                align = a
            }
            pf.mode = .tile(tx: tx, ty: ty, sx: sx, sy: sy, flip: flip, align: align)
        case .stretch(var rect):
            if let arr = pp.get("stretch")?.asArray {
                for (i, v) in zip(rect.indices, arr) {
                    if let v = v.asF64, v.isFinite { rect[i] = v.clamped(-10, 0.99) }
                }
            }
            pf.mode = .stretch(fillRect: rect)
        }
    }

    // MARK: Outline

    static func lineEnd(_ v: String) -> LineEnd? {
        v == "none" ? nil : LineEnd(kind: v, w: "med", len: "med")
    }

    @Sendable static func line(_ s: Session, _ p: JSON) throws -> JSON {
        let reset = Cmd.boolOr(p, "reset", false)
        let none = Cmd.boolOr(p, "none", false)
        let color = Cmd.colorParam(p, "color")
        let width = Cmd.f64Param(p, "width").map { $0.clamped(0, 1584) }
        let dash = Cmd.strParam(p, "dash").map { Dash.preset(name: $0) }
        let head: LineEnd?? = Cmd.strParam(p, "head").map(lineEnd)
        let tail: LineEnd?? = Cmd.strParam(p, "tail").map(lineEnd)
        let cap: LineCap? = Cmd.strParam(p, "cap").map { c in
            switch c {
            case "round": .round
            case "square": .square
            default: .flat
            }
        }
        let compound: Compound? = Cmd.strParam(p, "compound").map { c in
            switch c {
            case "double": .double
            case "thickThin": .thickThin
            case "thinThick": .thinThick
            case "triple": .triple
            default: .single
            }
        }
        func endSize(_ k: String) -> String? {
            guard let v = Cmd.strParam(p, k), ["sm", "med", "lg"].contains(where: { rustEqual($0, v) }) else { return nil }
            return v
        }
        let (headSize, tailSize) = (endSize("headSize"), endSize("tailSize"))
        let join: LineJoin? = Cmd.strParam(p, "join").map { c in
            switch c {
            case "bevel": .bevel
            case "miter": .miter
            default: .round
            }
        }
        return try editGroupAppearance(s, p, "shape.line") { sh in
            if reset {
                sh.line = nil
                return
            }
            var l = sh.line ?? Line()
            if none { l.fill = .none_ }
            if let c = color { l.fill = .solid(c) }
            if width != nil {
                l.width = width
                if l.fill == nil || (l.fill?.isNone == true && !none) { l.fill = .solid(.scheme(.tx1)) }
            }
            if dash != nil { l.dash = dash }
            func keepSize(_ old: LineEnd?, _ new: LineEnd?) -> LineEnd? {
                guard var n = new else { return nil }
                if let o = old {
                    n.w = o.w
                    n.len = o.len
                }
                return n
            }
            if let h = head { l.head = keepSize(l.head, h) }
            if let t = tail { l.tail = keepSize(l.tail, t) }
            if cap != nil { l.cap = cap }
            if join != nil { l.join = join }
            if compound != nil { l.compound = compound }
            // Arrowhead size (width and length together), kept when the kind changes.
            if var e = l.head, let sz = headSize {
                e.w = sz
                e.len = sz
                l.head = e
            }
            if var e = l.tail, let sz = tailSize {
                e.w = sz
                e.len = sz
                l.tail = e
            }
            sh.line = l
        }
    }

    // MARK: Effects

    static func shadowBase(_ inner: Bool) -> Shadow {
        Shadow(color: ColorRef.rgb(.black).with(.alpha(40000)), blur: 4, dist: 3, dir: 45, inner: inner, sx: 1, sy: 1, kx: 0, ky: 0, align: "tl", rotateWithShape: false)
    }

    /// nil: not a shadow request; `.some(nil)`: no shadow.
    static func shadowPreset(_ v: JSON) -> Shadow?? {
        switch v {
        case .string(let s):
            switch s {
            case "none": return .some(nil)
            case "inner": return .some(shadowBase(true))
            case "perspective":
                var x = shadowBase(false)
                x.sy = 0.23
                x.kx = -1_200_000.0 / 60000.0
                x.dir = 90
                x.dist = 0
                x.blur = 6
                x.align = "bl"
                return .some(x)
            case "bottom":
                var x = shadowBase(false)
                x.dir = 90
                return .some(x)
            case "center":
                var x = shadowBase(false)
                x.dist = 0
                x.blur = 8
                return .some(x)
            default: return .some(shadowBase(false))
            }
        case .object(let o):
            var x = shadowBase(false)
            x.color = o["color"].flatMap(Cmd.colorValue) ?? ColorRef.rgb(.black).with(.alpha(40000))
            x.blur = (o["blur"]?.asF64 ?? 4).clamped(0, 200)
            x.dist = (o["dist"]?.asF64 ?? 3).clamped(0, 200)
            x.dir = o["dir"]?.asF64 ?? 45
            x.inner = o["inner"]?.asBool ?? false
            return .some(x)
        default:
            return nil
        }
    }

    static func defaultGlow() -> Glow { Glow(color: ColorRef.scheme(.accent1).with(.alpha(40000)), radius: 8) }

    @Sendable static func effects(_ s: Session, _ p: JSON) throws -> JSON {
        let reset = Cmd.boolOr(p, "reset", false)
        let shadow: Shadow?? = p.get("shadow").flatMap(shadowPreset)
        let glow: Glow?? = p.get("glow").map { g in
            switch g {
            case .object(let o):
                return Glow(color: o["color"].flatMap(Cmd.colorValue) ?? ColorRef.scheme(.accent1).with(.alpha(40000)), radius: (o["radius"]?.asF64 ?? 8).clamped(0, 150))
            case .uint, .int, .double, .float:
                return Glow(color: ColorRef.scheme(.accent1).with(.alpha(40000)), radius: (g.asF64 ?? 8).clamped(0, 150))
            default:
                return nil
            }
        }
        let soft: Double?? = p.get("softEdges").map { v in v.asF64.flatMap { $0 > 0 ? $0.rustMin(100) : nil } }
        let refl: Reflection?? = Cmd.strParam(p, "reflection").map { r in
            switch r {
            case "none": nil
            case "half": Reflection(blur: 0.5, startAlpha: 0.5, endAlpha: 0, endPos: 0.55, dist: 4)
            case "full": Reflection(blur: 0.5, startAlpha: 0.5, endAlpha: 0, endPos: 0.9, dist: 4)
            default: Reflection(blur: 0.5, startAlpha: 0.5, endAlpha: 0, endPos: 0.35, dist: 0)
            }
        }
        let threeD = p.get("threeD").flatMap { $0.isObject ? $0 : nil }
        let bevel: String?? = Cmd.strParam(p, "bevel").map { $0 == "none" ? nil : $0 }
        let shadowProps = p.get("shadowProps").flatMap { $0.isObject ? $0 : nil }
        let glowProps = p.get("glowProps").flatMap { $0.isObject ? $0 : nil }
        let reflProps = p.get("reflectionProps").flatMap { $0.isObject ? $0 : nil }
        return try Cmd.editShapes(s, p, "shape.effects") { sh in
            if reset {
                sh.effects = nil
                return
            }
            var e = sh.effects ?? Effects()
            defer { sh.effects = e }
            if let sw = shadow {
                switch sw {
                case let x? where x.inner:
                    e.innerShadow = x
                    e.outerShadow = nil
                case let x?:
                    e.outerShadow = x
                    e.innerShadow = nil
                case nil:
                    e.outerShadow = nil
                    e.innerShadow = nil
                }
            }
            if let g = glow { e.glow = g }
            if let sf = soft { e.softEdge = sf }
            if let r = refl { e.reflection = r }
            if bevel != nil || threeD != nil {
                var s3 = e.raw3d.map(ThreeDCommands.Shape3d.parse) ?? .default
                if let b = bevel { s3.apply(["bevelTop": .string(b ?? "none")]) }
                if let t = threeD {
                    if t.get("reset")?.asBool == true { s3 = .default }
                    s3.apply(t)
                }
                ThreeDCommands.store(&e, s3)
            }
            if let v = shadowProps {
                let inner = e.innerShadow != nil
                guard var x = (inner ? e.innerShadow : e.outerShadow) ?? (shadowPreset("outer") ?? nil) else {
                    throw Cmd.bad("shape.effects", "no shadow preset")
                }
                if let c = v.get("color").flatMap(Cmd.colorValue) {
                    let a = x.color.alpha
                    x.color = withAlpha(c, a)
                }
                if let t = num(v, "transparency") { x.color = withAlpha(x.color, 1 - t.clamped(0, 1)) }
                if let b = num(v, "blur") { x.blur = b.clamped(0, 100) }
                if let d = num(v, "dist") { x.dist = d.clamped(0, 200) }
                if let d = num(v, "dir") { x.dir = ThreeDCommands.remEuclid(d, 360) }
                if inner { e.innerShadow = x } else { e.outerShadow = x }
            }
            if let v = glowProps {
                var g = e.glow ?? defaultGlow()
                if let c = v.get("color").flatMap(Cmd.colorValue) {
                    let a = g.color.alpha
                    g.color = withAlpha(c, a)
                }
                if let t = num(v, "transparency") { g.color = withAlpha(g.color, 1 - t.clamped(0, 1)) }
                if let r = num(v, "radius") { g.radius = r.clamped(0, 150) }
                e.glow = g.radius > 0 ? g : nil
            }
            if let v = reflProps {
                var r = e.reflection ?? Reflection(blur: 0.5, startAlpha: 0.5, endAlpha: 0, endPos: 0.35, dist: 0)
                if let t = num(v, "transparency") { r.startAlpha = 1 - t.clamped(0, 1) }
                if let sz = num(v, "size") { r.endPos = sz.clamped(0, 1) }
                if let d = num(v, "dist") { r.dist = d.clamped(0, 100) }
                if let b = num(v, "blur") { r.blur = b.clamped(0, 100) }
                e.reflection = r
            }
        }
    }

    /// A finite number at `key` of an effect's properties.
    static func num(_ v: JSON, _ key: String) -> Double? {
        v.get(key)?.asF64.flatMap { $0.isFinite ? $0 : nil }
    }

    /// `c` with its alpha set to `a` (0–1); fully opaque drops the transform.
    static func withAlpha(_ c: ColorRef, _ a: Double) -> ColorRef {
        var c = c
        c.mods.removeAll { if case .alpha = $0 { return true } else { return false } }
        if a < 1 { c.mods.append(.alpha(Int32(rustCast: (a.clamped(0, 1) * 100_000).rounded()))) }
        return c
    }

    // MARK: Styles

    /// Theme quick styles: 7 rows (outline only, solid fill variants, intense…) × 6 accents.
    public static func quickStyleFor(_ index: Int) -> (ShapeStyle, Fill?, Line?) {
        let slots: [SchemeSlot] = [.dk1, .accent1, .accent2, .accent3, .accent4, .accent5, .accent6]
        let slot = slots.at(index % 7) ?? .accent1
        let row = index / 7
        var st = ShapeStyle.accent(slot)
        let c = ColorRef.scheme(slot)
        switch row {
        case 0:
            // Coloured outline, light fill.
            st.fillRef = Pair(1, .scheme(.lt1))
            st.lineRef = Pair(2, c)
            st.fontRef.b = .scheme(.dk1)
            return (st, nil, nil)
        case 1:
            return (st, nil, nil)
        case 2:
            st.fillRef = Pair(1, c.with(.lumMod(20000)).with(.lumOff(80000)))
            st.lineRef = Pair(0, c)
            st.fontRef.b = c.with(.lumMod(50000))
            return (st, nil, Line.none())
        case 3:
            st.fillRef = Pair(2, c)
            return (st, nil, Line.none())
        case 4:
            st.fillRef = Pair(3, c)
            st.effectRef = Pair(3, c)
            return (st, nil, Line.none())
        default:
            st.fillRef = Pair(1, c.with(.lumMod(75000)))
            st.lineRef = Pair(1, .scheme(.lt1))
            return (st, nil, nil)
        }
    }

    @Sendable static func quickStyle(_ s: Session, _ p: JSON) throws -> JSON {
        let i = min(Cmd.usizeParam(p, "index") ?? 1, 41)
        let (st, f, l) = quickStyleFor(i)
        return try Cmd.editShapes(s, p, "shape.quickStyle") { sh in
            sh.style = st
            sh.fill = f
            sh.line = l
            sh.effects = nil
            if var t = sh.text {
                TextEdit.formatAll(&t) { $0.fill = nil }
                sh.text = t
            }
        }
    }

    // MARK: Names, alt text, visibility, lock, default look

    @Sendable static func rename(_ s: Session, _ p: JSON) throws -> JSON {
        guard let name = Cmd.strParam(p, "name") else { throw Cmd.bad("shape.rename", "missing `name`") }
        return try Cmd.editShapes(s, p, "shape.rename") { $0.name = name }
    }

    @Sendable static func altText(_ s: Session, _ p: JSON) throws -> JSON {
        let text = Cmd.strParam(p, "text") ?? ""
        let deco = Cmd.boolParam(p, "decorative")
        return try Cmd.editShapes(s, p, "shape.altText") { sh in
            sh.descr = text
            if let d = deco { sh.decorative = d }
        }
    }

    @Sendable static func visible(_ s: Session, _ p: JSON) throws -> JSON {
        let v = Cmd.boolParam(p, "visible")
        return try Cmd.editShapes(s, p, "shape.visible") { sh in sh.hidden = !(v ?? sh.hidden) }
    }

    /// Lock: a locked object can be selected, formatted and typed in, but not moved, sized, rotated, flipped,
    /// reshaped or cropped. Locking or unlocking a group does the same to everything in it (a child can still
    /// be unlocked on its own afterwards), as PowerPoint does.
    @Sendable static func lock(_ s: Session, _ p: JSON) throws -> JSON {
        let v = Cmd.boolParam(p, "locked")
        return try Cmd.editShapes(s, p, "shape.lock") { sh in
            let to = v ?? !sh.locked
            setLocked(&sh, to, 0)
        }
    }

    static func setLocked(_ sh: inout Shape, _ to: Bool, _ depth: Int) {
        sh.locked = to
        if depth > 64 { return }
        sh.mutateChildren { children in
            for i in children.indices { setLocked(&children[i], to, depth + 1) }
        }
    }

    @Sendable static func setDefault(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        guard let sh = st.selectedShapes.first else { return Cmd.ok() }
        // New shapes drawn in this session take this look (Set as Default Shape).
        s.defaultLook = Painted(
            run: sh.text?.paragraphs.first?.runs.first?.props,
            para: nil,
            fill: sh.fill,
            line: sh.line,
            effects: sh.effects,
            style: sh.style
        )
        return Cmd.ok()
    }

    // MARK: Pictures

    @Sendable static func crop(_ s: Session, _ p: JSON) throws -> JSON {
        let c = [Cmd.f64Param(p, "left"), Cmd.f64Param(p, "top"), Cmd.f64Param(p, "right"), Cmd.f64Param(p, "bottom")]
        return try Cmd.editGeometry(s, p, "picture.crop") { sh in
            guard case .picture(var fill) = sh.kind else { return }
            for (i, v) in c.enumerated() {
                if let v, fill.crop.indices.contains(i) { fill.crop[i] = v.clamped(-10, 0.95) }
            }
            sh.kind = .picture(fill: fill)
        }
    }

    @Sendable static func pictureAdjust(_ s: Session, _ p: JSON) throws -> JSON {
        try Cmd.editShapes(s, p, "picture.adjust") { sh in
            guard case .picture(var fill) = sh.kind else { return }
            if Cmd.boolOr(p, "reset", false) { fill.adjust = .default }
            if let v = Cmd.f64Param(p, "brightness") { fill.adjust.brightness = v.clamped(-1, 1) }
            if let v = Cmd.f64Param(p, "contrast") { fill.adjust.contrast = v.clamped(-1, 1) }
            if let v = Cmd.f64Param(p, "saturation") { fill.adjust.saturation = v.clamped(0, 4) }
            if let v = Cmd.boolParam(p, "grayscale") { fill.adjust.grayscale = v }
            if let v = Cmd.f64Param(p, "transparency") { fill.alpha = (1 - v).clamped(0, 1) }
            sh.kind = .picture(fill: fill)
        }
    }

    @Sendable static func pictureReset(_ s: Session, _ p: JSON) throws -> JSON {
        try Cmd.editShapes(s, p, "picture.reset") { sh in
            if case .picture(var fill) = sh.kind {
                fill.adjust = .default
                fill.crop = [0, 0, 0, 0]
                fill.alpha = nil
                if let a = fill.artistic {
                    fill.artistic = nil
                    fill.media = a.original
                }
                sh.kind = .picture(fill: fill)
            }
            sh.effects = nil
            sh.line = nil
        }
    }

    @Sendable static func pictureChange(_ s: Session, _ p: JSON) throws -> JSON {
        let (name, bytes) = try InsertCommands.mediaBytes(p, "picture.change")
        let ct = InsertCommands.contentType(name, bytes)
        let media = try s.edit { doc, _ in
            guard let m = doc.addMedia(name, ct, bytes) else { throw Cmd.bad("picture.change", Cmd.noIdSpace) }
            return m
        }
        return try Cmd.editShapes(s, p, "picture.change") { sh in
            guard case .picture(var fill) = sh.kind else { return }
            fill.media = media
            fill.crop = [0, 0, 0, 0]
            fill.artistic = nil
            sh.kind = .picture(fill: fill)
        }
    }

    @Sendable static func mediaOptions(_ s: Session, _ p: JSON) throws -> JSON {
        _ = try Cmd.editShapes(s, p, "media.options") { sh in
            guard case .media(var m) = sh.kind else { return }
            if let v = Cmd.boolParam(p, "autoplay") { m.autoplay = v }
            if let v = Cmd.boolParam(p, "loop") { m.loopPlay = v }
            if let v = Cmd.boolParam(p, "rewind") { m.rewind = v }
            if let v = Cmd.boolParam(p, "acrossSlides") { m.playAcrossSlides = v }
            if let v = Cmd.boolParam(p, "hide") { m.hideWhileNotPlaying = v }
            if let v = Cmd.boolParam(p, "fullScreen") { m.fullScreen = v }
            if let v = Cmd.f64Param(p, "volume") { m.volume = v.clamped(0, 1) }
            func ms(_ k: String) -> UInt32? { p.get(k)?.asU64.map { UInt32(min($0, UInt64(UInt32.max))) } }
            if let v = ms("trimStart") { m.trimStartMs = v }
            if let v = ms("trimEnd") { m.trimEndMs = v }
            if let v = ms("fadeIn") { m.fadeInMs = v }
            if let v = ms("fadeOut") { m.fadeOutMs = v }
            sh.kind = .media(m)
        }
        return .emptyObject
    }

    // MARK: Connectors and freeforms

    @Sendable static func sites(_ s: Session, _ p: JSON) throws -> JSON {
        guard let id = try Cmd.idParam(p, "id", "shape.sites") else { throw Cmd.bad("shape.sites", "missing `id`") }
        let st = try s.doc()
        guard let sh = st.shape(id) else { throw Cmd.bad("shape.sites", "no such shape") }
        return .array(Connect.sites(st.doc, st.selection, sh).map { [.num($0.x), .num($0.y)] })
    }

    @Sendable static func connect(_ s: Session, _ p: JSON) throws -> JSON {
        guard let from = try Cmd.idParam(p, "from", "shape.connect"), let to = try Cmd.idParam(p, "to", "shape.connect") else {
            throw Cmd.bad("shape.connect", "missing `from` / `to`")
        }
        let st = try s.doc()
        func siteList(_ id: ShapeId) -> [Point] { st.shape(id).map { Connect.sites(st.doc, st.selection, $0) } ?? [] }
        let (a, b) = (siteList(from), siteList(to))
        if a.isEmpty || b.isEmpty {
            throw Cmd.bad("shape.connect", "both shapes need connection sites (lines and groups have none)")
        }
        func pick(_ v: [Point], _ key: String) -> Int? { Cmd.usizeParam(p, key).flatMap { $0 < v.count ? $0 : nil } }
        let (fi, fj) = (pick(a, "fromSite"), pick(b, "toSite"))
        var (ia, ib) = (0, 0)
        if let i = fi, let j = fj {
            (ia, ib) = (i, j)
        } else {
            var best = (Double.greatestFiniteMagnitude, 0, 0)
            for (i, pa) in a.enumerated() where fi == nil || fi == i {
                for (j, pb) in b.enumerated() where fj == nil || fj == j {
                    let d = (pa - pb).hypot
                    if d < best.0 { best = (d, i, j) }
                }
            }
            (ia, ib) = (best.1, best.2)
        }
        let (p0, p1) = (a[ia], b[ib])
        let id: ShapeId
        if let given = try Cmd.idParam(p, "id", "shape.connect") {
            id = given
        } else {
            let preset = Cmd.strParam(p, "preset") ?? "straightConnector1"
            let r = try s.execute("shape.insert", ["preset": .string(preset), "rect": [.num(p0.x), .num(p0.y), 1.0, 1.0]])
            guard let n = r.get("id")?.asU64 else { throw Cmd.bad("shape.connect", "insert failed") }
            id = ShapeId(UInt32(truncatingIfNeeded: n))
        }
        try s.edit { doc, sel in
            try withShapes(&doc, sel, missing: Cmd.bad("shape.connect", "no slide")) { list in
                let found: Void? = try withShape(&list, id) { sh in
                    if !sh.isLine { throw Cmd.bad("shape.connect", "`id` is not a line or connector") }
                    sh.xfrm = Tools.lineXfrm(p0, p1, 0)
                    sh.kind = .connector(start: Pair(from, UInt32(ia)), end: Pair(to, UInt32(ib)))
                }
                if found == nil { throw Cmd.bad("shape.connect", "no such line") }
            }
        }
        return ["id": id.toJSON(), "fromSite": .integer(ia), "toSite": .integer(ib)]
    }

    /// Path data through `pts` (shape-local): straight segments, or a Catmull-Rom curve as cubics.
    public static func freeformPath(_ pts: [Point], _ closed: Bool, _ smooth: Bool) -> String {
        func f(_ v: Double) -> String { trimFixed(rustFixed(v, places: 2)) }
        guard let first = pts.first else { return "" }
        var d = "M \(f(first.x)) \(f(first.y))"
        let n = pts.count
        if smooth && n > 2 {
            func at(_ i: Int) -> Point {
                if closed { return pts[((i % n) + n) % n] }
                return pts[max(0, min(i, n - 1))]
            }
            let segs = closed ? n : n - 1
            for i in 0 ..< segs {
                let (p0, p1, p2, p3) = (at(i - 1), at(i), at(i + 1), at(i + 2))
                let c1 = p1 + (p2 - p0) / 6.0
                let c2 = p2 - (p3 - p1) / 6.0
                d += " C \(f(c1.x)) \(f(c1.y)) \(f(c2.x)) \(f(c2.y)) \(f(p2.x)) \(f(p2.y))"
            }
        } else {
            for q in pts.dropFirst() { d += " L \(f(q.x)) \(f(q.y))" }
        }
        if closed { d += " Z" }
        return d
    }

    /// `s.trim_end_matches('0').trim_end_matches('.')`.
    static func trimFixed(_ s: String) -> String {
        var t = Substring(s)
        while t.last == "0" { t = t.dropLast() }
        while t.last == "." { t = t.dropLast() }
        return String(t)
    }

    @Sendable static func freeform(_ s: Session, _ p: JSON) throws -> JSON {
        var pts: [Point] = []
        for v in p.get("points")?.asArray ?? [] {
            guard let x = v.at(0)?.asF64, let y = v.at(1)?.asF64, x.isFinite, y.isFinite else { continue }
            pts.append(Point(x, y))
            if pts.count >= 20_000 { break }
        }
        guard pts.count >= 2, let p0 = pts.first else { throw Cmd.bad("shape.freeform", "need at least two points") }
        let closed = Cmd.boolOr(p, "closed", false) && pts.count > 2
        let smooth = Cmd.boolOr(p, "smooth", false)
        var bb = Rect.fromPoints(p0, p0)
        for q in pts { bb = bb.unionPoint(q) }
        let (w, h) = (bb.width.rustMax(1), bb.height.rustMax(1))
        let local = pts.map { Point($0.x - bb.x0, $0.y - bb.y0) }
        let d = freeformPath(local, closed, smooth)
        // Closed shapes take the default shape style, open paths the line style.
        let r = try s.execute("shape.insert", ["preset": .string(closed ? "rect" : "line"), "rect": [.num(bb.x0), .num(bb.y0), .num(w), .num(h)]])
        guard let n = r.get("id")?.asU64 else { throw Cmd.bad("shape.freeform", "insert failed") }
        let id = ShapeId(UInt32(truncatingIfNeeded: n))
        try s.edit { doc, sel in
            try withShapes(&doc, sel, missing: Cmd.bad("shape.freeform", "no slide")) { list in
                let found: Void? = withShape(&list, id) { sh in
                    sh.geom = .custom(paths: [CustomPath(w: w, h: h, d: d, fill: closed ? .norm : .none, stroke: true)])
                    sh.xfrm = Xfrm(bb.x0, bb.y0, w, h)
                    sh.kind = .shape
                    sh.name = "Freeform \(id.rawValue)"
                }
                if found == nil { throw Cmd.bad("shape.freeform", "insert failed") }
            }
        }
        return ["id": id.toJSON()]
    }

    // MARK: Ink to Shape

    /// Draw › Ink to Shape: each recognisable stroke of the slide's ink becomes a preset shape outlined in
    /// the stroke's colour and width; the rest stays ink. One undo step.
    @Sendable static func inkToShape(_ s: Session, _ p: JSON) throws -> JSON {
        let shapes = try s.doc().shapes
        let empty: JSON = ["shapes": .array([]), "kept": 0]
        guard let ink = shapes.first(where: { if case .ink = $0.kind { return true } else { return false } }) else { return empty }
        let (inkId, off) = (ink.id, ink.xfrm.map { ($0.x, $0.y) } ?? (0, 0))
        guard case .ink(let strokes) = ink.kind else { return empty }
        let found: [InkShape.Recognized?] = strokes.map { st in
            st.highlighter ? nil : InkShape.recognize(st.points.map { ($0.a + off.0, $0.b + off.1) })
        }
        if found.allSatisfy({ $0 == nil }) { return ["shapes": .array([]), "kept": .integer(strokes.count)] }
        return try s.edit { doc, sel in
            var made: [(String, Xfrm, Rgba, Double)] = []
            let remaining: Int = try withShapes(&doc, sel, missing: Cmd.bad("draw.inkToShape", "no slide")) { list in
                guard let pos = list.firstIndex(where: { $0.id == inkId }) else { throw Cmd.bad("draw.inkToShape", "ink gone") }
                guard case .ink(let all) = list[pos].kind else { throw Cmd.bad("draw.inkToShape", "not ink") }
                var kept: [InkStroke] = []
                for (st, r) in zip(all, found) {
                    guard let r else {
                        kept.append(st)
                        continue
                    }
                    switch r {
                    case .line(let x0, let y0, let x1, let y1):
                        made.append(("line", Tools.lineXfrm(Point(x0, y0), Point(x1, y1), 0), st.color, st.width))
                    case .rect(let x, let y, let w, let h):
                        made.append(("rect", Xfrm(x, y, w, h), st.color, st.width))
                    case .ellipse(let x, let y, let w, let h):
                        made.append(("ellipse", Xfrm(x, y, w, h), st.color, st.width))
                    case .triangle(let x, let y, let w, let h, let flipV):
                        var xf = Xfrm(x, y, w, h)
                        xf.flipV = flipV
                        made.append(("triangle", xf, st.color, st.width))
                    }
                }
                // `zip` stops at the shorter list, as Rust's does: strokes beyond `found` are dropped.
                list[pos].kind = .ink(strokes: kept)
                if kept.isEmpty { list.remove(at: pos) }
                return kept.count
            }
            var new: [ShapeId] = []
            for (preset, xfrm, color, width) in made {
                guard let raw = doc.allocId() else { throw Cmd.bad("draw.inkToShape", Cmd.noIdSpace) }
                let id = ShapeId(raw)
                let label = switch preset {
                case "line": "Straight Connector"
                case "rect": "Rectangle"
                case "ellipse": "Oval"
                default: "Isosceles Triangle"
                }
                var sh = Shape.default
                sh.id = id
                sh.name = "\(label) \(raw)"
                sh.xfrm = xfrm
                sh.geom = .preset(preset)
                sh.fill = .none_
                sh.line = Line.solid(.rgb(color), width.clamped(0.25, 100))
                sh.kind = .shape
                try withShapes(&doc, sel, missing: Cmd.bad("draw.inkToShape", "no slide")) { $0.append(sh) }
                new.append(id)
            }
            sel.shapes = new
            return ["shapes": new.toJSON(), "kept": .integer(remaining)]
        }
    }
}

// MARK: - Interactions (tools.rs `begin` / `commit_named`, used by `shape.rotate`'s gestures)

extension Session {
    /// Start an interaction labelled `label` (one undo step at its end) unless one is running.
    func begin(_ label: String) {
        let vertexKind = tool.vertexKind
        guard let st = activeDoc, st.interaction == nil else { return }
        st.interaction = Interaction(label: label, doc: st.docRef, selection: st.selection, vertexKind: vertexKind)
    }

    /// End the interaction only when it is the one `label` started. A twist must not commit a drag.
    func commitNamed(_ label: String) {
        guard let st = activeDoc, let i = st.interaction, i.label == label else { return }
        st.interaction = nil
        if i.doc !== st.docRef {
            pushUndo(st, HistoryEntry(label: i.label, doc: i.doc, selection: i.selection, vertexKind: i.vertexKind))
        }
    }
}
