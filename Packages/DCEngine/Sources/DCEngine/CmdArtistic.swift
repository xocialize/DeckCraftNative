// DCEngine — the `artistic` command module: Picture Format ▸ Artistic Effects, a picture redrawn as a pencil
// sketch, blurred, grainy…
//
// The effect is applied to the pixels and the result becomes the picture, as PowerPoint does; the original
// is kept (`PictureFill.artistic`) so the effect can be changed or removed, and both are saved
// (`a14:imgLayer`). The effects approximate PowerPoint's look.
// Port of deckcraft crates/engine/src/cmd/artistic.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors), with the `image` crate's Gaussian blur (`imageops::blur`, its f32 separable filter in
// `imageops/filter_1d.rs`) and `thumbnail` ported from image 0.25.10 (MIT OR Apache-2.0).
//
// The processed pixels are stored in the document, so the pixel algorithm is a port, not Core Image: the
// same picture gives the same pixels as deckcraft. Only the PNG's compressed stream differs.
import CoreGraphics
import DCCore
import DCModel
import DCRender
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ArtisticCommands {
    /// The effects offered: `a14` element name and label.
    public static let effects: [(String, String)] = [
        ("artisticBlur", "Blur"),
        ("artisticPencilGrayscale", "Pencil Grayscale"),
        ("artisticLineDrawing", "Line Drawing"),
        ("artisticFilmGrain", "Film Grain"),
        ("artisticCutout", "Cutout"),
        ("artisticGlowEdges", "Glow Edges"),
        ("artisticPhotocopy", "Photocopy"),
    ]

    public static func specs() -> [CommandSpec] {
        [
            .cmd("picture.artisticEffect", "Artistic Effects", ["Picture Format", "Adjust"], nil, "{effect: none|artisticBlur|artisticPencilGrayscale|artisticLineDrawing|artisticFilmGrain|artisticCutout|artisticGlowEdges|artisticPhotocopy, ids?}", Cmd.hasSelection, artisticEffect),
        ]
    }

    /// Largest side processed; bigger pictures are scaled down first.
    static let maxSide = 3000

    /// An image of `channels` interleaved 8-bit channels (`GrayImage`, `RgbaImage`).
    public struct Pixels: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var channels: Int
        public var data: [UInt8]

        public init(width: Int, height: Int, channels: Int, data: [UInt8]) {
            self.width = width
            self.height = height
            self.channels = channels
            self.data = data
        }

        init(_ width: Int, _ height: Int, _ channels: Int) {
            self.init(width: width, height: height, channels: channels, data: [UInt8](repeating: 0, count: width * height * channels))
        }

        @inline(__always) func at(_ x: Int, _ y: Int, _ c: Int) -> UInt8 { data[(y * width + x) * channels + c] }
    }

    static func luma(_ img: Pixels, _ i: Int) -> Float {
        0.299 * Float(img.data[i]) + 0.587 * Float(img.data[i + 1]) + 0.114 * Float(img.data[i + 2])
    }

    static func gray(_ img: Pixels) -> Pixels {
        var g = Pixels(img.width, img.height, 1)
        for k in 0 ..< img.width * img.height { g.data[k] = UInt8(rustCast: luma(img, k * 4).rounded().clamped(0, 255)) }
        return g
    }

    /// Sobel edge strength, 0–255.
    static func edges(_ g: Pixels) -> Pixels {
        let (w, h) = (g.width, g.height)
        func at(_ x: Int, _ y: Int) -> Float { Float(g.data[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]) }
        var out = Pixels(w, h, 1)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let gx = at(x + 1, y - 1) + 2.0 * at(x + 1, y) + at(x + 1, y + 1) - at(x - 1, y - 1) - 2.0 * at(x - 1, y) - at(x - 1, y + 1)
                let gy = at(x - 1, y + 1) + 2.0 * at(x, y + 1) + at(x + 1, y + 1) - at(x - 1, y - 1) - 2.0 * at(x, y - 1) - at(x + 1, y - 1)
                out.data[y * w + x] = UInt8(rustCast: ((gx * gx + gy * gy).squareRoot() / 4.0).clamped(0, 255))
            }
        }
        return out
    }

    // MARK: The image crate's Gaussian blur

    /// `get_gaussian_kernel_1d`.
    static func gaussianKernel(_ width: Int, _ sigma: Float) -> [Float] {
        var sumNorm: Float = 0
        var kernel = [Float](repeating: 0, count: width)
        let scale = 1 / ((2 * Float.pi).squareRoot() * sigma)
        let mean = Float(width / 2)
        for x in 0 ..< width {
            let t = (Float(x) - mean) / sigma
            // `f32::powf(t, 2.0)`: LLVM folds the square to `t * t`.
            let w = expf(-0.5 * (t * t)) * scale
            kernel[x] = w
            sumNorm += w
        }
        if sumNorm != 0 {
            let sumScale = 1 / sumNorm
            for i in kernel.indices { kernel[i] = kernel[i] * sumScale }
        }
        return kernel
    }

    /// `GaussianBlurParameters::kernel_size_from_sigma`.
    static func kernelSize(_ sigma: Float) -> Int {
        let possible = Int(UInt32(rustCast: max((((sigma - 0.8) / 0.3) + 1) * 2 + 1, 3)))
        return possible % 2 == 0 ? possible + 1 : possible
    }

    /// `prepare_symmetric_kernel`: zero weights trimmed from both ends while both ends are zero.
    static func trimmedKernel(_ k: [Float]) -> [Float] {
        var k = k
        while k.count > 2, k.first == 0, k.last == 0 {
            k.removeFirst()
            k.removeLast()
        }
        return k
    }

    /// `imageops::blur`: a separable Gaussian over f32 copies of the channels, rounded back to the nearest.
    static func blur(_ img: Pixels, _ sigmaIn: Float) -> Pixels {
        let sigma = sigmaIn == 0 ? 0.8 : sigmaIn
        let (w, h, n) = (img.width, img.height, img.channels)
        guard w > 0, h > 0, sigma.isNormal, sigma > 0 else { return img }
        let size = kernelSize(sigma)
        let kernel = trimmedKernel(gaussianKernel(size, sigma))
        let len = kernel.count
        let half = len / 2
        let hc = kernel[half]
        let full = w * n
        // Horizontal pass, each row padded by clamping (`make_arena_row`, `filter_symmetric_row`).
        let padW = max(half, 1)
        var rows = [Float](repeating: 0, count: w * h * n)
        var arena = [Float](repeating: 0, count: (w + 2 * padW) * n)
        for y in 0 ..< h {
            let src = y * full
            for x in 0 ..< w + 2 * padW {
                let sx = min(max(x - padW, 0), w - 1)
                for c in 0 ..< n { arena[x * n + c] = Float(img.data[src + sx * n + c]) }
            }
            for j in 0 ..< full {
                var k0 = arena[j + half * n] * hc
                for i in 0 ..< half {
                    k0 = k0.addingProduct(arena[j + i * n] + arena[j + (len - i - 1) * n], kernel[i])
                }
                rows[src + j] = k0
            }
        }
        // Vertical pass over the rows, clamped at the top and bottom (`filter_symmetric_column`).
        var out = Pixels(w, h, n)
        for y in 0 ..< h {
            func row(_ k: Int) -> Int { min(max(y - half + k, 0), h - 1) * full }
            let centre = row(half)
            for j in 0 ..< full {
                var k0 = rows[centre + j] * hc
                for i in 0 ..< half {
                    k0 = k0.addingProduct(rows[row(i) + j] + rows[row(len - i - 1) + j], kernel[i])
                }
                // `FloatNearest`: rounded half away from zero.
                out.data[y * full + j] = UInt8(rustCast: k0.rounded().clamped(0, 255))
            }
        }
        return out
    }

    // MARK: The image crate's thumbnail

    /// `resize_dimensions(width, height, nwidth, nheight, false)`.
    static func resizeDimensions(_ width: Int, _ height: Int, _ nwidth: Int, _ nheight: Int) -> (Int, Int) {
        let wratio = Double(nwidth) / Double(width)
        let hratio = Double(nheight) / Double(height)
        let ratio = wratio.rustMin(hratio)
        let nw = max(UInt64(rustCast: (Double(width) * ratio).rounded()), 1)
        let nh = max(UInt64(rustCast: (Double(height) * ratio).rounded()), 1)
        return (Int(min(nw, UInt64(UInt32.max))), Int(min(nh, UInt64(UInt32.max))))
    }

    /// `imageops::thumbnail` for a downscale: each target pixel is the rounded mean of the source pixels
    /// its window covers.
    static func thumbnail(_ img: Pixels, _ nw: Int, _ nh: Int) -> Pixels {
        var out = Pixels(nw, nh, img.channels)
        let (width, height) = (img.width, img.height)
        guard width > 0, height > 0, nw > 0, nh > 0 else { return out }
        let xRatio = Float(width) / Float(nw)
        let yRatio = Float(height) / Float(nh)
        for oy in 0 ..< nh {
            let bottomf = Float(oy) * yRatio
            let topf = bottomf + yRatio
            let bottom = min(max(Int(UInt32(rustCast: bottomf.rounded(.up))), 0), height - 1)
            let top = min(max(Int(UInt32(rustCast: topf.rounded(.up))), bottom), height)
            for ox in 0 ..< nw {
                let leftf = Float(ox) * xRatio
                let rightf = leftf + xRatio
                let left = min(max(Int(UInt32(rustCast: leftf.rounded(.up))), 0), width - 1)
                let right = min(max(Int(UInt32(rustCast: rightf.rounded(.up))), left), width)
                // A downscale always has a full block; a degenerate one takes its corner pixel.
                let (l, r, b, t) = (left, max(right, left + 1), bottom, max(top, bottom + 1))
                let count = UInt32((r - l) * (t - b))
                for c in 0 ..< img.channels {
                    var sum: UInt32 = 0
                    for y in b ..< min(t, height) {
                        for x in l ..< min(r, width) { sum &+= UInt32(img.at(x, y, c)) }
                    }
                    out.data[(oy * nw + ox) * img.channels + c] = UInt8(clamping: (sum &+ count / 2) / max(count, 1))
                }
            }
        }
        return out
    }

    // MARK: Effects

    /// Applies `effect` to `img` (RGBA, alpha kept).
    public static func apply(_ effect: String, _ img: Pixels) -> Pixels? {
        let (w, h) = (img.width, img.height)
        let scale = Float(UInt32(truncatingIfNeeded: w &* w &+ h &* h)).squareRoot() / 1000
        func alpha(_ k: Int) -> UInt8 { img.data[k * 4 + 3] }
        switch effect {
        case "artisticBlur":
            return blur(img, max(6 * scale, 1))
        case "artisticPencilGrayscale", "artisticLineDrawing", "artisticPhotocopy":
            let soft = blur(gray(img), max(0.8 * scale, 0.5))
            let e = edges(soft)
            var out = Pixels(w, h, 4)
            for k in 0 ..< w * h {
                let ev = Float(e.data[k])
                let gv = Float(soft.data[k])
                let v: Float = switch effect {
                case "artisticPencilGrayscale": 255 - ev * 2 - (255 - gv) * 0.25
                case "artisticLineDrawing": ev > 28 ? 255 - (ev - 28) * 3 : 255
                default: ev > 40 || gv < 70 ? 0 : 255
                }
                let b = UInt8(rustCast: v.clamped(0, 255))
                (out.data[k * 4], out.data[k * 4 + 1], out.data[k * 4 + 2], out.data[k * 4 + 3]) = (b, b, b, alpha(k))
            }
            return out
        case "artisticFilmGrain":
            // Deterministic noise, so the same picture gives the same grain.
            var seed: UInt32 = 0x9E37_79B9
            var out = Pixels(w, h, 4)
            for k in 0 ..< w * h {
                seed ^= seed << 13
                seed ^= seed >> 17
                seed ^= seed << 5
                let n = Float(seed % 61) - 30
                func c(_ v: UInt8) -> UInt8 { UInt8(rustCast: ((Float(v) - 128) * 1.1 + 128 + n).clamped(0, 255)) }
                let i = k * 4
                (out.data[i], out.data[i + 1], out.data[i + 2], out.data[i + 3]) = (c(img.data[i]), c(img.data[i + 1]), c(img.data[i + 2]), img.data[i + 3])
            }
            return out
        case "artisticCutout":
            let soft = blur(img, max(1.5 * scale, 0.5))
            var out = Pixels(w, h, 4)
            func q(_ v: UInt8) -> UInt8 { UInt8(rustCast: (Float(v) / 255 * 3).rounded() / 3 * 255) }
            for k in 0 ..< w * h {
                let i = k * 4
                (out.data[i], out.data[i + 1], out.data[i + 2], out.data[i + 3]) = (q(soft.data[i]), q(soft.data[i + 1]), q(soft.data[i + 2]), alpha(k))
            }
            return out
        case "artisticGlowEdges":
            let e = edges(gray(img))
            var out = Pixels(w, h, 4)
            for k in 0 ..< w * h {
                let kk = (Float(e.data[k]) / 255 * 2.5).rustMinF(1)
                func c(_ v: UInt8) -> UInt8 { UInt8(rustCast: (Float(v) * kk + 255 * kk * 0.3).clamped(0, 255)) }
                let i = k * 4
                (out.data[i], out.data[i + 1], out.data[i + 2], out.data[i + 3]) = (c(img.data[i]), c(img.data[i + 1]), c(img.data[i + 2]), img.data[i + 3])
            }
            return out
        default:
            return nil
        }
    }

    /// The raster formats the `image` crate decodes for deckcraft; WMF and EMF aren't among them.
    static func isMetafile(_ b: [UInt8]) -> Bool {
        if b.count >= 4 && b[0] == 0xD7 && b[1] == 0xCD && b[2] == 0xC6 && b[3] == 0x9A { return true }
        if b.count >= 4 && (b[0] == 1 || b[0] == 2) && b[1] == 0 && b[2] == 9 && b[3] == 0 { return true }
        if b.count >= 44 && b[0] == 1 && b[1] == 0 && b[2] == 0 && b[3] == 0 && Array(b[40 ..< 44]) == Array(" EMF".utf8) { return true }
        return false
    }

    /// Decodes `data`, applies `effect` and encodes a PNG.
    static func process(_ effect: String, _ data: [UInt8]) throws -> [UInt8] {
        guard !isMetafile(data), let decoded = Images.decode(data) else {
            throw Cmd.bad("picture.artisticEffect", "this picture's format can't be processed")
        }
        var img = Pixels(width: decoded.width, height: decoded.height, channels: 4, data: decoded.pixels)
        if max(img.width, img.height) > maxSide {
            let (nw, nh) = resizeDimensions(img.width, img.height, maxSide, maxSide)
            img = thumbnail(img, nw, nh)
        }
        guard let out = apply(effect, img) else { throw Cmd.bad("picture.artisticEffect", "unknown effect") }
        let png = pngBytes(out)
        if png.isEmpty { throw Cmd.bad("picture.artisticEffect", "the processed picture couldn't be stored") }
        return png
    }

    /// A PNG of straight RGBA pixels, ImageIO's stream.
    static func pngBytes(_ img: Pixels) -> [UInt8] {
        guard img.width > 0, img.height > 0, img.channels == 4, img.data.count == img.width * img.height * 4,
              let provider = CGDataProvider(data: Data(img.data) as CFData),
              let cg = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return [] }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return [] }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return [] }
        return [UInt8](data as Data)
    }

    @Sendable static func artisticEffect(_ s: Session, _ p: JSON) throws -> JSON {
        let effect: String?
        switch Cmd.strParam(p, "effect") {
        case "none"?: effect = nil
        case let e? where effects.contains(where: { rustEqual($0.0, e) }): effect = e
        default: throw Cmd.bad("picture.artisticEffect", "`effect` is none or one of artisticBlur, artisticPencilGrayscale, …")
        }
        let ids = try Cmd.targets(s, p)
        let st = try s.doc()
        // (shape, original picture, its bytes and name)
        var work: [(ShapeId, MediaId, ([UInt8], String)?)] = []
        for id in ids {
            guard case .picture(let fill)? = st.shape(id)?.kind else { continue }
            let original = fill.artistic?.original ?? fill.media
            let item = st.doc.media(original).map { ($0.data, $0.name) }
            work.append((id, original, item))
        }
        if work.isEmpty { throw Cmd.bad("picture.artisticEffect", "select a picture") }
        var results: [(ShapeId, MediaId, (String, [UInt8])?)] = []
        for (id, original, item) in work {
            var processed: (String, [UInt8])?
            if let e = effect {
                guard let (data, name) = item else { throw Cmd.bad("picture.artisticEffect", "the picture's data is missing") }
                let stem = name.lastIndex(of: ".").map { String(name[..<$0]) } ?? name
                processed = ("\(stem)-\(e).png", try process(e, data))
            }
            results.append((id, original, processed))
        }
        try s.edit { doc, sel in
            var set: [(ShapeId, MediaId, MediaId?)] = []
            for (id, original, processed) in results {
                var m: MediaId?
                if let (name, png) = processed {
                    guard let added = doc.addMedia(name, "image/png", png) else { throw Cmd.bad("picture.artisticEffect", Cmd.noIdSpace) }
                    m = added
                }
                set.append((id, original, m))
            }
            try withShapes(&doc, sel, missing: Cmd.bad("picture.artisticEffect", "no slide")) { list in
                for (id, original, m) in set {
                    _ = withShape(&list, id) { sh in
                        guard case .picture(var fill) = sh.kind else { return }
                        if let m, let e = effect {
                            fill.media = m
                            fill.artistic = Artistic(effect: e, original: original)
                        } else {
                            fill.media = original
                            fill.artistic = nil
                        }
                        sh.kind = .picture(fill: fill)
                    }
                }
            }
        }
        return ["effect": .opt(effect)]
    }
}

extension Float {
    /// Rust's `f32::min` (a NaN operand is ignored).
    fileprivate func rustMinF(_ o: Float) -> Float {
        if isNaN { return o }
        if o.isNaN { return self }
        return self < o ? self : o
    }
}
