// dccliTests — the command line's own tests, in process. Port of the tests in deckcraft
// apps/deckcraft-cli/src/main.rs and automation_args.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors).
import DCAutomation
import DCCore
@testable import dccli
import DCRender
import Foundation
import Testing

@Suite("deckcraft-cli main.rs")
struct CLITests {
    @Test func renderHelpPrintsUsageAndWritesNothing() {
        #expect((try? CLI.render(["--help"])) != nil)
        #expect((try? CLI.render(["-h"])) != nil)
        #expect(!FileManager.default.fileExists(atPath: "--help"))
    }

    @Test func renderRejectsUnknownFlag() {
        #expect(throws: CLIFailure("unknown option `--scael`")) { try CLI.render(["--sample", "--scael", "2", "out.png"]) }
        #expect(!FileManager.default.fileExists(atPath: "--scael"))
    }

    @Test func otherSubcommandsAcceptHelp() {
        #expect((try? CLI.info(["--help"])) != nil)
        #expect((try? CLI.convert(["-h"])) != nil)
        #expect((try? CLI.run(["--help"])) != nil)
        #expect((try? CLI.describe("--help")) != nil)
        #expect((try? CLI.mcp(["-h"])) != nil)
    }

    @Test func renderRefusesAnUnknownOptionInsteadOfWritingItAsAFile() {
        let out = FileManager.default.temporaryDirectory.appending(path: "deckcraft-cli-unknown-option.png").path
        try? FileManager.default.removeItem(atPath: out)
        for flag in ["--bogus", "-x"] {
            do {
                try CLI.render(["--sample", flag, out])
                Issue.record("\(flag): rendered")
            } catch {
                #expect(error.message.contains("unknown option `\(flag)`"), "\(flag): \(error)")
            }
            #expect(!FileManager.default.fileExists(atPath: out), "\(flag): rendered anyway")
        }
    }

    /// `render --transparent` leaves the slide background out (#784): the corner is transparent.
    @Test func renderTransparentLeavesTheBackgroundOut() throws {
        let dir = scratch("transparent")
        defer { try? FileManager.default.removeItem(at: dir) }
        func alpha(_ path: URL) throws -> UInt8 {
            let img = try #require(Images.decode(readBytes(path)))
            return img.pixels[(1 * img.width + 1) * 4 + 3]
        }
        let opaque = dir.appending(path: "opaque.png")
        try onLargeStack { try CLI.render(["--sample", "--scale", "0.25", opaque.path]) }
        #expect(try alpha(opaque) == 255)
        let clear = dir.appending(path: "clear.png")
        try onLargeStack { try CLI.render(["--sample", "--transparent", "--scale", "0.25", clear.path]) }
        #expect(try alpha(clear) == 0)
    }

    /// `run --export OUT.gif --export-params JSON` and `convert IN OUT.gif` write animated GIFs.
    @Test func exportsAnAnimatedGif() throws {
        let dir = scratch("gif")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gif = dir.appending(path: "sample.gif").path
        let deck = dir.appending(path: "sample.deckcraft").path
        let params = #"{"width": "small", "secondsPerSlide": 2, "loop": false, "slides": [0, 1]}"#
        try onLargeStack { try CLI.run(["--sample", "--save", deck, "--export", gif, "--export-params", params]) }
        var bytes = try readBytes(URL(filePath: gif))
        #expect(bytes.starts(with: Array("GIF89a".utf8)))
        #expect(bytes.count > 8 && UInt16(bytes[6]) | UInt16(bytes[7]) << 8 == 640, "small = 640 px wide")
        #expect(!contains(bytes, "NETSCAPE2.0"), "play once: no loop block")

        let gif2 = dir.appending(path: "converted.gif").path
        try onLargeStack { try CLI.convert([deck, gif2]) }
        bytes = try readBytes(URL(filePath: gif2))
        #expect(bytes.starts(with: Array("GIF89a".utf8)) && contains(bytes, "NETSCAPE2.0"), "loops forever by default")

        // Bad options are errors, not panics.
        let bad = dir.appending(path: "bad.gif").path
        #expect(throws: CLIFailure.self) { try onLargeStack { try CLI.run(["--sample", "--export", bad, "--export-params", #"{"width": 1e9}"#]) } }
        #expect(throws: CLIFailure.self) { try onLargeStack { try CLI.run(["--sample", "--export", bad, "--export-params", "[1]"]) } }
        #expect((try? onLargeStack { try CLI.run(["--sample", "--export-params", "{}"]) }) != nil)
        #expect(throws: CLIFailure.self) { try onLargeStack { try CLI.run(["--sample", "--export-params", #"{"width": 64}"#]) } }
    }

    private func contains(_ bytes: [UInt8], _ s: String) -> Bool {
        let n = Array(s.utf8)
        guard bytes.count >= n.count else { return false }
        return (0 ... bytes.count - n.count).contains { Array(bytes[$0 ..< $0 + n.count]) == n }
    }

    // slide_index_tests
    @Test func slideNumbersStartAtZeroAndFilesAtOne() {
        #expect((try? CLI.slideIndices(8, false, nil)) == [0])
        #expect((try? CLI.slideIndices(8, false, 0)) == [0])
        #expect((try? CLI.slideIndices(8, false, 7)) == [7])
        #expect((try? CLI.slideIndices(8, true, nil)) == Array(0 ..< 8))
        do {
            _ = try CLI.slideIndices(8, false, 8)
            Issue.record("index 8 was accepted")
        } catch {
            #expect(error.message.contains("numbered 0 through 7"), "\(error)")
            #expect(error.message.contains("slide-01.png"), "\(error)")
            #expect(error.message.contains("slide-08.png"), "\(error)")
        }
        #expect(CLI.missingSlide(0, 0).contains("no slides"))
        #expect(CLI.missingSlide(1, 1).contains("index 0"))
    }

    // frame_path_tests
    @Test func singleFrameUsesOutAsIs() {
        #expect((try? CLI.framePaths("a/b.png", [0.5])) == ["a/b.png"])
    }

    @Test func framesGetDistinctNames() {
        #expect((try? CLI.framePaths("f.png", [0.0, 0.25, 1.0])) == ["f-t0.000.png", "f-t0.250.png", "f-t1.000.png"])
        #expect((try? CLI.framePaths("dir/f.png", [0.5, -0.25])) == ["dir/f-t0.500.png", "dir/f-t-0.250.png"])
    }

    @Test func valuesRoundingToOneNameAreRejected() {
        #expect(throws: CLIFailure.self) { try CLI.framePaths("f.png", [0.1001, 0.1002]) }
        #expect(throws: CLIFailure.self) { try CLI.framePaths("f.png", [0.5, 0.5]) }
    }

    // The table ArgumentParser routes: every subcommand of the help overview.
    @Test func everySubcommandIsRouted() throws {
        for name in Help.subcommands.map(\.name) where name != "version" {
            let command = try DCCLI.parseAsRoot([name, "--whatever", "-x", "value"])
            let p = try #require(command as? any PassthroughCommand, "\(name)")
            #expect(p.args == ["--whatever", "-x", "value"], "\(name)")
        }
        #expect(throws: (any Error).self) { try DCCLI.parseAsRoot(["bogus"]) }
    }
}

@Suite("deckcraft-cli automation_args.rs")
struct AutomationArgsTests {
    @Test func rootsAreTakenOnceAndOtherArgumentsAreLeft() throws {
        var roots = AutomationArgs()
        var args = ArgStream(["a folder", "deck.pptx"])
        #expect(try roots.consume("--automation-read-root", &args))
        #expect(try roots.consume("--automation-write-root=out", &args))
        #expect(try !roots.consume("--sample", &args))
        #expect(roots.readRoot == "a folder")
        #expect(roots.writeRoot == "out")
        #expect(args.next() == "deck.pptx")
        #expect(throws: CLIFailure.self) { try roots.consume("--automation-read-root=other", &args) }
        #expect(roots.readRoot == "a folder")
    }

    @Test func invalidOperandsLeaveRootsUnchanged() {
        for flag in ["--automation-read-root", "--automation-write-root"] {
            for operand in [nil, "", "--version", "--connect", "-folder"] as [String?] {
                var roots = AutomationArgs(readRoot: "read", writeRoot: "write")
                var args = ArgStream(operand.map { [$0] } ?? [])
                #expect(throws: CLIFailure.self, "\(flag) \(operand ?? "nil")") { try roots.consume(flag, &args) }
                #expect(roots.readRoot == "read")
                #expect(roots.writeRoot == "write")
            }
            var roots = AutomationArgs()
            var none = ArgStream([])
            #expect(throws: CLIFailure.self) { try roots.consume("\(flag)=", &none) }
        }
    }

    @Test func explicitDashFolderAndRelativeDashFolderAreValid() throws {
        var roots = AutomationArgs()
        var none = ArgStream([])
        #expect(try roots.consume("--automation-read-root=-folder", &none))
        var one = ArgStream(["./-folder"])
        #expect(try roots.consume("--automation-write-root", &one))
        #expect(roots.readRoot == "-folder")
        #expect(roots.writeRoot == "./-folder")
    }
}

/// Run `body` on a thread with the engine's 32 MiB stack, as `dccli` runs its subcommands.
func onLargeStack(_ body: @escaping () throws -> Void) throws {
    let r = EngineThread.onLargeStack { Result { try body() } } ?? .success(())
    try r.get()
}
