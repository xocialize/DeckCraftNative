// Shared helpers for the ports of deckcraft crates/pptx/tests/it/*.rs and chart_data_labels.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The Rust modules each carry their own copy
// of these (`png`, `entries`, `rezip`, `round`…); here they're shared.
//
// - The `image` crate's PNGs come from ImageIO. Only their pixels and size matter to the tests.
// - The `zip` crate's reader and writer are DCZip's. `SimpleFileOptions::default()` deflates, as
//   `ZipWriter.add(_:_:compress: true)` does.
// - Strings are searched, sliced and replaced byte-wise, as Rust's `str` methods are.
import CoreGraphics
import DCCore
import DCFormat
import DCGeometry
import DCModel
import DCTestSupport
import DCZip
import Foundation
import ImageIO
import Testing
@testable import DCPPTX

enum IT {
    // MARK: Pictures

    /// `image::RgbImage::from_pixel(w, h, rgb)` as a PNG.
    static func png(_ w: Int, _ h: Int, _ rgb: (UInt8, UInt8, UInt8)) -> [UInt8] {
        pngFrom(w, h) { _, _ in rgb }
    }

    /// `image::RgbImage::from_fn(w, h, f)` as a PNG.
    static func pngFrom(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        guard w > 0, h > 0 else { return [] }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let (r, g, b) = f(x, y)
                let i = (y * w + x) * 4
                px[i] = r
                px[i + 1] = g
                px[i + 2] = b
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let image = CGImage(
                  width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                  decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return [] }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return [] }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return [] }
        return [UInt8](out as Data)
    }

    /// The pixel size of an encoded picture (`image::load_from_memory(…).dimensions()`).
    static func imageSize(_ bytes: [UInt8]) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return (img.width, img.height)
    }

    // MARK: Zip packages

    /// Every entry of a zip, in archive order (`(0..z.len()).map(by_index)`).
    static func entries(_ bytes: [UInt8]) throws -> [(name: String, data: [UInt8])] {
        let z = try ZipReader(bytes)
        return try z.entries.map { ($0.name, try z.read($0, max: 1 << 30)) }
    }

    /// A zip of `files`, in order, each deflated (`SimpleFileOptions::default()`).
    static func zip(_ files: [(name: String, data: [UInt8])]) throws -> [UInt8] {
        var out = ZipWriter()
        for f in files { try out.add(f.name, f.data, compress: true) }
        return try out.finish()
    }

    /// A zip of `files`, each stored (`CompressionMethod::Stored`) when `stored` says so.
    static func zip(_ files: [(name: String, data: [UInt8], stored: Bool)]) throws -> [UInt8] {
        var out = ZipWriter()
        for f in files { try out.add(f.name, f.data, compress: !f.stored) }
        return try out.finish()
    }

    /// The bytes of one part, if the package has it.
    static func part(_ bytes: [UInt8], _ name: String) -> [UInt8]? {
        guard let z = try? ZipReader(bytes), let e = z.find(name) else { return nil }
        return try? z.read(e, max: 1 << 30)
    }

    /// One part as UTF-8 text (lossy), or "" when the package hasn't it.
    static func text(_ bytes: [UInt8], _ name: String) -> String {
        part(bytes, name).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Every part of `bytes`, with `edit` applied to the ones whose name ends `.xml` (the Rust tests'
    /// `rewrite`).
    static func rewriteXML(_ bytes: [UInt8], _ edit: (String, String) -> String) throws -> [UInt8] {
        try zip(entries(bytes).map { e in
            guard e.name.hasSuffix(".xml") else { return e }
            return (e.name, Array(edit(e.name, String(decoding: e.data, as: UTF8.self)).utf8))
        })
    }

    // MARK: Model

    /// `import(export(p))`.
    static func round(_ p: Presentation) throws -> Presentation {
        try PPTX.import(PPTX.export(p))
    }

    /// `Shape { id: alloc_id, name, xfrm: Xfrm::new(x, y, w, h), ..Default::default() }`.
    static func shape(_ p: inout Presentation, _ name: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Shape {
        var s = Shape.default
        s.id = ShapeId(p.allocId() ?? 0)
        s.name = name
        s.xfrm = Xfrm(x, y, w, h)
        return s
    }

    /// A new slide on the Title Only layout with `title` in its first placeholder (the Rust tests'
    /// `new_slide`).
    static func newSlide(_ p: inout Presentation, _ title: String) -> Slide {
        let layout = layoutOfKind(p, .titleOnly) ?? LayoutId.default
        var s = DCModel.newSlide(&p, layout) ?? Slide.default
        if !s.shapes.isEmpty { s.shapes[0].text = TextBody.fromText(title) }
        return s
    }

    /// The first shape named `name` anywhere in `shapes`, groups included (`walk`).
    static func find(_ shapes: [Shape], _ name: String) -> Shape? {
        var found: Shape?
        walk(shapes) { x, _ in
            if found == nil, bytesEqual(x.name, name) { found = x }
        }
        return found
    }

    /// The engine's sample deck (`deckcraft_engine::sample::open_sample`), read from the oracle corpus,
    /// where deckcraft saved it at the pin. nil without the corpus.
    static func sample() throws -> Presentation? {
        guard let corpus = Fixtures.oracleCorpus else { return nil }
        let bytes = try [UInt8](Data(contentsOf: corpus.appending(path: "decks/sample.deckcraft")))
        return try DeckFormat.load(bytes)
    }

    /// Whether the oracle corpus is there (the tests that read the sample deck skip without it).
    static var hasCorpus: Bool { Fixtures.oracleCorpus != nil }

    /// `std::env::var(name)`, when set and not empty.
    static func env(_ name: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return nil }
        return v
    }

    /// A tiny 8 kHz mono 16-bit WAV of `n` silent samples.
    static func wav(_ n: UInt32) -> [UInt8] {
        let data = n &* 2
        var out = Array("RIFF".utf8)
        func le32(_ v: UInt32) { out += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        func le16(_ v: UInt16) { out += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        le32(36 &+ data)
        out += Array("WAVEfmt ".utf8)
        le32(16)
        le16(1)
        le16(1)
        le32(8000)
        le32(16000)
        le16(2)
        le16(16)
        out += Array("data".utf8)
        le32(data)
        out += [UInt8](repeating: 0, count: Int(data))
        return out
    }
}

// MARK: Rust `str` methods, byte-wise

extension String {
    /// `str::matches(needle).count()`: non-overlapping occurrences.
    func count(of needle: String) -> Int {
        let h = Array(utf8), n = Array(needle.utf8)
        guard !n.isEmpty, h.count >= n.count else { return 0 }
        var i = 0, count = 0
        while i + n.count <= h.count {
            if h[i ..< i + n.count].elementsEqual(n) {
                count += 1
                i += n.count
            } else {
                i += 1
            }
        }
        return count
    }

    /// `str::find(needle)` from byte `from`: the byte offset of the first match.
    func byteFind(_ needle: String, from: Int = 0) -> Int? {
        let h = Array(utf8), n = Array(needle.utf8)
        guard from >= 0, h.count >= n.count, from <= h.count - n.count else { return nil }
        var i = from
        while i + n.count <= h.count {
            if h[i ..< i + n.count].elementsEqual(n) { return i }
            i += 1
        }
        return nil
    }

    /// `str::rfind(needle)` within the first `before` bytes.
    func byteRFind(_ needle: String, before: Int? = nil) -> Int? {
        let h = Array(utf8), n = Array(needle.utf8)
        let end = Swift.min(before ?? h.count, h.count)
        guard end >= n.count else { return nil }
        var i = end - n.count
        while i >= 0 {
            if h[i ..< i + n.count].elementsEqual(n) { return i }
            i -= 1
        }
        return nil
    }

    /// `&s[a..b]` by byte offsets (lossy at a split character, where Rust would panic).
    func bytes(_ a: Int, _ b: Int? = nil) -> String {
        let u = Array(utf8)
        let lo = Swift.max(0, Swift.min(a, u.count)), hi = Swift.max(lo, Swift.min(b ?? u.count, u.count))
        return String(decoding: u[lo ..< hi], as: UTF8.self)
    }

    /// `str::contains`, byte-wise.
    func has(_ needle: String) -> Bool { needle.isEmpty || byteFind(needle) != nil }

    /// `str::replacen(from, to, n)`.
    func replacen(_ from: String, _ to: String, _ n: Int) -> String {
        guard !from.isEmpty else { return self }
        var out = "", rest = self, done = 0
        while done < n, let i = rest.byteFind(from) {
            out += rest.bytes(0, i) + to
            rest = rest.bytes(i + from.utf8.count)
            done += 1
        }
        return out + rest
    }

    /// `str::replace(from, to)`.
    func replace(_ from: String, _ to: String) -> String { replacen(from, to, .max) }
}
