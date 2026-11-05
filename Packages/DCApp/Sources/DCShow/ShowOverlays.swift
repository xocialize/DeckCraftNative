// DCShow — what the audience sees over the slide that isn't the slide: the end screen's line, the blank screens
// (B and W) and ink, drawn in this order over the frame, as the show window's overlay drew them. Port of that part
// of the overlay painting of `ui` in deckcraft `crates/ui-egui/src/show.rs` (MIT OR Apache-2.0, © ArtCraft Team
// and the DeckCraft contributors); DCApp's `ShowOverlayView` drew them in AppKit until 2026-11-04, so a client of
// the renderer alone (a texture in another program) didn't see them. Pointer-driven and presenter-side marks (the
// laser, media bars, GIF buttons, Go to slide, the zoom prompt, See All Slides, the rehearsal HUD) stay with the
// window that has the pointer.
import CNCore
import CoreGraphics
import CoreText
import DCAppModel
import DCColor
import DCModel
import DCRender
import Foundation
import Metal

/// Ink rasterised once per change of the strokes, the slide's place, the zoom or the target size.
@MainActor
final class ShowInkLayer {
    struct Key: Equatable {
        var strokes: [[CGPoint]]
        var srect: CGRect
        var uv: CGRect
        var scale: Double
        var width: Int
        var height: Int
        var color: Rgba
    }

    private var key: Key?
    private var texture: MTLTexture?

    /// The ink texture for `key` (the whole target), drawn again only when the key changed.
    func texture(_ key: Key, _ metal: ShowMetal) -> MTLTexture? {
        if key == self.key, let t = texture { return t }
        guard let img = Self.raster(key) else { return nil }
        texture = metal.texture(img, reuse: texture)
        self.key = key
        return texture
    }

    /// The strokes as the show window drew them: 3 points wide, round caps and joins, the pen colour, on a
    /// transparent target of `width`×`height` pixels whose coordinates are points × `scale`, top left.
    nonisolated static func raster(_ k: Key) -> RenderImage? {
        guard k.width > 0, k.height > 0, k.width <= 16384, k.height <= 16384, k.scale.isFinite, k.scale > 0 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var px = [UInt8](repeating: 0, count: k.width * k.height * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: k.width, height: k.height, bitsPerComponent: 8, bytesPerRow: k.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(k.height))
            ctx.scaleBy(x: CGFloat(k.scale), y: -CGFloat(k.scale))
            ctx.setStrokeColor(CGColor(srgbRed: Double(k.color.r) / 255, green: Double(k.color.g) / 255, blue: Double(k.color.b) / 255, alpha: 1))
            ctx.setLineWidth(3)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for stroke in k.strokes where stroke.count > 1 {
                let pts = stroke.map { ShowGeometry.slideToScreen(k.srect, k.uv, $0.x, $0.y) }
                ctx.addLines(between: pts)
                ctx.strokePath()
            }
            return true
        }
        return ok ? RenderImage(width: k.width, height: k.height, pixels: px) : nil
    }
}

/// One line of text drawn once per change of its words or scale: the end screen's line.
@MainActor
final class ShowTextLayer {
    struct Key: Equatable {
        var text: String
        var scale: Double
        /// The fraction of a pixel the line starts past its whole pixel, so the texture lands on whole pixels.
        var fx: Double
        var fy: Double
    }

    private var key: Key?
    private var texture: MTLTexture?

    nonisolated static let pointSize = 18.0
    nonisolated static let gray = 0.78
    nonisolated static let pad = 2

    /// The line's size in points and its baseline below its top, as AppKit lays out one line
    /// (`NSAttributedString.size()`, `draw(at:)`): the typographic width, and the font's ascent, descent and leading
    /// each rounded to a whole point (the system font at 18 points: 17.4 + 3.8 → a 21-point line, baseline 17 down).
    nonisolated static func size(_ text: String) -> (width: Double, height: Double, ascent: Double) {
        let line = Self.line(text, pointSize)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let (a, d, l) = (Double(ascent).rounded(), Double(descent).rounded(), Double(leading).rounded())
        return (w, a + d + l, a)
    }

    nonisolated static func line(_ text: String, _ size: Double) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) ?? CGColorSpaceCreateDeviceGray()
        let color = CGColor(colorSpace: space, components: [gray, 1]) ?? CGColor(gray: gray, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    /// `text` centred on `center` (points) at `scale`: its texture and where it goes, in pixels.
    func draw(_ text: String, center: CGPoint, scale: Double, _ metal: ShowMetal) -> ShowDraw? {
        guard !text.isEmpty, scale.isFinite, scale > 0 else { return nil }
        let m = Self.size(text)
        // AppKit's `drawCentered`: the line's box centred on `center`, its baseline an ascent below its top.
        let left = (center.x - m.width / 2) * scale, baseline = (center.y - m.height / 2 + m.ascent) * scale
        let x0 = left.rounded(.down) - Double(Self.pad), top = (baseline - m.ascent * scale).rounded(.down) - Double(Self.pad)
        let key = Key(text: text, scale: scale, fx: left - x0, fy: baseline - top)
        let w = Int((m.width * scale).rounded(.up)) + 2 * Self.pad + 2
        let h = Int((m.height * scale).rounded(.up)) + 2 * Self.pad + 2
        if key != self.key || texture == nil {
            guard let img = Self.raster(text, scale: scale, width: w, height: h, x: key.fx, baseline: key.fy) else { return nil }
            texture = metal.texture(img, reuse: texture)
            self.key = key
        }
        guard let t = texture else { return nil }
        return .quad(t, CGRect(x: x0, y: top, width: Double(t.width), height: Double(t.height)))
    }

    /// The line at pixel size, its pen at (`x`, `baseline`) pixels from the top left, on a transparent target.
    nonisolated static func raster(_ text: String, scale: Double, width w: Int, height h: Int, x: Double, baseline: Double) -> RenderImage? {
        guard w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        // Set at 18 points under a scaled context, as the window drew it: a font made at 18 × scale points would
        // take the system face's display design, narrower than the text design the window shows.
        let line = Self.line(text, pointSize)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            ctx.textPosition = CGPoint(x: x / scale, y: (Double(h) - baseline) / scale)
            CTLineDraw(line, ctx)
            return true
        }
        return ok ? RenderImage(width: w, height: h, pixels: px) : nil
    }
}

extension ShowRenderer {
    /// The end screen's line, the blank screen and ink over a frame of `full` points at `scale`, in that order.
    func overlayDraws(_ s: ShowController, _ doc: Presentation, full: CGRect, scale: Double, srect: CGRect) -> [ShowDraw] {
        var out: [ShowDraw] = []
        let fullPx = CGRect(x: full.minX * scale, y: full.minY * scale, width: full.width * scale, height: full.height * scale)
        if s.ended, let text = endText,
           let d = endLine.draw(text, center: CGPoint(x: full.midX, y: full.minY + 40), scale: scale, metal) {
            out.append(d)
        }
        if let b = s.blank {
            out.append(.quad(nil, fullPx, color: b == .black ? SIMD4(0, 0, 0, 1) : SIMD4(1, 1, 1, 1)))
        }
        if s.strokes.contains(where: { $0.count > 1 }) {
            let key = ShowInkLayer.Key(
                strokes: s.strokes, srect: srect, uv: s.zoomUV, scale: scale,
                width: Int(rustCast: (full.width * scale).rounded()), height: Int(rustCast: (full.height * scale).rounded()),
                color: doc.show.penColor
            )
            if let t = ink.texture(key, metal) {
                out.append(.quad(t, CGRect(x: fullPx.minX, y: fullPx.minY, width: Double(t.width), height: Double(t.height))))
            }
        }
        return out
    }
}
