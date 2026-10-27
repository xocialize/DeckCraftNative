// DCAnim — slide show timing: the animation timeline, the show state machine, transition frames and
// Morph. Port of deckcraft crates/anim/src/lib.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// - `Timeline`: a slide's animation list grouped into click steps, with per-shape (and per-paragraph)
//   `AnimState` at any point of the show.
// - `transitionLayers`: a slide transition frame as textured quads of the old/new slide images.
// - `morphFrame`: a Morph transition frame (shapes matched by `morphPairs`, moved by `morphXfrm`).
// - `ShowState`: slide show navigation (hidden slides, custom shows, loop, timings), what was played on
//   each visited slide, and what a click does (`ShowState.click`).
//
// Pure logic: no rendering, no UI toolkit. Every function accepts hostile numbers (NaN, huge or negative
// times) and never traps.
import DCColor
import DCCore

/// Animation state of one shape (or one paragraph of a shape's text) at one moment of the show.
///
/// Same meaning as the renderer's `ShapeState`: translation in points, scale and rotation (degrees) around
/// the shape's centre, a reveal clip in shape-local unit space (l, t, r, b), and a fill colour override.
public struct AnimState: Sendable, Equatable {
    public var visible = true
    public var opacity = 1.0
    public var offsetX = 0.0
    public var offsetY = 0.0
    public var scaleX = 1.0
    public var scaleY = 1.0
    public var rotate = 0.0
    /// l, t, r, b.
    public var clip: SIMD4<Double>?
    public var tint: Rgba?

    public init(
        visible: Bool = true, opacity: Double = 1.0, offsetX: Double = 0.0, offsetY: Double = 0.0, scaleX: Double = 1.0,
        scaleY: Double = 1.0, rotate: Double = 0.0, clip: SIMD4<Double>? = nil, tint: Rgba? = nil
    ) {
        self.visible = visible
        self.opacity = opacity
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.rotate = rotate
        self.clip = clip
        self.tint = tint
    }

    public static var `default`: AnimState { AnimState() }

    /// A hidden state.
    public static func hidden() -> AnimState { AnimState(visible: false) }

    /// Is this the identity (nothing to apply)?
    public var isIdentity: Bool { self == AnimState() }

    /// Apply `d` on top of `self`: opacities and scales multiply, offsets and rotations add, clips
    /// intersect, a tint replaces.
    public func compose(_ d: AnimState) -> AnimState {
        let clip: SIMD4<Double>? = switch (self.clip, d.clip) {
        case let (a?, b?): SIMD4(a[0].rustMax(b[0]), a[1].rustMax(b[1]), a[2].rustMin(b[2]), a[3].rustMin(b[3]))
        case let (a, nil): a
        case let (nil, b): b
        }
        return AnimState(
            visible: visible && d.visible,
            opacity: opacity * d.opacity,
            offsetX: offsetX + d.offsetX,
            offsetY: offsetY + d.offsetY,
            scaleX: scaleX * d.scaleX,
            scaleY: scaleY * d.scaleY,
            rotate: rotate + d.rotate,
            clip: clip,
            tint: d.tint ?? tint
        )
    }

    /// Replace any non-finite number with its neutral value and clamp opacity and clip.
    public func sanitized() -> AnimState {
        func f(_ v: Double, _ d: Double) -> Double { v.isFinite ? v : d }
        var s = self
        s.opacity = f(opacity, 1.0).clamped(0.0, 1.0)
        s.offsetX = f(offsetX, 0.0)
        s.offsetY = f(offsetY, 0.0)
        s.scaleX = f(scaleX, 1.0)
        s.scaleY = f(scaleY, 1.0)
        s.rotate = f(rotate, 0.0)
        s.clip = clip.map { c in
            let l = f(c[0], 0.0).clamped(0.0, 1.0)
            let t = f(c[1], 0.0).clamped(0.0, 1.0)
            let r = f(c[2], 1.0).clamped(0.0, 1.0)
            let b = f(c[3], 1.0).clamped(0.0, 1.0)
            return SIMD4(l, t, r.rustMax(l), b.rustMax(t))
        }
        return s
    }
}

/// Clamp a hostile number into `lo...hi`, mapping NaN to `nan`.
@inline(__always)
func clampf(_ v: Double, _ lo: Double, _ hi: Double, _ nan: Double) -> Double {
    v.isNaN ? nan : v.clamped(lo, hi)
}

// MARK: Rust semantics used across the crate

extension Double {
    /// Rust's `f64::rem_euclid`.
    @inline(__always)
    func remEuclid(_ rhs: Double) -> Double {
        let r = rem(rhs)
        return r < 0.0 ? r + Swift.abs(rhs) : r
    }

    /// Rust's `f64::total_cmp(..) == Less`.
    @inline(__always)
    func totalLess(_ other: Double) -> Bool {
        !other.isTotallyOrdered(belowOrEqualTo: self)
    }
}

extension String {
    /// Rust's `str::starts_with` (bytes, not canonical equivalence).
    func bytesHavePrefix(_ p: String) -> Bool { utf8.starts(with: p.utf8) }

    /// Rust's `str::ends_with`.
    func bytesHaveSuffix(_ s: String) -> Bool { utf8.reversed().starts(with: s.utf8.reversed()) }

    /// Rust's `str::contains(char)` for an ASCII character.
    func bytesContain(_ c: Unicode.Scalar) -> Bool { utf8.contains(UInt8(truncatingIfNeeded: c.value)) }
}

extension Array {
    /// A stable sort, as Rust's `sort_by` (equal elements keep their order).
    func stableSorted(_ less: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
