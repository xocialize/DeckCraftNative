// DCRender — the colour under an image's transparent edge, for PDF. CGPDFContext writes an image with
// transparency as its colour under a soft mask, and the transparent pixels' colour is whatever the image holds
// there: RGB 0 in a premultiplied raster (an effect drawn as an image) and in most pictures. A viewer that smooths
// the image samples the colour and the mask separately, so along a hard edge it blends that black into the ink:
// a dark fringe. deckcraft fixed the same fringe in its raster PDF by copying the backdrop's colour into its
// content raster's transparent pixels (d6f532bb); with no backdrop raster here, the ink's own colour is bled
// outwards instead, the usual cure for this in texture pipelines. Raster drawing doesn't need it.
import CoreGraphics
import Foundation
import Synchronization

enum EdgeBleed {
    /// How far, in pixels, the colour is carried out from the ink: further than any smoothing filter reaches.
    static let reach = 2

    private struct Entry {
        var source: CGImage
        var image: CGImage
    }

    /// The last few images, holding their source so its identity stays valid.
    private static let cache = Mutex<[Entry]>([])

    /// `img` as straight sRGB RGBA whose transparent pixels near ink carry the ink's colour; `img` itself when it
    /// has no alpha or no transparent pixel touches ink.
    static func apply(_ img: CGImage) -> CGImage {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return img
        default: break
        }
        if let hit = cache.withLock({ $0.first { $0.source === img }?.image }) { return hit }
        let out = bled(img) ?? img
        cache.withLock { c in
            c.insert(Entry(source: img, image: out), at: 0)
            if c.count > 8 { c.removeLast(c.count - 8) }
        }
        return out
    }

    private static func bled(_ img: CGImage) -> CGImage? {
        let (w, h) = (img.width, img.height)
        guard w > 0, h > 0, w <= maxRenderSide, h <= maxRenderSide else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: Canvas.srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let n = w * h
        // 0: transparent, 1: has a colour, 2: transparent and waiting for one.
        var state = [UInt8](repeating: 0, count: n)
        var frontier: [Int] = []
        var edge = false
        px.withUnsafeMutableBufferPointer { p in
            state.withUnsafeMutableBufferPointer { st in
                // Straight colour, and which pixels have a colour of their own.
                for i in 0 ..< n {
                    let a = UInt32(p[i * 4 + 3])
                    guard a > 0 else { continue }
                    st[i] = 1
                    if a < 255 {
                        for k in 0 ..< 3 { p[i * 4 + k] = UInt8(min(255, (UInt32(p[i * 4 + k]) * 255 + a / 2) / a)) }
                    }
                }
                // The transparent pixels beside ink, found where a row or column changes between the two.
                func wait(_ i: Int) {
                    if st[i] == 0 { st[i] = 2; frontier.append(i) }
                }
                for y in 0 ..< h {
                    let row = y * w
                    for x in 0 ..< w {
                        let i = row + x, here = st[i] == 1
                        if x + 1 < w, here != (st[i + 1] == 1) { wait(here ? i + 1 : i) }
                        if y + 1 < h, here != (st[i + w] == 1) { wait(here ? i + w : i) }
                    }
                }
                edge = !frontier.isEmpty
                // Each pass gives those pixels the mean of their coloured neighbours, then moves out a pixel.
                var colours: [UInt8] = []
                for _ in 0 ..< reach where !frontier.isEmpty {
                    colours.removeAll(keepingCapacity: true)
                    for i in frontier {
                        let (x, y) = (i % w, i / w)
                        var r = 0, g = 0, b = 0, c = 0
                        for ny in max(0, y - 1) ... min(h - 1, y + 1) {
                            for nx in max(0, x - 1) ... min(w - 1, x + 1) where st[ny * w + nx] == 1 {
                                let j = (ny * w + nx) * 4
                                r += Int(p[j])
                                g += Int(p[j + 1])
                                b += Int(p[j + 2])
                                c += 1
                            }
                        }
                        c = max(c, 1)
                        colours += [UInt8(r / c), UInt8(g / c), UInt8(b / c)]
                    }
                    let done = frontier
                    frontier.removeAll(keepingCapacity: true)
                    for (k, i) in done.enumerated() {
                        st[i] = 1
                        for c in 0 ..< 3 { p[i * 4 + c] = colours[k * 3 + c] }
                    }
                    for i in done {
                        let (x, y) = (i % w, i / w)
                        if x > 0 { wait(i - 1) }
                        if x + 1 < w { wait(i + 1) }
                        if y > 0 { wait(i - w) }
                        if y + 1 < h { wait(i + w) }
                    }
                }
            }
        }
        guard edge, let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: Canvas.srgb,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: img.shouldInterpolate, intent: img.renderingIntent
        )
    }
}
