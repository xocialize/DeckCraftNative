// Ported from deckcraft crates/render/src/pattern.rs `mod tests` and the pattern render tests in
// tests.rs / tests_wild.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCGeometry
import DCModel
@testable import DCRender
import Testing

@Suite struct PatternTests {
    @Test func everyDrawingMLPresetHasATile() {
        // ECMA-376 ST_PresetPatternVal.
        let all = [
            "pct5", "pct10", "pct20", "pct25", "pct30", "pct40", "pct50", "pct60", "pct70", "pct75", "pct80", "pct90", "horz", "vert",
            "ltHorz", "ltVert", "dkHorz", "dkVert", "narHorz", "narVert", "dashHorz", "dashVert", "cross", "dnDiag", "upDiag",
            "ltDnDiag", "ltUpDiag", "dkDnDiag", "dkUpDiag", "wdDnDiag", "wdUpDiag", "dashDnDiag", "dashUpDiag", "diagCross",
            "smCheck", "lgCheck", "smGrid", "lgGrid", "dotGrid", "smConfetti", "lgConfetti", "horzBrick", "diagBrick", "solidDmnd",
            "openDmnd", "dotDmnd", "plaid", "sphere", "weave", "divot", "shingle", "wave", "trellis", "zigZag",
        ]
        #expect(all.count == 54)
        for n in all { #expect(Pattern.presets.contains(n), "\(n)") }
        #expect(Pattern.tiles.count == 54)
    }

    @Test func percentPresetsGetDenser() {
        // The pctN tiles set more cells as N grows (pct5 sets 2 of 64, pct50 half, pct90 all but 2).
        func share(_ n: String) -> Int {
            let t = Pattern.tile(n)
            return (0 ..< 64).filter { Pattern.isFg(t, $0 % 8, $0 / 8) }.count
        }
        let names = ["pct5", "pct10", "pct20", "pct25", "pct30", "pct40", "pct50", "pct60", "pct70", "pct75", "pct80", "pct90"]
        #expect(zip(names, names.dropFirst()).allSatisfy { share($0) <= share($1) }, "\(names.map(share))")
        #expect(share("pct5") == 2 && share("pct50") == 32 && share("pct90") == 62)
        #expect(Pattern.tile("nonsense") == Pattern.tile("pct50"))
    }

    func patterned(_ preset: String, at box: Rect, on c: Canvas, scale: Double) {
        let (pres, rctx) = testContext()
        let fill = Fill.pattern(PatternFill(preset: preset, fg: .rgb(.rgb(0, 0, 0)), bg: .rgb(.rgb(255, 255, 255))))
        let local = Rect(0, 0, box.width, box.height)
        PaintFill.fillPath(c, rctx, fill, nil, rectPath(local), local, Affine.scale(scale) * Affine.translate(box.origin.toVec2), .norm, 1, pres)
    }

    @Test func patternFillsDrawPowerPointsTiles() throws {
        // dkVert at one output pixel per pattern cell (0.75 pt): columns 11001100… across, as
        // PowerPoint's export draws it; pct50 is a checkerboard.
        let c = try #require(whiteCanvas(260, 100))
        patterned("dkVert", at: Rect(0, 0, 60, 60), on: c, scale: 4.0 / 3.0)
        patterned("pct50", at: Rect(120, 0, 180, 60), on: c, scale: 4.0 / 3.0)
        let img = c.finish()
        func dark(_ x: Int, _ y: Int) -> Bool { (pixel(img, x, y)?[0] ?? 255) < 128 }
        #expect((8 ..< 16).map { dark($0, 20) } == [true, true, false, false, true, true, false, false], "dkVert columns")
        #expect((8 ..< 16).allSatisfy { dark(8, $0) == dark(8, 20) }, "dkVert is vertical")
        // pct50 starts at slide x = 120 pt = 160 px.
        for (x, y) in [(168, 8), (169, 9), (170, 12)] {
            #expect(dark(x, y) != dark(x + 1, y), "pct50 alternates across at \(x),\(y)")
            #expect(dark(x, y) == dark(x + 1, y + 1), "pct50 repeats diagonally at \(x),\(y)")
        }
    }

    @Test func patternsBetweenWholePixelCellsBlendNeighbouringCells() throws {
        // narVert (alternate cells) at 0.75 output pixels per cell: PowerPoint's export reads 255, 128,
        // 0 repeating across; drawing the nearest cell gave only black and white. Bilinear sampling gives
        // about 213, 128, 42 (closer on average over all presets, not exact).
        let c = try #require(whiteCanvas(80, 80))
        patterned("narVert", at: Rect(0, 0, 60, 60), on: c, scale: 1.0)
        let img = c.finish()
        let row = (12 ..< 24).map { pixel(img, $0, 20)?[0] ?? 0 }
        #expect(row.contains { (100 ... 156).contains($0) }, "a blended column: \(row)")
        #expect(row.contains { $0 < 60 } && row.contains { $0 > 200 }, "\(row)")
        // Bilinear exactly as vello samples it: 213, 128, 42 (here 43: rounding in f64, not f32).
        #expect(zip(row.prefix(3), [213, 128, 42]).allSatisfy { abs(Int($0) - $1) <= 1 }, "\(row)")
        // The pattern repeats every 6 px (8 cells).
        #expect(zip(row, row.dropFirst(6)).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "\(row)")
    }

    @Test func aDegenerateTransformDrawsNothing() throws {
        let c = try #require(whiteCanvas(20, 20))
        Pattern.fill(c, "pct50", .black, .white, 1, rectPath(Rect(0, 0, 20, 20)), Affine(0, 0, 0, 0, 0, 0))
        #expect(near(c.finish(), 10, 10, .white, 0))
    }
}
