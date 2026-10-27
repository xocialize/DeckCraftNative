// DCPPTX — DrawingML reading: colours, fills, lines, effects, transforms and text. Port of deckcraft
// crates/pptx/src/read/dml.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel
import Foundation

extension PPTXRead {
    static func pt(_ e: XMLEl, _ name: String) -> Double? {
        e.i64(name).map(emuToPt)
    }

    /// 1/100 000 → fraction.
    static func pct(_ e: XMLEl, _ name: String) -> Double? {
        e.f64(name).map { $0 / 100_000.0 }
    }

    /// 1/60 000 degree → degrees.
    static func ang(_ e: XMLEl, _ name: String) -> Double? {
        e.f64(name).map { $0 / 60_000.0 }
    }

    static func linToSRGB(_ v: Double) -> Double {
        let v = v.clamped(0.0, 1.0)
        return v <= 0.003_130_8 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    /// A colour element (`srgbClr`, `schemeClr`, …) with its transforms.
    static func colorEl(_ c: XMLEl) -> ColorRef? {
        let base: ColorBase
        switch c.local {
        case "srgbClr":
            base = .rgb(rgb: Rgba.fromHex(c.attr("val") ?? "000000") ?? .black)
        case "schemeClr":
            base = .scheme(slot: c.attr("val").flatMap(SchemeSlot.fromXML) ?? .tx1)
        case "sysClr":
            base = .system(
                name: c.attr("val") ?? "windowText",
                last: c.attr("lastClr").flatMap(Rgba.fromHex) ?? (attrIs(c.attr("val"), "window") ? .white : .black)
            )
        case "prstClr":
            base = .preset(name: c.attr("val") ?? "black")
        case "scrgbClr":
            func f(_ n: String) -> Double { linToSRGB((c.f64(n) ?? 0.0) / 100_000.0) }
            base = .rgb(rgb: Rgba.fromF64(f("r"), f("g"), f("b"), 1.0))
        case "hslClr":
            let h = (c.f64("hue") ?? 0.0) / 60_000.0
            let s = (c.f64("sat") ?? 0.0) / 100_000.0
            let l = (c.f64("lum") ?? 0.0) / 100_000.0
            base = .rgb(rgb: Rgba.fromHSL(h, s, l, 255))
        default:
            return nil
        }
        let mods = c.elements.prefix(32).compactMap { ColorTransform.fromXML(String($0.local), $0.i32("val")) }
        return ColorRef(base: base, mods: mods)
    }

    /// The first colour child of a container (`solidFill`, `fgClr`, `lnRef`…).
    static func color(_ container: XMLEl) -> ColorRef? {
        for e in container.elements {
            if let c = colorEl(e) { return c }
        }
        return nil
    }

    static let fillNames = ["noFill", "solidFill", "gradFill", "blipFill", "pattFill", "grpFill"]

    static func isFillName(_ n: Substring) -> Bool {
        fillNames.contains { bytesEqual($0, n) }
    }

    /// The fill child of `parent`, if any.
    static func fillOf(_ imp: Imp, _ part: Part, _ parent: XMLEl) -> Fill? {
        parent.elements.first { isFillName($0.local) }.flatMap { fillEl(imp, part, $0) }
    }

    static func fillEl(_ imp: Imp, _ part: Part, _ f: XMLEl) -> Fill? {
        switch f.local {
        case "noFill":
            return .none_
        case "solidFill":
            return .solid(color: color(f) ?? .rgb(.black))
        case "gradFill":
            return .gradient(gradient(f))
        case "blipFill":
            guard var p = blipFill(imp, part, f) else { return .none_ }
            // A picture filling a shape or background with neither `a:stretch` nor `a:tile` is tiled
            // at its own size, as PowerPoint draws it.
            if f.child("stretch") == nil && f.child("tile") == nil {
                p.mode = .tile(tx: 0.0, ty: 0.0, sx: 1.0, sy: 1.0, flip: "none", align: "tl")
            }
            return .picture(p)
        case "pattFill":
            return .pattern(pattern(f))
        case "grpFill":
            return .group
        default:
            return nil
        }
    }

    /// An `a:pattFill`: its preset (5 % dots when unset), foreground (black) and background (white).
    static func pattern(_ f: XMLEl) -> PatternFill {
        PatternFill(
            preset: f.attr("prst") ?? "pct5",
            fg: f.child("fgClr").flatMap(color) ?? .rgb(.black),
            bg: f.child("bgClr").flatMap(color) ?? .rgb(.white)
        )
    }

    static func gradient(_ f: XMLEl) -> Gradient {
        var stops: [GradientStop] = f.child("gsLst").map { l in
            l.childrenNamed("gs").prefix(256).map { g in
                GradientStop(pos: (pct(g, "pos") ?? 0.0).clamped(0.0, 1.0), color: color(g) ?? .rgb(.black))
            }
        } ?? []
        // `sort_by(total_cmp)`: stable.
        stops = stops.enumerated().sorted { x, y in
            if totalLess(x.element.pos, y.element.pos) { return true }
            if totalLess(y.element.pos, x.element.pos) { return false }
            return x.offset < y.offset
        }.map(\.element)
        let shape: GradientShape
        if let l = f.child("lin") {
            shape = .linear(angle: ang(l, "ang") ?? 0.0, scaled: l.bool("scaled") ?? false)
        } else if let p = f.child("path") {
            let r = p.child("fillToRect")
            func g(_ n: String) -> Double { r.flatMap { pct($0, n) } ?? 0.0 }
            shape = .path(path: p.attr("path") ?? "circle", focus: [g("l"), g("t"), g("r"), g("b")])
        } else {
            shape = .linear(angle: 90.0, scaled: false)
        }
        let tile = f.child("tileRect").map { r in
            [pct(r, "l"), pct(r, "t"), pct(r, "r"), pct(r, "b")].map { ($0 ?? 0.0).clamped(-10.0, 10.0) }
        }
        return Gradient(stops: stops, shape: shape, rotateWithShape: f.bool("rotWithShape") ?? true, tile: tile ?? [0, 0, 0, 0])
    }

    /// `blipFill` (either `a:` or `p:`) → picture fill, registering the image as media.
    static func blipFill(_ imp: Imp, _ part: Part, _ bf: XMLEl) -> PictureFill? {
        let blip = bf.child("blip")
        guard let media = blip.flatMap({ mediaRef(imp, part, $0) }) else { return nil }
        var pf = PictureFill(media: media, upright: !(bf.bool("rotWithShape") ?? true))
        if let layer = blip?.child("extLst")?.find("imgLayer") {
            var effect: String?
            outer: for e in layer.elements where bytesEqual(e.local, "imgEffect") {
                for x in e.elements where hasBytePrefix(x.local, "artistic") {
                    effect = String(x.local)
                    break outer
                }
            }
            if let effect, let original = mediaRef(imp, part, layer) {
                pf.artistic = Artistic(effect: effect, original: original)
            }
        }
        if let b = blip {
            for e in b.elements {
                switch e.local {
                case "alphaModFix":
                    pf.alpha = (pct(e, "amt") ?? 1.0).clamped(0.0, 1.0)
                case "lum":
                    pf.adjust.brightness = (pct(e, "bright") ?? 0.0).clamped(-1.0, 1.0)
                    pf.adjust.contrast = (pct(e, "contrast") ?? 0.0).clamped(-1.0, 1.0)
                case "grayscl":
                    pf.adjust.grayscale = true
                case "biLevel":
                    pf.adjust.bilevel = (pct(e, "thresh") ?? 0.5).clamped(0.0, 1.0)
                case "alphaInv":
                    pf.adjust.alphaInv = true
                case "duotone":
                    let cs = e.elements.compactMap(colorEl)
                    if cs.count == 2 { pf.adjust.duotone = Pair(cs[0], cs[1]) }
                case "clrChange":
                    if let c = e.child("clrFrom").flatMap(color), case .rgb(let rgb) = c.base {
                        pf.adjust.clearColor = rgb
                    }
                default:
                    break
                }
            }
        }
        if let r = bf.child("srcRect") {
            pf.crop = [pct(r, "l") ?? 0.0, pct(r, "t") ?? 0.0, pct(r, "r") ?? 0.0, pct(r, "b") ?? 0.0].map { $0.clamped(-10.0, 1.0) }
        }
        if let t = bf.child("tile") {
            pf.mode = .tile(
                tx: pt(t, "tx") ?? 0.0, ty: pt(t, "ty") ?? 0.0, sx: pct(t, "sx") ?? 1.0, sy: pct(t, "sy") ?? 1.0,
                flip: t.attr("flip") ?? "none", align: t.attr("algn") ?? "tl"
            )
        } else {
            let r = bf.path(["stretch", "fillRect"])
            func g(_ n: String) -> Double { (r.flatMap { pct($0, n) } ?? 0.0).clamped(-10.0, 1.0) }
            pf.mode = .stretch(fillRect: [g("l"), g("t"), g("r"), g("b")])
        }
        return pf
    }

    /// Media for an element with `r:embed` (or `r:link`).
    static func mediaRef(_ imp: Imp, _ part: Part, _ b: XMLEl) -> MediaId? {
        if let id = b.attr("r:embed"), !id.isEmpty, let r = part.rels.get(id) {
            if r.external { return imp.mediaLink(r.target) }
            if let m = imp.mediaFor(r.target) { return m }
        }
        if let id = b.attr("r:link"), !id.isEmpty, let r = part.rels.get(id) {
            if r.external { return imp.mediaLink(r.target) }
            return imp.mediaFor(r.target)
        }
        return nil
    }

    static func line(_ imp: Imp, _ part: Part, _ ln: XMLEl) -> Line {
        var l = Line(width: pt(ln, "w").map { $0.clamped(0.0, 2000.0) })
        l.cap = ln.attr("cap").map { c -> LineCap in
            switch c {
            case "rnd": .round
            case "sq": .square
            default: .flat
            }
        }
        l.compound = ln.attr("cmpd").map(Compound.fromXML)
        l.fill = fillOf(imp, part, ln)
        for e in ln.elements {
            switch e.local {
            case "prstDash":
                l.dash = .preset(name: e.attr("val") ?? "solid")
            case "custDash":
                let pattern = e.childrenNamed("ds").prefix(64).map { d in Pair(pct(d, "d") ?? 1.0, pct(d, "sp") ?? 1.0) }
                l.dash = .custom(pattern: pattern)
            case "round": l.join = .round
            case "bevel": l.join = .bevel
            case "miter": l.join = .miter
            case "headEnd": l.head = lineEnd(e)
            case "tailEnd": l.tail = lineEnd(e)
            default: break
            }
        }
        return l
    }

    static func lineEnd(_ e: XMLEl) -> LineEnd? {
        LineEnd(kind: e.attr("type") ?? "none", w: e.attr("w") ?? "med", len: e.attr("len") ?? "med")
    }

    static func shadow(_ e: XMLEl, _ inner: Bool) -> Shadow {
        Shadow(
            color: color(e) ?? .rgb(.black),
            blur: (pt(e, "blurRad") ?? 0.0).rustMax(0.0),
            dist: pt(e, "dist") ?? 0.0,
            dir: ang(e, "dir") ?? 0.0,
            inner: inner,
            sx: pct(e, "sx") ?? 1.0,
            sy: pct(e, "sy") ?? 1.0,
            kx: ang(e, "kx") ?? 0.0,
            ky: ang(e, "ky") ?? 0.0,
            align: e.attr("algn") ?? (inner ? "" : "b"),
            rotateWithShape: e.bool("rotWithShape") ?? true
        )
    }

    /// `effectLst` → effects.
    static func effects(_ el: XMLEl) -> Effects {
        var fx = Effects()
        for e in el.elements {
            switch e.local {
            case "outerShdw":
                fx.outerShadow = shadow(e, false)
            case "prstShdw":
                var s = shadow(e, false)
                s.align = "b"
                fx.outerShadow = s
            case "innerShdw":
                fx.innerShadow = shadow(e, true)
            case "glow":
                fx.glow = Glow(color: color(e) ?? .rgb(.black), radius: (pt(e, "rad") ?? 0.0).rustMax(0.0))
            case "softEdge":
                fx.softEdge = (pt(e, "rad") ?? 0.0).rustMax(0.0)
            case "fillOverlay":
                var fill: Fill?
                for f in e.elements {
                    switch f.local {
                    case "solidFill": fill = color(f).map { .solid(color: $0) }
                    case "gradFill": fill = .gradient(gradient(f))
                    default: fill = nil
                    }
                    if fill != nil { break }
                }
                fx.fillOverlay = fill.map { FillOverlay(blend: e.attr("blend") ?? "over", fill: $0) }
            case "reflection":
                fx.reflection = Reflection(
                    blur: pt(e, "blurRad") ?? 0.0, startAlpha: pct(e, "stA") ?? 1.0, endAlpha: pct(e, "endA") ?? 0.0,
                    endPos: pct(e, "endPos") ?? 1.0, dist: pt(e, "dist") ?? 0.0
                )
            default:
                break
            }
        }
        return fx
    }

    /// `a:xfrm` → (box, child box for groups).
    static func xfrm(_ x: XMLEl) -> (Xfrm, Xfrm?) {
        let off = x.child("off")
        let ext = x.child("ext")
        func g(_ e: XMLEl?, _ n: String) -> Double { e.flatMap { pt($0, n) } ?? 0.0 }
        var xf = Xfrm(g(off, "x"), g(off, "y"), g(ext, "cx").rustMax(0.0), g(ext, "cy").rustMax(0.0))
        xf.rot = ang(x, "rot") ?? 0.0
        if !xf.rot.isFinite { xf.rot = 0.0 }
        xf.flipH = x.bool("flipH") ?? false
        xf.flipV = x.bool("flipV") ?? false
        var child: Xfrm?
        if let o = x.child("chOff"), let e = x.child("chExt") {
            child = Xfrm(g(o, "x"), g(o, "y"), g(e, "cx").rustMax(0.0), g(e, "cy").rustMax(0.0))
        }
        return (xf, child)
    }

    // MARK: - Text

    static func bodyPr(_ b: XMLEl) -> BodyProps {
        var p = BodyProps(
            insetL: pt(b, "lIns"),
            insetT: pt(b, "tIns"),
            insetR: pt(b, "rIns"),
            insetB: pt(b, "bIns"),
            anchor: b.attr("anchor").flatMap(Anchor.fromXML),
            anchorCtr: b.bool("anchorCtr"),
            wrap: b.attr("wrap").map { !bytesEqual($0, "none") },
            vert: b.attr("vert").flatMap(TextDir.fromXML),
            rot: ang(b, "rot"),
            columns: b.u32("numCol").map { Swift.min(Swift.max($0, 1), 16) },
            colSpacing: pt(b, "spcCol"),
            rtlCol: b.bool("rtlCol"),
            upright: b.bool("upright"),
            spaceFirstLast: b.bool("spcFirstLastPara")
        )
        for e in b.elements {
            switch e.local {
            case "normAutofit":
                p.autofit = .shrink(
                    fontScale: pct(e, "fontScale").map { $0.clamped(0.01, 1.0) },
                    lineReduction: (pct(e, "lnSpcReduction") ?? 0.0).clamped(0.0, 1.0)
                )
            case "spAutoFit":
                p.autofit = .shape
            case "noAutofit":
                p.autofit = .none_
            case "prstTxWarp":
                p.warp = e.attr("prst").flatMap { w in bytesEqual(w, "textNoShape") || w.isEmpty ? nil : w }
                p.warpAdj = p.warp.map { warpAdjusts($0, e) } ?? []
            default:
                break
            }
        }
        return p
    }

    /// The index of an adjust guide named `adj` (0) or `adjN` for N in `1...maxN`.
    static func adjIndex(_ n: String, _ maxN: Int) -> Int? {
        if bytesEqual(n, "adj") { return 0 }
        guard let k = stripBytePrefix(n, "adj").flatMap({ rustParseUnsigned($0, as: UInt.self) }), k >= 1, k <= UInt(maxN) else { return nil }
        return Int(k) - 1
    }

    /// A guide's `val N` formula, as a finite number.
    static func adjValue(_ gd: XMLEl) -> Double? {
        guard let f = gd.attr("fmla"), let rest = stripBytePrefix(rustTrim(f), "val"),
              let v = rustParseF64(rustTrim(String(rest))), v.isFinite
        else { return nil }
        return v
    }

    /// `prstTxWarp/avLst` guides `adj` / `adj1`… as raw values by index (empty when none is given);
    /// slots the file leaves out keep the preset's default.
    static func warpAdjusts(_ preset: String, _ e: XMLEl) -> [Double] {
        var adj: [Double] = []
        guard let av = e.child("avLst") else { return adj }
        let defaults = Warp.adjustDefaults(preset)
        for gd in av.childrenNamed("gd").prefix(16) {
            guard let idx = adjIndex(gd.attr("name") ?? "", 8) else { continue }
            guard let v = adjValue(gd) else { continue }
            while adj.count <= idx { adj.append(defaults.at(adj.count) ?? 0.0) }
            if idx < adj.count { adj[idx] = v.clamped(-1.0e9, 1.0e9) }
        }
        return adj
    }

    static func spacing(_ e: XMLEl) -> Spacing? {
        if let p = e.child("spcPct") {
            return .pct((pct(p, "val") ?? 1.0).clamped(0.0, 100.0))
        }
        return e.child("spcPts").map { p in .pts((p.f64("val") ?? 0.0).clamped(0.0, 1_000_000.0) / 100.0) }
    }

    /// `a:pPr` / `a:lvlNpPr` → (level, paragraph props, default run props).
    static func ppr(_ imp: Imp, _ part: Part, _ p: XMLEl) -> (UInt8?, ParaProps, RunProps?) {
        var pp = ParaProps(
            align: p.attr("algn").flatMap(Align.fromXML),
            marginLeft: pt(p, "marL"),
            marginRight: pt(p, "marR"),
            indent: pt(p, "indent"),
            defaultTab: pt(p, "defTabSz"),
            rtl: p.bool("rtl"),
            fontAlign: p.attr("fontAlgn"),
            eastAsianLineBreak: p.bool("eaLnBrk"),
            latinLineBreak: p.bool("latinLnBrk"),
            hangingPunct: p.bool("hangingPunct")
        )
        let lvl = p.u32("lvl").map { UInt8(Swift.min($0, 8)) }
        var def: RunProps?
        for e in p.elements {
            switch e.local {
            case "lnSpc": pp.lineSpacing = spacing(e)
            case "spcBef": pp.spaceBefore = spacing(e)
            case "spcAft": pp.spaceAfter = spacing(e)
            case "buNone": pp.bullet = Bullet.none_
            case "buChar": pp.bullet = .char(char: takeChars(e.attr("char") ?? "•", 4))
            case "buAutoNum":
                pp.bullet = .autoNum(
                    scheme: e.attr("type") ?? "arabicPeriod",
                    startAt: Swift.min(Swift.max(e.u32("startAt") ?? 1, 1), 32767)
                )
            case "buBlip":
                if let m = e.child("blip").flatMap({ mediaRef(imp, part, $0) }) { pp.bullet = .picture(media: m) }
            case "buFont": pp.bulletFont = e.attr("typeface")
            case "buClr": pp.bulletColor = color(e)
            case "buSzPct": pp.bulletSize = pct(e, "val").map { $0.clamped(0.25, 4.0) }
            case "tabLst":
                pp.tabs = e.childrenNamed("tab").prefix(64).map { t in TabStop(pos: pt(t, "pos") ?? 0.0, align: t.attr("algn") ?? "l") }
            case "defRPr": def = rpr(imp, part, e)
            default: break
            }
        }
        return (lvl, pp, def)
    }

    static func hyperlink(_ imp: Imp, _ part: Part, _ h: XMLEl) -> Hyperlink? {
        let rid = h.attr("r:id") ?? ""
        let rel = part.rels.get(rid)
        let action = h.attr("action") ?? ""
        let a: Action
        if let rest = stripBytePrefix(action, "ppaction://hlinkshowjump?jump=") {
            switch rest {
            case "nextslide": a = .nextSlide
            case "previousslide": a = .previousSlide
            case "firstslide": a = .firstSlide
            case "lastslide": a = .lastSlide
            case "endshow": a = .endShow
            case "lastslideviewed": a = .lastViewed
            default: return nil
            }
        } else if hasBytePrefix(action, "ppaction://hlinksldjump") {
            guard let slide = rel.flatMap({ imp.slideByPart[ByteKey(OPC.norm($0.target))] }) else { return nil }
            a = .slide(slide: slide)
        } else if let q = stripBytePrefix(action, "ppaction://customshow?") {
            let kvs = splitByte(q, UInt8(ascii: "&"))
            let id = kvs.lazy.compactMap { stripBytePrefix($0, "id=") }.first.map(String.init) ?? "0"
            let ret = kvs.lazy.compactMap { stripBytePrefix($0, "return=") }.first
            let returns = !(ret.map { bytesEqual($0, "false") || bytesEqual($0, "0") } ?? false)
            a = .customShow(name: imp.customShowNames[ByteKey(id)] ?? id, returns: returns)
        } else if hasBytePrefix(action, "ppaction://program") {
            a = .program(path: rel?.target ?? "")
        } else if hasBytePrefix(action, "ppaction://media") {
            a = .playMedia
        } else if action.isEmpty || hasBytePrefix(action, "ppaction://hlinkfile") {
            guard let r = rel else { return nil }
            if r.target.isEmpty { return nil }
            if !r.external, let s = imp.slideByPart[ByteKey(OPC.norm(r.target))] {
                a = .slide(slide: s)
            } else {
                a = .url(url: r.target)
            }
        } else {
            return nil
        }
        return Hyperlink(
            action: a,
            tooltip: h.attr("tooltip") ?? "",
            highlightClick: h.bool("highlightClick") ?? false,
            sound: h.child("snd").flatMap { mediaRef(imp, part, $0) },
            stopSound: h.bool("endSnd") ?? false,
            zoomReturn: nil
        )
    }

    static func typeface(_ e: XMLEl) -> String? {
        guard let t = e.attr("typeface"), !t.isEmpty else { return nil }
        return takeChars(t, 256)
    }

    static func rpr(_ imp: Imp, _ part: Part, _ r: XMLEl) -> RunProps {
        var p = RunProps(
            size: r.f64("sz").map { ($0 / 100.0).clamped(1.0, 4000.0) },
            bold: r.bool("b"),
            italic: r.bool("i"),
            underline: r.attr("u"),
            strike: r.attr("strike").map { s -> Strike in
                switch s {
                case "sngStrike": .single
                case "dblStrike": .double
                default: .none_
                }
            },
            baseline: pct(r, "baseline").map { $0.clamped(-10.0, 10.0) },
            caps: r.attr("cap").map { c -> Caps in
                switch c {
                case "small": .small
                case "all": .all
                default: .none_
                }
            },
            spacing: r.f64("spc").map { ($0 / 100.0).clamped(-4000.0, 4000.0) },
            kern: r.f64("kern").map { ($0 / 100.0).clamped(0.0, 4000.0) },
            lang: r.attr("lang"),
            noProof: r.bool("noProof")
        )
        for e in r.elements {
            let n = e.local
            switch n {
            case "ln": p.outline = line(imp, part, e)
            case _ where isFillName(n): p.fill = fillEl(imp, part, e)
            case "effectLst":
                let fx = effects(e)
                p.shadow = fx.outerShadow
                p.innerShadow = fx.innerShadow
                p.glow = fx.glow
                p.reflection = fx.reflection
                p.softEdge = fx.softEdge
            case "highlight": p.highlight = color(e)
            case "uFill": p.underlineColor = e.child("solidFill").flatMap(color)
            case "latin": p.font = typeface(e)
            case "ea": p.fontEa = typeface(e)
            case "cs": p.fontCs = typeface(e)
            case "sym": p.fontSym = typeface(e)
            case "hlinkClick": p.link = hyperlink(imp, part, e)
            case "hlinkMouseOver": p.hover = hyperlink(imp, part, e)
            default: break
            }
        }
        return p
    }

    /// `a:lstStyle`, `p:titleStyle`, `a:defaultTextStyle`… → list style.
    static func listStyle(_ imp: Imp, _ part: Part, _ ls: XMLEl) -> ListStyle {
        var out = ListStyle()
        for e in ls.elements {
            guard let mid = stripBytePrefix(e.local, "lvl").flatMap({ stripByteSuffix($0, "pPr") }),
                  let l = rustParseUnsigned(mid, as: UInt8.self)
            else { continue }
            if !(1 ... 9).contains(l) { continue }
            let (_, para, run) = ppr(imp, part, e)
            out.set(l - 1, LevelStyle(para: para, run: run ?? .default))
        }
        return out
    }

    static func textBody(_ imp: Imp, _ part: Part, _ tx: XMLEl) -> TextBody {
        let body = tx.child("bodyPr").map(bodyPr) ?? .default
        let list = tx.child("lstStyle").map { listStyle(imp, part, $0) } ?? .default
        let paragraphs = tx.childrenNamed("p").prefix(100_000).map { paragraph(imp, part, $0) }
        return TextBody(body: body, listStyle: list, paragraphs: paragraphs)
    }

    static let maxParagraphRuns = 10_000

    /// The run properties of `e`'s `rPr` child, or the defaults.
    static func runProps(_ imp: Imp, _ part: Part, _ e: XMLEl) -> RunProps {
        e.child("rPr").map { rpr(imp, part, $0) } ?? .default
    }

    /// Appends the runs of an `a:r` text, where a vertical tab or line feed is a line break, as it
    /// lays out and as export writes it.
    static func pushTextRuns(_ para: inout Paragraph, _ props: RunProps, _ text: String) {
        // `split(['\u{b}', '\n'])`, over scalars (a CR LF is one Swift `Character`).
        var pieces: [String] = []
        var cur = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if u == "\u{0B}" || u == "\n" {
                pieces.append(String(cur))
                cur = String.UnicodeScalarView()
            } else {
                cur.append(u)
            }
        }
        pieces.append(String(cur))
        for (i, piece) in pieces.enumerated() {
            if para.runs.count >= maxParagraphRuns { break }
            if i > 0 {
                para.runs.append(Run(text: "", props: props, kind: .break))
            }
            if !piece.isEmpty {
                if para.runs.count >= maxParagraphRuns { break }
                para.runs.append(Run(text: piece, props: props, kind: .text))
            }
        }
    }

    /// Appends an Office Math (a14:m) run: its plain text and its OMML.
    static func pushMathRun(_ para: inout Paragraph, _ part: Part, _ e: XMLEl) {
        if para.runs.count < maxParagraphRuns {
            let text = e.findAll("t").map(\.text).joined()
            let omml = e.elements.map { part.keepInner($0) }.joined()
            para.runs.append(Run(text: text, props: .default, kind: .math(omml: omml)))
        }
    }

    static func paragraph(_ imp: Imp, _ part: Part, _ p: XMLEl) -> Paragraph {
        var para = Paragraph()
        for e in p.elements {
            switch e.local {
            case "pPr":
                let (lvl, pp, def) = ppr(imp, part, e)
                para.level = lvl ?? 0
                para.props = pp
                if let d = def { para.defProps = d }
            case "r":
                let props = runProps(imp, part, e)
                let text = e.child("t")?.text ?? ""
                pushTextRuns(&para, props, text)
            case "br":
                if para.runs.count < maxParagraphRuns {
                    let props = runProps(imp, part, e)
                    para.runs.append(Run(text: "", props: props, kind: .break))
                }
            case "fld":
                if para.runs.count < maxParagraphRuns {
                    let props = runProps(imp, part, e)
                    let text = e.child("t")?.text ?? ""
                    para.runs.append(Run(text: text, props: props, kind: .field(field: e.attr("type") ?? "")))
                }
            case "m":
                pushMathRun(&para, part, e)
            case "endParaRPr":
                para.endProps = rpr(imp, part, e)
            default:
                break
            }
        }
        return para
    }
}
