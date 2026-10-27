// DCAnim — slide transitions as layers of textured quads. Port of deckcraft crates/anim/src/transition.rs
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// A frame is drawn over black: each `Layer` maps part of a source image (old slide, new slide, their
// backgrounds or contents alone, or a solid colour) onto a quad in slide-unit space (0...1, y down), with an
// opacity per corner. Perspective comes from projecting 3-D cards (`layerMesh` keeps their textures
// straight); soft edges come from per-corner opacity ramps; wedges are triangles (4th corner repeats the
// 3rd).
//
// The motions, curves, directions and option meanings were measured by deckcraft frame by frame on
// PowerPoint's video export of synthetic decks. The effects themselves live in TransitionFX.swift.

/// What a layer shows.
public enum Source: Sendable, Hashable {
    /// The outgoing slide.
    case old
    /// The incoming slide.
    case new
    case black
    case white
    /// The outgoing slide's background (background fill plus master and layout graphics) alone.
    case oldBack
    /// The incoming slide's background alone.
    case newBack
    /// The outgoing slide's own shapes alone, over transparency.
    case oldContent
    /// The incoming slide's own shapes alone, over transparency.
    case newContent

    /// The whole-slide source to draw instead when the parts aren't available: a background becomes its
    /// slide, content becomes nothing.
    public var whole: Source? {
        switch self {
        case .oldBack: .old
        case .newBack: .new
        case .oldContent, .newContent: nil
        default: self
        }
    }

    /// Does this source need the slide rendered in parts (background / content)?
    public var isPart: Bool {
        switch self {
        case .oldBack, .newBack, .oldContent, .newContent: true
        default: false
        }
    }
}

/// A point in slide-unit space (x, y).
public typealias UnitPoint = SIMD2<Double>

/// Four corners: tl, tr, br, bl.
public struct Quad: Sendable, Equatable {
    public var tl: UnitPoint
    public var tr: UnitPoint
    public var br: UnitPoint
    public var bl: UnitPoint

    public init(_ tl: UnitPoint, _ tr: UnitPoint, _ br: UnitPoint, _ bl: UnitPoint) {
        self.tl = tl
        self.tr = tr
        self.br = br
        self.bl = bl
    }

    /// Corner `i` (0 tl, 1 tr, 2 br, 3 bl; anything else is bl).
    public subscript(_ i: Int) -> UnitPoint {
        get {
            switch i {
            case 0: tl
            case 1: tr
            case 2: br
            default: bl
            }
        }
        set {
            switch i {
            case 0: tl = newValue
            case 1: tr = newValue
            case 2: br = newValue
            default: bl = newValue
            }
        }
    }

    public var corners: [UnitPoint] { [tl, tr, br, bl] }

    public func map(_ f: (UnitPoint) -> UnitPoint) -> Quad { Quad(f(tl), f(tr), f(br), f(bl)) }
}

/// One textured quad of a transition frame.
public struct Layer: Sendable, Equatable {
    public var source: Source
    /// Source sub-rectangle in uv space (0...1): l, t, r, b (bounds of `uv`).
    public var src: SIMD4<Double>
    /// Destination corners in slide-unit space: tl, tr, br, bl.
    public var quad: Quad
    /// Texture coordinate of each destination corner (tl, tr, br, bl). For plain rectangles these are the
    /// corners of `src`; triangles and mirrored flaps carry their own. Draw with these.
    public var uv: Quad
    public var alpha: Double
    /// Opacity of each corner (tl, tr, br, bl), multiplied by `alpha` and interpolated across the quad: soft
    /// edges and feathered masks.
    public var fade: SIMD4<Double>

    public init(source: Source, src: SIMD4<Double>, quad: Quad, uv: Quad, alpha: Double, fade: SIMD4<Double> = SIMD4(repeating: 1.0)) {
        self.source = source
        self.src = src
        self.quad = quad
        self.uv = uv
        self.alpha = alpha
        self.fade = fade
    }
}

typealias R = SIMD4<Double>
typealias P = SIMD2<Double>
let fullRect = R(0.0, 0.0, 1.0, 1.0)

@inline(__always)
func corners(_ r: R) -> Quad {
    Quad(P(r[0], r[1]), P(r[2], r[1]), P(r[2], r[3]), P(r[0], r[3]))
}

extension Layer {
    /// The whole source over the whole slide.
    public static func full(_ source: Source, _ alpha: Double) -> Layer {
        rect(source, fullRect, fullRect, alpha)
    }

    /// `src` rectangle of the source drawn into the `dst` rectangle.
    public static func rect(_ source: Source, _ src: SIMD4<Double>, _ dst: SIMD4<Double>, _ alpha: Double) -> Layer {
        Layer(source: source, src: src, quad: corners(dst), uv: corners(src), alpha: alpha)
    }

    /// `src` rectangle of the source drawn onto a quad.
    public static func quad(_ source: Source, _ src: SIMD4<Double>, _ quad: Quad, _ alpha: Double) -> Layer {
        Layer(source: source, src: src, quad: quad, uv: corners(src), alpha: alpha)
    }

    /// The part of the source under `dst` drawn in place.
    static func inplace(_ source: Source, _ dst: R, _ alpha: Double) -> Layer {
        rect(source, dst, dst, alpha)
    }

    /// A triangle with its own texture coordinates and corner opacities.
    static func triUV(_ source: Source, _ p: (P, P, P), _ uv: (P, P, P), _ fade: (Double, Double, Double), _ alpha: Double) -> Layer {
        let xs = [uv.0[0], uv.1[0], uv.2[0]]
        let ys = [uv.0[1], uv.1[1], uv.2[1]]
        func mn(_ v: [Double]) -> Double { v.reduce(Double.infinity) { $0.rustMin($1) } }
        func mx(_ v: [Double]) -> Double { v.reduce(-Double.infinity) { $0.rustMax($1) } }
        return Layer(
            source: source,
            src: R(mn(xs), mn(ys), mx(xs), mx(ys)),
            quad: Quad(p.0, p.1, p.2, p.2),
            uv: Quad(uv.0, uv.1, uv.2, uv.2),
            alpha: alpha,
            fade: SIMD4(fade.0, fade.1, fade.2, fade.2)
        )
    }

    /// With corner opacities.
    func faded(_ fade: SIMD4<Double>) -> Layer {
        var l = self
        l.fade = fade
        return l
    }

    /// A black copy of this layer's shape at `k` of its opacity: shading a card.
    func shade(_ k: Double) -> Layer {
        var l = self
        l.source = .black
        l.alpha = alpha * k.clamped(0.0, 1.0)
        return l
    }

    func sanitized() -> Layer {
        func f(_ v: Double) -> Double { v.isFinite ? v.clamped(-1.0e6, 1.0e6) : 0.0 }
        var l = self
        for i in 0 ..< 4 { l.src[i] = f(src[i]).clamped(0.0, 1.0) }
        for i in 0 ..< 4 {
            l.quad[i] = P(f(quad[i][0]), f(quad[i][1]))
            l.uv[i] = P(f(uv[i][0]).clamped(0.0, 1.0), f(uv[i][1]).clamped(0.0, 1.0))
        }
        for i in 0 ..< 4 { l.fade[i] = clampf(fade[i], 0.0, 1.0, 0.0) }
        l.alpha = clampf(alpha, 0.0, 1.0, 0.0)
        return l
    }
}

/// Slide aspect assumed by `transitionLayers` (16:9).
public let defaultAspect = 16.0 / 9.0

/// Layers of the transition `kind` (a `DCModel.transitions` id) with `option` at progress `t` (0...1) on a
/// 16:9 slide. See `transitionFrame`.
public func transitionLayers(_ kind: String, _ option: String, _ t: Double) -> [Layer] {
    transitionFrame(kind, option, t, defaultAspect)
}

/// Layers of the transition `kind` with `option` at linear progress `t` (0...1; the effect applies its own
/// easing) on a slide `aspect` wide per unit of height. Draw in order over black. At `t >= 1` the result is
/// the new slide alone; at `t <= 0` (or NaN) the old slide alone. Morph returns a plain crossfade (the show
/// renders morph frames with `morphFrame`). Layers with `Source.isPart` sources need the slides rendered as
/// background and content (`usesSlideParts`).
public func transitionFrame(_ kind: String, _ option: String, _ t0: Double, _ aspect0: Double) -> [Layer] {
    let t = clampf(t0, 0.0, 1.0, 0.0)
    let aspect = aspect0.isFinite && aspect0 > 0.01 ? aspect0.rustMin(100.0) : defaultAspect
    let v: [Layer]
    if t >= 1.0 {
        v = [Layer.full(.new, 1.0)]
    } else if t <= 0.0 {
        v = [Layer.full(.old, 1.0)]
    } else {
        v = TransitionFX.layers(kind, option, t, aspect, 0)
    }
    return v.map { $0.sanitized() }.filter { l in l.alpha > 0.0 && (0 ..< 4).contains { l.fade[$0] > 0.0 } }
}

/// Does `kind` animate the slides' backgrounds and contents separately (PowerPoint's Dynamic Content
/// transitions and Reveal)? Then the frame uses `Source.oldBack` & co.
public func usesSlideParts(_ kind: String, _ option: String) -> Bool {
    switch kind {
    case "pan", "ferris", "conveyor", "rotate", "window", "orbit", "flythrough": true
    case "reveal": !option.bytesHavePrefix("black")
    default: false
    }
}
