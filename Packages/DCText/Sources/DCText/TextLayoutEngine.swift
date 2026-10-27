// DCText — the entry points: lay out a shape's text body (lines, spacing, alignment, bullets, columns,
// anchoring, autofit shrink, vertical text, decorations), and the heights and widths that fit it. Port of
// deckcraft crates/text/src/lib.rs (`layout`, `layout_scaled`, `merge_decos`, `kashida_opportunities`,
// `fit_height`, `fit_width`; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCGeometry
import DCModel
import Synchronization

public enum TextLayoutEngine {
    /// Counts layout passes (tests count autofit's passes).
    final class PassCounter: Sendable {
        let count = Mutex(0)
    }

    @TaskLocal static var passCounter: PassCounter?

    /// Lay out a shape's text body in `opts.rect`, shrinking it on overflow when the body asks for it.
    public static func layout(_ ctx: Resolve.Ctx, _ shape: Shape, _ body: TextBody, _ opts: TextOpts) -> TextLayout {
        let bp = Resolve.body(ctx, shape)
        let autofit = bp.autofit ?? .none_
        // Shrink on overflow starts from the scale the file was saved with (`fontScale`, `lnSpcReduction`),
        // which is what PowerPoint draws; editing the text resets it.
        var scale0 = 1.0
        var reduce0 = 0.0
        var noSavedScale = false
        var shrink = false
        if case .shrink(let fontScale, let lineReduction) = autofit, !opts.noShrink {
            shrink = true
            scale0 = fontScale.flatMap { $0.isFinite ? $0.clamped(0.1, 1) : nil } ?? 1
            reduce0 = lineReduction.isFinite ? lineReduction.clamped(0, 0.2) : 0
            noSavedScale = fontScale == nil
        }
        var l = layoutScaled(ctx, shape, body, bp, opts, scale0, reduce0)
        // A scale PowerPoint saved is drawn as it is: PowerPoint fits the text again only when it changes,
        // not when a file opens. A body whose file has no `fontScale` at all is the schema default 100 % and
        // is drawn as it is too.
        let saved = noSavedScale || scale0 < 1 || reduce0 > 0
        if shrink && l.overflow && !saved {
            // Text that overflows even at the smallest scale gets that scale.
            let smallest = layoutScaled(ctx, shape, body, bp, opts, 0.1, 0.2)
            if smallest.overflow { return smallest }
            // Binary search the largest scale that fits (steps like 90%, 80%… with line reduction).
            var (lo, hi) = (0.1, scale0)
            var best = smallest
            for _ in 0 ..< 12 {
                let mid = (lo + hi) / 2
                let red = ((1 - mid) * 0.8).rustMin(0.2).rustMax(reduce0)
                let t = layoutScaled(ctx, shape, body, bp, opts, mid, red)
                if t.overflow {
                    hi = mid
                } else {
                    lo = mid
                    best = t
                }
            }
            l = best
        }
        return l
    }

    private struct PendingLine {
        var info: LineInfo
        var place: LinePlace
        var bullet: (text: String, x: Double, baseline: Double)?
    }

    static func layoutScaled(_ ctx: Resolve.Ctx, _ shape: Shape, _ body: TextBody, _ bp: BodyProps, _ opts: TextOpts, _ scale: Double, _ reduce: Double) -> TextLayout {
        if let c = passCounter { c.count.withLock { $0 += 1 } }
        var r = opts.rect
        let vert = bp.vert ?? .horizontal
        // East Asian vertical text: CJK stands upright in text turned a quarter turn; stacked text stands
        // every character upright, one under the other.
        let uprightText: Upright = switch vert {
        case .eaVertical: .cjk
        case .stacked, .stackedRtl: .all
        default: .none_
        }
        // Mongolian vertical and stacked text: turned like vert, their lines run from left to right.
        let linesLTR = vert == .mongolianVertical || vert == .stacked
        let turn: Double = switch vert {
        case .vertical, .eaVertical, .stacked, .stackedRtl, .mongolianVertical: 90
        case .vertical270: 270
        case .horizontal: 0
        }
        let rotation = turn + (bp.rot ?? 0)
        // For vertical text, lay out in a box with swapped dimensions centred on the text rect.
        if abs(rotation - 90) < 1e-6 || abs(rotation - 270) < 1e-6 {
            let c = r.center
            r = Rect(c.x - r.height / 2, c.y - r.width / 2, c.x + r.height / 2, c.y + r.width / 2)
        }
        let inner = Rect(
            r.x0 + (bp.insetL ?? 7.2), r.y0 + (bp.insetT ?? 3.6),
            (r.x1 - (bp.insetR ?? 7.2)).rustMax(r.x0 + (bp.insetL ?? 7.2)), (r.y1 - (bp.insetB ?? 3.6)).rustMax(r.y0 + (bp.insetT ?? 3.6))
        )
        // Text that follows a WordArt arch or circle is set on one line per paragraph.
        let follow = bp.warp.map(Warp.isFollow) ?? false
        let shapeFit: Bool = if case .shape? = bp.autofit { true } else { false }
        let wrap = (bp.wrap ?? true) && !follow && !(shapeFit && shape.textBox && !(bp.wrap ?? true))
        let ncols = Int(Swift.min(Swift.max(bp.columns ?? 1, 1), 16))
        let colGap = (bp.colSpacing ?? 0).rustMax(0)
        let colW = ((inner.width - colGap * (Double(ncols) - 1)) / Double(ncols)).rustMax(1)

        var out = TextLayout()
        out.inner = inner
        out.fontScale = scale
        out.lineReduction = reduce
        out.rotation = rotation
        var y = 0.0
        var numbering = [UInt32](repeating: 0, count: 9)
        var allLines: [PendingLine] = []
        var prevAfter = 0.0
        // How far the last line's full pitch reaches past the text (exact spacing; see below).
        var tail = 0.0
        let firstLast = bp.spaceFirstLast ?? false
        var shapedParas: [ParaShaped] = []
        shapedParas.reserveCapacity(body.paragraphs.count)
        for (pi, para) in body.paragraphs.enumerated() {
            let lvl = Int(Swift.min(para.level, 8))
            let pp = Resolve.para(ctx, shape, para)
            let autoNum: Bool = if case .autoNum? = pp.bullet { true } else { false }
            let number: UInt32?
            if autoNum && !para.isEmpty {
                numbering[lvl] &+= 1
                for d in (lvl + 1) ..< 9 { numbering[d] = 0 }
                number = numbering[lvl]
            } else if autoNum {
                // Preview the next number without consuming it: empty paragraphs do not advance numbering.
                let (s, o) = numbering[lvl].addingReportingOverflow(1)
                number = o ? .max : s
            } else {
                if !para.isEmpty { for d in lvl ..< 9 { numbering[d] = 0 } }
                number = nil
            }
            shapedParas.append(shapePara(ctx, shape, body, pi, scale, opts, number, uprightText))
        }
        for (pi, p) in shapedParas.enumerated() {
            let props = p.props
            let margin = (props.marginLeft ?? 0).rustMax(0)
            let indent = props.indent ?? 0
            let mr = (props.marginRight ?? 0).rustMax(0)
            let bulletW = p.bullet.map { measureStr($0.style.face, $0.style.size, $0.text).width } ?? 0
            let firstX: Double
            if p.bullet != nil {
                let bx = (margin + indent).rustMax(0)
                // A hanging bullet's text starts at the margin. When the hang reaches left of the box
                // (marL + indent < 0), PowerPoint pins the bullet to the box's edge and keeps the hang.
                let stop = margin.rustMax(-indent)
                firstX = indent < 0 && bx + bulletW <= stop ? stop : bx + bulletW + (indent >= 0 ? 0 : 3)
            } else {
                firstX = (margin + indent).rustMax(0)
            }
            let restX = margin
            let tabs = tabsOf(props)
            let defaultTab = props.defaultTab ?? 72
            let firstW = (colW - firstX - mr).rustMax(1)
            let restW = (colW - restX - mr).rustMax(1)
            let raw = breakLines(p, firstW, restW, wrap, tabs, defaultTab, firstX, restX)
            // The first paragraph's space before counts only when the body says so.
            let before = pi == 0 && !firstLast ? 0 : spacingPts(props.spaceBefore, p.leadSize)
            y += before.rustMax(0) + prevAfter
            let firstLineIdx = allLines.count
            for (li, rl) in raw.enumerated() {
                // Line metrics: max ascent/descent over the line's styles (or the lead style if empty).
                var (asc, desc, size) = (0.0, 0.0, 0.0)
                if rl.end > rl.start {
                    for c in p.cells[rl.start ..< rl.end] {
                        guard let st = p.styles.at(c.style), let face = p.faces.at(c.face) else { continue }
                        let sz = st.size
                        // The run's own fonts set the line; a fallback face does not move the baseline.
                        let own = face === st.face
                            || [st.ea, st.cs, st.sym].compactMap { $0 }.contains { rustASCIILowercase(face.family) == rustASCIILowercase($0) }
                        let (a, d) = lineMetrics(own ? face : st.face, sz)
                        asc = asc.rustMax(a)
                        desc = desc.rustMax(d)
                        size = size.rustMax(sz)
                    }
                }
                if size == 0 {
                    // PowerPoint sizes an empty line by the mark that ends it: the `a:rPr` of the `a:br` that
                    // closes it, or `a:endParaRPr` for the paragraph's last line.
                    let face: FontFace
                    let sz: Double
                    if let c = p.cells.at(rl.end), c.ch == "\u{0B}", let st = p.styles.at(c.style) {
                        (face, sz) = (st.face, st.size)
                    } else if rl.end >= p.cells.count {
                        (face, sz) = (p.endFace, p.endSize)
                    } else {
                        (face, sz) = (p.leadFace, p.leadSize)
                    }
                    (asc, desc) = lineMetrics(face, sz)
                    size = sz
                }
                let natural = (asc + desc).rustMax(size * 1)
                let lh: Double = switch props.lineSpacing {
                // The reduction comes off the percentage (90 % less 20 % is 70 %).
                case .pct(let f)?: natural * (f - reduce).rustMax(f * 0.1).rustMax(0)
                case .pts(let v)?: v * (1 - reduce)
                case nil: natural * (1 - reduce)
                }
                let ratio = natural > 0 ? lh / natural : 1
                let top = y
                // Exact spacing (`spcPts`): the baseline sits at 80 % of the line pitch, and the text ends at
                // the last line's descent rather than a full pitch.
                let exact: Bool = if case .pts? = props.lineSpacing { true } else { false }
                let baseline = exact ? top + lh * 0.8 : top + asc * ratio
                tail = exact ? (lh * 0.2 - desc).rustMax(-lh) : 0
                y += lh
                let x0 = li == 0 ? firstX : restX
                let avail = (colW - x0 - mr).rustMax(0)
                let n = Swift.max(rl.end - rl.start, 0)
                let lineCells = n > 0 ? Array(p.cells[rl.start ..< rl.end]) : []
                // Logical advances; tabs measure from the start edge.
                var adv: [Double] = []
                adv.reserveCapacity(n)
                var x = 0.0
                // A line that breaks at a soft hyphen ends with a visible hyphen.
                let shyEnd = li + 1 < raw.count && lineCells.last?.ch == "\u{AD}"
                for (k, c) in lineCells.enumerated() {
                    let a: Double
                    if shyEnd && k + 1 == n {
                        if let f = p.faces.at(c.face), let st = p.styles.at(c.style) { a = measureStr(f, st.size, "-").width } else { a = 0 }
                    } else if c.ch == "\t" {
                        a = tabAdvance(x0 + x, tabs, defaultTab, tabSegment(p.cells, rl.start + k))
                    } else {
                        a = c.adv
                    }
                    adv.append(a)
                    x += a
                }
                let width = x
                let align = props.align ?? .left
                let lastLine = li + 1 == raw.count
                let slack = (avail - width).rustMax(0)
                // Justification: kashida (justLow, Arabic), spaces, or every character.
                let stretch = !lastLine && wrap && slack > 0
                var kashida = [Double](repeating: 0, count: n)
                var filled = false
                if stretch && align == .justLow {
                    let ops = kashidaOpportunities(p, rl.start, rl.end)
                    if !ops.isEmpty {
                        let each = slack / Double(ops.count)
                        for k in ops where k < n {
                            kashida[k] = each
                            adv[k] += each
                        }
                        filled = true
                    }
                }
                if stretch && !filled && (align == .justify || align == .justLow) {
                    let spaces = lineCells.filter { $0.ch == " " }.count
                    if spaces > 0 {
                        for k in 0 ..< n where lineCells[k].ch == " " { adv[k] += slack / Double(spaces) }
                        filled = true
                    }
                }
                if align == .distributed && n > 1 {
                    for k in 0 ..< n - 1 { adv[k] += slack / Double(n - 1) }
                    filled = true
                }
                let lineW = adv.reduce(0, +)
                // The line box, in column coordinates: the start edge is the left one for LTR and the right
                // one for RTL paragraphs.
                let (boxL, boxR) = p.rtl ? (mr, colW - x0) : (x0, colW - mr)
                let left: Double
                if filled {
                    left = boxL
                } else {
                    switch align {
                    case .left: left = boxL
                    case .right: left = boxR - lineW
                    case .center: left = boxL + (boxR - boxL - lineW) / 2
                    case .distributed where n <= 1: left = boxL + slack / 2
                    // Justified lines that aren't stretched (the last one) sit at the start edge.
                    case .justify, .justLow, .distributed: left = p.rtl ? boxR - lineW : boxL
                    }
                }
                // Distance from the box's start edge to the text (bullets move with centred or end-aligned text).
                let contentShift = p.rtl ? boxR - (left + lineW) : left - boxL
                // Rules L1 + L2: this line's visual order.
                let levels = Bidi.lineLevels(lineCells.map(\.ch), lineCells.map(\.level), p.rtl ? 1 : 0)
                let order = Bidi.visualOrder(levels)
                var edges = [(left: Double, right: Double)](repeating: (left, left), count: n)
                var vx = left
                for k in order where k < n {
                    let a = adv[k]
                    edges[k] = (vx, vx + a)
                    vx += a
                }
                func odd(_ k: Int) -> Bool { (levels.at(k) ?? 0) % 2 == 1 }
                var caretX = (0 ..< n).map { k in odd(k) ? edges[k].right : edges[k].left }
                if n > 0 {
                    caretX.append(odd(n - 1) ? edges[n - 1].left : edges[n - 1].right)
                } else {
                    caretX.append(p.rtl ? left + lineW : left)
                }
                var bullet: (text: String, x: Double, baseline: Double)?
                if li == 0, let (s, _) = p.bullet {
                    // Centred and end-aligned text carries its bullet along.
                    let endAligned = p.rtl ? align == .left : align == .right
                    let shifted = align == .center || endAligned
                    let b = shifted && p.cells.isEmpty ? contentShift + x0 - bulletW : (margin + indent).rustMax(0) + (shifted ? contentShift : 0)
                    // x_bullet = S - (marL + indent) for RTL: the bullet's start edge is its right.
                    bullet = (s, p.rtl ? colW - b - bulletW : b, baseline)
                }
                out.contentWidth = out.contentWidth.rustMax(width + x0 + mr)
                var info = LineInfo()
                info.para = pi
                info.start = rl.start
                info.end = rl.end
                info.top = top
                info.baseline = baseline
                info.bottom = y
                info.caretX = caretX
                info.rtl = p.rtl
                info.levels = levels
                info.edges = edges
                info.boundary = lineCells.map(\.boundary)
                info.extent = (left, left + lineW)
                info.startOffset = x0
                allLines.append(PendingLine(info: info, place: LinePlace(order: order, kashida: kashida), bullet: bullet))
            }
            out.paraLines.append((firstLineIdx, raw.count))
            prevAfter = spacingPts(props.spaceAfter, p.leadSize).rustMax(0)
        }
        // The text ends at the last line's descent under exact spacing; the last paragraph's space after
        // counts only when the body says so.
        let total = (y - tail).rustMax(0) + (firstLast ? prevAfter : 0)
        out.contentHeight = total
        // Where column `c` starts: from the left, or from the right with `rtlCol`.
        let rtlCols = (bp.rtlCol ?? false) && ncols > 1
        func colX(_ c: Int) -> Double { Double(rtlCols ? Swift.max(ncols - 1 - c, 0) : c) * (colW + colGap) }
        // Columns: distribute lines by height.
        let colH = ncols > 1 ? inner.height : .infinity
        var col = 0
        var colY0 = 0.0
        for i in allLines.indices {
            if ncols > 1 && allLines[i].info.bottom - colY0 > colH + 0.01 && col + 1 < ncols {
                col += 1
                colY0 = allLines[i].info.top
            }
            allLines[i].info.column = col
            if col > 0 {
                allLines[i].info.top -= colY0
                allLines[i].info.baseline -= colY0
                allLines[i].info.bottom -= colY0
            }
            let cx = colX(col)
            if cx != 0 { allLines[i].info.shiftX(cx) }
        }
        let usedH = ncols > 1 ? allLines.map(\.info.bottom).reduce(0, { $0.rustMax($1) }) : total
        out.overflow = usedH > inner.height + 0.5 || (ncols > 1 && (allLines.last.map { $0.info.bottom > inner.height + 0.5 } ?? false))
        let dy: Double = switch bp.anchor ?? .top {
        case .top: 0
        case .middle: (inner.height - usedH) / 2
        // PowerPoint draws justified and distributed anchoring at the bottom.
        case .bottom, .justified, .distributed: inner.height - usedH
        }
        // anchorCtr: centre the drawn text block on the box. Empty lines carry no ink and stay out of the
        // block. Not applied to vertical text or multi-column bodies.
        let centreBlock = (bp.anchorCtr ?? false) && ncols == 1 && vert == .horizontal
        var ox = inner.x0
        if centreBlock && !allLines.isEmpty {
            var (bmin, bmax) = (Double.infinity, -Double.infinity)
            for l in allLines where l.info.end > l.info.start {
                bmin = bmin.rustMin(l.info.extent.left)
                bmax = bmax.rustMax(l.info.extent.right)
            }
            if bmax >= bmin { ox = inner.x0 + inner.width / 2 - (bmin + bmax) / 2 }
        }
        let oy = inner.y0 + dy
        // Emit runs, in visual order.
        for li in allLines.indices {
            allLines[li].info.top += oy
            allLines[li].info.baseline += oy
            allLines[li].info.bottom += oy
            allLines[li].info.shiftX(ox)
            if linesLTR {
                // The line's place mirrored across the box: the first line ends up on the left.
                let d = inner.y0 + inner.y1 - allLines[li].info.top - allLines[li].info.bottom
                allLines[li].info.top += d
                allLines[li].info.baseline += d
                allLines[li].info.bottom += d
            }
            let line = allLines[li].info
            let place = allLines[li].place
            guard let p = shapedParas.at(line.para) else { continue }
            if let (s, bx, _) = allLines[li].bullet, let (_, st) = p.bullet {
                let g = measureStr(st.face, st.size, s).glyphs
                let run = GlyphRun(
                    face: st.face, size: st.size, color: st.color,
                    glyphs: g.map { PositionedGlyph(gid: $0.gid, x: ox + bx + $0.x + colX(line.column), y: line.baseline) }, cells: [],
                    fakeBold: false, fakeItalic: false, outline: nil, para: line.para, chars: (0, 0), link: false, alpha: st.alpha,
                    gradient: nil, effects: nil, upright: false
                )
                if (body.paragraphs.at(line.para)?.isEmpty ?? false) && opts.promptColor == nil {
                    out.emptyBullets.append(run)
                } else {
                    out.runs.append(run)
                }
            }
            // Group visually consecutive cells by (style, face).
            var cur: GlyphRun?
            var curKey = (Int.max, Int.max, false, false)
            let lineLen = Swift.max(line.end - line.start, 0)
            for k in place.order {
                let ci = line.start + k
                guard let cell = p.cells.at(ci), let st = p.styles.at(cell.style), let (cx, cx1) = line.edges.at(k) else { continue }
                let baseY = line.baseline - st.baseline * st.size
                let smallCap = st.caps == .small && cell.ch.properties.isLowercase
                var size = st.baseline != 0 ? st.size * subSuper : st.size
                if smallCap { size *= 0.8 }
                // Small capitals are drawn smaller than the capitals beside them: a run of their own.
                let key = (cell.style, cell.face, smallCap, cell.upright)
                if key != curKey {
                    if let r = cur.take() { out.runs.append(r) }
                    guard let face = p.faces.at(cell.face) else { continue }
                    cur = GlyphRun(
                        face: face, size: size, color: st.color, glyphs: [], cells: [], fakeBold: st.fakeBold, fakeItalic: st.fakeItalic,
                        outline: st.outline, para: line.para, chars: (ci, ci + 1), link: st.link, alpha: st.alpha, gradient: st.gradient,
                        effects: st.effects, upright: cell.upright
                    )
                    curKey = key
                }
                if var r = cur {
                    r.chars = (Swift.min(r.chars.start, ci), Swift.max(r.chars.end, ci + 1))
                    if cell.ch == "\u{AD}" && cx1 - cx > 0.01 {
                        // The soft hyphen a line breaks at is drawn as a hyphen.
                        if let f = p.faces.at(cell.face) {
                            r.glyphs.append(PositionedGlyph(gid: f.glyph(for: "-"), x: cx, y: baseY))
                            r.cells.append((ci, cell.ch))
                        }
                    } else if cell.head == ci && !cell.glyphs.isEmpty {
                        // The cluster's glyphs start at its leftmost cell; kashida (right-to-left only) fills
                        // the gap on the cluster's left with tatweel glyphs.
                        var (cl, kash) = (cx, 0.0)
                        var j = k
                        while j < lineLen, p.cells.at(line.start + j)?.head == ci {
                            cl = cl.rustMin(line.edges.at(j)?.left ?? cx)
                            kash += place.kashida.at(j) ?? 0
                            j += 1
                        }
                        if kash > 0, let f = p.faces.at(cell.face) {
                            let tg = f.glyph(for: "\u{0640}")
                            let tw = f.advance(tg) * size / f.upem.rustMax(1)
                            if tg != 0 && tw > 0 {
                                let count = Swift.min(Swift.max(Int(rustCast: (kash / tw).rounded(.up)), 1), 256)
                                for i in 0 ..< count {
                                    r.glyphs.append(PositionedGlyph(gid: tg, x: cl + (Double(i) * tw).rustMin((kash - tw).rustMax(0)), y: baseY))
                                    r.cells.append((ci, cell.ch))
                                }
                            }
                        }
                        for g in cell.glyphs {
                            r.glyphs.append(PositionedGlyph(gid: g.gid, x: cl + kash + g.x, y: baseY + g.y))
                            r.cells.append((ci, cell.ch))
                        }
                    }
                    cur = r
                }
                guard cx1 - cx > 0 else { continue }
                if let hl = st.highlight {
                    out.decos.append(Deco(rect: Rect(cx, line.top, cx1, line.bottom), color: hl, behind: true, para: line.para, line: .solid))
                }
                if !cell.ch.isWS || st.underline != nil {
                    if let (uc, u) = st.underline {
                        // At the underline position and thickness of the run's own font.
                        let k = st.size / st.face.upem.rustMax(1)
                        let (pos, t) = (st.face.underline.position * k, (st.face.underline.thickness * k).rustMax(0.5))
                        for (y0, y1, kind) in u.boxes(pos, t) {
                            out.decos.append(Deco(rect: Rect(cx, line.baseline + y0, cx1, line.baseline + y1), color: uc, behind: false, para: line.para, line: kind))
                        }
                    }
                    if let sk = st.strike {
                        // At the strikeout position and thickness of the run's own font.
                        let k = st.size / st.face.upem.rustMax(1)
                        let t = (st.face.strikeout.thickness * k).rustMax(0.5)
                        let sy = line.baseline - st.face.strikeout.position * k
                        out.decos.append(Deco(rect: Rect(cx, sy, cx1, sy + t), color: st.color, behind: false, para: line.para, line: .solid))
                        if sk == .double {
                            out.decos.append(Deco(rect: Rect(cx, sy - t * 2, cx1, sy - t), color: st.color, behind: false, para: line.para, line: .solid))
                        }
                    }
                }
            }
            if let r = cur { out.runs.append(r) }
        }
        out.boundaries = shapedParas.map { p in
            var b = p.cells.map(\.boundary)
            b.append(true)
            b[0] = true
            return b
        }
        out.lines = allLines.map(\.info)
        // Merge adjacent decorations of the same colour on the same line.
        out.decos = mergeDecos(out.decos)
        return out
    }

    /// Height the shape needs so its text fits (Resize shape to fit text): text height + insets.
    public static func fitHeight(_ ctx: Resolve.Ctx, _ shape: Shape, _ body: TextBody, _ rect: Rect, _ fields: any TextFields) -> Double {
        let bp = Resolve.body(ctx, shape)
        let l = layout(ctx, shape, body, TextOpts(rect: rect, fields: fields, promptColor: nil, noShrink: true))
        return l.contentHeight + (bp.insetT ?? 3.6) + (bp.insetB ?? 3.6)
    }

    /// Width a non-wrapping text box needs.
    public static func fitWidth(_ ctx: Resolve.Ctx, _ shape: Shape, _ body: TextBody, _ rect: Rect, _ fields: any TextFields) -> Double {
        let bp = Resolve.body(ctx, shape)
        let wide = Rect(rect.x0, rect.y0, rect.x0 + 100_000, rect.y1)
        var s2 = shape
        s2.text?.body.wrap = false
        let l = layout(ctx, s2, body, TextOpts(rect: wide, fields: fields, promptColor: nil, noShrink: true))
        let w = l.lines.map { $0.startOffset + ($0.extent.right - $0.extent.left) }.reduce(0, { $0.rustMax($1) })
        return w + (bp.insetL ?? 7.2) + (bp.insetR ?? 7.2) + 1
    }
}

func mergeDecos(_ v: [Deco]) -> [Deco] {
    var out: [Deco] = []
    out.reserveCapacity(v.count)
    for d in v {
        // Lines drawn together (a double underline, a strikethrough) interleave: look a few back.
        var merged = false
        for i in out.indices.reversed().prefix(4) {
            let last = out[i]
            if last.color == d.color && last.behind == d.behind && last.line == d.line && abs(last.rect.y0 - d.rect.y0) < 0.01
                && abs(last.rect.y1 - d.rect.y1) < 0.01 && abs(last.rect.x1 - d.rect.x0) < 0.5
            {
                out[i].rect.x1 = d.rect.x1
                merged = true
                break
            }
        }
        if !merged { out.append(d) }
    }
    return out
}

/// How a line's cells are placed: visual order (indices from the line start) and kashida widths.
struct LinePlace {
    var order: [Int]
    var kashida: [Double]
}

/// Kashida opportunities on a line (indices from the line start), at most one per word (its last join):
/// the last cell of a right-to-left Arabic grapheme that joins the next letter, in a face with a tatweel
/// glyph, when the two aren't one ligature.
func kashidaOpportunities(_ p: ParaShaped, _ start: Int, _ end: Int) -> [Int] {
    var out: [Int] = []
    var wordHas = false
    guard end > start else { return out }
    for i in start ..< end {
        guard let c = p.cells.at(i) else { continue }
        if c.ch.isWS {
            wordHas = false
            continue
        }
        if !c.boundary || c.level % 2 == 0 || !Script.joinsFollowing(c.ch) { continue }
        // The next grapheme on the line.
        guard i + 1 < end, let nx = (i + 1 ..< end).first(where: { p.cells.at($0)?.boundary ?? false }), let d = p.cells.at(nx) else { continue }
        let sameCluster = d.head == c.head || d.head != nx
        let tatweel = p.faces.at(c.face).map { $0.glyph(for: "\u{0640}") != 0 } ?? false
        if Script.joinsPreceding(d.ch) && d.face == c.face && !sameCluster && tatweel {
            // A later join in the same word replaces the earlier one.
            if wordHas { out.removeLast() }
            out.append(nx - 1 - start)
            wordHas = true
        }
    }
    return out
}

extension LineInfo {
    mutating func shiftX(_ dx: Double) {
        for i in caretX.indices { caretX[i] += dx }
        for i in edges.indices {
            edges[i].left += dx
            edges[i].right += dx
        }
        extent.left += dx
        extent.right += dx
    }
}
