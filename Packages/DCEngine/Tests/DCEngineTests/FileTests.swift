// DCEngineTests — the File menu: new from templates, open (native, PPTX, outlines, damaged files),
// save and export, File › Info, properties, the Print page's ranges, and the file reads and writes.
// Ports the file tests of deckcraft crates/engine/src/tests.rs, cmd/file.rs, io.rs and templates.rs (MIT
// OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
@testable import DCEngine
import DCFormat
import DCGeometry
import DCModel
import DCPPTX
import DCRender
import DCText
import DCZip
import Foundation
import Testing

/// DeckCraft Colr Squares (deckcraft's crates/render/tests/fixtures/colr-squares.ttf, CC0-1.0).
private let colrSquares = """
AAEAAAAMAIAAAwBAQ09MUgAHAD0AAAM8AAAAJkNQQUwA//8SAAADZAAAABZPUy8yRQA3FQAAAUgAAABgY21hcL/yIJ0AAAG4AAAAPGdseWaixKS4\
AAACBAAAAGRoZWFkMOIGKAAAAMwAAAA2aGhlYQfRA+oAAAEEAAAAJGhtdHgD6AAAAAABqAAAAA5sb2NhAEoAMAAAAfQAAAAObWF4cAAIAAYAAAEo\
AAAAIG5hbWWljbI7AAACaAAAAI1wb3N0Ig/kjgAAAvgAAABEAAEAAAABAADEZcueXw889QABA+gAAAAA5vLgsAAAAADm8uCwAAAAAAPoA+gAAAAD\
AAIAAAAAAAAAAQAAA+gAAAAAA+gAAAAAA+gAAQAAAAAAAAAAAAAAAAAAAAEAAQAAAAYABAABAAAAAAACAAAAAAAAAAAAAAAAAAAAAAADA+gBkAAF\
AAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEQAAAAAAAAAAAAAAA/Pz8/AAAAIOABA+gAAAAAA+gAAAAAAAAAAAAAAAAAAAAA\
ACAAAAPoAAAAAAAAAAAAAAAAAAAAAAACAAAAAwAAABQAAwABAAAAFAAEACgAAAAGAAQAAQACACDgAf//AAAAIOAA////4SACAAEAAAAAAAAAAAAA\
AAAADAAYACQAMgAAAAEAAAAAA+gD6AADAAAxESERA+gD6PwYAAEAAAAAA+gD6AADAAAxESERA+gD6PwYAAEAAAAAA+gD6AADAAAxESERA+gD6PwY\
AAEBLAEsArwCvAADAAABESERASwBkAEsAZD+cAAAAAQANgABAAAAAAABABYAAAABAAAAAAACAAcAFgADAAEECQABACwAHQADAAEECQACAA4ASURl\
Y2tDcmFmdCBDb2xyIFNxdWFyZXNSZWd1bGFyAEQAZQBjAGsAQwByAGEAZgB0ACAAQwBvAGwAcgAgAFMAcQB1AGEAcgBlAHMAUgBlAGcAdQBsAGEA\
cgAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAYAAAADAQIBAwEEAQUHcmVkYmx1ZQNpbmsDYmlnBXNtYWxsAAAAAgAAAA4AAAAa\
AAMAAgAAAAIAAwACAAEABAAAAAUAAQAE//8AAAAAAAIAAQACAAAADgAAAAD///8AAP8AAA==
"""

/// A one-slide deck whose title is set in `font`, as base64 `.pptx` bytes.
private func deckInFont(_ font: String) throws -> String {
    var p = Presentation.default
    var body = TextBody.fromText("Hello")
    body.paragraphs[0].runs[0].props.font = font
    p.slides[0].shapes[0].text = body
    return Cmd.base64Encode(try FileCommands.saveBytes(p, "pptx"))
}

private func pngSize(_ b: [UInt8]) -> (Int, Int)? {
    guard b.count >= 24 else { return nil }
    func be(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
    return (be(16), be(20))
}

@Suite("File")
struct FileTests {
    @Test func writableFormatForPathRejectsFormatsDeckCraftDoesNotWrite() {
        let f = FileCommands.writableFormatForPath
        #expect(f("a.deckcraft") == "deckcraft")
        #expect(f("dir/A.PPTX") == "pptx")
        #expect(f("a.pdf") == "pdf")
        #expect(f("a.jpg") == "jpeg")
        #expect(f("a.txt") == "outline")
        #expect(f("a.gif") == "gif")
        for path in ["a.odp", "a.bmp", "a.svg", "a.outline", "a", "dir.v2/a", ".deckcraft"] {
            #expect(f(path) == nil, "\(path)")
        }
    }

    @Test func saveAndReopenNative() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "twoContent", "title": "Kept"}"#)
        let bytes = try #require(s.run("file.saveBytes").get("data")?.asStr)
        let n = s.st.doc.slides.count
        s.run("file.openBytes", "{\"name\": \"x.deckcraft\", \"data\": \"\(bytes)\"}")
        #expect(s.st.doc.slides.count == n)
        #expect(s.documents.count == 2)
        #expect(s.st.displayTitle == "x")
        #expect(s.st.path == nil, "bytes have no file to save back to")
        #expect(s.st.doc.slides[1].title == "Kept")
    }

    @Test func pptxSavesAndOpensBack() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "titleAndContent", "title": "Agenda", "body": "One\n\tTwo"}"#)
        let data = try #require(s.run("file.saveBytes", #"{"format": "pptx"}"#).get("data")?.asStr)
        let bytes = try #require(Cmd.base64Decode(data))
        #expect(PPTX.sniff(bytes))
        let r = s.run("file.openBytes", "{\"name\": \"deck.pptx\", \"data\": \"\(data)\"}")
        #expect(r.get("lostSlides") == [] && r.get("damagedMedia") == [])
        #expect(s.st.doc.slides.map(\.title) == ["", "Agenda"])
    }

    @Test func fileInfoReportsThePresentation() throws {
        let s = session()
        s.run("slide.new")
        s.run("slide.new")
        s.run("slide.go", #"{"index": 1}"#)
        s.run("slide.hide")
        s.run("file.properties", #"{"title": "Quarterly", "author": "Ada"}"#)
        var v = s.run("file.info")
        #expect(v.get("slides") == 3)
        #expect(v.get("hiddenSlides") == 1)
        #expect(v.get("path") == .null)
        #expect(v.get("dirty") == true)
        #expect(v.get("properties")?.get("title") == "Quarterly")
        #expect(v.get("properties")?.get("author") == "Ada")
        #expect(v.get("title")?.asStr.map { !$0.isEmpty } == true)
        // A query: no undo step, and nothing changes.
        let before = s.st.history.undo.count
        s.run("file.info")
        #expect(s.st.history.undo.count == before)
        // Saved to disk, it reports where and how big.
        let dir = scratchDir("info")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "Info test.pptx").path
        s.run("file.saveAs", JSON.object(JSONObject(["path": .string(path)])).display)
        v = s.run("file.info")
        #expect(v.get("path")?.asStr == path)
        #expect(v.get("format") == "pptx")
        #expect(v.get("dirty") == false)
        #expect((v.get("bytes")?.asU64 ?? 0) > 0)
        #expect(v.get("title") == "Info test")
        // Nothing open: an error, not a trap.
        #expect(Session().fails("file.info"))
    }

    /// The Print page's Slides box (#76): PowerPoint-style ranges, 1-based.
    @Test func slideRangesParseLikePowerPointsPrintBox() throws {
        let r = FileCommands.parseSlideRange
        #expect(try r("1-3, 5", 6) == [0, 1, 2, 4])
        #expect(try r("3-1;2", 6) == [0, 1, 2], "reversed ranges and repeats")
        #expect(try r(" 6 ", 6) == [5])
        #expect(throws: EngineError.self, "past the last slide") { try r("7", 6) }
        #expect(throws: EngineError.self) { try r("0", 6) }
        #expect(throws: EngineError.self) { try r("a-b", 6) }
        #expect(throws: EngineError.self) { try r(" , ", 6) }
        #expect(throws: EngineError.self, "hostile numbers are refused") { try r("1-99999999999999999999999", 6) }
        // file.export takes the same text for a PDF.
        let s = session()
        s.run("slide.new")
        let doc = s.st.doc
        let one = try FileCommands.pdfBytes(doc, ["slides": "2"])
        let both = try FileCommands.pdfBytes(doc, ["slides": "1-2"])
        #expect(one.count < both.count)
        #expect(throws: EngineError.self) { try FileCommands.pdfBytes(doc, ["slides": "5"]) }
        let opts = try FileCommands.pdfOptions(j(#"{"slides": [0, 7, 1]}"#), 2)
        #expect(opts.slides == [0, 1], "indices past the end are dropped")
    }

    /// The Print page's paper and orientation reach the PDF options; Letter portrait by default.
    @Test func pdfOptionsTakePaperAndOrientation() throws {
        var o = try FileCommands.pdfOptions(.emptyObject, 1)
        #expect(o.paper == (612.0, 792.0))
        o = try FileCommands.pdfOptions(j(#"{"paper": "A4", "orientation": "landscape"}"#), 1)
        #expect(o.paper == (841.89, 595.28))
        o = try FileCommands.pdfOptions(j(#"{"paper": "legal"}"#), 1)
        #expect(o.paper == (612.0, 1008.0))
        #expect(throws: EngineError.self) { try FileCommands.pdfOptions(j(#"{"paper": "tabloid"}"#), 1) }
        #expect(throws: EngineError.self) { try FileCommands.pdfOptions(j(#"{"orientation": "sideways"}"#), 1) }
        o = try FileCommands.pdfOptions(j(#"{"layout": "handouts", "perPage": 99, "dpi": 5, "textLayer": false}"#), 1)
        #expect(o.layout == .handouts(perPage: 9) && o.dpi == 36 && !o.textLayer)
    }

    @Test func outlineRTFExportsAndOpensBack() throws {
        let s = session()
        s.run("slide.fromOutline", #"{"text": "Roadmap\n\tShip 1.0\n\t\tLinux first\n"}"#)
        let dir = scratchDir("rtf")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "deck.rtf").path
        s.run("file.export", JSON.object(JSONObject(["path": .string(path)])).display)
        let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(bytes.starts(with: Array("{\\rtf1".utf8)))
        let text = FileCommands.outlineText(bytes)
        #expect(text.contains("Roadmap\n\tShip 1.0\n\t\tLinux first\n"), "\(text)")
        s.run("file.open", JSON.object(JSONObject(["path": .string(path)])).display)
        #expect(s.st.doc.slides.contains { $0.title == "Roadmap" })
        #expect(s.st.path == nil, "an outline opens as a new presentation")
    }

    @Test func damagedNativeFileOpensAsRepairedCopy() throws {
        var p = Presentation.default
        _ = p.addMedia("a.png", "image/png", Array("PICTURE-BYTES-0123456789".utf8))
        let good = try DeckFormat.save(p)
        // PNGs are stored as they are, so flipping a byte breaks the entry's CRC.
        var bad = good
        let needle = Array("PICTURE-BYTES".utf8)
        let at = try #require((0 ... (bad.count - needle.count)).first { Array(bad[$0 ..< $0 + needle.count]) == needle })
        bad[at] ^= 0xff
        let dir = scratchDir("392")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, bytes, damaged) in [("good.deckcraft", good, false), ("bad.deckcraft", bad, true)] {
            let path = dir.appending(path: name)
            try Data(bytes).write(to: path)
            let s = Session()
            let r = s.run("file.open", JSON.object(JSONObject(["path": .string(path.path)])).display)
            #expect(r.get("damagedMedia")?.asArray?.count == (damaged ? 1 : 0), "\(r.display)")
            #expect((s.st.path == nil) == damaged, "\(name)")
            #expect(s.st.title.hasSuffix("(Repaired)") == damaged)
            #expect(s.uiRequests.contains { if case .message = $0 { return true } else { return false } } == damaged)
            // Bytes route too.
            let r2 = s.run("file.openBytes", "{\"name\": \"\(name)\", \"data\": \"\(Cmd.base64Encode(bytes))\"}")
            #expect(r2.get("damagedMedia")?.asArray?.count == (damaged ? 1 : 0))
        }
        #expect(try [UInt8](Data(contentsOf: dir.appending(path: "bad.deckcraft"))) == bad, "original untouched")
    }

    @Test func openingAPPTXWithAnUnreadableSlideSaysSo() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        #expect(s.st.doc.slides.count == 2)
        let good = try PPTX.export(s.st.doc)
        let zin = try ZipReader(good)
        var out = ZipWriter()
        for e in zin.entries {
            var d = try zin.read(e, max: 1 << 30)
            if e.name == "ppt/slides/slide2.xml" { d = Array("<p:sld".utf8) }
            try out.add(e.name, d)
        }
        let broken = try out.finish()
        let t = session()
        let r = t.run("file.openBytes", "{\"name\": \"Broken.pptx\", \"data\": \"\(Cmd.base64Encode(broken))\"}")
        #expect(r.get("lostSlides") == ["ppt/slides/slide2.xml"], "\(r.display)")
        #expect(t.st.doc.slides.count == 1)
        #expect(t.st.title.hasSuffix("(Repaired)"), "\(t.st.title)")
        #expect(t.uiRequests.contains { if case .message(let text) = $0 { return text.contains("1 slide in this file couldn't be read") } else { return false } })
        // A good file reports nothing.
        let u = session()
        let r2 = u.run("file.openBytes", "{\"name\": \"Fine.pptx\", \"data\": \"\(Cmd.base64Encode(good))\"}")
        #expect(r2.get("lostSlides") == [], "\(r2.display)")
        #expect(u.uiRequests.isEmpty)
    }

    @Test func openingAFileListsTheFontsItUsesThatAreMissing() throws {
        let s = Session.withNew()
        var r = s.run("file.openBytes", "{\"name\": \"a.pptx\", \"data\": \"\(try deckInFont("Qqq Nonexistent Sans"))\"}")
        #expect(r.get("missingFonts") == ["Qqq Nonexistent Sans"])
        #expect(s.st.missingFonts == ["Qqq Nonexistent Sans"])
        // A font that is there (bundled or installed) isn't listed; new documents list nothing.
        let have = FontDB.shared.face(fallbackFamily, "Regular").family
        r = s.run("file.openBytes", "{\"name\": \"b.pptx\", \"data\": \"\(try deckInFont(have))\"}")
        #expect(r.get("missingFonts") == [])
        s.run("file.new")
        #expect(s.st.missingFonts.isEmpty)
    }

    @Test func anEmbeddedFaceIsUsedWhenTheMachineLacksIt() throws {
        var p = Presentation.default
        var body = TextBody.fromText("Hello")
        body.paragraphs[0].runs[0].props.font = "DeckCraft Colr Squares"
        p.slides[0].shapes[0].text = body
        let font = try #require(Data(base64Encoded: colrSquares))
        let idRaw = p.addMedia("font1.fntdata", "application/x-fontdata", [UInt8](font))
        let id = try #require(idRaw)
        var e = EmbeddedFont.default
        e.typeface = "DeckCraft Colr Squares"
        e.regular = id
        p.embeddedFonts.append(e)
        let data = Cmd.base64Encode(try FileCommands.saveBytes(p, "pptx"))
        let s = Session.withNew()
        let r = s.run("file.openBytes", "{\"name\": \"fonts.pptx\", \"data\": \"\(data)\"}")
        #expect(r.get("missingFonts") == [])
        #expect(s.st.doc.embeddedFonts.first?.typeface == "DeckCraft Colr Squares")
        #expect(s.st.doc.embeddedFonts.first?.regular != nil)
    }

    /// Image export keeps the whole slide: the scale is lowered so the picture fits the renderer's
    /// largest side.
    @Test func imageExportScaleFitsTheLargestPicture() {
        var doc = session().st.doc
        #expect(FileCommands.imageScale(doc, 2) == 2)
        #expect(FileCommands.imageScale(doc, .nan) == 1)
        #expect(FileCommands.imageScale(doc, 16) == 16, "16× of 960 pt fits")
        doc.slideSize = Size(4032, 72)
        let k = FileCommands.imageScale(doc, 4)
        let max = Double(maxRenderSide)
        #expect(k * 4032 <= max + 1e-6 && k * 4032 > max - 1, "\(k)")
    }

    /// Exporting every slide as images: when one file can't be written, the error says which slides
    /// already were.
    @Test func aFailedAllSlidesExportSaysWhatWasWritten() throws {
        let dir = scratchDir("export")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "deck2.png"), withIntermediateDirectories: true)
        let s = Session.withNew()
        s.run("slide.new")
        do {
            _ = try s.execute("file.export", ["path": .string(dir.appending(path: "deck.png").path), "all": true, "scale": 0.1])
            Issue.record("the export succeeded")
        } catch {
            #expect(error.description.contains("slides 1–1 were written"), "\(error)")
        }
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "deck1.png").path))
    }

    @Test func aPNGExportRecordsTheSlideResolution() throws {
        let s = session()
        let dir = scratchDir("dpi")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "slide.png")
        s.run("file.export", JSON.object(JSONObject(["path": .string(png.path), "format": "png"])).display)
        let bytes = try [UInt8](Data(contentsOf: png))
        #expect(Images.dpi(bytes).map { $0 == (144.0, 144.0) } == true)
        #expect(pngSize(bytes).map { $0 == (1920, 1080) } == true, "960×540 pt at 2 px per point")
        let one = dir.appending(path: "one.png")
        s.run("file.export", JSON.object(JSONObject(["path": .string(one.path), "format": "png", "scale": 1])).display)
        let oneBytes = try [UInt8](Data(contentsOf: one))
        #expect(Images.dpi(oneBytes).map { $0 == (72.0, 72.0) } == true)
        #expect(pngSize(oneBytes).map { $0 == (960, 540) } == true)
        let jpg = dir.appending(path: "slide.jpg")
        s.run("file.export", JSON.object(JSONObject(["path": .string(jpg.path), "format": "jpeg"])).display)
        #expect(Images.dpi(try [UInt8](Data(contentsOf: jpg))).map { $0 == (144.0, 144.0) } == true)
    }

    @Test func aTransparentBackgroundIsForPNGOnly() throws {
        let s = session()
        let dir = scratchDir("transparent")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, format) in [("slide.jpg", "jpeg"), ("deck.pdf", "pdf"), ("deck.gif", "gif"), ("deck.pptx", "pptx")] {
            let path = dir.appending(path: name)
            do {
                _ = try s.execute("file.export", ["path": .string(path.path), "format": .string(format), "transparentBackground": true])
                Issue.record("\(format) took a transparent background")
            } catch {
                #expect(error.description.contains("for PNG export"), "\(format): \(error)")
            }
            #expect(!FileManager.default.fileExists(atPath: path.path), "\(format): nothing is written")
        }
        let clear = dir.appending(path: "clear.png")
        s.run("file.export", JSON.object(JSONObject(["path": .string(clear.path), "scale": 1, "transparentBackground": true])).display)
        let img = try #require(Images.decode([UInt8](Data(contentsOf: clear))))
        #expect(img.pixels[(5 * img.width + 5) * 4 + 3] == 0, "no background")
    }

    @Test(.enabled(if: ported("shape.insert", "design.background")))
    func aPNGExportCanLeaveTheBackgroundTransparent() throws {
        let s = session()
        s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 200, 100]}"#)
        s.run("design.background", ##"{"color": "#0000C8"}"##)
        let dir = scratchDir("transparent-shape")
        defer { try? FileManager.default.removeItem(at: dir) }
        func px(_ url: URL, _ x: Int, _ y: Int) throws -> [UInt8] {
            let img = try #require(Images.decode([UInt8](Data(contentsOf: url))))
            let i = (y * img.width + x) * 4
            return Array(img.pixels[i ..< i + 4])
        }
        let opaque = dir.appending(path: "opaque.png")
        s.run("file.export", JSON.object(JSONObject(["path": .string(opaque.path), "scale": 1])).display)
        #expect(try px(opaque, 5, 5) == [0, 0, 200, 255], "the background draws by default")
        let clear = dir.appending(path: "clear.png")
        s.run("file.export", JSON.object(JSONObject(["path": .string(clear.path), "scale": 1, "transparentBackground": true])).display)
        #expect(try px(clear, 5, 5)[3] == 0)
        #expect(try px(clear, 200, 150)[3] == 255, "the shape stays opaque")
    }

    @Test func gifExportWritesOneFramePerVisibleSlide() throws {
        let s = session()
        s.run("slide.new")
        s.run("slide.new")
        s.run("slide.hide", #"{"index": 1}"#)
        let dir = scratchDir("gif")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "deck.gif").path
        let r = s.run("file.export", JSON.object(JSONObject(["path": .string(path), "width": "small", "secondsPerSlide": 1.5, "slides": "1-3"])).display)
        #expect(r.get("frames") == 2 && r.get("width") == 640 && r.get("height") == 360 && r.get("secondsPerSlide") == 1.5, "\(r.display)")
        let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(bytes.starts(with: Array("GIF8".utf8)))
        #expect(s.fails("file.export", JSON.object(JSONObject(["path": .string(path), "width": 9])).display))
        #expect(s.fails("file.export", JSON.object(JSONObject(["path": .string(path), "secondsPerSlide": 0])).display))
        #expect(s.fails("file.export", JSON.object(JSONObject(["path": .string(path), "loop": "twice"])).display))
        #expect(throws: EngineError.self) { try GifExport.options(j(#"{"slides": []}"#)) }
        #expect(GifExport.frameSize(s.st.doc, 3840) == (3840, 2160))
        var tall = s.st.doc
        tall.slideSize = Size(100, 1000)
        #expect(GifExport.frameSize(tall, 960) == (384, 3840))
    }

    @Test func renderAndColorAtAnswerWithPicturesAndPixels() throws {
        let s = session()
        let r = s.run("file.render", #"{"scale": 0.25}"#)
        #expect(r.get("width") == 240 && r.get("height") == 135)
        let png = try #require(r.get("png")?.asStr.flatMap(Cmd.base64Decode))
        #expect(pngSize(png).map { $0 == (240, 135) } == true)
        let c = s.run("slide.colorAt", #"{"x": 2, "y": 2}"#)
        #expect(c.get("color")?.asStr?.count == 6 && c.get("alpha") == 255 && c.get("x") == 2.0)
        #expect(s.fails("slide.colorAt", #"{"x": -5, "y": 2}"#))
        #expect(s.fails("slide.colorAt", #"{"y": 2}"#))
        #expect(s.fails("file.render", #"{"slide": 9}"#))
    }

    @Test func backgroundLoadsAreAdoptedThroughACommand() throws {
        let src = Session.withNew()
        src.run("slide.new")
        let dir = scratchDir("adopt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "adopt.deckcraft").path
        src.run("file.saveAs", JSON.object(JSONObject(["path": .string(path)])).display)
        let s = Session()
        let loaded = try FileCommands.readPresentationFile(path)
        let token = s.stageLoaded(loaded)
        let r = s.run("file.adopt", JSON.object(JSONObject(["path": .string(path), "token": .integer(token)])).display)
        #expect(r.get("slides") == 2, "\(r.display)")
        #expect(s.documents.count == 1)
        #expect(s.st.path == path)
        let (id, params) = try #require(s.journal.last)
        #expect(id == "file.adopt")
        // The token was used up; replaying the entry reads the file again.
        let replay = Session()
        _ = try replay.execute(id, params)
        #expect(replay.st.doc.slides.count == 2)
        // A token staged for another path is not taken for this one.
        let other = s.stageLoaded(LoadedFile(path: "/elsewhere.pptx", doc: .default, native: true, damaged: Damage()))
        s.run("file.adopt", JSON.object(JSONObject(["path": .string(path), "token": .integer(other)])).display)
        #expect(s.st.doc.slides.count == 2)
        #expect(s.fails("file.adopt", "{}"))
    }

    @Test func saveWithoutAPathAsksForOne() {
        let s = session()
        #expect(s.run("file.save") == ["needsPath": true])
        #expect(s.run("file.saveAs") == ["needsPath": true])
        #expect(s.uiRequests == [.pickFile(purpose: "saveAs"), .pickFile(purpose: "saveAs")])
    }

    @Test func openingWhatIsNotAPresentationIsAnError() {
        let s = Session()
        #expect(s.fails("file.openBytes", #"{"name": "x.bin", "data": "AAEC"}"#))
        #expect(s.fails("file.openBytes", #"{"name": "x.bin", "data": "!!"}"#))
        #expect(s.fails("file.open", #"{"path": "/no/such/file.deckcraft"}"#))
        #expect(s.fails("file.open", "{}"))
        // A password-protected package (a compound file).
        let cfb: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + Array(repeating: 0, count: 504)
        #expect(throws: EngineError.self) { try FileCommands.openPresentation("locked.pptx", cfb) }
        #expect(s.activeDoc == nil)
    }

    @Test func newTakesAThemeASizeOrBlank() {
        let s = Session()
        let r = s.run("file.new", #"{"theme": "harbor", "size": [800, 600]}"#)
        #expect(r == ["document": 0, "slides": 1])
        #expect(s.st.doc.masters[0].theme.name == "Harbor")
        #expect(s.st.doc.slideSize == Size(800, 600))
        s.run("file.new", #"{"blank": true, "size": [0.5, 9999]}"#)
        #expect(s.st.doc.slides.isEmpty, "blank means no slides")
        #expect(s.st.doc.slideSize == wideSlideSize, "an unusable size takes the default")
        #expect(s.st.title == "Presentation2")
    }

    @Test func writeFileDoesNotTouchAPredictableSavingSibling() throws {
        let dir = scratchDir("sibling")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appending(path: "deck.deckcraft")
        try Data("old".utf8).write(to: dest)
        try Data("precious".utf8).write(to: dir.appending(path: "deck.deckcraft.saving"))
        try FileCommands.writeFile(dest.path, Array("new".utf8))
        #expect(try Data(contentsOf: dest) == Data("new".utf8))
        #expect(try Data(contentsOf: dir.appending(path: "deck.deckcraft.saving")) == Data("precious".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.count == 2, "no temporary file may be left behind: \(names)")
    }

    @Test func writeFileFailedRenameKeepsDestinationAndCleansUp() throws {
        let dir = scratchDir("failed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appending(path: "target")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        #expect(throws: EngineError.self) { try FileCommands.writeFile(dest.path, Array("new".utf8)) }
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
    }

    @Test func readFileRejectsADirectory() {
        #expect(throws: EngineError.self) { try IO.readFile(FileManager.default.temporaryDirectory.path) }
        #expect(IO.fileLen("/no/such/file") == nil)
    }

    @Test func writeFilePreservesPermissionsAndWritesContent() throws {
        let dir = scratchDir("io")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "test_write.txt").path
        try IO.writeFile(path, Array("hello world".utf8))
        #expect(try IO.readFile(path) == Array("hello world".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        try IO.writeFile(path, Array("updated world".utf8))
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(perms == 0o640)
        #expect(IO.fileLen(path) == 13)
    }

    @Test func rustPathHelpers() {
        #expect(RustPath.fileStem("/a/b.deckcraft") == "b")
        #expect(RustPath.fileStem("a.tar.gz") == "a.tar")
        #expect(RustPath.fileStem(".hidden") == ".hidden")
        #expect(RustPath.fileStem("dir/") == "dir")
        #expect(RustPath.ext("a.") == "")
        #expect(RustPath.ext(".deckcraft") == nil)
        #expect(RustPath.withFileName("/x/deck.png", "deck1.png") == "/x/deck1.png")
    }
}

/// `slide.colorAt`, the colour the slide is drawn with at a point: what the Eyedropper takes (#367).
/// (cmd/color_at_tests.rs)
@Suite("Color at")
struct ColorAtTests {
    private func deck() -> Session {
        let s = Session.withNew()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 200, 100]}"#)
        s.run("shape.fill", ##"{"color": "#ff0000"}"##)
        return s
    }

    private func colorAt(_ s: Session, _ x: Double, _ y: Double) -> JSON { s.run("slide.colorAt", "{\"x\": \(x), \"y\": \(y)}") }

    @Test(.enabled(if: ported("shape.insert", "shape.fill")))
    func aPointInAShapeGivesItsFillAndOneBesideItTheBackground() {
        let s = deck()
        let inside = colorAt(s, 150, 150)
        #expect(inside.get("color") == "FF0000")
        #expect(inside.get("alpha") == 255)
        let beside = colorAt(s, 700, 450)
        #expect(beside.get("color") != "FF0000")
        // Just inside and just outside the shape's corner.
        #expect(colorAt(s, 101, 101).get("color") == "FF0000")
        #expect(colorAt(s, 99, 99).get("color") == beside.get("color"))
        // A finer or coarser picture gives the same colour.
        for scale in [0.5, 1.0, 4.0] {
            #expect(s.run("slide.colorAt", "{\"x\": 150, \"y\": 150, \"scale\": \(scale)}").get("color") == "FF0000", "scale \(scale)")
        }
        // It is a query: the deck is not changed and nothing goes on the undo stack.
        let revision = s.st.revision
        _ = colorAt(s, 150, 150)
        #expect(s.st.revision == revision)
    }

    @Test(.enabled(if: ported("shape.insert", "shape.fill")))
    func aSeeThroughFillGivesTheColourItIsDrawnWith() {
        let s = deck()
        let background = colorAt(s, 700, 450).get("color")
        s.run("shape.fill", #"{"transparency": 0.5}"#)
        let v = colorAt(s, 150, 150)
        #expect(v.get("color") != "FF0000", "half of the background shows through")
        #expect(v.get("color") != background)
        #expect(v.get("alpha") == 255, "the slide is opaque")
    }

    @Test func pointsOutsideTheSlideAndBadParametersAreErrors() {
        let s = Session.withNew()
        s.run("slide.new", #"{"layout": "blank"}"#)
        for p in [
            #"{"x": -1, "y": 10}"#, #"{"x": 10, "y": -0.5}"#, #"{"x": 1e9, "y": 10}"#, #"{"x": 10, "y": 1e9}"#, #"{"x": 10}"#,
            #"{"y": 10}"#, #"{"x": "10", "y": 10}"#, #"{"x": 10, "y": 10, "slide": 99}"#,
        ] {
            #expect(s.fails("slide.colorAt", p), "\(p)")
        }
        // Odd scales are clamped, not refused or crashed on.
        for scale in ["0.0", "-3.0", "1e9"] {
            #expect(!s.fails("slide.colorAt", "{\"x\": 150, \"y\": 150, \"scale\": \(scale)}"), "\(scale)")
        }
    }
}

@Suite("Templates")
struct TemplateTests {
    private func body(_ doc: Presentation, _ slide: Int, _ n: Int) -> (String, UInt8) {
        let text = doc.slides[slide].shapes.filter { $0.phType.map { !$0.isTitle } ?? false }.at(n)?.text ?? .default
        return (text.text, text.paragraphs.at(1)?.level ?? 0)
    }

    @Test func everyStarterOpensOnItsThemeAndIsACleanDocument() {
        let s = Session()
        for starter in Templates.starters() {
            s.run("file.new", "{\"template\": \"\(starter.name.lowercased())\"}")
            let st = s.st
            #expect(st.doc.masters[0].theme.name == starter.theme, "\(starter.name)")
            #expect(st.doc.slides.count == starter.slides.count, "\(starter.name)")
            #expect(st.doc.slides[0].title == starter.slides[0].title, "\(starter.name)")
            #expect(!st.isDirty, "\(starter.name)")
            #expect(st.history.undo.isEmpty, "\(starter.name)")
            #expect(st.selection.slide == 0)
        }
        let listed = s.run("file.templates")
        #expect(listed.get("templates")?.asArray?.count == Templates.starters().count)
    }

    @Test func briefingKeepsNotesColumnsAndOutlineLevels() {
        let s = Session()
        s.run("file.new", #"{"template": "Briefing", "size": [800.0, 450.0]}"#)
        let doc = s.st.doc
        #expect(doc.slideSize.width == 800)
        #expect(doc.slides[0].notesText == "Open with what changed since last week.")
        let (agenda, level) = body(doc, 1, 0)
        #expect(agenda.contains("One concrete change"), "\(agenda)")
        #expect(level == 1)
        #expect(body(doc, 3, 0).0.hasPrefix("Done"))
        #expect(body(doc, 3, 1).0.hasPrefix("Next"))
    }

    @Test func pitchComparisonFillsBothColumns() throws {
        let doc = try Templates.build("Pitch", wideSlideSize)
        #expect(body(doc, 3, 0).0 == "Today")
        #expect(body(doc, 3, 1).0.contains("buried"))
        #expect(body(doc, 3, 2).0 == "After")
        #expect(body(doc, 3, 3).0.contains("top"))
    }

    @Test func searchMatchesNameSummaryAndTheme() {
        #expect(Templates.matching("ridge").map(\.name) == ["Field Notes"])
        #expect(Templates.matching("nocturne").map(\.name) == ["Evening Talk"])
        #expect(Templates.matching("").count == Templates.starters().count)
        #expect(Templates.matching("facet").isEmpty)
    }

    @Test func unknownBlankAndThemeAreRefused() {
        let s = Session()
        do {
            _ = try s.execute("file.new", ["template": "Ion"])
            Issue.record("an unknown template opened")
        } catch { #expect(error.description.contains("Briefing"), "\(error)") }
        do {
            _ = try s.execute("file.new", ["template": "Lesson", "theme": "Harbor"])
            Issue.record("theme and template both taken")
        } catch { #expect(error.description.contains("not both"), "\(error)") }
        do {
            _ = try s.execute("file.new", ["template": "Lesson", "blank": true])
            Issue.record("a blank template opened")
        } catch { #expect(error.description.contains("blank"), "\(error)") }
        #expect(s.activeDoc == nil)
    }

    @Test func aStarterRoundTripsThroughPPTX() throws {
        let doc = try Templates.build("Evening Talk", wideSlideSize)
        let bytes = try PPTX.export(doc)
        let (back, _) = try PPTX.importChecked(bytes)
        #expect(back.slides.count == doc.slides.count)
        for (before, after) in zip(doc.slides, back.slides) { #expect(after.title == before.title) }
        #expect(back.slides[3].shapes.contains { $0.text?.text.contains("bedroom") == true })
    }
}
