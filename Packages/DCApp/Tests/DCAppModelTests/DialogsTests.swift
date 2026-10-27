// DCAppModelTests — the dialogs without a window: each opens with deckcraft's fields, and its buttons run
// deckcraft's commands with deckcraft's params. Ported from deckcraft `crates/ui-egui/src/dialogs.rs`'s tests
// and `columns_dialog_tests.rs`, `paragraph_dialog_tests.rs`, `font_dialog_tests.rs`,
// `size_position_tests.rs`, `replacefonts_tests.rs`, `photo_album_tests.rs`, `datetime_tests.rs`,
// `find_dialog_tests.rs`, `preferences_tests.rs` (MIT OR Apache-2.0); each test names its source. Where the
// Rust test clicked an egui widget, this one sets the field or presses the button through the controller,
// which is what the Mac window's controls do.
import DCCore
import DCEngine
import DCModel
import DCText
import Foundation
import Testing
@testable import DCAppModel

@MainActor
@Suite struct DialogsTests {
    /// A deck with one rectangle holding "Hello", selected (not editing its text).
    func withBox(_ rect: [Double] = [80, 80, 320, 80]) throws -> DialogsHost {
        let s = Session.withNew()
        _ = try s.execute("shape.insert", ["preset": "rect", "rect": .array(rect.map { .num($0) }), "text": "Hello"])
        _ = try? s.execute("text.exit")
        return DialogsHost(s)
    }

    // MARK: Hyperlink (dialogs.rs `tests`)

    // dialogs.rs: no_link_opens_as_a_new_web_address
    @Test func noLinkOpensAsANewWebAddress() {
        let seed = HyperlinkSeed.from(.none, [])
        #expect(seed == .blank)
        #expect(seed.shouldApply(mode: "url", url: "https://", email: "", slide: 0))
    }

    func link(_ action: Action, _ tip: String) -> Hyperlink { Hyperlink(action: action, tooltip: tip, highlightClick: false, stopSound: false) }
    func url(_ address: String, _ tip: String) -> Hyperlink {
        var h = link(.url(url: address), tip)
        h.highlightClick = tip == "glow"
        return h
    }

    // dialogs.rs: web_email_and_slide_links_fill_the_dialog
    @Test func webEmailAndSlideLinksFillTheDialog() {
        let ids = [SlideId(7), SlideId(9)]
        let web = HyperlinkSeed.of(url("https://example.org", "See"), ids)
        #expect(web.mode == "url" && web.url == "https://example.org" && web.tip == "See" && !web.preserve)
        #expect(web.shouldApply(mode: "url", url: "https://example.org", email: "", slide: 0))
        let mail = HyperlinkSeed.of(url("mailto:a@b.org", "Write"), ids)
        #expect(mail.mode == "email" && mail.email == "a@b.org" && mail.tip == "Write")
        #expect(HyperlinkSeed.command(mode: "email", url: "", email: "a@b.org", slide: 0, tip: "Write", highlight: false)["url"] == "mailto:a@b.org")
        let slide = HyperlinkSeed.of(link(.slide(slide: SlideId(9)), "There"), ids)
        #expect(slide.mode == "slide" && slide.slide == 1 && slide.tip == "There" && !slide.preserve)
        let glow = url("https://example.org", "glow")
        #expect(HyperlinkSeed.of(glow, ids).highlight)
        #expect(HyperlinkSeed.command(mode: "url", url: "https://example.org", email: "", slide: 0, tip: "glow", highlight: true)["highlightClick"] == true)
    }

    // dialogs.rs: actions_this_dialog_does_not_edit_survive_ok
    @Test func actionsThisDialogDoesNotEditSurviveOk() {
        let next = HyperlinkSeed.of(link(.nextSlide, "On"), [])
        #expect(next.preserve && next.tip == "On" && next.url == "")
        #expect(!next.shouldApply(mode: "url", url: "", email: "", slide: 0))
        #expect(next.shouldApply(mode: "url", url: "https://example.org", email: "", slide: 0))
        let gone = HyperlinkSeed.of(link(.slide(slide: SlideId(99)), ""), [SlideId(1)])
        #expect(gone.preserve, "a missing slide is not retargeted to the first slide")
        #expect(!gone.shouldApply(mode: "url", url: "", email: "", slide: 0))
        let mixed = HyperlinkSeed.from(.mixed, [])
        #expect(mixed.preserve)
        #expect(!mixed.shouldApply(mode: "url", url: "", email: "", slide: 0))
        #expect(mixed.shouldApply(mode: "email", url: "", email: "a@b.org", slide: 0))
    }

    // dialogs.rs: a_text_span_reports_the_link_it_covers
    @Test func aTextSpanReportsTheLinkItCovers() {
        var body = TextBody.fromText("Hello world")
        body.paragraphs[0].runs = [Run("Hello ")]
        var world = Run("world")
        world.props.link = url("https://example.org", "tip")
        body.paragraphs[0].runs.append(world)
        #expect(HyperlinkSeed.linkCovering(body, (0, 6), (0, 6)) == .none, "a caret inserts; it does not edit the run beside it")
        if case .one(let h) = HyperlinkSeed.linkCovering(body, (0, 6), (0, 11)) { #expect(h.tooltip == "tip") } else { Issue.record("linked word") }
        #expect(HyperlinkSeed.linkCovering(body, (0, 0), (0, 11)) == .mixed)
        var other = url("https://example.org", "tip")
        other.tooltip = "other"
        #expect(HyperlinkSeed.commonClick([nil, nil]) == .none)
        #expect(HyperlinkSeed.commonClick([url("https://example.org", "tip")]) == .one(url("https://example.org", "tip")))
        #expect(HyperlinkSeed.commonClick([url("https://example.org", "tip"), other]) == .mixed)
        #expect(HyperlinkSeed.commonClick([]) == .none)
    }

    // dialogs.rs: the_open_dialog_reads_the_caret_word_and_the_shape_click (through the engine's text commands)
    @Test func theOpenDialogReadsTheShapeClickAndOkLinksIt() throws {
        let h = try withBox()
        h.run("app.dialog", ["id": "hyperlink"])
        #expect(h.dialog?.value("url") == "https://")
        h.press("ok", ["url": "https://shape.example", "tip": "shape tip"])
        #expect(h.dialog == nil)
        let click = h.st?.selectedShapes.first?.click
        #expect(click?.action == .url(url: "https://shape.example"))
        #expect(click?.tooltip == "shape tip")
        h.run("app.dialog", ["id": "hyperlink"])
        #expect(h.dialog?.value("url") == "https://shape.example", "the dialog reopens on the shape's link")
        #expect(h.dialog?.value("tip") == "shape tip")
    }

    // MARK: Zoom, Trim, Alt Text

    // dialogs.rs zoom_tests: zoom_percent_accepts_a_number_and_clamps
    @Test func zoomPercentAcceptsANumberAndClamps() {
        func near(_ v: Double?, _ want: Double) -> Bool { v.map { abs($0 - want) < 1e-4 } ?? false }
        #expect(near(DialogMath.parseZoomPercent("150"), 1.5))
        #expect(near(DialogMath.parseZoomPercent("150%"), 1.5))
        #expect(near(DialogMath.parseZoomPercent("  100 "), 1.0))
        #expect(near(DialogMath.parseZoomPercent("1"), 0.1))
        #expect(near(DialogMath.parseZoomPercent("900"), 4.0))
        for bad in ["", "fit", "nan", "inf"] { #expect(DialogMath.parseZoomPercent(bad) == nil, "\(bad)") }
    }

    @Test func zoomDialogSetsAPercentOrFit() {
        let h = DialogsHost()
        h.run("view.zoomDialog")
        #expect(h.dialog?.value("mode") == "fit")
        h.press("ok", ["zoomPick": "150"])
        #expect(h.model.ui.zoom == 1.5)
        h.run("view.zoomDialog")
        h.press("ok", ["percent": "abc"])
        #expect(h.dialog?.id == "zoom", "a bad percent keeps the dialog")
        #expect(h.model.status == "Enter a zoom percent")
        h.press("ok", ["zoomPick": "fit"])
        #expect(h.model.ui.zoom == nil)
    }

    // dialogs.rs trim_media_tests: trim_seconds_round_trip_the_stored_milliseconds
    @Test func trimSecondsRoundTripTheStoredMilliseconds() {
        for ms: UInt32 in [0, 1, 250, 333, 1000, 1500, 60000] {
            let text = DialogMath.msAsSeconds(ms)
            #expect(DialogMath.secondsTextToMs(text) == ms, "\(text)")
        }
        #expect(DialogMath.secondsTextToMs("") == 0)
        #expect(DialogMath.secondsTextToMs("nope") == 0)
        #expect(DialogMath.secondsTextToMs("-2") == 0)
        #expect(DialogMath.secondsTextToMs("1.5") == 1500)
        #expect(DialogMath.secondsTextToMs("999999999") == UInt32.max)
        #expect(TrimSeed.of(nil).start == "0")
    }

    // dialogs.rs alt_text_tests: decorative_starts_checked_only_when_every_shape_is
    @Test func decorativeStartsCheckedOnlyWhenEveryShapeIs() {
        #expect(!DialogMath.altTextStartsDecorative([]))
        #expect(!DialogMath.altTextStartsDecorative([false]))
        #expect(DialogMath.altTextStartsDecorative([true]))
        #expect(DialogMath.altTextStartsDecorative([true, true]))
        #expect(!DialogMath.altTextStartsDecorative([true, false]))
    }

    @Test func altTextOkWritesTheDescription() throws {
        let h = try withBox()
        h.run("app.dialog", ["id": "altText"])
        h.press("ok", ["text": "A red box", "deco": "1"])
        #expect(h.st?.selectedShapes.first?.descr == "A red box")
        #expect(h.st?.selectedShapes.first?.decorative == true)
    }

    // MARK: Columns (columns_dialog_tests.rs)

    func twoBoxes() throws -> DialogsHost {
        let s = Session.withNew()
        var ids: [JSON] = []
        for (y, count, spacing) in [(80.0, 2, 9.0), (300.0, 3, 36.0)] {
            ids.append(try s.execute("shape.insert", ["preset": "rect", "rect": [80, .num(y), 320, 160], "text": "Hello"])["id"] ?? .null)
            _ = try? s.execute("text.exit")
            _ = try s.execute("format.columns", ["count": .integer(count), "spacing": .num(spacing)])
        }
        _ = try s.execute("edit.select", ["ids": .array(ids)])
        return DialogsHost(s)
    }

    func columnsOfEach(_ h: DialogsHost) -> [[Double?]] {
        h.st?.selectedShapes.map { [$0.text?.body.columns.map(Double.init), $0.text?.body.colSpacing] } ?? []
    }

    func okColumns(_ h: DialogsHost, _ fields: [String: String]) {
        h.run("format.columns")
        #expect(h.dialog?.id == "columns")
        h.press("ok", fields)
        #expect(h.dialog == nil, "status \(h.model.status ?? "")")
    }

    // columns_dialog_tests.rs: a_field_left_as_shown_keeps_each_text_box_s_own_value
    @Test func aFieldLeftAsShownKeepsEachTextBoxsOwnValue() throws {
        var h = try twoBoxes()
        #expect(columnsOfEach(h) == [[2, 9], [3, 36]])
        okColumns(h, ["count": "4"])
        #expect(columnsOfEach(h) == [[4, 9], [4, 36]], "Number only")
        h = try twoBoxes()
        okColumns(h, ["spacing": "0.5"])
        #expect(columnsOfEach(h) == [[2, 36], [3, 36]], "Spacing only")
    }

    // columns_dialog_tests.rs: ok_with_nothing_changed_closes_without_an_edit
    @Test func okWithNothingChangedClosesWithoutAnEdit() throws {
        let h = try twoBoxes()
        let n = h.undoLabels.count
        okColumns(h, [:])
        #expect(h.undoLabels.count == n)
        #expect(columnsOfEach(h) == [[2, 9], [3, 36]])
    }

    // columns_dialog_tests.rs: more_columns_sets_the_number_and_spacing_in_one_undo,
    // ok_with_the_spacing_unchanged_keeps_the_exact_spacing
    @Test func moreColumnsSetsTheNumberAndSpacingInOneUndo() throws {
        let h = try withBox([80, 80, 320, 160])
        _ = try h.session.execute("format.columns", ["count": 3, "spacing": 9.0])
        h.run("format.columns")
        #expect(h.dialog?.value("count") == "3")
        #expect(h.dialog?.value("spacing") == "0.12", "shown rounded to two places")
        let n = h.undoLabels.count
        h.press("ok", ["count": "2", "spacing": "0.5"])
        #expect(columnsOfEach(h) == [[2, 36]])
        #expect(h.undoLabels.count == n + 1)
        #expect(h.undoLabels.last == "Columns")
        h.run("format.columns")
        h.press("ok", ["count": "4"])
        #expect(columnsOfEach(h) == [[4, 36]], "the exact spacing is kept")
    }

    // columns_dialog_tests.rs: a_bad_number_keeps_the_dialog_open_and_changes_nothing
    @Test func aBadNumberKeepsTheDialogOpenAndChangesNothing() throws {
        let h = try withBox([80, 80, 320, 160])
        h.run("format.columns")
        for (count, spacing) in [("0", "0.25"), ("17", "0.25"), ("two", "0.25"), ("2", "-1"), ("2", "wide")] {
            h.press("ok", ["count": count, "spacing": spacing])
            #expect(h.dialog?.id == "columns", "\(count) / \(spacing)")
            #expect(!(h.dialog?.value("error").isEmpty ?? true), "\(count) / \(spacing)")
            #expect(columnsOfEach(h) == [[nil, nil]], "\(count) / \(spacing)")
        }
    }

    // MARK: Paragraph and Tabs (paragraph_dialog_tests.rs)

    // paragraph_dialog_tests.rs: paragraph_button_aligns_text_in_one_undo
    @Test func paragraphButtonAlignsTextInOneUndo() throws {
        let h = try withBox()
        h.run("format.paragraphDialog")
        #expect(h.dialog?.id == "paragraph")
        h.press("ok", ["align": "right"])
        #expect(h.dialog == nil, "status \(h.model.status ?? "")")
        #expect(h.st?.selectedShapes.first?.text?.paragraphs.first?.props.align == .right)
        #expect(h.undoLabels.last == "Paragraph…")
    }

    // paragraph_dialog_tests.rs: tabs_from_paragraph_applies_a_stop_and_returns
    @Test func tabsFromParagraphAppliesAStopAndReturns() throws {
        let h = try withBox()
        h.run("format.paragraphDialog")
        h.dialogs.set("align", "right")
        h.dialogs.press("tabs")
        #expect(h.dialog?.id == "tabs")
        h.press("ok", ["stops": "2:ctr"])
        #expect(h.dialog?.id == "paragraph", "Tabs returns to Paragraph")
        #expect(h.dialog?.value("align") == "right")
        let tabs = h.st?.selectedShapes.first?.text?.paragraphs.first?.props.tabs ?? []
        #expect(tabs.map(\.pos) == [144] && tabs.map(\.align) == ["ctr"])
        #expect(h.undoLabels.last == "Tabs…")
        h.dialogs.press("cancel")
        #expect(h.dialog == nil)
        #expect(h.st?.selectedShapes.first?.text?.paragraphs.first?.props.align == .center, "cancelling Paragraph leaves the alignment shape.insert wrote")
    }

    @Test func tabsSetAndClear() throws {
        let h = try withBox()
        h.run("app.dialog", ["id": "tabs"])
        h.press("set", ["newpos": "1.5", "newalign": "r"])
        h.press("set", ["newpos": "0.5"])
        #expect(h.dialog?.value("stops") == "0.5:r|1.5:r")
        h.dialogs.press("clear:0")
        #expect(h.dialog?.value("stops") == "1.5:r")
        h.press("set", ["newpos": "99"])
        #expect(h.dialog?.value("stops") == "1.5:r", "a stop past 56 inches is refused")
    }

    // MARK: Font (font_dialog_tests.rs)

    // font_dialog_tests.rs: font_button_applies_bold_from_the_dialog
    @Test func fontButtonAppliesBoldFromTheDialog() throws {
        let h = try withBox()
        h.run("format.fontDialog")
        #expect(h.dialog?.id == "font")
        h.press("ok", ["bold": "1"])
        #expect(h.dialog == nil, "status \(h.model.status ?? "")")
        #expect(h.st?.selectedShapes.first?.text?.paragraphs.first?.runs.first?.props.bold == true)
        #expect(h.undoLabels.last == "Font…")
    }

    // font_dialog_tests.rs: command_t_opens_the_font_dialog_and_cancel_keeps_the_text
    @Test func cancelKeepsTheText() throws {
        let h = try withBox()
        h.run("format.fontDialog")
        h.dialogs.press("cancel")
        #expect(h.dialog == nil)
        #expect(h.st?.selectedShapes.first?.text?.paragraphs.first?.runs.first?.props.bold == nil)
    }

    @Test func fontRefusesABadSize() throws {
        let h = try withBox()
        h.run("format.fontDialog")
        h.press("ok", ["size": "big"])
        #expect(h.dialog?.id == "font")
        #expect(h.model.status == "Font size must be a number")
    }

    // MARK: Size and Position (size_position_tests.rs)

    // size_position_tests.rs: size_button_sets_width_in_one_undo
    @Test func sizeButtonSetsWidthInOneUndo() throws {
        let h = DialogsHost()
        let id = try #require(try h.session.execute("shape.insert", ["preset": "rect", "rect": [40, 50, 200, 100]])["id"]?.asU32)
        h.run("shape.sizePosition")
        #expect(h.dialog?.id == "sizePosition")
        #expect(h.dialog?.value("w") == "2.78")
        #expect(h.dialog?.value("h") == "1.39")
        #expect(h.dialog?.value("lock") == "0")
        h.press("ok", ["w": "4"])
        #expect(h.dialog == nil)
        let x = try #require(h.st?.shape(ShapeId(id))?.xfrm)
        #expect([x.x, x.y, x.w, x.h, x.rot] == [40, 50, 288, 100, 0])
        #expect(h.undoLabels.last == "Size and Position…")
    }

    // size_position_tests.rs: lock_aspect_from_the_dialog_scales_height
    @Test func lockAspectFromTheDialogScalesHeight() throws {
        let h = DialogsHost()
        let id = try #require(try h.session.execute("shape.insert", ["preset": "rect", "rect": [40, 50, 200, 100]])["id"]?.asU32)
        h.run("shape.sizePosition")
        h.dialogs.set("lock", "1")
        h.dialogs.set("w", "4")
        #expect(h.dialog?.value("h") == "2", "the height follows as it is typed")
        #expect(h.dialog?.value("scaleW") == "144")
        h.dialogs.press("ok")
        let x = try #require(h.st?.shape(ShapeId(id))?.xfrm)
        #expect([x.x, x.y, x.w, x.h, x.rot] == [40, 50, 288, 144, 0])
    }

    // MARK: Header and Footer (dialogs.rs header_footer_apply_keeps_an_existing_date_format)

    @Test func headerFooterApplyKeepsAnExistingDateFormat() throws {
        let s = Session.withNew()
        _ = try s.execute("design.headerFooter", ["date": true, "dateText": "", "dateFormat": "datetime4", "all": true])
        func dateFields() -> [String] {
            (s.activeDoc?.doc.slides ?? []).flatMap(\.shapes).filter { $0.phType == .date }.compactMap(\.text).flatMap(\.paragraphs).flatMap(\.runs).compactMap {
                if case .field(let f) = $0.kind { return f }
                return nil
            }
        }
        #expect(dateFields() == ["datetime4"])
        let h = DialogsHost(s)
        h.run("app.dialog", ["id": "headerFooter"])
        #expect(h.dialog?.value("dateFormat") == "datetime4", "the format it shows")
        #expect(h.dialog?.fields["dateFormat"] == nil, "is not a format the user picked")
        h.dialogs.press("apply")
        #expect(h.dialog == nil)
        #expect(dateFields() == ["datetime4"], "the dialog left the field's format alone")
    }

    // MARK: Replace Fonts (replacefonts_tests.rs ribbon_button_opens_the_dialog_and_replaces)

    @Test func replaceFontsReplacesAndStaysOpen() throws {
        let s = Session.withNew()
        _ = try s.execute("slide.new", ["layout": "blank"])
        _ = try s.execute("insert.textBox", ["rect": [40, 40, 400, 80], "text": "Hello fonts"])
        _ = try s.execute("text.exit")
        _ = try s.execute("format.font", ["family": "Comic Neue"])
        let h = DialogsHost(s)
        func runFont() -> String? { h.st?.currentSlide?.shapes.compactMap(\.text).first?.paragraphs.first?.runs.first?.props.font }
        h.run("app.dialog", ["id": "replaceFonts"])
        #expect(h.dialog?.id == "replaceFonts")
        h.press("ok", ["from": "Comic Neue", "to": "Lato"])
        #expect(runFont() == "Lato")
        #expect(h.dialog?.id == "replaceFonts", "the dialog stays open")
        #expect(h.dialog?.fields["result"]?.hasPrefix("Replaced “Comic Neue”") == true)
        _ = try s.execute("edit.undo")
        #expect(runFont() == "Comic Neue")
    }

    // MARK: Date and Time (datetime_tests.rs)

    // datetime_tests.rs: insert_opens_the_dialog_and_ok_inserts_one_field
    @Test func insertOpensTheDialogAndOkInsertsOneField() throws {
        let h = try withBox()
        _ = try h.session.execute("text.edit")
        h.run("insert.dateTime")
        #expect(h.dialog?.id == "dateTime")
        #expect(h.dialog?.value("language") == "en-US")
        #expect(h.dialogs.form.contains { if case .check(_, "update") = $0 { return true } else { return false } })
        let n = h.undoLabels.count
        h.press("ok", ["format": "datetime2"])
        #expect(h.dialog == nil)
        let runs = h.st?.selectedShapes.first?.text?.paragraphs.flatMap(\.runs) ?? []
        #expect(runs.contains { if case .field("datetime2") = $0.kind { true } else { false } })
        #expect(h.undoLabels.count == n + 1)
        #expect(h.undoLabels.last == "Date & Time")
    }

    // datetime_tests.rs: cancel_closes_the_dialog_without_a_date
    @Test func cancelClosesTheDialogWithoutADate() throws {
        let h = try withBox()
        h.run("insert.dateTime")
        let n = h.undoLabels.count
        h.dialogs.press("cancel")
        #expect(h.dialog == nil)
        #expect(h.undoLabels.count == n)
    }

    // MARK: Find (find_dialog_tests.rs ctrl_f_puts_the_caret_in_find_what)

    @Test func findStepsThroughMatchesAndReplaces() throws {
        let s = Session.withNew()
        _ = try s.execute("shape.insert", ["preset": "rect", "rect": [80, 80, 320, 80], "text": "hello there"])
        _ = try s.execute("text.exit")
        let h = DialogsHost(s)
        h.run("app.find")
        #expect(h.dialog?.id == "find")
        #expect(h.dialogs.buttons.first { $0.id == "findNext" }?.enabled == false, "nothing to find yet")
        h.press("findNext", ["text": "there"])
        #expect(h.dialog?.value("status").hasPrefix("Match 1 of 1") == true, "\(h.dialog?.value("status") ?? "")")
        h.press("findNext", ["text": "nowhere"])
        #expect(h.dialog?.value("status") == "DeckCraft can't find “nowhere”.")
        h.dialogs.press("showReplace")
        #expect(h.dialog?.flag("replace") == true)
        h.press("replaceAll", ["text": "there", "with": "world"])
        #expect(h.dialog?.value("status") == "Replaced 1 occurrence(s).")
        #expect(h.st?.currentSlide?.shapes.compactMap(\.text).contains { $0.text == "hello world" } == true)
        h.run("app.replace")
        #expect(h.dialog?.flag("replace") == true)
    }

    @Test func findWithNothingOpenIsThePalette() {
        let h = DialogsHost(Session())
        h.run("app.find")
        #expect(h.dialog == nil)
        #expect(h.dialogs.palette != nil)
    }

    // MARK: Preferences (preferences_tests.rs)

    // preferences_tests.rs: options_cancel_undoes_the_changes
    @Test func optionsCancelUndoesTheChanges() {
        let h = DialogsHost()
        let was = h.session.prefs.smartGuides
        h.run("app.preferences")
        #expect(h.dialog?.id == "preferences")
        h.dialogs.set("smartGuides", was ? "0" : "1")
        #expect(h.session.prefs.smartGuides == !was, "the change applies as it is made")
        h.dialogs.press("cancel")
        #expect(h.session.prefs.smartGuides == was, "Cancel restores the setting")
        #expect(h.dialog == nil)
    }

    // preferences_tests.rs: options_cancel_undoes_every_editing_setting
    @Test func optionsCancelUndoesEveryEditingSetting() {
        let h = DialogsHost()
        let before = h.session.prefs
        h.run("app.preferences")
        h.dialogs.set("snapToGrid", before.snapToGrid ? "0" : "1")
        h.dialogs.set("smartQuotes", before.smartQuotes ? "0" : "1")
        h.dialogs.set("autocorrect", before.autocorrect ? "0" : "1")
        h.dialogs.set("author", before.author + "Z")
        h.dialogs.set("units", "centimeters")
        let changed = h.session.prefs
        #expect(changed.snapToGrid != before.snapToGrid && changed.smartQuotes != before.smartQuotes && changed.autocorrect != before.autocorrect)
        #expect(changed.author == before.author + "Z" && changed.units == .centimeters)
        h.dialogs.press("cancel")
        #expect(h.session.prefs == before)
    }

    // preferences_tests.rs: options_cancel_puts_the_appearance_and_scale_back, options_close_button_restores_the_settings
    @Test func optionsCloseRestoresTheAppearance() {
        let h = DialogsHost()
        let was = h.model.ui.brightness
        h.run("app.preferences")
        h.dialogs.set("appearance", "dark")
        #expect(h.model.ui.brightness == .dark)
        // Esc, the window's close button and `ui.dialog.close` all cancel.
        h.dialogs.cancel()
        #expect(h.model.ui.brightness == was)
        h.run("app.preferences")
        h.dialogs.set("appearance", "dark")
        h.dialogs.press("ok")
        #expect(h.model.ui.brightness == .dark, "Done keeps the settings")
    }

    // dialogs.rs `preferences` → AutoCorrect Options…
    @Test func autocorrectOptionsReplacePreferencesAndEditTheList() {
        let h = DialogsHost()
        h.run("app.preferences")
        h.dialogs.press("autocorrectOptions")
        #expect(h.dialog?.id == "autocorrect")
        h.dialogs.set("acDays", "0")
        #expect(!h.session.prefs.acDays)
        h.press("add", ["from": "teh2", "to": "the"])
        #expect(h.session.prefs.acEntries.contains { $0.a == "teh2" && $0.b == "the" })
        #expect(h.dialog?.value("from") == "")
        h.dialogs.press("remove:teh2")
        #expect(!h.session.prefs.acEntries.contains { $0.a == "teh2" })
    }

    // MARK: Photo Album (photo_album_tests.rs)

    // photo_album_tests.rs: insert_ribbon_opens_the_dialog_without_editing
    @Test func insertPhotoAlbumOpensTheDialogWithoutEditing() {
        let h = DialogsHost()
        h.run("insert.photoAlbum")
        #expect(h.dialog?.id == "photoAlbum")
        #expect(h.st?.doc.slides.count == 1)
        #expect(h.undoLabels.isEmpty)
    }

    // photo_album_tests.rs: create_inserts_the_album_in_one_step
    @Test func createInsertsTheAlbumInOneStep() throws {
        let dir = TempDir("album")
        defer { dir.clean() }
        try Data(redPNG()).write(to: URL(filePath: dir.path("cat.png")))
        let h = DialogsHost()
        h.openPaths = [dir.path("cat.png")]
        h.run("insert.photoAlbum")
        h.dialogs.press("addPictures")
        #expect(h.dialogs.form.contains { if case .list(_, "sel", let o, _) = $0 { o.map(\.label) == ["cat.png"] } else { false } }, "the chosen file is listed")
        h.dialogs.press("newTextBox")
        #expect(h.dialogs.form.contains { if case .list(_, "sel", let o, _) = $0 { o.last?.label == "Text: Text Box" } else { false } })
        h.dialogs.press("ok")
        #expect(h.dialog == nil, "Create closes the dialog")
        #expect(h.st?.doc.slides.count == 3)
        #expect(h.undoLabels == ["Photo Album…"])
        let pics = h.st?.doc.slides.at(1)?.shapes.filter { if case .picture = $0.kind { true } else { false } } ?? []
        #expect(pics.count == 1)
        #expect(pics.first?.line?.width == 1.5)
    }

    // photo_album_tests.rs: update_reflows_the_open_album
    @Test func updateReflowsTheOpenAlbum() throws {
        let data = JSON.string(Cmd.base64Encode(redPNG()))
        let h = DialogsHost()
        _ = try h.run("insert.photoAlbum", ["pictures": [["name": "hill.png", "data": data], ["name": "lake.png", "data": data]], "layout": "1"]).get()
        #expect(h.st?.doc.slides.count == 3)
        h.run("insert.photoAlbumEdit")
        #expect(h.dialog?.id == "photoAlbum")
        #expect(h.dialogs.buttons.contains { $0.label == "Update" })
        #expect(h.dialog?.value("layout") == "1")
        h.press("ok", ["grayscale": "1", "layout": "2"])
        #expect(h.dialog == nil, "Update closes the dialog")
        #expect(h.st?.doc.slides.count == 2)
        #expect(h.undoLabels.last == "Edit Photo Album…")
        let pics = h.st?.doc.slides.at(1)?.shapes.compactMap { sh -> PictureFill? in if case .picture(let f) = sh.kind { return f }; return nil } ?? []
        #expect(pics.count == 2)
        #expect(pics.first?.adjust.grayscale == true)
    }

    // photo_album_tests.rs: create_with_nothing_keeps_the_dialog
    @Test func createWithNothingKeepsTheDialog() {
        let h = DialogsHost()
        h.run("insert.photoAlbum")
        h.dialogs.press("ok")
        #expect(h.dialog?.id == "photoAlbum")
        #expect(h.st?.doc.slides.count == 1)
        #expect(h.model.status == "Add a picture or a text box first")
    }

    // MARK: The other dialogs' OK

    @Test func tableInsertsTheTypedSize() {
        let h = DialogsHost()
        h.run("app.dialog", ["id": "table"])
        h.press("ok", ["rows": "3", "cols": "4"])
        let t = h.st?.currentSlide?.shapes.compactMap { sh -> Table? in if case .table(let t) = sh.kind { return t }; return nil }.first
        #expect(t?.rows.count == 3)
        #expect(t?.cols.count == 4)
    }

    @Test func gridOptionsApplyAndRefuse() {
        let h = DialogsHost()
        h.run("view.gridOptions")
        #expect(h.dialog?.id == "gridOptions")
        h.press("ok", ["spacing": "500"])
        #expect(h.dialog?.id == "gridOptions", "an out-of-range spacing keeps the dialog")
        #expect(h.dialog?.value("error").contains("288") == true)
        h.press("ok", ["spacing": "12", "gridlines": "1"])
        #expect(h.dialog == nil)
        #expect(h.session.prefs.gridSpacing == 12 && h.model.ui.gridlines)
    }

    @Test func slideSizePresetsAndOrientation() {
        let h = DialogsHost()
        h.run("app.dialog", ["id": "slideSize"])
        h.dialogs.set("preset", "Standard (4:3)")
        #expect(h.dialog?.value("w") == "10.00" && h.dialog?.value("h") == "7.50")
        h.dialogs.set("orientation", "portrait")
        #expect(h.dialog?.value("w") == "7.50" && h.dialog?.value("h") == "10.00")
        h.dialogs.press("ok")
        #expect(h.st?.doc.slideSize.width == 540 && h.st?.doc.slideSize.height == 720)
    }

    @Test func customShowsCreateAndDelete() {
        let h = DialogsHost()
        _ = h.run("slide.new")
        h.run("app.dialog", ["id": "customShow"])
        h.press("ok", ["name": "Short", "slides": "2, 1"])
        #expect(h.st?.doc.customShows.map(\.name) == ["Short"])
        #expect(h.st?.doc.customShows.first?.slides.count == 2)
        h.run("app.dialog", ["id": "customShow"])
        h.dialogs.press("delete:0")
        #expect(h.st?.doc.customShows.isEmpty == true)
    }

    @Test func chartDataEditsTheSeries() throws {
        let h = DialogsHost()
        _ = try h.run("insert.chart").get()
        h.run("app.dialog", ["id": "chartData"])
        #expect(h.dialogs.form.contains { if case .grid = $0 { true } else { false } })
        h.dialogs.press("addRow")
        let rows = (h.dialog?.params["grid"]?.asArray ?? []).count
        h.dialogs.set("cell:\(rows - 1):0", "New")
        h.dialogs.set("cell:\(rows - 1):1", "42")
        h.dialogs.press("ok")
        let chart = h.st?.selectedShapes.compactMap { sh -> Chart? in if case .chart(let c) = sh.kind { return c }; return nil }.first
        #expect(chart?.categories.last == "New")
        #expect(chart?.series.first?.values.last == 42)
    }

    @Test func chartDataWithoutAChartOnlyCloses() {
        let h = DialogsHost()
        h.run("app.dialog", ["id": "chartData"])
        #expect(h.dialogs.buttons.map(\.id) == ["ok"])
        #expect(h.dialogs.form == [.note("Select a chart first.")])
    }

    @Test func bulletsAndNumbering() throws {
        let h = try withBox()
        h.run("app.dialog", ["id": "bullets"])
        h.press("ok", ["tab": "numbered", "scheme": "romanUcPeriod", "start": "3"])
        let pp = h.st?.selectedShapes.first?.text?.paragraphs.first?.props
        #expect(pp?.bullet != nil)
        h.run("app.dialog", ["id": "bullets"])
        #expect(h.dialog?.value("tab") == "numbered", "the dialog opens on the paragraph's list")
    }

    @Test func everyDialogOpensWithAFormAndAButton() throws {
        let h = try withBox()
        for id in DialogCatalog.ids {
            h.run("app.dialog", ["id": .string(id)])
            #expect(h.dialog?.id == id)
            #expect(!h.dialogs.form.isEmpty, "\(id)")
            #expect(!h.dialogs.buttons.isEmpty, "\(id)")
            #expect(h.dialogs.title != "DeckCraft", "\(id)")
            #expect(h.dialogs.describe()["id"]?.asStr == id)
            h.dialogs.cancel()
        }
    }

    @Test func pressingAnUnknownButtonIsRefused() {
        let h = DialogsHost()
        h.run("app.dialog", ["id": "table"])
        #expect(!h.dialogs.press("nope"))
        #expect(h.dialog?.id == "table")
    }

    @Test func engineDialogRequestsOpenTheirDialogs() throws {
        let h = try withBox()
        for (cmd, id) in [("format.fontDialog", "font"), ("format.paragraphDialog", "paragraph"), ("format.columns", "columns"), ("design.colors", "themeColors"), ("design.fonts", "themeFonts")] {
            h.run(cmd)
            #expect(h.dialog?.id == id, "\(cmd)")
            h.dialogs.cancel()
        }
    }

    @Test func themeColorsSaveNeedsValidColours() {
        let h = DialogsHost()
        h.run("design.colors")
        h.press("ok", ["accent1": "nope"])
        #expect(h.dialog?.id == "themeColors")
        #expect(h.model.status == "Accent 1 needs a colour like #RRGGBB.")
        h.press("ok", ["accent1": "#FF0000", "schemeName": "Mine"])
        #expect(h.dialog == nil)
        #expect(h.st?.doc.masters.first?.theme.colors.name == "Mine")
    }

    @Test func prettyEquation() {
        // deckcraft's rule: a superscript run takes digits, then one letter or sign, so `^2+` is `²⁺`.
        #expect(DialogMath.prettyEquation("a^2+b^2=c^2") == "a²⁺b²=c²")
        #expect(DialogMath.prettyEquation("a^2 + b^2") == "a² + b²")
        #expect(DialogMath.prettyEquation("x^n * pi") == "xⁿ · π")
        #expect(DialogMath.prettyEquation("a<=b+-c") == "a≤b±c")
    }
}
