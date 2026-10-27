// Ported from deckcraft crates/render/src/tests.rs (`radar_stock_and_combo_draw_their_own_layouts`; MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors). radar.rs has no tests of its own.
import DCColor
import DCGeometry
import DCModel
@testable import DCRender
import Testing

@Suite struct RadarTests {
    /// Radar charts are polar, stock charts draw high-low lines (and up/down bars), and a combo chart draws
    /// its line series over its columns.
    @Test func radarStockAndComboDrawTheirOwnLayouts() {
        var ohlc = Chart.sample(.stock)
        ohlc.series.insert(Series(name: "Open", values: [44, 25, 38, 50, 35]), at: 0)
        ohlc.upDownBars = true
        let charts: [(String, Chart)] = [
            ("Radar", .sample(.radar)),
            ("FilledRadar", .sample(.filledRadar)),
            ("Stock", .sample(.stock)),
            ("StockOHLC", ohlc),
            ("Combo", .sample(.combo)),
        ]
        for (name, c) in charts {
            let img = renderChart(c, 625)
            func ink(_ x: Int, _ y: Int) -> Bool { Array(pixelAt(img, x, y).prefix(3)) != [255, 255, 255] }
            switch name {
            // The radar's top spoke runs straight up from the centre; a line chart has nothing there.
            case "Radar", "FilledRadar":
                #expect((150 ..< 260).contains { ink(480, $0) }, "\(name)")
            // No series lines: well right of the first category there is only gridline grey.
            case "Stock", "StockOHLC":
                var coloured = false
                for y in Swift.stride(from: 60, to: 480, by: 2) where !coloured {
                    for x in Swift.stride(from: 40, to: 920, by: 4) {
                        let p = pixelAt(img, x, y)
                        if Int(p[2]) > Int(p[0]) + 60 {
                            coloured = true
                            break
                        }
                    }
                }
                #expect(!coloured || name == "Stock", "\(name): series drawn as lines")
            default:
                break
            }
        }
    }

    @Test func spokesStartUpAndGoRoundClockwise() {
        // The first spoke points up from the centre, the next a quarter turn on (y down: to the right).
        let cen = Point(100, 100)
        let up = Radar.spoke(cen, 50, 0, 4, 1)
        let right = Radar.spoke(cen, 50, 1, 4, 1)
        #expect(abs(up.x - 100) < 1e-9 && abs(up.y - 50) < 1e-9, "\(up)")
        #expect(abs(right.x - 150) < 1e-9 && abs(right.y - 100) < 1e-9, "\(right)")
        // No spokes: no division by zero.
        #expect(Radar.spoke(cen, 50, 0, 0, 1).y.isFinite)
    }
}
