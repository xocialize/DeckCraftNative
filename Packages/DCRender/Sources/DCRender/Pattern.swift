// DCRender — preset pattern fills (`a:pattFill`): an 8×8 two-colour tile, each cell one 96-dpi pixel
// (0.75 pt) of the slide, as PowerPoint draws them. Port of deckcraft crates/render/src/pattern.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// The tiles were read from PowerPoint's own slide export of every preset (black on white, at exactly two
// output pixels per pattern pixel), so the marks, their density and their phase match it. Bit 7 of each
// row is the leftmost cell; a set bit is the foreground colour.
import DCColor
import DCCore
import DCGeometry

public enum Pattern {
    /// Side of one pattern cell, in points.
    public static let cell = 0.75

    static let tiles: [(String, [UInt8])] = [
        ("pct5", [0x80, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00]),
        ("pct10", [0x80, 0x00, 0x08, 0x00, 0x80, 0x00, 0x08, 0x00]),
        ("pct20", [0x88, 0x00, 0x22, 0x00, 0x88, 0x00, 0x22, 0x00]),
        ("pct25", [0x88, 0x22, 0x88, 0x22, 0x88, 0x22, 0x88, 0x22]),
        ("pct30", [0xAA, 0x44, 0xAA, 0x11, 0xAA, 0x44, 0xAA, 0x11]),
        ("pct40", [0xAA, 0x55, 0xAA, 0x51, 0xAA, 0x55, 0xAA, 0x15]),
        ("pct50", [0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55]),
        ("pct60", [0xEE, 0x55, 0xBB, 0x55, 0xEE, 0x55, 0xBB, 0x55]),
        ("pct70", [0x77, 0xDD, 0x77, 0xDD, 0x77, 0xDD, 0x77, 0xDD]),
        ("pct75", [0x77, 0xFF, 0xDD, 0xFF, 0x77, 0xFF, 0xDD, 0xFF]),
        ("pct80", [0xEF, 0xFF, 0xFE, 0xFF, 0xEF, 0xFF, 0xFE, 0xFF]),
        ("pct90", [0xFF, 0xFF, 0xFF, 0xF7, 0xFF, 0xFF, 0xFF, 0x7F]),
        ("horz", [0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
        ("vert", [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80]),
        ("ltHorz", [0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00]),
        ("ltVert", [0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88]),
        ("dkHorz", [0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00]),
        ("dkVert", [0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC]),
        ("narHorz", [0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00]),
        ("narVert", [0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55]),
        ("dashHorz", [0xF0, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x00, 0x00]),
        ("dashVert", [0x80, 0x80, 0x80, 0x80, 0x08, 0x08, 0x08, 0x08]),
        ("cross", [0xFF, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80]),
        ("dnDiag", [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01]),
        ("upDiag", [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80]),
        ("ltDnDiag", [0x88, 0x44, 0x22, 0x11, 0x88, 0x44, 0x22, 0x11]),
        ("ltUpDiag", [0x11, 0x22, 0x44, 0x88, 0x11, 0x22, 0x44, 0x88]),
        ("dkDnDiag", [0xCC, 0x66, 0x33, 0x99, 0xCC, 0x66, 0x33, 0x99]),
        ("dkUpDiag", [0x33, 0x66, 0xCC, 0x99, 0x33, 0x66, 0xCC, 0x99]),
        ("wdDnDiag", [0xC1, 0xE0, 0x70, 0x38, 0x1C, 0x0E, 0x07, 0x83]),
        ("wdUpDiag", [0x83, 0x07, 0x0E, 0x1C, 0x38, 0x70, 0xE0, 0xC1]),
        ("dashDnDiag", [0x00, 0x00, 0x88, 0x44, 0x22, 0x11, 0x00, 0x00]),
        ("dashUpDiag", [0x00, 0x00, 0x11, 0x22, 0x44, 0x88, 0x00, 0x00]),
        ("diagCross", [0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81]),
        ("smCheck", [0x99, 0x66, 0x66, 0x99, 0x99, 0x66, 0x66, 0x99]),
        ("lgCheck", [0xF0, 0xF0, 0xF0, 0xF0, 0x0F, 0x0F, 0x0F, 0x0F]),
        ("smGrid", [0xFF, 0x88, 0x88, 0x88, 0xFF, 0x88, 0x88, 0x88]),
        ("lgGrid", [0xFF, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80]),
        ("dotGrid", [0xAA, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00]),
        ("smConfetti", [0x80, 0x08, 0x40, 0x02, 0x10, 0x01, 0x20, 0x04]),
        ("lgConfetti", [0xB1, 0x30, 0x03, 0x1B, 0xD8, 0xC0, 0x0C, 0x8D]),
        ("horzBrick", [0xFF, 0x80, 0x80, 0x80, 0xFF, 0x08, 0x08, 0x08]),
        ("diagBrick", [0x01, 0x02, 0x04, 0x08, 0x18, 0x24, 0x42, 0x81]),
        ("solidDmnd", [0x10, 0x38, 0x7C, 0xFE, 0x7C, 0x38, 0x10, 0x00]),
        ("openDmnd", [0x82, 0x44, 0x28, 0x10, 0x28, 0x44, 0x82, 0x01]),
        ("dotDmnd", [0x80, 0x00, 0x22, 0x00, 0x08, 0x00, 0x22, 0x00]),
        ("plaid", [0xAA, 0x55, 0xAA, 0x55, 0xF0, 0xF0, 0xF0, 0xF0]),
        ("sphere", [0x77, 0x89, 0x8F, 0x8F, 0x77, 0x98, 0xF8, 0xF8]),
        ("weave", [0x88, 0x54, 0x22, 0x45, 0x88, 0x14, 0x22, 0x51]),
        ("divot", [0x00, 0x10, 0x08, 0x10, 0x00, 0x80, 0x01, 0x80]),
        ("shingle", [0x03, 0x84, 0x48, 0x30, 0x0C, 0x02, 0x01, 0x01]),
        ("wave", [0x00, 0x18, 0x25, 0xC0, 0x00, 0x18, 0x25, 0xC0]),
        ("trellis", [0xFF, 0x66, 0xFF, 0x99, 0xFF, 0x66, 0xFF, 0x99]),
        ("zigZag", [0x81, 0x42, 0x24, 0x18, 0x81, 0x42, 0x24, 0x18]),
    ]

    /// Every preset name, in the order of the tiles.
    public static var presets: [String] { tiles.map(\.0) }

    /// The 8×8 tile of preset `name` (`pct50` for an unknown name).
    public static func tile(_ name: String) -> [UInt8] {
        tiles.first { rustEqual($0.0, name) }?.1
            ?? tiles.first { $0.0 == "pct50" }?.1
            ?? [0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55]
    }

    /// Is cell (`x`, `y`) of the tile the foreground?
    public static func isFg(_ tile: [UInt8], _ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, let row = tile.at(y % 8) else { return false }
        return row & (UInt8(0x80) >> UInt8(x % 8)) != 0
    }

    static func premul(_ c: Rgba, _ alpha: Double) -> [UInt8] {
        let a = (Double(c.a) * alpha.clamped(0.0, 1.0)).rounded().clamped(0.0, 255.0)
        func m(_ v: UInt8) -> UInt8 { UInt8(rustCast: (Double(v) * a / 255.0).rounded().clamped(0.0, 255.0)) }
        return [m(c.r), m(c.g), m(c.b), UInt8(rustCast: a)]
    }

    /// Fill `path` (in the space `m` maps to the output) with preset `name` in `fg` on `bg`, faded by
    /// `alpha`.
    public static func fill(_ c: Canvas, _ name: String, _ fg: Rgba, _ bg: Rgba, _ alpha: Double, _ path: BezPath, _ m: Affine) {
        let det = m.determinant
        if !det.isFinite || Swift.abs(det) <= 1e-12 { return }
        let t = tile(name)
        let (f, b) = (premul(fg, alpha), premul(bg, alpha))
        // Cells are laid out on the output from its origin (the slide's top-left corner), so
        // neighbouring shapes' patterns line up, as in PowerPoint.
        var k = scaleOf(m)
        if !(k.isFinite && k > 0.0) { k = 1.0 }
        let side = cell * k
        c.setTransform(m)
        // Sampled bilinearly, as PowerPoint samples the tile (and vello): exact at a whole number of
        // output pixels per cell; between, a pixel straddling two cells takes a blend of both. CoreGraphics
        // averages the area instead when it shrinks an image, so the pattern is sampled here, into an
        // image of the output pixels the path covers, drawn one to one.
        if let (x0, y0, w, h) = coverage(c, transformed(path, m).boundingBox), side.isFinite, side > 0 {
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let fc = SIMD4<Double>(f.map(Double.init)), bc = SIMD4<Double>(b.map(Double.init))
            let grid = (0 ..< 64).map { isFg(t, $0 % 8, $0 / 8) ? fc : bc }
            func cellColor(_ i: Int, _ j: Int) -> SIMD4<Double> { grid[(((j % 8) + 8) % 8) * 8 + ((i % 8) + 8) % 8] }
            for y in 0 ..< h {
                let v = (Double(y0 + y) + 0.5) / side - 0.5
                let j0 = Int(rustCast: v.rounded(.down))
                let fy = v - Double(j0)
                for x in 0 ..< w {
                    let u = (Double(x0 + x) + 0.5) / side - 0.5
                    let i0 = Int(rustCast: u.rounded(.down))
                    let fx = u - Double(i0)
                    let top = cellColor(i0, j0) + (cellColor(i0 + 1, j0) - cellColor(i0, j0)) * fx
                    let bottom = cellColor(i0, j0 + 1) + (cellColor(i0 + 1, j0 + 1) - cellColor(i0, j0 + 1)) * fx
                    let px = top + (bottom - top) * fy
                    let o = (y * w + x) * 4
                    for ch in 0 ..< 4 { data[o + ch] = UInt8(rustCast: px[ch].rounded().clamped(0, 255)) }
                }
            }
            if let image = RenderImage(width: w, height: h, pixels: data).cgImage() {
                c.setPaint(.image(image, xExtend: .pad, yExtend: .pad, quality: .low, alpha: 1.0))
                c.setPaintTransform(m.inverse * Affine.translate(Vec2(Double(x0), Double(y0))))
                c.fillPath(path)
                c.resetPaintTransform()
                return
            }
        }
        // Too large to sample (or unbounded): CoreGraphics' own sampling of the repeated tile.
        var data: [UInt8] = []
        data.reserveCapacity(64 * 4)
        for i in 0 ..< 64 { data += isFg(t, i % 8, i / 8) ? f : b }
        guard let image = RenderImage(width: 8, height: 8, pixels: data).cgImage() else { return }
        c.setPaint(.image(image, xExtend: .repeat, yExtend: .repeat, quality: .medium, alpha: 1.0))
        c.setPaintTransform(m.inverse * Affine.scale(side))
        c.fillPath(path)
        c.resetPaintTransform()
    }

    /// Largest number of output pixels sampled for one pattern fill.
    static let maxSampled = 16 << 20

    /// The output pixels (`x0`, `y0`, width, height) a device-space box covers on the canvas, or nil when
    /// it covers none or more than `maxSampled`.
    static func coverage(_ c: Canvas, _ box: Rect) -> (Int, Int, Int, Int)? {
        guard box.isFinite else { return nil }
        let x0 = max(Int(rustCast: box.minX.rounded(.down)) - 1, 0)
        let y0 = max(Int(rustCast: box.minY.rounded(.down)) - 1, 0)
        let x1 = min(Int(rustCast: box.maxX.rounded(.up)) + 1, c.width)
        let y1 = min(Int(rustCast: box.maxY.rounded(.up)) + 1, c.height)
        guard x1 > x0, y1 > y0, (x1 - x0) * (y1 - y0) <= maxSampled else { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }
}
