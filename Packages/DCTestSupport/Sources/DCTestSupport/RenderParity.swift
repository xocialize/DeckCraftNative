// DCTestSupport — render parity: how close a Swift render is to the Rust oracle's PNG, by SSIMULACRA2
// (media-bridge MediaMeasureCore, the metric PhotoCraftNative and MarqueeOptimize measure with). 100 is
// identical; above ~90 differences are hard to see; ~70 is "high quality" for a lossy codec.
import CoreGraphics
import Foundation
import ImageIO
import MediaMeasureCore

public enum RenderParity {
    /// Straight-alpha RGBA8 pixels, rows top to bottom, composited over white (a slide has no
    /// transparency; the oracle's PNGs are opaque).
    public static func rgba(_ image: CGImage) -> RGBA8Image? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ok: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
        return RGBA8Image(width: w, height: h, pixels: px)
    }

    public static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// SSIMULACRA2 of `distorted` against `reference`; nil when sizes differ or an image can't be read.
    public static func score(reference: CGImage, distorted: CGImage) -> Double? {
        guard reference.width == distorted.width, reference.height == distorted.height,
              let r = rgba(reference), let d = rgba(distorted) else { return nil }
        return try? SSIMULACRA2.score(reference: r, distorted: d)
    }

    /// The share of pixels whose largest channel difference exceeds `tolerance` (0–255).
    public static func differingPixels(_ a: CGImage, _ b: CGImage, tolerance: Int = 8) -> Double? {
        guard a.width == b.width, a.height == b.height, let x = rgba(a), let y = rgba(b) else { return nil }
        var n = 0
        for i in stride(from: 0, to: x.pixels.count, by: 4) {
            let d = max(abs(Int(x.pixels[i]) - Int(y.pixels[i])), abs(Int(x.pixels[i + 1]) - Int(y.pixels[i + 1])),
                        abs(Int(x.pixels[i + 2]) - Int(y.pixels[i + 2])))
            if d > tolerance { n += 1 }
        }
        return Double(n) / Double(x.width * x.height)
    }

    /// Writes `image` as a PNG (for looking at a failing render beside the oracle's).
    @discardableResult
    public static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
