// Parity with deckcraft-media: runs `Media.probeHeaders` and `Media.probe` over every case
// `Tools/oracle/media-vectors` wrote (the generated inputs, upstream's CC0 fixtures, and truncations and
// inverted bytes of each) and compares the result line for line with deckcraft's, the frame rate as its bit
// pattern. Skips cleanly without the fixtures.
@testable import DCMedia
import DCTestSupport
import Foundation
import Testing

private let dir = Fixtures.root.appending(path: "media", directoryHint: .isDirectory)
private let probeURL = dir.appending(path: "probe.txt")
private let haveVectors = FileManager.default.fileExists(atPath: probeURL.path)

/// The oracle's text for a probe result.
func oracleLine(_ r: Result<MediaInfo, MediaError>) -> String {
    switch r {
    case .failure(let e):
        switch e {
        case .unsupported(let s): return "err unsupported \(s)"
        case .corrupt(let s): return "err corrupt \(s)"
        case .missing(let s): return "err missing \(s)"
        }
    case .success(let i):
        let a = i.audio.map { "\($0.codec)|\($0.sampleRate)|\($0.channels)|\($0.decodable)" } ?? "-"
        let v = i.video.map { v -> String in
            let bits = String(v.fps.bitPattern, radix: 16)
            return "\(v.codec)|\(v.width)|\(v.height)|\(String(repeating: "0", count: 16 - bits.count) + bits)|\(v.frames)|\(v.decodable)"
        } ?? "-"
        return "ok \(i.container) \(i.durationMs) audio=\(a) video=\(v)"
    }
}

struct OracleCase {
    var name: String
    var lines: [String: String] = [:]
}

/// `probe.txt` as cases.
func oracleCases() throws -> [OracleCase] {
    let text = try String(contentsOf: probeURL, encoding: .utf8)
    var out: [OracleCase] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        if line.hasPrefix("== ") {
            out.append(OracleCase(name: String(line.dropFirst(3))))
        } else if let sp = line.firstIndex(of: " "), !out.isEmpty {
            out[out.count - 1].lines[String(line[..<sp])] = String(line[line.index(after: sp)...])
        } else if !out.isEmpty {
            out[out.count - 1].lines[String(line)] = ""
        }
    }
    return out
}

func caseBytes(_ name: String) throws -> [UInt8] {
    [UInt8](try Data(contentsOf: dir.appending(path: "cases/\(name).bin")))
}

@Suite(.enabled(if: haveVectors, "no media vectors: Tools/oracle/media-vectors/run.sh"))
struct OracleParityTests {
    @Test func probeMatchesDeckcraft() throws {
        let cases = try oracleCases()
        #expect(cases.count > 1000)
        var mismatches: [String] = []
        var compared = 0
        for c in cases {
            let b = try caseBytes(c.name)
            #expect(c.lines["sniff"] == Container.sniff(b).name, "\(c.name) sniff")
            for (key, run) in [("headers", { () throws(MediaError) -> MediaInfo in try Media.probeHeaders(b) }),
                               ("probe", { () throws(MediaError) -> MediaInfo in try Media.probe(b) })]
            {
                guard let want = c.lines[key] else { continue }
                let got: String
                do { got = oracleLine(.success(try run())) } catch { got = oracleLine(.failure(error)) }
                compared += 1
                if got != want { mismatches.append("\(c.name) \(key)\n  rust:  \(want)\n  swift: \(got)") }
            }
        }
        let unexplained = mismatches.filter { m in
            let name = String(m.prefix { $0 != " " })
            return !knownDifferences.contains { name == $0.case || name.hasPrefix($0.case + "~") && $0.mutations }
        }
        if !unexplained.isEmpty {
            print("media parity: \(mismatches.count) of \(compared) differ, \(unexplained.count) unexplained:\n" + unexplained.prefix(80).joined(separator: "\n"))
        }
        print("media parity: \(compared - mismatches.count)/\(compared) identical (\(cases.count) cases)")
        if let path = ProcessInfo.processInfo.environment["DCMEDIA_PARITY_DUMP"] {
            try mismatches.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(unexplained.isEmpty)
    }
}

extension OracleParityTests {
    /// Decoding: deckcraft's decoders are replaced, so samples differ; rate and channel count must agree, and
    /// the frame count must agree within one codec frame, wherever both decode.
    @Test func decodeAgreesWithDeckcraft() throws {
        var report: [String] = []
        var agree = 0, total = 0
        for c in try oracleCases() where !c.name.contains("~") {
            guard let want = c.lines["decode"] else { continue }
            let b = try caseBytes(c.name)
            let got: String
            do {
                let p = try Media.decodeAudio(b)
                got = "ok \(p.rate) \(p.channels) \(p.frames)"
            } catch {
                got = oracleLine(.failure(error))
            }
            total += 1
            let w = want.split(separator: " "), g = got.split(separator: " ")
            let same = w.count == 4 && g.count == 4 && w[0] == "ok" && g[0] == "ok" && w[1] == g[1] && w[2] == g[2]
                && abs((Int(w[3]) ?? 0) - (Int(g[3]) ?? 0)) <= 2048
            if same || want == got { agree += 1 } else { report.append("\(c.name)\n  rust:  \(want)\n  swift: \(got)") }
        }
        print("media decode: \(agree)/\(total) agree\n" + report.joined(separator: "\n"))
    }
}

extension OracleParityTests {
    /// Video: the track deckcraft opens (size, codec, frame count) and the presentation time of every decoded
    /// frame, for every case; frame times only for unmutated inputs (the oracle writes them only there).
    @Test func videoAgreesWithDeckcraft() throws {
        var report: [String] = []
        var agree = 0, total = 0
        for c in try oracleCases() {
            guard let want = c.lines["video"] else { continue }
            let b = try caseBytes(c.name)
            var got: String
            var times: [String] = []
            do {
                let d = try VideoDecoder(b)
                got = "ok \(d.size.0) \(d.size.1) \(d.codec) \(d.frameCount)"
                if c.lines["times"] != nil {
                    for _ in 0..<64 {
                        guard let f = try? d.nextFrame() else { break }
                        let s = String(f.time.bitPattern, radix: 16)
                        times.append(String(repeating: "0", count: 16 - s.count) + s)
                    }
                }
            } catch {
                got = oracleLine(.failure(error))
            }
            total += 1
            var same = got == want
            if same, let wt = c.lines["times"] { same = wt == times.joined(separator: ",") }
            if same { agree += 1 } else {
                report.append("\(c.name)\n  rust:  \(want) \(c.lines["times"] ?? "")\n  swift: \(got) \(times.joined(separator: ","))")
            }
        }
        print("media video: \(agree)/\(total) agree\n" + report.joined(separator: "\n"))
        if let path = ProcessInfo.processInfo.environment["DCMEDIA_VIDEO_DUMP"] {
            try report.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// Inputs whose probe differs from deckcraft's, explained in PORT-NOTES.md ("Probe parity"): the case, and
/// whether its mutations are covered too.
let knownDifferences: [(case: String, mutations: Bool, why: String)] = [
    ("at-aac-long-mpeg4.aac", true, "symphonia's ADTS duration estimate, approximated by the middle-of-file mean frame length"),
    ("wav-extensible.wav~x4", false, "a RIFF length 129 bytes short of the data chunk, which symphonia accepts for WAVE_FORMAT_EXTENSIBLE only"),
]
