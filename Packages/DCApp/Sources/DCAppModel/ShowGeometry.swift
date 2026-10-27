// DCAppModel — the slide show's geometry: where the slide sits on the screen, the zoom window, See All Slides'
// cells, the toolbar, presenter view's Next preview and the media bars. Pure functions over `CGRect` (y down, as
// the show's flipped views lay out). Port of the layout helpers of deckcraft `crates/ui-egui/src/show.rs`
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import CoreGraphics
import DCCore
import DCGeometry
import DCModel

public enum ShowGeometry {
    /// Two notches more than this wins a zoom back to the whole slide (`ZOOM_SCALE`).
    public static let zoomScale = 2.0
    /// Four notches double the zoom, so the wheel passes through the click-zoom's 2× on its way to 4×.
    public static let wheelNotchesPerDoubling = 4.0
    /// PowerPoint's slide show magnifier goes up to 400 %.
    public static let wheelZoomMax = 4.0
    /// See All Slides shows at most this many slides.
    public static let gridCap = 48
    public static let toolBarWidth = 520.0
    /// The reading view's bar along the bottom of the window.
    public static let readingBarHeight = 34.0

    /// The slide's rectangle inside `avail`, as large as fits (`fit`). A zero or non-finite slide side counts as 1.
    public static func fit(_ avail: CGRect, _ slideSize: (Double, Double)) -> CGRect {
        func side(_ v: Double) -> Double { v.isFinite ? Swift.max(Double(Float(v)), 1) : 1 }
        let (sw, sh) = (side(slideSize.0), side(slideSize.1))
        var s = Swift.min(avail.width / sw, avail.height / sh)
        if !(s > 0) { s = 0 }
        let (w, h) = (sw * s, sh * s)
        return CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h)
    }

    public static func fit(_ avail: CGRect, _ doc: Presentation) -> CGRect {
        fit(avail, (doc.slideSize.width, doc.slideSize.height))
    }

    /// Where the show draws the slide in a window of `full` (the reading bar keeps its strip; `shown_slide_rect`).
    public static func slideRect(_ full: CGRect, reading: Bool, _ doc: Presentation) -> CGRect {
        fit(available(full, reading: reading), doc)
    }

    /// The area the slide is fitted into: the window less the reading bar.
    public static func available(_ full: CGRect, reading: Bool) -> CGRect {
        reading ? CGRect(x: full.minX, y: full.minY, width: full.width, height: Swift.max(full.height - readingBarHeight, 0)) : full
    }

    /// The slide's width over its height, 16:9 when that isn't a usable number (`slide_aspect`).
    public static func slideAspect(_ doc: Presentation) -> Double {
        let a = Double(Float(doc.slideSize.width) / Float(Swift.max(doc.slideSize.height, 1)))
        return a.isFinite && a > 0.05 ? a : 16.0 / 9.0
    }

    /// Presenter view's "Next" preview: the column's width below its label, kept inside the top 60 % of the
    /// column (`next_rect`). A portrait slide used to take the full width and many times the window's height.
    public static func nextRect(_ right: CGRect, _ doc: Presentation) -> CGRect {
        let top = right.minY + 22
        let area = CGRect(x: right.minX, y: top, width: right.width, height: Swift.max(right.height - 22, 0) * 0.6)
        let f = fit(area, doc)
        return CGRect(x: area.minX, y: area.minY, width: f.width, height: f.height)
    }

    /// The whole texture.
    public static let unitUV = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The part of the slide a zoom shows, in 0–1 texture space; the window stays on the slide (`zoom_uv`).
    public static func zoomUV(_ nx: Double, _ ny: Double, _ scale0: Double) -> CGRect {
        let scale = scale0.isFinite && scale0 > 1 ? scale0 : zoomScale
        let w = 1 / scale
        if w >= 1 { return unitUV }
        let x = (nx - w * 0.5).clamped(0, 1 - w)
        let y = (ny - w * 0.5).clamped(0, 1 - w)
        return CGRect(x: x.isNaN ? 0 : x, y: y.isNaN ? 0 : y, width: w, height: w)
    }

    /// The slide point (0–1) under `p` when the slide is drawn in `srect` showing `uv` of it; nil off the slide.
    public static func normOnSlide(_ srect: CGRect, _ uv: CGRect, _ p: CGPoint) -> (Double, Double)? {
        guard srect.width > 1, srect.height > 1, contains(srect, p) else { return nil }
        let u = (p.x - srect.minX) / srect.width
        let v = (p.y - srect.minY) / srect.height
        let nx = uv.minX + u * uv.width
        let ny = uv.minY + v * uv.height
        guard nx.isFinite, ny.isFinite else { return nil }
        return (Double(nx).clamped(0, 1), Double(ny).clamped(0, 1))
    }

    /// The screen point of slide point (nx, ny) (`slide_to_screen`).
    public static func slideToScreen(_ srect: CGRect, _ uv: CGRect, _ nx: Double, _ ny: Double) -> CGPoint {
        let u = (nx - uv.minX) / Swift.max(uv.width, 1e-4)
        let v = (ny - uv.minY) / Swift.max(uv.height, 1e-4)
        return CGPoint(x: srect.minX + u * srect.width, y: srect.minY + v * srect.height)
    }

    /// A box in slide points on the screen, through a zoom (`slide_box`).
    public static func slideBox(_ srect: CGRect, _ uv: CGRect, _ slideW: Double, _ slideH: Double, _ x: Xfrm) -> CGRect {
        let a = slideToScreen(srect, uv, x.x / Swift.max(slideW, 1), x.y / Swift.max(slideH, 1))
        let b = slideToScreen(srect, uv, (x.x + x.w) / Swift.max(slideW, 1), (x.y + x.h) / Swift.max(slideH, 1))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// A slide-space box on screen, the slide drawn in `srect` at `k` pixels per point (`on_screen`).
    public static func onScreen(_ srect: CGRect, _ k: Double, _ x: Xfrm) -> CGRect {
        CGRect(x: srect.minX + x.x * k, y: srect.minY + x.y * k, width: x.w * k, height: x.h * k)
    }

    /// The zoom window's frame inside the slide's rectangle (`zoom_frame`): presenter view marks it.
    public static func zoomFrame(_ slide: CGRect, _ uv: CGRect) -> CGRect {
        CGRect(x: slide.minX + uv.minX * slide.width, y: slide.minY + uv.minY * slide.height, width: uv.width * slide.width, height: uv.height * slide.height)
    }

    /// The show's on-screen toolbar, bottom left (`tool_bar_rect`).
    public static func toolBarRect(_ full: CGRect) -> CGRect {
        let w = Swift.min(toolBarWidth, Swift.max(full.width - 32, 32))
        return CGRect(x: full.minX + 16, y: full.maxY - 50, width: w, height: 34)
    }

    /// The slides See All Slides lists (`grid_indices`).
    public static func gridIndices(_ n: Int) -> [Int] { Array(0 ..< Swift.max(Swift.min(n, gridCap), 0)) }

    /// Thumbnail rectangles for `n` slides inside `full`: the largest that fit (`see_all_cells`).
    public static func seeAllCells(_ full: CGRect, _ n: Int, _ aspect0: Double) -> [CGRect] {
        if n <= 0 || full.width < 16 || full.height < 16 { return [] }
        let aspect = aspect0.isFinite && aspect0 > 0.05 ? aspect0 : 16.0 / 9.0
        let (margin, gap, labelH) = (28.0, 16.0, 22.0)
        let shrunk = full.insetBy(dx: margin, dy: margin)
        let inner = CGRect(x: shrunk.minX, y: shrunk.minY + 36, width: shrunk.width, height: shrunk.height - 36)
        if inner.width < 8 || inner.height < 8 { return [] }
        var best: [CGRect] = []
        var bestArea = 0.0
        for cols in 1 ... Swift.max(Swift.min(n, 8), 1) {
            let rows = (n + cols - 1) / cols
            let cellW = (inner.width - gap * Double(cols - 1)) / Double(cols)
            let cellH = (inner.height - gap * Double(rows - 1)) / Double(rows)
            if cellW < 8 || cellH < labelH + 8 { continue }
            let thumbMaxH = cellH - labelH
            var tw = cellW
            var th = tw / aspect
            if th > thumbMaxH {
                th = thumbMaxH
                tw = th * aspect
            }
            if tw < 8 || th < 8 { continue }
            let area = tw * th
            if area <= bestArea { continue }
            bestArea = area
            best = (0 ..< n).map { i in
                let (c, r) = (i % cols, i / cols)
                let ox = inner.minX + Double(c) * (cellW + gap) + (cellW - tw) * 0.5
                let oy = inner.minY + Double(r) * (cellH + gap)
                return CGRect(x: ox, y: oy, width: tw, height: th)
            }
        }
        return best
    }

    /// The cell under `p` (with its label) (`see_all_hit`).
    public static func seeAllHit(_ full: CGRect, _ n: Int, _ aspect: Double, _ p: CGPoint) -> Int? {
        seeAllCells(full, n, aspect).firstIndex { contains($0.insetBy(dx: -4, dy: -18), p) }
    }

    /// Playback bar for one clip: along the bottom inside a large shape, just under a small one (`media_bar_rect`).
    public static func mediaBarRect(_ shape: CGRect) -> CGRect {
        let h = 26.0
        let w = Double(shape.width).clamped(160, 420)
        if shape.height >= h + 16 && shape.width >= 160 {
            return CGRect(x: shape.minX + 4, y: shape.maxY - h - 4, width: Swift.min(shape.width - 8, w), height: h)
        }
        return CGRect(x: shape.midX - w / 2, y: shape.maxY + 4, width: w, height: h)
    }

    /// The media shapes of slide `slide` with their boxes and bars on screen (`slide_media_bars`).
    public static func slideMediaBars(_ srect: CGRect, _ doc: Presentation, _ slide: Int) -> [(id: ShapeId, clip: MediaClip, rect: CGRect, bar: CGRect)] {
        let k = srect.width / Swift.max(doc.slideSize.width, 1)
        return MediaHost.slideMedia(doc, slide).map { m in
            let r = CGRect(x: srect.minX + m.xfrm.x * k, y: srect.minY + m.xfrm.y * k, width: m.xfrm.w * k, height: m.xfrm.h * k)
            return (m.id, m.clip, r, mediaBarRect(r))
        }
    }

    /// The parts of a media bar (`control_bar`'s layout): play/pause, back and forward a quarter second, the
    /// seekable track and the time label's width.
    public struct MediaBarParts: Equatable, Sendable {
        public var play: CGRect
        public var back: CGRect
        public var forward: CGRect
        /// The timeline; nil when the bar is too narrow for one.
        public var track: CGRect?
        /// Where a click or drag on the timeline lands.
        public var trackHit: CGRect?
    }

    public static func mediaBarParts(_ rect: CGRect) -> MediaBarParts {
        let h = rect.height
        var x = rect.minX + 4
        func button() -> CGRect {
            let r = CGRect(x: x, y: rect.minY + 2, width: h - 4, height: h - 4)
            x += h - 2
            return r
        }
        let play = button(), back = button(), fwd = button()
        let labelW = 64.0
        let track = CGRect(x: x + 6, y: rect.midY - 3, width: rect.maxX - labelW - 6 - (x + 6), height: 6)
        let ok = track.width > 10
        return MediaBarParts(play: play, back: back, forward: fwd, track: ok ? track : nil, trackHit: ok ? track.insetBy(dx: -4, dy: -8) : nil)
    }

    /// What a click at `p` on a media bar asks for (`control_bar`), given the clip's length and position.
    public static func mediaBarAction(_ rect: CGRect, _ p: CGPoint, duration: Double) -> MediaBarAction? {
        let parts = mediaBarParts(rect)
        if contains(parts.play, p) { return .toggle }
        if contains(parts.back, p) { return .nudge(-0.25) }
        if contains(parts.forward, p) { return .nudge(0.25) }
        if let t = parts.track, let hit = parts.trackHit, contains(hit, p), duration > 0 {
            let f = Double((p.x - t.minX) / t.width).clamped(0, 1)
            return .seek((f.isNaN ? 0 : f) * duration)
        }
        return nil
    }

    /// The play/pause button in the bottom-left corner of a GIF's box (`gif_button_rect`; PowerPoint puts it there).
    public static func gifButtonRect(_ r: CGRect) -> CGRect {
        let s = Swift.max(Swift.min(24, r.width - 8, r.height - 8), 12)
        return CGRect(x: r.minX + 6, y: r.maxY - 6 - s, width: s, height: s)
    }

    /// The part of a video frame a picture crop (left, top, right, bottom fractions) leaves visible (`crop_uv`).
    public static func cropUV(_ crop: [Double]) -> CGRect {
        func v(_ i: Int) -> Double {
            let x = crop.at(i) ?? 0
            return x.isFinite ? Double(Float(x.clamped(0, 0.99))) : 0
        }
        let (l, t, r, b) = (v(0), v(1), v(2), v(3))
        let maxX = Swift.max(1 - r, l + 0.01), maxY = Swift.max(1 - b, t + 0.01)
        return CGRect(x: l, y: t, width: maxX - l, height: maxY - t)
    }

    /// `Rect::contains` (inclusive at both ends, as egui's is).
    public static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        r.minX <= p.x && p.x <= r.maxX && r.minY <= p.y && p.y <= r.maxY
    }
}

/// What a media bar asks for (`BarAction`).
public enum MediaBarAction: Equatable, Sendable {
    case toggle
    case seek(Double)
    case nudge(Double)
}
