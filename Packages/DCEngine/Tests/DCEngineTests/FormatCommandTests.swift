// DCEngineTests — the `format` command module: the Font and Paragraph dialogs, columns, tabs and the ruler,
// text transforms and transparency, numbering, languages, Change Case.
// Ports the in-file tests of deckcraft crates/engine/src/cmd/format.rs, cmd/ruler_tests.rs and the format
// tests of tests.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
//
// Not ported here: tests.rs `what_a_command_acts_on_names_only_keys_it_takes` (ported by the core,
// RegistryTests).
import DCColor
import DCCore
@testable import DCEngine
import DCModel
import Foundation
import Testing

private func idOf(_ r: JSON) -> UInt64 { r.get("id")?.asU64 ?? 0 }

/// A session with a selected rectangle holding "Hello" (format.rs tests' `shape`).
private func shape() -> Session {
    let s = session()
    s.run("shape.insert", #"{"preset": "rect", "rect": [40.0, 40.0, 240.0, 80.0], "text": "Hello"}"#)
    return s
}

/// The first run's props of the first selected shape.
private func props(_ s: Session) -> RunProps {
    s.st.selectedShapes.first?.text?.paragraphs.first?.runs.first?.props ?? RunProps()
}

/// The first paragraph's props of the first selected shape.
private func para(_ s: Session) -> ParaProps {
    s.st.selectedShapes.first?.text?.paragraphs.first?.props ?? ParaProps()
}

private func body(_ s: Session) -> BodyProps {
    s.st.selectedShapes.first?.text?.body ?? BodyProps()
}

/// The last request to the UI, when it is a dialog: (id, params).
private func lastDialog(_ s: Session) -> (String, JSON)? {
    if case .dialog(let id, let params)? = s.uiRequests.last { return (id, params) }
    return nil
}

// MARK: - cmd/format.rs

@Suite("Format: dialogs", .enabled(if: ported("shape.insert")))
struct FormatDialogTests {
    // cmd/format.rs tests
    @Test func fontDialogAppliesCharacterFormattingInOneUndo() {
        let s = shape()
        let before = s.st.history.undo.count
        s.run("format.fontDialog", ##"{"family": "Liberation Serif", "size": 28, "bold": true, "italic": false, "underline": "wavy", "color": "#112233", "strike": "dbl", "baseline": "super", "caps": "small", "spacing": 3}"##)
        #expect(s.st.history.undo.count == before + 1)
        #expect(s.st.history.undo.last?.label == "Font…")
        let r = props(s)
        #expect(r.font == "Liberation Serif")
        #expect(r.size == 28.0)
        #expect(r.bold == true)
        #expect(r.italic == false)
        #expect(r.underline == "wavy")
        if case .solid(let color)? = r.fill, case .rgb = color.base {} else { Issue.record("solid rgb fill: \(String(describing: r.fill))") }
        #expect(r.strike == .double)
        #expect(r.baseline == 0.3)
        #expect(r.caps == .small)
        #expect(r.spacing == 3.0)
        s.run("edit.undo")
        let u = props(s)
        #expect(u.font == nil && u.size == nil && u.bold == nil && u.underline == nil && u.fill == nil)
        #expect(u.strike == nil)
        #expect(u.caps == nil)
    }

    // cmd/format.rs tests
    @Test func fontDialogChangesOnlyTheFieldsItIsGiven() {
        let s = shape()
        s.run("format.bold", #"{"on": true}"#)
        s.run("format.fontDialog", #"{"size": 22, "color": {"scheme": "accent2", "lumMod": 50000}}"#)
        let r = props(s)
        #expect(r.bold == true)
        #expect(r.size == 22.0)
        #expect(r.font == nil && r.italic == nil)
        guard case .solid(let color)? = r.fill else {
            Issue.record("solid fill")
            return
        }
        #expect(color.base == .scheme(slot: .accent2))
        #expect(color.mods.contains { $0.xmlName == "lumMod" })
        s.run("edit.undo")
        let u = props(s)
        #expect(u.bold == true)
        #expect(u.size == nil && u.fill == nil)
    }

    // cmd/format.rs tests
    @Test func fontDialogWithNoFieldsAsksTheUIToOpen() throws {
        let s = shape()
        s.run("format.italic", #"{"on": true}"#)
        let rev = s.st.revision
        let n = s.st.history.undo.count
        s.uiRequests.removeAll()
        s.run("format.fontDialog")
        #expect(s.st.revision == rev)
        #expect(s.st.history.undo.count == n)
        let (id, params) = try #require(lastDialog(s))
        #expect(id == "font")
        #expect(params.get("italic") == true)
        #expect(params.get("bold") == false)
        #expect(params.get("family")?.asStr.map { !$0.isEmpty } == true)
        #expect(params.get("size")?.asF64.map { $0 > 0 } == true)
    }

    // cmd/format.rs tests
    @Test func fontDialogRejectsBadFieldsWithoutEditing() {
        let s = shape()
        let n = s.st.history.undo.count
        do {
            _ = try s.execute("format.fontDialog", j(#"{"underline": "sparkle"}"#))
            Issue.record("an unknown underline is refused")
        } catch {
            #expect(String(describing: error).contains("underline"), "\(error)")
        }
        #expect(s.fails("format.fontDialog", #"{"size": "large"}"#))
        #expect(s.fails("format.fontDialog", #"{"bold": 1}"#))
        #expect(s.fails("format.fontDialog", #"{"family": "  "}"#))
        #expect(s.fails("format.fontDialog", #"{"color": "not-a-color"}"#))
        #expect(s.st.history.undo.count == n)
        #expect(props(s).underline == nil)
        s.run("edit.deselect")
        #expect(s.fails("format.fontDialog", #"{"bold": true}"#))
    }

    // cmd/format.rs tests
    @Test func paragraphDialogAppliesAlignmentIndentAndSpacingInOneUndo() {
        let s = shape()
        let before = s.st.history.undo.count
        s.run("format.paragraphDialog", #"{"align": "justify", "indentLeft": 36.0, "indentRight": 18.0, "special": "hanging", "specialBy": 18.0, "spaceBefore": 6.0, "spaceAfter": 8.0, "lineSpacing": 1.5}"#)
        #expect(s.st.history.undo.count == before + 1)
        #expect(s.st.history.undo.last?.label == "Paragraph…")
        let p = para(s)
        #expect(p.align == .justify)
        #expect(p.marginLeft == 36.0)
        #expect(p.marginRight == 18.0)
        #expect(p.indent == -18.0)
        #expect(p.spaceBefore == .pts(6.0))
        #expect(p.spaceAfter == .pts(8.0))
        #expect(p.lineSpacing == .pct(1.5))
        s.run("edit.undo")
        let u = para(s)
        #expect(u.align == .center, "undo restores the alignment shape.insert wrote")
        #expect(u.marginLeft == nil && u.indent == nil && u.spaceBefore == nil && u.lineSpacing == nil)
    }

    // cmd/format.rs tests
    @Test func paragraphDialogFirstLineAndExactSpacingReplaceOnlyThoseFields() {
        let s = shape()
        s.run("format.paragraphDialog", #"{"align": "right"}"#)
        s.run("format.paragraphDialog", #"{"special": "first", "specialBy": 27.0, "lineSpacingPt": 20.0}"#)
        let p = para(s)
        #expect(p.align == .right)
        #expect(p.indent == 27.0)
        #expect(p.lineSpacing == .pts(20.0))
        #expect(p.marginLeft == nil)
        s.run("edit.undo")
        #expect(para(s).align == .right)
        #expect(para(s).indent == nil)
    }

    // cmd/format.rs tests
    @Test func paragraphDialogWithNoFieldsAsksTheUIToOpen() throws {
        let s = shape()
        let rev = s.st.revision
        let n = s.st.history.undo.count
        s.uiRequests.removeAll()
        s.run("format.paragraphDialog")
        #expect(s.st.revision == rev)
        #expect(s.st.history.undo.count == n)
        let (id, params) = try #require(lastDialog(s))
        #expect(id == "paragraph")
        #expect(params.get("align") == "center", "a new shape's text is centred")
        #expect(params.get("special") == "none")
        #expect(params.get("lineKind") == "multiple")
        #expect(params.get("lineValue")?.asF64.map { $0 > 0 } == true)
    }

    // cmd/format.rs tests
    @Test func paragraphDialogRejectsBadFieldsWithoutEditing() {
        let s = shape()
        let n = s.st.history.undo.count
        do {
            _ = try s.execute("format.paragraphDialog", j(#"{"align": "sparkle"}"#))
            Issue.record("an unknown alignment is refused")
        } catch {
            #expect(String(describing: error).contains("align"))
        }
        #expect(s.fails("format.paragraphDialog", #"{"special": "middle"}"#))
        #expect(s.fails("format.paragraphDialog", #"{"indentLeft": "wide"}"#))
        #expect(s.fails("format.paragraphDialog", #"{"lineSpacing": "double"}"#))
        #expect(s.fails("format.paragraphDialog", #"{"spaceBeforeKind": "lines", "spaceBefore": 4.0}"#))
        #expect(s.st.history.undo.count == n)
        #expect(para(s).align == .center)
        #expect(para(s).indent == nil)
    }

    // cmd/format.rs tests
    @Test func columnsSetTheNumberAndSpacingAndALeftOutKeyKeepsItsValue() {
        let s = shape()
        let n = s.st.history.undo.count
        s.run("format.columns", #"{"count": 4, "spacing": 36.0}"#)
        #expect(body(s).columns == 4 && body(s).colSpacing == 36.0)
        #expect(s.st.history.undo.count == n + 1, "one undo step")
        s.run("format.columns", #"{"count": 2}"#)
        #expect(body(s).columns == 2 && body(s).colSpacing == 36.0, "the spacing stays")
        s.run("format.columns", #"{"spacing": 9.0}"#)
        #expect(body(s).columns == 2 && body(s).colSpacing == 9.0, "the number stays")
    }

    // cmd/format.rs tests
    @Test func columnsWithNoFieldsOpenTheDialogWithTheShapesValues() throws {
        let s = shape()
        s.run("format.columns", #"{"count": 3, "spacing": 27.0}"#)
        let rev = s.st.revision
        let n = s.st.history.undo.count
        s.uiRequests.removeAll()
        s.run("format.columns")
        #expect(s.st.revision == rev)
        #expect(s.st.history.undo.count == n)
        let (id, params) = try #require(lastDialog(s))
        #expect(id == "columns")
        #expect(params.get("count") == 3)
        #expect(params.get("spacing")?.asF64 == 27.0)
    }

    // cmd/format.rs tests
    @Test func columnsRejectABadNumberOrSpacingWithoutEditing() {
        let s = shape()
        let n = s.st.history.undo.count
        for p in [#"{"count": 0}"#, #"{"count": 17}"#, #"{"count": 2.5}"#, #"{"count": "two"}"#, #"{"spacing": "wide"}"#] {
            do {
                _ = try s.execute("format.columns", j(p))
                Issue.record("\(p) is refused")
            } catch {
                #expect(String(describing: error).contains("format.columns"), "\(p): \(error)")
            }
        }
        #expect(s.st.history.undo.count == n)
        #expect(body(s).columns == nil)
    }

    // cmd/format.rs tests
    @Test func tabsDialogSetsStopsInOneUndoAndOpensWithNoFields() throws {
        let s = shape()
        let before = s.st.history.undo.count
        s.run("format.tabs", #"{"set": [{"pos": 144.0, "align": "center"}, {"pos": 72.0, "align": "dec"}, {"pos": 72.02, "align": "right"}], "defaultTab": 36.0}"#)
        #expect(s.st.history.undo.count == before + 1)
        #expect(s.st.history.undo.last?.label == "Tabs…")
        let p = para(s)
        let tabs = try #require(p.tabs)
        #expect(tabs.count == 2, "stops within 0.05 pt collapse")
        #expect(tabs.first?.pos == 72.02)
        #expect(tabs.first?.align == "r")
        #expect(tabs.at(1)?.align == "ctr")
        #expect(p.defaultTab == 36.0)
        s.run("edit.undo")
        #expect(para(s).tabs == nil && para(s).defaultTab == nil)
        let n = s.st.history.undo.count
        s.uiRequests.removeAll()
        s.run("format.tabs")
        #expect(s.st.history.undo.count == n)
        let (id, params) = try #require(lastDialog(s))
        #expect(id == "tabs")
        #expect(params.get("tabs")?.asArray?.isEmpty == true)
        #expect(s.fails("format.tabs", #"{"set": [{"pos": 10.0, "align": "sparkle"}]}"#))
        #expect(s.fails("format.tabs", #"{"set": "nope"}"#))
        #expect(s.st.history.undo.count == n)
    }
}

// MARK: - cmd/ruler_tests.rs

@Suite("Format: ruler and tabs", .enabled(if: ported("insert.textBox")))
struct FormatRulerTests {
    private func editing() -> (Session, UInt64) {
        let s = session()
        s.run("slide.new", #"{"layout": "blank"}"#)
        let id = idOf(s.run("insert.textBox", #"{"rect": [100, 50, 400, 40]}"#))
        s.run("text.edit", "{\"id\": \(id)}")
        s.run("text.insert", #"{"text": "a\tb"}"#)
        return (s, id)
    }

    // cmd/ruler_tests.rs
    @Test func rulerReportsTheTextAreaAndIndents() {
        let (s, _) = editing()
        var r = s.run("format.ruler")
        #expect(abs((r.get("x")?.asF64 ?? 0) - 107.2) < 0.01, "\(r.display)")
        #expect(r.get("rotated") == false)
        #expect(r.get("tabs")?.asArray?.count == 0)
        s.run("format.paragraph", #"{"indentLeft": 36, "indentFirst": -18}"#)
        r = s.run("format.ruler")
        #expect(r.get("marginLeft")?.asF64 == 36.0 && r.get("indent")?.asF64 == -18.0)
        s.run("text.exit")
        #expect(s.fails("format.ruler"), "only while editing text")
    }

    // cmd/ruler_tests.rs
    @Test func tabsAddMoveRemoveClearAndUndo() {
        let (s, _) = editing()
        func tabs() -> [(Double, String)] {
            (s.run("format.ruler").get("tabs")?.asArray ?? []).map { ($0.get("pos")?.asF64 ?? -1, $0.get("align")?.asStr ?? "") }
        }
        func eq(_ a: [(Double, String)], _ b: [(Double, String)]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { $0 == $1 } }
        s.run("format.tabs", #"{"add": {"pos": 144, "align": "center"}}"#)
        s.run("format.tabs", #"{"add": {"pos": 72}}"#)
        #expect(eq(tabs(), [(72.0, "l"), (144.0, "ctr")]), "sorted")
        s.run("format.tabs", #"{"add": {"pos": 72.2, "align": "r"}}"#)
        #expect(eq(tabs(), [(72.2, "r"), (144.0, "ctr")]), "a stop at the same place is replaced")
        s.run("format.tabs", #"{"move": {"from": 144, "to": 200}}"#)
        s.run("format.tabs", #"{"remove": 72.2}"#)
        #expect(eq(tabs(), [(200.0, "ctr")]))
        s.run("edit.undo")
        #expect(tabs().count == 2)
        s.run("format.tabs", #"{"clear": true}"#)
        #expect(tabs().isEmpty)
        s.uiRequests.removeAll()
        s.run("format.tabs")
        #expect(lastDialog(s)?.0 == "tabs", "no fields opens the Tabs dialog")
        #expect(!s.fails("format.tabs", #"{"add": {"pos": 1.7976931348623157e308}}"#), "clamped, not a crash")
        for i in 0 ..< 100 { s.run("format.tabs", "{\"add\": {\"pos\": \(Double(i) * 3.0)}}") }
        #expect(tabs().count <= 32)
        s.run("format.tabs", #"{"set": [{"pos": 90, "align": "dec"}, {"pos": 30, "align": "right"}, {"pos": "x"}], "defaultTab": 36}"#)
        #expect(eq(tabs(), [(30.0, "r"), (90.0, "dec")]), "set replaces all, sorted, bad entries dropped")
        #expect(s.run("format.ruler").get("defaultTab")?.asF64 == 36.0)
    }
}

// MARK: - tests.rs

@Suite("Format: text and paragraphs")
struct FormatTextTests {
    // tests.rs text_transform_sets_and_clears_a_warp
    @Test(.enabled(if: ported("shape.insert", "shape.inspect"))) func textTransformSetsAndClearsAWarp() {
        let s = session()
        let id = idOf(s.run("shape.insert", #"{"preset": "rect", "rect": [80.0, 80.0, 420.0, 160.0], "text": "ARCH"}"#))
        func body() -> JSON { s.run("shape.inspect", "{\"id\": \(id)}").get("shape")?.get("text")?.get("body") ?? .null }
        #expect(s.fails("format.textWarp"))
        #expect(s.fails("format.textWarp", #"{"preset": "notAWarp"}"#))
        #expect(s.fails("format.textWarp", #"{"preset": "textArchUp", "adj": "wide"}"#))
        #expect(s.fails("format.textWarp", #"{"preset": "textArchUp", "adj": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0]}"#))
        #expect(s.fails("format.textWarp", #"{"preset": "textArchUp", "adj": [null]}"#))
        #expect(body().get("warp") == nil || body().get("warp") == .null)
        s.run("format.textWarp", #"{"preset": "textArchUp"}"#)
        #expect(body().get("warp") == "textArchUp")
        #expect(body().get("warpAdj") == nil)
        s.run("format.textWarp", #"{"preset": "textInflate", "adj": [20000.0]}"#)
        let b = body()
        #expect(b.get("warp") == "textInflate")
        #expect(b.get("warpAdj")?.valueEquals([20000.0]) == true)
        s.run("format.textWarp", #"{"preset": "none"}"#)
        #expect(body().get("warp") == nil || body().get("warp") == .null)
        s.run("edit.undo")
        #expect(body().get("warp") == "textInflate")
        s.run("text.edit", "{\"id\": \(id)}")
        s.run("format.textWarp", #"{"preset": "textCircle"}"#)
        #expect(body().get("warp") == "textCircle")
    }

    // tests.rs insert_shape_and_format
    @Test(.enabled(if: ported("shape.insert", "shape.fill", "shape.line", "shape.rotate", "shape.move", "shape.inspect")))
    func insertShapeAndFormat() {
        let s = session()
        let id = idOf(s.run("shape.insert", #"{"preset": "roundRect", "rect": [100, 100, 200, 100], "text": "Hi"}"#))
        s.run("shape.fill", ##"{"color": "#ff0000"}"##)
        s.run("shape.line", #"{"width": 3, "color": "accent2", "dash": "dash"}"#)
        s.run("shape.rotate", #"{"deg": 30}"#)
        s.run("shape.move", #"{"dx": 10, "dy": -5}"#)
        s.run("format.bold")
        var v = s.run("shape.inspect", "{\"id\": \(id)}")
        #expect(v.get("box")?.get("x")?.asF64 == 110.0)
        #expect(v.get("box")?.get("rot")?.asF64 == 30.0)
        #expect(v.get("shape")?.get("text")?.get("paragraphs")?.at(0)?.get("runs")?.at(0)?.get("props")?.get("bold") == true)
        // Undo restores step by step.
        for _ in 0 ..< 5 { s.run("edit.undo") }
        v = s.run("shape.inspect", "{\"id\": \(id)}")
        #expect(v.get("shape")?.get("fill") == nil || v.get("shape")?.get("fill") == .null)
    }

    // tests.rs text_transparency_keeps_the_colour_and_sets_alpha
    @Test(.enabled(if: ported("shape.insert"))) func textTransparencyKeepsTheColourAndSetsAlpha() throws {
        let s = session()
        let id = ShapeId(UInt32(idOf(s.run("shape.insert", #"{"preset": "rect", "rect": [100, 100, 200, 100], "text": "Hi"}"#))))
        func color() -> ColorRef? {
            if case .solid(let c)? = s.st.shape(id)?.text?.paragraphs.first?.runs.first?.props.fill { return c }
            return nil
        }
        // Inherited colour: the run gets the colour it showed, now 25% transparent.
        s.run("format.textTransparency", #"{"value": 0.25}"#)
        var c = try #require(color())
        #expect(abs(c.alpha - 0.75) < 1e-9, "\(c)")
        // Its own colour stays; the alpha is replaced, not stacked.
        s.run("format.color", ##"{"color": "#C00000"}"##)
        s.run("format.textTransparency", #"{"value": 0.6}"#)
        s.run("format.textTransparency", #"{"value": 0.5}"#)
        c = try #require(color())
        #expect(c.base == .rgb(rgb: Rgba.rgb(0xC0, 0, 0)))
        #expect(c.mods.filter { if case .alpha = $0 { return true }; return false }.count == 1)
        #expect(abs(c.alpha - 0.5) < 1e-9)
        s.run("format.textTransparency", #"{"value": 0}"#)
        c = try #require(color())
        #expect(c.mods.isEmpty, "opaque drops the alpha: \(c)")
        s.run("edit.undo")
        c = try #require(color())
        #expect(abs(c.alpha - 0.5) < 1e-9)
        #expect(s.fails("format.textTransparency"))
    }

    // tests.rs numbering_takes_color_and_size
    @Test(.enabled(if: ported("insert.textBox"))) func numberingTakesColorAndSize() {
        let s = session()
        s.run("insert.textBox", #"{"rect": [10, 10, 300, 100], "text": "One\nTwo"}"#)
        s.run("format.numbering", #"{"on": true, "scheme": "romanUcPeriod", "start": 3, "color": "accent2", "size": 150}"#)
        func pp() -> ParaProps {
            let st = s.st
            return st.selection.shapes.first.flatMap { st.shape($0)?.text?.paragraphs.first?.props } ?? ParaProps()
        }
        let p = pp()
        #expect(p.bullet == .autoNum(scheme: "romanUcPeriod", startAt: 3))
        #expect(p.bulletSize == 1.5)
        #expect(p.bulletColor == ColorRef.scheme(.accent2))
        s.run("format.bullets", #"{"on": true, "char": "★", "size": 9000}"#)
        #expect(pp().bulletSize == 4.0)
    }

    // tests.rs format_language_marks_the_selected_text
    @Test func formatLanguageMarksTheSelectedText() throws {
        let s = session()
        let title = s.st.currentSlide?.shapes.first?.id.rawValue ?? 0
        s.run("text.edit", "{\"id\": \(title)}")
        s.run("text.insert", #"{"text": "Hola mundo"}"#)
        s.run("text.move", #"{"to": "wordLeft", "extend": true}"#)
        s.run("format.language", #"{"lang": "es-ES"}"#)
        #expect(s.run("format.state").get("lang") == "es-ES")
        let runs = try #require(s.st.currentSlide?.shapes.first?.text?.paragraphs.first?.runs)
        let langs = runs.map { ($0.text, $0.props.lang) }
        #expect(langs.count == 2)
        #expect(langs.first?.0 == "Hola " && langs.first?.1 == nil)
        #expect(langs.last?.0 == "mundo" && langs.last?.1 == "es-ES")
    }

    // tests.rs change_case_spans_formatting_runs
    @Test(.enabled(if: ported("shape.insert"))) func changeCaseSpansFormattingRuns() throws {
        func setup(_ text: String, _ boldTo: Int) -> (Session, ShapeId) {
            let s = session()
            let r = s.run("shape.insert", JSON.object(JSONObject(["preset": "rect", "rect": [80.0, 80.0, 420.0, 160.0], "text": .string(text)])).display)
            let id = ShapeId(UInt32(idOf(r)))
            s.run("text.edit", "{\"id\": \(id.rawValue)}")
            s.run("text.select", "{\"anchor\": [0, 0], \"caret\": [0, \(boldTo)]}")
            s.run("format.bold", #"{"on": true}"#)
            return (s, id)
        }
        func textOf(_ s: Session, _ id: ShapeId) -> TextBody { s.st.shape(id)?.text ?? TextBody() }
        for (mode, input, want) in [("title", "hello world", "Hello World"), ("sentence", "hello world. bye", "Hello world. Bye")] {
            // Text range.
            var (s, id) = setup(input, 3)
            s.run("text.select", "{\"anchor\": [0, 0], \"caret\": [0, \(input.unicodeScalars.count)]}")
            s.run("format.case", "{\"mode\": \"\(mode)\"}")
            #expect(textOf(s, id).text == want, "\(mode) range")
            // Whole shape.
            (s, id) = setup(input, 3)
            s.run("text.exit")
            s.run("format.case", "{\"mode\": \"\(mode)\"}")
            #expect(textOf(s, id).text == want, "\(mode) shape")
            #expect(textOf(s, id).paragraphs.first?.runs.first?.props.bold == true)
        }
        // A length-changing mapping keeps each piece in its own run.
        let (s, id) = setup("straße", 4)
        s.run("text.select", #"{"anchor": [0, 0], "caret": [0, 6]}"#)
        s.run("format.case", #"{"mode": "upper"}"#)
        let b = textOf(s, id)
        #expect(b.text == "STRASSE")
        #expect(b.paragraphs.first?.runs.first?.text == "STRA")
        #expect(b.paragraphs.first?.runs.first?.props.bold == true)
    }

    // tests.rs format_color_on_a_selected_chart_sets_its_text_color
    @Test(.enabled(if: ported("insert.chart"))) func formatColorOnASelectedChartSetsItsTextColor() throws {
        let s = session()
        let id = idOf(s.run("insert.chart", #"{"type": "column", "title": "Sales"}"#))
        s.run("edit.select", "{\"ids\": [\(id)]}")
        s.run("format.color", #"{"color": "accent2"}"#)
        guard case .chart(let c)? = s.st.shape(ShapeId(UInt32(id)))?.kind else {
            Issue.record("not a chart")
            return
        }
        #expect(c.textColor == ColorRef.scheme(.accent2))
    }
}
