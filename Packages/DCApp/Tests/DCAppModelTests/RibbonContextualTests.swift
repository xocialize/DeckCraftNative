// DCAppModelTests — R2 of Docs/plans/Ribbon-and-StartScreen.md without a window: the contextual tabs follow the
// selection and are never switched to on their own (`ribbon.rs` `contextual` and `show`), every contextual
// control runs its command with deckcraft's parameters, the galleries' sources, and a gallery pick being one undo
// step. The theme gallery's tiles are the start window's.
import DCCore
import DCEngine
import DCModel
import Foundation
import Testing
@testable import DCAppModel

@MainActor
@Suite struct RibbonContextualTests {
    /// A 1 × 1 PNG.
    static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    /// A short silent WAV: 8 kHz, 8-bit mono, a tenth of a second.
    static var wav: [UInt8] {
        let n: UInt32 = 800
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        return Array("RIFF".utf8) + le32(36 + n) + Array("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(8000) + le32(8000)
            + le16(1) + le16(8) + Array("data".utf8) + le32(n) + [UInt8](repeating: 128, count: Int(n))
    }

    /// The object kinds a slide can have selected, each made and selected in a fresh model.
    enum Kind: String, CaseIterable {
        case shape, picture, table, chart, smartArt, media, slideMaster, notesMaster, handoutMaster
    }

    /// The models' host (`AppModel.host` is weak).
    static let host = AcceptingHost()

    static func model(_ kind: Kind) throws -> AppModel {
        let s = Session.withNew()
        _ = try s.execute("slide.new", ["layout": "blank"])
        let m = AppModel(session: s)
        m.host = host
        switch kind {
        case .shape: _ = try s.execute("shape.insert", ["preset": "rect", "rect": [100, 100, 200, 100]])
        case .picture: _ = try s.execute("insert.picture", ["data": .string(png), "name": "dot.png"])
        case .table: _ = try s.execute("insert.table", ["rows": 3, "cols": 3])
        case .chart: _ = try s.execute("insert.chart", ["type": "Column"])
        case .smartArt: _ = try s.execute("insert.smartArt", ["kind": "list", "items": ["Plan", "Build", "Ship"]])
        case .media: _ = try s.execute("insert.audio", ["data": .string(Cmd.base64Encode(wav)), "name": "tone.wav"])
        case .slideMaster: _ = try s.execute("view.slideMaster", .emptyObject)
        case .notesMaster: _ = try s.execute("view.notesMaster", .emptyObject)
        case .handoutMaster: _ = try s.execute("view.handoutMaster", .emptyObject)
        }
        m.changed()
        return m
    }

    /// The contextual tabs each kind brings, by title.
    static let expected: [Kind: [String]] = [
        .shape: ["Shape Format"], .picture: ["Picture Format"], .table: ["Table Design", "Layout"], .chart: ["Chart Design"],
        // SmartArt is a group, so Shape Format comes with it, as deckcraft has it.
        .smartArt: ["Shape Format", "SmartArt Design"], .media: ["Playback"], .slideMaster: ["Slide Master"], .notesMaster: ["Notes Master"],
        .handoutMaster: ["Handout Master"],
    ]

    // R2: "selecting each object kind shows its contextual tabs (the predicates are tested in the model)".
    @Test(arguments: Kind.allCases) func eachObjectKindShowsItsTabs(_ kind: Kind) throws {
        let m = try Self.model(kind)
        let want = try #require(Self.expected[kind])
        #expect(RibbonModel.contextual(m.session.activeDoc) == want, "\(kind)")
        let tabs = RibbonModel.tabs(m)
        #expect(tabs.prefix(10).map(\.id) == RibbonLayout.regular.map(\.id))
        #expect(tabs.dropFirst(10).map(\.title) == want)
        #expect(tabs.dropFirst(10).allSatisfy { $0.contextual != nil })
        // The control channel lists them too.
        #expect(RibbonModel.inspect(m)["tabs"]?.asArray?.compactMap(\.asStr) == tabs.map(\.title))
        #expect(RibbonModel.inspect(m)["contextual"]?.asArray?.compactMap(\.asStr) == want)
    }

    // "… and never switches tabs": selecting an object leaves the tab alone; a contextual tab that stops applying
    // gives way to Home, and selecting the object again doesn't bring it back (`ribbon.rs` `show`).
    @Test func contextualTabsAreNeverSwitchedTo() throws {
        let m = try Self.model(.table)
        #expect(RibbonModel.selected(m).id == "home", "a new table doesn't switch to Table Design")
        m.run("view.tab", ["tab": "Layout"])
        #expect(RibbonModel.selected(m).id == "tableLayout")
        let table = try #require(m.session.activeDoc?.selection.shapes.first)
        m.run("edit.select", ["ids": []])
        #expect(RibbonModel.selected(m).id == "home" && m.ui.tab == "Home")
        m.run("edit.select", ["ids": [.integer(table.rawValue)]])
        #expect(RibbonModel.selected(m).id == "home", "selecting the table again stays on Home")
        // A regular tab is never moved.
        m.run("view.tab", ["tab": "Review"])
        m.run("edit.select", ["ids": []])
        #expect(m.ui.tab == "Review")
        // Choosing a tab the selection doesn't have is Home too.
        m.run("view.tab", ["tab": "Picture Format"])
        #expect(RibbonModel.selected(m).id == "home")
    }

    // Every gallery has items, a command for each with deckcraft's parameters, and its inline tiles among them.
    @Test func galleriesHaveTheirSources() throws {
        let m = try Self.model(.smartArt)
        for source in RibbonGalleries.sources {
            let g = try #require(RibbonGalleries.gallery(source, m), "\(source)")
            #expect(!g.items.isEmpty, "\(source)")
            #expect(!g.inline.isEmpty && g.inline.allSatisfy { id in g.items.contains { $0.id == id } }, "\(source)")
            #expect(Set(g.items.map(\.id)).count == g.items.count, "\(source) repeats an item")
            #expect(g.sections.flatMap(\.items) == g.items, "\(source)'s sections keep every item in order")
        }
        #expect(RibbonGalleries.gallery("nothing", m) == nil)
        let tr = try #require(RibbonGalleries.gallery("transitions", m))
        #expect(tr.items.count == DCModel.transitions.count && tr.selected == "none")
        #expect(tr.items.allSatisfy { $0.command.id == "transition.set" && $0.command.params["kind"]?.asStr == $0.id })
        let an = try #require(RibbonGalleries.gallery("animations", m))
        #expect(an.inline.first == "entrance:appear" && an.sections.count == 4)
        #expect(an.items.allSatisfy { $0.command.id == "animation.set" && "\($0.command.params["class"]?.asStr ?? ""):\($0.command.params["effect"]?.asStr ?? "")" == $0.id })
        let ts = try #require(RibbonGalleries.gallery("tableStyles", m))
        #expect(ts.inline.prefix(2) == ["none", "grid"] && ts.inline.dropFirst(2).allSatisfy { $0.hasPrefix("medium2") })
        let sa = try #require(RibbonGalleries.gallery("smartArtLayouts", m))
        #expect(sa.selected == "list" && sa.items.count == SmartArtCommands.layouts.count)
        let gid = try #require(m.session.activeDoc?.selection.shapes.first)
        #expect(sa.items.allSatisfy { $0.command.params["id"]?.asU64 == UInt64(gid.rawValue) })
        let st = try #require(RibbonGalleries.gallery("smartArtStyles", m))
        #expect(st.selected == "flat")
    }

    // "The theme gallery renders the same tiles as the start screen": its tiles are the start window's theme tiles.
    @Test func theThemeGalleryIsTheStartWindowsTiles() throws {
        let m = try Self.model(.shape)
        let g = try #require(RibbonGalleries.gallery("themes", m))
        let start = StartCatalog.themeTiles("").filter { $0.kind == .theme }.map(\.id)
        #expect(g.items.map(\.art) == start.map { .startTile($0) })
        #expect(g.selected == m.session.activeDoc?.doc.masters.first?.theme.name)
        // The start window's renderer draws each of them.
        #expect(StartCatalog.newParams(start.first ?? "") != nil)
    }

    // "Choosing a gallery item is one undo step."
    @Test func aGalleryPickIsOneUndoStep() throws {
        let cases: [(Kind, String)] = [
            (.shape, "themes"), (.shape, "variants"), (.shape, "transitions"), (.shape, "animations"), (.shape, "quickStyles"),
            (.table, "tableStyles"), (.picture, "pictureStyles"), (.smartArt, "smartArtLayouts"), (.smartArt, "smartArtStyles"),
        ]
        for (kind, source) in cases {
            let m = try Self.model(kind)
            let g = try #require(RibbonGalleries.gallery(source, m))
            // A tile other than the current one, so the pick changes something.
            let item = try #require(g.items.first { $0.id != g.selected && $0.id != "none" }, "\(source)")
            let before = m.session.activeDoc?.history.undo.count ?? 0
            let r = m.run(item.command.id, item.command.params)
            if case .failure(let e) = r { Issue.record("\(source) \(item.id): \(e.message)") }
            #expect((m.session.activeDoc?.history.undo.count ?? 0) == before + 1, "\(source) \(item.id)")
            m.run("edit.undo")
            #expect((m.session.activeDoc?.history.undo.count ?? 0) == before, "\(source) undoes in one step")
        }
    }

    /// The object each contextual tab is for.
    static let tabKind: [String: Kind] = [
        "shapeFormat": .shape, "pictureFormat": .picture, "tableDesign": .table, "tableLayout": .table, "chartDesign": .chart,
        "smartArtDesign": .smartArt, "playback": .media, "slideMaster": .slideMaster, "notesMaster": .notesMaster, "handoutMaster": .handoutMaster,
    ]

    /// Commands a contextual tab shows that need more than its object selected; they fail with that reason.
    static let needsState = [
        "table.merge": "a range of cells", "table.split": "a merged cell", "smartArt.promote": "a line below the top level",
        "smartArt.demote": "a line with one above it", "master.deleteLayout": "a layout, not the master",
        "arrange.regroup": "a group ungrouped before", "picture.removeBackground": "a picture whose edges are its background",
    ]

    // R2, as R1's walk: every contextual control runs its command with deckcraft's parameters, with the object its
    // tab is for selected. A command the ribbon shows enabled must succeed.
    @Test func everyContextualControlRunsItsCommand() throws {
        var ran = 0, skipped: [String] = []
        for tab in RibbonLayout.contextualTabs {
            let kind = try #require(Self.tabKind[tab.id], "\(tab.id)")
            let probe = try Self.model(kind)
            #expect(RibbonModel.tabs(probe).contains { $0.id == tab.id }, "\(tab.id) shows for a \(kind)")
            for g in tab.groups {
                for c in g.controls {
                    let refs = RibbonModelTests.invocations(c, probe)
                    #expect(!refs.isEmpty, "\(c.id) runs nothing")
                    for r in refs {
                        if r.id.hasPrefix("tool.") {
                            let pen = InspectorShape.pens.at(Int(r.params["pen"]?.asU64 ?? 99)) != nil
                            #expect(r.id == "tool.select" || (r.id == "tool.ink" && pen) || (r.id == "tool.shape" && r.params["preset"]?.asStr != nil), "\(c.id)")
                            continue
                        }
                        if r.id == "app.dialog" {
                            #expect(DialogCatalog.ids.contains(r.params["id"]?.asStr ?? ""), "\(c.id): dialog \(r.params)")
                            continue
                        }
                        let m = try Self.model(kind)
                        guard RibbonModel.enabled(r.id, m.session) else {
                            skipped.append("\(c.id) → \(r.id)")
                            continue
                        }
                        if case .failure(let e) = m.run(r.id, r.params), Self.needsState[r.id] == nil {
                            Issue.record("\(c.id) → \(r.id) \(r.params): \(e.message)")
                        }
                        ran += 1
                    }
                }
            }
        }
        #expect(ran > 250, "only \(ran) ran; skipped \(skipped)")
        #expect(skipped.count < 20, "\(skipped)")
    }

    // The check boxes read the object: a table's style options, a clip's playback, a master's placeholders.
    @Test func checkBoxesReadTheirObject() throws {
        let t = try Self.model(.table)
        let header = try #require(RibbonLayout.control("tableDesign.headerRow"))
        let on = RibbonModel.isChecked(header, t)
        t.run("table.options", ["headerRow": .bool(!on)])
        #expect(RibbonModel.isChecked(header, t) == !on)
        let media = try Self.model(.media)
        let loop = try #require(RibbonLayout.control("playback.loop"))
        #expect(!RibbonModel.isChecked(loop, media))
        media.run(RibbonModel.check(loop, true).id, RibbonModel.check(loop, true).params)
        #expect(RibbonModel.isChecked(loop, media))
        let master = try Self.model(.slideMaster)
        let title = try #require(RibbonLayout.control("slideMaster.title"))
        let had = RibbonModel.isChecked(title, master)
        master.run("master.placeholders", ["title": .bool(!had)])
        #expect(RibbonModel.isChecked(title, master) == !had)
        let notes = try Self.model(.notesMaster)
        let body = try #require(RibbonLayout.control("notesMaster.body"))
        let hadBody = RibbonModel.isChecked(body, notes)
        notes.run("notes.placeholders", ["body": .bool(!hadBody)])
        #expect(RibbonModel.isChecked(body, notes) == !hadBody)
        // Slides Per Page is the handout's UI state, through its own command.
        let handout = try Self.model(.handoutMaster)
        handout.run("view.handoutSlides", ["count": 3])
        #expect(handout.ui.handoutPerPage == 3)
        let perPage = try #require(RibbonLayout.control("handoutMaster.perPage"))
        #expect(RibbonModel.label(perPage).hasPrefix("Slides Per Page"))
        if case .success = handout.run("view.handoutSlides", ["count": 5]) { Issue.record("5 slides a page isn't a handout layout") }
    }

    // Height and Width show the first selected shape's size in the Preferences unit and set it in points.
    @Test func sizeSpinnersUseThePreferencesUnit() throws {
        let m = try Self.model(.shape)
        let h = try #require(RibbonLayout.control("shapeFormat.height"))
        m.session.prefs.units = .inches
        #expect(RibbonModel.spinnerValue(h, "h", m).map { ($0 * 1000).rounded() / 1000 } == (100.0 / 72 * 1000).rounded() / 1000)
        #expect(RibbonModel.spinnerFormat(h, m).suffix == "\"" && RibbonModel.spinnerFormat(h, m).step == 0.1)
        let set = RibbonModel.spin(h, "h", 2, units: .inches)
        #expect(set.params["h"]?.asF64 == 144)
        m.run(set.id, set.params)
        #expect(RibbonModel.spinnerValue(h, "h", m) == 2)
        m.session.prefs.units = .centimeters
        #expect(RibbonModel.spinnerFormat(h, m).suffix == " cm")
        #expect(RibbonModel.spin(h, "h", -1, units: .points).params["h"]?.asF64 == 0)
        #expect(RibbonModel.spin(h, "h", .infinity, units: .points).params["h"]?.asF64 == 0)
        let none = try Self.model(.chart)
        none.run("edit.select", ["ids": []])
        #expect(RibbonModel.spinnerValue(h, "h", none) == nil, "nothing selected: no value")
    }

    // The tiles DCRender draws: a table style and a SmartArt layout come out as pictures.
    @Test func tileArtRenders() throws {
        let m = try Self.model(.smartArt)
        let pres = try #require(m.session.activeDoc?.doc)
        for art: RibbonGalleryItem.Art in [.tableStyle("medium2-accent1"), .smartArt(kind: "process", style: "", colors: ""), .smartArt(kind: "orgChart", style: "polished", colors: "accent2")] {
            let png = try #require(RibbonTileArt.png(art, pres, slide: 0, width: 132), "\(art)")
            #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(art)")
        }
        #expect(RibbonTileArt.png(.quickStyle(3), pres, slide: 0, width: 80) == nil, "the view draws the others")
        #expect(RibbonTileArt.png(.tableStyle("grid"), pres, slide: 99, width: .max) != nil, "a slide out of range and a huge width are bounded")
    }
}
