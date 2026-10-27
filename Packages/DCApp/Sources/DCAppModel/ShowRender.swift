// DCAppModel — the show's slide pictures: a slide at a step and time with its media hidden or shown, its
// backdrop kept while it animates (only its own shapes are drawn again each frame), the shapes stacked over a
// playing video, and the next slide's first frame rendered ahead of time on another thread. Port of
// `render_frame`, `render_backdrop`, `over`, `render_overlay`, `start_prefetch` and the `backdrop` cache of
// deckcraft `crates/ui-egui/src/show.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCAnim
import DCCore
import DCModel
import DCRender
import Foundation

public enum ShowRender {
    /// The largest side the show renders (Metal's texture limit on Apple silicon; DCRender caps at 16,000).
    public static let maxSide = 16_000

    /// `(w, h)` scaled down, keeping its shape, so neither side exceeds `max` and none is 0 (`fit_size`).
    public static func fitSize(_ w0: Int, _ h0: Int, _ max0: Int = maxSide) -> ShowSize {
        let (w, h, mx) = (Swift.max(w0, 1), Swift.max(h0, 1), Swift.max(max0, 1))
        let big = Swift.max(w, h)
        if big <= mx { return ShowSize(w, h) }
        let k = Double(mx) / Double(big)
        return ShowSize(Swift.min(Swift.max(Int((Double(w) * k).rounded(.down)), 1), mx), Swift.min(Swift.max(Int((Double(h) * k).rounded(.down)), 1), mx))
    }

    static func opts(_ doc: Presentation, _ size: ShowSize) -> RenderOpts {
        var o = RenderOpts(scale: Double(size.w) / Swift.max(doc.slideSize.width, 1))
        o.size = (size.w, size.h)
        return o
    }

    /// Slide `idx` at main step `step`, `t` seconds into it, with `hidden` media hidden (`render_frame`). With a
    /// `backdrop` of this slide at this size, only the slide's own shapes are rendered, over it.
    public static func frame(
        _ doc: Presentation, _ idx: Int, _ tl: Timeline, _ step: Int, _ t: Double, _ size: ShowSize, hidden: [ShapeId], gifTimes: [(ShapeId, Double)] = [],
        plays: [TriggerPlay] = [], stamps: [StepStamp] = [], backdrop: RenderImage? = nil
    ) -> RenderImage {
        var o = opts(doc, size)
        o.state = { id in
            var st = showShapeState(tl, id, step, t, plays, stamps)
            if hidden.contains(id) { st.visible = false }
            return st
        }
        o.gifTimes = gifTimes
        guard let back = backdrop else { return renderSlide(doc, idx, o) }
        return over(back, renderSlidePart(doc, idx, .content, o))
    }

    /// The slide's own shapes except `skip`, over transparency: what is stacked above a playing video
    /// (`render_overlay`).
    public static func overlay(
        _ doc: Presentation, _ idx: Int, _ tl: Timeline, _ step: Int, _ t: Double, _ size: ShowSize, hidden: [ShapeId], skip: [ShapeId],
        gifTimes: [(ShapeId, Double)] = [], plays: [TriggerPlay] = [], stamps: [StepStamp] = []
    ) -> RenderImage {
        var o = opts(doc, size)
        o.state = { id in
            var st = showShapeState(tl, id, step, t, plays, stamps)
            if hidden.contains(id) { st.visible = false }
            return st
        }
        o.skip = skip
        o.gifTimes = gifTimes
        return renderSlidePart(doc, idx, .content, o)
    }

    /// A slide's backdrop: background, master and layout graphics (`render_backdrop`).
    public static func backdrop(_ doc: Presentation, _ idx: Int, _ size: ShowSize) -> RenderImage {
        renderSlidePart(doc, idx, .backdrop, opts(doc, size))
    }

    /// `top` laid over `back`, both premultiplied RGBA of one size; `top` alone otherwise (`over`).
    public static func over(_ back: RenderImage, _ top: RenderImage) -> RenderImage {
        guard back.width == top.width, back.height == top.height, back.pixels.count == top.pixels.count else { return top }
        var out = top
        out.pixels.withUnsafeMutableBufferPointer { o in
            back.pixels.withUnsafeBufferPointer { b in
                var i = 0
                while i + 3 < o.count {
                    let k = 255 - UInt32(o[i + 3])
                    for c in 0 ..< 4 {
                        o[i + c] = UInt8(Swift.min(UInt32(o[i + c]) + (UInt32(b[i + c]) * k + 127) / 255, 255))
                    }
                    i += 4
                }
            }
        }
        return out
    }

    /// A thumbnail `width` pixels wide (See All Slides, presenter view's Next).
    public static func thumb(_ doc: Presentation, _ idx: Int, width: Int) -> RenderImage {
        let w = Double(Swift.max(width, 1))
        let h = (w * doc.slideSize.height / Swift.max(doc.slideSize.width, 1)).rounded()
        let size = fitSize(Int(w), Int(rustCast: h.isFinite ? Swift.max(h, 1) : 1))
        return renderSlide(doc, idx, opts(doc, size))
    }
}

/// A picture being rendered on another thread; `wait` takes it (or blocks until it is ready).
public final class ShowPending: @unchecked Sendable {
    private let cond = NSCondition()
    private var value: RenderImage?

    public init(_ work: @escaping @Sendable () -> RenderImage) {
        let me = self
        DispatchQueue.global(qos: .userInitiated).async {
            let v = work()
            me.cond.lock()
            me.value = v
            me.cond.broadcast()
            me.cond.unlock()
        }
    }

    /// The picture, waiting for it if needed (deckcraft's `rx.recv()`).
    public func wait() -> RenderImage {
        cond.lock()
        defer { cond.unlock() }
        while value == nil { cond.wait() }
        return value ?? RenderImage()
    }

    /// The picture if it is ready.
    public var ready: RenderImage? {
        cond.lock()
        defer { cond.unlock() }
        return value
    }
}

/// The next slide's first frame being rendered ahead (`Prefetch`).
public struct ShowPrefetch {
    public var key: ShowFrameKey
    public var pending: ShowPending

    /// Start rendering slide `next`'s first frame (`start_prefetch`).
    public static func start(_ doc: Presentation, _ docID: ObjectIdentifier?, _ next: Int, _ size: ShowSize) -> ShowPrefetch {
        let hidden = hiddenOnEntry(doc, next)
        let key = ShowFrameKey(slide: next, step: 0, size: size, doc: docID, hidden: hidden)
        let pending = ShowPending {
            let tl = ShowState.timeline(doc, next)
            return ShowRender.frame(doc, next, tl, 0, 0, size, hidden: hidden)
        }
        return ShowPrefetch(key: key, pending: pending)
    }
}

/// What a backdrop was rendered for (`BackKey`).
public struct ShowBackKey: Equatable, Sendable {
    public var slide: Int
    public var size: ShowSize
    public var doc: ObjectIdentifier?
    public init(slide: Int, size: ShowSize, doc: ObjectIdentifier?) {
        self.slide = slide
        self.size = size
        self.doc = doc
    }
}

/// The current slide's backdrop, kept while the slide is shown so animation frames render only its shapes
/// (`Backdrop`). A layout picture with a glow made animations crawl at 2–3 frames a second without it.
public final class ShowBackdrop {
    /// The document it was rendered from, held so its identity can't be reused while it is kept.
    private var docRef: AnyObject?
    private var key: ShowBackKey?
    private var image: RenderImage?
    private var pending: ShowPending?

    public init() {}

    /// The backdrop for `key`: kept, waited for, or rendered now.
    public func get(_ doc: Presentation, _ docRef: AnyObject?, _ key: ShowBackKey) -> RenderImage {
        if self.key == key, self.docRef === docRef {
            if image == nil { image = pending?.wait() }
            pending = nil
            if let img = image { return img }
        }
        let img = ShowRender.backdrop(doc, key.slide, key.size)
        self.docRef = docRef
        self.key = key
        image = img
        pending = nil
        return img
    }

    /// Start rendering the backdrop for `key` on another thread, unless it is there or on its way.
    public func prefetch(_ doc: Presentation, _ docRef: AnyObject?, _ key: ShowBackKey) {
        if self.key == key, self.docRef === docRef { return }
        self.docRef = docRef
        self.key = key
        image = nil
        pending = ShowPending { ShowRender.backdrop(doc, key.slide, key.size) }
    }
}
