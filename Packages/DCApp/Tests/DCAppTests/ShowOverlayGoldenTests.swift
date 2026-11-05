// DCAppTests — the show window's whole picture (Metal and the AppKit overlay, `ShowView.snapshot()`) for the
// overlay cases, across a change of who draws them (DCShow took the blank screens, the end screen and ink from the
// AppKit overlay on 2026-11-04): with `DECKCRAFT_SHOW_GOLDEN=write` each case is written to
// `.build-parity/show-overlay-golden/`; with `=check` it is compared with what was written: exactly, but for ink's
// edges, within a level. The move was checked so: every case identical, ink within 1 level on 0.008 % of channels. Without the variable the
// test does nothing.
import AppKit
import DCAppModel
import DCEngine
import DCRender
import DCShow
import DCTestSupport
import Foundation
import Testing
@testable import DCApp

@MainActor
@Suite(.serialized) struct ShowOverlayGoldenTests {
    nonisolated static var mode: String? { ProcessInfo.processInfo.environment["DECKCRAFT_SHOW_GOLDEN"] }
    nonisolated static var out: URL { Fixtures.repositoryRoot.appending(path: ".build-parity/show-overlay-golden", directoryHint: .isDirectory) }

    nonisolated static func cases() -> [String] {
        guard mode != nil else { return [] }
        return ["rest", "black", "white", "ink", "ink-over-black", "ended", "ended-ink"]
    }

    /// A two-slide show on its second slide in a 640 × 400 view (no window: scale 2), set up as `name` says.
    static func snapshot(_ name: String) throws -> CGImage? {
        guard let metal = ShowMetal.shared else { return nil }
        let s = Session.withNew()
        _ = try s.execute("slide.new", ["title": "Second"])
        _ = try s.execute("shape.insert", ["preset": "star5", "rect": [100, 100, 300, 200]])
        let m = AppModel(session: s)
        m.ui.presenterView = false
        let c = ShowCoordinator(model: m)
        c.startShow(from: 1, reading: false)
        _ = c.tick(10)
        let view = ShowView(coord: c, metal: metal)
        view.frame = CGRect(x: 0, y: 0, width: 640, height: 400)
        let sh = try #require(c.show)
        let ink: [[CGPoint]] = [
            [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.25), CGPoint(x: 0.5, y: 0.6), CGPoint(x: 0.52, y: 0.61)],
            [CGPoint(x: 0.7, y: 0.1), CGPoint(x: 0.9, y: 0.9)],
            [CGPoint(x: 0.4, y: 0.4)],
        ]
        switch name {
        case "black": sh.toggleBlank(.black)
        case "white": sh.toggleBlank(.white)
        case "ink": sh.strokes = ink
        case "ink-over-black":
            sh.toggleBlank(.black)
            sh.strokes = ink
        case "ended": sh.ended = true
        case "ended-ink":
            sh.ended = true
            sh.strokes = ink
        default: break
        }
        return view.snapshot()
    }

    static func pixels(_ img: CGImage) -> [UInt8]? {
        let (w, h) = (img.width, img.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px : nil
    }

    @Test(arguments: cases()) func theWindowsPictureIsUnchanged(_ name: String) throws {
        guard let mode = Self.mode, ShowMetal.shared != nil else { return }
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let img = try #require(try Self.snapshot(name), "\(name): no snapshot")
        let px = try #require(Self.pixels(img))
        let file = Self.out.appending(path: "\(name)-\(img.width)x\(img.height).rgba")
        if mode == "write" {
            try Data(px).write(to: file)
            RenderParity.writePNG(img, to: Self.out.appending(path: "\(name).png"))
            return
        }
        let want = try #require(try? Data(contentsOf: file), "\(name): no golden (run with DECKCRAFT_SHOW_GOLDEN=write first)")
        #expect(want.count == px.count)
        var maxDiff = 0, differing = 0
        for (a, b) in zip(want, px) {
            let d = Swift.abs(Int(a) - Int(b))
            if d > 0 { differing += 1 }
            maxDiff = Swift.max(maxDiff, d)
        }
        let share = Double(differing) / Double(Swift.max(px.count, 1))
        print("overlay golden \(name): \(differing) channels differ (\(share)), max \(maxDiff)")
        RenderParity.writePNG(img, to: Self.out.appending(path: "\(name).now.png"))
        try? Data(px).write(to: Self.out.appending(path: "\(name).now.rgba"))
        #expect(share <= 0.01, "\(name): \(differing) channels differ")
        #expect(maxDiff <= Self.tolerance(name), "\(name): a channel is \(maxDiff) levels off")
    }

    /// Exact, but for ink's antialiased edges: rasterised alone and blended on the GPU, they round a level
    /// differently from strokes drawn straight over the picture (measured 2026-11-04: 329 channels, at most 1 level).
    static func tolerance(_ name: String) -> Int {
        name.contains("ink") ? 1 : 0
    }
}
