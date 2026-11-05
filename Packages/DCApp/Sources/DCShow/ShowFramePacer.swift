// DCShow — when a client of `ShowRenderer` draws a frame: the show window's rule (it was `ShowView.tick`'s until
// 2026-11-04), so every client draws on the same terms. A frame is drawn after any change the client is told of
// (input, a resize, a new video frame) or sees in the show itself (`observe`: the slide or step, a blank screen, the
// end, ink, the zoom: changes presenter view, the control channel or another client may make), every display frame
// while the picture moves by itself (the last frame said `animating`, or a transition runs), and otherwise at least
// every `keepAlive` seconds.
import CoreGraphics
import DCAppModel

/// When to draw the next frame of a show. A value type a client keeps beside its renderer.
public struct ShowFramePacer: Sendable {
    /// The longest a client goes without drawing while nothing changes (nil: never). The show window keeps
    /// 0.25 s, deckcraft's; a client that publishes frames to another program may want none.
    public var keepAlive: Double?
    private var dirty = true
    private var animating = false
    private var lastDraw = -Double.infinity
    private var seen: Seen?

    /// What of the show the picture depends on, apart from the clock (which `animating` and transitions cover).
    struct Seen: Equatable, Sendable {
        var instance: UInt64
        var slide: Int
        var step: Int
        var ended: Bool
        var blank: ShowBlank?
        var uv: CGRect
        var reading: Bool
        var ink: [Int]
        var inkLast: CGPoint?
    }

    public init(keepAlive: Double? = 0.25) {
        self.keepAlive = keepAlive
    }

    /// Something the frame shows changed: draw on the next tick.
    public mutating func invalidate() {
        dirty = true
    }

    /// Look at the show (nil: none): draw on the next tick if what the picture shows changed since the last look.
    @MainActor
    public mutating func observe(_ show: ShowController?) {
        let now = show.map {
            Seen(instance: $0.instance, slide: $0.state.slide, step: $0.state.step, ended: $0.ended, blank: $0.blank, uv: $0.zoomUV,
                 reading: $0.reading, ink: $0.strokes.map(\.count), inkLast: $0.strokes.last?.last)
        }
        if now != seen {
            seen = now
            dirty = true
        }
    }

    /// Whether to draw at `now`; `transitioning` when the show has a transition running.
    public func shouldDraw(now: Double, transitioning: Bool) -> Bool {
        if animating || dirty || transitioning { return true }
        guard let k = keepAlive, k.isFinite else { return false }
        return now - lastDraw > k
    }

    /// A frame is about to be drawn at `now`.
    public mutating func willDraw(now: Double) {
        dirty = false
        lastDraw = now
    }

    /// The frame drawn: whether it moves by itself decides the next ticks.
    public mutating func drew(_ frame: ShowFrame) {
        animating = frame.animating
    }
}
