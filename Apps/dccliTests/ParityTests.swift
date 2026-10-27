// dccliTests — `dccli` is deckcraft-cli, command for command: the built binary run beside the pinned
// oracle (`Tools/oracle/oracle.sh build`) and against the oracle corpus. Tests that need the oracle skip
// when it isn't built; those that need the corpus or the engine vectors skip without them.
import CoreGraphics
import DCCore
import DCEngine
import DCRender
import DCTestSupport
import Foundation
import Testing

/// SSIMULACRA2 floors for pictures scored at 480 pixels wide. Slides and transition frames come from the same
/// renderer DCRender checks at full size (floor 88); PDF pages are our vector pages drawn at 2 px/pt against the
/// oracle's slide pictures (its PDF holds those pictures at 200 dpi).
let renderFloor = 85.0
let pdfFloor = 85.0

@Suite("dccli is deckcraft-cli", .enabled(if: Binaries.haveDccli, "dccli isn't built"))
struct ParityTests {
    // MARK: commands, describe, help

    @Test("`commands` is the corpus's commands.txt", .enabled(if: Fixtures.oracleCorpus != nil, "no oracle corpus"))
    func commandsList() throws {
        let corpus = try #require(Fixtures.oracleCorpus)
        let r = try dccli(["commands"])
        #expect(r.code == 0)
        let want = try Data(contentsOf: corpus.appending(path: "commands.txt"))
        #expect(r.out == want, "\(firstDifference([UInt8](r.out), [UInt8](want)))")
        #expect(r.stdout.split(separator: "\n").count == commandSpecs().count)
    }

    @Test("`describe` of every command is the oracle's", .enabled(if: Binaries.haveOracle, "the oracle isn't built"))
    func describeEveryCommand() async throws {
        let ids = commandSpecs().map(\.id)
        #expect(ids.count == 330)
        let bad = try await withThrowingTaskGroup(of: String?.self) { group in
            for chunk in stride(from: 0, to: ids.count, by: 30).map({ Array(ids[$0 ..< min($0 + 30, ids.count)]) }) {
                group.addTask {
                    for id in chunk {
                        let (a, b) = (try dccli(["describe", id]), try oracle(["describe", id]))
                        if a.out != b.out || a.code != b.code { return "\(id):\n\(a.stdout)\n---\n\(b.stdout)" }
                    }
                    return nil
                }
            }
            var out: [String] = []
            for try await r in group { if let r { out.append(r) } }
            return out
        }
        #expect(bad.isEmpty, "\(bad.joined(separator: "\n"))")
    }

    @Test("Help, version, links and usage errors are the oracle's", .enabled(if: Binaries.haveOracle, "the oracle isn't built"), arguments: [
        [], ["--version"], ["-V"], ["version"], ["help"], ["--help"], ["-h"], ["help", "run"], ["help", "nope"], ["links"], ["bogus"], ["--sample"],
        ["render", "--help"], ["run", "--cmd", "x", "-h"], ["info", "--help"], ["convert", "-h"], ["describe", "--help"], ["mcp", "-h"],
        ["app", "--help"], ["bench", "--help"], ["render-transition", "--help"], ["commands", "--help"], ["help", "version"], ["help", "-V"],
        ["commands", "FORMAT.B"], ["commands", "Picture"], ["commands", "nothing-matches-this"],
    ])
    func helpAndUsage(_ args: [String]) throws {
        let (a, b) = (try dccli(args), try oracle(args))
        #expect(a.code == b.code, "\(args): exit \(a.code), the oracle's \(b.code)")
        #expect(a.stdout == b.stdout, "\(args): stdout\n\(a.stdout)\n---\n\(b.stdout)")
        #expect(a.stderr == b.stderr, "\(args): stderr\n\(a.stderr)\n---\n\(b.stderr)")
    }

    /// Bad input: the same message on stderr and the same exit code.
    @Test("Errors and exit codes on bad input are the oracle's", .enabled(if: Binaries.haveOracle && Fixtures.oracleCorpus != nil, "the oracle isn't built"), arguments: [
        ["info"], ["info", "/nonexistent/deck.deckcraft"], ["info", "/etc/hosts"], ["info", "/tmp"],
        ["render"], ["render", "--sample"], ["render", "--sample", "--scael", "2", "o.png"], ["render", "--sample", "-x", "o.png"],
        ["render", "--sample", "--slide"], ["render", "--sample", "--slide", "x", "o.png"], ["render", "--sample", "--slide", "-1", "o.png"],
        ["render", "--sample", "--slide", "99", "<scratch>/o.png"], ["render", "--sample", "--scale", "big", "o.png"],
        ["render", "--sample", "<scratch>/missing/o.png"], ["render", "--sample", "--all", "/dev/null/x"],
        ["render-transition"], ["render-transition", "<deck>"], ["render-transition", "<deck>", "o.png"],
        ["render-transition", "<deck>", "--slide", "1", "o.png"], ["render-transition", "<deck>", "--slide", "1", "--t", "a", "o.png"],
        ["render-transition", "<deck>", "--slide", "1", "--t", "inf", "o.png"], ["render-transition", "<deck>", "--slide", "1", "--t", "0.1001,0.1002", "o.png"],
        ["render-transition", "<deck>", "--slide", "99", "--t", "0.5", "<scratch>/o.png"], ["render-transition", "<deck>", "--width", "0"],
        ["render-transition", "<deck>", "--t"], ["render-transition", "<deck>", "--slide", "1", "--t", "0.5", "<scratch>/no/o.png"],
        ["convert"], ["convert", "a"], ["convert", "a", "b.docx"], ["convert", "a", "b"], ["convert", "/nonexistent.deckcraft", "<scratch>/b.pptx"],
        ["convert", "<deck>", "<scratch>/missing/b.pptx"],
        ["run", "--bogus"], ["run", "--in"], ["run", "--cmd"], ["run", "--save"], ["run", "--export"], ["run", "--export-params"],
        ["run", "--export-params", "{bad"], ["run", "--export-params", "[1]"], ["run", "--save", "x.docx"], ["run", "--export", "x"],
        ["run", "--cmd", "slide.new={bad"], ["run", "--cmd", "no.such"], ["run", "--cmd", "slide.go={\"index\":9}"],
        ["run", "--cmd", "slide.new=[]"], ["run", "--in", "/nonexistent.pptx"], ["run", "--sample", "--export-params", "{\"width\":64}"],
        ["run", "--sample", "--export", "<scratch>/bad.gif", "--export-params", "{\"width\": 1e9}"],
        ["run", "--cmd", "file.open={\"path\":\"/nonexistent.deckcraft\"}"],
        ["describe"], ["describe", "no.such"],
        ["app", "--port"], ["app", "--method"], ["app", "--port", "1", "slide.new"], ["app", "--port", "nohost", "x"], ["app", "--port", "h:x", "x"],
        ["mcp", "--bogus"], ["mcp", "--connect"], ["mcp", "--connect", "1"], ["mcp", "--automation-read-root"], ["mcp", "--automation-read-root", "-x"],
        ["mcp", "--automation-read-root="], ["mcp", "--automation-read-root=/a", "--automation-read-root=/b"],
        ["mcp", "--automation-read-root", "/nonexistent-root"], ["mcp", "--automation-write-root", "/etc/hosts"],
        ["mcp", "--automation-read-root", "/tmp", "--connect", "1"],
        ["bench"], ["bench", "--runs", "0", "--sample"], ["bench", "--runs"], ["bench", "--bogus"], ["bench", "/nonexistent.deckcraft"],
    ])
    func badInput(_ raw: [String]) throws {
        let dir = scratch("bad")
        defer { try? FileManager.default.removeItem(at: dir) }
        let deck = try #require(Corpus.decks).appending(path: "content.deckcraft").path
        let args = raw.map { $0.replacingOccurrences(of: "<scratch>", with: dir.path).replacingOccurrences(of: "<deck>", with: deck) }
        let (a, b) = (try dccli(args, cwd: dir), try oracle(args, cwd: dir))
        #expect(a.code == b.code, "\(args): exit \(a.code), the oracle's \(b.code)\n\(a.stderr)\n---\n\(b.stderr)")
        #expect(a.stderr == b.stderr, "\(args): stderr\n\(a.stderr)\n---\n\(b.stderr)")
        #expect(a.stdout == b.stdout, "\(args): stdout\n\(a.stdout)\n---\n\(b.stdout)")
    }

    // MARK: Scripts

    /// One `run` of `script` with `--print --save`: its answers and saved deck.
    private func runScript(_ script: CommandScript, save: URL) throws -> Ran {
        try dccli(["run"] + script.inArgs + script.cmdArgs() + ["--print", "--save", save.path])
    }

    /// Each refusal run as `oracle.sh engine-vectors` runs it: the commands before it, then it; `id=json\tmessage`.
    private func refusals(_ script: CommandScript) throws -> [String] {
        var out: [String] = []
        for (k, l) in script.lines.enumerated() where l.refused {
            let r = try dccli(["run"] + script.inArgs + script.cmdArgs(before: k) + ["--cmd", l.line])
            var err = r.stderr
            while err.hasSuffix("\n") { err.removeLast() }
            if err.hasPrefix("deckcraft-cli: ") { err.removeFirst("deckcraft-cli: ".count) }
            out.append(r.code == 0 ? "\(l.line)\tsucceeded" : "\(l.line)\t\(err)")
        }
        return out
    }

    private func expectedLines(_ name: String, _ ext: String) -> [String]? {
        (try? String(contentsOf: Corpus.engineVectors.appending(path: "\(name).\(ext)"), encoding: .utf8))?.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    @Test("Every engine script gives the oracle's answers, refusals and deck", .enabled(if: Corpus.haveVectors, "no engine vectors or corpus"), arguments: engineScripts)
    func engineScript(_ script: CommandScript) throws {
        guard let want = expectedLines(script.name, "results.txt") else { try Test.cancel("no oracle answers for \(script.name)") }
        let dir = scratch("script")
        defer { try? FileManager.default.removeItem(at: dir) }
        let save = dir.appending(path: "\(script.name).deckcraft")
        let r = try runScript(script, save: save)
        #expect(r.code == 0, "\(script.name): exit \(r.code): \(r.stderr)")
        #expect(r.stderr.isEmpty, "\(script.name): \(r.stderr)")
        let got = r.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(got.count == want.count, "\(script.name): \(got.count) answers, the oracle printed \(want.count)")
        let saved = try readBytes(save)
        let oracleDeck = try readBytes(Corpus.engineVectors.appending(path: "\(script.name).deckcraft"))
        let native = script.name.contains("-native-")
        if script.name.hasPrefix("text-native-") {
            for (i, (g, w)) in zip(got, want).enumerated() { compareTextNative(script.name, i, g, w) }
            let (a, b) = (try presentationJSON(saved), try presentationJSON(oracleDeck))
            #expect(a == b, "\(script.name): presentation \(firstDifference(a, b))")
        } else if script.name.hasPrefix("shapes-native-") {
            var diff = StructuralDiff()
            for (i, (g, w)) in zip(got, want).enumerated() {
                let (gid, gj) = answer(g), (wid, wj) = answer(w)
                #expect(gid == wid, "\(script.name) line \(i + 1)")
                if let gj, let wj { compareStructurally(gj, wj, "\(script.name) answer \(i + 1)", &diff) }
            }
            compareStructurally(try JSONParser.parse(presentationJSON(saved)), try JSONParser.parse(presentationJSON(oracleDeck)), "\(script.name) deck", &diff)
            for p in diff.problems { Issue.record("\(p)") }
            #expect(diff.worstArea <= 1e-3)
        } else if script.name.hasPrefix("insert-native-") {
            for (i, (g, w)) in zip(got, want).enumerated() {
                let (gid, gj) = answer(g), (wid, wj) = answer(w)
                #expect(gid == wid, "\(script.name) line \(i + 1)")
                let (a, b) = (gj.map(maskPictureBytes)?.display, wj.map(maskPictureBytes)?.display)
                if a != b { Issue.record("\(script.name) line \(i + 1):\n  ours:   \(a ?? g)\n  oracle: \(b ?? w)") }
            }
            let (a, b) = (try presentationJSON(saved), try presentationJSON(oracleDeck))
            #expect(a == b, "\(script.name): presentation \(firstDifference(a, b))")
            #expect(try pictureSizes(saved) == pictureSizes(oracleDeck), "\(script.name): picture sizes")
        } else {
            for (i, (g, w)) in zip(got, want).enumerated() where blankTimestamps(g) != blankTimestamps(w) {
                Issue.record("\(script.name) line \(i + 1):\n  ours:   \(g)\n  oracle: \(w)")
            }
            let (a, b) = (try presentationJSON(saved), try presentationJSON(oracleDeck))
            #expect(a == b, "\(script.name): presentation \(firstDifference(a, b))")
        }
        // Refused commands: the same message, as `deckcraft-cli run` prints it.
        let wantErrors = expectedLines(script.name, "errors.txt") ?? []
        let errors = try refusals(script)
        #expect(errors.count == wantErrors.count, "\(script.name): \(errors.count) refusals, the oracle recorded \(wantErrors.count)")
        for (i, (g, w)) in zip(errors, wantErrors).enumerated() where g != w {
            Issue.record("\(script.name) refusal \(i + 1):\n  ours:   \(g)\n  oracle: \(w)")
        }
        print("dccli script \(script.name)\(native ? " (native)" : ""): \(got.count) answers, \(errors.count) refusals compared")
    }

    @Test("Corpus scripts print the oracle's answers and make the corpus decks", .enabled(if: Binaries.haveOracle && Fixtures.oracleCorpus != nil, "the oracle isn't built"), arguments: corpusScripts)
    func corpusScript(_ script: CommandScript) throws {
        let dir = scratch("corpus")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ours, theirs) = (dir.appending(path: "ours.deckcraft"), dir.appending(path: "theirs.deckcraft"))
        let a = try dccli(["run"] + script.cmdArgs() + ["--print", "--save", ours.path])
        let b = try oracle(["run"] + script.cmdArgs() + ["--print", "--save", theirs.path])
        #expect(a.code == 0 && b.code == 0, "\(a.stderr)\(b.stderr)")
        let (x, y) = (a.stdout.components(separatedBy: "\n").map(blankTimestamps), b.stdout.components(separatedBy: "\n").map(blankTimestamps))
        #expect(x.count == y.count)
        for (i, (g, w)) in zip(x, y).enumerated() where g != w { Issue.record("\(script.name) line \(i + 1):\n  ours:   \(g)\n  oracle: \(w)") }
        let corpusDeck = try readBytes(try #require(Corpus.decks).appending(path: "\(script.name).deckcraft"))
        let (p, q) = (try presentationJSON(readBytes(ours)), try presentationJSON(corpusDeck))
        #expect(p == q, "\(script.name): presentation \(firstDifference(p, q))")
    }

    @Test("`run --sample --save` is the corpus's sample deck", .enabled(if: Fixtures.oracleCorpus != nil, "no oracle corpus"))
    func sampleDeck() throws {
        let dir = scratch("sample")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "sample.deckcraft")
        let r = try dccli(["run", "--sample", "--save", out.path])
        #expect(r.code == 0 && r.out.isEmpty && r.err.isEmpty)
        let (a, b) = (try presentationJSON(readBytes(out)), try presentationJSON(readBytes(try #require(Corpus.decks).appending(path: "sample.deckcraft"))))
        #expect(a == b, "sample: presentation \(firstDifference(a, b))")
    }

    // MARK: info, convert

    @Test("`info` is the corpus's info.json", .enabled(if: Fixtures.oracleCorpus != nil, "no oracle corpus"), arguments: Corpus.deckNames)
    func info(_ name: String) throws {
        let decks = try #require(Corpus.decks)
        let r = try dccli(["info", decks.appending(path: "\(name).deckcraft").path])
        #expect(r.code == 0)
        let want = try Data(contentsOf: decks.appending(path: "\(name).info.json"))
        #expect(r.out == want, "\(name): \(firstDifference([UInt8](r.out), [UInt8](want)))")
    }

    @Test("`convert` writes the corpus's .pptx, .md and .from-pptx.deckcraft", .enabled(if: Fixtures.oracleCorpus != nil, "no oracle corpus"), arguments: Corpus.deckNames)
    func convert(_ name: String) throws {
        let decks = try #require(Corpus.decks)
        let dir = scratch("convert")
        defer { try? FileManager.default.removeItem(at: dir) }
        // .deckcraft → .pptx: the same parts, byte for byte.
        let pptx = dir.appending(path: "\(name).pptx")
        var r = try dccli(["convert", decks.appending(path: "\(name).deckcraft").path, pptx.path])
        #expect(r.code == 0 && r.stdout == "\(pptx.path)\n", "\(r.stderr)")
        let (ours, theirs) = (try zipParts(readBytes(pptx)), try zipParts(readBytes(decks.appending(path: "\(name).pptx"))))
        #expect(Set(ours.keys) == Set(theirs.keys), "\(name).pptx parts")
        for (k, v) in theirs where ours[k] != v { Issue.record("\(name).pptx: part \(k) differs") }
        // .pptx → .deckcraft: the same presentation and media.
        let back = dir.appending(path: "\(name).from-pptx.deckcraft")
        r = try dccli(["convert", decks.appending(path: "\(name).pptx").path, back.path])
        #expect(r.code == 0, "\(r.stderr)")
        let oracleBack = try readBytes(decks.appending(path: "\(name).from-pptx.deckcraft"))
        let (a, b) = (try presentationJSON(readBytes(back)), try presentationJSON(oracleBack))
        #expect(a == b, "\(name).from-pptx: presentation \(firstDifference(a, b))")
        let (m, n) = (try zipParts(readBytes(back)), try zipParts(oracleBack))
        #expect(Set(m.keys) == Set(n.keys), "\(name).from-pptx parts")
        for (k, v) in n where k != "presentation.json" && m[k] != v { Issue.record("\(name).from-pptx: part \(k) differs") }
        // The outline.
        let md = dir.appending(path: "\(name).md")
        r = try dccli(["convert", decks.appending(path: "\(name).deckcraft").path, md.path])
        #expect(r.code == 0)
        #expect(try Data(contentsOf: md) == Data(contentsOf: decks.appending(path: "\(name).md")), "\(name).md")
    }

    @Test("`convert` to .pdf and .png draws what the oracle draws", .enabled(if: Fixtures.oracleCorpus != nil, "no oracle corpus"), arguments: Corpus.deckNames)
    func convertPictures(_ name: String) throws {
        let decks = try #require(Corpus.decks)
        let dir = scratch("pictures")
        defer { try? FileManager.default.removeItem(at: dir) }
        let deck = decks.appending(path: "\(name).deckcraft").path
        // PDF: the oracle's page count, each page drawn like the oracle's picture of that slide. deckcraft's pages
        // are those pictures at 200 dpi; ours are vectors, drawn here at the 2 px/pt of the corpus renders.
        let pdf = dir.appending(path: "\(name).pdf")
        var r = try dccli(["convert", deck, pdf.path])
        #expect(r.code == 0, "\(r.stderr)")
        let ours = pdfPages(pdf, scale: 2)
        let oracleCount = CGPDFDocument(decks.appending(path: "\(name).pdf") as CFURL)?.numberOfPages ?? -1
        #expect(ours.count == oracleCount && !ours.isEmpty, "\(name).pdf: \(ours.count) pages, the oracle's \(oracleCount)")
        var worst = 100.0
        for (i, a) in ours.enumerated() {
            let slide = decks.appending(path: "\(name).render/slide-\(i + 1 < 10 ? "0" : "")\(i + 1).png")
            guard let b = RenderParity.load(slide), let s = reducedScore(ours: a, oracle: b) else {
                Issue.record("\(name).pdf page \(i + 1): no slide picture of its size")
                continue
            }
            worst = min(worst, s)
            if name == "effects" && i == 2 {
                // DCRender's PDF keeps an 8 px gradient picture at its own size (/Interpolate true), and
                // CoreGraphics, drawing the page, magnifies it in soft blocks (DCRender's PORT-NOTES: the raster
                // canvas enlarges such pictures first; PDF output keeps the original).
                withKnownIssue("small pictures in a vector PDF are magnified in blocks by CoreGraphics") {
                    #expect(s >= pdfFloor, "\(name).pdf page \(i + 1): SSIMULACRA2 \(s)")
                }
            } else {
                #expect(s >= pdfFloor, "\(name).pdf page \(i + 1): SSIMULACRA2 \(s)")
            }
        }
        // PNG: the first slide, as `render` draws it.
        let png = dir.appending(path: "\(name).png")
        r = try dccli(["convert", deck, png.path])
        #expect(r.code == 0, "\(r.stderr)")
        let a = try #require(RenderParity.load(png)), b = try #require(RenderParity.load(decks.appending(path: "\(name).render/slide-01.png")))
        let s = try #require(reducedScore(ours: a, oracle: b), "\(name).png: \(a.width)×\(a.height), the oracle's \(b.width)×\(b.height)")
        #expect(s >= renderFloor, "\(name).png: SSIMULACRA2 \(s)")
        print("dccli convert \(name): \(ours.count) PDF pages, worst SSIMULACRA2 \(worst); PNG \(s)")
    }

    @Test("`render --all` and `render-transition` draw what the oracle drew", .enabled(if: Fixtures.oracleCorpus != nil, "no oracle corpus"), arguments: Corpus.deckNames)
    func render(_ name: String) throws {
        let decks = try #require(Corpus.decks)
        let dir = scratch("render")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "r")
        let r = try dccli(["render", decks.appending(path: "\(name).deckcraft").path, "--all", "--scale", "2", out.path])
        #expect(r.code == 0, "\(r.stderr)")
        let want = try FileManager.default.contentsOfDirectory(atPath: decks.appending(path: "\(name).render").path).filter { $0.hasSuffix(".png") }.sorted()
        let got = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        #expect(got == want)
        #expect(r.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }.count == want.count)
        var worst = 100.0
        for f in want {
            guard let a = RenderParity.load(out.appending(path: f)), let b = RenderParity.load(decks.appending(path: "\(name).render/\(f)")),
                  let s = reducedScore(ours: a, oracle: b) else {
                Issue.record("\(name) \(f): missing or a different size")
                continue
            }
            worst = min(worst, s)
            #expect(s >= renderFloor, "\(name) \(f): SSIMULACRA2 \(s)")
        }
        // Transitions: the frames oracle.sh drew, at 0.25, 0.5 and 0.75.
        let frames = decks.appending(path: "\(name).transitions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frames.path).filter { $0.hasSuffix(".png") }.sorted()) ?? []
        var slides = Set<Int>()
        for f in names {
            // slide-N-t0.250.png
            if let n = f.split(separator: "-").dropFirst().first.flatMap({ Int($0) }) { slides.insert(n) }
        }
        var tworst = 100.0
        for n in slides.sorted() {
            let base = dir.appending(path: "t/slide-\(n).png")
            try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
            let t = try dccli(["render-transition", decks.appending(path: "\(name).deckcraft").path, "--slide", "\(n - 1)", "--t", "0.25,0.5,0.75", base.path])
            #expect(t.code == 0, "\(t.stderr)")
            let o = try oracleTransitionLines(name, n, base)
            if let o { #expect(t.stdout == o, "\(name) slide \(n): \(t.stdout) vs \(o)") }
            for tt in ["0.250", "0.500", "0.750"] {
                let f = "slide-\(n)-t\(tt).png"
                guard let a = RenderParity.load(dir.appending(path: "t/\(f)")), let b = RenderParity.load(frames.appending(path: f)),
                      let s = reducedScore(ours: a, oracle: b) else {
                    Issue.record("\(name) \(f): missing or a different size")
                    continue
                }
                tworst = min(tworst, s)
                #expect(s >= renderFloor, "\(name) transition \(f): SSIMULACRA2 \(s)")
            }
        }
        print("dccli render \(name): \(want.count) slides, worst SSIMULACRA2 \(worst); \(slides.count) transitions, worst \(tworst)")
    }

    /// What the oracle prints for the same transition frames, written to the same paths (in a scratch
    /// folder of its own, then the folder named back), or nil without the oracle.
    private func oracleTransitionLines(_ name: String, _ n: Int, _ base: URL) throws -> String? {
        guard Binaries.oracle != nil, let decks = Corpus.decks else { return nil }
        let other = scratch("otrans")
        defer { try? FileManager.default.removeItem(at: other) }
        let o = try oracle(["render-transition", decks.appending(path: "\(name).deckcraft").path, "--slide", "\(n - 1)", "--t", "0.25,0.5,0.75", other.appending(path: "slide-\(n).png").path])
        return o.stdout.replacingOccurrences(of: other.path, with: base.deletingLastPathComponent().path)
    }
}
