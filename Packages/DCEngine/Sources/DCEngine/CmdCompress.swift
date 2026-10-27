// DCEngine — the `compress` command module: Picture Format ▸ Adjust ▸ Compress Pictures. Pictures are
// downsampled to a target resolution for the size they are shown at, and optionally lose their cropped-away
// areas.
// Port of deckcraft crates/engine/src/cmd/compress.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// deckcraft decodes, crops, resamples (Lanczos3) and encodes with the `image` crate; here ImageIO decodes and
// encodes and vImage resamples (its high-quality Lanczos kernel). The pixel sizes, crops and the choice of
// JPEG or PNG are deckcraft's; the bytes differ (see PORT-NOTES, Divergences).
import Accelerate
import CoreGraphics
import DCCore
import DCModel
import DCRender
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CompressCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd(
                "picture.compress",
                "Compress Pictures",
                ["Picture Format", "Adjust"],
                nil,
                "{ppi?: 330|220|150|96 (default 220), deleteCropped?: bool (default true), all?: bool (every picture in the presentation; default the selected pictures), ids?} → {pictures, before, after}",
                Cmd.hasDoc,
                compress
            ),
        ]
    }

    /// A picture compressed for one shape: new bytes, content type and the crop it now needs.
    struct Packed {
        var bytes: [UInt8]
        var contentType: String
        var crop: [Double]
    }

    /// Whether `crop` cuts something away (and only cuts: negative values pad, and are kept).
    static func realCrop(_ c: [Double]) -> Bool {
        guard c.count == 4 else { return false }
        return c.allSatisfy { (0.0 ..< 1.0).contains($0) } && c.contains { $0 > 0.0 } && c[0] + c[2] < 1.0 && c[1] + c[3] < 1.0
    }

    /// Largest picture decoded for compression, in pixels (a 61 MP camera frame fits); bigger ones are left
    /// as they are.
    static let maxPixels: UInt64 = 64_000_000

    /// The raster formats compression re-encodes (the `image` crate's `guess_format`, by signature).
    enum Format { case png, jpeg, bmp, tiff, webp }

    static func guessFormat(_ data: [UInt8]) -> Format? {
        switch InsertCommands.contentType("", data) {
        case "image/png": .png
        case "image/jpeg": .jpeg
        case "image/bmp": .bmp
        case "image/tiff": .tiff
        case "image/webp": .webp
        default: nil
        }
    }

    /// Decode `data` within `maxPixels`: the size is read from the header first, so a picture claiming to be
    /// huge is never decoded.
    static func decode(_ data: [UInt8]) -> StraightImage? {
        guard let (w, h) = InsertCommands.pixelSize(data), w > 0, h > 0, UInt64(w) * UInt64(h) <= maxPixels else { return nil }
        guard let img = Images.decode(data), img.width == w, img.height == h else { return nil }
        return img
    }

    /// `crop_imm`: the part of `img` at (x, y) of size w × h, clipped to the image.
    static func crop(_ img: StraightImage, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> StraightImage {
        let x = min(x, img.width), y = min(y, img.height)
        let w = min(w, img.width - x), h = min(h, img.height - y)
        var px = [UInt8](repeating: 0, count: max(w, 0) * max(h, 0) * 4)
        for row in 0 ..< max(h, 0) {
            let src = ((y + row) * img.width + x) * 4
            let dst = row * w * 4
            px.replaceSubrange(dst ..< dst + w * 4, with: img.pixels[src ..< src + w * 4])
        }
        return StraightImage(width: max(w, 0), height: max(h, 0), pixels: px)
    }

    /// Resample straight RGBA to `w` × `h` with vImage's high-quality (Lanczos) kernel.
    static func resize(_ img: StraightImage, _ w: Int, _ h: Int) -> StraightImage? {
        guard img.width > 0, img.height > 0, w > 0, h > 0 else { return nil }
        var src = img.pixels
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let err = src.withUnsafeMutableBytes { sp -> vImage_Error in
            out.withUnsafeMutableBytes { dp -> vImage_Error in
                guard let s = sp.baseAddress, let d = dp.baseAddress else { return kvImageNullPointerArgument }
                var sb = vImage_Buffer(data: s, height: vImagePixelCount(img.height), width: vImagePixelCount(img.width), rowBytes: img.width * 4)
                var db = vImage_Buffer(data: d, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                return vImageScale_ARGB8888(&sb, &db, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return err == kvImageNoError ? StraightImage(width: w, height: h, pixels: out) : nil
    }

    static func encode(_ img: StraightImage, jpeg: Bool) -> [UInt8]? {
        guard img.width > 0, img.height > 0, let provider = CGDataProvider(data: Data(img.pixels) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: (jpeg ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.last).rawValue)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                               space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let data = NSMutableData()
        let type = jpeg ? UTType.jpeg : UTType.png
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](data as Data)
    }

    /// Compress `data` for a picture shown `wPt` × `hPt` with `crop`, at `ppi`. Nil when the format isn't a
    /// raster we re-encode (SVG, EMF, GIF…) or nothing would get smaller.
    static func pack(_ data: [UInt8], _ crop: [Double], _ wPt: Double, _ hPt: Double, _ ppi: Double, _ deleteCropped: Bool) -> Packed? {
        guard let format = guessFormat(data), var img = decode(data) else { return nil }
        let crop = crop.count == 4 ? crop : [0, 0, 0, 0]
        let iw = Double(img.width), ih = Double(img.height)
        if iw < 1.0 || ih < 1.0 { return nil }
        let cut = deleteCropped && realCrop(crop)
        var newCrop = crop
        // The share of the image that is visible across and down.
        var fx = (1.0 - crop[0] - crop[2]).rustMax(0.01)
        var fy = (1.0 - crop[1] - crop[3]).rustMax(0.01)
        if cut {
            let x = Int(rustCast: (crop[0] * iw).rounded(.down))
            let y = Int(rustCast: (crop[1] * ih).rounded(.down))
            let w = min(max(Int(rustCast: (fx * iw).rounded()), 1), img.width - min(x, img.width - 1))
            let h = min(max(Int(rustCast: (fy * ih).rounded()), 1), img.height - min(y, img.height - 1))
            img = self.crop(img, x, y, w, h)
            newCrop = [0, 0, 0, 0]
            (fx, fy) = (1.0, 1.0)
        } else if !crop.allSatisfy(\.isFinite) {
            return nil
        }
        // Pixels needed for the whole (possibly still cropped) image at `ppi`.
        let needW = (abs(wPt) / 72.0 * ppi / fx).rounded(.up).rustMax(1.0)
        let needH = (abs(hPt) / 72.0 * ppi / fy).rounded(.up).rustMax(1.0)
        let k = (needW / Double(img.width)).rustMax(needH / Double(img.height))
        let resized = k < 1.0
        if resized {
            let w = max(Int(rustCast: (Double(img.width) * k).rounded()), 1)
            let h = max(Int(rustCast: (Double(img.height) * k).rounded()), 1)
            guard let r = resize(img, w, h) else { return nil }
            img = r
        }
        if !resized && !cut { return nil }
        var alpha = false
        var i = 3
        while i < img.pixels.count {
            if img.pixels[i] < 255 {
                alpha = true
                break
            }
            i += 4
        }
        let jpeg = format == .jpeg && !alpha
        guard let bytes = encode(img, jpeg: jpeg) else { return nil }
        // Never make a picture bigger just to resample it; deleting a crop is worth it regardless.
        if bytes.count >= data.count && !cut { return nil }
        return Packed(bytes: bytes, contentType: jpeg ? "image/jpeg" : "image/png", crop: newCrop)
    }

    private struct CacheKey: Hashable {
        var media: UInt32
        var crop: [UInt64]
        var w: UInt64
        var h: UInt64
    }

    @Sendable static func compress(_ s: Session, _ p: JSON) throws -> JSON {
        let ppi = Cmd.f64Param(p, "ppi") ?? 220.0
        if !ppi.isFinite || !(36.0 ... 1200.0).contains(ppi) {
            throw Cmd.bad("picture.compress", "`ppi` must be between 36 and 1200 (PowerPoint offers 330, 220, 150 and 96)")
        }
        let deleteCropped = Cmd.boolOr(p, "deleteCropped", true)
        let all = Cmd.boolOr(p, "all", false)
        let ids: Set<ShapeId> = all ? [] : Set(try Cmd.targets(s, p))
        if !all && ids.isEmpty { throw Cmd.bad("picture.compress", "select a picture, or pass all: true") }
        let current = try s.doc().selection.slide
        return try s.edit { doc, _ in
            var before = 0
            var after = 0
            var count = 0
            var changed: [MediaId] = []
            // The same picture at the same size and crop compresses once.
            var cache: [CacheKey: (MediaId, [Double], Int)?] = [:]
            let range: [Int] = all ? Array(doc.slides.indices) : [current]
            for i in range {
                guard i >= 0, i < doc.slides.count else { continue }
                var slide = doc.slides[i]
                var touched = false
                func visit(_ shapes: inout [Shape], _ depth: Int) throws {
                    if depth > 64 { return }
                    for k in shapes.indices {
                        if case .picture(var fill) = shapes[k].kind, all || ids.contains(shapes[k].id) {
                            let (w, h) = shapes[k].xfrm.map { ($0.w, $0.h) } ?? (0.0, 0.0)
                            let media = fill.media
                            let crop = fill.crop
                            let key = CacheKey(media: media.rawValue, crop: crop.map(\.bitPattern), w: w.bitPattern, h: h.bitPattern)
                            let hit: (MediaId, [Double], Int)?
                            if let v = cache[key] {
                                hit = v
                            } else {
                                var v: (MediaId, [Double], Int)?
                                if let m = doc.media(media), !m.data.isEmpty, let pk = pack(m.data, crop, w, h, ppi, deleteCropped) {
                                    let old = m.data.count
                                    before += old
                                    after += pk.bytes.count
                                    let stem = RustPath.fileStem(m.name) ?? m.name
                                    let ext = pk.contentType == "image/jpeg" ? "jpg" : "png"
                                    guard let id = doc.addMedia("\(stem).\(ext)", pk.contentType, pk.bytes) else {
                                        throw Cmd.bad("picture.compress", Cmd.noIdSpace)
                                    }
                                    v = (id, pk.crop, old)
                                }
                                cache[key] = .some(v)
                                hit = v
                            }
                            if let (id, newCrop, _) = hit {
                                changed.append(media)
                                fill.media = id
                                fill.crop = newCrop
                                shapes[k].kind = .picture(fill: fill)
                                count += 1
                                touched = true
                            }
                        } else if shapes[k].isGroup {
                            try shapes[k].mutateChildren { try visit(&$0, depth + 1) }
                        }
                    }
                }
                try visit(&slide.shapes, 0)
                if touched { doc.slides[i] = slide }
            }
            // Drop the originals nothing uses any more, so the saved file actually shrinks.
            if !changed.isEmpty {
                // Typed walk of every reference (artistic originals, fills, posters, sounds, fonts…).
                let used = Set(MediaRefs.presentationMedia(doc))
                doc.media.removeAll { changed.contains($0.id) && !used.contains($0.id) }
            }
            return ["pictures": .integer(count), "before": .integer(before), "after": .integer(after), "ppi": .num(ppi)]
        }
    }
}
