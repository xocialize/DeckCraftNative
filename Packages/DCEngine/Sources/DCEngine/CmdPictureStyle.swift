// DCEngine — the `picture_style` command module: Picture Format ▸ Picture Styles, PowerPoint's quick styles
// for pictures, each a frame (shape, outline) and effects applied as one step, replacing the previous style.
// Port of deckcraft crates/engine/src/cmd/picture_style.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
import DCColor
import DCCore
import DCModel

public enum PictureStyleCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd("picture.style", "Picture Styles", ["Picture Format", "Picture Styles"], nil, "{style: simpleFrameWhite|dropShadowRectangle|softEdgeOval|… | none (see picture.styles), ids?}", Cmd.hasSelection, style),
            .query("picture.styles", "Picture Style Gallery", [], nil, "{} → [{id, label}]", Cmd.always) { _, _ in
                .array(styles.map { ["id": .string($0.0), "label": .string($0.1)] })
            },
        ]
    }

    /// (id, label), in PowerPoint's gallery order.
    public static let styles: [(String, String)] = [
        ("simpleFrameWhite", "Simple Frame, White"),
        ("beveledMatteWhite", "Beveled Matte, White"),
        ("metalFrame", "Metal Frame"),
        ("dropShadowRectangle", "Drop Shadow Rectangle"),
        ("roundedDiagonalCornerWhite", "Rounded Diagonal Corner, White"),
        ("snipDiagonalCornerWhite", "Snip Diagonal Corner, White"),
        ("moderateFrameWhite", "Moderate Frame, White"),
        ("rotatedWhite", "Rotated, White"),
        ("perspectiveShadowWhite", "Perspective Shadow, White"),
        ("softEdgeRectangle", "Soft Edge Rectangle"),
        ("doubleFrameBlack", "Double Frame, Black"),
        ("thickMatteBlack", "Thick Matte, Black"),
        ("simpleFrameBlack", "Simple Frame, Black"),
        ("beveledOvalBlack", "Beveled Oval, Black"),
        ("compoundFrameBlack", "Compound Frame, Black"),
        ("centerShadowRectangle", "Center Shadow Rectangle"),
        ("softEdgeOval", "Soft Edge Oval"),
        ("reflectedRoundedRectangle", "Reflected Rounded Rectangle"),
        ("reflectedBevelWhite", "Reflected Bevel, White"),
        ("metalRoundedRectangle", "Metal Rounded Rectangle"),
        ("moderateFrameBlack", "Moderate Frame, Black"),
        ("bevelRectangle", "Bevel Rectangle"),
        ("bevelPerspective", "Bevel Perspective"),
        ("metalOval", "Metal Oval"),
    ]

    /// The look of a style: geometry, outline (colour, width) and effects.
    public struct Look: Sendable {
        public var preset: String
        public var frame: (Rgba, Double)?
        public var shadow: String?
        public var softEdge: Double?
        public var reflection = false
        public var bevel: String?
        public var rot: Double?
    }

    public static func look(_ id: String) -> Look? {
        let white = Rgba.rgb(0xFF, 0xFF, 0xFF)
        let black = Rgba.rgb(0, 0, 0)
        let silver = Rgba.rgb(0xC0, 0xC0, 0xC0)
        func l(_ preset: String, _ frame: (Rgba, Double)?, _ shadow: String?) -> Look {
            Look(preset: preset, frame: frame, shadow: shadow, softEdge: nil, reflection: false, bevel: nil, rot: nil)
        }
        func with(_ base: Look, bevel: String? = nil, soft: Double? = nil, reflection: Bool = false, rot: Double? = nil) -> Look {
            var x = base
            if let bevel { x.bevel = bevel }
            if let soft { x.softEdge = soft }
            if reflection { x.reflection = true }
            if let rot { x.rot = rot }
            return x
        }
        switch id {
        case "simpleFrameWhite": return l("rect", (white, 7), "soft")
        case "beveledMatteWhite": return with(l("rect", (white, 6), "soft"), bevel: "circle")
        case "metalFrame": return with(l("rect", (silver, 7), "soft"), bevel: "angle")
        case "dropShadowRectangle": return l("rect", nil, "drop")
        case "roundedDiagonalCornerWhite": return l("round2DiagRect", (white, 6), "soft")
        case "snipDiagonalCornerWhite": return l("snip2DiagRect", (white, 6), "soft")
        case "moderateFrameWhite": return l("rect", (white, 4.5), "soft")
        case "rotatedWhite": return with(l("rect", (white, 6), "soft"), rot: 356)
        case "perspectiveShadowWhite": return l("rect", (white, 4), "perspective")
        case "softEdgeRectangle": return with(l("rect", nil, nil), soft: 10)
        case "doubleFrameBlack": return l("rect", (black, 6), nil)
        case "thickMatteBlack": return l("rect", (black, 10), "soft")
        case "simpleFrameBlack": return l("rect", (black, 5), nil)
        case "beveledOvalBlack": return with(l("ellipse", (black, 4), "soft"), bevel: "circle")
        case "compoundFrameBlack": return l("rect", (black, 4.5), nil)
        case "centerShadowRectangle": return l("rect", nil, "center")
        case "softEdgeOval": return with(l("ellipse", nil, nil), soft: 12)
        case "reflectedRoundedRectangle": return with(l("roundRect", nil, nil), reflection: true)
        case "reflectedBevelWhite": return with(l("rect", (white, 4), nil), bevel: "circle", reflection: true)
        case "metalRoundedRectangle": return with(l("roundRect", (silver, 6), "soft"), bevel: "angle")
        case "moderateFrameBlack": return l("rect", (black, 4.5), "soft")
        case "bevelRectangle": return with(l("rect", nil, "soft"), bevel: "angle")
        case "bevelPerspective": return with(l("rect", nil, "perspective"), bevel: "relaxedInset")
        case "metalOval": return with(l("ellipse", (silver, 6), "soft"), bevel: "angle")
        default: return nil
        }
    }

    static func shadow(_ kind: String) -> Shadow {
        var s = Shadow(color: ColorRef.rgb(.black).with(.alpha(40000)), blur: 4, dist: 3, dir: 45, inner: false, sx: 1, sy: 1, kx: 0, ky: 0, align: "tl", rotateWithShape: false)
        switch kind {
        case "drop":
            s.blur = 12
            s.dist = 6
            s.dir = 90
        case "center":
            s.blur = 16
            s.dist = 0
        case "perspective":
            s.sy = 0.23
            s.kx = -20
            s.dir = 90
            s.dist = 0
            s.blur = 6
            s.align = "bl"
        default:
            break
        }
        return s
    }

    /// Apply style `id` (or clear the style with `none`) to `sh`.
    @discardableResult
    public static func apply(_ sh: inout Shape, _ id: String) -> Bool {
        if id == "none" {
            sh.geom = .preset("rect")
            sh.line = nil
            sh.effects = nil
            return true
        }
        guard let lk = look(id) else { return false }
        sh.geom = .preset(lk.preset)
        sh.line = lk.frame.map { Line.solid(.rgb($0.0), $0.1) } ?? Line.none()
        let e = Effects(
            outerShadow: lk.shadow.map(shadow),
            softEdge: lk.softEdge,
            reflection: lk.reflection ? Reflection(blur: 0.5, startAlpha: 0.5, endAlpha: 0, endPos: 0.35, dist: 0) : nil,
            bevel: lk.bevel
        )
        sh.effects = e.isEmpty ? nil : e
        if let r = lk.rot, var x = sh.xfrm {
            x.rot = r
            sh.xfrm = x
        }
        return true
    }

    @Sendable static func style(_ s: Session, _ p: JSON) throws -> JSON {
        guard let id = Cmd.strParam(p, "style") else { throw Cmd.bad("picture.style", "missing `style`") }
        if id != "none" && look(id) == nil {
            throw Cmd.bad("picture.style", "unknown style `\(id)`; see picture.styles")
        }
        return try Cmd.editShapes(s, p, "picture.style") { apply(&$0, id) }
    }
}
