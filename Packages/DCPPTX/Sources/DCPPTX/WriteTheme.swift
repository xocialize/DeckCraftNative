// DCPPTX — theme parts. Port of deckcraft crates/pptx/src/write/theme.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCModel

extension PPTXWrite {
    /// The `write::theme` module.
    enum Themes {
        static func fontSet(_ w: inout W, _ tag: String, _ f: FontSet) {
            w.open0(tag)
            w.empty("a:latin", A.new().a("typeface", f.latin.isEmpty ? "Arial" : f.latin))
            w.empty("a:ea", A.new().a("typeface", f.ea))
            w.empty("a:cs", A.new().a("typeface", f.cs))
            for sf in f.scripts {
                w.empty("a:font", A.new().a("script", sf.script).a("typeface", sf.typeface))
            }
            w.close(tag)
        }

        static func styleFill(_ f: Fill) -> Fill {
            switch f {
            case .background, .group: .solid(.scheme(.phClr))
            default: f
            }
        }

        static func themeXML(_ x: Exp, _ o: Out, _ t: Theme) -> [UInt8] {
            var w = W.new()
            w.open("a:theme", A.new().a("xmlns:a", OPC.nsA).a("xmlns:r", OPC.nsR).a("name", t.name.isEmpty ? "Theme" : t.name))
            w.open0("a:themeElements")
            w.open("a:clrScheme", A.new().a("name", t.colors.name.isEmpty ? t.name : t.colors.name))
            for slot in SchemeSlot.theme {
                let tag = "a:" + slot.xmlName
                w.open0(tag)
                w.val("a:srgbClr", t.colors.get(slot).hex)
                w.close(tag)
            }
            w.close("a:clrScheme")
            w.open("a:fontScheme", A.new().a("name", t.fonts.name.isEmpty ? t.name : t.fonts.name))
            fontSet(&w, "a:majorFont", t.fonts.major)
            fontSet(&w, "a:minorFont", t.fonts.minor)
            w.close("a:fontScheme")
            let d = defaultFormat()
            let f = t.format
            w.open("a:fmtScheme", A.new().a("name", f.name.isEmpty ? t.name : f.name))
            func three(_ v: [Fill], _ d: [Fill]) -> [Fill] {
                var out = v.map(styleFill)
                while out.count < 3 {
                    out.append(d.at(out.count) ?? .solid(.scheme(.phClr)))
                }
                return out
            }
            w.open0("a:fillStyleLst")
            for fl in three(f.fills, d.fills) {
                DML.fill(&w, x, o, fl)
            }
            w.close("a:fillStyleLst")
            w.open0("a:lnStyleLst")
            var lines = f.lines
            while lines.count < 3 {
                lines.append(d.lines.at(lines.count) ?? Line())
            }
            for var l in lines {
                if l.fill == nil {
                    l.fill = .solid(.scheme(.phClr))
                }
                if let fl = l.fill {
                    l.fill = styleFill(fl)
                }
                DML.line(&w, x, o, "a:ln", l)
            }
            w.close("a:lnStyleLst")
            w.open0("a:effectStyleLst")
            var fx = f.effects
            while fx.count < 3 {
                fx.append(Effects())
            }
            for e in fx {
                w.open0("a:effectStyle")
                DML.effects(&w, e)
                if let raw = e.raw3d {
                    w.raw(raw)
                } else if let xml = e.bevel.flatMap(DML.bevelSp3d) {
                    w.raw(xml)
                }
                w.close("a:effectStyle")
            }
            w.close("a:effectStyleLst")
            w.open0("a:bgFillStyleLst")
            for fl in three(f.bgFills, d.bgFills) {
                DML.fill(&w, x, o, fl)
            }
            w.close("a:bgFillStyleLst")
            w.close("a:fmtScheme")
            w.close("a:themeElements")
            switch t.rawExtra {
            case let raw? where utf8Contains(raw, "objectDefaults"):
                w.raw(raw)
            case let raw?:
                w.empty0("a:objectDefaults")
                w.raw(raw)
            case nil:
                w.empty0("a:objectDefaults")
                w.empty0("a:extraClrSchemeLst")
            }
            w.close("a:theme")
            return w.finish()
        }
    }
}
