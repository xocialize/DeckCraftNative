// DCRenderTests — the CPU transition compositor against deckcraft-render's `composite_transition`, bit for
// bit: `Tools/oracle/anim-vectors` composites generated images with every transition and option at five
// times, with and without an old slide and slide parts, and writes a hash of each frame to
// `DeckCraftNative-Fixtures/anim/composite.txt`. The same images are composited here. Skips without the
// fixtures.
import DCModel
@testable import DCRender
import DCTestSupport
import Foundation
import Testing

private struct Hash {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    mutating func bytes(_ b: some Sequence<UInt8>) {
        for x in b {
            h ^= UInt64(x)
            h = h &* 0x0000_0100_0000_01B3
        }
    }

    mutating func u(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes($0) } }

    var hex: String {
        let s = String(h, radix: 16)
        return String(repeating: "0", count: Swift.max(0, 16 - s.count)) + s
    }
}

private func unhex(_ s: Substring) -> String {
    if s == "-" { return "" }
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) {
        out.append(UInt8(s[i ..< j], radix: 16) ?? 0)
        i = j
    }
    return String(decoding: out, as: UTF8.self)
}

/// anim-vectors' generated images: opaque patterns for slides and backgrounds, premultiplied see-through ones
/// for contents.
private func image(_ w: UInt32, _ h: UInt32, _ seed: UInt32, _ content: Bool) -> RenderImage {
    var px: [UInt8] = []
    px.reserveCapacity(Int(w * h * 4))
    for y in 0 ..< h {
        for x in 0 ..< w {
            let v = x &* 7 &+ y &* 13 &+ seed &* 31
            let r = UInt8((v &* 5) % 256)
            let g = UInt8((x * 255) / Swift.max(w, 1))
            let b = UInt8((y * 255) / Swift.max(h, 1)) ^ UInt8(truncatingIfNeeded: seed)
            if content {
                let a: UInt8 = (x / 8 + y / 6 + seed) % 3 == 0 ? 0 : UInt8((x * 11 + y * 3 + seed) % 256)
                func m(_ c: UInt8) -> UInt8 { UInt8((UInt32(c) * UInt32(a) + 127) / 255) }
                px += [m(r), m(g), m(b), a]
            } else {
                px += [r, g, b, 255]
            }
        }
    }
    return RenderImage(width: Int(w), height: Int(h), pixels: px)
}

@Suite struct CompositeVectorTests {
    @Test func compositorMatchesDeckcraftBitForBit() throws {
        let file = Fixtures.root.appending(path: "anim/composite.txt")
        guard let data = FileManager.default.contents(atPath: file.path) else { return }
        let (w, h): (UInt32, UInt32) = (64, 36)
        let old = image(w, h, 1, false)
        let new = image(w, h, 2, false)
        let parts = SlideParts(oldBack: image(w, h, 3, false), oldContent: image(w, h, 4, true), newBack: image(w, h, 5, false), newContent: image(w, h, 6, true))
        var first = parts
        first.oldBack = nil
        first.oldContent = nil
        var bad: [String] = []
        var checked = 0, misses = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 5, let tb = UInt64(f[2], radix: 16) else { continue }
            let (kind, o, t) = (unhex(f[0]), unhex(f[1]), Double(bitPattern: tb))
            let ls = transitionFrame(kind, o, t, 16.0 / 9.0)
            let img: RenderImage = switch f[3] {
            case "0": compositeTransition(old, new, nil, ls)
            case "1": compositeTransition(nil, new, nil, ls)
            case "2": compositeTransition(old, new, parts, ls)
            default: compositeTransition(nil, new, first, ls)
            }
            var hh = Hash()
            hh.u(UInt64(img.width))
            hh.u(UInt64(img.height))
            hh.bytes(img.pixels)
            checked += 1
            if hh.hex != f[4] {
                misses += 1
                if bad.count < 12 { bad.append("\(kind)/\(o) t=\(t) variant \(f[3]): \(hh.hex) vs \(f[4])") }
            }
        }
        #expect(checked > 1000)
        #expect(misses == 0, "\(misses) of \(checked) frames differ:\n\(bad.joined(separator: "\n"))")
    }
}
