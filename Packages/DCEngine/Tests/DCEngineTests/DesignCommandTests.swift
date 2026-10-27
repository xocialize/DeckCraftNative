// DCEngineTests — the Design tab and the master views: themes, colours, fonts, effects, backgrounds, slide
// size, header & footer, Browse for Themes, Slide/Handout/Notes Master.
// Ports the tests of deckcraft crates/engine/src/cmd/design.rs and the design tests of tests.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
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

private func scheme(_ s: Session) -> ColorScheme { s.st.doc.masters[0].theme.colors }
private func fontScheme(_ s: Session) -> FontScheme { s.st.doc.masters[0].theme.fonts }
private func undoLen(_ s: Session) -> Int { s.st.history.undo.count }
private func lastLabel(_ s: Session) -> String? { s.st.history.undo.last?.label }

/// `s.execute(id, params).unwrap_err().to_string()`, or "" when the command succeeds.
private func errText(_ s: Session, _ id: String, _ params: String = "{}") -> String {
    do {
        _ = try s.execute(id, j(params))
        return ""
    } catch {
        return "\(error)"
    }
}

/// A 2×2 PNG, base64 (design.rs `png`).
private func png() -> String {
    var px = [UInt8](repeating: 0, count: 16)
    px[0 ..< 4] = [10, 20, 30, 255]
    let bytes = BackgroundCommands.pngBytes(StraightImage(width: 2, height: 2, pixels: px)) ?? []
    return Cmd.base64Encode(bytes)
}

private func picture(_ s: Session) -> PictureFill? {
    if case .fill(.picture(let pf))? = s.st.doc.slides[0].background { return pf }
    Issue.record("expected a picture background, got \(String(describing: s.st.doc.slides[0].background))")
    return nil
}

@Suite("Design commands", .enabled(if: ported("design.theme", "design.background", "view.slideMaster", "master.preserve")))
struct DesignCommandTests {
    // Rust: cmd/design.rs::layout_commands_reject_invalid_index
    @Test func layoutCommandsRejectInvalidIndex() {
        let s = session()
        s.run("master.insertLayout")
        func count() -> Int { s.st.doc.masters.reduce(0) { $0 + $1.layouts.count } }
        func names() -> [String] { s.st.doc.masters.flatMap { $0.layouts.map(\.name) } }
        let n = count()
        let before = names()
        for bad in ["-1", "1.5"] {
            #expect(s.fails("master.deleteLayout", "{\"layout\": \(bad)}"))
            #expect(s.fails("master.deleteLayout", "{\"master\": \(bad)}"))
            #expect(s.fails("master.renameLayout", "{\"layout\": \(bad), \"name\": \"x\"}"))
            #expect(count() == n)
            #expect(names() == before)
        }
        s.run("master.deleteLayout")
        #expect(count() == n - 1)
    }

    // Rust: cmd/design.rs::civil_dates
    @Test func civilDates() {
        func c(_ z: Int64) -> [Int64] {
            let d = DesignCommands.civil(z)
            return [d.year, Int64(d.month), Int64(d.day)]
        }
        #expect(c(0) == [1970, 1, 1])
        #expect(c(20_734) == [2026, 10, 8])
        // Past `NaiveDate`'s range the 400-year cycles carry the year, exactly, up to the extremes.
        #expect(c(95_026_602) == [262_144, 1, 1])
        #expect(c(-96_465_964) == [-262_145, 3, 1])
        #expect(c(Int64.max) == [25_252_734_927_768_524, 7, 27])
        #expect(c(Int64.min) == [-25_252_734_927_764_585, 6, 7])
    }

    // Rust: cmd/design.rs::colors_dialog_apply_and_reject
    @Test func colorsDialogApplyAndReject() throws {
        let s = session()
        let original = scheme(s)
        let n = undoLen(s)
        s.run("design.colors")
        _ = try s.execute("design.colors", .null)
        #expect(scheme(s) == original)
        #expect(undoLen(s) == n, "opening the dialog does not edit")
        #expect(s.uiRequests.count == 2)
        guard case .dialog(let id, let params)? = s.uiRequests.first else {
            Issue.record("expected a dialog, got \(String(describing: s.uiRequests.first))")
            return
        }
        #expect(id == "themeColors")
        #expect(params["name"] == "DeckCraft")
        let colors = try #require(params["colors"]?.asObject)
        #expect(colors.entries.count == 12)
        #expect(colors["accent1"]?.asStr == "#\(original.get(.accent1).hex)")
        #expect(colors["folHlink"] != nil)

        s.run("design.colors", ##"{"name": "Harbor"}"##)
        let harbor = try #require(builtinColorSchemes().first { $0.name == "Harbor" })
        #expect(scheme(s).name == "Harbor")
        #expect(scheme(s).get(.accent1) == harbor.get(.accent1))
        #expect(undoLen(s) == n + 1)
        #expect(lastLabel(s) == "Colors")
        s.run("design.colors", ##"{"name": "Harbor"}"##)
        #expect(undoLen(s) == n + 1, "the same scheme is not an undo step")

        let err = errText(s, "design.colors", ##"{"name": "Nope"}"##)
        #expect(err.contains("no colour scheme `Nope`"), "\(err)")
        #expect(s.fails("design.colors", ##"{"name": "  "}"##))
        #expect(s.fails("design.colors", ##"{"name": 1}"##))
        #expect(s.fails("design.colors", ##"{"colors": {}}"##))
        #expect(s.fails("design.colors", ##"{"colors": "red"}"##))
        #expect(s.fails("design.colors", ##"{"colors": {"bg1": "#112233"}}"##))
        #expect(s.fails("design.colors", ##"{"colors": {"tx1": "#112233"}}"##))
        #expect(s.fails("design.colors", ##"{"colors": {"phClr": "#112233"}}"##))
        #expect(s.fails("design.colors", ##"{"colors": {"nope": "#112233"}}"##))
        #expect(s.fails("design.colors", ##"{"colors": {"accent1": "zz"}}"##))
        #expect(s.fails("design.colors", ##"{"name": "Harbor", "colors": {}}"##))
        #expect(scheme(s).name == "Harbor")
        #expect(scheme(s).get(.accent1) == harbor.get(.accent1))
        #expect(undoLen(s) == n + 1)

        s.run("design.colors", ##"{"colors": {"accent1": "112233"}}"##)
        #expect(scheme(s).name == "Custom")
        #expect(scheme(s).get(.accent1).hex == "112233")
        #expect(scheme(s).get(.accent2) == harbor.get(.accent2))
        #expect(undoLen(s) == n + 2)

        let meadow = try #require(builtinColorSchemes().first { $0.name == "Meadow" })
        s.run("design.colors", ##"{"name": "Meadow", "colors": {"lt1": "#010203"}}"##)
        #expect(scheme(s).name == "Meadow")
        #expect(scheme(s).get(.lt1).hex == "010203")
        #expect(scheme(s).get(.accent1) == meadow.get(.accent1))
        #expect(undoLen(s) == n + 3)

        s.run("design.colors", ##"{"name": "Talk", "colors": {"dk1": "#ABCDEF"}}"##)
        #expect(scheme(s).name == "Talk")
        #expect(scheme(s).get(.dk1).hex == "ABCDEF")
        #expect(scheme(s).get(.lt1).hex == "010203")
        #expect(scheme(s).get(.accent1) == meadow.get(.accent1))

        s.run("edit.undo")
        #expect(scheme(s).name == "Meadow")
        #expect(scheme(s).get(.dk1) == meadow.get(.dk1))
    }

    // Rust: cmd/design.rs::fonts_dialog_apply_and_reject
    @Test func fontsDialogApplyAndReject() throws {
        let s = session()
        let original = fontScheme(s)
        var n = undoLen(s)
        s.run("design.fonts")
        _ = try s.execute("design.fonts", .null)
        _ = try s.execute("design.fonts", [1, 2])
        #expect(fontScheme(s) == original)
        #expect(undoLen(s) == n, "opening the dialog does not edit")
        #expect(s.uiRequests.count == 3)
        guard case .dialog(let id, let params)? = s.uiRequests.first else {
            Issue.record("expected a dialog")
            return
        }
        #expect(id == "themeFonts")
        #expect(params["name"]?.asStr == original.name)
        #expect(params["major"]?.asStr == original.major.latin)
        #expect(params["minor"]?.asStr == original.minor.latin)

        s.run("design.fonts", ##"{"name": "classic"}"##)
        let classic = try #require(builtinFontSchemes().first { $0.name == "Classic" })
        #expect(fontScheme(s) == classic, "a builtin name keeps that scheme, including its own name")
        #expect(undoLen(s) == n + 1)
        #expect(lastLabel(s) == "Fonts")
        s.run("design.fonts", ##"{"name": "Classic"}"##)
        #expect(undoLen(s) == n + 1, "the same scheme is not an undo step")

        let err = errText(s, "design.fonts", ##"{"name": "Nope"}"##)
        #expect(err.contains("no font scheme `Nope`"), "\(err)")
        #expect(s.fails("design.fonts", ##"{"name": "  "}"##))
        #expect(s.fails("design.fonts", ##"{"name": 1}"##))
        #expect(s.fails("design.fonts", ##"{"major": ""}"##))
        #expect(s.fails("design.fonts", ##"{"major": "  "}"##))
        #expect(s.fails("design.fonts", ##"{"minor": 1}"##))
        #expect(s.fails("design.fonts", ##"{"name": "Classic", "major": ""}"##))
        #expect(fontScheme(s) == classic)
        #expect(undoLen(s) == n + 1)

        try s.edit { doc, _ in
            doc.masters[0].theme.fonts.major.ea = "EA Major"
            doc.masters[0].theme.fonts.minor.cs = "CS Minor"
            doc.masters[0].theme.fonts.major.scripts.append(ScriptFont(script: "Arab", typeface: "Noto Naskh Arabic"))
        }
        let marked = fontScheme(s)
        n = undoLen(s)

        s.run("design.fonts", ##"{"major": " Lato "}"##)
        let custom = fontScheme(s)
        #expect(custom.name == "Custom")
        #expect(custom.major.latin == "Lato")
        #expect(custom.minor.latin == "Lato", "an omitted minor copies major")
        #expect(custom.major.ea == "EA Major")
        #expect(custom.minor.cs == "CS Minor")
        #expect(custom.major.scripts == marked.major.scripts)
        #expect(undoLen(s) == n + 1)

        s.run("design.fonts", ##"{"minor": "Roboto"}"##)
        #expect(fontScheme(s).name == "Custom")
        #expect(fontScheme(s).major.latin == "Lato")
        #expect(fontScheme(s).minor.latin == "Roboto")
        #expect(fontScheme(s).major.ea == "EA Major")
        #expect(undoLen(s) == n + 2)

        s.run("design.fonts", ##"{"name": "Classic", "major": "Inter"}"##)
        #expect(fontScheme(s).name == "Classic")
        #expect(fontScheme(s).major.latin == "Inter")
        #expect(fontScheme(s).minor.latin == "Open Sans")
        #expect(fontScheme(s).major.ea == "")
        #expect(fontScheme(s).major.scripts.isEmpty, "a builtin is applied before the latin overlay")
        #expect(undoLen(s) == n + 3)

        try s.edit { doc, _ in doc.masters[0].theme.fonts.major.ea = "Kept" }
        s.run("design.fonts", ##"{"name": "Talk", "minor": "Nunito Sans"}"##)
        #expect(fontScheme(s).name == "Talk")
        #expect(fontScheme(s).major.latin == "Inter")
        #expect(fontScheme(s).minor.latin == "Nunito Sans")
        #expect(fontScheme(s).major.ea == "Kept")
        #expect(lastLabel(s) == "Fonts")

        s.run("edit.undo")
        #expect(fontScheme(s).name == "Classic")
        #expect(fontScheme(s).major.ea == "Kept")
        #expect(fontScheme(s).minor.latin == "Open Sans")
    }

    // Rust: cmd/design.rs::background_picture_options_tile_transparency_and_copy
    @Test func backgroundPictureOptionsTileTransparencyAndCopy() throws {
        let s = session()
        var n = undoLen(s)
        let err = errText(s, "design.background", ##"{"pictureProps": {"tile": true}}"##)
        #expect(err.contains("picture background"), "\(err)")
        #expect(s.fails("design.background", ##"{"transparency": 0.2}"##))
        #expect(undoLen(s) == n)

        s.run("design.background", ##"{"color": "accent1", "transparency": 0.25}"##)
        if case .fill(.solid(let color))? = s.st.doc.slides[0].background {
            #expect(abs(color.alpha - 0.75) < 1e-4, "\(color.alpha)")
        } else {
            Issue.record("expected a solid background")
        }
        n = undoLen(s)
        s.run("design.background", ##"{"transparency": 0.25}"##)
        #expect(undoLen(s) == n, "the same transparency is not an undo step")

        s.run("design.background", "{\"picture\": \"\(png())\", \"name\": \"dot.png\", \"transparency\": 0.4, \"pictureProps\": {\"tile\": true}}")
        let pf = try #require(picture(s))
        #expect(abs((pf.alpha ?? 1.0) - 0.6) < 1e-6)
        if case .tile = pf.mode {} else { Issue.record("expected a tile") }
        n = undoLen(s)

        s.run("design.background", ##"{"pictureProps": {"offsetX": 12.0, "offsetY": -3.0, "scaleX": 0.5, "scaleY": 50.0, "align": "ctr", "mirror": "xy", "rotateWithShape": false}}"##)
        if case .tile(let tx, let ty, let sx, let sy, let flip, let align)? = picture(s)?.mode {
            #expect([tx, ty, sx, sy] == [12.0, -3.0, 0.5, 10.0])
            #expect(flip == "xy")
            #expect(align == "ctr")
        } else {
            Issue.record("expected a tile")
        }
        #expect(picture(s)?.upright == true)
        s.run("design.background", ##"{"pictureProps": {"align": "bogus", "offsetX": "nope"}}"##)
        if case .tile(let tx, _, _, _, _, let align)? = picture(s)?.mode {
            #expect(tx == 12.0)
            #expect(align == "ctr")
        } else {
            Issue.record("expected the tile to stay")
        }
        #expect(undoLen(s) == n + 1, "ignored options are not an undo step")

        s.run("design.background", ##"{"pictureProps": {"tile": false, "stretch": [0.1, 0.2, 0.0, 0.0]}}"##)
        if case .stretch(let fillRect)? = picture(s)?.mode {
            #expect(fillRect == [0.1, 0.2, 0.0, 0.0])
        } else {
            Issue.record("expected a stretch")
        }

        s.run("slide.new")
        #expect(s.st.doc.slides[1].background == nil)
        s.run("slide.go", ##"{"index": 0}"##)
        n = undoLen(s)
        s.run("design.background", ##"{"copy": true}"##)
        #expect(s.st.doc.slides[1].background == s.st.doc.slides[0].background)
        #expect(undoLen(s) == n + 1)
        #expect(lastLabel(s) == "Format Background")
        s.run("design.background", ##"{"copy": true}"##)
        #expect(undoLen(s) == n + 1, "copying an already shared background is not an undo step")
    }

    // Rust: cmd/design.rs::background_all_applies_to_master_and_new_slides_inherit
    @Test func backgroundAllAppliesToMasterAndNewSlidesInherit() {
        let s = session()
        s.run("file.new", ##"{"theme": "Nocturne"}"##)
        #expect(s.run("slide.inspect", ##"{"index": 0}"##)["background"] == "#121826")
        let n = undoLen(s)
        s.run("design.background", ##"{"color": "#0D0D0D", "all": true}"##)
        #expect(undoLen(s) == n + 1)
        // Idempotency: re-applying the same background to all is a no-op (no extra undo step).
        s.run("design.background", ##"{"color": "#0D0D0D", "all": true}"##)
        #expect(undoLen(s) == n + 1, "re-applying already applied background is not an undo step")
        // Slide 0 has new background, master has new background, layouts cleared.
        let doc = s.st.doc
        if case .fill? = doc.slides[0].background {} else { Issue.record("expected a fill") }
        #expect(doc.masters[0].background == doc.slides[0].background)
        #expect(doc.masters[0].layouts.allSatisfy { $0.background == nil })
        // Newly added slides inherit the master background (fixes #891).
        s.run("slide.new", ##"{"layout": "titleAndContent", "title": "new"}"##)
        #expect(s.run("slide.inspect", ##"{"index": 0}"##)["background"] == "#0D0D0D")
        #expect(s.run("slide.inspect", ##"{"index": 1}"##)["background"] == "#0D0D0D")
        // Undo restores previous slide and master backgrounds.
        s.run("edit.undo")
        #expect(s.st.doc.slides.count == 1)
        s.run("edit.undo")
        #expect(s.run("slide.inspect", ##"{"index": 0}"##)["background"] == "#121826")
    }

    // Rust: cmd/design.rs::background_copy_from_slide_following_master_preserves_master_and_layout_backgrounds
    @Test func backgroundCopyFromSlideFollowingMasterPreservesMasterAndLayoutBackgrounds() throws {
        let s = session()
        s.run("file.new", ##"{"theme": "Nocturne"}"##)
        s.run("slide.new", ##"{"layout": "titleAndContent"}"##)
        let customLayoutBg = Background.fill(fill: .solid(.rgb(.rgb(0x22, 0x22, 0x22))))
        try s.edit { doc, _ in doc.masters[0].layouts[0].background = customLayoutBg }
        // Slide 0 follows master (background: nil).
        #expect(s.st.doc.slides[0].background == nil)
        // Give Slide 1 an explicit override.
        s.run("design.background", ##"{"color": "#FF0000", "index": 1}"##)
        #expect(s.st.doc.slides[1].background != nil)
        let origMasterBg = s.st.doc.masters[0].background
        #expect(origMasterBg != nil)
        // Select slide 0 (which follows master) and apply copy to all.
        s.run("slide.go", ##"{"index": 0}"##)
        let n = undoLen(s)
        s.run("design.background", ##"{"copy": true}"##)
        #expect(undoLen(s) == n + 1)
        // Slide 1 has been reset to nil (follows master), slide 0 remains nil.
        let doc = s.st.doc
        #expect(doc.slides[0].background == nil)
        #expect(doc.slides[1].background == nil)
        // Master and layout backgrounds survived.
        #expect(doc.masters[0].background == origMasterBg)
        #expect(doc.masters[0].layouts[0].background == customLayoutBg)
        // Idempotency: re-applying copy is a no-op.
        s.run("design.background", ##"{"copy": true}"##)
        #expect(undoLen(s) == n + 1, "re-copying when already matching is a no-op")
    }

    // Rust: cmd/design.rs::background_reset_all_preserves_master_and_layout_backgrounds
    @Test func backgroundResetAllPreservesMasterAndLayoutBackgrounds() throws {
        let s = session()
        s.run("file.new", ##"{"theme": "Nocturne"}"##)
        s.run("slide.new", ##"{"layout": "titleAndContent"}"##)
        let customLayoutBg = Background.fill(fill: .solid(.rgb(.rgb(0x33, 0x33, 0x33))))
        try s.edit { doc, _ in doc.masters[0].layouts[0].background = customLayoutBg }
        let origMasterBg = s.st.doc.masters[0].background
        #expect(origMasterBg != nil)
        // Set explicit backgrounds on both slides individually (master remains untouched).
        s.run("design.background", ##"{"color": "#0D0D0D", "index": 0}"##)
        s.run("design.background", ##"{"color": "#0D0D0D", "index": 1}"##)
        #expect(s.st.doc.slides[0].background != nil)
        #expect(s.st.doc.slides[1].background != nil)
        // Now perform reset with all.
        let n = undoLen(s)
        s.run("design.background", ##"{"reset": true, "all": true}"##)
        #expect(undoLen(s) == n + 1)
        let doc = s.st.doc
        #expect(doc.slides[0].background == nil)
        #expect(doc.slides[1].background == nil)
        #expect(doc.masters[0].background == origMasterBg)
        #expect(doc.masters[0].layouts[0].background == customLayoutBg)
        // Idempotency: re-running reset all is a no-op.
        s.run("design.background", ##"{"reset": true, "all": true}"##)
        #expect(undoLen(s) == n + 1, "re-resetting when already reset is a no-op")
    }

    // Rust: cmd/design.rs::background_all_only_touches_used_masters
    @Test func backgroundAllOnlyTouchesUsedMasters() throws {
        let s = session()
        s.run("file.new", ##"{"theme": "Nocturne"}"##)
        let secondMasterBg = Background.fill(fill: .solid(.rgb(.rgb(0x55, 0x55, 0x55))))
        try s.edit { doc, _ in
            var m2 = doc.masters[0]
            m2.id = MasterId(999)
            m2.background = secondMasterBg
            doc.masters.append(m2)
        }
        #expect(s.st.doc.masters.count == 2)
        // Slides only use master 0 (default layout).
        s.run("design.background", ##"{"color": "#AA0000", "all": true}"##)
        let doc = s.st.doc
        #expect(doc.masters[0].background == doc.slides[0].background)
        #expect(doc.masters[1].background == secondMasterBg)
    }

    // Rust: cmd/design.rs::background_all_clears_layout_overrides_even_if_slides_and_master_match
    @Test func backgroundAllClearsLayoutOverridesEvenIfSlidesAndMasterMatch() throws {
        let s = session()
        s.run("file.new", ##"{"theme": "Nocturne"}"##)
        s.run("design.background", ##"{"color": "#AA0000", "all": true}"##)
        #expect(s.st.doc.masters[0].background == s.st.doc.slides[0].background)
        let customBg = Background.fill(fill: .solid(.rgb(.rgb(0x12, 0x34, 0x56))))
        try s.edit { doc, _ in doc.masters[0].layouts[0].background = customBg }
        // Re-run Apply to All with #AA0000. Must not be skipped as no-op; must clear layout override.
        let n = undoLen(s)
        s.run("design.background", ##"{"color": "#AA0000", "all": true}"##)
        #expect(undoLen(s) == n + 1, "should execute and clear layout override, not treat as no-op")
        #expect(s.st.doc.masters[0].layouts[0].background == nil)
        s.run("design.background", ##"{"color": "#AA0000", "all": true}"##)
        #expect(undoLen(s) == n + 1, "now it is truly a no-op")
    }

    // MARK: browse_theme_tests

    // Rust: cmd/design.rs::browse_theme_tests::applies_the_theme_of_another_deck_and_undoes
    @Test func appliesTheThemeOfAnotherDeckAndUndoes() throws {
        let other = session()
        other.run("design.fonts", ##"{"major": "Lato", "minor": "Source Sans 3"}"##)
        other.run("design.colors", ##"{"colors": {"accent1": "#123456"}}"##)
        let data = try #require(other.run("file.saveBytes", ##"{"format": "pptx"}"##)["data"]?.asStr)
        let s = session()
        s.run("slide.new", ##"{"layout": "titleAndContent", "title": "T", "body": "B"}"##)
        let before = s.st.doc.masters[0].theme
        _ = try s.execute("design.browseTheme", ["name": "Brand.pptx", "data": .string(data)])
        let t = s.st.doc.masters[0].theme
        #expect(t.fonts.major.latin == "Lato")
        #expect(t.fonts.minor.latin == "Source Sans 3")
        #expect(t.colors.get(.accent1).hex.lowercased() == "123456")
        #expect(s.st.doc.validate().isEmpty)
        s.run("edit.undo")
        #expect(s.st.doc.masters[0].theme == before)
        #expect(s.fails("design.browseTheme", ##"{"data": "AAAA"}"##))
        #expect(s.fails("design.browseTheme", "{}"))
    }

    /// A 4:3 brand template: a logo and a background on the master, its layouts renamed (so slides can only
    /// find them by kind) and its content layout's title moved.
    private func brandTemplate() throws -> (String, [UInt8], Xfrm) {
        let logo = try #require(BackgroundCommands.pngBytes(StraightImage(width: 2, height: 2, pixels: [200, 20, 30, 255] + [UInt8](repeating: 0, count: 12))))
        let t = session()
        t.run("design.slideSize", ##"{"preset": "standard", "scale": "none"}"##)
        let title: Xfrm = try t.edit { doc, _ in
            guard let media = doc.addMedia("logo.png", "image/png", logo), let raw = doc.allocId() else { throw EngineError.other("ids") }
            var logoShape = Shape.default
            logoShape.id = ShapeId(raw)
            logoShape.name = "Logo"
            logoShape.kind = .picture(fill: PictureFill(media: media))
            logoShape.xfrm = Xfrm(x: 600.0, y: 20.0, w: 100.0, h: 40.0)
            doc.masters[0].shapes.append(logoShape)
            doc.masters[0].background = .fill(fill: .solid(.rgb(.rgb(0x0A, 0x2B, 0x4C))))
            for l in doc.masters[0].layouts.indices { doc.masters[0].layouts[l].name = "Brand \(doc.masters[0].layouts[l].name)" }
            let x = Xfrm(x: 72.0, y: 400.0, w: 576.0, h: 80.0)
            guard let li = doc.masters[0].layouts.firstIndex(where: { $0.kind == .titleAndContent }),
                  let ti = doc.masters[0].layouts[li].shapes.firstIndex(where: { $0.phType?.isTitle == true }) else { throw EngineError.other("layout") }
            doc.masters[0].layouts[li].shapes[ti].xfrm = x
            return x
        }
        return (Cmd.base64Encode(try PPTX.exportAs(t.st.doc, "potx")), logo, title)
    }

    // Rust: cmd/design.rs::browse_theme_tests::a_template_brings_its_master_and_layouts_and_slides_follow
    @Test func aTemplateBringsItsMasterAndLayoutsAndSlidesFollow() throws {
        let (data, logo, title) = try brandTemplate()
        let s = session()
        s.run("slide.new", ##"{"layout": "titleAndContent", "title": "Agenda", "body": "Point one"}"##)
        let before = s.st.doc
        let n = undoLen(s)
        let r = try s.execute("design.browseTheme", ["name": "Brand.potx", "data": .string(data)])
        #expect(r["slides"] == 2, "\(r.display)")
        #expect(undoLen(s) == n + 1, "one undo step")

        let doc = s.st.doc
        #expect(doc.validate().isEmpty, "\(doc.validate())")
        #expect(doc.masters.count == 1, "the old master is replaced")
        let m = doc.masters[0]
        #expect(m.id != before.masters[0].id)
        #expect(m.layouts.allSatisfy { $0.name.hasPrefix("Brand ") })
        if case .fill(.solid)? = m.background {} else { Issue.record("expected a solid master background") }
        let pic = try #require(m.shapes.first { $0.name == "Logo" }, "the master's logo comes along")
        guard case .picture(let fill) = pic.kind else {
            Issue.record("logo is a picture")
            return
        }
        #expect(doc.media(fill.media)?.data == logo)
        // The 4:3 master stretches to this deck's 16:9.
        let k = doc.slideSize.width / 720.0
        let px = try #require(pic.xfrm)
        #expect(abs(px.x - 600.0 * k) < 0.01 && abs(px.w - 100.0 * k) < 0.01 && abs(px.y - 20.0) < 0.01, "\(px)")

        // Each slide moved to the brand layout of its kind, and kept its text.
        for (old, new) in zip(before.slides, doc.slides) {
            let was = try #require(before.layout(old.layout)).layout
            let (owner, now) = try #require(doc.layout(new.layout), "on a layout of the new master")
            #expect(owner.id == m.id)
            #expect(now.kind == was.kind)
        }
        let agenda = try #require(doc.slides.first { $0.shapes.contains { $0.text?.text == "Agenda" } })
        #expect(agenda.shapes.contains { $0.text?.text == "Point one" })
        let lay = try #require(doc.layout(agenda.layout)).layout
        let lt = try #require(lay.shapes.first { $0.phType?.isTitle == true }?.xfrm)
        #expect(abs(lt.x - title.x * k) < 0.01 && abs(lt.y - title.y) < 0.01, "\(lt)")
        let st = try #require(agenda.shapes.first { $0.phType?.isTitle == true })
        #expect(st.xfrm == nil, "the slide title follows the new layout")

        s.run("edit.undo")
        #expect(s.st.doc.masters == before.masters)
        #expect(s.st.doc.slides == before.slides)
    }

    // Rust: cmd/design.rs::browse_theme_tests::a_preserved_master_stays_beside_the_template
    @Test func aPreservedMasterStaysBesideTheTemplate() throws {
        let (data, _, _) = try brandTemplate()
        let s = session()
        s.run("view.slideMaster", ##"{"master": 0, "layout": 1}"##)
        s.run("master.preserve", ##"{"preserve": true}"##)
        s.run("view.slideMaster", ##"{"master": 0}"##)
        s.run("master.preserve", ##"{"preserve": true}"##)
        let old = s.st.doc.masters[0].id
        s.run("view.slideMaster", ##"{"master": 0, "layout": 1}"##)
        _ = try s.execute("design.browseTheme", ["name": "Brand.pptx", "data": .string(data)])
        let st = s.st
        #expect(st.doc.masters.count == 2)
        #expect(st.doc.masters[1].id == old)
        #expect(st.selection.target == .master(master: 0), "Slide Master view shows the new master")
        let new = st.doc.masters[0]
        #expect(st.doc.slides.allSatisfy { new.layout($0.layout) != nil })
    }

    // Rust: cmd/design.rs::browse_theme_tests::effect_scheme_replaces_format_and_keeps_colours_and_fonts
    @Test func effectSchemeReplacesFormatAndKeepsColoursAndFonts() {
        let s = session()
        let listed = s.run("design.themes")
        let names = listed["effectSchemes"]?.asArray?.compactMap(\.asStr) ?? []
        #expect(names == ["DeckCraft", "Soft", "Crisp", "Lift", "Glow", "Plain"])

        var n = undoLen(s)
        s.run("design.effects", ##"{"name": "DeckCraft"}"##)
        #expect(undoLen(s) == n, "the scheme already on the theme is not an undo step")
        let err = errText(s, "design.effects", ##"{"name": "Office"}"##)
        #expect(err.contains("no effect scheme"), "\(err)")
        #expect(s.fails("design.effects", "{}"))
        #expect(undoLen(s) == n)

        s.run("design.theme", ##"{"name": "Harbor"}"##)
        let before = s.st.doc.masters[0].theme
        s.run("design.effects", ##"{"name": "soft"}"##)
        let theme = s.st.doc.masters[0].theme
        #expect(theme.name == "Harbor")
        #expect(theme.colors == before.colors)
        #expect(theme.fonts == before.fonts)
        #expect(theme.format.name == "Soft")
        #expect(theme.format.effects.first?.outerShadow != nil)
        #expect(lastLabel(s) == "Effects")

        n = undoLen(s)
        s.run("design.effects", ##"{"name": "Soft"}"##)
        #expect(undoLen(s) == n, "the same scheme is not an undo step")

        s.run("design.effects", ##"{"name": "Glow"}"##)
        let glow = s.st.doc.masters[0].theme.format.effects.at(2)?.glow
        #expect(glow.map { abs($0.radius - 12.0) < 1e-6 } ?? false)
        s.run("design.effects", ##"{"name": "Plain"}"##)
        let plain = s.st.doc.masters[0].theme.format
        #expect(plain.effects.allSatisfy { $0.outerShadow == nil && $0.glow == nil })
        #expect(plain.lines.at(2)?.width == 0.75)
    }

    private func hasTitle(_ s: Session) -> Bool { s.st.shapes.contains { $0.phType?.isTitle == true } }
    private func hasFooters(_ s: Session) -> Bool { s.st.shapes.contains { $0.phType?.isFooterKind == true } }

    // Rust: cmd/design.rs::browse_theme_tests::preserve_and_placeholders_edit_the_open_master_or_layout
    @Test func preserveAndPlaceholdersEditTheOpenMasterOrLayout() throws {
        for id in ["master.preserve", "master.placeholders"] {
            #expect(commandSpecs().contains { $0.id == id }, "\(id)")
        }
        let s = session()
        let blank = try #require(s.st.doc.masters[0].layouts.firstIndex { $0.name == "Blank" })

        s.run("view.slideMaster")
        #expect(s.st.selection.target == .layout(master: 0, layout: 0))
        s.run("view.slideMaster", ##"{"master": 0}"##)
        #expect(s.st.selection.target == .master(master: 0))
        #expect(!s.st.doc.masters[0].preserve)

        var n = undoLen(s)
        s.run("master.preserve", ##"{"preserve": false}"##)
        #expect(undoLen(s) == n, "the same value is not an undo step")
        s.run("master.preserve")
        #expect(s.st.doc.masters[0].preserve)
        #expect(lastLabel(s) == "Preserve")
        s.run("edit.undo")
        #expect(!s.st.doc.masters[0].preserve)

        s.run("master.placeholders", ##"{"footers": false}"##)
        #expect(lastLabel(s) == "Layout Placeholders")
        #expect(hasTitle(s))
        #expect(!hasFooters(s))
        s.run("edit.undo")
        #expect(hasFooters(s))

        s.run("view.closeMaster")
        n = undoLen(s)
        var err = errText(s, "master.preserve")
        #expect(err.contains("open Slide Master view"), "\(err)")
        err = errText(s, "master.placeholders", ##"{"title": true}"##)
        #expect(err.contains("open Slide Master view"), "\(err)")
        err = errText(s, "master.placeholders")
        #expect(err.contains("give title or footers"), "\(err)")
        #expect(undoLen(s) == n)

        s.run("view.slideMaster", "{\"master\": 0, \"layout\": \(blank)}")
        #expect(s.st.selection.target == .layout(master: 0, layout: blank))
        #expect(s.st.doc.masters[0].layouts[blank].preserve)
        #expect(!hasTitle(s))
        #expect(hasFooters(s))

        n = undoLen(s)
        s.run("master.placeholders", ##"{"title": false, "footers": true}"##)
        #expect(undoLen(s) == n, "already in that state")

        s.run("master.placeholders", ##"{"title": true, "footers": false}"##)
        #expect(undoLen(s) == n + 1, "both keys are one undo step")
        #expect(lastLabel(s) == "Layout Placeholders")
        #expect(hasTitle(s))
        #expect(!hasFooters(s))
        let title = try #require(s.st.shapes.first { $0.phType?.isTitle == true })
        #expect(title.name == "Title 1")
        #expect(title.ph?.idx == 0)
        #expect(title.text?.paragraphs.allSatisfy { $0.runs.isEmpty } ?? false)
        s.run("edit.undo")
        #expect(!hasTitle(s))
        #expect(hasFooters(s))

        s.run("master.placeholders", ##"{"footers": false}"##)
        s.run("master.placeholders", ##"{"footers": true}"##)
        let restored = s.st.shapes
        #expect(restored.contains { $0.phType == .date })
        #expect(restored.contains { $0.phType == .footer })
        let num = try #require(restored.first { $0.phType == .slideNum })
        let run = try #require(num.text?.paragraphs.first?.runs.first)
        #expect(run.text == "‹#›")
        #expect(run.kind == .field(field: "slidenum"))

        #expect(s.st.doc.masters[0].layouts[blank].preserve)
        s.run("master.preserve", ##"{"preserve": false}"##)
        #expect(!s.st.doc.masters[0].layouts[blank].preserve)
        #expect(lastLabel(s) == "Preserve")
        s.run("edit.undo")
        #expect(s.st.doc.masters[0].layouts[blank].preserve)

        try s.edit { doc, _ in doc.masters[0].shapes.removeAll { $0.phType?.isTitle == true } }
        s.run("master.placeholders", ##"{"title": true}"##)
        let t = try #require(s.st.shapes.first { $0.phType == .title })
        #expect(t.name == "Title")
        let box = try #require(t.xfrm)
        #expect(abs(box.x - 60.0) < 0.01 && abs(box.y - 29.0) < 0.01)
        #expect(abs(box.w - 840.0) < 0.01 && abs(box.h - 104.0) < 0.01)
    }

    // MARK: header_footer_date_tests

    /// The date field of the Date placeholders of every slide: (saved text, field type).
    private func dates(_ s: Session) -> [(String, String?)] {
        s.st.doc.slides.flatMap(\.shapes).filter { $0.phType == .date }.compactMap(\.text).flatMap(\.paragraphs).flatMap(\.runs).map { r in
            if case .field(let f) = r.kind { return (r.text, f) }
            return (r.text, nil)
        }
    }

    private func sample(_ kind: String) -> String {
        DateTime.nowLocal().flatMap { DateFields.fieldText(kind, nil, $0) } ?? "?"
    }

    /// Runs `design.headerFooter` and checks the slide's date run is an automatic `kind` field. The clock is
    /// read before and after the command, so a second ticking over between the command and the read cannot
    /// fail the comparison. Returns the run text.
    @discardableResult
    private func runAutomatic(_ s: Session, _ params: String, _ kind: String) -> String {
        let before = sample(kind)
        s.run("design.headerFooter", params)
        let after = sample(kind)
        let got = dates(s)
        #expect(got.count == 1, "\(got)")
        #expect(got.first?.1 == kind)
        let text = got.first?.0 ?? ""
        #expect(text == before || text == after, "\(got) is neither \(before) nor \(after)")
        return text
    }

    // Rust: cmd/design.rs::header_footer_date_tests::the_automatic_date_takes_the_format_it_is_given
    @Test func theAutomaticDateTakesTheFormatItIsGiven() {
        let s = session()
        // Default: the short date, as before.
        runAutomatic(s, ##"{"date": true, "dateText": "", "all": true}"##, "datetime1")
        // A format: the field type changes and the saved text is that format's.
        runAutomatic(s, ##"{"date": true, "dateFormat": "datetime5", "all": true}"##, "datetime5")
        #expect(s.st.doc.headerFooter.dateFormat == "datetime5")
        // A time format works the same way, and these two differ, so the format is really read.
        let time = runAutomatic(s, ##"{"date": true, "dateFormat": "datetime11", "all": true}"##, "datetime11")
        #expect(time != sample("datetime5"))
        // Asking again changes nothing (and does not rewrite the run).
        let again = runAutomatic(s, ##"{"date": true, "dateFormat": "datetime11", "all": true}"##, "datetime11")
        #expect(again == time)
        // A fixed date still wins: plain text, no field.
        s.run("design.headerFooter", ##"{"date": true, "dateText": "4 July 1776", "all": true}"##)
        let fixed = dates(s)
        #expect(fixed.count == 1 && fixed.first?.0 == "4 July 1776" && fixed.first?.1 == nil, "\(fixed)")
        // Back to automatic: the remembered format comes back, not datetime1.
        runAutomatic(s, ##"{"date": true, "dateText": "", "dateFormat": "datetime11", "all": true}"##, "datetime11")
        // An unknown format is refused rather than ignored, and changes nothing.
        for bad in ["datetime0", "datetime14", "nonsense", ""] {
            #expect(s.fails("design.headerFooter", "{\"date\": true, \"dateFormat\": \"\(bad)\"}"), "\(bad)")
        }
        #expect(s.st.doc.headerFooter.dateFormat == "datetime11")
        let got = dates(s)
        #expect(got.count == 1, "\(got)")
        #expect(got.first?.1 == "datetime11")
    }

    // MARK: tests.rs

    // Rust: tests.rs::themes_and_slide_size
    @Test func themesAndSlideSize() {
        let s = session()
        s.run("design.theme", ##"{"name": "Ember"}"##)
        #expect(s.st.doc.masters[0].theme.name == "Ember")
        s.run("design.slideSize", ##"{"preset": "standard"}"##)
        #expect(s.st.doc.slideSize.width == 720.0)
        s.run("design.slideSize", ##"{"preset": "widescreen", "orientation": "portrait"}"##)
        #expect([s.st.doc.slideSize.width, s.st.doc.slideSize.height] == [540.0, 960.0])
        s.run("design.slideSize", ##"{"w": 540.0, "h": 960.0, "orientation": "landscape"}"##)
        #expect([s.st.doc.slideSize.width, s.st.doc.slideSize.height] == [960.0, 540.0])
        #expect(s.fails("design.slideSize", ##"{"preset": "standard", "orientation": "sideways"}"##))
        s.run("design.headerFooter", ##"{"slideNumber": true, "footer": true, "footerText": "Hello"}"##)
        let v = s.run("slide.inspect")
        #expect(v["shapes"]?.asArray?.contains { $0["placeholder"] == "sldNum" } ?? false)
    }

    // Rust: tests.rs::header_footer_fixed_date_is_the_slides_own_text
    @Test(.enabled(if: ported("text.edit", "text.insert", "insert.dateTime")))
    func headerFooterFixedDateIsTheSlidesOwnText() throws {
        let s = session()
        func date() -> TextBody? { s.st.currentSlide?.shapes.first { $0.phType == .date }?.text }
        func kind() -> RunKind? { date()?.paragraphs.first?.runs.first?.kind }
        // Automatic: a date field, saved with today's date.
        s.run("design.headerFooter", ##"{"date": true}"##)
        #expect(kind() == .field(field: "datetime1"))
        #expect((date()?.text.filter { $0 == "/" }.count ?? 0) == 2, "M/D/YYYY")
        // Fixed: plain text in the slide's own placeholder (other slides' fields aren't affected).
        s.run("design.headerFooter", ##"{"date": true, "dateText": "Launch day"}"##)
        #expect(kind() == .text && date()?.text == "Launch day")
        // Back to automatic.
        s.run("design.headerFooter", ##"{"date": true, "dateText": ""}"##)
        if case .field? = kind() {} else { Issue.record("expected a field") }
        // A new date field is saved with the date it shows.
        let titleId = try #require(s.st.currentSlide?.shapes.first?.id)
        s.run("text.edit", "{\"id\": \(titleId.rawValue)}")
        s.run("text.insert", ##"{"text": "Updated "}"##)
        s.run("insert.dateTime", ##"{"format": "datetime10"}"##)
        let title = try #require(s.st.currentSlide?.shapes.first?.text)
        let run = try #require(title.paragraphs.first?.runs.first { if case .field = $0.kind { true } else { false } })
        #expect(run.text.contains(":"), "H:mm \(run)")
    }

    // Rust: tests.rs::motion_path_presets_have_paths_ids_and_round_trip
    @Test(.enabled(if: ported("shape.insert")))
    func motionPathPresetsHavePathsIdsAndRoundTrip() throws {
        let paths = DCModel.animations.filter { $0.animClass == .path }
        // Preset ids identify the effect when PowerPoint's file is read back: no two share one.
        let ids = paths.map(\.presetId)
        #expect(Set(ids).count == ids.count, "duplicate motion-path preset ids")
        #expect(ids.count >= 40, "\(ids.count) motion paths")
        let s = session()
        let id = s.run("shape.insert", ##"{"preset": "rect", "rect": [100, 100, 50, 50]}"##)["id"] ?? .null
        _ = try s.execute("animation.set", ["ids": [id], "effect": "heart", "class": "path"])
        let a = try #require(s.st.doc.slides[s.st.selection.slide].animations.first)
        #expect(a.path == presetPath("heart"))
        let back = try PPTX.import(PPTX.export(s.st.doc))
        let b = try #require(back.slides.flatMap(\.animations).first)
        #expect(b.effect == "heart" && b.class == .path)
        #expect(b.path?.contains("L") ?? false)
    }

    // Rust: tests.rs::handout_master_view_edits_and_round_trips
    @Test(.enabled(if: ported("shape.insert")))
    func handoutMasterViewEditsAndRoundTrips() throws {
        let s = session()
        #expect(s.st.doc.handoutMaster == nil)
        #expect(s.fails("handout.placeholders", ##"{"footer": false}"##), "only in the view")
        var r = s.run("view.handoutMaster")
        #expect(r["created"] == true)
        var st = s.st
        #expect(st.selection.target == .handout)
        #expect(pageSize(st) == st.doc.notesSize)
        #expect(st.shapes.compactMap(\.phType) == [.header, .date, .footer, .slideNum])
        // Hide the footer, then show it again; undo restores the hidden state.
        r = s.run("handout.placeholders", ##"{"footer": false}"##)
        #expect(r["footer"] == false)
        #expect(s.st.shapes.count == 3)
        s.run("handout.placeholders", ##"{"footer": true}"##)
        #expect(s.st.shapes.count == 4)
        s.run("edit.undo")
        #expect(s.st.shapes.count == 3)
        // Shapes drawn in the view land on the handout master, not the slide.
        let slideShapes = s.st.doc.slides[0].shapes.count
        s.run("shape.insert", ##"{"preset": "rect", "rect": [20, 300, 100, 40]}"##)
        #expect(s.st.doc.handoutMaster?.shapes.count == 4)
        #expect(s.st.doc.slides[0].shapes.count == slideShapes)
        st = s.st
        #expect(masterPage(st.doc, .handout).map { $0.masters.count == 1 && $0.slideSize == $0.notesSize } ?? false)
        s.run("view.closeMaster")
        #expect(s.st.selection.target == .slides)
        // Reopening doesn't make a second master, and it survives PPTX.
        #expect(s.run("view.handoutMaster")["created"] == false)
        let back = try PPTX.import(PPTX.export(s.st.doc))
        let hm = try #require(back.handoutMaster, "handout master kept")
        #expect(hm.shapes.count == 4)
        #expect(hm.shapes.contains { $0.phType == .slideNum })
    }

    // Rust: tests.rs::notes_master_view_edits_and_saves
    @Test(.enabled(if: ported("shape.insert")))
    func notesMasterViewEditsAndSaves() throws {
        let s = session()
        #expect(s.fails("notes.placeholders", ##"{"header": false}"##), "only in the view")
        #expect(s.run("view.notesMaster")["created"] == true)
        let st = s.st
        #expect(st.selection.target == .notesMaster)
        #expect(pageSize(st) == st.doc.notesSize)
        #expect(st.shapes.compactMap(\.phType) == [.header, .date, .slideImage, .body, .footer, .slideNum])
        let r = s.run("notes.placeholders", ##"{"header": false, "date": false}"##)
        #expect(r["header"]?.asBool == false && r["body"]?.asBool == true)
        #expect(s.st.shapes.count == 4)
        s.run("edit.undo")
        #expect(s.st.shapes.count == 6)
        s.run("notes.placeholders", ##"{"header": false}"##)
        // A shape added in the view is on the notes master and is saved, even with no notes in the deck.
        s.run("shape.insert", ##"{"preset": "ellipse", "rect": [20, 20, 60, 60]}"##)
        #expect(s.st.doc.slides.allSatisfy { $0.notes.isEmpty })
        #expect(masterPage(s.st.doc, .notesMaster) != nil)
        let back = try PPTX.import(PPTX.export(s.st.doc))
        let nm = try #require(back.notesMaster, "notes master written")
        #expect(nm.shapes.count == 6, "\(nm.shapes.map(\.name))")
        #expect(!nm.shapes.contains { $0.phType == .header })
        s.run("view.closeMaster")
        #expect(s.run("view.notesMaster")["created"] == false)
    }

    // Rust: tests.rs::theme_variants_apply_and_report_the_current_one
    @Test func themeVariantsApplyAndReportTheCurrentOne() throws {
        let s = session()
        let name = builtinThemes()[1].name
        _ = try s.execute("design.theme", ["name": .string(name)])
        let v = s.run("design.variants")
        #expect(v["variants"]?.asArray?.count == 4)
        #expect(v["current"] == 0)
        let base = s.st.doc.masters[0].theme.colors
        s.run("design.variant", ##"{"index": 1}"##)
        let c = s.st.doc.masters[0].theme.colors
        #expect(c.colors[4] == base.colors[5], "accents rotate")
        #expect(c.colors[0] == base.colors[0])
        #expect(s.run("design.variants")["current"] == 1)
        // From a variant, another variant is built from the theme's own colours, not the variant's.
        s.run("design.variant", ##"{"index": 3}"##)
        let d = s.st.doc.masters[0].theme.colors
        #expect([d.colors[0], d.colors[1], d.colors[4]] == [base.colors[1], base.colors[0], base.colors[4]])
        s.run("design.variant", ##"{"index": 0}"##)
        #expect(s.st.doc.masters[0].theme.colors.colors == base.colors)
        #expect(s.fails("design.variant", ##"{"index": 9}"##))
        // It survives PPTX.
        s.run("design.variant", ##"{"index": 2}"##)
        let p = s.st.doc
        let back = try PPTX.import(PPTX.export(p))
        #expect(back.masters[0].theme.colors.colors == p.masters[0].theme.colors.colors)
    }
}
