// DCEngineTests — the insert module: deckcraft crates/engine/src/cmd/insert.rs's tests (Date & Time, icons,
// pictures and photo albums), icons.rs's, and the tests of tests.rs that exercise insert commands.
import DCColor
import DCCore
@testable import DCEngine
import DCGeometry
import DCModel
import DCPPTX
import DCRender
import DCText
import Foundation
import Testing

/// 8×8 red PNG (insert.rs `png()`).
let insertPNG8: [UInt8] = [
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 8, 0, 0, 0, 8, 8, 2, 0, 0, 0, 75, 109, 41, 220, 0, 0, 0, 17, 73,
    68, 65, 84, 120, 156, 99, 184, 163, 161, 129, 21, 49, 12, 45, 9, 0, 123, 123, 75, 1, 251, 162, 81, 240, 0, 0, 0, 0, 73, 69, 78, 68, 174,
    66, 96, 130,
]

/// `{"name": name, "data": base64(png)}` as JSON text.
private func pic(_ name: String) -> String { #"{"name": "\#(name)", "data": "\#(Cmd.base64Encode(insertPNG8))"}"# }

private func nSlides(_ s: Session) -> Int { s.activeDoc?.doc.slides.count ?? 0 }

private func pictures(_ s: Session, _ index: Int) -> [Shape] {
    (s.activeDoc?.doc.slides.at(index)?.shapes ?? []).filter { if case .picture = $0.kind { return true }; return false }
}

private func boxText(_ s: Session, _ index: Int) -> [String] {
    (s.activeDoc?.doc.slides.at(index)?.shapes ?? []).filter(\.textBox).compactMap { $0.text?.text }
}

private func undos(_ s: Session) -> Int { s.st.history.undo.count }

private func dateRun(_ s: Session) -> Run? {
    s.st.currentSlide?.shapes.first { $0.phType == .date }?.text?.paragraphs.first?.runs.first
}

private func titleField(_ s: Session) -> Run? {
    let title = s.st.currentSlide?.shapes.first?.text
    return title?.paragraphs.first?.runs.first { r in
        if r.text.contains(":") { return true }
        if case .field = r.kind { return true }
        return false
    }
}

private func editTitle(_ s: Session) {
    let id = s.st.currentSlide?.shapes.first?.id.rawValue ?? 0
    s.run("text.edit", #"{"id": \#(id)}"#)
    s.run("text.insert", #"{"text": "On "}"#)
}

private func isField(_ r: Run?, _ name: String? = nil) -> Bool {
    guard case .field(let f)? = r?.kind else { return false }
    return name.map { $0 == f } ?? true
}

@Suite("Insert: Date & Time")
struct InsertDateTimeTests {
    // insert.rs::no_params_opens_the_dialog_and_edits_nothing
    @Test func noParamsOpensTheDialogAndEditsNothing() throws {
        let s = session()
        let rev = s.st.revision
        for p in [JSON.emptyObject, .null] {
            s.uiRequests.removeAll()
            _ = try s.execute("insert.dateTime", p)
            #expect(s.uiRequests == [.dialog(id: "dateTime", params: .emptyObject)])
            #expect(s.st.revision == rev)
            #expect(undos(s) == 0)
            #expect(dateRun(s) == nil)
        }
    }

    // insert.rs::a_format_at_the_caret_is_one_updating_field
    @Test(.enabled(if: ported("text.edit", "text.insert", "edit.undo"))) func aFormatAtTheCaretIsOneUpdatingField() throws {
        let s = session()
        editTitle(s)
        let before = undos(s)
        let v = s.run("insert.dateTime", #"{"format": "datetime10", "update": true}"#)
        #expect(v.get("where") == "caret")
        let run = titleField(s)
        #expect(isField(run, "datetime10"), "\(String(describing: run))")
        #expect(run?.text.contains(":") == true)
        #expect(undos(s) == before + 1)
        #expect(s.st.history.undo.last?.label == "Date & Time")
        s.run("edit.undo")
        #expect(s.st.currentSlide?.shapes.first?.text?.text == "On ")
    }

    // insert.rs::update_false_inserts_plain_text_in_the_chosen_language
    @Test(.enabled(if: ported("text.edit", "text.insert"))) func updateFalseInsertsPlainTextInTheChosenLanguage() throws {
        let s = session()
        editTitle(s)
        let before = undos(s)
        let now = try #require(DCText.DateTime.nowLocal())
        let expect = try #require(DateFields.fieldText("datetime1", "en-GB", now))
        s.run("insert.dateTime", #"{"format": "datetime1", "update": false, "language": "en-GB"}"#)
        let run = try #require(s.st.currentSlide?.shapes.first?.text?.paragraphs.first?.runs.first { $0.text == expect })
        #expect(run.kind == .text)
        #expect(run.props.lang == "en-GB")
        #expect(undos(s) == before + 1)
    }

    // insert.rs::a_named_format_in_french_and_a_bad_value_change_nothing
    @Test(.enabled(if: ported("text.edit", "text.insert"))) func aNamedFormatInFrenchAndABadValueChangeNothing() throws {
        let s = session()
        editTitle(s)
        let rev = s.st.revision
        let n = undos(s)
        do {
            _ = try s.execute("insert.dateTime", j(#"{"format": "datetime2", "language": "fr-FR"}"#))
            Issue.record("accepted")
        } catch {
            #expect("\(error)".contains("isn't available"), "\(error)")
        }
        #expect(s.st.revision == rev)
        #expect(undos(s) == n)
        for p in [#"{"format": "datetime14"}"#, #"{"format": "nope"}"#, #"{"update": "yes"}"#, #"{"language": "de-DE"}"#, #"{"language": ""}"#] {
            do {
                _ = try s.execute("insert.dateTime", j(p))
                Issue.record("accepted \(p)")
            } catch {
                #expect("\(error)".contains("insert.dateTime"), "\(error)")
            }
            #expect(s.st.revision == rev)
            #expect(undos(s) == n)
        }
    }

    // insert.rs::without_a_caret_the_date_lands_on_this_slide_only
    @Test(.enabled(if: ported("design.headerFooter", "edit.undo"))) func withoutACaretTheDateLandsOnThisSlideOnly() throws {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        s.run("slide.go", #"{"index": 0}"#)
        let now = try #require(DCText.DateTime.nowLocal())
        let clock = try #require(DateFields.fieldText("datetime10", "en-US", now))
        let v = s.run("insert.dateTime", #"{"format": "datetime10", "language": "en_US"}"#)
        #expect(v.get("where") == "footer")
        let run = try #require(dateRun(s))
        #expect(isField(run, "datetime10"))
        #expect(run.text == clock)
        #expect(run.props.lang == "en-US")
        s.run("slide.go", #"{"index": 1}"#)
        #expect(dateRun(s) == nil, "the other slide keeps its own footer")
        s.run("slide.go", #"{"index": 0}"#)
        let fixed = try #require(DateFields.fieldText("datetime12", nil, now))
        s.run("insert.dateTime", #"{"format": "datetime12", "update": false}"#)
        let after = try #require(dateRun(s))
        #expect(after.kind == .text && after.text == fixed)
        s.run("edit.undo")
        #expect(isField(dateRun(s)), "one undo restores the field")
    }

    // tests.rs::header_footer_fixed_date_is_the_slides_own_text
    @Test(.enabled(if: ported("design.headerFooter", "text.edit", "text.insert"))) func headerFooterFixedDateIsTheSlidesOwnText() throws {
        let s = session()
        func date() -> TextBody? { s.st.currentSlide?.shapes.first { $0.phType == .date }?.text }
        func kind() -> RunKind? { date()?.paragraphs.first?.runs.first?.kind }
        // Automatic: a date field, saved with today's date.
        s.run("design.headerFooter", #"{"date": true}"#)
        #expect(kind() == .field(field: "datetime1"))
        #expect((date()?.text.filter { $0 == "/" }.count ?? 0) == 2, "M/D/YYYY")
        // Fixed: plain text in the slide's own placeholder.
        s.run("design.headerFooter", #"{"date": true, "dateText": "Launch day"}"#)
        #expect(kind() == .text && date()?.text == "Launch day")
        // Back to automatic.
        s.run("design.headerFooter", #"{"date": true, "dateText": ""}"#)
        #expect(isField(date()?.paragraphs.first?.runs.first))
        // A new date field is saved with the date it shows.
        s.run("text.edit", #"{"id": \#(s.st.currentSlide?.shapes.first?.id.rawValue ?? 0)}"#)
        s.run("text.insert", #"{"text": "Updated "}"#)
        s.run("insert.dateTime", #"{"format": "datetime10"}"#)
        let run = try #require(s.st.currentSlide?.shapes.first?.text?.paragraphs.first?.runs.first { isField($0) })
        #expect(run.text.contains(":"), "H:mm \(run)")
    }
}

@Suite("Insert: photo albums and pictures", .enabled(if: ported("shape.line", "picture.adjust", "shape.rotate", "design.theme")))
struct InsertAlbumTests {
    // insert.rs::two_pictures_one_per_slide_are_one_undo
    @Test func twoPicturesOnePerSlideAreOneUndo() {
        let s = session()
        let before = nSlides(s)
        let r = s.run("insert.photoAlbum", #"{"pictures": [\#(pic("hill.png")), \#(pic("lake.png"))], "layout": "1"}"#)
        #expect(r.get("slides") == 2)
        #expect(nSlides(s) == before + 2)
        #expect(pictures(s, 1).count == 1)
        #expect(pictures(s, 2).count == 1)
        #expect(s.st.selection.slide == 1)
        #expect(s.st.history.undo.count == 1)
        #expect(s.st.history.undo.first?.label == "Photo Album…")
        s.run("edit.undo")
        #expect(nSlides(s) == before)
        #expect(pictures(s, 1).isEmpty)
    }

    // insert.rs::two_up_shares_one_slide
    @Test func twoUpSharesOneSlide() {
        let s = session()
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("a.png")), \#(pic("b.png"))], "layout": "2"}"#)
        #expect(nSlides(s) == 2)
        #expect(pictures(s, 1).count == 2)
        #expect(boxText(s, 1).isEmpty)
    }

    // insert.rs::captions_and_titles_use_the_file_stem
    @Test func captionsAndTitlesUseTheFileStem() {
        let s = session()
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("harbor.png"))], "layout": "1", "captions": true}"#)
        #expect(boxText(s, 1) == ["harbor"])
        s.run("edit.undo")
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("harbor.png"))], "layout": "1title"}"#)
        #expect(boxText(s, 1) == ["harbor"])
        #expect(pictures(s, 1).count == 1)
        #expect((pictures(s, 1).first?.xfrm?.y ?? 0) > 40.0, "the picture sits below the title")
    }

    // insert.rs::frames_set_the_picture_line
    @Test func framesSetThePictureLine() {
        let s = session()
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("a.png"))], "frame": "rect"}"#)
        #expect(pictures(s, 1).first?.line?.width == 1.5)
        s.run("edit.undo")
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("a.png"))], "frame": "rounded"}"#)
        #expect(pictures(s, 1).first?.line?.width == 2.25)
        #expect(pictures(s, 1).first?.line?.join == .round)
        s.run("edit.undo")
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("a.png"))], "frame": "simple"}"#)
        #expect(pictures(s, 1).first?.line?.width == 6.0)
    }

    // insert.rs::a_text_box_breaks_the_picture_row
    @Test func aTextBoxBreaksThePictureRow() {
        let s = session()
        let r = s.run("insert.photoAlbum", #"{"pictures": [\#(pic("a.png")), {"text": "A day on the water"}, \#(pic("b.png"))], "layout": "2"}"#)
        #expect(r.get("slides") == 3)
        #expect(pictures(s, 1).count == 1)
        #expect(boxText(s, 2) == ["A day on the water"])
        #expect(pictures(s, 2).isEmpty)
        #expect(pictures(s, 3).count == 1)
        #expect(s.st.history.undo.count == 1)
    }

    // insert.rs::no_pictures_opens_the_dialog_without_editing
    @Test func noPicturesOpensTheDialogWithoutEditing() {
        let s = session()
        let before = nSlides(s)
        let r = s.run("insert.photoAlbum")
        #expect(r.get("dialog") == "photoAlbum")
        #expect(nSlides(s) == before)
        #expect(s.st.history.undo.isEmpty)
        #expect(s.uiRequests.count == 1)
        guard case .dialog(let id, _)? = s.uiRequests.first else {
            Issue.record("dialog request, got \(s.uiRequests)")
            return
        }
        #expect(id == "photoAlbum")
    }

    // insert.rs::bad_input_adds_no_slides
    @Test func badInputAddsNoSlides() {
        let s = session()
        let before = nSlides(s)
        #expect(s.fails("insert.photoAlbum", #"{"pictures": [], "layout": "1"}"#))
        #expect(s.fails("insert.photoAlbum", #"{"pictures": [\#(pic("a.png"))], "layout": "grid"}"#))
        #expect(s.fails("insert.photoAlbum", #"{"pictures": [\#(pic("a.png"))], "frame": "glow"}"#))
        #expect(s.fails("insert.photoAlbum", #"{"pictures": [\#(pic("a.png"))], "captions": "yes"}"#))
        #expect(s.fails("insert.photoAlbum", #"{"pictures": [{"name": "notes.txt", "data": "\#(Cmd.base64Encode(Array("hello".utf8)))"}]}"#))
        #expect(s.fails("insert.photoAlbum", #"{"pictures": [{"text": "  "}]}"#))
        let many = (0 ..< 49).map { #"{"text": "box \#($0)"}"# }.joined(separator: ",")
        #expect(s.fails("insert.photoAlbum", #"{"pictures": [\#(many)]}"#))
        #expect(nSlides(s) == before)
        #expect(s.st.history.undo.isEmpty)
    }

    // insert.rs::fit_is_larger_than_one_picture_and_four_up_is_one_slide
    @Test func fitIsLargerThanOnePictureAndFourUpIsOneSlide() {
        let s = session()
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("a.png"))], "layout": "1"}"#)
        let one = pictures(s, 1).first?.xfrm?.h ?? 0
        s.run("edit.undo")
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("a.png"))], "layout": "fit"}"#)
        let fitted = pictures(s, 1).first?.xfrm?.h ?? 0
        #expect(fitted > one, "fit \(fitted) should be taller than one-up \(one)")
        s.run("edit.undo")
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("a.png")), \#(pic("b.png")), \#(pic("c.png")), \#(pic("d.png"))], "layout": "4"}"#)
        #expect(nSlides(s) == 2)
        #expect(pictures(s, 1).count == 4)
    }

    private func adjust(_ s: Session, _ index: Int) -> PictureAdjust? {
        guard case .picture(let fill)? = pictures(s, index).first?.kind else { return nil }
        return fill.adjust
    }

    private func themeName(_ s: Session) -> String { s.activeDoc?.doc.masters.first?.theme.name ?? "" }

    // insert.rs::edit_without_pictures_reopens_the_dialog
    @Test func editWithoutPicturesReopensTheDialog() {
        let s = session()
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("hill.png")), \#(pic("lake.png"))], "layout": "1"}"#)
        s.uiRequests.removeAll()
        let before = nSlides(s)
        let n = s.st.history.undo.count
        let r = s.run("insert.photoAlbumEdit")
        #expect(r.get("dialog") == "photoAlbum")
        #expect(nSlides(s) == before)
        #expect(s.st.history.undo.count == n)
        guard case .dialog(let id, let params)? = s.uiRequests.first else {
            Issue.record("dialog request, got \(s.uiRequests)")
            return
        }
        #expect(id == "photoAlbum")
        #expect(params.get("items")?.at(0)?.get("name") == "hill.png")
        #expect(params.get("items")?.at(1)?.get("name") == "lake.png")
        #expect(params.get("layout") == "1")
        #expect((params.get("album")?.asU64 ?? 0) > 0)
    }

    // insert.rs::edit_reflows_the_album_in_one_undo
    @Test func editReflowsTheAlbumInOneUndo() {
        let s = session()
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("hill.png")), \#(pic("lake.png"))], "layout": "1"}"#)
        #expect(nSlides(s) == 3)
        let r = s.run("insert.photoAlbumEdit", #"{"pictures": [\#(pic("hill.png")), \#(pic("lake.png"))], "layout": "2"}"#)
        #expect(r.get("slides") == 1)
        #expect(nSlides(s) == 2)
        #expect(pictures(s, 1).count == 2)
        #expect(s.st.history.undo.last?.label == "Edit Photo Album…")
        s.run("edit.undo")
        #expect(nSlides(s) == 3)
        #expect(pictures(s, 1).count == 1)
        #expect(pictures(s, 2).count == 1)
    }

    // insert.rs::picture_options_and_theme_are_one_step
    @Test func pictureOptionsAndThemeAreOneStep() {
        let s = session()
        let one = #"{"name": "hill.png", "data": "\#(Cmd.base64Encode(insertPNG8))", "rot": 90, "brightness": 0.2, "contrast": -0.1}"#
        s.run("insert.photoAlbum", #"{"pictures": [\#(one)], "grayscale": true, "theme": "Harbor"}"#)
        let adj = adjust(s, 1)
        #expect(adj?.grayscale == true)
        #expect(abs((adj?.brightness ?? 0) - 0.2) < 1e-6)
        #expect(abs((adj?.contrast ?? 0) + 0.1) < 1e-6)
        #expect(abs((pictures(s, 1).first?.xfrm?.rot ?? 0) - 90.0) < 0.01)
        #expect(themeName(s) == "Harbor")
        let mark = s.st.doc.slides.at(1)?.rawExt ?? ""
        #expect(mark.contains("gray=1"), "\(mark)")
        #expect(mark.contains("theme=Harbor"), "\(mark)")
        #expect(s.st.doc.slides.at(1)?.name == "Photo Album")
        s.run("edit.undo")
        #expect(themeName(s) == "DeckCraft")
        #expect(nSlides(s) == 1)
    }

    // insert.rs::unknown_theme_and_a_plain_slide_change_nothing
    @Test func unknownThemeAndAPlainSlideChangeNothing() {
        let s = session()
        let before = nSlides(s)
        do {
            _ = try s.execute("insert.photoAlbum", j(#"{"pictures": [\#(pic("a.png"))], "theme": "NotATheme"}"#))
            Issue.record("accepted")
        } catch {
            #expect("\(error)".contains("unknown theme"), "\(error)")
        }
        #expect(s.fails("insert.photoAlbum", #"{"pictures": [\#(pic("a.png")), {"brightness": "high"}]}"#))
        #expect(s.fails("insert.photoAlbum", #"{"pictures": [{"name": "a.png", "data": "\#(Cmd.base64Encode(insertPNG8))", "brightness": 2}]}"#))
        do {
            _ = try s.execute("insert.photoAlbumEdit", .emptyObject)
            Issue.record("accepted")
        } catch {
            #expect("\(error)".contains("not part of a photo album"), "\(error)")
        }
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("a.png"))]}"#)
        s.run("slide.go", #"{"index": 0}"#)
        #expect(s.fails("insert.photoAlbumEdit", #"{"pictures": [\#(pic("b.png"))], "layout": "2"}"#))
        #expect(nSlides(s) == before + 1)
        #expect(pictures(s, 1).count == 1)
        #expect(themeName(s) == "DeckCraft")
    }

    // insert.rs::two_albums_stay_independent
    @Test func twoAlbumsStayIndependent() {
        let s = session()
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("a.png")), \#(pic("b.png"))], "layout": "1"}"#)
        s.run("slide.go", #"{"index": \#(nSlides(s) - 1)}"#)
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("c.png")), \#(pic("d.png"))], "layout": "1"}"#)
        #expect(nSlides(s) == 5)
        s.run("insert.photoAlbumEdit", #"{"pictures": [\#(pic("c.png")), \#(pic("d.png"))], "layout": "2"}"#)
        #expect(nSlides(s) == 4)
        #expect(pictures(s, 1).count == 1)
        #expect(pictures(s, 2).count == 1)
        #expect(pictures(s, 3).count == 2)
        let first = s.st.doc.slides.at(1)?.rawExt ?? ""
        let second = s.st.doc.slides.at(3)?.rawExt ?? ""
        #expect(first.hasPrefix("deckcraft-album:"))
        #expect(second.hasPrefix("deckcraft-album:"))
        #expect(first.split(separator: ";").first != second.split(separator: ";").first)
    }

    // insert.rs::a_named_run_without_a_marker_still_reflows
    @Test func aNamedRunWithoutAMarkerStillReflows() throws {
        let s = session()
        s.run("insert.photoAlbum", #"{"pictures": [\#(pic("a.png")), \#(pic("b.png"))], "layout": "1"}"#)
        var doc = s.st.doc
        for i in doc.slides.indices.dropFirst() { doc.slides[i].rawExt = nil }
        s.st.docRef = DocRef(doc)
        s.run("insert.photoAlbumEdit", #"{"pictures": [\#(pic("a.png")), \#(pic("b.png"))], "layout": "2"}"#)
        #expect(nSlides(s) == 2)
        #expect(pictures(s, 1).count == 2)
        let mark = s.st.doc.slides.at(1)?.rawExt ?? ""
        #expect(mark.hasPrefix("deckcraft-album:"), "\(mark)")
    }
}

/// Pixels with ink (not near-white, opaque) in a box of `img` at `scale` (icons.rs `ink_in`).
private func inkIn(_ img: RenderImage, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ scale: Double) -> Int {
    let px = img.toStraight()
    let x0 = Int(max((x * scale).rounded(.down), 0)), y0 = Int(max((y * scale).rounded(.down), 0))
    let x1 = Int(min(((x + w) * scale).rounded(.up), Double(img.width))), y1 = Int(min(((y + h) * scale).rounded(.up), Double(img.height)))
    var n = 0
    for yy in y0 ..< max(y1, y0) {
        for xx in x0 ..< max(x1, x0) {
            let i = (yy * img.width + xx) * 4
            let sum = Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])
            if px[i + 3] > 200 && sum < 680 { n += 1 }
        }
    }
    return n
}

@Suite("Insert: icons")
struct InsertIconTests {
    // icons.rs::every_icon_converts_and_a_second_subpath_keeps_its_own_origin
    @Test func everyIconConvertsAndASecondSubpathKeepsItsOwnOrigin() throws {
        #expect(Icons.icons.count >= 60)
        for icon in Icons.icons {
            let bp = try #require(Icons.outline(icon.name), "\(icon.name) did not parse")
            #expect(bp.elements.count >= 2, "\(icon.name)")
            let d = try #require(Icons.pathData(icon.name), "\(icon.name)")
            #expect(d.hasPrefix("M"), "\(d)")
            #expect(!parsePath(d).elements.isEmpty, "\(icon.name)")
        }
        // `m19 12…` is a second SVG element, not a continuation of the shaft.
        let down = try #require(Icons.pathData("arrow-down"))
        #expect(down.contains("M 19 12"), "\(down)")
        // Relative arcs in the star become cubics our renderer understands.
        #expect(Icons.pathData("star")?.contains(" C ") == true)
        #expect(Icons.find("arrow_right")?.name == "arrow-right")
        #expect(Icons.find("Star")?.name == "star")
        #expect(Icons.find("nope") == nil)
    }

    // icons.rs::insert_icon_strokes_the_outline_and_round_trips_through_pptx
    @Test func insertIconStrokesTheOutlineAndRoundTripsThroughPptx() throws {
        let s = session()
        #expect(s.fails("insert.icon"))
        #expect(s.fails("insert.icon", #"{"name": "not-an-icon"}"#))
        let listed = s.run("insert.icons")
        #expect(listed.asArray?.contains { $0.get("name") == "star" && $0.get("category") == "Marks" } == true)
        let before = s.st.shapes.count
        let id = try #require(s.run("insert.icon", #"{"name": "star", "rect": [100.0, 80.0, 72.0, 72.0]}"#).get("id")?.asU32)
        do {
            let st = s.st
            #expect(st.shapes.count == before + 1)
            let sh = try #require(st.shape(ShapeId(id)))
            #expect(sh.name == "Star")
            #expect(sh.fill == Fill.none_)
            guard case .custom(let paths) = sh.geom else {
                Issue.record("\(sh.geom)")
                return
            }
            #expect(paths.count == 1)
            #expect(paths.first?.fill == FillMode.none)
            #expect(paths.first?.stroke == true)
            #expect(paths.first?.w == Icons.view && paths.first?.h == Icons.view)
            #expect(paths.first.map { $0.d.contains("M") && $0.d.contains("C") } == true)
            #expect(abs((sh.line?.width ?? 0) - 6.0) < 1e-6)
            var opts = RenderOpts()
            opts.scale = 2.0
            let img = renderSlide(st.doc, st.selection.slide, opts)
            #expect(inkIn(img, 100, 80, 72, 72, 2) > 40, "star stroke pixels")
            let px = img.toStraight()
            let i = ((80 + 36) * 2 * img.width + (100 + 36) * 2) * 4
            #expect(Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) > 680, "a stroked star is hollow")
        }
        s.run("edit.undo")
        #expect(s.st.shapes.count == before)

        s.run("insert.icon", #"{"name": "arrow-right", "rect": [200.0, 200.0, 96.0, 96.0]}"#)
        let sh = try #require(s.st.shapes.first { $0.name == "Arrow right" })
        #expect(abs((sh.line?.width ?? 0) - 8.0) < 1e-6)
        var opts = RenderOpts()
        opts.scale = 2.0
        #expect(inkIn(renderSlide(s.st.doc, s.st.selection.slide, opts), 200, 200, 96, 96, 2) > 40)

        let p = try PPTX.import(PPTX.export(s.st.doc))
        let back = try #require(p.slides.first?.shapes.first { $0.name == "Arrow right" })
        guard case .custom(let paths) = back.geom else {
            Issue.record("\(back.geom)")
            return
        }
        #expect(paths.contains { $0.fill == FillMode.none && $0.stroke && $0.d.contains("M") })
        #expect(abs((back.line?.width ?? 0) - 8.0) < 0.05)
    }
}

@Suite("Insert: shapes, links, actions and charts")
struct InsertShapeTests {
    // tests.rs::insert_shape_and_format
    @Test(.enabled(if: ported("shape.fill", "shape.line", "shape.rotate", "shape.move", "format.bold", "shape.inspect")))
    func insertShapeAndFormat() throws {
        let s = session()
        let id = s.run("shape.insert", #"{"preset": "roundRect", "rect": [100, 100, 200, 100], "text": "Hi"}"#).get("id")?.asU64 ?? 0
        s.run("shape.fill", ##"{"color": "#ff0000"}"##)
        s.run("shape.line", #"{"width": 3, "color": "accent2", "dash": "dash"}"#)
        s.run("shape.rotate", #"{"deg": 30}"#)
        s.run("shape.move", #"{"dx": 10, "dy": -5}"#)
        s.run("format.bold")
        let v = s.run("shape.inspect", #"{"id": \#(id)}"#)
        #expect(v.get("box")?.get("x") == 110.0)
        #expect(v.get("box")?.get("rot") == 30.0)
        #expect(v.get("shape")?.get("text")?.get("paragraphs")?.at(0)?.get("runs")?.at(0)?.get("props")?.get("bold") == true)
        // Undo restores step by step.
        for _ in 0 ..< 5 { s.run("edit.undo") }
    }

    // tests.rs::action_settings_set_click_and_hover
    @Test func actionSettingsSetClickAndHover() throws {
        let s = session()
        s.run("slide.new")
        s.run("shape.insert", #"{"preset": "rect", "rect": [0, 0, 50, 50]}"#)
        func shape() -> Shape? { s.st.selectedShapes.first }
        s.run("shape.action", #"{"action": "slide", "slide": 0, "highlight": false}"#)
        let first = s.st.doc.slides[0].id
        #expect(shape()?.click?.action == .slide(slide: first))
        #expect(shape()?.click?.highlightClick == false)
        s.run("shape.action", #"{"on": "hover", "action": "url", "url": "https://example.com"}"#)
        #expect(shape()?.hover?.action == .url(url: "https://example.com"))
        #expect(shape()?.click != nil, "hover leaves the click action")
        s.run("shape.action", #"{"action": "none"}"#)
        #expect(shape()?.click == nil)
        // Bad input is refused.
        #expect(s.fails("shape.action", #"{"action": "slide", "slide": 99}"#))
        #expect(s.fails("shape.action", #"{"action": "url"}"#))
        #expect(s.fails("shape.action", #"{"action": "customShow", "show": "nope"}"#))
        #expect(s.fails("shape.action", #"{"on": "drag", "action": "next"}"#))
    }

    private func chartOf(_ s: Session, _ id: UInt64) -> Chart? {
        guard let i = UInt32(exactly: id), case .chart(let c)? = s.st.shape(ShapeId(i))?.kind else { return nil }
        return c
    }

    // tests.rs::chart_options_text_color_sets_clears_and_refuses
    @Test func chartOptionsTextColorSetsClearsAndRefuses() throws {
        let s = session()
        let id = try #require(s.run("insert.chart", #"{"type": "column", "title": "Sales"}"#).get("id")?.asU64)
        #expect(chartOf(s, id)?.textColor == nil)
        s.run("chart.options", ##"{"id": \##(id), "textColor": "#FF0000"}"##)
        #expect(chartOf(s, id)?.textColor == .rgb(Rgba.rgb(255, 0, 0)))
        s.run("chart.options", #"{"id": \#(id), "textColor": "accent2"}"#)
        #expect(chartOf(s, id)?.textColor == .scheme(.accent2))
        do {
            _ = try s.execute("chart.options", j(#"{"id": \#(id), "textColor": "reddish"}"#))
            Issue.record("accepted")
        } catch {
            #expect("\(error)".contains("textColor"), "\(error)")
        }
        #expect(chartOf(s, id)?.textColor == .scheme(.accent2), "refused: unchanged")
        s.run("chart.options", #"{"id": \#(id), "textColor": null}"#)
        #expect(chartOf(s, id)?.textColor == nil)
    }

    // tests.rs::format_color_on_a_selected_chart_sets_its_text_color
    @Test(.enabled(if: ported("format.color"))) func formatColorOnASelectedChartSetsItsTextColor() throws {
        let s = session()
        let id = try #require(s.run("insert.chart", #"{"type": "column", "title": "Sales"}"#).get("id")?.asU64)
        s.run("edit.select", #"{"ids": [\#(id)]}"#)
        s.run("format.color", #"{"color": "accent2"}"#)
        #expect(chartOf(s, id)?.textColor == .scheme(.accent2))
    }

    /// (text, linked?) of each run in the first paragraph of the current slide's title.
    private func titleRuns(_ s: Session) -> [String] {
        (s.st.currentSlide?.shapes.first?.text?.paragraphs.first?.runs ?? []).map { "\($0.text)|\($0.props.link != nil)" }
    }

    private func editTitle0(_ s: Session) {
        s.run("text.edit", #"{"id": \#(s.st.currentSlide?.shapes.first?.id.rawValue ?? 0)}"#)
    }

    // tests.rs::hyperlink_with_a_bare_caret_inserts_the_address
    @Test(.enabled(if: ported("text.edit", "text.insert"))) func hyperlinkWithABareCaretInsertsTheAddress() {
        let s = session()
        editTitle0(s)
        s.run("text.insert", #"{"text": "See "}"#)
        s.run("insert.hyperlink", #"{"url": "https://example.org"}"#)
        s.run("text.insert", #"{"text": " now"}"#)
        #expect(titleRuns(s) == ["See |false", "https://example.org|true", " now|false"], "the address is inserted as a link")
    }

    // tests.rs::hyperlink_display_text_and_targets
    @Test(.enabled(if: ported("text.edit", "text.insert"))) func hyperlinkDisplayTextAndTargets() {
        let s = session()
        editTitle0(s)
        s.run("insert.hyperlink", #"{"url": "mailto:a@b.org"}"#)
        #expect(titleRuns(s) == ["a@b.org|true"], "email links show the address without mailto:")
        s.run("text.insert", #"{"text": " "}"#)
        s.run("insert.hyperlink", #"{"slide": 0, "text": "start"}"#)
        #expect(titleRuns(s) == ["a@b.org|true", " |false", "start|true"])
    }

    // tests.rs::hyperlink_on_a_word_or_shape_links_it
    @Test(.enabled(if: ported("text.edit", "text.insert", "text.move", "text.exit"))) func hyperlinkOnAWordOrShapeLinksIt() {
        let s = session()
        editTitle0(s)
        s.run("text.insert", #"{"text": "Hello world"}"#)
        s.run("text.move", #"{"to": "left"}"#)
        s.run("insert.hyperlink", #"{"url": "https://example.org"}"#)
        #expect(titleRuns(s) == ["Hello |false", "world|true"], "a caret inside a word links the word")
        s.run("text.exit")
        s.run("insert.hyperlink", #"{"url": "https://example.org"}"#)
        #expect(s.st.currentSlide?.shapes.first?.click != nil, "a selected shape gets the link as its click action")
    }

    // tests.rs::hyperlink_can_keep_highlight_click
    @Test(.enabled(if: ported("text.edit", "text.exit"))) func hyperlinkCanKeepHighlightClick() throws {
        let s = session()
        editTitle0(s)
        s.run("text.exit")
        s.run("insert.hyperlink", #"{"url": "https://example.org", "tooltip": "tip", "highlightClick": true}"#)
        let click = try #require(s.st.currentSlide?.shapes.first?.click)
        #expect(click.tooltip == "tip")
        #expect(click.highlightClick)
        #expect(click.action == .url(url: "https://example.org"))
        s.run("insert.hyperlink", #"{"url": "https://example.org"}"#)
        #expect(s.st.currentSlide?.shapes.first?.click?.highlightClick == false, "omitting the flag still stores false")
    }

    // tests.rs::inserted_hyperlinks_look_like_links
    @Test(.enabled(if: ported("text.edit", "text.insert", "text.move", "format.state", "format.underline")))
    func insertedHyperlinksLookLikeLinks() throws {
        let s = session()
        editTitle0(s)
        s.run("text.insert", #"{"text": "Read the docs"}"#)
        s.run("text.move", #"{"to": "wordLeft", "extend": true}"#)
        #expect(s.run("format.state").get("underline") == false)
        s.run("insert.hyperlink", #"{"url": "https://example.org"}"#)
        // Underlined (and hlink-coloured) without touching the run's own props.
        #expect(s.run("format.state").get("underline") == true)
        let run = try #require(s.st.currentSlide?.shapes.first?.text?.paragraphs.first?.runs.first { $0.props.link != nil })
        #expect(run.props.fill == nil && run.props.underline == nil, "\(run)")
        // Underline off is the run's own u="none", as in PowerPoint.
        s.run("format.underline")
        #expect(s.run("format.state").get("underline") == false)
    }

    /// New: the shape and icon galleries list deckcraft's catalogues, and automatic names count up past
    /// gaps (insert.rs `auto_name_base`, `first_free_name`).
    @Test func galleriesAndAutomaticNames() throws {
        let s = session()
        #expect(s.run("shape.presets").asArray?.count == Preset.catalog.count)
        #expect(s.run("insert.icons").asArray?.count == Icons.icons.count)
        s.run("slide.new", #"{"layout": "blank"}"#)
        let a = s.run("shape.insert", #"{"preset": "rect"}"#).get("id")?.asU32 ?? 0
        s.run("shape.insert", #"{"preset": "rect"}"#)
        #expect(s.st.shapes.map(\.name) == ["Rectangle 1", "Rectangle 2"])
        s.run("edit.select", #"{"ids": [\#(a)]}"#)
        s.run("edit.delete")
        s.run("shape.insert", #"{"preset": "rect"}"#)
        #expect(s.st.shapes.map(\.name) == ["Rectangle 2", "Rectangle 3"], "a gap never makes a second Rectangle 2")
        s.run("insert.table")
        s.run("insert.chart")
        s.run("insert.textBox", #"{"text": "x"}"#)
        #expect(Array(s.st.shapes.map(\.name).suffix(3)) == ["Table 3", "Chart 4", "TextBox 5"])
        #expect(InsertCommands.contentType("a.mov", Array("....ftypqt  ".utf8)) == "video/quicktime")
        #expect(InsertCommands.contentType("x", Array("<html><svg".utf8)) == "image/svg+xml")
        #expect(InsertCommands.contentType("x.aac", [0xFF, 0xF1]) == "audio/aac")
        #expect(InsertCommands.contentType("x.aac", [0xFF, 0xFB]) == "audio/aac")
        #expect(InsertCommands.contentType("x.mp3", [0xFF, 0xFB]) == "audio/mpeg")
        #expect(InsertCommands.contentType("", []) == "application/octet-stream")
    }
}
