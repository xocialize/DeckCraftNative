// Parity with deckcraft-geom: rebuilds every dump `Tools/oracle/geom-vectors` writes (presets, warps,
// morphs, squircles, units, transforms) and compares it line for line with the oracle's, every float as
// its bit pattern. Skips cleanly without the fixtures.
@testable import DCGeometry
import DCTestSupport
import Foundation
import Testing

private let dir = Fixtures.root.appending(path: "geom", directoryHint: .isDirectory)
private let haveVectors = FileManager.default.fileExists(atPath: dir.appending(path: "presets.txt").path)

func hx(_ v: Double) -> String {
    let s = String(v.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - s.count) + s
}

func hx(_ p: Point) -> String { "\(hx(p.x)) \(hx(p.y))" }
func hx(_ r: Rect) -> String { "\(hx(r.x0)) \(hx(r.y0)) \(hx(r.x1)) \(hx(r.y1))" }

func dumpEl(_ out: inout String, _ e: PathEl) {
    switch e {
    case .moveTo(let a): out += "M \(hx(a))\n"
    case .lineTo(let a): out += "L \(hx(a))\n"
    case .quadTo(let a, let b): out += "Q \(hx(a)) \(hx(b))\n"
    case .curveTo(let a, let b, let c): out += "C \(hx(a)) \(hx(b)) \(hx(c))\n"
    case .closePath: out += "Z\n"
    }
}

private func b(_ v: Bool) -> String { v ? "1" : "0" }

func dumpGeometry(_ out: inout String, _ g: Preset.Geometry) {
    for s in g.paths {
        out += "path \(s.fill.rawValue) \(b(s.stroke)) \(b(s.evenOdd))\n"
        for e in s.path.elements { dumpEl(&out, e) }
    }
    out += "text \(hx(g.textRect))\n"
    for h in g.handles {
        out += "handle \(h.index) \(hx(h.pos)) \(hx(h.origin)) \(hx(h.dir.x)) \(hx(h.dir.y)) \(hx(h.min)) \(hx(h.max)) \(b(h.angle)) \(hx(h.valueAt(h.pos)))\n"
    }
    for s in g.sites { out += "site \(hx(s))\n" }
    let o = g.outline
    out += "bbox \(hx(o.boundingBox)) area \(hx(o.area))\n"
}

let oracleSizes: [(Double, Double)] = [(100, 100), (300, 80), (40, 200), (0, 0), (216, 108)]
let oracleAdjustSets: [[Double]] = [
    [],
    Array(repeating: 0.0, count: 8),
    Array(repeating: 100_000.0, count: 8),
    [30000, 60000, 20000, 9_000_000, 20000, 40000, 120_000, -30000],
    [1e12, -1e12, 1e12, -1e12, 1e12, -1e12, 1e12, -1e12],
    [.nan, .infinity, -.infinity, .nan, 5, 6, 7, 8],
]

func dumpCase(_ name: String, _ w: Double, _ h: Double, _ adj: [Double]) -> String {
    var s = ""
    if let g = Preset.build(name, w, h, adj) { dumpGeometry(&s, g) } else { s += "none\n" }
    return s
}

func fnv(_ s: String) -> UInt64 {
    var x: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in s.utf8 {
        x ^= UInt64(byte)
        x = x &* 0x100_0000_01b3
    }
    return x
}

/// Rust's `{:?}` for the plain test strings: quotes, with `\` and `"` escaped.
private func rustDebug(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// Compares `got` with the oracle file line by line; records the first few differences.
private func compare(_ file: String, _ got: String) throws {
    let want = try String(contentsOf: dir.appending(path: file), encoding: .utf8)
    let (a, b) = (got.split(separator: "\n", omittingEmptySubsequences: false), want.split(separator: "\n", omittingEmptySubsequences: false))
    var shown = 0
    var context = ""
    for i in 0 ..< max(a.count, b.count) {
        let (x, y) = (a.at(i), b.at(i))
        if let x, x.hasPrefix("case ") || x.hasPrefix("warp ") || x.hasPrefix("morph ") { context = String(x) }
        if x != y {
            Issue.record("\(file):\(i + 1) [\(context)]\n  swift: \(x ?? "<eof>")\n  rust:  \(y ?? "<eof>")")
            shown += 1
            if shown >= 5 { break }
        }
    }
}

@Suite(.enabled(if: haveVectors, "no geom vectors: run Tools/oracle/geom-vectors"))
struct GeometryOracleTests {
    @Test func presetsMatchBitForBit() throws {
        var full = ""
        for info in Preset.catalog {
            for (w, h) in [(100.0, 100.0), (216.0, 108.0)] {
                full += "case \(info.name) \(hx(w)) \(hx(h))\n"
                full += dumpCase(info.name, w, h, [])
                if let g = Preset.build(info.name, w, h, []) {
                    var n = 0
                    presetFlatten(g.outline) { e in
                        n += 1
                        dumpEl(&full, e)
                    }
                    full += "flat \(n)\n"
                    full += "near \(b(nearPath(g.outline, Point(w / 2, 0), 0.5))) \(b(nearPath(g.outline, Point(w / 2, h / 2), 0.5)))\n"
                }
            }
        }
        try compare("presets.txt", full)
    }

    @Test func everySizeAndAdjustSetHashesTheSame() throws {
        var out = ""
        for info in Preset.catalog {
            for (si, (w, h)) in oracleSizes.enumerated() {
                for (ai, adj) in oracleAdjustSets.enumerated() {
                    let hs = String(fnv(dumpCase(info.name, w, h, adj)), radix: 16)
                    out += "\(info.name) \(si) \(ai) \(String(repeating: "0", count: 16 - hs.count) + hs)\n"
                }
            }
        }
        try compare("preset-hashes.txt", out)
    }

    private func guideLines(_ out: inout String, _ tag: String, _ g: Warp.Guide, _ full: Bool) {
        out += "\(tag) len \(hx(g.length)) closed \(b(g.isClosed))\n"
        let samples: [Double] = full ? (0 ... 200).map { Double($0) / 200.0 } : [0.0, 0.25, 0.5, 0.75, 1.0]
        for t in samples {
            let (q, tan) = g.at(t * g.length)
            out += "at \(hx(t)) \(hx(q)) \(hx(tan.x)) \(hx(tan.y))\n"
        }
        let o = g.offset(7.5)
        out += "offset len \(hx(o.length))\n"
        out += "offset at \(hx(o.at(o.length * 0.3).0))\n"
    }

    @Test func warpsMatchBitForBit() throws {
        var out = ""
        let rects = [Rect(0, 0, 420, 200), Rect(110, 60, 10, 20)]
        let adjs: [[Double]] = [[], [.nan, .infinity], [21_599_999, 100_000]]
        let lines = [
            Warp.Line(ink: Rect(100, 50, 300, 90), extent: (100, 300), refY: 88),
            Warp.Line(ink: Rect(150, 95, 250, 130), extent: (150, 250), refY: 128),
            Warp.Line(ink: nil, extent: (5, 5), refY: 3),
        ]
        for info in Warp.catalog {
            for (ri, rect) in rects.enumerated() {
                for (ai, adj) in adjs.enumerated() {
                    out += "warp \(info.id) \(ri) \(ai)\n"
                    let full = ri == 0 && ai == 0
                    guard let w = Warp.make(info.id, adj, rect) else {
                        out += "none\n"
                        continue
                    }
                    for band in w.bands {
                        switch band {
                        case .fill(let top, let bottom):
                            guideLines(&out, "top", top, full)
                            guideLines(&out, "bottom", bottom, full)
                        case .follow(let path, let anchor):
                            let name = switch anchor {
                            case .last: "Last"
                            case .first: "First"
                            case .middle: "Middle"
                            }
                            out += "follow \(name)\n"
                            guideLines(&out, "path", path, full)
                        }
                    }
                    for h in Warp.handles(info.id, adj, rect) {
                        out += "handle \(h.index) \(hx(h.pos)) \(hx(h.valueAt(Point(rect.x0 + 37, rect.y1 - 11))))\n"
                    }
                    let m = w.mapper(lines, rect.inset(-5))
                    out += "zoom \(hx(m.zoom))\n"
                    let probes: [(Int, Point)] = [
                        (0, Point(100, 50)), (0, Point(300, 90)), (0, Point(200, 70)), (1, Point(150, 95)), (1, Point(250, 130)),
                        (2, Point(5, 3)), (7, Point(1, 1)),
                    ]
                    for (i, q) in probes { out += "map \(i) \(hx(m.map(i, q)))\n" }
                }
            }
        }
        for (l, n, bands) in [(0, 2, 2), (2, 3, 2), (4, 5, 3), (3, 4, 3), (0, 0, 3), (7, 9, 1)] {
            out += "bandOfLine \(l) \(n) \(bands) \(Warp.bandOfLine(l, n, bands))\n"
        }
        try compare("warps.txt", out)
    }

    @Test func morphsMatchBitForBit() throws {
        var out = ""
        let pairs: [(String, Double, Double, String, Double, Double)] = [
            ("ellipse", 100, 100, "star5", 200, 100), ("triangle", 100, 100, "ellipse", 100, 100), ("rect", 100, 100, "cube", 100, 100),
            ("donut", 100, 100, "ellipse", 100, 100), ("cloud", 300, 200, "wave", 240, 120), ("rect", 10, 10, "line", 10, 0),
            ("gear9", 150, 150, "heart", 150, 150),
        ]
        for (a, aw, ah, bn, bw, bh) in pairs {
            guard let ga = Preset.build(a, aw, ah, []), let gb = Preset.build(bn, bw, bh, []) else { continue }
            let m = GeometryMorph(ga, gb)
            for t in [0.0, 0.37, 1.0] {
                let (g, fades) = m.at(t, Vec2(1, 1), Vec2(0.5, 2))
                out += "morph \(a) \(bn) \(hx(t))\n"
                for (s, f) in zip(g.paths, fades) {
                    out += "path \(s.fill.rawValue) \(b(s.stroke)) \(b(s.evenOdd)) fade \(hx(f.fill)) \(hx(f.stroke))\n"
                    for e in s.path.elements { dumpEl(&out, e) }
                }
                out += "text \(hx(g.textRect))\n"
            }
            let (x, y) = Morph.align(Morph.contours(ga.paths[0].path), Morph.contours(gb.paths[0].path), nil, nil)
            out += "align \(a) \(bn) \(x.count) \(y.count)\n"
            for c in x + y {
                out += "contour \(b(c.closed)) \(c.pts.count)\n"
                for q in c.pts { out += "pt \(hx(q))\n" }
            }
        }
        try compare("morphs.txt", out)
    }

    @Test func squirclesUnitsAndTransformsMatch() throws {
        var out = ""
        let squircles: [(Double, Double, Double, Double)] = [
            (100, 50, 0, 0.6), (200, 100, 20, 0), (200, 100, 20, 0.6), (120, 80, 16, 0.6), (40, 40, 50, 0.8), (10, 300, 4, 0.6),
            (.nan, 10, .infinity, .nan), (1e21, 3, 1, 0.5), (0.1234567, 0.2, 0.05, 1),
        ]
        for (w, h, r, s) in squircles { out += "squircle \(Squircle.pathD(w, h, r, s))\n" }
        for t in ["2", "2\"", "2.54 cm", "36pt", "abc", "", "  5mm ", "-3.5in", "40px", "+1.25", "1e3", ".5", "1.2.3"] {
            out += "parse \(rustDebug(t)) \(DCGeometry.Unit.inches.parse(t).map { hx($0) } ?? "none")\n"
        }
        let unitNames: [(DCGeometry.Unit, String)] = [(.inches, "Inches"), (.centimeters, "Centimeters"), (.points, "Points"), (.pixels, "Pixels")]
        for v in [150.0, 0.0, -1.005, 1e9, 2.675] {
            for (u, n) in unitNames { out += "format \(hx(v)) \(n) \(u.format(v))\n" }
        }
        for v in [0.0, 1.0, 12_699.0 / 12_700.0, -5.5, 1e300, .nan, 0.5 / 12_700.0, 2.5 / 12_700.0] {
            out += "emu \(hx(v)) \(ptToEmu(v))\n"
        }
        for x in [
            Xfrm(x: 10, y: 20, w: 100, h: 50, rot: 90),
            Xfrm(x: -3, y: 7, w: 33.3, h: 12.1, rot: 33, flipH: true, flipV: false),
            Xfrm(x: 0, y: 0, w: 100, h: 50, rot: -725, flipH: true, flipV: true),
        ] {
            let a = x.affine
            let c = a.coeffs
            out += "xfrm \([c.0, c.1, c.2, c.3, c.4, c.5].map { hx($0) }.joined(separator: " ")) bounds \(hx(x.bounds)) rotnorm \(hx(x.rotNorm)) map \(hx(a * Point(3, 4)))\n"
            let g = groupChildAffine(x, Rect(5, 5, 55, 30)).coeffs
            out += "group \([g.0, g.1, g.2, g.3, g.4, g.5].map { hx($0) }.joined(separator: " "))\n"
        }
        try compare("misc.txt", out)
    }
}
