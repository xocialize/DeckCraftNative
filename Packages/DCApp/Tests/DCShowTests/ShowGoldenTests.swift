// DCShowTests — the show's frames, byte for byte, across a refactor of its drawing code (DCShow, 2026-11-04): with
// `DECKCRAFT_SHOW_GOLDEN=write` every frame below is written to `.build-parity/show-golden/`; with `=check` each is
// compared with what was written. Without the variable the test does nothing. Run it once before a change to the
// renderer and once after:
//   DECKCRAFT_SHOW_GOLDEN=write swift test --filter ShowGoldenTests --scratch-path .build-dcshow
import CNCore
import DCAppModel
import DCEngine
import DCModel
import DCRender
import DCTestSupport
import Foundation
import Metal
import Testing
@testable import DCShow

@MainActor
@Suite(.serialized) struct ShowGoldenTests {
    nonisolated static var mode: String? { ProcessInfo.processInfo.environment["DECKCRAFT_SHOW_GOLDEN"] }
    nonisolated static var out: URL { Fixtures.repositoryRoot.appending(path: ".build-parity/show-golden", directoryHint: .isDirectory) }

    nonisolated static func decks() -> [String] {
        guard mode != nil else { return [] }
        return ["sample", "content", "motion", "transitions"]
    }

    nonisolated static func deckURL(_ name: String) -> URL? {
        let candidates = [
            Fixtures.oracleCorpus?.appending(path: "decks/\(name).deckcraft"),
            Fixtures.root.appending(path: "engine/\(name).deckcraft"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The frame at `now` at 640 × 400 points, scale 1 (letterboxed: the slide rect is not the whole target).
    static func render(_ c: ShowCoordinator, _ renderer: ShowRenderer, now: Double) -> RenderImage? {
        let frame = renderer.frame(bounds: CGRect(x: 0, y: 0, width: 640, height: 400), scale: 1, now: now)
        return renderer.renderOffscreen(frame, width: 640, height: 400)
    }

    @Test(arguments: decks()) func framesAreUnchanged(_ name: String) throws {
        guard let mode = Self.mode, let metal = ShowMetal.shared else { return }
        guard let url = Self.deckURL(name) else {
            Issue.record("\(name): deck not found")
            return
        }
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let s = Session()
        _ = try s.execute("file.open", ["path": .string(url.path)])
        let m = AppModel(session: s)
        m.ui.presenterView = false
        let c = ShowCoordinator(model: m)
        c.startShow(from: 0, reading: false)
        let renderer = ShowRenderer(coord: c, metal: metal)
        var now = 10.0
        _ = c.tick(now)
        var n = 0
        var compared = 0
        func record(_ label: String, _ t: Double) {
            guard let img = Self.render(c, renderer, now: t) else {
                Issue.record("\(name) \(label): nothing rendered")
                return
            }
            let file = Self.out.appending(path: "\(name)-\(String(format: "%03d", n))-\(label).rgba")
            n += 1
            if mode == "write" {
                try? Data(img.pixels).write(to: file)
            } else if let want = try? Data(contentsOf: file) {
                compared += 1
                #expect(want == Data(img.pixels), "\(name) \(file.lastPathComponent): the frame changed")
            } else {
                Issue.record("\(name) \(file.lastPathComponent): no golden frame (run with DECKCRAFT_SHOW_GOLDEN=write first)")
            }
        }
        for _ in 0 ..< 30 {
            record("rest", now)
            guard c.navigate(true, now: now), c.show != nil else { break }
            for dt in [0.15, 0.4] {
                guard c.tick(now + dt) else { break }
                record("t\(Int(dt * 100))", now + dt)
            }
            now += 5
            guard c.tick(now), c.show != nil, !(c.show?.ended ?? true) else { break }
        }
        #expect(n > 3, "\(name): too few frames")
        if mode == "check" { #expect(compared == n) }
    }
}
