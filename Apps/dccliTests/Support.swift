// dccliTests — running the built `dccli` and the oracle `deckcraft-cli` side by side, and the comparisons
// the parity tests share. The script and deck helpers follow DCEngineTests' (EngineScriptTests,
// TextNativeScriptTests, ShapesScriptTests, InsertNativeScriptTests), whose comparisons the CLI's must
// match.
import CoreGraphics
import Darwin
import DCCore
import DCEngine
import DCRender
import DCTestSupport
import DCZip
import Foundation
import ImageIO
import Testing

// MARK: - The binaries

/// What a process did.
struct Ran: Sendable {
    var code: Int32
    var out: Data
    var err: Data
    var stdout: String { String(decoding: out, as: UTF8.self) }
    var stderr: String { String(decoding: err, as: UTF8.self) }
}

final class BundleMarker {}

enum Binaries {
    /// The `dccli` built beside this test bundle (or `DCCLI`).
    static let dccli: String? = {
        if let env = ProcessInfo.processInfo.environment["DCCLI"], FileManager.default.isExecutableFile(atPath: env) { return env }
        var dir = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
        for _ in 0 ..< 4 {
            let p = dir.appending(path: "dccli").path
            if FileManager.default.isExecutableFile(atPath: p) { return p }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }()

    /// The pinned `deckcraft-cli` that `Tools/oracle/oracle.sh build` makes (or `DECKCRAFT_CLI`).
    static let oracle: String? = {
        if let env = ProcessInfo.processInfo.environment["DECKCRAFT_CLI"], FileManager.default.isExecutableFile(atPath: env) { return env }
        let p = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/DeckCraftNative/cargo-target/release/deckcraft-cli").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }()

    static var haveDccli: Bool { dccli != nil }
    static var haveOracle: Bool { oracle != nil && dccli != nil }
}

/// Run `exe` with `args` (stdin from `input`), its output through files so nothing can block. posix_spawn
/// hands the arguments over byte for byte (Foundation's `Process` passes them in their file-system
/// representation, which decomposes `Ü` into `U` and a combining diaeresis).
func runProcess(_ exe: String, _ args: [String], input: Data? = nil, cwd: URL? = nil) throws -> Ran {
    let dir = scratch("proc")
    defer { try? FileManager.default.removeItem(at: dir) }
    let outPath = dir.appending(path: "out").path, errPath = dir.appending(path: "err").path, inPath = dir.appending(path: "in").path
    FileManager.default.createFile(atPath: inPath, contents: input ?? Data())
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, inPath, O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, outPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    posix_spawn_file_actions_addopen(&actions, 2, errPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if let cwd { posix_spawn_file_actions_addchdir(&actions, cwd.path) }
    let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
    defer { for p in argv { free(p) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe, &actions, nil, argv, environ)
    guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EINVAL) }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
    return Ran(code: code, out: try Data(contentsOf: URL(filePath: outPath)), err: try Data(contentsOf: URL(filePath: errPath)))
}

func dccli(_ args: [String], input: Data? = nil, cwd: URL? = nil) throws -> Ran {
    try runProcess(try #require(Binaries.dccli, "dccli isn't built"), args, input: input, cwd: cwd)
}

func oracle(_ args: [String], input: Data? = nil, cwd: URL? = nil) throws -> Ran {
    try runProcess(try #require(Binaries.oracle, "the oracle isn't built"), args, input: input, cwd: cwd)
}

/// A fresh scratch folder.
func scratch(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "dccli-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0 ... .max))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - The corpus

enum Corpus {
    static var decks: URL? { Fixtures.oracleCorpus?.appending(path: "decks") }
    static let engineVectors = Fixtures.root.appending(path: "engine")
    static var haveVectors: Bool { FileManager.default.fileExists(atPath: engineVectors.path) && Fixtures.oracleCorpus != nil }

    /// The corpus decks' names (`sample`, `shapes`…).
    static let deckNames: [String] = {
        guard let d = decks, let files = try? FileManager.default.contentsOfDirectory(atPath: d.path) else { return [] }
        return files.filter { $0.hasSuffix(".deckcraft") && !$0.hasSuffix(".from-pptx.deckcraft") }.map { String($0.dropLast(".deckcraft".count)) }.sorted()
    }()
}

/// A command script: an optional corpus deck it starts from, and `id` / `id=json` lines; `!` lines are
/// refusals (see DCEngineTests' `CommandScript`).
struct CommandScript: Sendable, CustomStringConvertible {
    var name: String
    var input: String?
    /// Every command line as written (without `!`), and whether it is a refusal.
    var lines: [(line: String, refused: Bool)]

    var description: String { name }

    init(name: String, text: String) {
        self.name = name
        var all = text.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        if let first = all.first, first.hasPrefix("# in: ") { input = String(first.dropFirst("# in: ".count)) }
        lines = all.filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { $0.hasPrefix("!") ? (String($0.dropFirst()), true) : ($0, false) }
    }

    static func load(_ dir: URL) -> [CommandScript] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "cmds" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return CommandScript(name: url.deletingPathExtension().lastPathComponent, text: text)
        }
    }

    /// `--in DECK` when the script starts from a corpus deck.
    var inArgs: [String] {
        guard let input, let decks = Corpus.decks else { return [] }
        return ["--in", decks.appending(path: input).path]
    }

    /// `run`'s arguments for the commands before line `k` (all of them for nil), refusals left out.
    func cmdArgs(before k: Int? = nil) -> [String] {
        lines.prefix(k ?? lines.count).filter { !$0.refused }.flatMap { ["--cmd", $0.line] }
    }
}

let engineScripts = CommandScript.load(Fixtures.repositoryRoot.appending(path: "Tools/oracle/engine-scripts"))
let corpusScripts = CommandScript.load(Fixtures.repositoryRoot.appending(path: "Tools/oracle/scripts"))

// MARK: - Decks

/// The `presentation` member of a `.deckcraft` file's `presentation.json`, as serde_json writes it (the
/// manifest's `generator` names the writing app, so it is left out). Comment dates are blanked.
func presentationJSON(_ file: [UInt8]) throws -> [UInt8] {
    let z = try ZipReader(file)
    let manifest = try JSONParser.parse(try z.read(named: "presentation.json", max: 1 << 30))
    let p = try #require(manifest["presentation"])
    return JSONWriter(nonFiniteAsZero: true).bytes(blankCommentDates(p))
}

func blankCommentDates(_ v: JSON) -> JSON {
    guard case .object(var o) = v, case .array(var slides)? = o["slides"] else { return v }
    func blank(_ c: JSON) -> JSON {
        guard case .object(var co) = c else { return c }
        if co["date"] != nil { co.set("date", .string("")) }
        if case .array(let replies)? = co["replies"] { co.set("replies", .array(replies.map(blank))) }
        return .object(co)
    }
    for i in slides.indices {
        guard case .object(var so) = slides[i], case .array(let comments)? = so["comments"] else { continue }
        so.set("comments", .array(comments.map(blank)))
        slides[i] = .object(so)
    }
    o.set("slides", .array(slides))
    return .object(o)
}

/// ISO timestamps in an answer line replaced, so clock-stamped answers compare.
func blankTimestamps(_ line: String) -> String {
    line.replacingOccurrences(of: #"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"#, with: "<time>", options: .regularExpression)
}

/// The first byte where two byte strings differ, with a little context.
func firstDifference(_ a: [UInt8], _ b: [UInt8]) -> String {
    let n = min(a.count, b.count)
    var at = n
    for i in 0 ..< n where a[i] != b[i] {
        at = i
        break
    }
    let lo = max(at - 80, 0)
    let ctx = { (x: [UInt8]) in String(decoding: x[min(lo, x.count) ..< min(at + 80, x.count)], as: UTF8.self) }
    return "differs at byte \(at) of \(a.count)/\(b.count):\n  ours:   …\(ctx(a))…\n  oracle: …\(ctx(b))…"
}

func readBytes(_ url: URL) throws -> [UInt8] { try [UInt8](Data(contentsOf: url)) }

/// Every entry of a zip by name.
func zipParts(_ file: [UInt8]) throws -> [String: [UInt8]] {
    let z = try ZipReader(file)
    var out: [String: [UInt8]] = [:]
    for e in z.entries { out[e.name] = try z.read(e, max: 1 << 30) }
    return out
}

// MARK: - Structural comparison (native scripts)

/// An answer line split into its command and parsed answer.
func answer(_ line: String) -> (String, JSON?) {
    guard let r = line.range(of: " → ") else { return (line, nil) }
    return (String(line[..<r.lowerBound]), try? JSONParser.parse(String(line[r.upperBound...])))
}

/// The answer's shape: an object's keys with their values' shapes, an array, or a scalar's kind.
func shape(_ v: JSON?) -> String {
    switch v {
    case nil: "missing"
    case .null?: "null"
    case .bool?: "bool"
    case .string?: "string"
    case .array?: "array"
    case .object(let o)?: "{" + o.entries.map { "\($0.key): \(shape($0.value))" }.sorted().joined(separator: ", ") + "}"
    default: "number"
    }
}

/// A spelling answer's words as `(where, word, repeated)`.
func words(_ v: JSON?) -> [String] {
    (v?.asArray ?? []).map { w in
        let at = ["slide", "shape", "row", "col", "notes", "para", "start", "end"].map { w.get($0)?.display ?? "-" }.joined(separator: ",")
        return "\(at) \(w.get("word")?.display ?? "") \(w.get("repeated")?.asBool == true ? "repeated" : "")"
    }
}

/// The text group's comparison under the system spell checker (TextNativeScriptTests.systemChecker).
func compareTextNative(_ script: String, _ i: Int, _ got: String, _ want: String) {
    let nativeAnswers: Set<String> = ["review.spelling", "review.dictionary", "font.rescan"]
    let (gid, g) = answer(blankTimestamps(got))
    let (wid, w) = answer(blankTimestamps(want))
    #expect(gid == wid, "\(script) line \(i + 1): \(gid) where the oracle ran \(wid)")
    guard nativeAnswers.contains(gid) else {
        if blankTimestamps(got) != blankTimestamps(want) { Issue.record("\(script) line \(i + 1):\n  ours:   \(got)\n  oracle: \(want)") }
        return
    }
    if gid == "review.spelling" {
        let (ours, theirs) = (words(g), words(w))
        #expect(ours.filter { $0.hasSuffix("repeated") } == theirs.filter { $0.hasSuffix("repeated") }, "\(script) line \(i + 1): repeated words")
        for t in theirs where !ours.contains(t) { Issue.record("\(script) line \(i + 1): the system checker missed \(t)") }
    } else {
        #expect(shape(g) == shape(w), "\(script) line \(i + 1): \(got) is not shaped like the oracle's \(want)")
    }
}

/// The area a path's text (`M`/`L`/`C`/`Q`/`Z`) encloses, sub-paths netted by their winding.
func pathArea(_ d: String) -> Double {
    var total = 0.0
    var ring: [(Double, Double)] = []
    func close() {
        if ring.count > 2 {
            var a = 0.0
            for i in ring.indices {
                let (p, q) = (ring[i], ring[(i + 1) % ring.count])
                a += p.0 * q.1 - q.0 * p.1
            }
            total += a / 2
        }
        ring = []
    }
    for seg in PointsCommands.parse(d) {
        switch seg {
        case .m(let p):
            close()
            ring.append((p.x, p.y))
        case .l(let p), .q(_, let p), .c(_, _, let p): ring.append((p.x, p.y))
        case .z: close()
        }
    }
    close()
    return Swift.abs(total)
}

struct StructuralDiff {
    var problems: [String] = []
    var areas: [(ours: Double, oracle: Double)] = []
    var worstArea: Double { areas.map { Swift.abs($0.ours - $0.oracle) / Swift.max($0.oracle, 1e-9) }.max() ?? 0 }
}

/// The shapes group's comparison (ShapesScriptTests.compareStructurally).
func compareStructurally(_ a: JSON, _ b: JSON, _ path: String, _ diff: inout StructuralDiff, tol: Double = 0.02, areaTol: Double = 1e-3) {
    if diff.problems.count > 20 { return }
    switch (a.canonical, b.canonical) {
    case (.object(let x), .object(let y)):
        if x.keys != y.keys {
            diff.problems.append("\(path): keys \(x.keys) vs \(y.keys)")
            return
        }
        for k in x.keys {
            let (va, vb) = (x[k] ?? .null, y[k] ?? .null)
            if k == "d", case .string(let da) = va, case .string(let db) = vb, !rustEqual(da, db) {
                let (aa, ab) = (pathArea(da), pathArea(db))
                diff.areas.append((aa, ab))
                if Swift.abs(aa - ab) > areaTol * Swift.max(ab, 1) { diff.problems.append("\(path).d: area \(aa) vs \(ab)") }
                continue
            }
            compareStructurally(va, vb, "\(path).\(k)", &diff, tol: tol, areaTol: areaTol)
        }
    case (.array(let x), .array(let y)):
        if x.count != y.count {
            diff.problems.append("\(path): \(x.count) items vs \(y.count)")
            return
        }
        for (i, (va, vb)) in zip(x, y).enumerated() { compareStructurally(va, vb, "\(path)[\(i)]", &diff, tol: tol, areaTol: areaTol) }
    case let (x, y) where x.isNumber && y.isNumber:
        let (u, v) = (x.asF64 ?? .nan, y.asF64 ?? .nan)
        if !(Swift.abs(u - v) <= Swift.max(tol, 1e-6 * Swift.abs(v))) { diff.problems.append("\(path): \(u) vs \(v)") }
    case let (x, y):
        if x != y { diff.problems.append("\(path): \(x.display.prefix(80)) vs \(y.display.prefix(80))") }
    }
}

/// The insert group's answer with the bytes only a picture encoder decides left out
/// (InsertNativeScriptTests.maskPictureBytes).
func maskPictureBytes(_ v: JSON) -> JSON {
    switch v {
    case .array(let a):
        return .array(a.map(maskPictureBytes))
    case .object(var o):
        let type = o["type"]?.asStr ?? o["contentType"]?.asStr ?? ""
        if type.hasPrefix("image/") { o.remove("bytes") }
        if o["ppi"] != nil, o["pictures"] != nil {
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
func pictureSizes(_ deck: [UInt8]) throws -> [String: String] {
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

// MARK: - Pictures

/// The pages of a PDF drawn at `scale` pixels per point, over white.
func pdfPages(_ url: URL, scale: Double) -> [CGImage] {
    guard let doc = CGPDFDocument(url as CFURL) else { return [] }
    var out: [CGImage] = []
    for i in 1 ... max(doc.numberOfPages, 1) where doc.numberOfPages > 0 {
        guard let page = doc.page(at: i) else { continue }
        let box = page.getBoxRect(.mediaBox)
        let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        if let img = ctx.makeImage() { out.append(img) }
    }
    return out
}

/// `image` scaled to `width` pixels wide (the height kept in proportion), drawn with high-quality
/// interpolation over white. SSIMULACRA2 in a debug build takes seconds on a 1920×1080 picture; the
/// parity tests score pictures at a quarter of that size, where a difference that shows still shows.
func reduced(_ image: CGImage, width: Int = 480) -> CGImage? {
    let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

/// SSIMULACRA2 of `ours` against `oracle`, both reduced to 480 pixels wide; nil when their sizes differ.
func reducedScore(ours: CGImage, oracle: CGImage) -> Double? {
    guard ours.width == oracle.width, ours.height == oracle.height, let a = reduced(ours), let b = reduced(oracle) else { return nil }
    return RenderParity.score(reference: b, distorted: a)
}
