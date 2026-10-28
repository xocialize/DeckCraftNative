// DCAppTests — the app's external video decoders: VP9 and VP8 through vpx-swift (libvpx), registered as the app
// registers them. Upstream's own clips (deckcraft `crates/media/tests/fixtures`) give deckcraft's frame times for
// VP9 (`media/probe.txt`; deckcraft reports VP8 unsupported, so VP8 has no oracle) and ffmpeg's own VP8/VP9
// decoders give the pixels to compare against, when ffmpeg is installed.
import DCMedia
import DCTestSupport
import Foundation
import Testing
@testable import DCApp

private enum Clips {
    static var dir: URL {
        Fixtures.repositoryRoot.deletingLastPathComponent().appending(path: "deckcraft/crates/media/tests/fixtures", directoryHint: .isDirectory)
    }

    static func load(_ name: String) -> [UInt8]? { (try? Data(contentsOf: dir.appending(path: name))).map { [UInt8]($0) } }
    static var available: Bool { FileManager.default.fileExists(atPath: dir.appending(path: "clip-vp9.webm").path) }
    static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// ffmpeg's RGBA frames of `name` (its own decoder: `vp8`, `vp9`), converted with `matrix` (`bt601`, `bt709`)
    /// from video range.
    static func ffmpegFrames(_ name: String, _ w: Int, _ h: Int, matrix: String) throws -> [[UInt8]] {
        guard let ffmpeg else { return [] }
        let p = Process()
        p.executableURL = URL(filePath: ffmpeg)
        p.arguments = ["-v", "error", "-i", dir.appending(path: name).path,
                       "-vf", "scale=in_color_matrix=\(matrix):in_range=tv,format=rgba", "-f", "rawvideo", "-"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = [UInt8](out.fileHandleForReading.readDataToEndOfFile())
        p.waitUntilExit()
        let size = w * h * 4
        guard size > 0 else { return [] }
        return stride(from: 0, to: data.count - size + 1, by: size).map { Array(data[$0 ..< $0 + size]) }
    }
}

@Suite(.serialized) struct CodecsTests {
    /// Mean absolute difference over RGB, in levels.
    private func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum = 0, n = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            for c in 0 ..< 3 { sum += abs(Int(a[i + c]) - Int(b[i + c])) }
            n += 3
        }
        return Double(sum) / Double(n)
    }

    @Test(.enabled(if: Clips.available)) func vp9AndVP8PlayWithTheAppsDecoders() throws {
        Codecs.registerExternalDecoders()
        Codecs.registerExternalDecoders()  // once per process: a second call adds nothing
        for (name, codec) in [("clip-vp9.webm", "VP9"), ("clip-vp8.webm", "VP8")] {
            let bytes = try #require(Clips.load(name))
            let info = try Media.probe(bytes)
            #expect(info.video?.codec == codec)
            #expect(info.videoSupport == .supported, "\(codec) plays once the app's decoders are registered")
            let d = try VideoDecoder(bytes)
            var frames: [DCMedia.Frame] = []
            while let f = try d.nextFrame() { frames.append(f) }

            // deckcraft's frame times for VP9 (`media/probe.txt`: 0, 0.1, … 0.4); the VP8 clip has the same five.
            #expect(frames.map(\.time) == [0, 0.1, 0.2, 0.3, 0.4], "\(codec): \(frames.map(\.time))")
            #expect(frames.allSatisfy { $0.width == 64 && $0.height == 48 }, "\(codec) frame size")
            // The decode is libvpx's exactly, in the colours deckcraft shows: VP8 is BT.601 by its specification, and
            // deckcraft's `yuv.rs` takes an untagged stream of 576 lines or fewer as BT.601 too, as vpx-swift does
            // since 0.3.1. ffmpeg's own VP8/VP9 decoders, converted as BT.601 with swscale's default (bilinear)
            // chroma, give the same pixels to rounding (measured 0.30 levels; BT.709 is about 6 levels away).
            let as601 = try Clips.ffmpegFrames(name, 64, 48, matrix: "bt601")
            if !as601.isEmpty {
                #expect(as601.count == frames.count, "\(codec): ffmpeg decoded \(as601.count) frames")
                for (f, r) in zip(frames, as601) {
                    let diff = meanDiff(f.rgba, r)
                    #expect(diff < 1, "\(codec) at \(f.time) s: mean difference \(diff) levels from ffmpeg (BT.601)")
                }
            }
            let as709 = try Clips.ffmpegFrames(name, 64, 48, matrix: "bt709")
            if let f = frames.first, let r = as709.first {
                #expect(meanDiff(f.rgba, r) > 3, "\(codec): an untagged SD stream isn't converted as BT.709")
            }
        }
    }
}
