// DCEngineTests — the command registry: the params-doc grammar, colour params, base64, the registry's
// order and text against the oracle's `commands.txt`, and every command surviving hostile parameters.
// Ports the tests of deckcraft crates/engine/src/cmd/mod.rs and the registry tests of tests.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
@testable import DCEngine
import DCModel
import DCTestSupport
import Foundation
import Testing

@Suite("Registry")
struct RegistryTests {
    @Test func thePaletteSkipsACommandThatNeedsAValue() {
        #expect(Cmd.needsArguments("{path}"))
        #expect(Cmd.needsArguments("{path, format: png|jpeg|pptx, slide?: index}"))
        #expect(Cmd.needsArguments("{path? | data: base64, name?, rect?}"))
        #expect(Cmd.needsArguments("{rows, cols, rect?}"))
        #expect(Cmd.needsArguments("{axis: horizontal|vertical, ids?}"))
        #expect(Cmd.needsArguments("{percent}"))
        #expect(!Cmd.needsArguments("{}"))
        #expect(!Cmd.needsArguments("{on?: bool}"))
        #expect(!Cmd.needsArguments("{theme?: name, size?: [w,h] pt, blank?: bool}"))
        #expect(!Cmd.needsArguments("{uid?: one entry, else all}"))
        #expect(!Cmd.needsArguments("{locked?: bool (default: toggle), ids?}"))
        #expect(!Cmd.needsArguments("{} → [{name, label, category}]"))
        #expect(!Cmd.needsArguments("{title?, subject?} → properties"))
        #expect(!Cmd.needsArguments("{slides?: [index] | \"1-3,5\", includeHidden?}"))
        let export = findCommand("file.export")
        let save = findCommand("file.save")
        #expect(export.map { Cmd.needsArguments($0.params) } == true)
        #expect(save.map { Cmd.needsArguments($0.params) } == false)
    }

    @Test(.enabled(if: ported("insert.audio"))) func theAudioCommandNeedsAValue() {
        #expect(findCommand("insert.audio").map { Cmd.needsArguments($0.params) } == true)
    }

    @Test func presetAndSystemColorsKeepTheirBase() {
        let preset = Cmd.colorValue(j(#"{"preset": "red", "lumMod": 50000}"#))
        #expect(preset == ColorRef(base: .preset(name: "red"), mods: [.lumMod(50_000)]))
        let system = Cmd.colorValue(j(##"{"system": "windowText", "last": "#123456"}"##))
        #expect(system == ColorRef(base: .system(name: "windowText", last: .rgb(0x12, 0x34, 0x56)), mods: []))
        #expect(Cmd.colorValue(j(#"{"system": "windowText"}"#)) == nil, "a system color needs its last value")
        #expect(Cmd.colorValue(j(#"{"preset": "notAColor"}"#)) == nil)
        #expect(Cmd.colorValue(j(##"{"system": "notAColor", "last": "#000000"}"##)) == nil)
        for name in ["aliceBlue", "darkBlue", "ltSlateGrey"] {
            #expect(Cmd.colorValue(["preset": .string(name)]) != nil, "\(name)")
        }
        #expect(Cmd.colorValue(j(##"{"system": "3dDkShadow", "last": "#000000"}"##)) != nil)
    }

    @Test func colourModsFollowSerdesSortedMapOrder() {
        // serde_json's map is a BTreeMap: the transforms come in key order, not as written.
        let c = Cmd.colorValue(j(#"{"scheme": "accent1", "lumOff": 20000, "lumMod": 60000, "alpha": 50000}"#))
        #expect(c?.mods == [.alpha(50_000), .lumMod(60_000), .lumOff(20_000)])
        #expect(Cmd.colorValue("accent2") == .scheme(.accent2))
        #expect(Cmd.colorValue("#FF8000") == .rgb(.rgb(255, 128, 0)))
        #expect(Cmd.colorValue(5) == nil)
    }

    @Test func everyCommandIdIsRegisteredOnce() {
        var seen = Set<String>()
        let dups = CommandSpecs.all.map(\.id).filter { !seen.insert($0).inserted }
        #expect(dups.isEmpty, "registered more than once: \(dups)")
    }

    @Test func everyParamsDocNamesItsKeys() throws {
        for c in CommandSpecs.all {
            #expect((try? Cmd.paramKeys(c.params)) != nil, "\(c.id)")
        }
        #expect(try Cmd.paramKeys("{index} | {id}") == ["index", "id"])
        #expect(try Cmd.paramKeys("{color? | none?: true, kind?: a|b (x, y), ids?} → {id}") == ["color", "none", "kind", "ids"])
    }

    @Test func aParamsDocSpellsOutEachParameter() throws {
        func p(_ name: String, _ optional: Bool, _ about: String, _ or: Bool, _ object: Int) -> Param {
            Param(name: name, optional: optional, about: about, or: or, object: object)
        }
        #expect(try Cmd.parseParams("{preset: rect|roundRect, rect?: [x,y,w,h] pt, index? (else selected shapes)} → {id}") == [
            p("preset", false, "rect|roundRect", false, 0),
            p("rect", true, "[x,y,w,h] pt", false, 0),
            p("index", true, "(else selected shapes)", false, 0),
        ])
        #expect(try Cmd.parseParams("{color? | none?: true, gradient?: {stops, kind?: a|b}, ids?}") == [
            p("color", true, "", false, 0),
            p("none", true, "true", true, 0),
            p("gradient", true, "{stops, kind?: a|b}", false, 0),
            p("ids", true, "", false, 0),
        ])
        #expect(try Cmd.parseParams("{name} | {major, minor}") == [p("name", false, "", false, 0), p("major", false, "", false, 1), p("minor", false, "", false, 1)])
        #expect(throws: ParamDocError.self) { try Cmd.parseParams("{9lives}") }
        #expect(throws: ParamDocError.self) { try Cmd.parseParams("{name! oops}") }
    }

    @Test func whatACommandActsOnNamesOnlyKeysItTakes() throws {
        for c in CommandSpecs.all {
            let keys = try Cmd.paramKeys(c.params)
            let said = c.actsOn() ?? ""
            #expect(!said.contains("`ids`") || keys.contains("ids"), "\(c.id): \(said)")
            #expect(!said.contains("`id`") || keys.contains("id"), "\(c.id): \(said)")
        }
        #expect(findCommand("slide.new")?.actsOn() == nil)
        #expect(findCommand("edit.duplicate")?.actsOn() == "Acts on the shapes in `ids`, else on the selected shapes.")
        #expect(findCommand("edit.undo")?.actsOn() == nil)
    }

    @Test(.enabled(if: ported("shape.resize", "table.style", "shape.setDefault", "format.size")))
    func whatTheShapeCommandsActOn() {
        let acts = { (id: String) in findCommand(id)?.actsOn() }
        #expect(acts("shape.resize") == "Acts on the shapes in `ids`, else on the selected shapes.")
        #expect(acts("table.style") == "Acts on the shape in `id`, else on the selected shapes.")
        #expect(acts("shape.setDefault") == "Acts on the selected shapes.")
        #expect(acts("format.size") == "Acts on the selected text or shapes.")
    }

    @Test func base64RoundTrip() {
        for data in [[], [0], [1, 2], [1, 2, 3], Array(0 ... 255)] as [[UInt8]] {
            #expect(Cmd.base64Decode(Cmd.base64Encode(data)) == data)
        }
        #expect(Cmd.base64Decode("!!") == nil)
        #expect(Cmd.base64Encode(Array("Man".utf8)) == "TWFu")
        #expect(Cmd.base64Encode(Array("Ma".utf8)) == "TWE=")
        #expect(Cmd.base64Decode("data:image/png;base64,TWFu") == Array("Man".utf8))
    }

    /// Every registered command, in order, with the label and params deckcraft-cli's `commands` prints.
    @Test(.enabled(if: Fixtures.oracleCorpus != nil, "no oracle corpus: run Tools/oracle/oracle.sh corpus"))
    func theRegistryMatchesTheOraclesCommandList() throws {
        let corpus = try #require(Fixtures.oracleCorpus)
        let text = try String(contentsOf: corpus.appending(path: "commands.txt"), encoding: .utf8)
        let oracle = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        func line(_ c: CommandSpec) -> String {
            c.params.hasPrefix("{}") ? "\(c.id) — \(c.label)\(c.params.dropFirst(2))" : "\(c.id) — \(c.label): \(c.params)"
        }
        let ours = CommandSpecs.all.map(line)
        // Ours, in order, are the oracle's lines with the unported modules' lines left out.
        let registered = Set(CommandSpecs.all.map(\.id))
        let expected = oracle.filter { l in registered.contains(String(l.prefix { $0 != " " })) }
        #expect(ours == expected)
        #expect(ours.count <= oracle.count)
        let waiting = oracle.count - ours.count
        if waiting > 0 { print("registry: \(ours.count) of \(oracle.count) commands registered; \(waiting) wait for their modules") }
    }

    /// No command traps or leaves an invalid deck on empty or hostile parameters (deckcraft runs this on
    /// the sample; here on the corpus's copy of it, so it needs no unported command to build it).
    @Test(.enabled(if: Fixtures.oracleCorpus != nil, "no oracle corpus: run Tools/oracle/oracle.sh corpus"))
    func everyCommandSurvivesEmptyAndHostileParams() throws {
        let corpus = try #require(Fixtures.oracleCorpus)
        let s = Session()
        _ = try s.execute("file.open", ["path": .string(corpus.appending(path: "decks/sample.deckcraft").path)])
        let first = try #require(s.st.currentSlide?.shapes.first?.id)
        _ = try s.execute("edit.select", ["ids": [first.toJSON()]])
        let skip: Set<String> = ["file.close", "file.open", "file.save", "file.saveAs", "file.export", "file.saveTemplate"]
        let ids = CommandSpecs.all.map(\.id).filter { !skip.contains($0) }
        for p in [j("{}"), .null, j("[1, 2]"), j(#"{"index": 99999, "ids": [999999], "id": -1, "text": "x", "rect": "bad", "color": 5, "size": 1e308}"#)] {
            for id in ids { _ = try? s.execute(id, p) }
        }
        #expect(s.activeDoc != nil)
        for d in s.documents { #expect(d.doc.validate().isEmpty, "\(d.doc.validate())") }
    }

    @Test(.enabled(if: ported(Sample.commands)))
    func everyCommandSurvivesHostileParamsOnTheSample() throws {
        let s = Session()
        try Sample.openSample(s)
        let first = try #require(s.st.currentSlide?.shapes.first?.id)
        _ = try s.execute("edit.select", ["ids": [first.toJSON()]])
        let skip: Set<String> = ["file.close", "file.open", "file.save", "file.saveAs", "file.export", "file.saveTemplate"]
        for p in [j("{}"), .null, j("[1, 2]"), j(#"{"index": 99999, "ids": [999999], "id": -1, "text": "x", "rect": "bad", "color": 5, "size": 1e308}"#)] {
            for id in CommandSpecs.all.map(\.id) where !skip.contains(id) { _ = try? s.execute(id, p) }
        }
        #expect(s.activeDoc != nil)
        for d in s.documents { #expect(d.doc.validate().isEmpty, "\(d.doc.validate())") }
    }

    @Test func unknownAndDisabledCommandsAreErrors() {
        let s = Session()
        #expect(throws: EngineError.unknownCommand("no.such")) { try s.execute("no.such", .null) }
        #expect(throws: EngineError.disabled("edit.undo", "nothing to undo")) { try s.execute("edit.undo", .null) }
        #expect(throws: EngineError.disabled("slide.new", "no presentation open")) { try s.execute("slide.new", .null) }
        #expect(EngineError.badParams(cmd: "x", msg: "y").description == "invalid parameters for `x`: y")
        #expect(EngineError.disabled("a", "b").description == "command `a` is not available right now: b")
    }

    @Test func aNamedShapeSkipsTheSelectionCheck() throws {
        let s = session()
        // Nothing selected: Duplicate is disabled…
        #expect(throws: EngineError.disabled("edit.duplicate", Cmd.nothingSelected)) { try s.execute("edit.duplicate", .emptyObject) }
        // …unless the shapes are named.
        let title = try #require(s.st.currentSlide?.shapes.first?.id)
        let r = try s.execute("edit.duplicate", ["ids": [title.toJSON()]])
        #expect(r.get("ids")?.asArray?.count == 1)
    }

    @Test func theJournalKeepsOuterCommandsOnly() throws {
        let s = session()
        s.run("slide.new")
        s.run("document.inspect")
        s.run("slide.go", #"{"index": 0}"#)
        #expect(s.journal.map(\.0) == ["file.new", "slide.new", "slide.go"])
    }
}
