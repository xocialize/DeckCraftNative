// DCRender — exact bilinear magnification of pictures. vello samples a magnified image bilinearly with
// exact weights; CoreGraphics quantises its interpolation weights (about eighths of a source pixel), which
// shows as soft blocks when a small picture is stretched many times over (an 8 px image across a slide).
// The raster canvas therefore enlarges such an image by a whole factor here first, so CoreGraphics only
// scales the rest (under 2×), where the quantisation can't be seen. PDF output keeps the original image.
import CoreGraphics
import Synchronization

enum Upscale {
    /// Largest side and pixel count of an enlarged image.
    static let maxSide = 8192
    static let maxPixels = 32 << 20

    /// The whole factor to enlarge `img` by before drawing it under `ctm` (device pixels per image pixel
    /// along each axis), or nil when the magnification is under 2× or the result would be too large.
    static func factor(_ img: CGImage, _ ctm: CGAffineTransform) -> Int? {
        let sx = (ctm.a * ctm.a + ctm.b * ctm.b).squareRoot(), sy = (ctm.c * ctm.c + ctm.d * ctm.d).squareRoot()
        let s = Swift.min(sx, sy)
        guard s.isFinite, s >= 2 else { return nil }
        let f = Int(Swift.min(s, Double(maxSide)).rounded(.down))
        guard img.width * f <= maxSide, img.height * f <= maxSide, img.width * f * img.height * f <= maxPixels else { return nil }
        return f
    }

    private struct Entry {
        var source: CGImage
        var factor: Int
        var image: CGImage
    }

    /// The last few enlargements, holding their source image so its identity stays valid.
    private static let cache = Mutex<[Entry]>([])

    /// `img` enlarged `f` times, each output pixel the bilinear sample at its centre (premultiplied, the
    /// edges clamped: vello's `Extend::Pad`).
    static func bilinear(_ img: CGImage, _ f: Int) -> CGImage? {
        if let hit = cache.withLock({ $0.first { $0.source === img && $0.factor == f }?.image }) { return hit }
        let (w, h) = (img.width, img.height)
        guard f >= 2, w > 0, h > 0 else { return nil }
        var src = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = src.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: Canvas.srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let (ow, oh) = (w * f, h * f)
        // Per output column and row: the two source indices and the weight of the second.
        func taps(_ n: Int, _ count: Int) -> [(Int, Int, Float)] {
            (0 ..< count).map { i in
                let x = (Float(i) + 0.5) / Float(f) - 0.5
                let x0 = Swift.max(0, Swift.min(n - 1, Int(x.rounded(.down))))
                let x1 = Swift.min(n - 1, x0 + 1)
                let t = Swift.max(0, Swift.min(1, x - Float(x0)))
                return (x0, x1, x <= 0 ? 0 : t)
            }
        }
        let cols = taps(w, ow), rows = taps(h, oh)
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        out.withUnsafeMutableBufferPointer { o in
            src.withUnsafeBufferPointer { s in
                for (y, (r0, r1, ty)) in rows.enumerated() {
                    for (x, (c0, c1, tx)) in cols.enumerated() {
                        let a = (r0 * w + c0) * 4, b = (r0 * w + c1) * 4, c = (r1 * w + c0) * 4, d = (r1 * w + c1) * 4
                        let di = (y * ow + x) * 4
                        for k in 0 ..< 4 {
                            let top = Float(s[a + k]) * (1 - tx) + Float(s[b + k]) * tx
                            let bottom = Float(s[c + k]) * (1 - tx) + Float(s[d + k]) * tx
                            o[di + k] = UInt8(Swift.min(255, (top * (1 - ty) + bottom * ty).rounded()))
                        }
                    }
                }
            }
        }
        guard let up = RenderImage(width: ow, height: oh, pixels: out).cgImage() else { return nil }
        cache.withLock { c in
            c.insert(Entry(source: img, factor: f, image: up), at: 0)
            if c.count > 8 { c.removeLast(c.count - 8) }
        }
        return up
    }
}
