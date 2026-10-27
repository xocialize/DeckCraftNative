// DCRender — tables: cell fills from the table style (or overrides), borders, and cell text. Port of
// deckcraft crates/render/src/table.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel
import DCText
import Synchronization

/// Style colours for a cell: fill, text colour, bold and borders.
public struct CellLook: Sendable, Equatable {
    public var fill: Rgba?
    public var text: Rgba?
    public var bold: Bool
    public var border: Pair<Rgba, Double>?
    /// Left, right, top and bottom borders from a file-defined style (a fully transparent colour means no
    /// border); nil falls back to `border`.
    public var sides: [Pair<Rgba, Double>?]
    /// A file-defined style's fill as a paint (gradients, see-through colours), with its placeholder colour;
    /// drawn instead of `fill`.
    public var paint: Pair<Fill, Rgba?>?

    init(fill: Rgba?, text: Rgba?, bold: Bool, border: (Rgba, Double)?) {
        self.fill = fill
        self.text = text
        self.bold = bold
        self.border = border.map { Pair($0.0, $0.1) }
        sides = [nil, nil, nil, nil]
        paint = nil
    }
}

/// Which parts of the table a cell sits in, for the preset styles.
private struct PresetPart {
    var header: Bool
    var total: Bool
    var firstCol: Bool
    var lastCol: Bool
    var banded: Bool

    /// In a header, total, first or last column: the parts a preset style makes strong.
    var strong: Bool { header || total || firstCol || lastCol }
}

/// Tables (table.rs).
public enum TableRender {
    /// Counts the cells whose text `draw` lays out, for tests that check off-slide cells are skipped
    /// (deckcraft's thread-local `TEXT_CELLS_DRAWN`; task-local here so parallel tests don't share it).
    @TaskLocal static var textCellsDrawn: TextCellCounter?

    final class TextCellCounter: Sendable {
        let n = Mutex(0)
        var value: Int { n.withLock { $0 } }
    }

    static func accent(_ ctx: Resolve.Ctx, _ style: String) -> Rgba {
        let last = style.split(separator: "-", omittingEmptySubsequences: false).last.map(String.init) ?? "accent1"
        let slot: SchemeSlot = switch last {
        case "accent2": .accent2
        case "accent3": .accent3
        case "accent4": .accent4
        case "accent5": .accent5
        case "accent6": .accent6
        case "tx1": .tx1
        default: .accent1
        }
        return ctx.color(.scheme(slot), nil)
    }

    /// The look of cell (`r`, `c`) from a table style the file defines: each part that applies to the cell
    /// (whole table, bands, first and last rows and columns, corners, in that order) sets the fill, text and
    /// the borders on its region's edges (its inside lines within it).
    static func lookDef(_ ctx: Resolve.Ctx, _ def: TableStyleDef, _ t: Table, _ r: Int, _ c: Int) -> CellLook {
        let (rows, cols) = (t.rows.count, t.cols.count)
        let spans = t.cell(r, c).map { cell in
            (satAdd(r, Int(Swift.max(cell.rowSpan, 1))) - 1, satAdd(c, Int(Swift.max(cell.gridSpan, 1))) - 1)
        } ?? (r, c)
        let lastR = Swift.max(rows - 1, 0)
        let lastC = Swift.max(cols - 1, 0)
        let (r1, c1) = (Swift.min(spans.0, lastR), Swift.min(spans.1, lastC))
        let header = t.firstRow && r == 0
        let total = t.lastRow && r1 == lastR && rows > 1
        let firstCol = t.firstCol && c == 0
        let lastCol = t.lastCol && c1 == lastC && cols > 1
        let bodyR = Swift.max(r - (t.firstRow ? 1 : 0), 0)
        let bodyC = Swift.max(c - (t.firstCol ? 1 : 0), 0)
        var look = CellLook(fill: nil, text: nil, bold: false, border: nil)
        for part in TablePart.all {
            // (applies, region rows, region cols)
            let (on, region): (Bool, (Int, Int, Int, Int)) = switch part {
            case .wholeTbl: (true, (0, lastR, 0, lastC))
            case .band1H: (t.bandRow && !header && !total && bodyR % 2 == 0, (r, r1, 0, lastC))
            case .band2H: (t.bandRow && !header && !total && bodyR % 2 == 1, (r, r1, 0, lastC))
            case .band1V: (t.bandCol && !firstCol && !lastCol && bodyC % 2 == 0, (0, lastR, c, c1))
            case .band2V: (t.bandCol && !firstCol && !lastCol && bodyC % 2 == 1, (0, lastR, c, c1))
            case .lastCol: (lastCol, (0, lastR, c, lastC))
            case .firstCol: (firstCol, (0, lastR, 0, c1))
            case .lastRow: (total, (r, lastR, 0, lastC))
            case .firstRow: (header, (0, r1, 0, lastC))
            case .seCell: (total && lastCol, (r, r1, c, c1))
            case .swCell: (total && firstCol, (r, r1, c, c1))
            case .neCell: (header && lastCol, (r, r1, c, c1))
            case .nwCell: (header && firstCol, (r, r1, c, c1))
            }
            if !on { continue }
            guard let ps = def.part(part) else { continue }
            if let p = styleFill(ctx, ps) {
                look.fill = fillColor(ctx, p.0, p.1)
                look.paint = Pair(p.0, p.1)
            }
            if let tc = ps.textColor { look.text = ctx.color(tc, nil) }
            if let b = ps.bold { look.bold = b }
            let (r0, rr1, c0, cc1) = region
            // Left, right, top, bottom of the cell: the part's edge or its inside line.
            let pick = [c == c0 ? 0 : 5, c1 == cc1 ? 1 : 5, r == r0 ? 2 : 4, r1 == rr1 ? 3 : 4]
            for (side, i) in pick.enumerated() {
                if let b = ps.borders.at(i) ?? nil, look.sides.indices.contains(side) {
                    let bl = borderLook(ctx, b)
                    look.sides[side] = Pair(bl.0, bl.1)
                }
            }
        }
        return look
    }

    /// A style part's fill, a theme fill reference resolved to the theme's fill with its colour as the
    /// placeholder colour.
    static func styleFill(_ ctx: Resolve.Ctx, _ ps: TablePartStyle) -> (Fill, Rgba?)? {
        if let fr = ps.fillRef {
            let (idx, col) = (fr.a, fr.b)
            let ph = ctx.color(col, nil)
            if idx == 0 { return (.none_, nil) }
            if let f = ctx.master.theme.format.fills.at(Int(idx) - 1) { return (f, ph) }
            return (.solid(.rgb(ph)), nil)
        }
        return ps.fill.map { ($0, nil) }
    }

    /// A fill's colour for a table cell (gradients and pictures by their first colour).
    static func fillColor(_ ctx: Resolve.Ctx, _ f: Fill, _ ph: Rgba?) -> Rgba? {
        switch f {
        case .none_: .transparent
        case .solid(let c): ctx.color(c, ph)
        case .gradient(let g): g.stops.first.map { ctx.color($0.color, ph) }
        case .pattern(let p): ctx.color(p.bg, ph)
        default: nil
        }
    }

    /// A style border's colour and width (a transparent colour for no line).
    static func borderLook(_ ctx: Resolve.Ctx, _ b: TableBorder) -> (Rgba, Double) {
        switch b {
        case .line(let line):
            switch line.fill {
            case .solid(let c)?: return (ctx.color(c, nil), line.width ?? 0.75)
            case .gradient(let g)?: return (g.stops.first.map { ctx.color($0.color, nil) } ?? .black, line.width ?? 0.75)
            default: return (.transparent, 0)
            }
        case .ref(let idx, let color):
            let w = ctx.master.theme.format.lines.at(Swift.max(Int(idx) - 1, 0))?.width ?? 0.75
            return idx == 0 ? (.transparent, 0) : (ctx.color(color, nil), w)
        }
    }

    /// The file-defined table style a table names (matched ignoring ASCII case), if any.
    public static func resolveStyle(_ ctx: Resolve.Ctx, _ t: Table) -> TableStyleDef? {
        ctx.pres.tableStyles.first { asciiLower($0.id) == asciiLower(t.style) }
    }

    public static func look(_ ctx: Resolve.Ctx, _ t: Table, _ r: Int, _ c: Int) -> CellLook {
        lookWithDef(ctx, resolveStyle(ctx, t), t, r, c)
    }

    /// Tint `k` of accent `a`.
    private static func tint(_ a: Rgba, _ k: Int32) -> Rgba { applyTransforms(a, [.tint(k)]) }

    private static func light1Look(_ a: Rgba, _ p: PresetPart, _ on: (Rgba) -> Rgba) -> CellLook {
        let fill = p.banded ? tint(a, 20000) : nil
        return CellLook(fill: fill, text: fill.map(on), bold: p.strong, border: p.header ? (a, 1) : nil)
    }

    private static func light2Look(_ a: Rgba, _ p: PresetPart) -> CellLook {
        CellLook(fill: p.header ? a : nil, text: p.header ? .white : nil, bold: p.header || p.total || p.firstCol, border: (a, 1))
    }

    private static func dark1Look(_ a: Rgba, _ p: PresetPart) -> CellLook {
        let fill: Rgba = p.header ? .black : p.banded ? applyTransforms(a, [.shade(60000)]) : applyTransforms(a, [.shade(75000)])
        return CellLook(fill: fill, text: .white, bold: p.header || p.total || p.firstCol, border: (.white, 1))
    }

    private static func medium4Look(_ a: Rgba, _ p: PresetPart, _ on: (Rgba) -> Rgba) -> CellLook {
        let fill = p.header || p.banded ? tint(a, 40000) : tint(a, 20000)
        return CellLook(fill: fill, text: on(fill), bold: p.strong, border: (a, 0.75))
    }

    /// medium2: strong header, banded light tints, white grid.
    private static func medium2Look(_ a: Rgba, _ p: PresetPart, _ on: (Rgba) -> Rgba) -> CellLook {
        let strong = p.strong
        let fill = strong ? a : p.banded ? tint(a, 40000) : tint(a, 20000)
        return CellLook(fill: fill, text: strong ? .white : on(fill), bold: strong, border: (.white, 1))
    }

    public static func lookWithDef(_ ctx: Resolve.Ctx, _ def: TableStyleDef?, _ t: Table, _ r: Int, _ c: Int) -> CellLook {
        if let def { return lookDef(ctx, def, t, r, c) }
        let a = accent(ctx, t.style)
        let kind = t.style.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? "medium2"
        let header = t.firstRow && r == 0
        let total = t.lastRow && r + 1 == t.rows.count
        let firstCol = t.firstCol && c == 0
        let lastCol = t.lastCol && c + 1 == t.cols.count
        // Rust's `r.wrapping_sub(1)` is odd at r = 0, as -1 % 2 is non-zero here (and a header anyway).
        let bodyR = t.firstRow ? r - 1 : r
        let band = t.bandRow && !header && !total && bodyR % 2 == 0
        let bandC = t.bandCol && c % 2 == 0
        let p = PresetPart(header: header, total: total, firstCol: firstCol, lastCol: lastCol, banded: band || bandC)
        let textColor = ctx.color(.scheme(.tx1), nil)
        // Text on a tinted cell never inherits the text colour, which a dark theme makes light and
        // unreadable on the light tint: PowerPoint's medium styles set it to the theme's dark colour (dk1).
        // A dark theme may keep that in dk1 and map tx1 away from it, or (Nocturne) put it in lt1, so of the
        // two the one contrasting more with the cell's fill is used.
        let dk1 = ctx.color(.scheme(.dk1), nil)
        let lt1 = ctx.color(.scheme(.lt1), nil)
        let on = { (fill: Rgba) -> Rgba in dk1.contrast(fill) >= lt1.contrast(fill) ? dk1 : lt1 }
        switch kind {
        case "none": return CellLook(fill: nil, text: nil, bold: false, border: nil)
        case "grid": return CellLook(fill: nil, text: nil, bold: false, border: (textColor, 0.75))
        case "light1": return light1Look(a, p, on)
        case "light2": return light2Look(a, p)
        case "dark1": return dark1Look(a, p)
        case "medium4": return medium4Look(a, p, on)
        default: return medium2Look(a, p, on)
        }
    }

    /// Running edges 0, s0, s0+s1, … of a list of sizes (negative sizes count as 0).
    static func edges(_ sizes: [Double]) -> [Double] {
        var out = [0.0]
        var acc = 0.0
        for s in sizes {
            acc += s.rustMax(0)
            out.append(acc)
        }
        return out
    }

    /// A cell's text as drawn: its margins, anchor and direction, plus the table style's text colour and bold.
    public static func cellBody(_ rctx: Resolve.Ctx, _ t: Table, _ r: Int, _ c: Int, _ cell: Cell) -> TextBody {
        cellBodyWithDef(rctx, resolveStyle(rctx, t), t, r, c, cell)
    }

    public static func cellBodyWithDef(_ rctx: Resolve.Ctx, _ def: TableStyleDef?, _ t: Table, _ r: Int, _ c: Int, _ cell: Cell) -> TextBody {
        let lk = lookWithDef(rctx, def, t, r, c)
        var body = cell.text
        // Rust destructures a `[f64; 4]`; a shorter list here falls back to the default for what's missing.
        let mg = cell.margins ?? [7.2, 7.2, 3.6, 3.6]
        body.body.insetL = mg.at(0) ?? 7.2
        body.body.insetR = mg.at(1) ?? 7.2
        body.body.insetT = mg.at(2) ?? 3.6
        body.body.insetB = mg.at(3) ?? 3.6
        body.body.anchor = cell.anchor ?? .top
        if cell.vertical != nil { body.body.vert = cell.vertical }
        for pi in body.paragraphs.indices {
            for ri in body.paragraphs[pi].runs.indices {
                if body.paragraphs[pi].runs[ri].props.fill == nil, let tc = lk.text {
                    body.paragraphs[pi].runs[ri].props.fill = .solid(.rgb(tc))
                }
                if lk.bold && body.paragraphs[pi].runs[ri].props.bold == nil {
                    body.paragraphs[pi].runs[ri].props.bold = true
                }
            }
        }
        return body
    }

    /// Heights the rows are drawn at. A stored row height (`a:tr/@h`) is a minimum: the row grows so the
    /// text of each of its cells fits, as in PowerPoint. Files from pandoc or python-pptx store 0. Cells
    /// spanning several rows and vertical text keep the stored height.
    public static func rowHeights(_ rctx: Resolve.Ctx, _ t: Table, _ fields: any TextFields) -> [Double] {
        rowHeightsWithDef(rctx, resolveStyle(rctx, t), t, fields)
    }

    /// `rowHeights` with the table's style already resolved, for a caller that needs it too.
    static func rowHeightsWithDef(_ rctx: Resolve.Ctx, _ styleDef: TableStyleDef?, _ t: Table, _ fields: any TextFields) -> [Double] {
        let xs = edges(t.cols)
        var out: [Double] = []
        out.reserveCapacity(t.rows.count)
        for (ri, row) in t.rows.enumerated() {
            var h = row.height.rustMax(0)
            for (ci, cell) in row.cells.prefix(t.cols.count).enumerated() {
                if cell.isCovered || cell.rowSpan > 1 || !(cell.vertical == nil || cell.vertical == .horizontal) { continue }
                let c1 = Swift.min(satAdd(ci, Int(Swift.max(cell.gridSpan, 1))), t.cols.count)
                guard let x0 = xs.at(ci), let x1 = xs.at(c1) else { continue }
                let body = cellBodyWithDef(rctx, styleDef, t, ri, ci, cell)
                let tmp = Shape.tableCell(body)
                let need = TextLayoutEngine.fitHeight(rctx, tmp, body, Rect(x0, 0, x1, h.rustMax(1)), fields)
                if need.isFinite { h = h.rustMax(need.rustMin(20000)) }
            }
            out.append(h)
        }
        return out
    }

    /// Cell rectangles in table-local space, honouring merges: (row, col, rect) for visible cells. `heights`
    /// are the drawn row heights (`rowHeights`).
    public static func cellRects(_ t: Table, _ heights: [Double]) -> [(Int, Int, Rect)] {
        var out: [(Int, Int, Rect)] = []
        let xs = edges(t.cols)
        let ys = edges(heights)
        for (ri, row) in t.rows.enumerated() {
            for (ci, cell) in row.cells.prefix(t.cols.count).enumerated() {
                if cell.isCovered { continue }
                let c1 = Swift.min(satAdd(ci, Int(Swift.max(cell.gridSpan, 1))), t.cols.count)
                let r1 = Swift.min(satAdd(ri, Int(Swift.max(cell.rowSpan, 1))), t.rows.count)
                guard let x0 = xs.at(ci), let x1 = xs.at(c1), let y0 = ys.at(ri), let y1 = ys.at(r1) else { continue }
                out.append((ri, ci, Rect(x0, y0, x1, y1)))
            }
        }
        return out
    }

    /// Can a cell's text be left undrawn because it lands wholly outside the `target` (pixels)? Only for
    /// cells whose text stays inside the cell: its row grew to fit it (one row, horizontal text, not at the
    /// height cap), so nothing overflows. A margin covers italic overhang and the like. A table of thousands
    /// of rows otherwise lays out every cell's text off the slide's bottom.
    static func textOffTarget(_ cell: Cell, _ rect: Rect, _ m: Affine, _ target: (Int, Int)) -> Bool {
        if cell.rowSpan > 1 || !(cell.vertical == nil || cell.vertical == .horizontal) || rect.height >= 20000 { return false }
        let b = m.transformRectBBox(rect).inflate(64, 64)
        let view = Rect(0, 0, Double(target.0), Double(target.1))
        return b.isFinite && (b.x1 < view.x0 || b.y1 < view.y0 || b.x0 > view.x1 || b.y0 > view.y1)
    }

    /// Draws the table; returns the box its cells cover (table space), which grows with their text.
    @discardableResult
    public static func draw(
        _ c: Canvas, _ pres: Presentation, _ rctx: Resolve.Ctx, _ t: Table, _ m: Affine, _ w: Double, _ h: Double,
        _ fields: any TextFields, _ editing: Bool
    ) -> Rect? {
        let styleDef = resolveStyle(rctx, t)
        let rects = cellRects(t, rowHeightsWithDef(rctx, styleDef, t, fields))
        let covered = rects.map(\.2).reduce(nil as Rect?) { acc, r in acc.map { $0.union(r) } ?? r }
        let styleBg = styleDef?.background.flatMap { styleFill(rctx, $0) }
        let ownBg = t.background.map { ($0, nil as Rgba?) }
        if let all = covered {
            for (bg, ph) in [styleBg, ownBg].compactMap({ $0 }) {
                c.setTransform(m)
                PaintFill.fillPath(c, rctx, bg, ph, rectPath(all), all, m, .norm, 1, rctx.pres)
            }
        }
        for (r, col, rect) in rects {
            guard let cell = t.cell(r, col) else { continue }
            let lk = lookWithDef(rctx, styleDef, t, r, col)
            c.setTransform(m)
            if let f = cell.fill {
                PaintFill.fillPath(c, rctx, f, nil, rectPath(rect), rect, m, .norm, 1, rctx.pres)
            } else if let p = lk.paint {
                PaintFill.fillPath(c, rctx, p.a, p.b, rectPath(rect), rect, m, .norm, 1, rctx.pres)
            } else if let fc = lk.fill, fc.a > 0 {
                c.setPaint(.color(fc, 1))
                c.fillRect(rect)
            }
        }
        // Diagonal borders, under the edges: drawn like any line (dashes, compound, caps).
        for (r, col, rect) in rects {
            guard let cell = t.cell(r, col) else { continue }
            let diags = [(cell.diagDown, Point(rect.x0, rect.y0), Point(rect.x1, rect.y1)), (cell.diagUp, Point(rect.x0, rect.y1), Point(rect.x1, rect.y0))]
            for (line, a, b) in diags {
                guard let l = line, let f = l.fill, !f.isNone else { continue }
                var p = BezPath()
                p.moveTo(a)
                p.lineTo(b)
                strokeLine(c, rctx, l, nil, p, nil, m, (l.width ?? 1).rustMax(0), 1)
            }
        }
        // Borders: explicit cell borders, else the style's grid.
        for (r, col, rect) in rects {
            guard let cell = t.cell(r, col) else { continue }
            let lk = lookWithDef(rctx, styleDef, t, r, col)
            let sides = [
                (rect.x0, rect.y0, rect.x0, rect.y1),
                (rect.x1, rect.y0, rect.x1, rect.y1),
                (rect.x0, rect.y0, rect.x1, rect.y0),
                (rect.x0, rect.y1, rect.x1, rect.y1),
            ]
            for (i, e) in sides.enumerated() {
                var p = BezPath()
                p.moveTo(Point(e.0, e.1))
                p.lineTo(Point(e.2, e.3))
                // An explicit border is drawn like any line: dashed, compound, gradient.
                if let l = cell.borders.at(i) ?? nil {
                    if let f = l.fill, !f.isNone {
                        strokeLine(c, rctx, l, nil, p, nil, m, (l.width ?? 1).rustMax(0.25), 1)
                    }
                    continue
                }
                guard let b = (lk.sides.at(i) ?? nil) ?? lk.border, b.a.a > 0, b.b > 0 else { continue }
                c.setTransform(m)
                c.setPaint(.color(b.a, 1))
                c.setStroke(StrokeStyle(b.b.rustMax(0.25)))
                c.strokePath(p)
            }
        }
        // Text.
        for (r, col, rect) in rects {
            guard let cell = t.cell(r, col) else { continue }
            if (cell.text.isEmpty && !editing) || textOffTarget(cell, rect, m, (c.width, c.height)) { continue }
            let body = cellBodyWithDef(rctx, styleDef, t, r, col, cell)
            let tmp = Shape.tableCell(body)
            textCellsDrawn?.n.withLock { $0 += 1 }
            var l = TextLayoutEngine.layout(rctx, tmp, body, TextOpts(rect: rect, fields: fields, promptColor: nil, noShrink: false))
            if editing { previewEmptyBullets(&l) }
            drawLayout(c, l, rect, m)
        }
        return covered
    }
}

/// `a + b` saturating at `Int.max`, as Rust's `usize::saturating_add`.
private func satAdd(_ a: Int, _ b: Int) -> Int {
    let (v, overflow) = a.addingReportingOverflow(b)
    return overflow ? .max : v
}

/// ASCII-only lowercasing, for Rust's `eq_ignore_ascii_case`.
private func asciiLower(_ s: String) -> [UInt8] {
    s.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
}
