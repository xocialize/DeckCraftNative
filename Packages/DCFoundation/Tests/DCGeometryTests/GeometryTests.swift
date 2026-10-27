// Ported from deckcraft crates/geom/src/lib.rs `mod tests` (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
import DCCore
@testable import DCGeometry
import Testing

@Suite struct GeometryLibTests {
    @Test func emuRoundtripIsExact() {
        for emu: Int64 in [0, 1, 12_699, 12_700, 914_400, 12_192_000, 6_858_000, -5, 123_456_789] {
            #expect(ptToEmu(emuToPt(emu)) == emu)
        }
        #expect(ptToEmu(.nan) == 0)
        #expect(ptToEmu(.infinity) == 0)
    }

    @Test func unitParseAndFormat() {
        #expect(DCGeometry.Unit.inches.parse("2") == 144.0)
        #expect(DCGeometry.Unit.inches.parse("2\"") == 144.0)
        #expect(abs((DCGeometry.Unit.inches.parse("2.54 cm") ?? 0) - 72.0) < 1e-9)
        #expect(DCGeometry.Unit.inches.parse("36pt") == 36.0)
        #expect(DCGeometry.Unit.inches.parse("abc") == nil)
        #expect(DCGeometry.Unit.inches.parse("") == nil)
        #expect(DCGeometry.Unit.inches.format(150.0) == "2.08\"")
    }

    @Test func xfrmAffineRotationAboutCenter() {
        let x = Xfrm(x: 10, y: 20, w: 100, h: 50, rot: 90)
        let c = x.affine * Point(50, 25)
        #expect(abs(c.x - 60) < 1e-9 && abs(c.y - 45) < 1e-9)
        let b = x.bounds
        #expect(abs(b.width - 50) < 1e-9 && abs(b.height - 100) < 1e-9)
    }

    @Test func flipsMirrorLocalSpace() {
        let x = Xfrm(x: 0, y: 0, w: 100, h: 50, flipH: true)
        let p = x.affine * Point(0, 0)
        #expect(abs(p.x - 100) < 1e-9 && abs(p.y) < 1e-9)
    }

    @Test func groupChildMapping() {
        let g = Xfrm(100, 100, 200, 100)
        let a = groupChildAffine(g, Rect(0, 0, 100, 50))
        let p = a * Point(100, 50)
        #expect(abs(p.x - 300) < 1e-9 && abs(p.y - 200) < 1e-9)
    }

    @Test func segmentDistance() {
        #expect(abs(distToSegment(Point(5, 5), Point(0, 0), Point(10, 0)) - 5) < 1e-9)
        #expect(abs(distToSegment(Point(0, 3), Point(0, 0), Point(0, 0)) - 3) < 1e-9)
    }

    // New: the serde shapes the model relies on.
    @Test func xfrmAndKurboTypesSerializeAsSerdeDoes() throws {
        let w = JSONWriter()
        #expect(w.string(Xfrm(10, 20, 100, 50).toJSON()) == #"{"x":10.0,"y":20.0,"w":100.0,"h":50.0}"#)
        #expect(w.string(Xfrm(x: 0, y: 0, w: 1, h: 1, rot: 45, flipH: true).toJSON()) == #"{"x":0.0,"y":0.0,"w":1.0,"h":1.0,"rot":45.0,"flipH":true}"#)
        #expect(try Xfrm(fromJSON: JSONParser.parse(#"{"w":3}"#)) == Xfrm(x: 0, y: 0, w: 3, h: 0))
        #expect(w.string(Size(960, 540).toJSON()) == #"{"width":960.0,"height":540.0}"#)
        #expect(w.string(Rect(0, 1, 2, 3).toJSON()) == #"{"x0":0.0,"y0":1.0,"x1":2.0,"y1":3.0}"#)
        #expect(w.string(Point(1, 2).toJSON()) == #"{"x":1.0,"y":2.0}"#)
        #expect(try Size(fromJSON: JSONParser.parse(#"{"width":4,"height":5}"#)) == Size(4, 5))
        #expect(throws: JSONDecodeError.self) { try Rect(fromJSON: JSONParser.parse(#"{"x0":0}"#)) }
        #expect(w.string(FillMode.lightenLess.toJSON()) == #""lightenLess""#)
    }

    // New: Rust's min/max/clamp semantics on signed zeros and NaN, which the bit-exact ports rely on.
    @Test func rustFloatSemantics() {
        #expect(fmin(0.0, -0.0).sign == .minus && fmin(-0.0, 0.0).sign == .minus)
        #expect(fmax(0.0, -0.0).sign == .plus && fmax(-0.0, 0.0).sign == .plus)
        #expect(fmin(.nan, 3) == 3 && fmax(3, .nan) == 3)
        #expect((-0.0).clamp(0.0, 1.0).sign == .minus)
        #expect(Double.nan.clamp(0, 1).isNaN)
        #expect((-7.5).remEuclid(2) == 0.5)
        #expect(BezPath().area.sign == .minus)
        #expect(asUsize(-3) == 0 && asUsize(.nan) == 0 && asUsize(3.9) == 3)
    }
}
