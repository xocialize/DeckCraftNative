// DCRender — Morph of an outline: a frame shape whose geometry turns from the old shape's into its own (a
// circle into a star), with the points aligned by DCGeometry's `GeometryMorph`. Port of deckcraft
// crates/render/src/morph_path.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCGeometry
import DCModel
import Foundation

/// A frame shape (see `renderBlend`) whose outline morphs from `from` into its own geometry.
public struct PathMorph: Sendable, Equatable {
    public var id: ShapeId
    /// The old shape's geometry.
    public var from: Geom
    /// The boxes of the old and the new shape on their own slides.
    public var fromBox: Xfrm
    public var toBox: Xfrm
    /// Progress, 0...1 (already eased).
    public var t: Double

    public init(id: ShapeId, from: Geom, fromBox: Xfrm, toBox: Xfrm, t: Double) {
        self.id = id
        self.from = from
        self.fromBox = fromBox
        self.toBox = toBox
        self.t = t
    }
}

/// `now / own`, or 1 when that is no usable scale (a line's zero height).
private func ratio(_ now: Double, _ own: Double) -> Double {
    let r = now / own
    return Swift.abs(own) > 1e-9 && r.isFinite ? r : 1.0
}

/// What a `GeometryMorph` is built from: both outlines at their own sizes. None of it changes while a
/// transition plays, only `t` and the current box do.
private struct MorphSource: Sendable {
    var from: Geom
    var fromWH: (Double, Double)
    var to: Geom
    var toWH: (Double, Double)

    init(_ pm: PathMorph, _ s: Shape) {
        from = pm.from
        fromWH = (pm.fromBox.w, pm.fromBox.h)
        to = s.geom
        toWH = (pm.toBox.w, pm.toBox.h)
    }

    func isFor(_ pm: PathMorph, _ s: Shape) -> Bool {
        from == pm.from && fromWH == (pm.fromBox.w, pm.fromBox.h) && to == s.geom && toWH == (pm.toBox.w, pm.toBox.h)
    }

    func build() -> GeometryMorph {
        func geo(_ geom: Geom, _ wh: (Double, Double)) -> Preset.Geometry {
            var s = Shape.default
            s.geom = geom
            return shapeGeometry(s, wh.0, wh.1)
        }
        return GeometryMorph(geo(from, fromWH), geo(to, toWH))
    }
}

/// The aligned outlines of the morphs being played, kept across frames: aligning is the expensive part,
/// blending them at `t` is cheap. deckcraft keeps one per thread's renderer; a `Renderer` here lives for one
/// frame, so frames share `MorphPathCache.shared` (locked).
final class MorphPathCache: @unchecked Sendable {
    static let shared = MorphPathCache()

    /// More than this many morphs at once is no transition: start over rather than grow.
    private static let limit = 256

    private let lock = NSLock()
    /// With whether the current frame used it.
    private var morphs: [(source: MorphSource, morph: GeometryMorph, used: Bool)] = []

    init() {}

    /// The geometry of frame shape `s` at its current size `w` x `h`: both outlines are built at their own
    /// sizes (so the alignment does not change while the box grows), then scaled into the box. With a fade
    /// per sub-path.
    func geometry(_ pm: PathMorph, _ s: Shape, _ w: Double, _ h: Double) -> (Preset.Geometry, [Morph.Fade]) {
        func scale(_ x: Xfrm) -> Vec2 { Vec2(ratio(w, x.w), ratio(h, x.h)) }
        let found: GeometryMorph? = lock.withLock {
            guard let k = morphs.firstIndex(where: { $0.source.isFor(pm, s) }) else { return nil }
            morphs[k].used = true
            return morphs[k].morph
        }
        if let m = found { return m.at(pm.t, scale(pm.fromBox), scale(pm.toBox)) }
        let src = MorphSource(pm, s)
        let m = src.build()
        lock.withLock {
            if morphs.count >= MorphPathCache.limit { morphs.removeAll() }
            if !morphs.contains(where: { $0.source.isFor(pm, s) }) { morphs.append((src, m, true)) }
        }
        return m.at(pm.t, scale(pm.fromBox), scale(pm.toBox))
    }

    /// Ends a frame: forgets the morphs it did not use (their transition is over).
    func sweep() {
        lock.withLock {
            morphs.removeAll { !$0.used }
            for k in morphs.indices { morphs[k].used = false }
        }
    }

    var count: Int { lock.withLock { morphs.count } }
}
