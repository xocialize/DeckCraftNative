// DCAppModelTests — the inspector without a window: the Format pane's fill and transparency rules, the
// gradient and pattern editors, colours as parameters, the Animation Pane's timeline, the Selection Pane, the
// ribbon's effect options, the Quick Access Toolbar and the controller's actions. Each test names the
// deckcraft test (`crates/ui-egui`) whose behaviour it ports; Rust names in camelCase.
import DCColor
import DCCore
import DCEngine
import DCGeometry
import DCModel
import Foundation
import Testing
@testable import DCAppModel

/// Shared fixtures.
@MainActor
enum Fx {
    /// A session on a blank slide.
    static func blank() -> Session {
        let s = Session.withNew()
        _ = try? s.execute("slide.new", ["layout": "blank"])
        return s
    }

    @discardableResult
    static func rect(_ s: Session, _ x: Double, _ y: Double = 40, w: Double = 120, h: Double = 80) -> UInt32 {
        let r = try? s.execute("shape.insert", ["preset": "rect", "rect": [.num(x), .num(y), .num(w), .num(h)]])
        return UInt32(r?["id"]?.asU64 ?? 0)
    }

    static func select(_ s: Session, _ ids: [UInt32]) {
        _ = try? s.execute("edit.select", ["ids": .array(ids.map { .integer($0) })])
    }

    static func shape(_ s: Session, _ id: UInt32) -> Shape? { s.activeDoc?.shape(ShapeId(id)) }

    static func undoCount(_ s: Session) -> Int { s.activeDoc?.history.undo.count ?? 0 }
}

/// A host that records the engine's UI requests (dialogs, panes).
@MainActor
final class RecordingHost: AppHost {
    var requests: [UiRequest] = []
    func uiCommand(_ id: String, _ params: JSON) -> Result<JSON, CommandError>? { nil }
    func uiRequest(_ request: UiRequest) { requests.append(request) }
    func modelChanged() {}
}

@MainActor
@Suite struct InspectorFillTests {
    // panes.rs: solid_fill_transparency_reads_the_alpha_shape_fill_writes
    @Test func solidFillTransparencyReadsTheAlphaShapeFillWrites() {
        #expect(InspectorFill.solidFillTransparencyPercent(nil) == 0)
        #expect(InspectorFill.solidFillTransparencyPercent(.none_) == 0)
        #expect(InspectorFill.solidFillTransparencyPercent(.group) == 0)
        let plain = Fill.solid(.scheme(.accent1))
        #expect(InspectorFill.solidFillTransparencyPercent(plain) == 0)
        let forty = Fill.solid(ColorRef.scheme(.accent1).with(.alpha(60_000)))
        #expect(abs(InspectorFill.solidFillTransparencyPercent(forty) - 40) < 0.01)
        let clear = Fill.solid(ColorRef.scheme(.accent1).with(.alpha(0)))
        #expect(abs(InspectorFill.solidFillTransparencyPercent(clear) - 100) < 0.01)
        // A later alpha wins, matching ColorRef.alpha.
        let layered = Fill.solid(ColorRef.scheme(.accent1).with(.alpha(0)).with(.alpha(60_000)))
        #expect(abs(InspectorFill.solidFillTransparencyPercent(layered) - 40) < 0.01)

        #expect(InspectorFill.fillTransparencyToApply(40, 40) == nil)
        #expect(InspectorFill.fillTransparencyToApply(40.005, 40) == nil)
        #expect(InspectorFill.fillTransparencyToApply(.nan, 40) == nil)
        #expect(InspectorFill.fillTransparencyToApply(55, 40).map { abs($0 - 0.55) < 1e-6 } == true)
        #expect(InspectorFill.fillTransparencyToApply(0, 40) == 0)
    }

    // panes.rs: fill_transparency_slider_follows_the_selection — the slider is seeded from the selected
    // shape, an unchanged value writes nothing, and a real edit writes the new alpha.
    @Test func fillTransparencySliderFollowsTheSelection() {
        let s = Fx.blank()
        let a = Fx.rect(s, 40), b = Fx.rect(s, 200)
        _ = try? s.execute("shape.fill", ["id": .integer(a), "color": "accent1", "transparency": 0.0])
        _ = try? s.execute("shape.fill", ["id": .integer(b), "color": "accent1", "transparency": 0.4])
        #expect(InspectorFill.fillTransparencySeed(Fx.shape(s, a)?.fill) == 0)
        let seed = InspectorFill.fillTransparencySeed(Fx.shape(s, b)?.fill)
        #expect(abs(seed - 40) < 0.5)
        // Looking at the shape and leaving the slider writes nothing.
        #expect(InspectorFill.fillTransparencyToApply(seed, seed) == nil)
        Fx.select(s, [b])
        let m = AppModel(session: s)
        if let t = InspectorFill.fillTransparencyToApply(50, seed) { m.run("shape.fill", ["transparency": .num(t)]) }
        guard case .solid(let c)? = Fx.shape(s, b)?.fill else { Issue.record("expected a solid fill"); return }
        #expect(c.mods.contains(.alpha(50_000)))
    }

    // panes.rs: fill_color_and_transparency_show_only_where_they_change_the_fill
    @Test func fillColorAndTransparencyShowOnlyWhereTheyChangeTheFill() {
        let gradient = Fill.gradient(InspectorFill.defaultGradient(.scheme(.accent1), 90))
        let picture = Fill.picture(PictureFill(media: MediaId(1), crop: [0, 0, 0, 0], mode: .default, alpha: nil, adjust: PictureAdjust.default, upright: false))
        let cases: [(String, Fill?, Bool, Bool)] = [
            ("automatic", nil, true, true), ("solid", .solid(.scheme(.accent2)), true, true), ("no fill", .none_, false, false),
            ("gradient", gradient, false, false), ("picture", picture, false, true),
        ]
        for (name, fill, color, transparency) in cases {
            #expect(InspectorFill.showsColor(fill) == color, "\(name): Color")
            #expect(InspectorFill.showsTransparency(fill) == transparency, "\(name): Transparency")
        }
    }

    // panes.rs: picture_fill_transparency_slider_shows_the_picture_transparency
    @Test func pictureFillTransparencySliderShowsThePictureTransparency() {
        var pf = PictureFill(media: MediaId(1), crop: [0, 0, 0, 0], mode: .default, alpha: 0.6, adjust: PictureAdjust.default, upright: false)
        #expect(abs(InspectorFill.fillTransparencySeed(.picture(pf)) - 40) < 0.01)
        pf.alpha = nil
        #expect(InspectorFill.fillTransparencySeed(.picture(pf)) == 0)
    }

    @Test func fillKindsAndTheirParams() {
        #expect(InspectorFill.kind(nil) == "auto")
        #expect(InspectorFill.kind(.none_) == "none")
        #expect(InspectorFill.shapeKindParams("picture") == nil)
        let s = Fx.blank()
        let id = Fx.rect(s, 40)
        Fx.select(s, [id])
        let m = AppModel(session: s)
        for k in ["none", "solid", "gradient", "pattern", "auto"] {
            if let p = InspectorFill.shapeKindParams(k) { m.run("shape.fill", p) }
            #expect(InspectorFill.kind(Fx.shape(s, id)?.fill) == k, "\(k)")
        }
    }

    // fillui.rs: the gradient editor's edits.
    @Test func gradientEditsKeepStopsSortedAndBounded() throws {
        var g = InspectorFill.defaultGradient(.scheme(.accent1), 90)
        #expect(g.stops.count == 2)
        let (added, i) = try #require(InspectorFill.addStop(g, at: 0.4))
        #expect(added.stops.map(\.pos) == [0, 0.4, 1])
        #expect(i == 1)
        // A new stop takes the colour of the nearest one.
        #expect(added.stops[1].color == g.stops[0].color)
        g = added
        g = InspectorFill.setStopPosition(g, 1, percent: 150)
        #expect(g.stops.map(\.pos) == [0, 1, 1])
        g = InspectorFill.setStopTransparency(g, 0, percent: 25)
        #expect(abs(InspectorFill.alphaOf(g.stops[0].color) - 0.75) < 1e-9)
        // Recolouring keeps the transparency.
        g = InspectorFill.setStopColor(g, 0, .rgb(.rgb(1, 2, 3)))
        #expect(abs(InspectorFill.alphaOf(g.stops[0].color) - 0.75) < 1e-9)
        let removed = try #require(InspectorFill.removeStop(g, 2))
        #expect(removed.0.stops.count == 2 && removed.1 == 1)
        #expect(InspectorFill.removeStop(removed.0, 0) == nil, "two stops always stay")
        var full = InspectorFill.defaultGradient(.scheme(.accent1), 90)
        for k in 0 ..< 20 { if let (n, _) = InspectorFill.addStop(full, at: Double(k) / 20) { full = n } }
        #expect(full.stops.count == InspectorFill.maxStops)
        #expect(InspectorFill.addStop(full, at: .nan) == nil)
        #expect(InspectorFill.moveStop(full, 99, to: 0.5) == full)
    }

    @Test func gradientTypesDirectionsAndJSON() throws {
        let g = InspectorFill.defaultGradient(.scheme(.accent1), 90)
        #expect(InspectorFill.typeName(g) == "Linear")
        #expect(InspectorFill.withType(g, "Linear") == nil)
        let radial = try #require(InspectorFill.withType(g, "Radial"))
        #expect(InspectorFill.typeName(radial) == "Radial")
        #expect(InspectorFill.gradientJSON(radial)["kind"]?.asStr == "radial")
        #expect(InspectorFill.gradientJSON(try #require(InspectorFill.withType(g, "Rectangular")))["kind"]?.asStr == "rectangular")
        #expect(InspectorFill.gradientJSON(try #require(InspectorFill.withType(g, "Path")))["kind"]?.asStr == "path")
        if case .linear(let a, _) = InspectorFill.withAngle(g, -45).shape { #expect(a == 315) } else { Issue.record("linear") }
        if case .linear(let a, _) = InspectorFill.withAngle(g, .infinity).shape { #expect(a == 0) } else { Issue.record("linear") }
        #expect(InspectorFill.presets(g).count == 6)
        // The JSON round-trips through `shape.fill`.
        let s = Fx.blank()
        let id = Fx.rect(s, 40)
        Fx.select(s, [id])
        _ = try s.execute("shape.fill", ["gradient": InspectorFill.gradientJSON(radial)])
        guard case .gradient(let back)? = Fx.shape(s, id)?.fill else { Issue.record("gradient"); return }
        #expect(InspectorFill.typeName(back) == "Radial")
        #expect(back.stops.count == 2)
    }

    // pattern_fill_tests.rs: shape_pattern_fill_picks_a_preset_from_the_gallery (the gallery's content)
    @Test func patternGalleryHasFortyEightPresetsWithoutTheSixPowerPointLeavesOut() {
        #expect(InspectorFill.patternGallery.count == 48)
        #expect(Set(InspectorFill.patternGallery).count == 48)
        for name in ["horz", "vert", "cross", "dnDiag", "upDiag", "diagCross"] {
            #expect(!InspectorFill.patternGallery.contains(name), "\(name) is not in the gallery")
        }
        #expect(InspectorFill.patternLabel("dkDnDiag") == "Dark downward diagonal")
        #expect(InspectorFill.patternLabel("zigZag") == "Zig zag")
        #expect(InspectorFill.patternLabel("nope") == "nope")
    }

    /// A new deck with one rectangle selected and filled with `pct25` in accent 1 on background 1.
    static func patternedShape() -> (Session, UInt32) {
        let s = Session.withNew()
        let id = Fx.rect(s, 80, 80, w: 200, h: 120)
        Fx.select(s, [id])
        _ = try? s.execute("shape.fill", ["pattern": ["preset": "pct25", "fg": "accent1", "bg": "bg1"]])
        return (s, id)
    }

    static func pattern(_ s: Session, _ id: UInt32) -> PatternFill? {
        if case .pattern(let p)? = Fx.shape(s, id)?.fill { return p }
        return nil
    }

    // pattern_fill_tests.rs: shape_pattern_fill_picks_a_preset_from_the_gallery (one undo step)
    @Test func shapePatternFillPicksAPresetFromTheGallery() throws {
        let (s, id) = Self.patternedShape()
        let m = AppModel(session: s)
        let before = Fx.undoCount(s)
        let pt = try #require(Self.pattern(s, id))
        #expect(InspectorFill.showsTransparency(Fx.shape(s, id)?.fill) == false, "a pattern has no solid-fill transparency")
        let n = try #require(InspectorFill.withPreset(pt, "dkDnDiag"))
        m.run("shape.fill", ["pattern": InspectorFill.patternJSON(n)])
        let after = try #require(Self.pattern(s, id))
        #expect(after.preset == "dkDnDiag")
        #expect(after.fg == .scheme(.accent1) && after.bg == .scheme(.bg1))
        #expect(Fx.undoCount(s) == before + 1, "one undo step")
        #expect(InspectorFill.withPreset(after, "dkDnDiag") == nil, "the same preset changes nothing")
    }

    // pattern_fill_tests.rs: shape_pattern_fill_keeps_preset_and_system_colors
    @Test func shapePatternFillKeepsPresetAndSystemColors() throws {
        let (s, id) = Self.patternedShape()
        let fg: JSON = ["preset": "red", "lumMod": 50000]
        let bg: JSON = ["system": "window", "last": "#F0F0F0"]
        _ = try s.execute("shape.fill", ["pattern": ["preset": "pct25", "fg": fg, "bg": bg]])
        let before = try #require(Self.pattern(s, id))
        let m = AppModel(session: s)
        m.run("shape.fill", ["pattern": InspectorFill.patternJSON(try #require(InspectorFill.withPreset(before, "zigZag")))])
        let pt = try #require(Self.pattern(s, id))
        #expect(pt.preset == "zigZag")
        #expect(pt.fg == before.fg && pt.bg == before.bg, "a preset change keeps both colors")
        var n = pt
        n.fg = .rgb(.rgb(0, 255, 0))
        m.run("shape.fill", ["pattern": InspectorFill.patternJSON(n)])
        #expect(Self.pattern(s, id)?.bg == before.bg, "a foreground change keeps the background")
    }

    // pattern_fill_tests.rs: shape_pattern_fill_sets_its_foreground_and_background_colors
    @Test func shapePatternFillSetsItsForegroundAndBackgroundColors() throws {
        let (s, id) = Self.patternedShape()
        let m = AppModel(session: s)
        var pt = try #require(Self.pattern(s, id))
        pt.fg = try #require(InspectorColors.hex("00FF00"))
        m.run("shape.fill", ["pattern": InspectorFill.patternJSON(pt)])
        pt = try #require(Self.pattern(s, id))
        #expect(pt.fg == .rgb(.rgb(0, 255, 0)) && pt.preset == "pct25")
        pt.bg = try #require(InspectorColors.hex("112233"))
        m.run("shape.fill", ["pattern": InspectorFill.patternJSON(pt)])
        pt = try #require(Self.pattern(s, id))
        #expect(pt.bg == .rgb(.rgb(0x11, 0x22, 0x33)) && pt.fg == .rgb(.rgb(0, 255, 0)))
    }

    // pattern_fill_tests.rs: background_pattern_fill_offers_every_preset_and_both_colors,
    // background_pattern_fill_keeps_a_system_color
    @Test func backgroundPatternFillKeepsItsColors() throws {
        let s = Session.withNew()
        let bgColor: JSON = ["system": "window", "last": "#F0F0F0"]
        _ = try s.execute("design.background", ["pattern": ["preset": "pct20", "fg": "accent1", "bg": bgColor]])
        func bg() -> PatternFill? {
            if case .pattern(let p)? = InspectorFill.backgroundFill(s.activeDoc?.doc.slides.first?.background) { return p }
            return nil
        }
        let before = try #require(bg())
        #expect(InspectorFill.backgroundKind(s.activeDoc?.doc.slides.first?.background) == "pattern")
        let m = AppModel(session: s)
        m.run("design.background", ["pattern": InspectorFill.patternJSON(try #require(InspectorFill.withPreset(before, "zigZag")))])
        var pt = try #require(bg())
        #expect(pt.preset == "zigZag" && pt.bg == before.bg)
        pt.bg = .rgb(.rgb(0xFF, 0xEE, 0))
        m.run("design.background", ["pattern": InspectorFill.patternJSON(pt)])
        #expect(bg()?.bg == .rgb(.rgb(0xFF, 0xEE, 0)) && bg()?.preset == "zigZag")
    }

    /// 1×1 PNG.
    static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    // background_tests.rs: apply_to_all_copies_the_picture
    @Test func applyToAllCopiesThePicture() throws {
        let s = Session.withNew()
        _ = try s.execute("design.background", ["picture": .string(Self.png), "name": "dot.png"])
        _ = try s.execute("slide.new", .emptyObject)
        _ = try s.execute("slide.go", ["index": 0])
        let bg = s.activeDoc?.doc.slides.first?.background
        #expect(InspectorFill.backgroundKind(bg) == "picture")
        let p = try #require(InspectorFill.applyToAllParams(bg))
        #expect(p == ["copy": true])
        AppModel(session: s).run("design.background", p)
        let doc = try #require(s.activeDoc?.doc)
        #expect(doc.slides[1].background == doc.slides[0].background)
        #expect(doc.masters[0].background == doc.slides[0].background)
    }

    // background_tests.rs: picture_fill_shows_transparency_and_tiling, solid_fill_shows_transparency_without_tile_options
    @Test func backgroundPictureTilesAndSolidAppliesToAll() throws {
        let s = Session.withNew()
        _ = try s.execute("design.background", ["picture": .string(Self.png), "name": "dot.png"])
        AppModel(session: s).run("design.background", ["pictureProps": ["tile": true]])
        guard case .picture(let pf)? = InspectorFill.backgroundFill(s.activeDoc?.doc.slides.first?.background), case .tile = pf.mode else {
            Issue.record("expected a tiled picture background"); return
        }
        _ = try s.execute("design.background", ["color": "accent1"])
        let p = try #require(InspectorFill.applyToAllParams(s.activeDoc?.doc.slides.first?.background))
        #expect(p["all"]?.asBool == true)
        #expect(p["color"] == ["scheme": "accent1"])
        #expect(InspectorFill.applyToAllParams(nil) == nil)
    }

    @Test func lineChoicesAndPresetLabels() {
        #expect(InspectorFill.presetLabel("perspectiveHeroicLeftFacing") == "Perspective heroic left facing")
        let c = InspectorFill.lineChoices(nil)
        #expect(c.compound == "single" && c.cap == "flat" && c.join == "round" && c.head == "none" && c.headSize == nil)
        #expect(InspectorFill.lineKind(nil) == "auto")
        #expect(InspectorFill.lineKind(Line(fill: .none_)) == "none")
        #expect(InspectorFill.lineKind(Line(fill: .solid(.scheme(.tx1)))) == "solid")
    }
}

@MainActor
@Suite struct InspectorColorTests {
    @Test func colorParamsRoundTripThroughTheEngine() {
        let cases: [ColorRef] = [
            .rgb(.rgb(0x12, 0x34, 0x56)), .scheme(.accent2), ColorRef.scheme(.tx1).with(.lumMod(75_000)).with(.lumOff(25_000)),
            ColorRef.rgb(.rgb(1, 2, 3)).with(.alpha(50_000)), ColorRef(base: .preset(name: "red"), mods: [.lumMod(50_000)]),
            ColorRef(base: .system(name: "window", last: .rgb(0xF0, 0xF0, 0xF0)), mods: []),
        ]
        for c in cases {
            #expect(Cmd.colorValue(InspectorColors.param(c)) == c, "\(c)")
        }
        #expect(InspectorColors.param(.rgb(.rgb(0xAB, 0xCD, 0xEF))) == "#ABCDEF")
    }

    @Test func themeGridHasTenColumnsAndSixRows() {
        let scheme = Theme.default.colors
        let grid = InspectorColors.themeGrid(scheme)
        #expect(grid.count == 6)
        #expect(grid.allSatisfy { $0.count == 10 })
        // Picked theme colours are stored by their aliases, with the variant's transforms.
        #expect(grid[0][0].ref == .scheme(.bg1))
        #expect(grid[0][1].ref == .scheme(.tx1))
        #expect(grid[0][4].ref == .scheme(.accent1))
        #expect(grid[1][4].ref.mods == themeVariants(scheme.get(.accent1)).first?.transforms)
        #expect(InspectorColors.standard.count == 10)
        #expect(InspectorColors.hex("zzz") == nil)
        #expect(InspectorColors.hex("#00FF00") == .rgb(.rgb(0, 255, 0)))
    }

    // last_color_tests.rs: home_shape_fill_button_reapplies_the_last_colour,
    // home_shape_outline_button_reapplies_the_last_colour (and the Shape Format tab's, which share the code)
    @Test func shapeFillAndOutlineButtonsReapplyTheLastColour() throws {
        let s = Fx.blank()
        let a = Fx.rect(s, 100), b = Fx.rect(s, 300)
        Fx.select(s, [b])
        _ = try s.execute("shape.fill", ["color": "#FF0000"])
        _ = try s.execute("shape.line", ["color": "#0000FF", "width": 3])
        Fx.select(s, [a])
        let ctl = InspectorController(model: AppModel(session: s))
        func rgb(_ f: Fill?) -> String? {
            if case .solid(let c)? = f, case .rgb(let v) = c.base { return v.hex }
            return nil
        }
        ctl.pickFill(.rgb(.rgb(0, 0xAA, 0x55)))
        #expect(rgb(Fx.shape(s, a)?.fill) == "00AA55", "the menu pick applies to the selection")
        ctl.pickOutline(.rgb(.rgb(0xAA, 0x55, 0)))
        #expect(rgb(Fx.shape(s, a)?.line?.fill) == "AA5500")
        Fx.select(s, [b])
        #expect(rgb(Fx.shape(s, b)?.fill) == "FF0000", "selecting alone changes nothing")
        ctl.shapeFillButton()
        #expect(rgb(Fx.shape(s, b)?.fill) == "00AA55", "the button applies the last colour, not Accent 1")
        ctl.shapeOutlineButton()
        #expect(rgb(Fx.shape(s, b)?.line?.fill) == "AA5500", "the button applies the last colour, not Text 1")
        #expect(Fx.shape(s, b)?.line?.width == 3, "recolouring leaves the weight alone")
    }

    // last_color_tests.rs: before_any_pick_the_buttons_still_apply_accent_1_and_text_1
    @Test func beforeAnyPickTheButtonsStillApplyAccent1AndText1() {
        let s = Fx.blank()
        let a = Fx.rect(s, 100)
        Fx.select(s, [a])
        let ctl = InspectorController(model: AppModel(session: s))
        ctl.shapeFillButton()
        ctl.shapeOutlineButton()
        let sh = Fx.shape(s, a)
        if case .solid(let c)? = sh?.fill { #expect(c.base == .scheme(slot: .accent1)) } else { Issue.record("fill") }
        if case .solid(let c)? = sh?.line?.fill { #expect(c.base == .scheme(slot: .tx1)) } else { Issue.record("line") }
    }

    @Test func noFillAndNoOutline() {
        let s = Fx.blank()
        let a = Fx.rect(s, 100)
        Fx.select(s, [a])
        let ctl = InspectorController(model: AppModel(session: s))
        ctl.pickFill(nil)
        ctl.pickOutline(nil)
        #expect(Fx.shape(s, a)?.fill == Fill.none_)
        #expect(Fx.shape(s, a)?.line?.fill == Fill.none_)
        #expect(ctl.lastFill == "accent1", "No Fill isn't remembered")
    }
}

@MainActor
@Suite struct InspectorTimelineTests {
    typealias E = AnimTimeline.Effect

    // animtimeline.rs: first_paragraph_wins_and_missing_are_none
    @Test func firstParagraphWinsAndMissingAreNone() {
        let b = AnimTimeline.bars(3, [E(anim: 0, step: 0, start: 0, span: 0.5), E(anim: 0, step: 0, start: 0.5, span: 0.5),
                                      E(anim: 2, step: 1, start: .nan, span: -1), E(anim: 9, step: 0, start: 0, span: 1)])
        #expect(b[0] == AnimTimeline.Bar(anim: 0, step: 0, start: 0, span: 0.5))
        #expect(b[1] == nil)
        #expect(b[2] == AnimTimeline.Bar(anim: 2, step: 1, start: 0, span: 0))
    }

    // animtimeline.rs: ruler_and_scale
    @Test func rulerAndScale() {
        #expect(AnimTimeline.rulerSeconds([]) == 1)
        #expect(AnimTimeline.rulerSeconds(AnimTimeline.bars(1, [E(anim: 0, step: 0, start: 1.2, span: 2)])) == 4)
        #expect(AnimTimeline.pixelsPerSecond(200, 4) == 50)
        #expect(AnimTimeline.pixelsPerSecond(10_000, 1) == 120)
        #expect(AnimTimeline.pixelsPerSecond(.nan, 0) == 8)
    }

    // animtimeline.rs: drags_snap_and_clamp
    @Test func dragsSnapAndClamp() {
        #expect(AnimTimeline.draggedDelay(0, 25, 50) == 500)
        #expect(AnimTimeline.draggedDelay(500, -100, 50) == 0)
        #expect(AnimTimeline.draggedDelay(0, 13, 50) == 250)
        #expect(AnimTimeline.draggedDelay(0, .infinity, 50) == 0)
        #expect(AnimTimeline.draggedDelay(AnimTimeline.maxMs, 1e9, 1) == AnimTimeline.maxMs)
        #expect(AnimTimeline.draggedDuration(500, 50, 50, 1) == 1500)
        #expect(AnimTimeline.draggedDuration(500, 50, 50, 2) == 1000)
        #expect(AnimTimeline.draggedDuration(500, -1000, 50, 1) == AnimTimeline.minDurationMs)
        #expect(AnimTimeline.draggedDuration(500, 0, 0, .nan) == 500)
    }

    // animtimeline.rs: label_text
    @Test func labelText() {
        #expect(AnimTimeline.label(AnimTimeline.Bar(anim: 0, step: nil, start: 0.5, span: 2)) == "Start: 0.50s, End: 2.50s")
    }

    /// animpane_tests.rs' harness: a blank slide with two shapes, Fade on click (1 s), then Zoom after previous (2 s).
    static func session() -> (Session, [UInt32]) {
        let s = Fx.blank()
        var ids: [UInt32] = []
        for (i, (effect, start, dur)) in [("fade", "onClick", 1000), ("zoom", "afterPrevious", 2000)].enumerated() {
            let id = Fx.rect(s, 40 + 200 * Double(i), 80, w: 150, h: 100)
            Fx.select(s, [id])
            _ = try? s.execute("animation.add", ["effect": .string(effect), "start": .string(start), "duration": .integer(dur)])
            ids.append(id)
        }
        return (s, ids)
    }

    // animpane_tests.rs: after_previous_bar_starts_where_the_first_ends
    @Test func afterPreviousBarStartsWhereTheFirstEnds() throws {
        let (s, _) = Self.session()
        let pane = AnimPane(try #require(s.activeDoc))
        let a = try #require(pane.rows[0].bar), b = try #require(pane.rows[1].bar)
        #expect(abs(b.start - (a.start + a.span)) < 1e-9)
        #expect(abs(b.span - 2 * a.span) < 1e-9, "2 s bar twice the 1 s bar")
        #expect(pane.rows.map(\.click) == ["1", ""])
        #expect(pane.seconds == 3)
    }

    // animpane_tests.rs: dragging_a_bar_sets_the_delay_and_undoes, dragging_the_edge_sets_the_duration
    @Test func draggingABarSetsTheDelayAndTheEdgeTheDuration() throws {
        let (s, _) = Self.session()
        let m = AppModel(session: s)
        let pane = AnimPane(try #require(s.activeDoc))
        let pps = AnimTimeline.pixelsPerSecond(200, pane.seconds)
        // Half a second to the right.
        let d = AnimTimeline.draggedDelay(pane.rows[0].delayMs, pps / 2, pps)
        m.run("animation.timing", ["index": 0, "delay": .integer(d)])
        func timing(_ i: Int) -> (UInt32, UInt32)? { s.activeDoc?.currentSlide?.animations.at(i).map { ($0.delayMs, $0.durationMs) } }
        #expect(timing(0)! == (500, 1000))
        m.run("edit.undo")
        #expect(timing(0)! == (0, 1000))
        let bar = try #require(pane.rows[1].bar)
        let factor = bar.span / (Double(pane.rows[1].durationMs) / 1000)
        let dur = AnimTimeline.draggedDuration(pane.rows[1].durationMs, -pps, pps, factor)
        m.run("animation.timing", ["index": 1, "duration": .integer(dur)])
        #expect(timing(1)! == (0, 1000))
    }

    // animpane_tests.rs: play_from_starts_at_the_selected_effect, play_from_follows_the_effect_clicked_in_the_pane,
    // moving_an_effect_forgets_the_clicked_row, play_from_skips_a_triggered_effect
    @Test func playFromFollowsTheSelectionTheClickAndTheClickSequence() throws {
        let (s, ids) = Self.session()
        let ctl = InspectorController(model: AppModel(session: s))
        // The zoomed shape is selected: its effect starts once the 1 s fade is over.
        var pane = ctl.animationPane()
        var from = try #require(pane.playFrom(pick: ctl.currentAnimPick, selected: [ShapeId(ids[1])]))
        #expect(from == 1)
        #expect(abs((pane.starts[from] ?? -1) - 1.0) < 0.1)
        #expect(pane.playFrom(pick: nil, selected: []) == nil, "nothing selected: Play All")
        #expect(AnimPane.playButton(playing: false, from: nil).label == "Play All")
        #expect(AnimPane.playButton(playing: false, from: 1).params == ["on": true, "from": 1])
        // A second effect on the first shape, after the zoom; clicking its row plays from it.
        Fx.select(s, [ids[0]])
        _ = try s.execute("animation.add", ["effect": "pulse", "start": "afterPrevious", "duration": 1000])
        pane = ctl.animationPane()
        ctl.clickAnimation(pane.rows[2])
        #expect(s.activeDoc?.selection.shapes == [ShapeId(ids[0])])
        from = try #require(pane.playFrom(pick: ctl.currentAnimPick, selected: [ShapeId(ids[0])]))
        #expect(from == 2)
        #expect(abs((pane.starts[2] ?? -1) - 3.0) < 0.1, "plays from the clicked row")
        // Reordering forgets the click.
        ctl.animationEdit("animation.move", ["index": 2, "to": 1])
        #expect(ctl.currentAnimPick == nil)
        pane = ctl.animationPane()
        #expect(pane.playFrom(pick: ctl.currentAnimPick, selected: [ShapeId(ids[0])]) == 0, "back to the shape's first effect")
        // A triggered effect is not on the click sequence: Play From skips it.
        let (t, tids) = Self.session()
        _ = try t.execute("animation.timing", ["index": 1, "trigger": .integer(tids[0])])
        Fx.select(t, [tids[1]])
        _ = try t.execute("animation.add", ["effect": "pulse", "start": "afterPrevious", "duration": 1000])
        let tp = AnimPane(try #require(t.activeDoc))
        #expect(tp.starts[1] == nil)
        #expect(tp.playFrom(pick: 1, selected: [ShapeId(tids[1])]) == 2, "a clicked triggered row falls back too")
    }

    // ribbon.rs: effect_options_mark_only_the_stored_choice
    @Test func effectOptionsMarkOnlyTheStoredChoice() {
        func marked(_ rows: [(String, Bool)]) -> [String] { rows.filter(\.1).map(\.0) }
        #expect(marked(InspectorMotion.transitionEffectRows("push", "l")) == ["l"])
        #expect(InspectorMotion.transitionEffectRows("push", "l").map(\.1) == [false, false, true, false])
        #expect(marked(InspectorMotion.transitionEffectRows("fade", "throughBlack")) == ["throughBlack"])
        #expect(marked(InspectorMotion.transitionEffectRows("push", "missing")).isEmpty)
        #expect(InspectorMotion.transitionEffectRows("none", nil).isEmpty)
        #expect(marked(InspectorMotion.transitionEffectRows("cut", "")) == [""])
        #expect(marked(InspectorMotion.animationEffectRows("fly", .entrance, "l")) == ["l"])
        #expect(marked(InspectorMotion.animationEffectRows("fly", .entrance, "nope")).isEmpty)
        #expect(InspectorMotion.animationEffectRows("appear", .entrance, "l").isEmpty)
        let builds = ["asOne", "byParagraph"]
        #expect(marked(InspectorMotion.marked(builds, InspectorMotion.textBuildId(.byParagraph))) == ["byParagraph"])
        #expect(marked(InspectorMotion.marked(builds, InspectorMotion.textBuildId(.asOne))) == ["asOne"])
        #expect(marked(InspectorMotion.marked(builds, InspectorMotion.textBuildId(.byWord))).isEmpty)
    }

    @Test func optionLabelsAndMilliseconds() {
        #expect(InspectorMotion.optionLabel("l") == "From Left")
        #expect(InspectorMotion.optionLabel("fromBottom") == "From Bottom")
        #expect(InspectorMotion.ms(1.25) == 1250)
        #expect(InspectorMotion.ms(-3) == 0)
        #expect(InspectorMotion.ms(.nan) == 0)
    }
}
