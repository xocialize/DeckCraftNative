// The tests of deckcraft crates/pptx/src/opc.rs, cfb.rs and png.rs (MIT OR Apache-2.0, © ArtCraft Team
// and the DeckCraft contributors).
@testable import DCPPTX
import DCZip
import Testing

@Suite struct OPCTests {
    @Test func resolveKeepsEncodedHashAndStripsFragment() {
        #expect(OPC.resolve("ppt/slides", "../media/a%23b.png") == "ppt/media/a#b.png")
        #expect(OPC.resolve("ppt/slides", "../media/a.png#frag") == "ppt/media/a.png")
    }

    @Test func resolvePercentDecodeRequiresTwoHexDigits() {
        #expect(OPC.resolve("ppt/slides", "../media/a%+5b.png") == "ppt/media/a%+5b.png")
        #expect(OPC.resolve("ppt/slides", "../media/a%20b.png") == "ppt/media/a b.png")
    }

    /// A zip of `x`-filled entries, deflated.
    static func zipOf(_ entries: [(String, Int)]) throws -> [UInt8] {
        var zw = ZipWriter()
        for (name, len) in entries {
            try zw.add(name, [UInt8](repeating: UInt8(ascii: "x"), count: len), compress: true)
        }
        return try zw.finish()
    }

    @Test func discardedPartsCountAgainstTheInflateBudget() throws {
        // Kept bytes cap at 100: b, c and d are inflated past what's left and discarded. That work is
        // charged, so after d the budget (130) is spent and e is not read, although it would have fit.
        let z = try Self.zipOf([("a", 80), ("b", 80), ("c", 80), ("d", 80), ("e", 5)])
        let p = try Package.openWithin(z, maxPart: 1000, maxTotal: 100, maxWork: 130)
        #expect(p.get("a") != nil)
        #expect(p.get("b") == nil && p.get("d") == nil)
        #expect(p.get("e") == nil, "the inflate budget stops reading")
        // With room to spare the same small part is kept.
        let q = try Package.openWithin(z, maxPart: 1000, maxTotal: 100, maxWork: 10_000)
        #expect(q.get("e") != nil)
    }

    @Test func xmlBytesAppliesTheXMLLimit() throws {
        let z = try Self.zipOf([("small.xml", 10)])
        let p = try Package.open(z)
        #expect(p.xmlBytes("small.xml")?.count == 10)
        #expect(p.xmlBytes("missing.xml") == nil)
    }

    @Test func resolveBackslashTarget() {
        #expect(OPC.resolve("ppt/slides", "..\\media\\image1.png") == "ppt/media/image1.png")
        #expect(OPC.resolve("ppt/slides", "\\ppt\\media\\a.png") == "ppt/media/a.png")
    }

    @Test func pathResolution() {
        #expect(OPC.resolve("ppt/slides", "../media/image1.png") == "ppt/media/image1.png")
        #expect(OPC.resolve("ppt", "slides/slide1.xml") == "ppt/slides/slide1.xml")
        #expect(OPC.resolve("ppt/slides", "/ppt/media/a%20b.png") == "ppt/media/a b.png")
        #expect(OPC.resolve("", "../../../x.xml") == "x.xml")
        #expect(OPC.relsPath("ppt/presentation.xml") == "ppt/_rels/presentation.xml.rels")
        #expect(OPC.relsPath("[Content_Types].xml") == "_rels/[Content_Types].xml.rels")
        #expect(OPC.relative("ppt/slides/slide1.xml", "ppt/media/image1.png") == "../media/image1.png")
        #expect(OPC.relative("ppt/presentation.xml", "ppt/slides/slide1.xml") == "slides/slide1.xml")
        #expect(OPC.relative("ppt/slides/slide1.xml", "ppt/slides/slide2.xml") == "slide2.xml")
    }

    @Test func sidecarPartsStayInsideChartFolders() {
        #expect(OPC.sidecarPart("ppt/embeddings/Microsoft_Excel_Worksheet1.xlsx"))
        #expect(OPC.sidecarPart("ppt/charts/style1.xml"))
        #expect(OPC.sidecarPart("ppt/drawings/chartDrawing1.xml"))
        #expect(OPC.sidecarPart("ppt/media/image1.png"))
        #expect(!OPC.sidecarPart("ppt/charts/chart1.xml"))
        #expect(!OPC.sidecarPart("ppt/charts/_rels/chart1.xml.rels"))
        #expect(!OPC.sidecarPart("ppt/slides/slide1.xml"))
        #expect(!OPC.sidecarPart("ppt/embeddings/../../ppt/slides/slide1.xml"))
        #expect(!OPC.sidecarPart("/etc/passwd"))
    }

    // MARK: Beyond the Rust tests

    @Test func duplicateNamesKeepTheLastData() throws {
        var zw = ZipWriter()
        try zw.add("a.xml", Array("<first/>".utf8))
        try zw.add("b.xml", Array("<b/>".utf8))
        try zw.add("a.xml", Array("<second/>".utf8))
        let p = try Package.open(try zw.finish())
        #expect(p.xml("A.XML")?.root.name == "second")
        #expect(p.originalName("/a.xml") == "a.xml")
    }

    @Test func relsAndContentTypes() throws {
        var out = PackageOut()
        var rels = RelsOut()
        let a = rels.add("slide", "slides/slide1.xml", false)
        let b = rels.add("slide", "slides/slide1.xml", false)
        let c = rels.addNew("http://example.com/x", "https://example.com/a b", true)
        #expect(a == "rId1" && b == "rId1" && c == "rId2")
        out.xmlPart("ppt/presentation.xml", "application/x-pres", Array("<p:presentation/>".utf8))
        out.rels("ppt/presentation.xml", rels)
        out.binary("ppt/media/image1.PNG", "image/png", [1, 2, 3])
        out.binary("ppt/media/image2.png", "image/x-other", [4])
        out.raw("ppt/presentation.xml", [9])
        let pkg = try Package.open(try out.finish())
        #expect(pkg.get("ppt/presentation.xml") == Array("<p:presentation/>".utf8), "the first of two parts is kept")
        #expect(pkg.contentType("ppt/presentation.xml") == "application/x-pres")
        #expect(pkg.contentType("ppt/media/image1.PNG") == "image/png")
        #expect(pkg.contentType("ppt/media/image2.png") == "image/x-other")
        let r = pkg.rels("ppt/presentation.xml")
        #expect(r.items.count == 2)
        #expect(r.get("rId1")?.target == "ppt/slides/slide1.xml")
        #expect(r.get("rId1")?.kind == "slide")
        #expect(r.get("rId2")?.external == true && r.target("rId2") == "https://example.com/a b")
        #expect(r.allOf("slide").count == 1 && r.firstOf("x")?.id == "rId2")
    }

    @Test func mimeTypes() {
        #expect(mimeFor("a/b.JPEG") == "image/jpeg")
        #expect(mimeFor("noext") == "application/octet-stream")
        #expect(mimeFor("x.fntdata") == "application/x-fontdata")
    }

    @Test func sniffLooksInTheCentralDirectory() throws {
        #expect(!PPTX.sniff(Array("PK".utf8)))
        var zw = ZipWriter()
        try zw.add("a", [1])
        try zw.add("[Content_Types].xml", Array("<Types/>".utf8))
        #expect(PPTX.sniff(try zw.finish()))
        #expect(!PPTX.sniff(try Self.zipOf([("a", 1)])))
    }
}

@Suite struct CFBTests {
    static let endOfChain = CFB.endOfChain

    /// A minimal valid compound file (512-byte sectors: FAT at sector 0, directory at sector 1) whose
    /// directory holds a root entry plus the given stream names.
    static func build(_ streams: [String]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 512 * 3)
        func put16(_ at: Int, _ v: UInt16) { b[at] = UInt8(v & 0xFF); b[at + 1] = UInt8(v >> 8) }
        func put32(_ at: Int, _ v: UInt32) { for k in 0 ..< 4 { b[at + k] = UInt8(v >> (8 * UInt32(k)) & 0xFF) } }
        b.replaceSubrange(0 ..< 8, with: CFB.signature)
        put16(24, 0x3E) // minor version
        put16(26, 3) // major version
        put16(28, 0xFFFE) // byte order
        put16(30, 9) // sector shift
        put16(32, 6) // mini sector shift
        put32(44, 1) // FAT sectors
        put32(48, 1) // first directory sector
        put32(60, endOfChain) // no mini FAT
        put32(68, endOfChain) // no DIFAT sectors
        for i in 0 ..< 109 { put32(76 + i * 4, 0xFFFF_FFFF) }
        put32(76, 0) // FAT lives in sector 0
        // FAT (sector 0, at byte 512): sector 0 is a FAT sector, sector 1 ends its chain.
        for i in 0 ..< 128 { put32(512 + i * 4, 0xFFFF_FFFF) }
        put32(512, 0xFFFF_FFFD)
        put32(516, endOfChain)
        // Directory (sector 1, at byte 1024).
        for (k, name) in (["Root Entry"] + streams).prefix(4).enumerated() {
            let e = 1024 + k * 128
            let units = Array(name.utf16.prefix(31))
            for (i, u) in units.enumerated() { put16(e + i * 2, u) }
            put16(e + 64, UInt16((units.count + 1) * 2))
            b[e + 66] = k == 0 ? 5 : 2
        }
        return b
    }

    @Test func readsDirectoryNames() {
        let b = Self.build(["EncryptionInfo", "EncryptedPackage"])
        #expect(CFB.directoryNames(b) == ["Root Entry", "EncryptionInfo", "EncryptedPackage"])
        #expect(CFB.isEncrypted(b))
        // A PowerPoint 97-2003 .ppt is a compound file too, without the encryption streams.
        #expect(!CFB.isEncrypted(Self.build(["PowerPoint Document", "Current User"])))
        #expect(!CFB.isEncrypted(Array("PK\u{3}\u{4}".utf8)))
    }

    @Test func hostileHeadersNeverPanic() {
        var b = Self.build(["PowerPoint Document"])
        for at in [30, 48, 68, 76, 512, 516, 1024 + 64] {
            for v: UInt32 in [0, 1, 7, 0xFFFF_FFFA, 0xFFFF_FFFF, 0x7FFF_FFFF] {
                var c = b
                for k in 0 ..< 4 { c[at + k] = UInt8(v >> (8 * UInt32(k)) & 0xFF) }
                _ = CFB.isEncrypted(c)
                for cut in [0, 8, 100, 600, 1100] {
                    _ = CFB.isEncrypted(Array(c[..<min(cut, c.count)]))
                }
            }
        }
        // A directory chain that loops back on itself stops at the bound.
        b[516] = 1
        b[517] = 0
        b[518] = 0
        b[519] = 0
        #expect(!CFB.isEncrypted(b))
    }

    /// #346: opening a password-protected presentation says so instead of failing as an unknown file.
    /// The Rust test goes through deckcraft-engine's `cmd::file::open_presentation`, which DCEngine
    /// ports in wave 4: there, `"Locked.pptx"` with the encryption streams fails with an error that
    /// contains "Locked.pptx is password-protected", and `"Old.ppt"` (a 97-2003 compound file) with one
    /// that doesn't mention a password. Enable it, calling DCEngine, when that lands.
    @Test(.disabled("needs DCEngine (wave 4)"))
    func aPasswordProtectedPresentationIsNamedAsSuch() {
        #expect(PPTX.isEncrypted(Self.build(["EncryptionInfo", "EncryptedPackage"])))
        #expect(!PPTX.isEncrypted(Self.build(["PowerPoint Document", "Current User"])))
    }
}

@Suite struct PNGTests {
    @Test func crcKnown() {
        #expect(PNG.crc32(Array("IEND".utf8)) == 0xAE42_6082)
        #expect(PNG.transparent1x1().starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }
}
