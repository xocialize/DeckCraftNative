// DCPPTX — table styles: our style ids ↔ table style GUIDs, and `tableStyles.xml` definitions for the
// styles we write (generated from theme accents, matching how DeckCraft draws them). Port of deckcraft
// crates/pptx/src/tables.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCModel

/// The `tables` module.
enum Tables {
    /// Well-known built-in table style GUIDs (format identifiers) and our equivalent ids.
    static let known: [(guid: String, style: String)] = [
        ("{2D5ABB26-0587-4C30-8999-92F81FD0307C}", "none"),
        ("{5940675A-B579-460E-94D1-54222C63F5DA}", "grid"),
        ("{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}", "medium2-accent1"),
        ("{073A0DAA-6AF3-43AB-8588-CEC1D06C72B9}", "medium2-tx1"),
        ("{21E4AEA4-8DFA-4A89-87EB-49C32662AFE8}", "medium2-accent2"),
        ("{F5AB1C69-6EDB-4FF4-983F-18BD219EF322}", "medium2-accent3"),
        ("{00A15C55-8517-42AA-B614-E9B94910E393}", "medium2-accent4"),
        ("{7DF18680-E054-41AD-8BC1-D1AEF772440D}", "medium2-accent5"),
        ("{93296810-A885-4BE3-A3E7-6D5BEEA58F35}", "medium2-accent6"),
    ]

    /// GUIDs we write as built-in references (no definition needed).
    static let builtinWrite = ["none", "grid", "medium2-accent1"]

    static func fnv(_ s: String, _ seed: UInt64) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0100_0000_01b3
        }
        return h
    }

    /// A stable GUID derived from text (version-4 layout).
    static func guid(_ text: String) -> String {
        let a = fnv(text, 0x5163_7261_6674)
        let b = fnv(text, 0x7461_626c_6573)
        return "{" + rustHex(UInt32(truncatingIfNeeded: a >> 32), width: 8) + "-" + rustHex(UInt16(truncatingIfNeeded: a >> 16), width: 4)
            + "-4" + rustHex(UInt16(truncatingIfNeeded: a & 0x0fff), width: 3) + "-8"
            + rustHex(UInt16(truncatingIfNeeded: b >> 48) & 0x0fff, width: 3) + "-" + rustHex(b & 0xffff_ffff_ffff, width: 12) + "}"
    }

    static func ownGUID(_ style: String) -> String {
        guid("deckcraft-table-style:" + style)
    }

    private static func asciiUppercase(_ s: String) -> String {
        String(decoding: s.utf8.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 32 : $0 }, as: UTF8.self)
    }

    /// Is `g` the GUID DeckCraft writes for one of its own styles?
    static func isOwnGUID(_ g: String) -> Bool {
        let up = asciiUppercase(g)
        return tableStyles().contains { bytesEqual(ownGUID($0.id), up) }
    }

    /// Table style GUID → our style id (or the GUID itself when unknown).
    static func styleFromGUID(_ g: String) -> String {
        let up = asciiUppercase(g)
        if let k = known.first(where: { bytesEqual($0.guid, up) }) { return k.style }
        for (id, _) in tableStyles() where bytesEqual(ownGUID(id), up) {
            return id
        }
        return g.isEmpty ? "none" : g
    }

    /// GUID to write for our style id, and whether a definition must be written.
    static func guidForStyle(_ style: String) -> (guid: String, define: Bool) {
        if hasBytePrefix(style, "{") { return (style, false) }
        if builtinWrite.contains(where: { bytesEqual($0, style) }), let k = known.first(where: { bytesEqual($0.style, style) }) {
            return (k.guid, false)
        }
        let isKnown = tableStyles().contains { bytesEqual($0.id, style) }
        return isKnown ? (ownGUID(style), true) : ("{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}", false)
    }

    private static func clr(_ w: inout W, _ slot: String, _ mods: [(String, Int32)]) {
        if mods.isEmpty {
            w.val("a:schemeClr", slot)
            return
        }
        w.open("a:schemeClr", A().a("val", slot))
        for (n, v) in mods {
            w.val(n, v)
        }
        w.close("a:schemeClr")
    }

    private static func solid(_ w: inout W, _ slot: String, _ mods: [(String, Int32)]) {
        w.open0("a:fill")
        w.open0("a:solidFill")
        clr(&w, slot, mods)
        w.close("a:solidFill")
        w.close("a:fill")
    }

    private static func borders(_ w: inout W, _ b: (slot: String, mods: [(String, Int32)], width: Int32)?) {
        w.open0("a:tcBdr")
        if let (slot, mods, width) = b {
            for side in ["a:left", "a:right", "a:top", "a:bottom", "a:insideH", "a:insideV"] {
                w.open0(side)
                w.open("a:ln", A().a("w", width).a("cmpd", "sng"))
                w.open0("a:solidFill")
                clr(&w, slot, mods)
                w.close("a:solidFill")
                w.close("a:ln")
                w.close(side)
            }
        }
        w.close("a:tcBdr")
    }

    private static func txt(_ w: inout W, _ bold: Bool, _ color: String?) {
        w.open("a:tcTxStyle", A().o("b", bold ? "on" : nil))
        w.open("a:fontRef", A().a("idx", "minor"))
        w.val("a:prstClr", "black")
        w.close("a:fontRef")
        w.val("a:schemeClr", color ?? "dk1")
        w.close("a:tcTxStyle")
    }

    /// Write one `a:tblStyle` for our style id.
    private static func styleDef(_ w: inout W, _ id: String, _ name: String) {
        let kind = id.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "medium2"
        let last = id.utf8.lastIndex(of: UInt8(ascii: "-")).map { String(id[id.utf8.index(after: $0)...]) } ?? id
        let acc = if last == "tx1" { "dk1" } else if hasBytePrefix(last, "accent") { last } else { "accent1" }
        w.open("a:tblStyle", A().a("styleId", ownGUID(id)).a("styleName", name))
        func part(
            _ tag: String, _ bold: Bool, _ text: String?, _ fill: (String, [(String, Int32)])?, _ bdr: (String, [(String, Int32)], Int32)?
        ) {
            w.open0(tag)
            if bold || text != nil {
                txt(&w, bold, text)
            }
            w.open0("a:tcStyle")
            borders(&w, bdr)
            if let (s, m) = fill {
                solid(&w, s, m)
            }
            w.close("a:tcStyle")
            w.close(tag)
        }
        switch kind {
        case "grid":
            part("a:wholeTbl", false, "dk1", nil, ("dk1", [], 9525))
        case "light1":
            part("a:wholeTbl", false, "dk1", nil, nil)
            part("a:band1H", false, nil, (acc, [("a:tint", 20000)]), nil)
            part("a:band1V", false, nil, (acc, [("a:tint", 20000)]), nil)
            part("a:lastCol", true, nil, nil, nil)
            part("a:firstCol", true, nil, nil, nil)
            part("a:lastRow", true, nil, nil, nil)
            part("a:firstRow", true, nil, nil, (acc, [], 12700))
        case "light2":
            part("a:wholeTbl", false, "dk1", nil, (acc, [], 12700))
            // Schema order: … lastCol, firstCol, lastRow, …, firstRow.
            part("a:firstCol", true, nil, nil, nil)
            part("a:lastRow", true, nil, nil, nil)
            part("a:firstRow", true, "lt1", (acc, []), (acc, [], 12700))
        case "dark1":
            part("a:wholeTbl", false, "lt1", (acc, [("a:shade", 75000)]), ("lt1", [], 12700))
            part("a:band1H", false, nil, (acc, [("a:shade", 60000)]), nil)
            part("a:band1V", false, nil, (acc, [("a:shade", 60000)]), nil)
            part("a:firstCol", true, nil, nil, nil)
            part("a:lastRow", true, nil, nil, nil)
            part("a:firstRow", true, "lt1", ("dk1", []), nil)
        case "medium4":
            part("a:wholeTbl", false, "dk1", (acc, [("a:tint", 20000)]), (acc, [], 9525))
            part("a:band1H", false, nil, (acc, [("a:tint", 40000)]), nil)
            part("a:band1V", false, nil, (acc, [("a:tint", 40000)]), nil)
            part("a:lastCol", true, nil, nil, nil)
            part("a:firstCol", true, nil, nil, nil)
            part("a:lastRow", true, nil, nil, nil)
            part("a:firstRow", true, nil, (acc, [("a:tint", 40000)]), nil)
        default:
            // medium2
            part("a:wholeTbl", false, "dk1", (acc, [("a:tint", 20000)]), ("lt1", [], 12700))
            part("a:band1H", false, nil, (acc, [("a:tint", 40000)]), nil)
            part("a:band1V", false, nil, (acc, [("a:tint", 40000)]), nil)
            part("a:lastCol", true, "lt1", (acc, []), nil)
            part("a:firstCol", true, "lt1", (acc, []), nil)
            part("a:lastRow", true, "lt1", (acc, []), nil)
            part("a:firstRow", true, "lt1", (acc, []), nil)
        }
        w.close("a:tblStyle")
    }

    /// Does a definition read back as one `a:tblStyle`?
    private static func isStyleDefinition(_ raw: String) -> Bool {
        (try? XML.parse(Array(raw.utf8)))?.root.is("tblStyle") ?? false
    }

    /// `ppt/tableStyles.xml` with definitions for the styles in `used`: ours, generated, and those the
    /// opened file defined (`defs`), written back as they were read.
    static func tableStylesXML(_ used: [String], _ defs: [TableStyleDef]) -> [UInt8] {
        var w = W.new()
        w.open("a:tblStyleLst", A().a("xmlns:a", OPC.nsA).a("def", "{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"))
        let names = tableStyles()
        var done: [String] = []
        for s in used {
            if done.contains(where: { bytesEqual($0, s) }) { continue }
            done.append(s)
            if let d = defs.first(where: { eqIgnoreASCIICase($0.id, s) }), isStyleDefinition(d.raw) {
                w.raw(d.raw)
                continue
            }
            let (_, define) = guidForStyle(s)
            if !define { continue }
            let name = names.first { bytesEqual($0.id, s) }.map { "DeckCraft " + $0.label } ?? s
            styleDef(&w, s, name)
        }
        // Styles the file defined but no table uses still belong to the deck.
        for d in defs {
            if done.contains(where: { eqIgnoreASCIICase($0, d.id) }) { continue }
            if isStyleDefinition(d.raw) {
                done.append(d.id)
                w.raw(d.raw)
            }
        }
        w.close("a:tblStyleLst")
        return w.finish()
    }
}
