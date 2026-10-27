// DCPPTX — theme parts (`a:theme`). Port of deckcraft crates/pptx/src/read/theme.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCModel

extension PPTXRead {
    static func fontSet(_ e: XMLEl?) -> FontSet {
        func tf(_ n: String) -> String { e?.child(n)?.attr("typeface") ?? "" }
        let scripts: [ScriptFont] = e.map { e in
            Array(e.childrenNamed("font").lazy.compactMap { f -> ScriptFont? in
                guard let script = f.attr("script") else { return nil }
                return ScriptFont(script: script, typeface: f.attr("typeface") ?? "")
            }.prefix(256))
        } ?? []
        return FontSet(latin: tf("latin"), ea: tf("ea"), cs: tf("cs"), scripts: scripts)
    }

    static func readTheme(_ imp: Imp, _ part: Part, _ root: XMLEl) -> Theme {
        var t = Theme.default
        t.name = root.attr("name") ?? "Theme"
        guard let te = root.child("themeElements") else { return t }
        if let cs = te.child("clrScheme") {
            var scheme = ColorScheme(name: cs.attr("name") ?? "", colors: t.colors.colors)
            for slot in SchemeSlot.theme {
                guard let c = cs.child(slot.xmlName).flatMap(color) else { continue }
                let rgb: Rgba
                switch c.base {
                case .rgb(let v): rgb = v
                case .system(_, let last): rgb = last
                case .preset(let name): rgb = presetColor(name) ?? .black
                case .scheme: continue
                }
                scheme.set(slot, rgb)
            }
            t.colors = scheme
        }
        if let fs = te.child("fontScheme") {
            t.fonts = FontScheme(name: fs.attr("name") ?? "", major: fontSet(fs.child("majorFont")), minor: fontSet(fs.child("minorFont")))
        }
        if let fm = te.child("fmtScheme") {
            let dflt = defaultFormat()
            var f = FormatScheme(name: fm.attr("name") ?? "")
            if let l = fm.child("fillStyleLst") {
                f.fills = l.elements.prefix(16).compactMap { fillEl(imp, part, $0) }
            }
            if let l = fm.child("lnStyleLst") {
                f.lines = l.childrenNamed("ln").prefix(16).map { line(imp, part, $0) }
            }
            if let l = fm.child("effectStyleLst") {
                f.effects = l.childrenNamed("effectStyle").prefix(16).map { e in
                    var fx = e.child("effectLst").map(effects) ?? Effects()
                    if let b = e.path(["sp3d", "bevelT"]) {
                        fx.bevel = b.attr("prst") ?? "circle"
                    }
                    let raw = e.elements.filter { $0.is("scene3d") || $0.is("sp3d") }.map { part.keep($0) }.joined()
                    if !raw.isEmpty { fx.raw3d = raw }
                    return fx
                }
            }
            if let l = fm.child("bgFillStyleLst") {
                f.bgFills = l.elements.prefix(16).compactMap { fillEl(imp, part, $0) }
            }
            // The style matrix needs three entries of each kind.
            pad(&f.fills, dflt.fills)
            pad(&f.lines, dflt.lines)
            pad(&f.bgFills, dflt.bgFills)
            while f.effects.count < 3 { f.effects.append(Effects()) }
            t.format = f
        }
        let extra = root.elements
            .filter { ($0.is("objectDefaults") || $0.is("extraClrSchemeLst")) && !hasRelRefs($0) }
            .map { part.keep($0) }
            .joined()
        if !extra.isEmpty { t.rawExtra = extra }
        return t
    }

    static func pad<T>(_ v: inout [T], _ d: [T]) {
        while v.count < 3 {
            guard let x = d.at(v.count) else { break }
            v.append(x)
        }
    }
}
