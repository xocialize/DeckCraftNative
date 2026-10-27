// DCEngine — the `recolor` command module: Picture Format ▸ Color, the Recolor presets and Set Transparent
// Color.
// Port of deckcraft crates/engine/src/cmd/recolor.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// Recolouring stores only settings on the picture (`PictureAdjust`): the renderer applies them. Set
// Transparent Color's `at` reads the colour of one pixel of the picture as stored and keeps it in the
// document (`clearColor`), so it decodes the picture as deckcraft does (DCRender's `Images.decode`, which
// keeps a PNG's stored values exactly).
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCRender

public enum RecolorCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd("picture.recolor", "Recolor", ["Picture Format", "Adjust", "Color"], nil, "{preset: none|grayscale|sepia|washout|bw25|bw50|bw75|accent1Dark…accent6Dark|accent1Light…accent6Light|tx2Dark|tx2Light (see picture.recolors), ids?}", Cmd.hasSelection, recolor),
            .query("picture.recolors", "Recolor Gallery", [], nil, "{} → [{id, label}]", Cmd.always) { _, _ in
                .array(presets().map { ["id": .string($0.0), "label": .string($0.1)] })
            },
            .cmd("picture.transparentColor", "Set Transparent Color", ["Picture Format", "Adjust", "Color"], nil, "{color: #RRGGBB | at: [x, y] | none: true, ids?} (pixels of that colour become transparent; `at` takes the colour of the picture's own pixel under that slide point, as a click does in PowerPoint)", Cmd.hasSelection, transparentColor),
        ]
    }

    static let accents: [(String, String, SchemeSlot)] = [
        ("tx2", "Text color 2", .dk2),
        ("accent1", "Accent color 1", .accent1),
        ("accent2", "Accent color 2", .accent2),
        ("accent3", "Accent color 3", .accent3),
        ("accent4", "Accent color 4", .accent4),
        ("accent5", "Accent color 5", .accent5),
        ("accent6", "Accent color 6", .accent6),
    ]

    /// (id, label), in PowerPoint's gallery order: colour modes, then dark and light variations.
    public static func presets() -> [(String, String)] {
        var v: [(String, String)] = [
            ("none", "No Recolor"),
            ("grayscale", "Grayscale"),
            ("sepia", "Sepia"),
            ("washout", "Washout"),
            ("bw25", "Black and White: 25%"),
            ("bw50", "Black and White: 50%"),
            ("bw75", "Black and White: 75%"),
        ]
        for (id, label, _) in accents { v.append(("\(id)Dark", "\(label) Dark")) }
        for (id, label, _) in accents { v.append(("\(id)Light", "\(label) Light")) }
        return v
    }

    /// Set `a`'s recolour to `preset`, clearing any earlier one. False for an unknown preset.
    @discardableResult
    public static func apply(_ a: inout PictureAdjust, _ preset: String) -> Bool {
        let washed = a.brightness == 0.7 && a.contrast == -0.7
        var n = a
        n.grayscale = false
        n.duotone = nil
        n.bilevel = nil
        if washed {
            n.brightness = 0
            n.contrast = 0
        }
        func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> ColorRef { .rgb(Rgba.rgb(r, g, b)) }
        switch preset {
        case "none": break
        case "grayscale": n.grayscale = true
        // PowerPoint's sepia is a duotone from dark brown to light cream.
        case "sepia": n.duotone = Pair(rgb(0x40, 0x2A, 0x10), rgb(0xF2, 0xE3, 0xC6))
        // Washout is PowerPoint's +70% brightness, −70% contrast.
        case "washout":
            n.brightness = 0.7
            n.contrast = -0.7
        case "bw25": n.bilevel = 0.25
        case "bw50": n.bilevel = 0.5
        case "bw75": n.bilevel = 0.75
        default:
            var found: (SchemeSlot, Bool)?
            for (id, _, slot) in accents where preset.hasPrefix(id) {
                let rest = preset.dropFirst(id.count)
                if rest == "Dark" { found = (slot, true) } else if rest == "Light" { found = (slot, false) }
                if found != nil { break }
            }
            guard let (slot, dark) = found else { return false }
            let c = ColorRef.scheme(slot)
            n.duotone = dark ? Pair(rgb(0, 0, 0), c) : Pair(c, rgb(0xFF, 0xFF, 0xFF))
        }
        a = n
        return true
    }

    @Sendable static func recolor(_ s: Session, _ p: JSON) throws -> JSON {
        guard let preset = Cmd.strParam(p, "preset") else { throw Cmd.bad("picture.recolor", "missing `preset`") }
        if !presets().contains(where: { rustEqual($0.0, preset) }) {
            throw Cmd.bad("picture.recolor", "unknown preset `\(preset)`; see picture.recolors")
        }
        return try Cmd.editShapes(s, p, "picture.recolor") { sh in
            guard case .picture(var fill) = sh.kind else { return }
            apply(&fill.adjust, preset)
            sh.kind = .picture(fill: fill)
        }
    }

    @Sendable static func transparentColor(_ s: Session, _ p: JSON) throws -> JSON {
        if let at = p.get("at") {
            let (id, c) = try picturePixelAt(s, p, at)
            return try Cmd.editShapes(s, ["ids": [id.toJSON()]], "picture.transparentColor") { sh in
                guard case .picture(var fill) = sh.kind else { return }
                fill.adjust.clearColor = c
                sh.kind = .picture(fill: fill)
            }
        }
        let c: Rgba?
        if Cmd.boolOr(p, "none", false) {
            c = nil
        } else {
            guard let hex = Cmd.strParam(p, "color") else {
                throw Cmd.bad("picture.transparentColor", "give `color` (#RRGGBB) or `none: true`")
            }
            guard let v = Rgba.fromHex(String(hex.unicodeScalars.drop { $0 == "#" })) else {
                throw Cmd.bad("picture.transparentColor", "bad colour `\(hex)`")
            }
            c = v
        }
        return try Cmd.editShapes(s, p, "picture.transparentColor") { sh in
            guard case .picture(var fill) = sh.kind else { return }
            fill.adjust.clearColor = c
            sh.kind = .picture(fill: fill)
        }
    }

    /// Rust's `Option<Vec<usize>>` order: nil first, then the paths lexicographically.
    static func pathLess(_ a: [Int]?, _ b: [Int]?) -> Bool {
        switch (a, b) {
        case (nil, nil): false
        case (nil, _): true
        case (_, nil): false
        case (let x?, let y?): x.lexicographicallyPrecedes(y)
        }
    }

    /// The topmost target picture under slide point `at` and the colour of its own pixel there: the picture
    /// as stored, before corrections and recolouring, so the colour matches the pixels that `clearColor` is
    /// compared with.
    static func picturePixelAt(_ s: Session, _ p: JSON, _ at: JSON) throws -> (ShapeId, Rgba) {
        let cmd = "picture.transparentColor"
        func xy(_ i: Int) -> Double? { at.at(i)?.asF64.flatMap { $0.isFinite ? $0 : nil } }
        guard let x = xy(0), let y = xy(1) else { throw Cmd.bad(cmd, "`at` is [x, y] in slide units") }
        var ids = try Cmd.targets(s, p)
        let st = try s.doc()
        guard let shapes = Cmd.currentShapes(st.doc, st.selection) else { throw Cmd.bad(cmd, "no slide") }
        // Same order as the hit-test: later in the shape list is in front, and a group's children sit where
        // the group is. The selection order says nothing about what is on top.
        let keys = ids.map { stackPath(shapes, $0) }
        ids = ids.indices.sorted { a, b in
            if pathLess(keys[b], keys[a]) { return true }
            if pathLess(keys[a], keys[b]) { return false }
            return a < b
        }.map { ids[$0] }
        for id in ids {
            guard let (sh, xf, toSlide) = placed(st.doc, st.selection, shapes, id, .identity, 0) else { continue }
            guard case .picture(let fill) = sh.kind else { continue }
            // The camera turns the picture where it is drawn, so the click is mapped back through it too.
            let turn = TextCommands.ctxFor(st.doc, st.selection).flatMap { cameraTurn($0, sh, xf.w, xf.h) } ?? .identity
            let local = (toSlide * turn).inverse * Point(x, y)
            guard local.isFinite, local.x >= 0, local.x <= xf.w, local.y >= 0, local.y <= xf.h else { continue }
            guard case .stretch(let fillRect) = fill.mode else {
                throw Cmd.bad(cmd, "a tiled picture has no single pixel under a point; give `color`")
            }
            let fr = fillRect.count == 4 ? fillRect : [0, 0, 0, 0]
            let (l, t, r, b) = (fr[0], fr[1], fr[2], fr[3])
            let inner = Rect(l * xf.w, t * xf.h, xf.w - r * xf.w, xf.h - b * xf.h)
            let dest = cropDest(inner, fill.crop)
            guard let img = st.doc.media(fill.media).flatMap({ Images.decode($0.data) }) else {
                throw Cmd.bad(cmd, "the picture can't be read")
            }
            let (u, v) = ((local.x - dest.x0) / dest.width, (local.y - dest.y0) / dest.height)
            guard u >= 0, u <= 1, v >= 0, v <= 1 else { continue }
            let (w, h) = (UInt32(clamping: img.width), UInt32(clamping: img.height))
            let px = min(UInt32(rustCast: u * Double(w)), w &- (w > 0 ? 1 : 0))
            let py = min(UInt32(rustCast: v * Double(h)), h &- (h > 0 ? 1 : 0))
            let i = (Int(py) * img.width + Int(px)) * 4
            guard px < w, py < h, i >= 0, i + 3 < img.pixels.count else { continue }
            // A transparent pixel keeps a colour nobody sees (often black): clearing it would clear that
            // colour where it is drawn.
            if img.pixels[i + 3] == 0 { throw Cmd.bad(cmd, "that spot of the picture is already transparent") }
            return (id, Rgba.rgb(img.pixels[i], img.pixels[i + 1], img.pixels[i + 2]))
        }
        throw Cmd.bad(cmd, "the point is not on a selected picture")
    }

    /// Where `id` sits in the paint order: its index in each list from the slide down to it. A larger path is
    /// drawn later, so in front.
    static func stackPath(_ shapes: [Shape], _ id: ShapeId, _ depth: Int = 0) -> [Int]? {
        if depth > 64 { return nil }
        for (i, sh) in shapes.enumerated() {
            if sh.id == id { return [i] }
            if case .group(let children, _) = sh.kind, let rest = stackPath(children, id, depth + 1) { return [i] + rest }
        }
        return nil
    }

    /// Shape `id` among `shapes` (searched into groups), its box, and the map from that box to slide space.
    static func placed(_ doc: Presentation, _ sel: Selection, _ shapes: [Shape], _ id: ShapeId, _ toSlide: Affine, _ depth: Int) -> (Shape, Xfrm, Affine)? {
        if depth > 64 { return nil }
        for sh in shapes {
            let x = Cmd.xfrmOf(doc, sel, sh)
            if sh.id == id { return (sh, x, toSlide * x.affine) }
            if case .group(let children, let child) = sh.kind {
                let ch = Rect(child.x, child.y, child.x + child.w, child.y + child.h)
                if let found = placed(doc, sel, children, id, toSlide * groupChildAffine(x, ch), depth + 1) { return found }
            }
        }
        return nil
    }
}
