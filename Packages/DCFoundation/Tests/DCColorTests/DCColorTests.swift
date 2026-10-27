// Ported from deckcraft crates/color/src/lib.rs tests (MIT OR Apache-2.0), plus JSON shape checks.
import DCColor
import DCCore
import Testing

@Suite struct ColorTests {
    @Test func fromHexRejectsMultipleHashes() {
        #expect(Rgba.fromHex("##FF0000") == nil)
        #expect(Rgba.fromHex("####FF0000") == nil)
        #expect(Rgba.fromHex("#FF0000") == .rgb(255, 0, 0))
        #expect(Rgba.fromHex("FF0000") == .rgb(255, 0, 0))
        #expect(Rgba.fromHex("#FF000080") == .rgba(255, 0, 0, 128))
    }

    @Test func fromHexRejectsSigns() {
        #expect(Rgba.fromHex("+12345") == nil)
        #expect(Rgba.fromHex("#+1+2+3") == nil)
        #expect(Rgba.fromHex("+1+2+3+4") == nil)
        #expect(Rgba.fromHex("+12") == nil)
    }

    @Test func hexRoundtrip() {
        #expect(Rgba.fromHex("#156082") == .rgb(0x15, 0x60, 0x82))
        #expect(Rgba.rgb(0x15, 0x60, 0x82).hex == "156082")
        #expect(Rgba.fromHex("fff") == .white)
        #expect(Rgba.fromHex("zz0000") == nil)
        #expect(Rgba.fromHex("ééé") == nil)
        #expect(Rgba.fromHex("") == nil)
    }

    @Test func hslRoundtrip() {
        for c in [Rgba.rgb(10, 200, 30), .rgb(255, 0, 0), .rgb(128, 128, 128), .rgb(21, 96, 130)] {
            let (h, s, l) = c.toHSL
            let d = Rgba.fromHSL(h, s, l, 255)
            #expect(abs(Int(d.r) - Int(c.r)) <= 1 && abs(Int(d.g) - Int(c.g)) <= 1 && abs(Int(d.b) - Int(c.b)) <= 1, "\(c) \(d)")
        }
    }

    @Test func transforms() {
        let c = Rgba.rgb(0x40, 0x80, 0xC0)
        #expect(applyTransforms(c, [.alpha(50000)]).a == 128)
        let lighter = applyTransforms(c, [.lumMod(20000), .lumOff(80000)])
        #expect(lighter.luminance > c.luminance)
        let darker = applyTransforms(c, [.lumMod(50000)])
        #expect(darker.luminance < c.luminance)
        #expect(applyTransforms(.white, [.shade(0)]) == .black)
        #expect(applyTransforms(.black, [.tint(0)]) == .white)
        #expect(applyTransforms(c, [.inv]) == .rgb(0xBF, 0x7F, 0x3F))
        // hostile values never trap
        _ = applyTransforms(c, [.lumMod(.max), .hueOff(.min), .alphaMod(.min)])
    }

    @Test func contrastRatio() {
        #expect(abs(Rgba.black.contrast(.white) - 21.0) < 0.01)
        #expect(abs(Rgba.white.contrast(.white) - 1.0) < 1e-9)
    }

    @Test func schemeSlots() {
        var s = ColorScheme(name: "t", colors: Array(repeating: .black, count: 12))
        s.set(.accent3, .white)
        #expect(s.get(.accent3) == .white)
        #expect(s.get(.tx1) == .black)
        for slot in SchemeSlot.theme {
            #expect(SchemeSlot.fromXML(slot.xmlName) == slot)
        }
    }

    /// The shapes serde writes: plain structs, an adjacently tagged transform list, camelCase slots.
    @Test func jsonMatchesSerde() throws {
        let w = JSONWriter()
        #expect(w.string(Rgba.rgba(1, 2, 3, 4).toJSON()) == #"{"r":1,"g":2,"b":3,"a":4}"#)
        #expect(w.string([ColorTransform.tint(75000), .comp].toJSON()) == #"[{"op":"tint","val":75000},{"op":"comp"}]"#)
        #expect(w.string(SchemeSlot.folHlink.toJSON()) == #""folHlink""#)
        let back = try [ColorTransform](fromJSON: try JSONParser.parse(#"[{"op":"lumMod","val":-5},{"op":"gray","val":null}]"#))
        #expect(back == [.lumMod(-5), .gray])
        #expect(throws: JSONDecodeError.self) { try ColorTransform(fromJSON: try JSONParser.parse(#"{"op":"tint"}"#)) }
        #expect(throws: JSONDecodeError.self) { try ColorScheme(fromJSON: try JSONParser.parse(#"{"name":"x","colors":[]}"#)) }
    }
}
