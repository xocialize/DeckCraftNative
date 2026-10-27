// DCEngine — the `background` command module: Picture Format ▸ Remove Background, a classical matte with no
// model. The background is what the picture's edges reach through similar colours: a flood fill from every
// edge pixel, each step close to the pixel before it (gradients and soft shadows) and to the edge colour it
// started from (so it can't leak into the subject). It turns transparent, with a one-pixel soft edge.
// Port of deckcraft crates/engine/src/cmd/background.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). Pictures are decoded and the PNG written with ImageIO instead of the `image` crate: the
// matte's pixels are the same, the PNG's compressed bytes are not.
import CoreGraphics
import DCCore
import DCModel
import DCRender
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum BackgroundCommands {
    /// Larger pictures are refused rather than matted slowly (16 megapixels).
    static let maxPixels: UInt64 = 16_000_000

    public static func specs() -> [CommandSpec] {
        [
            .cmd(
                "picture.removeBackground",
                "Remove Background",
                ["Picture Format", "Adjust"],
                nil,
                "{tolerance?: 0..100 (how different a colour may be from the edge's, default 20), ids?}",
                Cmd.hasSelection,
                removeBackground
            ),
        ]
    }

    static func dist(_ a: (UInt8, UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8, UInt8)) -> Double {
        let d0 = Double(a.0) - Double(b.0)
        let d1 = Double(a.1) - Double(b.1)
        let d2 = Double(a.2) - Double(b.2)
        return (d0 * d0 + d1 * d1 + d2 * d2).squareRoot()
    }

    /// Make the background of `img` (straight RGBA8) transparent. `tolerance` is 0–100. Returns how many
    /// pixels became transparent.
    public static func matte(_ img: inout StraightImage, _ tolerance: Double) -> Int {
        let (w, h) = (img.width, img.height)
        if w <= 0 || h <= 0 || img.pixels.count < w * h * 4 { return 0 }
        // Distances run 0–441 (black to white); the step limit follows gradients, the seed limit keeps the
        // fill on the edge's colour.
        let seedTol = tolerance.clamped(0.0, 100.0) * 4.41
        let stepTol = (seedTol * 0.35).rustMax(6.0)
        let pixels = img.pixels
        func px(_ i: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            (pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3])
        }
        // false: subject, true: background; the seed colour each background pixel was reached from.
        var bg = [Bool](repeating: false, count: w * h)
        var seed = [(UInt8, UInt8, UInt8, UInt8)](repeating: (0, 0, 0, 0), count: w * h)
        var queue: [Int] = []
        var head = 0
        func pushEdge(_ i: Int) {
            guard i >= 0, i < bg.count, !bg[i] else { return }
            bg[i] = true
            seed[i] = px(i)
            queue.append(i)
        }
        for x in 0 ..< w {
            pushEdge(x)
            pushEdge((h - 1) * w + x)
        }
        for y in 0 ..< h {
            pushEdge(y * w)
            pushEdge(y * w + w - 1)
        }
        while head < queue.count {
            let i = queue[head]
            head += 1
            let (x, y) = (i % w, i / w)
            let here = px(i)
            let from = seed[i]
            var near: [Int] = []
            if x > 0 { near.append(i - 1) }
            if x + 1 < w { near.append(i + 1) }
            if y > 0 { near.append(i - w) }
            if y + 1 < h { near.append(i + w) }
            for j in near {
                if bg[j] { continue }
                let c = px(j)
                // Transparent pixels are background already.
                if c.3 < 16 || (dist(c, here) <= stepTol && dist(c, from) <= seedTol) {
                    bg[j] = true
                    seed[j] = from
                    queue.append(j)
                }
            }
        }
        // A background edge that is the subject's colour throughout (the subject touches the edge on every
        // side) is no background: leave such a picture alone.
        let n = bg.reduce(0) { $0 + ($1 ? 1 : 0) }
        if n == w * h { return 0 }
        func isBg(_ x: Int, _ y: Int) -> Bool { bg[y * w + x] }
        var soft: [(Int, Int)] = []
        for y in 0 ..< h {
            for x in 0 ..< w {
                if isBg(x, y) { continue }
                let touching = (x > 0 && isBg(x - 1, y)) || (x + 1 < w && isBg(x + 1, y)) || (y > 0 && isBg(x, y - 1)) || (y + 1 < h && isBg(x, y + 1))
                if touching { soft.append((x, y)) }
            }
        }
        for (i, b) in bg.enumerated() where b {
            img.pixels[i * 4 + 3] = 0
        }
        for (x, y) in soft {
            let k = (y * w + x) * 4 + 3
            img.pixels[k] = UInt8(UInt16(img.pixels[k]) * 2 / 3)
        }
        return n
    }

    /// The pixel size in a picture's header (`ImageReader::into_dimensions`), nil when ImageIO can't read it.
    static func headerSize(_ bytes: [UInt8]) -> (UInt64, UInt64)? {
        guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w >= 0, h >= 0 else { return nil }
        return (UInt64(w), UInt64(h))
    }

    /// A PNG of straight RGBA8 pixels, nil when ImageIO can't write it.
    static func pngBytes(_ img: StraightImage) -> [UInt8]? {
        guard let cg = ImageEncoding.straightImage(img.width, img.height, img.pixels) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](data as Data)
    }

    @Sendable static func removeBackground(_ s: Session, _ p: JSON) throws -> JSON {
        let tolerance = Cmd.f64Or(p, "tolerance", 20.0)
        let ids = try Cmd.targets(s, p)
        var done: [(ShapeId, String, [UInt8])] = []
        let st = try s.doc()
        for id in ids {
            guard let sh = st.shape(id), case .picture(let fill) = sh.kind, let item = st.doc.media(fill.media) else { continue }
            guard let (iw, ih) = headerSize(item.data) else { continue }
            if iw.multipliedReportingOverflow(by: ih).partialValue > maxPixels || iw.multipliedReportingOverflow(by: ih).overflow {
                throw Cmd.bad("picture.removeBackground", "\(iw)×\(ih) pixels is too large; compress the picture first")
            }
            guard var img = Images.decode(item.data) else { continue }
            if matte(&img, tolerance) == 0 { continue }
            guard let png = pngBytes(img) else { continue }
            let stem: Substring = item.name.lastIndex(of: ".").map { item.name[..<$0] } ?? Substring(item.name)
            done.append((id, "\(stem)-no-background.png", png))
        }
        if done.isEmpty {
            throw Cmd.bad("picture.removeBackground", "no background found: select a picture whose edges show its background")
        }
        let n = done.count
        try s.edit { doc, sel in
            var added: [(ShapeId, MediaId)] = []
            for (id, name, png) in done {
                guard let m = doc.addMedia(name, "image/png", png) else { throw Cmd.bad("picture.removeBackground", Cmd.noIdSpace) }
                added.append((id, m))
            }
            try withShapes(&doc, sel, missing: Cmd.bad("picture.removeBackground", "no slide")) { shapes in
                for (id, media) in added {
                    withShape(&shapes, id) { sh in
                        if case .picture(var fill) = sh.kind {
                            fill.media = media
                            sh.kind = .picture(fill: fill)
                        }
                    }
                }
            }
        }
        return ["pictures": .integer(n)]
    }
}
