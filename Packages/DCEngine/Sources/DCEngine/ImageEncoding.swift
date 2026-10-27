// DCEngine — PNG, JPEG and animated GIF bytes of rendered slides.
// In place of deckcraft-render's `Image::to_png_at` / `to_jpeg_at` and the `image` crate's GIF encoder
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors), on ImageIO. The pixels are the
// same; the compressed streams are ImageIO's, so the bytes differ from deckcraft's.
import CoreGraphics
import DCCore
import DCRender
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageEncoding {
    /// deckcraft-render's `dpi_for_scale`: the resolution a picture at `pixelsPerPoint` has.
    public static func dpiForScale(_ pixelsPerPoint: Double) -> Double {
        if !pixelsPerPoint.isFinite || pixelsPerPoint <= 0 { return 72 }
        return (pixelsPerPoint * 72).clamped(1, 10_000)
    }

    /// A straight-alpha RGBA8 `CGImage`.
    static func straightImage(_ width: Int, _ height: Int, _ rgba: [UInt8], alpha: Bool = true) -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4,
              let provider = CGDataProvider(data: Data(rgba.prefix(width * height * 4)) as CFData) else { return nil }
        let info: CGImageAlphaInfo = alpha ? .last : .noneSkipLast
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: info.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func encode(_ image: CGImage, _ type: UTType, _ props: [CFString: Any]) -> [UInt8] {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { return [] }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return [] }
        return [UInt8](data as Data)
    }

    /// PNG of a render (`Image::to_png`), with no resolution recorded.
    public static func png(_ img: RenderImage) -> [UInt8] {
        guard let cg = straightImage(img.width, img.height, img.toStraight()) else { return [] }
        return encode(cg, .png, [:])
    }

    /// PNG of a render whose `pHYs` chunk says `dpi` dots per inch (`Image::to_png_at`).
    public static func png(_ img: RenderImage, dpi: Double) -> [UInt8] {
        let bytes = png(img)
        if bytes.isEmpty { return [] }
        return Images.stampPNGDPI(bytes, dpi)
    }

    /// JPEG of a render (`Image::to_jpeg_at`): `quality` 1–100, `dpi` stored as the density when given.
    public static func jpeg(_ img: RenderImage, quality: UInt8, dpi: Double?) -> [UInt8] {
        guard let cg = straightImage(img.width, img.height, img.toStraight(), alpha: false) else { return [] }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Double(min(max(quality, 1), 100)) / 100.0]
        let bytes = encode(cg, .jpeg, props)
        guard let d = dpi, d.isFinite, d >= 1, d <= Double(UInt16.max) else { return bytes }
        return stampJPEGDPI(bytes, UInt16(rustCast: d.rounded()))
    }

    /// A JPEG whose JFIF header records `dpi` dots per inch (the `image` crate's `PixelDensity::dpi`): the
    /// JFIF segment ImageIO wrote is updated, or one is put right after the start of the image.
    static func stampJPEGDPI(_ jpeg: [UInt8], _ dpi: UInt16) -> [UInt8] {
        guard jpeg.count >= 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { return jpeg }
        let hi = UInt8(dpi >> 8), lo = UInt8(dpi & 0xFF)
        if jpeg.count >= 18, jpeg[2] == 0xFF, jpeg[3] == 0xE0, Array(jpeg[6 ..< 11]) == Array("JFIF\0".utf8) {
            var out = jpeg
            out[13] = 1
            out[14] = hi
            out[15] = lo
            out[16] = hi
            out[17] = lo
            return out
        }
        let app0: [UInt8] = [0xFF, 0xE0, 0x00, 0x10] + Array("JFIF\0".utf8) + [0x01, 0x02, 0x01, hi, lo, hi, lo, 0x00, 0x00]
        return [0xFF, 0xD8] + app0 + jpeg[2...]
    }

    /// An animated GIF of straight RGBA frames, each shown `delayCs` hundredths of a second; `loop`
    /// repeats it forever, else it plays once.
    public static func gif(_ frames: [[UInt8]], width: Int, height: Int, delayCs: UInt16, loop: Bool) -> [UInt8]? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.gif.identifier as CFString, frames.count, nil) else { return nil }
        if loop {
            let file: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
            CGImageDestinationSetProperties(dest, file as CFDictionary)
        }
        let frameProps: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: Double(delayCs) / 100.0]]
        for f in frames {
            guard let cg = straightImage(width, height, f, alpha: false) else { return nil }
            CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        var out = [UInt8](data as Data)
        // ImageIO labels a GIF without a loop block `GIF87a`, yet writes each frame's delay in a Graphic
        // Control Extension, which only GIF89a has. Every GIF deckcraft writes is `GIF89a`.
        if out.starts(with: Array("GIF87a".utf8)) { out[4] = UInt8(ascii: "9") }
        return out
    }
}
