// DCApp — what one frame of the slide show draws: the slide's texture (rendered once per step, or every frame
// while something animates, over its kept backdrop), the transition's layers or the Morph frame, playing video
// frames with the shapes stacked above them, and the pictures presenter view and See All Slides show. Port of the
// drawing half of `ui` in deckcraft `crates/ui-egui/src/show.rs`, `part_textures`, `render_thumb` and the media
// frame drawing of `media.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import AppKit
import DCAnim
import DCAppModel
import DCCore
import DCEngine
import DCMedia
import DCModel
import DCRender
import Metal

/// Textures kept for one transition (`Transition.parts` and `.morph`).
final class ShowTransitionCache {
    var parts: [MTLTexture?]?
    var morph: MTLTexture?
}

/// A media shape's place in this frame, for the overlay (its bar, GIF button, "can't play" badge).
struct ShowMediaPlace {
    var id: ShapeId
    var rect: CGRect
    var unplayable: Bool
}

@MainActor
final class ShowStage {
    let coord: ShowCoordinator
    let metal: ShowMetal
    private var prefetch: ShowPrefetch?
    private let backdrop = ShowBackdrop()
    /// The shapes stacked above the playing videos (#1005): key, skipped shapes, texture.
    private var overlay: (key: ShowFrameKey, skip: [ShapeId], tex: MTLTexture)?
    private var videoTex: [ShapeId: (serial: UInt64, tex: MTLTexture)] = [:]
    /// The picture on screen, for presenter view.
    private(set) var current: (key: ShowFrameKey, image: RenderImage)?
    private var currentCG: (key: ShowFrameKey, image: CGImage)?
    private var thumbs: [Int: CGImage] = [:]
    private var nextThumb: (index: Int, image: CGImage)?
    /// The GIFs and media shapes of the last frame (the overlay draws their controls).
    private(set) var gifs: [ShowGif] = []
    private(set) var mediaPlaces: [ShowMediaPlace] = []
    /// The document `doc` identity the textures were made from.
    private var docRef: DocRef?

    init(coord: ShowCoordinator, metal: ShowMetal) {
        self.coord = coord
        self.metal = metal
    }

    /// The draws of the frame at `now` for a window of `full` points at `scale` pixels per point, and whether
    /// the picture changes by itself (redraw every display frame).
    func draws(full: CGRect, scale: Double, now: Double) -> (draws: [ShowDraw], animating: Bool) {
        guard let s = coord.show, let st = coord.showState else { return ([], false) }
        let doc = st.doc
        docRef = st.docRef
        let docID = ObjectIdentifier(st.docRef)
        var out: [ShowDraw] = []
        var animatingOut = false
        func px(_ r: CGRect) -> CGRect { CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale) }
        let srect = ShowGeometry.slideRect(full, reading: s.reading, doc)
        let size = ShowRender.fitSize(Int(rustCast: (srect.width * scale).rounded()), Int(rustCast: (srect.height * scale).rounded()))
        gifs = []
        mediaPlaces = []
        if s.ended { return ([], false) }
        let idx = s.state.slide
        let step = s.state.step
        let animating = s.animating
        let t = s.stepTime(now)
        let plays = s.state.triggerPlays
        let stamps = s.state.triggerStamps
        let media = MediaHost.slideMedia(doc, idx)
        let hidden = coord.hiddenMedia(doc, idx)
        gifs = coord.media.gifs(st.uid, doc, idx, now, coord.model.session.gifPaused)
        let times = gifs.map { ($0.id, $0.t) }
        let key = ShowFrameKey(
            slide: idx, step: step, size: size, doc: docID, hidden: hidden, plays: plays.map { ShowPlay(trigger: $0.trigger, step: $0.step) },
            gif: MediaHost.gifKey(gifs)
        )
        let backKey = ShowBackKey(slide: idx, size: size, doc: docID)
        let tl = s.timeline(doc)
        var tex: MTLTexture?
        if !animating, let f = s.frame, f.key == key, let reused = f.image as? MTLTexture {
            tex = reused
        } else {
            // The frame rendered ahead of time, when it is this one (waiting for it beats starting over).
            var img: RenderImage?
            if let p = prefetch, p.key == key, !animating { img = p.pending.wait() }
            prefetch = nil
            let image = img ?? ShowRender.frame(
                doc, idx, tl, step, t, size, hidden: hidden, gifTimes: times, plays: plays, stamps: stamps,
                backdrop: animating ? backdrop.get(doc, st.docRef, backKey) : nil
            )
            tex = metal.texture(image)
            if let tx = tex { s.frame = (key, tx) }
            current = (key, image)
        }
        // While this slide rests, its backdrop is readied for its animations and the next slide's first frame
        // is rendered (not one with GIFs, whose frame depends on when it is entered).
        if !animating && !tl.isEmpty { backdrop.prefetch(doc, st.docRef, backKey) }
        if !animating && s.trans == nil && !s.previewOnly, let n = s.state.peekNext(doc),
           coord.media.gifs(st.uid, doc, n, now, coord.model.session.gifPaused).isEmpty,
           prefetch.map({ $0.key.slide != n || $0.key.size != size || $0.key.doc != docID }) ?? true {
            prefetch = ShowPrefetch.start(doc, docID, n, size)
        }
        var drew = false
        if var tr = s.trans, tr.isMorph, now - tr.start < tr.dur, let from = tr.from, let a = doc.slides.at(from), let b = doc.slides.at(idx) {
            let p = tr.progress(now)
            let m = morphFrame(doc, a, b, p) { id in
                let stt = showShapeState(tl, id, 0, 0, [], [])
                return !stt.visible || stt.opacity <= 0 || hidden.contains(id)
            }
            var o = RenderOpts(scale: Double(size.w) / Swift.max(doc.slideSize.width, 1))
            o.size = (size.w, size.h)
            o.state = { id in
                var ss = ShapeState()
                ss.opacity = m.opacityOf(id)
                return ss
            }
            let text = m.text.map { TextMorph(old: $0.old, new: $0.new, from: $0.from, to: $0.to, chars: $0.chars, t: m.mix) }
            let paths = m.paths.map { PathMorph(id: $0.id, from: $0.from, fromBox: $0.fromBox, toBox: $0.toBox, t: m.mix) }
            let img = renderBlend(doc, from, idx, m.mix, m.shapes, text, paths, o)
            let cache = tr.cache as? ShowTransitionCache ?? ShowTransitionCache()
            cache.morph = metal.texture(img)
            tr.cache = cache
            s.trans = tr
            if let mt = cache.morph { out.append(.quad(mt, px(srect))) }
            drew = true
            animatingOut = true
        } else if var tr = s.trans, let new = tex {
            let p = tr.progress(now)
            if p < 1 {
                let cache = tr.cache as? ShowTransitionCache ?? ShowTransitionCache()
                // Slides split into background and content are rendered once per transition.
                if cache.parts == nil && usesSlideParts(tr.kind, tr.option) {
                    let parts = SlideParts.render(doc, tr.from, idx, ShowRenderOpts.at(doc, size))
                    cache.parts = [
                        parts.oldBack.flatMap { metal.texture($0) }, parts.oldContent.flatMap { metal.texture($0) },
                        metal.texture(parts.newBack), metal.texture(parts.newContent),
                    ]
                }
                tr.cache = cache
                s.trans = tr
                let aspect = doc.slideSize.width / Swift.max(doc.slideSize.height, 1)
                let textures = ShowTransitionTextures(old: tr.old as? MTLTexture, new: new, parts: cache.parts)
                out += ShowMetal.transitionDraws(tr.kind, tr.option, p, aspect: aspect, rect: px(srect), textures)
                drew = true
                animatingOut = true
            }
        }
        if !drew {
            s.trans = nil
            let uv = s.zoomUV
            if let tx = tex { out.append(.quad(tx, px(srect), uv: uv)) }
            // Playing video: the current frame in its box, or full screen.
            let (sw, sh) = (doc.slideSize.width, doc.slideSize.height)
            var framed: [ShapeId] = []
            var fullScreen = false
            for m in media where m.clip.video && !hidden.contains(m.id) {
                var r = ShowGeometry.slideBox(srect, uv, sw, sh, m.xfrm)
                if m.clip.fullScreen && coord.media.isPlaying(m.id) {
                    fullScreen = true
                    r = full
                }
                mediaPlaces.append(ShowMediaPlace(id: m.id, rect: r, unplayable: coord.media.videoUnplayable(m.id)))
                if let d = videoDraws(m.id, px(r), m.clip.crop) {
                    out += d
                    framed.append(m.id)
                }
            }
            for m in media where !m.clip.video { mediaPlaces.append(ShowMediaPlace(id: m.id, rect: ShowGeometry.slideBox(srect, uv, sw, sh, m.xfrm), unplayable: false)) }
            // Shapes stacked above a playing video show over it (#1005); a full-screen video covers the slide.
            let skip = fullScreen ? [] : belowPlayingVideo(doc, idx, framed)
            if skip.isEmpty {
                overlay = nil
            } else {
                let fresh = !animating && overlay.map { $0.key == key && $0.skip == skip } ?? false
                if !fresh {
                    let img = ShowRender.overlay(doc, idx, tl, step, t, size, hidden: hidden, skip: skip, gifTimes: times, plays: plays, stamps: stamps)
                    if let ot = metal.texture(img) { overlay = (key, skip, ot) }
                }
                if let o = overlay { out.append(.quad(o.tex, px(srect), uv: uv)) }
            }
            if !framed.isEmpty { animatingOut = true }
        }
        if animating { animatingOut = true }
        if gifs.contains(where: { !$0.paused }) { animatingOut = true }
        return (out, animatingOut)
    }

    /// A playing video's frame drawn in `rect` (pixels): letterboxed to the frame's shape, or, when the video
    /// is cropped, the cropped part over the whole box (`paint_frame`). nil before a frame has decoded.
    private func videoDraws(_ id: ShapeId, _ rect: CGRect, _ crop: [Double]) -> [ShowDraw]? {
        guard let (f, serial) = coord.media.frame(id) else {
            videoTex[id] = nil
            return nil
        }
        if videoTex[id]?.serial != serial {
            guard let t = metal.texture(f) else { return nil }
            videoTex[id] = (serial, t)
        }
        guard let t = videoTex[id]?.tex else { return nil }
        let black = ShowDraw.quad(nil, rect, color: SIMD4(0, 0, 0, 1))
        if crop.contains(where: { $0 > 0 }) { return [black, .quad(t, rect, uv: ShowGeometry.cropUV(crop))] }
        let (w, h) = (Double(Swift.max(t.width, 1)), Double(Swift.max(t.height, 1)))
        let k = Swift.min(rect.width / w, rect.height / h)
        let r = CGRect(x: rect.midX - w * k / 2, y: rect.midY - h * k / 2, width: w * k, height: h * k)
        return [black, .quad(t, r)]
    }

    /// The picture on screen as a CGImage (presenter view's current slide).
    func currentImage() -> CGImage? {
        guard let c = current else { return nil }
        if let cg = currentCG, cg.key == c.key { return cg.image }
        guard let img = c.image.cgImage() else { return nil }
        currentCG = (c.key, img)
        return img
    }

    /// Slide `i`'s thumbnail (See All Slides), rendered once (`render_thumb`); nil past the cap or when `budget`
    /// is spent.
    func thumb(_ i: Int, budget: inout Int) -> CGImage? {
        if let t = thumbs[i] { return t }
        guard budget > 0, thumbs.count < ShowGeometry.gridCap, let doc = coord.showState?.doc else { return nil }
        budget -= 1
        let img = ShowRender.thumb(doc, i, width: 320).cgImage()
        thumbs[i] = img
        return img
    }

    /// Presenter view's Next preview of slide `n` (480 pixels wide).
    func nextImage(_ n: Int) -> CGImage? {
        if let t = nextThumb, t.index == n { return t.image }
        guard let doc = coord.showState?.doc, let img = ShowRender.thumb(doc, n, width: 480).cgImage() else { return nil }
        nextThumb = (n, img)
        return img
    }
}

enum ShowRenderOpts {
    /// Render options for a picture of `size` pixels of `doc`'s slides.
    static func at(_ doc: Presentation, _ size: ShowSize) -> RenderOpts {
        var o = RenderOpts(scale: Double(size.w) / Swift.max(doc.slideSize.width, 1))
        o.size = (size.w, size.h)
        return o
    }
}
