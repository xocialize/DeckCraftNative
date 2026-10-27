// DCEngineTests — the insert group's native scripts (`insert-native-*.cmds`, which EngineScriptTests skips):
// poster frames and Compress Pictures, where ImageIO, vImage and AVFoundation write the pictures deckcraft's
// `image` crate and decoders write. Everything is compared with the oracle as EngineScriptTests compares it,
// except the pictures' bytes: answers are compared with the byte counts of images (`bytes` of an image item,
// `before` and `after` of `picture.compress`) left out, and each picture in the saved deck by its pixel size.
import CoreGraphics
import DCCore
@testable import DCEngine
import DCTestSupport
import DCZip
import Foundation
import ImageIO
import Testing

private let insertNativeScripts = CommandScript.load(Fixtures.repositoryRoot.appending(path: "Tools/oracle/engine-scripts")).filter { $0.name.hasPrefix("insert-native-") }
private let insertVectors = Fixtures.root.appending(path: "engine")

/// The answer with the bytes only a picture encoder decides left out.
private func maskPictureBytes(_ v: JSON) -> JSON {
    switch v {
    case .array(let a):
        return .array(a.map(maskPictureBytes))
    case .object(var o):
        let type = o["type"]?.asStr ?? o["contentType"]?.asStr ?? ""
        if type.hasPrefix("image/") { o.remove("bytes") }
        if o["ppi"] != nil, o["pictures"] != nil {
            // `before` too: it counts pictures an earlier compression wrote.
            o.remove("after")
            o.remove("before")
        }
        var out = JSONObject()
        for e in o.entries { out.set(e.key, maskPictureBytes(e.value)) }
        return .object(out)
    default:
        return v
    }
}

/// The pixel size of every picture in a saved deck, by media path.
private func pictureSizes(_ deck: [UInt8]) throws -> [String: String] {
    let z = try ZipReader(deck)
    var out: [String: String] = [:]
    for e in z.entries where e.name.hasPrefix("media/") {
        let data = try z.read(e, max: 1 << 28)
        guard let src = CGImageSourceCreateWithData(Data(data) as CFData, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { continue }
        out[e.name] = "\(w)×\(h)"
    }
    return out
}

@Suite("Insert: native scripts", .enabled(if: FileManager.default.fileExists(atPath: insertVectors.path), "no engine vectors"))
struct InsertNativeScriptTests {
    @Test("Every insert-native script is found")
    func scriptsExist() {
        #expect(insertNativeScripts.count >= 2)
    }

    @Test("Native scripts give the oracle's answers and deck, pictures by pixel size", arguments: insertNativeScripts)
    func nativeScript(_ script: CommandScript) throws {
        let missing = unported(script.needs)
        if !missing.isEmpty { try Test.cancel("waits for unported commands: \(Set(missing).sorted().joined(separator: ", "))") }
        let want = try String(contentsOf: insertVectors.appending(path: "\(script.name).results.txt"), encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        let s = Session()
        _ = try s.execute("file.new", .emptyObject)
        var got: [String] = []
        var errors: [String] = []
        for (i, (id, params)) in script.commands.enumerated() {
            let p = try JSONParser.parse(params)
            if script.refused.contains(i) {
                do {
                    let r = try s.execute(id, p)
                    errors.append("\(id)=\(params)\tsucceeded: \(r.display)")
                } catch {
                    errors.append("\(id)=\(params)\t\(error)")
                }
                continue
            }
            got.append("\(id) → \(try s.execute(id, p).display)")
        }
        #expect(got.count == want.count)
        for (k, (g, w)) in zip(got, want).enumerated() {
            let split = { (line: String) -> (String, JSON?) in
                let parts = line.components(separatedBy: " → ")
                return (parts[0], try? JSONParser.parse(parts.dropFirst().joined(separator: " → ")))
            }
            let (gi, gj) = split(g)
            let (wi, wj) = split(w)
            #expect(gi == wi, "\(script.name) line \(k + 1)")
            guard let gj, let wj else {
                Issue.record("\(script.name) line \(k + 1): unreadable answer")
                continue
            }
            let a = maskPictureBytes(gj).display, b = maskPictureBytes(wj).display
            if a != b { Issue.record("\(script.name) line \(k + 1):\n  ours:   \(a)\n  oracle: \(b)") }
            // Compress Pictures shrinks what it compresses, as deckcraft's does.
            if gi == "picture.compress", let n = gj.get("pictures")?.asU64, n > 0 {
                #expect((gj.get("after")?.asU64 ?? .max) < (gj.get("before")?.asU64 ?? 0), "\(g)")
            }
        }
        let wantErrors = (try? String(contentsOf: insertVectors.appending(path: "\(script.name).errors.txt"), encoding: .utf8))?
            .components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        #expect(errors == wantErrors)
        let out = scratchDir("insert-native").appending(path: "\(script.name).deckcraft")
        defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }
        _ = try s.execute("file.saveAs", ["path": .string(out.path)])
        let ours = try [UInt8](Data(contentsOf: out))
        let oracle = try [UInt8](Data(contentsOf: insertVectors.appending(path: "\(script.name).deckcraft")))
        let a = try presentationJSON(ours), b = try presentationJSON(oracle)
        #expect(a == b, "\(script.name): presentation \(firstDifference(a, b))")
        let sizes = try pictureSizes(ours), oracleSizes = try pictureSizes(oracle)
        #expect(sizes == oracleSizes, "\(script.name): picture sizes")
        print("native script \(script.name): \(got.count) answers, \(sizes.count) pictures compared by pixel size")
    }
}
