// Ported from deckcraft crates/geom/src/warp/tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
@testable import DCGeometry
import Testing

private let W = 420.0
private let H = 200.0
private let box = Rect(0, 0, W, H)

/// One line whose ink box is `ink`.
private func oneLine(_ ink: Rect) -> [Warp.Line] {
    [Warp.Line(ink: ink, extent: (ink.x0, ink.x1), refY: ink.y1)]
}

/// Where the unit-square point (u, v) of a single line's ink box lands, in unit coordinates.
private func land(_ name: String, _ adj: [Double], _ u: Double, _ v: Double) -> (Double, Double) {
    guard let w = Warp.make(name, adj, box) else { return (.nan, .nan) }
    let ink = Rect(100, 50, 300, 90)
    let m = w.mapper(oneLine(ink), box.inset(-5))
    let p = m.map(0, Point(ink.x0 + u * ink.width, ink.y0 + v * ink.height))
    return (p.x / W, p.y / H)
}

private func close(_ a: (Double, Double), _ b: (Double, Double), _ tol: Double) -> Bool {
    abs(a.0 - b.0) <= tol && abs(a.1 - b.1) <= tol
}

private func corners(
    _ name: String, _ adj: [Double], _ tl: (Double, Double), _ tr: (Double, Double), _ bl: (Double, Double), _ br: (Double, Double),
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for ((u, v), want) in [((0.0, 0.0), tl), ((1.0, 0.0), tr), ((0.0, 1.0), bl), ((1.0, 1.0), br)] {
        let got = land(name, adj, u, v)
        #expect(close(got, want, 0.004), "\(name) corner (\(u),\(v)): got \(got), want \(want)", sourceLocation: sourceLocation)
    }
}

@Suite struct WarpTests {
    @Test func catalogIsTheFortyDrawnPresets() {
        #expect(Warp.catalog.count == 40)
        var seen = Set<String>()
        for p in Warp.catalog {
            #expect(seen.insert(p.id).inserted, "duplicate \(p.id)")
            #expect(!p.label.isEmpty, "\(p.id)")
            #expect(Warp.isSupported(p.id), "\(p.id)")
            #expect(Warp.isFollow(p.id) == ["textArchUp", "textArchDown", "textCircle", "textButton"].contains(p.id), "\(p.id)")
        }
    }

    @Test func everyPresetBuildsFiniteGuides() {
        for p in Warp.catalog {
            let name = p.id
            #expect(Warp.isSupported(name), "\(name)")
            guard let w = Warp.make(name, [], box) else {
                Issue.record("\(name)")
                continue
            }
            #expect(!w.bands.isEmpty, "\(name)")
            for b in w.bands {
                #expect(b.length.isFinite && b.length > 10, "\(name): band length \(b.length)")
            }
            #expect(Warp.adjustCount(name) == Warp.adjustDefaults(name).count)
        }
        #expect(Warp.make("textNoShape", [], box) == nil)
        #expect(Warp.make("bogus", [], box) == nil)
        #expect(!Warp.isSupported("textNoShape"))
    }

    @Test func straightPresetsPutTheInkCornersOnTheirGuides() {
        corners("textPlain", [], (0, 0), (1, 0), (0, 1), (1, 1))
        // A smaller adjust shears the text: the top edge starts 40 % in, the bottom edge ends 60 % in.
        corners("textPlain", [30_000], (0.4, 0), (1, 0), (0, 1), (0.6, 1))
        corners("textStop", [], (0, 0.25), (1, 0.25), (0, 0.75), (1, 0.75))
        corners("textTriangle", [], (0, 0.5), (1, 0.5), (0, 1), (1, 1))
        corners("textTriangleInverted", [25_000], (0, 0), (1, 0), (0, 0.25), (1, 0.25))
        corners("textChevron", [], (0, 0.25), (1, 0.25), (0, 1), (1, 1))
        corners("textChevronInverted", [], (0, 0), (1, 0), (0, 0.75), (1, 0.75))
        corners("textFadeRight", [], (0, 0), (1, 0.33333), (0, 1), (1, 0.66667))
        corners("textFadeLeft", [], (0, 0.33333), (1, 0), (0, 0.66667), (1, 1))
        corners("textFadeUp", [], (0.33333, 0), (0.66667, 0), (0, 1), (1, 1))
        corners("textFadeDown", [], (0, 0), (1, 0), (0.33333, 1), (0.66667, 1))
        corners("textSlantUp", [], (0, 0.55556), (1, 0), (0, 1), (1, 0.44444))
        corners("textSlantDown", [], (0, 0), (1, 0.55556), (0, 0.44444), (1, 1))
        corners("textCascadeUp", [], (0, 0.13889), (1, 0), (0, 1), (1, 0.44444))
        corners("textCascadeDown", [], (0, 0), (1, 0.13889), (0, 0.44444), (1, 1))
    }

    @Test func curvedPresetsBendWherePowerpointBendsThem() {
        corners("textInflate", [], (0, 0.1875), (1, 0.1875), (0, 0.8125), (1, 0.8125))
        #expect(close(land("textInflate", [], 0.5, 0), (0.5, 0), 0.004))
        #expect(close(land("textInflate", [], 0.5, 1), (0.5, 1), 0.004))
        corners("textDeflate", [], (0, 0), (1, 0), (0, 1), (1, 1))
        #expect(close(land("textDeflate", [], 0.5, 0), (0.5, 0.1875), 0.004))
        corners("textInflateBottom", [], (0, 0), (1, 0), (0, 0.6), (1, 0.6))
        #expect(close(land("textInflateBottom", [], 0.5, 1), (0.5, 0.8), 0.004))
        #expect(close(land("textDeflateBottom", [], 0.5, 1), (0.5, 0.5), 0.004))
        #expect(close(land("textInflateTop", [], 0.5, 0), (0.5, 0.2), 0.004))
        #expect(close(land("textDeflateTop", [], 0.5, 0), (0.5, 0.5), 0.004))
        // Cans: half ellipses.
        corners("textCanUp", [], (0, 0.15), (1, 0.15), (0, 1), (1, 1))
        #expect(close(land("textCanUp", [], 0.5, 0), (0.5, 0), 0.004))
        #expect(close(land("textCanUp", [], 0.5, 1), (0.5, 0.85), 0.004))
        #expect(close(land("textCanDown", [], 0.5, 0), (0.5, 0.14286), 0.004))
        // Curves and waves.
        let a = 0.45977
        corners("textCurveUp", [], (0, a), (1, 0), (0, 1 - 3 * a / 8), (1, 1 - 3 * a / 8))
        #expect(close(land("textCurveUp", [], 0.5, 1), (0.5, 1), 0.004))
        corners("textCurveDown", [], (0, 0), (1, a), (0, 1 - 3 * a / 8), (1, 1 - 3 * a / 8))
        corners("textWave1", [], (0, 0.125), (1, 0.125), (0, 0.875), (1, 0.875))
        // Wave 1 rises first: its top is near the box top a quarter of the way along.
        #expect(land("textWave1", [], 0.25, 0).1 < 0.02)
        #expect(land("textWave2", [], 0.25, 0).1 > 0.23)
        // A horizontal shift moves the bottom guide right.
        corners("textWave1", [12_500, 5_000], (0, 0.125), (0.9, 0.125), (0.1, 0.875), (1, 0.875))
        #expect(land("textDoubleWave1", [], 0.125, 0).1 < 0.02)
        #expect(land("textWave4", [], 0.125, 0).1 > 0.1)
    }

    @Test func arcPresetsFollowEllipses() {
        // Pour arches: the outer arc from the left end over the top; the inner one is scaled by adj2.
        corners("textArchUpPour", [], (0, 0.5), (1, 0.5), (0.25, 0.5), (0.75, 0.5))
        #expect(close(land("textArchUpPour", [], 0.5, 0), (0.5, 0), 0.004))
        #expect(close(land("textArchUpPour", [], 0.5, 1), (0.5, 0.25), 0.004))
        #expect(close(land("textArchUpPour", [10_800_000, 30_000], 0.5, 1), (0.5, 0.35), 0.004))
        #expect(close(land("textArchDownPour", [], 0.5, 0), (0.5, 0.625), 0.004))
        #expect(close(land("textArchDownPour", [], 0.5, 1), (0.5, 1), 0.004))
        // Circle pour: once round from the left; the middle of the text is at the right.
        #expect(close(land("textCirclePour", [], 0.5, 0), (1, 0.5), 0.004))
        // Rings: the text goes round two stacked ellipses.
        #expect(close(land("textRingInside", [], 0, 0), (0, 0.3), 0.004))
        #expect(close(land("textRingInside", [], 0, 1), (0, 0.7), 0.004))
        #expect(close(land("textRingInside", [], 0.25, 0), (0.5, 0), 0.01))
        #expect(close(land("textRingOutside", [], 0.25, 1), (0.5, 1), 0.01))
    }

    @Test func followPresetsKeepTextSizeAndStackLinesOutwards() throws {
        let w = try #require(Warp.make("textArchUp", [], box))
        // A 40-wide centred line whose reference height is 80.
        let line = Warp.Line(ink: Rect(190, 50, 230, 88), extent: (190, 230), refY: 80)
        let inner = Rect(7.2, 3.6, W - 7.2, H - 3.6)
        var m = w.mapper([line], inner)
        // The middle of the reference line lands on the top of the ellipse; 10 pt above it lands 10 pt
        // above the top.
        let p = m.map(0, Point(210, 80))
        #expect(abs(p.x - 210) < 0.05 && abs(p.y) < 0.05, "\(p)")
        let q = m.map(0, Point(210, 70))
        #expect(abs(q.x - 210) < 0.15 && abs(q.y + 10) < 0.05, "\(q)")
        // Natural size: 40 pt of text spans about 40 pt of arc.
        let (a, b) = (m.map(0, Point(190, 80)), m.map(0, Point(230, 80)))
        #expect(abs((b - a).hypot - 40) < 0.5)
        // Left-aligned text starts at the very start of the arc: insets don't shorten it.
        let left = Warp.Line(ink: Rect(7.2, 50, 47.2, 88), extent: (7.2, 47.2), refY: 80)
        m = w.mapper([left], inner)
        let pl = m.map(0, Point(7.2, 80))
        #expect(abs(pl.x) < 0.01 && abs(pl.y - 100) < 0.01, "\(pl)")
        // Two lines on an arch up: the last sits on the arc, the first stacks outside it.
        let l1 = Warp.Line(ink: Rect(190, 10, 230, 40), extent: (190, 230), refY: 34)
        let l2 = Warp.Line(ink: Rect(190, 50, 230, 80), extent: (190, 230), refY: 74)
        m = w.mapper([l1, l2], inner)
        #expect(abs(m.map(1, Point(210, 74)).y) < 0.05)
        #expect(abs(m.map(0, Point(210, 34)).y + 40) < 0.05)
        // Arch down: the first line sits on the bottom of the ellipse.
        let down = try #require(Warp.make("textArchDown", [], box))
        m = down.mapper([l1, l2], inner)
        #expect(abs(m.map(0, Point(210, 34)).y - H) < 0.05)
        #expect(abs(m.map(1, Point(210, 74)).y - H - 40) < 0.05)
        // Text longer than the arc is shrunk to fit it.
        let long = Warp.Line(ink: Rect(-500, 50, 900, 88), extent: (-500, 900), refY: 80)
        m = w.mapper([long], inner)
        let (la, lb) = (m.map(0, Point(-500, 80)), m.map(0, Point(900, 80)))
        #expect(la.x < 5 && lb.x > W - 5 && abs(la.y - 100) < 10 && abs(lb.y - 100) < 10, "\(la) \(lb)")
    }

    @Test func linesShareBandsInOrder() {
        #expect((0 ..< 2).map { Warp.bandOfLine($0, 2, 2) } == [0, 1])
        #expect((0 ..< 3).map { Warp.bandOfLine($0, 3, 2) } == [0, 0, 1])
        #expect((0 ..< 5).map { Warp.bandOfLine($0, 5, 2) } == [0, 0, 0, 1, 1])
        #expect((0 ..< 5).map { Warp.bandOfLine($0, 5, 3) } == [0, 0, 1, 1, 2])
        #expect((0 ..< 4).map { Warp.bandOfLine($0, 4, 3) } == [0, 0, 1, 2])
        #expect((0 ..< 2).map { Warp.bandOfLine($0, 2, 3) } == [0, 1])
        #expect(Warp.bandOfLine(0, 1, 3) == 0)
        #expect(Warp.bandOfLine(7, 9, 1) == 0)
        #expect(Warp.bandOfLine(0, 0, 3) == 0)
    }

    @Test func deflateInflateMapsEachBandSeparately() throws {
        let w = try #require(Warp.make("textDeflateInflate", [], box))
        #expect(w.bands.count == 2)
        let l1 = Warp.Line(ink: Rect(100, 10, 300, 40), extent: (100, 300), refY: 34)
        let l2 = Warp.Line(ink: Rect(100, 50, 300, 80), extent: (100, 300), refY: 74)
        var m = w.mapper([l1, l2], box)
        // Band 1 ends at 45 % height on the sides, band 2 starts at 55 %.
        #expect(abs(m.map(0, Point(100, 40)).y / H - 0.45) < 0.004)
        #expect(abs(m.map(1, Point(100, 50)).y / H - 0.55) < 0.004)
        #expect(abs(m.map(1, Point(300, 80)).y / H - 1) < 0.004)
        // A band with fewer lines keeps them at the size of the fuller band, centred in its band: two
        // lines (ink 10..60) in band 1, one line (ink 70..80) in band 2 of three.
        let a = Warp.Line(ink: Rect(100, 10, 300, 30), extent: (100, 300), refY: 28)
        let b = Warp.Line(ink: Rect(100, 40, 300, 60), extent: (100, 300), refY: 58)
        let c = Warp.Line(ink: Rect(100, 70, 300, 80), extent: (100, 300), refY: 78)
        m = w.mapper([a, b, c], box)
        let (top, bot) = (m.map(2, Point(200, 70)).y / H, m.map(2, Point(200, 80)).y / H)
        // Band 2 runs from 0.4 to 1 at the centre; the line takes the middle fifth of it.
        #expect(abs(top - 0.64) < 0.005 && abs(bot - 0.76) < 0.005, "\(top) \(bot)")
        // A shorter first line keeps its share of the width.
        let short = Warp.Line(ink: Rect(150, 10, 250, 40), extent: (150, 250), refY: 34)
        m = w.mapper([short, l2], box)
        let p = m.map(0, Point(150, 10))
        #expect(abs(p.x / W - 0.25) < 0.01, "\(p)")
    }

    @Test func guidesExtrapolateAndWrap() throws {
        var p = BezPath()
        p.moveTo(Point(0, 0))
        p.lineTo(Point(10, 0))
        let g = Warp.Guide(path: p, closed: false)
        #expect(abs(g.length - 10) < 1e-9)
        #expect(abs(g.at(15).0.x - 15) < 1e-9)
        #expect(abs(g.at(-5).0.x + 5) < 1e-9)
        #expect(g.at(.nan).0.x.isFinite)
        let w = try #require(Warp.make("textCircle", [], box))
        guard case .follow(let path, _)? = w.bands.first else {
            Issue.record("not a follow band")
            return
        }
        #expect(path.isClosed)
        let l = path.length
        let (a, b) = (path.at(5).0, path.at(l + 5).0)
        #expect((a - b).hypot < 1e-6)
        let empty = Warp.Guide()
        #expect(empty.length == 0)
        #expect(empty.at(3).0.x.isFinite)
    }

    @Test func hostileAdjustsAndBoxesStayFinite() {
        let adjs: [[Double]] = [[], [.nan, .infinity], [-.infinity, .nan], [1e300, -1e300], [-1e9, 1e9], [0, 0], [21_599_999, 100_000]]
        let rects = [Rect(0, 0, 0, 0), Rect(10, 10, 10, 200), Rect(0, 0, 300, 0), Rect(100, 100, -50, -20), Rect(0, 0, 1e7, 1e7)]
        let lines = [
            Warp.Line(ink: Rect(0, 0, 0, 0), extent: (0, 0), refY: 0),
            Warp.Line(ink: nil, extent: (5, 5), refY: 3),
            Warp.Line(ink: Rect(-1e6, -5, 1e6, 5), extent: (-1e6, 1e6), refY: 4),
        ]
        for name in Warp.catalog.map(\.id) {
            for adj in adjs {
                for r in rects {
                    guard let w = Warp.make(name, adj, r) else {
                        Issue.record("\(name) \(adj) \(r)")
                        continue
                    }
                    for b in w.bands { #expect(b.length.isFinite) }
                    let m = w.mapper(lines, r)
                    #expect(m.zoom.isFinite && m.zoom >= 1)
                    let probes: [(Int, Point)] = [(0, .zero), (1, Point(5, 3)), (2, Point(1e6, -5)), (2, Point(.nan, 1)), (9, Point(1, 1))]
                    for (i, p) in probes {
                        let q = m.map(i, p)
                        #expect(q.x.isFinite || !p.x.isFinite, "\(name) \(adj) \(r): \(q)")
                        #expect(q.y.isFinite, "\(name) \(adj) \(r): \(q)")
                    }
                }
            }
        }
        #expect(Warp.make("textPlain", [], Rect(.nan, 0, 1, 1)) == nil)
    }

    @Test func everyPresetHasOneHandlePerAdjust() {
        for name in Warp.catalog.map(\.id) {
            let hs = Warp.handles(name, [], box)
            #expect(hs.count == Warp.adjustCount(name), "\(name)")
            let defaults = Warp.adjustDefaults(name)
            for h in hs {
                #expect(h.pos.x.isFinite && h.pos.y.isFinite, "\(name)")
                let back = h.valueAt(h.pos)
                let want = defaults.at(h.index) ?? .nan
                #expect(abs(back - want) <= 1, "\(name) handle \(h.index): \(back) vs \(want)")
            }
        }
        #expect(Warp.handles("textNoShape", [], box).isEmpty)
        #expect(Warp.handles("textArchUp", [], Rect(0, 0, .nan, 10)).isEmpty)
        #expect(Warp.handles("textArchUp", [], Rect(0, 0, 0, 0)).isEmpty)
        // A hostile adjust still places a finite handle on the clamped default.
        let hs = Warp.handles("textInflate", [.nan], box)
        #expect(hs.count == 1)
        #expect(hs.first.map { $0.pos.x.isFinite && $0.pos.y.isFinite } == true)
    }

    @Test func archAndInflateHandlesFollowThePointer() throws {
        let arch = try #require(Warp.handles("textArchUp", [], box).first)
        let deg = arch.valueAt(Point(box.center.x, box.y0)) / 60_000
        #expect(abs(deg - 270) < 0.5, "\(deg)")
        let down = try #require(Warp.handles("textArchDown", [], box).first)
        // The arch-down handle starts on the left; a pointer at the bottom is 90°, which is adjust 90
        // (guide angle 180 − adj).
        let deg2 = down.valueAt(Point(box.center.x, box.y1)) / 60_000
        #expect(abs(deg2 - 90) < 0.5, "\(deg2)")
        let inf = try #require(Warp.handles("textInflate", [], box).first)
        let more = inf.valueAt(Point(inf.pos.x, box.y0 - 80))
        #expect(more > Warp.adjustDefaults("textInflate")[0], "\(more)")
        #expect(abs(more - 20_000) < 1, "\(more)")
    }
}
