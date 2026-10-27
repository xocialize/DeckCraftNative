// DCPPTX — DrawingML writing: colours, fills, lines, effects, transforms and text. Port of deckcraft
// crates/pptx/src/write/dml.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCGeometry
import DCModel

extension PPTXWrite {
    /// The `write::dml` module.
    enum DML {
        static func emu(_ pt: Double) -> Int64 {
            Swift.min(Swift.max(ptToEmu(pt), -27_273_042_316_900), 27_273_042_316_900)
        }

        /// Positive coordinate extent (ST_PositiveCoordinate).
        static func emuPos(_ pt: Double) -> Int64 {
            Swift.max(emu(pt), 0)
        }

        /// Fraction → 1/100 000.
        static func pct(_ v: Double) -> Int64 {
            v.isFinite ? Int64(rustCast: (v * 100_000.0).rounded().clamped(-2.0e9, 2.0e9)) : 0
        }

        /// Degrees → 1/60 000 degree, normalised to 0..360.
        static func ang(_ deg: Double) -> Int64 {
            if !deg.isFinite { return 0 }
            let d = remEuclid(deg, 360.0)
            return Swift.min(Swift.max(Int64(rustCast: (d * 60_000.0).rounded()), 0), 21_599_999)
        }

        static func color(_ w: inout W, _ c: ColorRef) {
            let tag: String
            let a: A
            switch c.base {
            case .rgb(let rgb):
                (tag, a) = ("a:srgbClr", A.new().a("val", rgb.hex))
            case .scheme(let slot):
                (tag, a) = ("a:schemeClr", A.new().a("val", slot.xmlName))
            case .preset(let name):
                // The reader keeps any name a file has; only names the schema allows are written.
                (tag, a) = ("a:prstClr", A.new().a("val", presetColorNames.contains { bytesEqual($0, name) } ? name : "black"))
            case .system(let name, let last):
                (tag, a) = ("a:sysClr", A.new().a("val", systemColorNames.contains { bytesEqual($0, name) } ? name : "windowText").a("lastClr", last.hex))
            }
            var rgbAlpha: Int32?
            if case .rgb(let rgb) = c.base, rgb.a < 255, !c.mods.contains(where: { if case .alpha = $0 { true } else { false } }) {
                rgbAlpha = Int32(rustCast: Double(Int64(rgb.a) * 100_000 / 255))
            }
            if c.mods.isEmpty && rgbAlpha == nil {
                w.empty(tag, a)
                return
            }
            w.open(tag, a)
            for m in c.mods {
                let name = "a:" + m.xmlName
                if let v = m.value {
                    w.val(name, v)
                } else {
                    w.empty0(name)
                }
            }
            if let al = rgbAlpha {
                w.val("a:alpha", al)
            }
            w.close(tag)
        }

        static func solid(_ w: inout W, _ c: ColorRef) {
            w.open0("a:solidFill")
            color(&w, c)
            w.close("a:solidFill")
        }

        /// Write a fill. `Fill::Background` (only meaningful on `p:sp`) writes nothing.
        static func fill(_ w: inout W, _ x: Exp, _ o: Out, _ f: Fill) {
            switch f {
            case .none_: w.empty0("a:noFill")
            case .solid(let c): solid(&w, c)
            case .gradient(let g): gradient(&w, g)
            case .picture(let pf): blipFill(&w, x, o, "a:blipFill", pf)
            case .pattern(let p):
                w.open("a:pattFill", A.new().a("prst", p.preset.isEmpty ? "pct5" : p.preset))
                w.open0("a:fgClr")
                color(&w, p.fg)
                w.close("a:fgClr")
                w.open0("a:bgClr")
                color(&w, p.bg)
                w.close("a:bgClr")
                w.close("a:pattFill")
            case .group: w.empty0("a:grpFill")
            case .background: break
            }
        }

        /// `a:blipFill` / `p:blipFill`.
        static func blipFill(_ w: inout W, _ x: Exp, _ o: Out, _ tag: String, _ pf: PictureFill) {
            // An image that lives outside the package is a linked picture: `a:blip` names it through
            // `r:link`; `r:embed` may only reference a part inside the package.
            let linked = x.p.media(pf.media).map { $0.data.isEmpty && $0.link != nil } ?? false
            let rid = x.mediaRel(o, pf.media, "image") ?? x.placeholderRel(o)
            w.open(tag, A.new().a("rotWithShape", pf.upright ? "0" : "1"))
            let adj = pf.adjust
            let hasKids = pf.alpha != nil
                || adj.brightness != 0.0
                || adj.contrast != 0.0
                || adj.grayscale
                || adj.duotone != nil
                || adj.clearColor != nil
                || adj.bilevel != nil
                || adj.alphaInv
                || pf.artistic != nil
            let a = linked ? A.new().a("r:link", rid) : A.new().a("r:embed", rid)
            if hasKids {
                w.open("a:blip", a)
                if let c = adj.clearColor {
                    w.open0("a:clrChange")
                    w.open0("a:clrFrom")
                    color(&w, .rgb(c))
                    w.close("a:clrFrom")
                    w.open0("a:clrTo")
                    color(&w, ColorRef.rgb(c).with(.alpha(0)))
                    w.close("a:clrTo")
                    w.close("a:clrChange")
                }
                if let al = pf.alpha {
                    w.empty("a:alphaModFix", A.new().a("amt", pct(al.clamped(0.0, 1.0))))
                }
                if adj.alphaInv {
                    w.empty0("a:alphaInv")
                }
                if let t = adj.bilevel {
                    w.empty("a:biLevel", A.new().a("thresh", pct(t.clamped(0.0, 1.0))))
                }
                if let d = adj.duotone {
                    w.open0("a:duotone")
                    color(&w, d.a)
                    color(&w, d.b)
                    w.close("a:duotone")
                }
                if adj.grayscale {
                    w.empty0("a:grayscl")
                }
                if adj.brightness != 0.0 || adj.contrast != 0.0 {
                    w.empty("a:lum", A.new().a("bright", pct(adj.brightness.clamped(-1.0, 1.0))).a("contrast", pct(adj.contrast.clamped(-1.0, 1.0))))
                }
                // Artistic effect: the blip is the processed picture; the original rides in an
                // `a14:imgLayer` with the effect's name, as PowerPoint writes it.
                if let art = pf.artistic,
                   hasBytePrefix(art.effect, "artistic"),
                   isASCIIAlnum(art.effect),
                   let orig = x.mediaRel(o, art.original, "image")
                {
                    w.open0("a:extLst")
                    w.open("a:ext", A.new().a("uri", "{BEBA8EAE-BF5A-486C-A8C5-ECC9F3942E4B}"))
                    w.open("a14:imgProps", A.new().a("xmlns:a14", OPC.nsA14))
                    w.open("a14:imgLayer", A.new().a("r:embed", orig))
                    w.open0("a14:imgEffect")
                    w.empty0("a14:" + art.effect)
                    w.close("a14:imgEffect")
                    w.close("a14:imgLayer")
                    w.close("a14:imgProps")
                    w.close("a:ext")
                    w.close("a:extLst")
                }
                w.close("a:blip")
            } else {
                w.empty("a:blip", a)
            }
            let c = pf.crop
            if c.contains(where: { $0 != 0.0 }) {
                w.empty("a:srcRect", A.new().a("l", pct(at4(c, 0))).a("t", pct(at4(c, 1))).a("r", pct(at4(c, 2))).a("b", pct(at4(c, 3))))
            }
            switch pf.mode {
            case .stretch(let r):
                w.open0("a:stretch")
                if r.contains(where: { $0 != 0.0 }) {
                    w.empty("a:fillRect", A.new().a("l", pct(at4(r, 0))).a("t", pct(at4(r, 1))).a("r", pct(at4(r, 2))).a("b", pct(at4(r, 3))))
                } else {
                    w.empty0("a:fillRect")
                }
                w.close("a:stretch")
            case .tile(let tx, let ty, let sx, let sy, let flip, let align):
                let flip = ["x", "y", "xy"].contains { bytesEqual($0, flip) } ? flip : "none"
                let algn = ["tl", "t", "tr", "l", "ctr", "r", "bl", "b", "br"].contains { bytesEqual($0, align) } ? align : "tl"
                w.empty("a:tile", A.new().a("tx", emu(tx)).a("ty", emu(ty)).a("sx", pct(sx)).a("sy", pct(sy)).a("flip", flip).a("algn", algn))
            }
            w.close(tag)
        }

        static func line(_ w: inout W, _ x: Exp, _ o: Out, _ tag: String, _ l: Line) {
            let a = A.new()
                .o("w", l.width.map { emu($0.clamped(0.0, 1584.0)) })
                .o("cap", l.cap.map { c -> String in
                    switch c {
                    case .round: "rnd"
                    case .square: "sq"
                    case .flat: "flat"
                    }
                })
                .o("cmpd", l.compound.map(\.xml))
            w.open(tag, a)
            if let f = l.fill {
                switch f {
                case .none_, .solid, .gradient, .pattern: fill(&w, x, o, f)
                default: break
                }
            }
            switch l.dash {
            case .preset(let name)?:
                let n = Dash.presets.contains { bytesEqual($0, name) } ? name : "solid"
                w.val("a:prstDash", n)
            case .custom(let pattern)? where !pattern.isEmpty:
                w.open0("a:custDash")
                for p in pattern.prefix(64) {
                    w.empty("a:ds", A.new().a("d", Swift.max(pct(p.a), 0)).a("sp", Swift.max(pct(p.b), 0)))
                }
                w.close("a:custDash")
            default:
                break
            }
            switch l.join {
            case .round?: w.empty0("a:round")
            case .bevel?: w.empty0("a:bevel")
            case .miter?: w.empty0("a:miter")
            case nil: break
            }
            for (t, e) in [("a:headEnd", l.head), ("a:tailEnd", l.tail)] {
                if let e {
                    let kind = ["triangle", "stealth", "diamond", "oval", "arrow"].contains { bytesEqual($0, e.kind) } ? e.kind : "none"
                    func sz(_ s: String) -> String { bytesEqual(s, "sm") || bytesEqual(s, "lg") ? s : "med" }
                    w.empty(t, A.new().a("type", kind).a("w", sz(e.w)).a("len", sz(e.len)))
                }
            }
            w.close(tag)
        }

        static func shadow(_ w: inout W, _ tag: String, _ s: Shadow) {
            var a = A.new().a("blurRad", Swift.max(emu(s.blur), 0)).a("dist", Swift.max(emu(s.dist), 0)).a("dir", ang(s.dir))
            if tag == "a:outerShdw" {
                if s.sx != 1.0 {
                    a = a.a("sx", pct(s.sx))
                }
                if s.sy != 1.0 {
                    a = a.a("sy", pct(s.sy))
                }
                if s.kx != 0.0 {
                    a = a.a("kx", Int64(rustCast: (s.kx.clamped(-89.0, 89.0) * 60_000.0).rounded()))
                }
                if s.ky != 0.0 {
                    a = a.a("ky", Int64(rustCast: (s.ky.clamped(-89.0, 89.0) * 60_000.0).rounded()))
                }
                let algn = ["tl", "t", "tr", "l", "ctr", "r", "bl", "b", "br"].contains { bytesEqual($0, s.align) } ? s.align : "b"
                a = a.a("algn", algn).a("rotWithShape", s.rotateWithShape ? "1" : "0")
            }
            w.open(tag, a)
            color(&w, s.color)
            w.close(tag)
        }

        static func gradient(_ w: inout W, _ g: Gradient) {
            w.open("a:gradFill", A.new().a("rotWithShape", g.rotateWithShape ? "1" : "0"))
            // No stops: no `a:gsLst`, so the gradient keeps taking them from its style's fill.
            var stops = g.stops
            if stops.count == 1 {
                var s = stops[0]
                s.pos = 1.0
                stops.append(s)
            }
            if !stops.isEmpty {
                w.open0("a:gsLst")
                for s in stops {
                    w.open("a:gs", A.new().a("pos", pct(s.pos.clamped(0.0, 1.0))))
                    color(&w, s.color)
                    w.close("a:gs")
                }
                w.close("a:gsLst")
            }
            switch g.shape {
            case .linear(let angle, let scaled):
                w.empty("a:lin", A.new().a("ang", ang(angle)).a("scaled", scaled ? "1" : "0"))
            case .path(let path, let focus):
                let p = ["rect", "shape", "circle"].contains { bytesEqual($0, path) } ? path : "circle"
                w.open("a:path", A.new().a("path", p))
                w.empty("a:fillToRect", A.new().a("l", pct(at4(focus, 0))).a("t", pct(at4(focus, 1))).a("r", pct(at4(focus, 2))).a("b", pct(at4(focus, 3))))
                w.close("a:path")
            }
            if g.tile.contains(where: { $0 != 0.0 }) {
                let (l, t, r, b) = (at4(g.tile, 0), at4(g.tile, 1), at4(g.tile, 2), at4(g.tile, 3))
                w.empty("a:tileRect", A.new().a("l", pct(l)).a("t", pct(t)).a("r", pct(r)).a("b", pct(b)))
            }
            w.close("a:gradFill")
        }

        static func effects(_ w: inout W, _ fx: Effects) {
            w.open0("a:effectLst")
            // Schema order: blur, fillOverlay, glow, innerShdw, outerShdw, prstShdw, reflection, softEdge.
            if let ov = fx.fillOverlay {
                let blend = ["over", "mult", "screen", "darken", "lighten"].contains { bytesEqual($0, ov.blend) } ? ov.blend : "over"
                w.open("a:fillOverlay", A.new().a("blend", blend))
                switch ov.fill {
                case .solid(let c): solid(&w, c)
                case .gradient(let g): gradient(&w, g)
                default: w.empty0("a:noFill")
                }
                w.close("a:fillOverlay")
            }
            if let g = fx.glow {
                w.open("a:glow", A.new().a("rad", Swift.max(emu(g.radius), 0)))
                color(&w, g.color)
                w.close("a:glow")
            }
            if let s = fx.innerShadow {
                shadow(&w, "a:innerShdw", s)
            }
            if let s = fx.outerShadow {
                shadow(&w, "a:outerShdw", s)
            }
            if let r = fx.reflection {
                w.empty(
                    "a:reflection",
                    A.new()
                        .a("blurRad", Swift.max(emu(r.blur), 0))
                        .a("stA", pct(r.startAlpha.clamped(0.0, 1.0)))
                        .a("endA", pct(r.endAlpha.clamped(0.0, 1.0)))
                        .a("endPos", pct(r.endPos.clamped(0.0, 1.0)))
                        .a("dist", Swift.max(emu(r.dist), 0))
                        .a("dir", 5_400_000)
                        .a("sy", -100_000)
                        .a("algn", "bl")
                        .a("rotWithShape", "0")
                )
            }
            if let r = fx.softEdge {
                w.empty("a:softEdge", A.new().a("rad", Swift.max(emu(r), 0)))
            }
            w.close("a:effectLst")
        }

        /// `a:sp3d` for a bevel preset when the shape or theme style has no kept 3-D XML.
        /// The preset name is limited to ASCII letters and digits so it cannot break the markup.
        static func bevelSp3d(_ preset: String) -> String? {
            if preset.isEmpty || preset.utf8.count > 32 || !isASCIIAlnum(preset) {
                return nil
            }
            return "<a:sp3d><a:bevelT prst=\"\(preset)\"/></a:sp3d>"
        }

        static func xfrm(_ w: inout W, _ tag: String, _ x: Xfrm, _ child: Xfrm?) {
            let x = x.isFinite ? x : Xfrm()
            let rot = ang(x.rot)
            w.open(tag, A.new().o("rot", rot != 0 ? rot : nil).t("flipH", x.flipH).t("flipV", x.flipV))
            w.empty("a:off", A.new().a("x", emu(x.x)).a("y", emu(x.y)))
            w.empty("a:ext", A.new().a("cx", emuPos(x.w)).a("cy", emuPos(x.h)))
            if let c = child {
                let c = c.isFinite ? c : Xfrm()
                w.empty("a:chOff", A.new().a("x", emu(c.x)).a("y", emu(c.y)))
                w.empty("a:chExt", A.new().a("cx", emuPos(c.w)).a("cy", emuPos(c.h)))
            }
            w.close(tag)
        }

        // MARK: Text

        static func hyperlink(_ w: inout W, _ x: Exp, _ o: Out, _ tag: String, _ h: Hyperlink) {
            let rid: String
            let action: String?
            switch h.action {
            case .url(let url):
                if url.isEmpty { return }
                (rid, action) = (o.rels.add("hyperlink", url, true), nil)
            case .slide(let slide):
                guard let target = x.slideParts[slide] else { return }
                let rel = OPC.relative(o.name, target)
                (rid, action) = (o.rels.add("slide", rel, false), "ppaction://hlinksldjump")
            case .nextSlide: (rid, action) = ("", "ppaction://hlinkshowjump?jump=nextslide")
            case .previousSlide: (rid, action) = ("", "ppaction://hlinkshowjump?jump=previousslide")
            case .firstSlide: (rid, action) = ("", "ppaction://hlinkshowjump?jump=firstslide")
            case .lastSlide: (rid, action) = ("", "ppaction://hlinkshowjump?jump=lastslide")
            case .endShow: (rid, action) = ("", "ppaction://hlinkshowjump?jump=endshow")
            case .lastViewed: (rid, action) = ("", "ppaction://hlinkshowjump?jump=lastslideviewed")
            case .customShow(let name, let returns):
                let id = x.p.customShows.firstIndex { bytesEqual($0.name, name) } ?? 0
                let ret = returns ? "true" : "false"
                (rid, action) = ("", "ppaction://customshow?id=\(id)&return=\(ret)")
            case .program(let path):
                if path.isEmpty { return }
                (rid, action) = (o.rels.add("hyperlink", path, true), "ppaction://program")
            case .playMedia: (rid, action) = ("", "ppaction://media")
            }
            let attrs = A.new()
                .a("r:id", rid)
                .o("action", action)
                .o("tooltip", h.tooltip.isEmpty ? nil : h.tooltip)
                .t("highlightClick", h.highlightClick)
                .t("endSnd", h.stopSound)
            var sound: (String, MediaId)?
            if let id = h.sound, let rid = x.mediaRel(o, id, "audio") {
                sound = (rid, id)
            }
            guard let (soundRid, soundId) = sound else {
                w.empty(tag, attrs)
                return
            }
            w.open(tag, attrs)
            let name = x.p.media(soundId).map { soundLabel($0.name) } ?? "sound.wav"
            w.empty("a:snd", A.new().a("r:embed", soundRid).a("name", name))
            w.close(tag)
        }

        /// Display name PowerPoint stores on `a:snd`.
        static func soundLabel(_ name: String) -> String {
            var file = Substring(name)
            if let i = name.unicodeScalars.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
                file = name[name.unicodeScalars.index(after: i)...]
            }
            var label = String.UnicodeScalarView()
            for c in file.unicodeScalars where label.count < 80 {
                if c.isASCII && c.properties.generalCategory != .control && c != "\"" && c != "<" && c != ">" {
                    label.append(c)
                }
            }
            return label.isEmpty ? "sound.wav" : String(label)
        }

        static func bodyPr(_ w: inout W, _ b: BodyProps) {
            let a = A.new()
                .o("rot", b.rot.map { Int64(rustCast: ($0 * 60_000.0).rounded().clamped(-21_600_000.0, 21_600_000.0)) })
                .o("vert", b.vert.map(\.xml))
                .o("wrap", b.wrap.map { $0 ? "square" : "none" })
                .o("lIns", b.insetL.map(emu))
                .o("tIns", b.insetT.map(emu))
                .o("rIns", b.insetR.map(emu))
                .o("bIns", b.insetB.map(emu))
                .o("numCol", b.columns.map { Swift.min(Swift.max($0, 1), 16) })
                .o("spcCol", b.colSpacing.map { Swift.max(emu($0), 0) })
                .b("rtlCol", b.rtlCol)
                .o("anchor", b.anchor.map(\.xml))
                .b("anchorCtr", b.anchorCtr)
                .b("upright", b.upright)
                .b("spcFirstLastPara", b.spaceFirstLast)
            let warp = b.warp.flatMap { !$0.isEmpty && isASCIIAlnum($0) ? $0 : nil }
            if warp == nil && b.autofit == nil {
                w.empty("a:bodyPr", a)
                return
            }
            w.open("a:bodyPr", a)
            if let p = warp {
                w.open("a:prstTxWarp", A.new().a("prst", p))
                let adj: [(Int, Int64)] = b.warpAdj.prefix(8).enumerated().filter { $0.element.isFinite }
                    .map { ($0.offset, Int64(rustCast: $0.element.rounded().clamped(-2.0e9, 2.0e9))) }
                if adj.isEmpty {
                    w.empty0("a:avLst")
                } else {
                    let single = Warp.adjustCount(p) <= 1 && b.warpAdj.count == 1
                    w.open0("a:avLst")
                    for (i, v) in adj {
                        let n = single ? "adj" : "adj\(i + 1)"
                        w.empty("a:gd", A.new().a("name", n).a("fmla", "val \(v)"))
                    }
                    w.close("a:avLst")
                }
                w.close("a:prstTxWarp")
            }
            switch b.autofit {
            case .none_?: w.empty0("a:noAutofit")
            case .shape?: w.empty0("a:spAutoFit")
            case .shrink(let fontScale, let lineReduction)?:
                // A scale the model holds is written, 100 % included: reopening then keeps the same
                // "draw the saved scale" state instead of becoming a bare `<a:normAutofit/>` (#724).
                let fs = fontScale.map { pct($0.clamped(0.01, 1.0)) }
                let lr = pct(lineReduction.clamped(0.0, 1.0))
                w.empty("a:normAutofit", A.new().o("fontScale", fs).o("lnSpcReduction", lr != 0 ? lr : nil))
            case nil: break
            }
            w.close("a:bodyPr")
        }

        static func spacing(_ w: inout W, _ tag: String, _ s: Spacing) {
            w.open0(tag)
            switch s {
            case .pct(let v): w.val("a:spcPct", pct(v.clamped(0.0, 132.0)))
            case .pts(let v): w.val("a:spcPts", Int64(rustCast: (v.clamped(0.0, 1584.0) * 100.0).rounded()))
            }
            w.close(tag)
        }

        static func isDefaultPPr(_ p: ParaProps) -> Bool {
            p == ParaProps()
        }

        /// `a:pPr` / `a:lvlNpPr`.
        static func pPr(_ w: inout W, _ x: Exp, _ o: Out, _ tag: String, _ level: UInt8?, _ p: ParaProps, _ def: RunProps?) {
            let a = A.new()
                .o("marL", p.marginLeft.map { emu($0.clamped(0.0, 4032.0)) })
                .o("marR", p.marginRight.map { emu($0.clamped(0.0, 4032.0)) })
                .o("lvl", level.flatMap { $0 > 0 ? Swift.min($0, 8) : nil })
                .o("indent", p.indent.map { emu($0.clamped(-4032.0, 4032.0)) })
                .o("algn", p.align.map(\.xml))
                .o("defTabSz", p.defaultTab.map { Swift.max(emu($0), 0) })
                .b("rtl", p.rtl)
                .b("eaLnBrk", p.eastAsianLineBreak)
                .b("latinLnBrk", p.latinLineBreak)
                .b("hangingPunct", p.hangingPunct)
                .o("fontAlgn", p.fontAlign.flatMap { f in ["auto", "t", "ctr", "base", "b"].contains { bytesEqual($0, f) } ? f : nil })
            let hasKids = p.lineSpacing != nil
                || p.spaceBefore != nil
                || p.spaceAfter != nil
                || p.bullet != nil
                || p.bulletFont != nil
                || p.bulletColor != nil
                || p.bulletSize != nil
                || p.tabs != nil
                || def != nil
            if !hasKids {
                w.empty(tag, a)
                return
            }
            w.open(tag, a)
            if let s = p.lineSpacing {
                spacing(&w, "a:lnSpc", s)
            }
            if let s = p.spaceBefore {
                spacing(&w, "a:spcBef", s)
            }
            if let s = p.spaceAfter {
                spacing(&w, "a:spcAft", s)
            }
            if let c = p.bulletColor {
                w.open0("a:buClr")
                color(&w, c)
                w.close("a:buClr")
            }
            if let s = p.bulletSize {
                w.val("a:buSzPct", pct(s.clamped(0.25, 4.0)))
            }
            if let f = p.bulletFont {
                w.empty("a:buFont", A.new().a("typeface", f))
            }
            switch p.bullet {
            case .none_?: w.empty0("a:buNone")
            case .char(let char)?: w.empty("a:buChar", A.new().a("char", char.isEmpty ? "•" : char))
            case .autoNum(let scheme, let startAt)?:
                let s = scheme.isEmpty || !isASCIIAlnum(scheme) ? "arabicPeriod" : scheme
                w.empty("a:buAutoNum", A.new().a("type", s).o("startAt", startAt != 1 ? Swift.min(Swift.max(startAt, 1), 32767) : nil))
            case .picture(let media)?:
                if let rid = x.mediaRel(o, media, "image") {
                    w.open0("a:buBlip")
                    let linked = x.p.media(media).map { $0.data.isEmpty && $0.link != nil } ?? false
                    let a = linked ? A.new().a("r:link", rid) : A.new().a("r:embed", rid)
                    w.empty("a:blip", a)
                    w.close("a:buBlip")
                } else {
                    w.empty("a:buChar", A.new().a("char", "•"))
                }
            case nil: break
            }
            if let t = p.tabs {
                w.open0("a:tabLst")
                for tab in t.prefix(32) {
                    let al = ["ctr", "r", "dec"].contains { bytesEqual($0, tab.align) } ? tab.align : "l"
                    w.empty("a:tab", A.new().a("pos", emu(tab.pos)).a("algn", al))
                }
                w.close("a:tabLst")
            }
            if let d = def {
                rPr(&w, x, o, "a:defRPr", d)
            }
            w.close(tag)
        }

        static func typeface(_ w: inout W, _ tag: String, _ f: String?) {
            if let f {
                w.empty(tag, A.new().a("typeface", f))
            }
        }

        /// `a:rPr`, `a:defRPr`, `a:endParaRPr`.
        static func rPr(_ w: inout W, _ x: Exp, _ o: Out, _ tag: String, _ r: RunProps) {
            let a = A.new()
                .o("lang", r.lang.flatMap { $0.isEmpty ? nil : $0 })
                .o("sz", r.size.map { Int64(rustCast: ($0.clamped(1.0, 4000.0) * 100.0).rounded()) })
                .b("b", r.bold)
                .b("i", r.italic)
                .o("u", r.underline.flatMap { !$0.isEmpty && isASCIIAlnum($0) ? $0 : nil })
                .o("strike", r.strike.map { s -> String in
                    switch s {
                    case .none_: "noStrike"
                    case .single: "sngStrike"
                    case .double: "dblStrike"
                    }
                })
                .o("kern", r.kern.map { Int64(rustCast: ($0.clamped(0.0, 4000.0) * 100.0).rounded()) })
                .o("cap", r.caps.map { c -> String in
                    switch c {
                    case .none_: "none"
                    case .small: "small"
                    case .all: "all"
                    }
                })
                .o("spc", r.spacing.map { Int64(rustCast: ($0.clamped(-4000.0, 4000.0) * 100.0).rounded()) })
                .o("baseline", r.baseline.map { pct($0.clamped(-10.0, 10.0)) })
                .b("noProof", r.noProof)
            let hasFx = r.shadow != nil || r.innerShadow != nil || r.glow != nil || r.reflection != nil || r.softEdge != nil
            let hasKids = r.outline != nil
                || r.fill != nil
                || hasFx
                || r.highlight != nil
                || r.underlineColor != nil
                || r.font != nil
                || r.fontEa != nil
                || r.fontCs != nil
                || r.fontSym != nil
                || r.link != nil
                || r.hover != nil
            if !hasKids {
                w.empty(tag, a)
                return
            }
            w.open(tag, a)
            if let l = r.outline {
                line(&w, x, o, "a:ln", l)
            }
            if let f = r.fill {
                if case .background = f {} else { fill(&w, x, o, f) }
            }
            if hasFx {
                // Same child order as a shape's effect list: glow, inner shadow, outer shadow, reflection, soft edge.
                var fx = Effects()
                fx.outerShadow = r.shadow
                fx.innerShadow = r.innerShadow
                fx.glow = r.glow
                fx.reflection = r.reflection
                fx.softEdge = r.softEdge
                effects(&w, fx)
            }
            if let h = r.highlight {
                w.open0("a:highlight")
                color(&w, h)
                w.close("a:highlight")
            }
            if let c = r.underlineColor {
                w.open0("a:uFill")
                solid(&w, c)
                w.close("a:uFill")
            }
            typeface(&w, "a:latin", r.font)
            typeface(&w, "a:ea", r.fontEa)
            typeface(&w, "a:cs", r.fontCs)
            typeface(&w, "a:sym", r.fontSym)
            if let h = r.link {
                hyperlink(&w, x, o, "a:hlinkClick", h)
            }
            // Schema order: hlinkClick, hlinkMouseOver.
            if let h = r.hover {
                hyperlink(&w, x, o, "a:hlinkMouseOver", h)
            }
            w.close(tag)
        }

        /// `a:lstStyle`-like element (`a:lstStyle`, `p:titleStyle`, `p:defaultTextStyle`…).
        static func listStyle(_ w: inout W, _ x: Exp, _ o: Out, _ tag: String, _ ls: ListStyle) {
            if ls.isEmpty {
                w.empty0(tag)
                return
            }
            w.open0(tag)
            for (i, l) in ls.levels.prefix(9).enumerated() {
                if let l {
                    let t = "a:lvl\(i + 1)pPr"
                    let def = l.run != RunProps() ? l.run : nil
                    pPr(&w, x, o, t, nil, l.para, def)
                }
            }
            w.close(tag)
        }

        /// Write `<tag>` text body (`p:txBody`, `a:txBody`). `math` selects the OMML form of equations.
        static func textBody(_ w: inout W, _ x: Exp, _ o: Out, _ tag: String, _ tb: TextBody, _ math: Bool) {
            w.open0(tag)
            bodyPr(&w, tb.body)
            listStyle(&w, x, o, "a:lstStyle", tb.listStyle)
            if tb.paragraphs.isEmpty {
                w.empty0("a:p")
            }
            for (pi, p) in tb.paragraphs.enumerated() {
                paragraph(&w, x, o, p, math, pi)
            }
            w.close(tag)
        }

        static func runText(_ w: inout W, _ x: Exp, _ o: Out, _ text: String, _ props: RunProps) {
            for (i, piece) in splitScalars(text, ["\n", "\u{0B}"]).enumerated() {
                if i > 0 {
                    w.open0("a:br")
                    rPr(&w, x, o, "a:rPr", props)
                    w.close("a:br")
                }
                if piece.isEmpty && i > 0 {
                    continue
                }
                w.open0("a:r")
                rPr(&w, x, o, "a:rPr", props)
                w.elt("a:t", piece)
                w.close("a:r")
            }
        }

        static func paragraph(_ w: inout W, _ x: Exp, _ o: Out, _ p: Paragraph, _ math: Bool, _ index: Int) {
            w.open0("a:p")
            let def = p.defProps != RunProps() ? p.defProps : nil
            if p.level > 0 || !isDefaultPPr(p.props) || def != nil {
                pPr(&w, x, o, "a:pPr", p.level, p.props, def)
            }
            for (ri, r) in p.runs.enumerated() {
                switch r.kind {
                case .text:
                    runText(&w, x, o, r.text, r.props)
                case .break:
                    w.open0("a:br")
                    rPr(&w, x, o, "a:rPr", r.props)
                    w.close("a:br")
                case .field(let field):
                    let id = Tables.guid("\(o.name):\(index):\(ri):\(field)")
                    let ty = !field.isEmpty && field.unicodeScalars.allSatisfy({ isASCIIAlnumScalar($0) || $0 == "-" }) ? field : nil
                    w.open("a:fld", A.new().a("id", id).o("type", ty))
                    rPr(&w, x, o, "a:rPr", r.props)
                    w.elt("a:t", r.text)
                    w.close("a:fld")
                case .math(let omml):
                    if math && !omml.isEmpty {
                        w.open("a14:m", A.new().a("xmlns:a14", OPC.nsA14))
                        w.raw(omml)
                        w.close("a14:m")
                    } else {
                        runText(&w, x, o, r.text, r.props)
                    }
                }
            }
            if p.endProps != RunProps() {
                rPr(&w, x, o, "a:endParaRPr", p.endProps)
            }
            w.close("a:p")
        }

        static func hasMath(_ tb: TextBody) -> Bool {
            tb.paragraphs.contains { p in
                p.runs.contains { r in
                    if case .math(let omml) = r.kind { return !omml.isEmpty }
                    return false
                }
            }
        }
    }
}
