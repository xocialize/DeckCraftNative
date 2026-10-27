// DCRender — decoded pictures shared by every render in this process, keyed by the media bytes' storage
// and the requested size level and adjustments, so each picture is decoded once per size; picture
// adjustments (brightness, contrast, saturation, grayscale, duotone, black and white, clear colour,
// inverted alpha) as PowerPoint applies them; a picture's natural size from the resolution it records.
// Port of deckcraft crates/render/src/images.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors), decoding with ImageIO instead of the `image` crate.
import Accelerate
import CoreGraphics
import DCColor
import DCCore
import DCModel
import Foundation
import ImageIO

/// Straight (unpremultiplied) RGBA8, rows top to bottom (the `image` crate's `RgbaImage`).
public struct StraightImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

public enum Images {
    static let budget = 512 << 20

    /// Largest straight-RGBA picture a decode may produce (bytes, 4 per pixel), checked from the
    /// header before decoding and again after.
    static let maxRGBA: UInt64 = 512 << 20

    /// Pictures that failed to decode, remembered so they aren't retried every frame: at most this many,
    /// holding at most this many encoded bytes (oldest forgotten first). Larger failed inputs aren't kept.
    static let badMax = 256
    static let badBudget = 64 << 20

    /// Longest side, total decoded size and frame count kept for one animated GIF; the largest canvas
    /// decoded at all; and the decoded size of all cached GIFs together.
    static let gifSide = 1024
    static let gifBudget = 64 << 20
    static let gifMaxFrames = 1000
    static let gifMaxCanvas: UInt64 = 4096 * 4096
    static let gifMaxTotalCanvasPixels: UInt64 = 256 * 1024 * 1024
    static let gifCacheBudget = 192 << 20

    /// The side a metafile is drawn at by default (render/metafile.rs `DEFAULT_SIDE`).
    public static let metafileDefaultSide = 1024

    /// The metafile renderer (deckcraft render/metafile.rs): recognises WMF and EMF bytes and draws them
    /// to straight RGBA with the longer side the given pixels. `MetafileRender.hooks` by default; nil
    /// leaves metafiles undecoded.
    public struct MetafileHooks: Sendable {
        public var isMetafile: @Sendable ([UInt8]) -> Bool
        public var rasterize: @Sendable ([UInt8], Int) -> StraightImage?

        public init(isMetafile: @escaping @Sendable ([UInt8]) -> Bool, rasterize: @escaping @Sendable ([UInt8], Int) -> StraightImage?) {
            self.isMetafile = isMetafile
            self.rasterize = rasterize
        }
    }

    public static var metafile: MetafileHooks? {
        get { cache.withLock { $0.metafile } }
        set { cache.withLock { $0.metafile = newValue } }
    }

    // MARK: Cache

    /// A cache key part: the media bytes' storage address. The cache holds the bytes it was made from,
    /// so the address can't be reused by other bytes while it's listed.
    static func address(_ bytes: [UInt8]) -> UInt {
        bytes.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }

    struct AdjustKey: Hashable {
        var brightness: UInt64
        var contrast: UInt64
        var saturation: UInt64
        var grayscale: Bool
        var bilevel: UInt64?
        var alphaInv: Bool
        var sharpen: UInt64
        var clear: [UInt8]?
        var duotone: [UInt8]?
    }

    static func adjustKey(_ a: PictureAdjust) -> AdjustKey {
        AdjustKey(
            brightness: a.brightness.bitPattern, contrast: a.contrast.bitPattern, saturation: (a.saturation ?? 1.0).bitPattern,
            grayscale: a.grayscale, bilevel: a.bilevel?.bitPattern, alphaInv: a.alphaInv, sharpen: a.sharpen.bitPattern,
            clear: a.clearColor.map { [$0.r, $0.g, $0.b] },
            duotone: duotoneRGB(a).map { [$0.0.r, $0.0.g, $0.0.b, $0.0.a, $0.1.r, $0.1.g, $0.1.b, $0.1.a] }
        )
    }

    struct Key: Hashable {
        var addr: UInt
        var bucket: UInt32
        var adjust: AdjustKey
    }

    struct Entry {
        var bytes: [UInt8]
        var image: CGImage
        var stamp: UInt64
    }

    /// The frames of an animated GIF and when each one ends, in seconds from the start of a loop.
    final class Anim: @unchecked Sendable {
        let frames: [CGImage]
        let ends: [Double]

        init(frames: [CGImage], ends: [Double]) {
            self.frames = frames
            self.ends = ends
        }

        /// Decoded bytes held by the frames.
        var bytes: Int { frames.reduce(0) { $0 + $1.width * $1.height * 4 } }

        /// The frame showing `t` seconds into the (looping) animation and the seconds until the next.
        func at(_ t: Double) -> (Int, Double) {
            let total = ends.last ?? 0.0
            if total <= 0.0 || !t.isFinite { return (0, 1.0) }
            let local = t.rustMax(0.0).truncatingRemainder(dividingBy: total)
            let i = min(ends.firstIndex { !($0 <= local) } ?? ends.count, max(ends.count - 1, 0))
            return (i, ((ends.at(i) ?? total) - local).rustMax(0.001))
        }
    }

    struct AnimKey: Hashable {
        var addr: UInt
        var adjust: AdjustKey
    }

    struct Cache {
        var map: [Key: Entry] = [:]
        var bytes = 0
        var clock: UInt64 = 0
        var bad: [UInt: [UInt8]] = [:]
        var badOrder: [UInt] = []
        var badBytes = 0
        var anims: [AnimKey: (bytes: [UInt8], anim: Anim?)] = [:]
        var metafile: MetafileHooks? = MetafileRender.hooks

        /// Remember that `bytes` doesn't decode, within `badMax` and `badBudget`.
        mutating func markBad(_ addr: UInt, _ bytes: [UInt8]) {
            if bytes.count > Images.badBudget || bad[addr] != nil { return }
            while bad.count >= Images.badMax || badBytes + bytes.count > Images.badBudget {
                guard !badOrder.isEmpty else { break }
                let old = badOrder.removeFirst()
                if let b = bad.removeValue(forKey: old) { badBytes = max(badBytes - b.count, 0) }
            }
            bad[addr] = bytes
            badOrder.append(addr)
            badBytes += bytes.count
        }

        func isBad(_ addr: UInt, _ bytes: [UInt8]) -> Bool {
            guard let b = bad[addr] else { return false }
            return Images.address(b) == Images.address(bytes) && b.count == bytes.count
        }
    }

    final class Locked<T>: @unchecked Sendable {
        private var value: T
        private let lock = NSLock()

        init(_ value: T) { self.value = value }

        func withLock<R>(_ f: (inout T) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return f(&value)
        }
    }

    static let cache = Locked(Cache())

    /// The duotone's dark and light colours. The painter resolves them to plain RGB first (see
    /// `PaintFill.resolved`); a colour that is still a scheme reference falls back to black and white.
    static func duotoneRGB(_ a: PictureAdjust) -> (Rgba, Rgba)? {
        guard let pair = a.duotone else { return nil }
        func rgb(_ c: ColorRef, _ or: Rgba) -> Rgba {
            if case .rgb(let v) = c.base, c.mods.isEmpty { return v }
            return or
        }
        return (rgb(pair.a, .black), rgb(pair.b, .white))
    }

    // MARK: Decoding

    /// Decode encoded bytes (PNG, JPEG, GIF, WebP, BMP, TIFF…; WMF and EMF drawn at
    /// `metafileDefaultSide`) to straight RGBA.
    public static func decode(_ bytes: [UInt8]) -> StraightImage? { decodeAt(bytes, metafileDefaultSide) }

    /// `decode`, with a metafile drawn with its longer side `side` px.
    static func decodeAt(_ bytes: [UInt8], _ side: Int) -> StraightImage? {
        if bytes.count > 512 << 20 { return nil }
        if let mf = metafile, mf.isMetafile(bytes) { return mf.rasterize(bytes, side) }
        return decodeRaster(bytes, maxRGBA)
    }

    /// Whether a `w` × `h` picture fits `max` bytes of RGBA.
    static func fits(_ w: Int, _ h: Int, _ max: UInt64) -> Bool {
        w > 0 && h > 0 && UInt64(w).multipliedReportingOverflow(by: UInt64(h)).partialValue.multipliedReportingOverflow(by: 4).partialValue <= max
            && UInt64(w) < 1 << 31 && UInt64(h) < 1 << 31
    }

    static func source(_ bytes: [UInt8]) -> CGImageSource? {
        CGImageSourceCreateWithData(Data(bytes) as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// Pixel size from the header, without decoding.
    static func headerSize(_ src: CGImageSource) -> (Int, Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Decode a raster picture to RGBA, refusing (before decoding, by its header, and again after) any
    /// whose RGBA would exceed `max` bytes.
    static func decodeRaster(_ bytes: [UInt8], _ max: UInt64) -> StraightImage? {
        guard let src = source(bytes), CGImageSourceGetCount(src) > 0 else { return nil }
        if let (w, h) = headerSize(src), !fits(w, h, max) { return nil }
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, nil), fits(img.width, img.height, max) else { return nil }
        return straight(img)
    }

    /// A CGImage as straight RGBA8. RGB and grey pictures keep their stored values (as the `image` crate,
    /// which applies no colour profile; grey is copied to each channel); indexed and CMYK ones are
    /// converted to sRGB.
    static func straight(_ img: CGImage) -> StraightImage? {
        if let gray = img.colorSpace, gray.model == .monochrome,
           let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 16, colorSpace: gray,
                                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)),
           let ga = rows(img, format, 2) {
            var px = [UInt8](repeating: 0, count: ga.count * 2)
            for i in 0 ..< ga.count / 2 {
                let (v, a) = (ga[i * 2], ga[i * 2 + 1])
                (px[i * 4], px[i * 4 + 1], px[i * 4 + 2], px[i * 4 + 3]) = (v, v, v, a)
            }
            return StraightImage(width: img.width, height: img.height, pixels: px)
        }
        let space: CGColorSpace = img.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? Canvas.srgb
        guard let format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        ), let px = rows(img, format, 4) else { return nil }
        return StraightImage(width: img.width, height: img.height, pixels: px)
    }

    /// `img` converted to `format` by vImage, `bpp` bytes a pixel, rows packed.
    static func rows(_ img: CGImage, _ format: vImage_CGImageFormat, _ bpp: Int) -> [UInt8]? {
        guard let buf = try? vImage_Buffer(cgImage: img, format: format) else { return nil }
        defer { buf.free() }
        let w = Int(buf.width), h = Int(buf.height)
        guard w == img.width, h == img.height, let base = buf.data else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)
        var px = [UInt8](repeating: 0, count: w * h * bpp)
        for y in 0 ..< h {
            for i in 0 ..< w * bpp { px[y * w * bpp + i] = src[y * buf.rowBytes + i] }
        }
        return px
    }

    /// Straight RGBA resized (the `image` crate's `resize` with the triangle filter; here vImage's
    /// high-quality resampling, which smooths the same way on a downscale).
    static func resize(_ img: StraightImage, _ nw: Int, _ nh: Int) -> StraightImage {
        guard nw > 0, nh > 0, img.width > 0, img.height > 0, img.pixels.count == img.width * img.height * 4 else { return img }
        var out = [UInt8](repeating: 0, count: nw * nh * 4)
        var input = img.pixels
        let err: vImage_Error = input.withUnsafeMutableBytes { s in
            out.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(img.height), width: vImagePixelCount(img.width), rowBytes: img.width * 4)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(nh), width: vImagePixelCount(nw), rowBytes: nw * 4)
                return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return err == kvImageNoError ? StraightImage(width: nw, height: nh, pixels: out) : img
    }

    /// Straight RGBA to a premultiplied image.
    static func premultiplied(_ img: StraightImage) -> CGImage? {
        guard img.width <= Int(UInt16.max), img.height <= Int(UInt16.max) else { return nil }
        var px = img.pixels
        var i = 0
        while i + 3 < px.count {
            let a = UInt16(px[i + 3])
            for c in 0 ..< 3 { px[i + c] = UInt8((UInt16(px[i + c]) * a + 127) / 255) }
            i += 4
        }
        return RenderImage(width: img.width, height: img.height, pixels: px).cgImage()
    }

    /// A premultiplied image of the picture, downsampled so its longer side is near `want` px.
    public static func decodeFor(_ bytes: [UInt8], _ want: Double, _ adj: PictureAdjust) -> CGImage? {
        let addr = address(bytes)
        if cache.withLock({ $0.isBad(addr, bytes) }) { return nil }
        // Power-of-two size buckets so zooming doesn't re-decode every frame.
        let bucket = min(UInt32(rustCast: Darwin.log2(want.rustMax(16.0)).rounded(.up)), 15)
        let key = Key(addr: addr, bucket: bucket, adjust: adjustKey(adj))
        if let hit = cache.withLock({ c -> CGImage? in
            c.clock += 1
            let clock = c.clock
            guard var e = c.map[key] else { return nil }
            e.stamp = clock
            c.map[key] = e
            return e.image
        }) {
            return hit
        }
        let target = 1 << Int(bucket)
        guard var img = decodeAt(bytes, target) else {
            cache.withLock { $0.markBad(addr, bytes) }
            return nil
        }
        let (w, h) = (img.width, img.height)
        if max(w, h) > max(target, 16) && max(w, h) > min(4096, target * 2) {
            let k = Double(target) / Double(max(w, h))
            img = resize(img, max(Int(UInt32(rustCast: (Double(w) * k).rounded())), 1), max(Int(UInt32(rustCast: (Double(h) * k).rounded())), 1))
        }
        applyAdjust(&img, adj)
        guard let image = premultiplied(img) else { return nil }
        cache.withLock { c in
            c.clock += 1
            c.bytes += img.width * img.height * 4
            c.map[key] = Entry(bytes: bytes, image: image, stamp: c.clock)
            while c.bytes > budget && c.map.count > 1 {
                guard let oldest = c.map.min(by: { $0.value.stamp < $1.value.stamp })?.key else { break }
                if let e = c.map.removeValue(forKey: oldest) { c.bytes = max(c.bytes - e.image.width * e.image.height * 4, 0) }
            }
        }
        return image
    }

    // MARK: Natural size and resolution

    /// A raster picture's own size in 96-dpi pixels (so 0.75 pt each), read from its header: its pixel
    /// size, scaled by the resolution it records (PNG `pHYs`, JPEG JFIF density) when that isn't 96 dpi,
    /// as PowerPoint sizes pictures. Nil for metafiles and anything unreadable.
    public static func naturalSize(_ bytes: [UInt8]) -> (Double, Double)? {
        if let mf = metafile, mf.isMetafile(bytes) { return nil }
        guard let src = source(bytes), let (w, h) = headerSize(src), w > 0, h > 0 else { return nil }
        let (dx, dy) = dpi(bytes) ?? (96.0, 96.0)
        return (Double(w) * 96.0 / dx, Double(h) * 96.0 / dy)
    }

    static func be32(_ b: [UInt8], _ i: Int) -> UInt32? {
        guard i >= 0, let a = b.at(i), let c = b.at(i + 1), let d = b.at(i + 2), let e = b.at(i + 3) else { return nil }
        return UInt32(a) << 24 | UInt32(c) << 16 | UInt32(d) << 8 | UInt32(e)
    }

    static func be16(_ b: [UInt8], _ i: Int) -> UInt16? {
        guard i >= 0, let a = b.at(i), let c = b.at(i + 1) else { return nil }
        return UInt16(a) << 8 | UInt16(c)
    }

    static func slice(_ b: [UInt8], _ i: Int, _ n: Int) -> [UInt8]? {
        guard i >= 0, n >= 0, i <= b.count - n else { return nil }
        return Array(b[i ..< i + n])
    }

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The resolution (whole dots per inch across and down) a PNG or JPEG records, when it records one
    /// in a plausible range.
    public static func dpi(_ bytes: [UInt8]) -> (Double, Double)? {
        // Whole dots per inch: PNGs store dots per metre, so 96 dpi reads as 95.9866.
        func ok(_ d: Double) -> Double? { d.isFinite && d >= 10.0 && d <= 10000.0 ? d.rounded() : nil }
        if bytes.starts(with: pngSignature) {
            var i = 8
            for _ in 0 ..< 64 {
                guard let len = be32(bytes, i), let kind = slice(bytes, i + 4, 4) else { return nil }
                if kind == Array("pHYs".utf8) {
                    guard let x = be32(bytes, i + 8), let y = be32(bytes, i + 12), let unit = bytes.at(i + 16) else { return nil }
                    guard unit == 1, let dx = ok(Double(x) * 0.0254), let dy = ok(Double(y) * 0.0254) else { return nil }
                    return (dx, dy)
                }
                if kind == Array("IDAT".utf8) || kind == Array("IEND".utf8) { return nil }
                let (n, o1) = i.addingReportingOverflow(12)
                let (m, o2) = n.addingReportingOverflow(Int(len))
                if o1 || o2 { return nil }
                i = m
            }
            return nil
        }
        if bytes.starts(with: [0xFF, 0xD8]), slice(bytes, 6, 5) == Array("JFIF\0".utf8) {
            guard let unit = bytes.at(13), let x16 = be16(bytes, 14), let y16 = be16(bytes, 16) else { return nil }
            let (x, y) = (Double(x16), Double(y16))
            switch unit {
            case 1:
                guard let dx = ok(x), let dy = ok(y) else { return nil }
                return (dx, dy)
            case 2:
                guard let dx = ok(x * 2.54), let dy = ok(y * 2.54) else { return nil }
                return (dx, dy)
            default:
                return nil
            }
        }
        return nil
    }

    /// A copy of a PNG with a `pHYs` chunk saying `dpi` dots per inch. Anything that is not a PNG, or a
    /// resolution the reader would reject, is returned unchanged; a file that already has `pHYs` too.
    public static func stampPNGDPI(_ png: [UInt8], _ dpi: Double) -> [UInt8] {
        guard let ppm = pixelsPerMetre(dpi), let end = ihdrEnd(png), !hasPHYs(png) else { return png }
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let body = Array("pHYs".utf8) + be(ppm) + be(ppm) + [1]
        return Array(png[..<end]) + be(9) + body + be(pngCRC(body)) + Array(png[end...])
    }

    /// Dots per inch as pixels per metre, the unit a PNG `pHYs` chunk stores.
    static func pixelsPerMetre(_ dpi: Double) -> UInt32? {
        guard dpi.isFinite, dpi >= 1.0, dpi <= 10_000.0 else { return nil }
        let ppm = (dpi / 0.0254).rounded()
        guard ppm.isFinite, ppm >= 1.0, ppm <= Double(UInt32.max) else { return nil }
        return UInt32(rustCast: ppm)
    }

    static func ihdrEnd(_ png: [UInt8]) -> Int? {
        guard png.starts(with: pngSignature), let len = be32(png, 8), slice(png, 12, 4) == Array("IHDR".utf8) else { return nil }
        let end = 20 + Int(len)
        return end <= png.count ? end : nil
    }

    static func hasPHYs(_ png: [UInt8]) -> Bool {
        var i = 8
        for _ in 0 ..< 64 {
            guard let len = be32(png, i), let kind = slice(png, i + 4, 4) else { return false }
            if kind == Array("pHYs".utf8) { return true }
            if kind == Array("IDAT".utf8) || kind == Array("IEND".utf8) { return false }
            let next = i + 12 + Int(len)
            guard next <= png.count else { return false }
            i = next
        }
        return false
    }

    static func pngCRC(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data {
            c ^= UInt32(b)
            for _ in 0 ..< 8 {
                let mask = 0 &- (c & 1)
                c = (c >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return ~c
    }

    // MARK: Animated GIFs

    /// Decode every frame of an animated GIF (nil for a still or broken one).
    static func decodeAnim(_ bytes: [UInt8], _ adj: PictureAdjust) -> Anim? {
        guard let src = source(bytes), let (w, h) = headerSize(src), w > 0, h > 0,
              UInt64(w) * UInt64(h) <= gifMaxCanvas else { return nil }
        let k = (Double(gifSide) / Double(max(w, h))).rustMin(1.0)
        let nw = max(Int(UInt32(rustCast: (Double(w) * k).rounded())), 1)
        let nh = max(Int(UInt32(rustCast: (Double(h) * k).rounded())), 1)
        let size = nw * nh * 4
        let canvasPixels = UInt64(w) * UInt64(h)
        var totalCanvasPixels: UInt64 = 0
        var frames: [CGImage] = []
        var ends: [Double] = []
        var t = 0.0
        let count = CGImageSourceGetCount(src)
        var index = 0
        while true {
            if frames.count >= gifMaxFrames || (frames.count + 1) * size > gifBudget { break }
            if totalCanvasPixels + canvasPixels > gifMaxTotalCanvasPixels { break }
            guard index < count, let cg = CGImageSourceCreateImageAtIndex(src, index, nil) else { break }
            totalCanvasPixels += canvasPixels
            var ms = 0.0
            if let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
               let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                let d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
                ms = d * 1000.0
            }
            index += 1
            // Like browsers: frames of 10 ms or less show for 100 ms.
            t += ms <= 10.0 ? 0.1 : ms / 1000.0
            guard var img = straight(cg) else { break }
            if img.width != nw || img.height != nh { img = resize(img, nw, nh) }
            applyAdjust(&img, adj)
            guard let pm = premultiplied(img) else { return nil }
            frames.append(pm)
            ends.append(t)
        }
        return frames.count > 1 ? Anim(frames: frames, ends: ends) : nil
    }

    /// The decoded animation of GIF bytes, once per bytes and adjustments.
    static func anim(_ bytes: [UInt8], _ adj: PictureAdjust) -> Anim? {
        guard bytes.starts(with: Array("GIF8".utf8)) else { return nil }
        let key = AnimKey(addr: address(bytes), adjust: adjustKey(adj))
        if let hit = cache.withLock({ $0.anims[key] }) { return hit.anim }
        let a = decodeAnim(bytes, adj)
        cache.withLock { c in
            let held = c.anims.values.reduce(0) { $0 + ($1.anim?.bytes ?? 0) }
            if held + (a?.bytes ?? 0) > gifCacheBudget || c.anims.count >= 64 { c.anims.removeAll() }
            c.anims[key] = (bytes, a)
        }
        return a
    }

    /// For an animated GIF: the frame showing `t` seconds into its (looping) play and the seconds until
    /// the next frame. Nil for anything else.
    public static func gifFrame(_ bytes: [UInt8], _ adj: PictureAdjust, _ t: Double) -> (Int, Double)? {
        anim(bytes, adj).map { $0.at(t) }
    }

    /// The frame of an animated GIF at `t` seconds.
    public static func gifImage(_ bytes: [UInt8], _ adj: PictureAdjust, _ t: Double) -> CGImage? {
        guard let a = anim(bytes, adj) else { return nil }
        return a.frames.at(a.at(t).0)
    }

    // MARK: Adjustments

    static func applyAdjust(_ img: inout StraightImage, _ a: PictureAdjust) {
        let sat = a.saturation ?? 1.0
        if a.brightness == 0.0 && a.contrast == 0.0 && sat == 1.0 && !a.grayscale && a.clearColor == nil
            && a.duotone == nil && a.bilevel == nil && !a.alphaInv {
            return
        }
        let duo = duotoneRGB(a)
        let b = a.brightness.clamped(-1.0, 1.0) * 255.0
        let c = a.contrast.clamped(-1.0, 1.0)
        let cf = c >= 0.0 ? 1.0 / (1.0 - c * 0.99) : 1.0 + c
        var i = 0
        while i + 3 < img.pixels.count {
            defer { i += 4 }
            let (p0, p1, p2) = (img.pixels[i], img.pixels[i + 1], img.pixels[i + 2])
            if let cc = a.clearColor, Swift.abs(Int(p0) - Int(cc.r)) < 8, Swift.abs(Int(p1) - Int(cc.g)) < 8, Swift.abs(Int(p2) - Int(cc.b)) < 8 {
                img.pixels[i + 3] = 0
                continue
            }
            var rgb = [Double(p0), Double(p1), Double(p2)]
            let y = luma(rgb)
            let s = a.grayscale ? 0.0 : sat
            for k in 0 ..< 3 {
                rgb[k] = y + (rgb[k] - y) * s
                // Measured on PowerPoint's export of grey ramps: contrast scales about mid-grey by `cf`,
                // and brightness adds b · 255 scaled by (1 + cf) / 2 (half before the contrast stretch,
                // half after): +40% bright, +40% contrast maps 0 to 54.
                rgb[k] = (rgb[k] - 127.5) * cf + 127.5 + b * (1.0 + cf) / 2.0
            }
            // Duotone: the pixel's luminance picks a colour between the dark and the light one.
            if let (d, l) = duo {
                let t = (luma(rgb) / 255.0).clamped(0.0, 1.0)
                rgb = [Double(d.r) + (Double(l.r) - Double(d.r)) * t, Double(d.g) + (Double(l.g) - Double(d.g)) * t,
                       Double(d.b) + (Double(l.b) - Double(d.b)) * t]
            }
            // Black and white: white where the luminance reaches the threshold.
            if let t = a.bilevel {
                let v = luma(rgb) >= t * 255.0 ? 255.0 : 0.0
                rgb = [v, v, v]
            }
            for k in 0 ..< 3 { img.pixels[i + k] = UInt8(rustCast: rgb[k].rounded().clamped(0.0, 255.0)) }
            if a.alphaInv { img.pixels[i + 3] = 255 - img.pixels[i + 3] }
        }
    }

    /// Luminance as PowerPoint weighs it for grayscale, black-and-white and duotone pictures (measured:
    /// Rec. 709 weights on the stored values; pure red greys to 54, green to 182).
    static func luma(_ rgb: [Double]) -> Double {
        0.2126 * (rgb.at(0) ?? 0) + 0.7152 * (rgb.at(1) ?? 0) + 0.0722 * (rgb.at(2) ?? 0)
    }
}
