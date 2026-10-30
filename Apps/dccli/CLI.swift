// dccli — headless DeckCraft: each subcommand's work. Port of deckcraft apps/deckcraft-cli/src/main.rs
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). Arguments are read as deckcraft-cli
// reads them, so the same mistakes give the same messages; output, error text and exit codes are
// deckcraft-cli's (`dccli` speaks as `deckcraft-cli`, whose behaviour it is).
import DCAnim
import DCAutomation
import DCCore
import DCEngine
import DCModel
import DCRender
import Darwin
import Foundation

/// A subcommand's failure: printed as `deckcraft-cli: <message>`, exit code 1.
struct CLIFailure: Error, Equatable, CustomStringConvertible {
    var message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// Where the CLI writes (stdout; stderr for diagnostics).
enum Out {
    /// `outln!`: a line on stdout. A closed pipe ends the process quietly (exit 0), any other failure
    /// with exit 1.
    static func line(_ s: String) {
        do {
            try write(STDOUT_FILENO, s + "\n")
        } catch {
            if error.code == EPIPE { exit(0) }
            err("deckcraft-cli: can't write to stdout: \(error)")
            exit(1)
        }
    }

    /// `eprintln!`.
    static func err(_ s: String) {
        try? write(STDERR_FILENO, s + "\n")
    }

    private static func write(_ fd: Int32, _ s: String) throws(IOFailure) {
        let bytes = Array(s.utf8)
        var failure: IOFailure?
        bytes.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = Darwin.write(fd, raw.baseAddress?.advanced(by: done), raw.count - done)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = .current
                    return
                }
                done += n
            }
        }
        if let failure { throw failure }
    }
}

/// Rust's `std::fs` calls the CLI makes itself, with `io::Error`'s messages.
enum FS {
    /// `std::fs::read`.
    static func read(_ path: String) throws(IOFailure) -> [UInt8] {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw .current }
        defer { close(fd) }
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw .current
            }
            if n == 0 { return out }
            out.append(contentsOf: buf[0 ..< n])
        }
    }

    /// `std::fs::write`: create or truncate, then write everything.
    static func write(_ path: String, _ bytes: [UInt8]) throws(IOFailure) {
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw .current }
        defer { close(fd) }
        var failure: IOFailure?
        bytes.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = Darwin.write(fd, raw.baseAddress?.advanced(by: done), raw.count - done)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = .current
                    return
                }
                done += n
            }
        }
        if let failure { throw failure }
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// `Path::is_file`: a regular file, links followed.
    static func isFile(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// `std::fs::create_dir_all`.
    static func createDirAll(_ path: String) throws(IOFailure) {
        if path.isEmpty { return }
        if mkdir(path, 0o777) == 0 { return }
        let e = errno
        if e != ENOENT {
            if isDirectory(path) { return }
            throw IOFailure(os: e)
        }
        guard let parent = RustPath.parent(path) else { throw IOFailure("failed to create whole tree") }
        try createDirAll(parent)
        if mkdir(path, 0o777) == 0 { return }
        let e2 = errno
        if isDirectory(path) { return }
        throw IOFailure(os: e2)
    }
}

/// Rust's `std::path::Path` name helpers on `/`-separated strings (as DCEngine's `RustPath`).
enum RustPath {
    /// The last component (`file_name`), nil for `..`, `/` or empty.
    static func fileName(_ path: String) -> String? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard let last = comps.last, last != ".." else { return nil }
        if path.hasSuffix("/.") { return nil }
        return String(last)
    }

    /// `file_stem`: the file name without its final extension (a leading dot is part of the name).
    static func fileStem(_ path: String) -> String? {
        guard let name = fileName(path) else { return nil }
        let b = Array(name.utf8)
        guard let dot = b.lastIndex(of: UInt8(ascii: ".")), dot > 0 else { return name }
        return String(decoding: b[..<dot], as: UTF8.self)
    }

    /// `extension`: after the file name's last dot, nil without one (or with only a leading dot).
    static func ext(_ path: String) -> String? {
        guard let name = fileName(path) else { return nil }
        let b = Array(name.utf8)
        guard let dot = b.lastIndex(of: UInt8(ascii: ".")), dot > 0 else { return nil }
        return String(decoding: b[(dot + 1)...], as: UTF8.self)
    }

    /// `with_file_name`: the last component replaced (pushed when there is none).
    static func withFileName(_ path: String, _ name: String) -> String {
        guard fileName(path) != nil else { return path.isEmpty ? name : (path.hasSuffix("/") ? path + name : path + "/" + name) }
        var b = Array(path.utf8)
        while b.count > 1, b.last == UInt8(ascii: "/") { b.removeLast() }
        while b.count > 2, b.suffix(2) == Array("/.".utf8) { b.removeLast(2) }
        guard let slash = b.lastIndex(of: UInt8(ascii: "/")) else { return name }
        return String(decoding: b[...slash], as: UTF8.self) + name
    }

    /// `parent`: the path without its last component; nil for a root or an empty path.
    static func parent(_ path: String) -> String? {
        var b = Array(path.utf8)
        while b.count > 1, b.last == UInt8(ascii: "/") { b.removeLast() }
        if b.isEmpty || b == [UInt8(ascii: "/")] { return nil }
        guard let slash = b.lastIndex(of: UInt8(ascii: "/")) else { return "" }
        var p = Array(b[..<slash])
        while p.count > 1, p.last == UInt8(ascii: "/") { p.removeLast() }
        return p.isEmpty ? "/" : String(decoding: p, as: UTF8.self)
    }
}

enum CLI {
    /// The deckcraft-cli version this is (`--version` prints `deckcraft-cli <version>`).
    static let version = MCPProtocol.serverVersion

    static func isHelp(_ arg: String) -> Bool { arg == "--help" || arg == "-h" }

    /// The help page of subcommand `name`, else the overview.
    static func helpPage(_ name: String) -> String { Help.page(name) ?? Help.overview() }

    static func unknown(_ sub: String) -> Int32 {
        Out.err("deckcraft-cli: unknown subcommand `\(sub)`\n")
        return usage()
    }

    static func usage() -> Int32 {
        Out.err(Help.overview())
        Out.err("\nCommunity: \(Links.discord)  ·  \(Links.appPage)")
        return 1
    }

    static func report(_ body: () throws(CLIFailure) -> Void) -> Int32 {
        do {
            try body()
            return 0
        } catch {
            Out.err("deckcraft-cli: \(error.message)")
            return 1
        }
    }

    /// A JSON argument as serde_json reads it into a `Value` (map keys sorted, the last duplicate kept).
    static func parseJSON(_ text: String) throws(JSONParseError) -> JSON { try JSONParser.parse(text).canonical }

    static func execute(_ s: Session, _ id: String, _ params: JSON) throws(CLIFailure) -> JSON {
        do { return try s.execute(id, params) } catch { throw CLIFailure(error.description) }
    }

    static func open(_ s: Session, _ input: String?, _ sample: Bool) throws(CLIFailure) {
        if sample {
            do { try Sample.openSample(s) } catch { throw CLIFailure(error.description) }
            return
        }
        if let p = input {
            // A password-protected input's password comes from the environment, not the command line, so it stays
            // out of shell history and the process list.
            var params: JSON = ["path": .string(p)]
            if let pw = ProcessInfo.processInfo.environment["DCCLI_PASSWORD"] { params.set("password", .string(pw)) }
            let opened: JSON
            do { opened = try s.execute("file.open", params) } catch {
                if case .passwordRequired = error { throw CLIFailure("\(error) (set DCCLI_PASSWORD)") }
                throw CLIFailure(error.description)
            }
            warnIfDamaged(p, opened)
        } else {
            _ = try execute(s, "file.new", .emptyObject)
        }
    }

    /// Say on stderr what a file lost on opening, so a saved copy doesn't silently miss it (#203).
    static func warnIfDamaged(_ path: String, _ opened: JSON) {
        func count(_ key: String) -> Int { opened.get(key)?.asArray?.count ?? 0 }
        let (slides, media) = (count("lostSlides"), count("damagedMedia"))
        if slides > 0 { Out.err("deckcraft-cli: warning: \(path): \(slides) slide\(slides == 1 ? "" : "s") couldn't be read and left out") }
        if media > 0 { Out.err("deckcraft-cli: warning: \(path): \(media) picture or media file\(media == 1 ? "" : "s") couldn't be read") }
    }

    // MARK: commands, links

    static func commands(_ args: [String]) {
        let f = args.first.map(rustLowercase)
        for c in commandSpecs() where f.map({ contains(rustLowercase(c.id), $0) || contains(rustLowercase(c.label), $0) }) ?? true {
            if c.params.hasPrefix("{}") {
                Out.line("\(c.id) — \(c.label)\(String(decoding: Array(c.params.utf8).dropFirst(2), as: UTF8.self))")
            } else {
                Out.line("\(c.id) — \(c.label): \(c.params)")
            }
        }
    }

    static func links() {
        Out.line("Discord   \(Links.discord)\nWebsite   \(Links.website)\nApp page  \(Links.appPage)\nGitHub    \(Links.github)")
    }

    /// `str::contains` on bytes.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        let h = Array(haystack.utf8), n = Array(needle.utf8)
        if n.isEmpty { return true }
        if n.count > h.count { return false }
        for i in 0 ... (h.count - n.count) where h[i] == n[0] && Array(h[i ..< i + n.count]) == n { return true }
        return false
    }

    // MARK: bench

    /// Median and slowest of `runs` timings of `f`, in milliseconds.
    static func timeMs(_ runs: Int, _ f: () throws(CLIFailure) -> Void) throws(CLIFailure) -> (Double, Double) {
        var ms: [Double] = []
        for _ in 0 ..< max(runs, 1) {
            let t = DispatchTime.now().uptimeNanoseconds
            try f()
            ms.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
        }
        ms.sort { $0 < $1 }
        return (ms.isEmpty ? 0 : ms[ms.count / 2], ms.last ?? 0)
    }

    /// Peak resident memory of this process in MiB: deckcraft reads Linux's `VmHWM`, so none here.
    static func peakRssMiB() -> Double? { nil }

    /// The performance baseline (deckcraft docs/gaps.md "No baseline"): how long a deck takes to open, to
    /// render each slide, to save and to export, and the peak memory, as JSON or a table.
    static func bench(_ args: [String]) throws(CLIFailure) {
        var input: String?
        var sample = false
        var runs = 5
        var asJSON = false
        var it = ArgStream(args)
        while let a = it.next() {
            switch a {
            case "--sample": sample = true
            case "--json": asJSON = true
            case "--runs":
                guard let n = it.next().flatMap(RustParse.usize), (1 ... 1000).contains(n) else { throw CLIFailure("--runs needs a number from 1 to 1000") }
                runs = n
            case let f where !f.hasPrefix("--") && input == nil: input = f
            default: throw CLIFailure("bench: unknown argument `\(a)`")
            }
        }
        if input == nil && !sample { throw CLIFailure("bench needs a FILE or --sample") }
        let s = Session()
        let name: String
        let bytes: [UInt8]
        if let p = input {
            name = p
            do { bytes = try FS.read(p) } catch { throw CLIFailure("\(p): \(error)") }
        } else {
            try open(s, nil, true)
            let doc: Presentation
            do { doc = try s.doc().doc } catch { throw CLIFailure(error.description) }
            name = "sample.deckcraft"
            bytes = try engine { try FileCommands.saveBytes(doc, "deckcraft") }
        }
        let doc = try engine { try FileCommands.openPresentation(name, bytes) }
        let slides = doc.slides.count
        let openTime = try timeMs(runs) { () throws(CLIFailure) in _ = try engine { try FileCommands.openPresentation(name, bytes) } }
        let opts = RenderOpts(scale: 1)
        var perSlide: [(Double, Double)] = []
        for i in 0 ..< slides {
            perSlide.append(try timeMs(runs) { () throws(CLIFailure) in _ = renderSlide(doc, i, opts) })
        }
        let pptx = try engine { try FileCommands.saveBytes(doc, "pptx") }
        var steps: [(String, (Double, Double))] = [
            ("open", openTime),
            ("save .deckcraft", try timeMs(runs) { () throws(CLIFailure) in _ = try engine { try FileCommands.saveBytes(doc, "deckcraft") } }),
            ("save .pptx", try timeMs(runs) { () throws(CLIFailure) in _ = try engine { try FileCommands.saveBytes(doc, "pptx") } }),
            ("open .pptx", try timeMs(runs) { () throws(CLIFailure) in _ = try engine { try FileCommands.openPresentation("bench.pptx", pptx) } }),
            ("export .pdf", try timeMs(runs) { () throws(CLIFailure) in _ = try engine { try FileCommands.saveBytes(doc, "pdf") } }),
        ]
        let renderTotal = perSlide.reduce(0) { $0 + $1.0 }
        let renderMax = perSlide.reduce(0.0) { Swift.max($0, $1.1) }
        steps.insert(("render all slides (1×)", (renderTotal, renderMax)), at: 1)
        let peak = peakRssMiB()
        if asJSON {
            let v: JSON = [
                "file": .string(name),
                "bytes": .integer(bytes.count),
                "slides": .integer(slides),
                "runs": .integer(runs),
                "steps": .array(steps.map { ["step": .string($0.0), "medianMs": .num($0.1.0), "maxMs": .num($0.1.1)] }),
                "renderMsPerSlide": .array(perSlide.map { .num($0.0) }),
                "peakRssMiB": peak.map { JSON.num($0) } ?? .null,
            ]
            Out.line(v.pretty)
        } else {
            Out.line("\(name): \(slides) slides, \(bytes.count / 1024) KiB, median of \(runs) runs")
            for (k, (m, x)) in steps {
                Out.line("  \(pad(k, 24)) \(padLeft(rustFixed(m, places: 1), 9)) ms   (slowest \(rustFixed(x, places: 1)) ms)")
            }
            if let (i, m) = perSlide.enumerated().max(by: { $0.element.0 < $1.element.0 }).map({ ($0.offset, $0.element) }) {
                Out.line("  slowest slide            \(padLeft(rustFixed(m.0, places: 1), 9)) ms   (slide \(i + 1))")
            }
            if let p = peak { Out.line("  peak memory              \(padLeft(rustFixed(p, places: 1), 9)) MiB") }
        }
    }

    /// A lower layer's error as deckcraft-cli prints an `EngineError`.
    static func engine<T>(_ body: () throws -> T) throws(CLIFailure) -> T {
        do { return try body() } catch { throw CLIFailure(EngineError.from(error).description) }
    }

    /// `{:<width$}` / `{:>width$}`: padded by characters.
    static func pad(_ s: String, _ width: Int) -> String { s + String(repeating: " ", count: max(0, width - s.count)) }
    static func padLeft(_ s: String, _ width: Int) -> String { String(repeating: " ", count: max(0, width - s.count)) + s }

    // MARK: info

    static func info(_ args: [String]) throws(CLIFailure) {
        if let a = args.first, isHelp(a) {
            Out.line(helpPage("info"))
            return
        }
        guard let path = args.first else { throw CLIFailure("info needs a FILE") }
        let s = Session()
        try open(s, path, false)
        let v = try execute(s, "document.inspect", .emptyObject)
        Out.line(v.pretty)
    }

    // MARK: render

    static func render(_ args: [String]) throws(CLIFailure) {
        var input: String?
        var sample = false
        var slide: Int?
        var all = false
        var scale = 2.0
        var edit = false
        var transparent = false
        var out: String?
        var it = ArgStream(args)
        while let a = it.next() {
            switch a {
            case "--sample": sample = true
            case "--transparent": transparent = true
            case "--slide":
                guard let n = it.next().flatMap(RustParse.usize) else { throw CLIFailure("--slide needs a number") }
                slide = n
            case "--all": all = true
            case "--edit": edit = true
            case "--scale":
                guard let v = it.next().flatMap({ rustParseF64($0) }) else { throw CLIFailure("--scale needs a number") }
                scale = v
            case "--help", "-h":
                Out.line(helpPage("render"))
                return
            case let other where other.hasPrefix("-"):
                throw CLIFailure("unknown option `\(other)`")
            case let other where input == nil && !sample && !other.hasPrefix("--") && out == nil && !(other.hasSuffix(".png") || other.hasSuffix(".jpg"))
                || (input == nil && !sample && FS.isFile(other)):
                input = other
            default:
                out = a
            }
        }
        guard let out else { throw CLIFailure("render needs an output path") }
        let s = Session()
        try open(s, input, sample)
        let st: DocState
        do { st = try s.doc() } catch { throw CLIFailure(error.description) }
        let n = st.doc.slides.count
        let list = try slideIndices(n, all, slide)
        if all {
            do { try FS.createDirAll(out) } catch { throw CLIFailure("\(out): \(error)") }
        }
        for i in list {
            let (png, w, h) = FileCommands.renderPNGWith(st.doc, i, scale, edit, transparent)
            let path = all ? "\(out)/slide-\(i + 1 < 10 ? "0" : "")\(i + 1).png" : out
            do { try FS.write(path, png) } catch { throw CLIFailure("\(path): \(error)") }
            Out.line("\(path) (\(w)×\(h))")
        }
    }

    /// Slides `--slide` asks for. `N` is a 0-based index, the same one `slide.go` uses. `--all` still names
    /// files from 1 (`slide-01.png`), which is PowerPoint's slide number.
    static func slideIndices(_ n: Int, _ all: Bool, _ slide: Int?) throws(CLIFailure) -> [Int] {
        if all { return Array(0 ..< n) }
        let i = slide ?? 0
        if i >= n { throw CLIFailure(missingSlide(i, n)) }
        return [i]
    }

    static func missingSlide(_ i: Int, _ n: Int) -> String {
        switch n {
        case 0: return "no slide index \(i) (this deck has no slides)"
        case 1: return "no slide index \(i) (this deck has 1 slide, index 0, which --all names slide-01.png)"
        default:
            let last = n - 1
            return "no slide index \(i) (this deck has \(n) slides, numbered 0 through \(last); --all names them slide-01.png through slide-\(n < 10 ? "0" : "")\(n).png)"
        }
    }

    // MARK: render-transition

    /// Frames of slide N's transition (0-based N; from slide N-1, or black for the first slide) at the given
    /// progress values. With several values, OUT gets `-t<value>` before its extension.
    static func renderTransition(_ args: [String]) throws(CLIFailure) {
        var input: String?
        var slide: Int?
        var ts: [Double] = []
        var width: Double?
        var out: String?
        var it = ArgStream(args)
        while let a = it.next() {
            switch a {
            case "--slide":
                guard let n = it.next().flatMap(RustParse.usize) else { throw CLIFailure("--slide needs a number") }
                slide = n
            case "--t":
                guard let v = it.next() else { throw CLIFailure("--t needs a value") }
                for x in v.split(separator: ",", omittingEmptySubsequences: false) {
                    guard let t = rustParseF64(rustTrim(String(x))), t.isFinite else { throw CLIFailure("bad --t value `\(x)`") }
                    ts.append(t)
                }
            case "--width":
                guard let w = it.next().flatMap({ rustParseF64($0) }), w.isFinite, w >= 1 else { throw CLIFailure("--width needs pixels") }
                width = w
            case let other where input == nil:
                input = other
            default:
                out = a
            }
        }
        guard let input else { throw CLIFailure("render-transition needs a FILE") }
        guard let out else { throw CLIFailure("render-transition needs an output path") }
        guard let i = slide else { throw CLIFailure("render-transition needs --slide N") }
        if ts.isEmpty { throw CLIFailure("render-transition needs --t") }
        let paths = try framePaths(out, ts)
        let s = Session()
        try open(s, input, false)
        let doc: Presentation
        do { doc = try s.doc().doc } catch { throw CLIFailure(error.description) }
        let n = doc.slides.count
        guard i < n else { throw CLIFailure("no slide \(i) (the deck has \(n))") }
        let sl = doc.slides[i]
        let sw = doc.slideSize.width.rustMax(1)
        let w = (width ?? sw * 2).rustMin(Double(maxRenderSide))
        let opts = RenderOpts(scale: w / sw)
        let tr = sl.transition ?? .default
        // Render both slides once and composite every frame from them (morph re-renders per frame).
        let prev: Int? = i > 0 ? i - 1 : nil
        var cached: (RenderImage?, RenderImage, SlideParts?)?
        if tr.kind != "morph" {
            let parts = usesSlideParts(tr.kind, tr.option) ? SlideParts.render(doc, prev, i, opts) : nil
            cached = (prev.map { renderSlide(doc, $0, opts) }, renderSlide(doc, i, opts), parts)
        }
        let aspect = sw / doc.slideSize.height.rustMax(1)
        for (t, path) in zip(ts, paths) {
            let img: RenderImage
            if let (old, new, parts) = cached {
                img = compositeTransition(old, new, parts, transitionFrame(tr.kind, tr.option, t, aspect))
            } else {
                img = DCRender.renderTransition(doc, i, t, opts)
            }
            do { try FS.write(path, ImageEncoding.png(img, dpi: ImageEncoding.dpiForScale(opts.scale))) } catch { throw CLIFailure("\(path): \(error)") }
            Out.line("\(path) (\(img.width)×\(img.height)) \(tr.kind) \(tr.option) t=\(t.rustDisplay)")
        }
    }

    /// Output path of each frame. A single frame goes to OUT; several get `-t<value>` (three decimals) before
    /// the extension. Values that round to the same name would overwrite each other, so that is an error.
    static func framePaths(_ out: String, _ ts: [Double]) throws(CLIFailure) -> [String] {
        if ts.count == 1 { return [out] }
        let stem = RustPath.fileStem(out) ?? "frame"
        var paths: [String] = []
        for t in ts {
            let path = RustPath.withFileName(out, "\(stem)-t\(rustFixed(t, places: 3)).png")
            if paths.contains(where: { rustEqual($0, path) }) {
                throw CLIFailure("--t values round to the same three decimals: more than one frame would be written to \(path)")
            }
            paths.append(path)
        }
        return paths
    }

    // MARK: convert

    static func convert(_ args: [String]) throws(CLIFailure) {
        if let a = args.first, isHelp(a) {
            Out.line(helpPage("convert"))
            return
        }
        guard args.count >= 2 else { throw CLIFailure("convert needs IN and OUT") }
        let (input, out) = (args[0], args[1])
        let fmt = try outputFormat(out)
        let s = Session()
        try open(s, input, false)
        if fmt == "png" || fmt == "jpeg" {
            _ = try execute(s, "file.export", ["path": .string(out), "slide": 0])
        } else if fmt == "gif" {
            _ = try execute(s, "file.export", ["path": .string(out)])
        } else {
            _ = try execute(s, "file.saveAs", ["path": .string(out)])
        }
        Out.line(out)
    }

    /// The format `convert`, `run --save` and `run --export` write to `path`, or an error naming the
    /// supported extensions when `path`'s extension isn't one (rather than native bytes under that name).
    static func outputFormat(_ path: String) throws(CLIFailure) -> String {
        if let f = FileCommands.writableFormatForPath(path) { return f }
        let ext = RustPath.ext(path).map { ".\($0)" } ?? "(none)"
        throw CLIFailure("\(path): unsupported output format \(ext) (supported: .\(FileCommands.writableExtensions.joined(separator: ", .")))")
    }

    // MARK: run

    static func run(_ args: [String]) throws(CLIFailure) {
        var input: String?
        var sample = false
        var cmds: [String] = []
        var save: String?
        var export: String?
        var exportParams = JSON.emptyObject
        var print = false
        var it = ArgStream(args)
        while let a = it.next() {
            switch a {
            case "--in":
                guard let v = it.next() else { throw CLIFailure("--in needs a file") }
                input = v
            case "--sample": sample = true
            case "--cmd":
                guard let v = it.next() else { throw CLIFailure("--cmd needs COMMAND[=PARAMS]") }
                cmds.append(v)
            case "--save":
                guard let v = it.next() else { throw CLIFailure("--save needs a path") }
                save = v
            case "--export":
                guard let v = it.next() else { throw CLIFailure("--export needs a path") }
                export = v
            case "--export-params":
                guard let j = it.next() else { throw CLIFailure("--export-params needs a JSON object") }
                do { exportParams = try parseJSON(j) } catch { throw CLIFailure("--export-params: bad JSON: \(error)") }
                if !exportParams.isObject { throw CLIFailure("--export-params must be a JSON object") }
            case "--print": print = true
            case "--help", "-h":
                Out.line(helpPage("run"))
                return
            default:
                throw CLIFailure("unknown option `\(a)`")
            }
        }
        for p in [save, export].compactMap({ $0 }) { _ = try outputFormat(p) }
        let s = Session()
        try open(s, input, sample)
        for c in cmds {
            let id: String
            let p: JSON
            if let eq = c.firstIndex(of: "=") {
                id = String(c[..<eq])
                do { p = try parseJSON(String(c[c.index(after: eq)...])) } catch { throw CLIFailure("\(id): bad JSON: \(error)") }
            } else {
                id = c
                p = .emptyObject
            }
            let r = try execute(s, id, p)
            if print { Out.line("\(id) → \(r.display)") }
        }
        if let p = save { _ = try execute(s, "file.saveAs", ["path": .string(p)]) }
        if let p = export {
            exportParams.set("path", .string(p))
            _ = try execute(s, "file.export", exportParams.canonical)
        } else if exportParams != .emptyObject {
            throw CLIFailure("--export-params needs --export OUT")
        }
    }

    // MARK: describe

    static func describe(_ id: String?) throws(CLIFailure) {
        if let id, isHelp(id) {
            Out.line(helpPage("describe"))
            return
        }
        guard let id else { throw CLIFailure("describe needs a command id") }
        guard let c = findCommand(id) else { throw CLIFailure(EngineError.unknownCommand(id).description) }
        var head = "\(c.id): \(c.label)"
        if !c.menu.isEmpty { head += ", in \(c.menu.joined(separator: " ▸ "))" }
        if let k = c.shortcut { head += ", shortcut \(k)" }
        Out.line("\(head).\n")
        let (args, answer) = splitOnce(c.params, "→") ?? (c.params, "")
        let parsed = Result { () throws(ParamDocError) -> [Param] in try Cmd.parseParams(c.params) }
        switch parsed {
        case .failure: Out.line("Parameters: \(rustTrim(args))")
        case .success(let ps) where ps.isEmpty: Out.line("Takes no parameters.")
        case .success(let ps): printParams(ps)
        }
        let params = (try? parsed.get()) ?? []
        if let acts = c.actsOn() { Out.line(acts) }
        let note = remark(args)
        if !note.isEmpty { Out.line("Note: \(note)") }
        if !rustTrim(answer).isEmpty { Out.line("Answers with \(rustTrim(answer)).") }
        let bare = params.isEmpty || params.contains { p in params.filter { $0.object == p.object }.allSatisfy(\.optional) }
        let call = bare ? c.id : "'\(c.id)={…}'"
        Out.line("\nRun it with: deckcraft-cli run --cmd \(call)")
    }

    /// `str::split_once` on a string separator.
    static func splitOnce(_ s: String, _ sep: String) -> (String, String)? {
        let b = Array(s.utf8), p = Array(sep.utf8)
        guard b.count >= p.count else { return nil }
        for i in 0 ... (b.count - p.count) where Array(b[i ..< i + p.count]) == p {
            return (String(decoding: b[..<i], as: UTF8.self), String(decoding: b[(i + p.count)...], as: UTF8.self))
        }
        return nil
    }

    static func printParams(_ params: [Param]) {
        func name(_ p: Param) -> String { "\(p.or ? "or " : "")\(p.name)\(p.optional ? ", optional" : "")" }
        let width = params.map { name($0).unicodeScalars.count }.max() ?? 0
        let sets = (params.map(\.object).max() ?? 0) > 0
        Out.line("Parameters:")
        for (k, p) in params.enumerated() {
            if sets && (k == 0 || params[k - 1].object != p.object) {
                Out.line("  \(p.object == 0 ? "either:" : "or:")")
            }
            let indent = sets ? "    " : "  "
            let n = name(p)
            let padded = n + String(repeating: " ", count: max(0, width - n.unicodeScalars.count))
            Out.line(String(rustTrimEnd(Substring("\(indent)\(padded)  \(p.about)"))))
        }
    }

    static func remark(_ args: String) -> String {
        let b = Array(args.utf8)
        let after: Substring
        if let i = b.lastIndex(of: UInt8(ascii: "}")) {
            after = Substring(String(decoding: b[(i + 1)...], as: UTF8.self))
        } else {
            after = ""
        }
        var t = rustTrim(String(after))
        while t.hasPrefix("—") { t = t.dropFirst() }
        let trimmed = rustTrim(String(t))
        if trimmed.hasPrefix("("), trimmed.hasSuffix(")"), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return String(trimmed)
    }

    // MARK: app

    static func app(_ args: [String]) throws(CLIFailure) {
        var port = String(Automation.defaultPort)
        var method: String?
        var rest: [String] = []
        var it = ArgStream(args)
        while let a = it.next() {
            switch a {
            case "--port":
                guard let v = it.next() else { throw CLIFailure("--port needs a value") }
                port = v
            case "--method":
                guard let v = it.next() else { throw CLIFailure("--method needs a name") }
                method = v
            case "--help", "-h":
                Out.line(helpPage("app"))
                return
            default:
                rest.append(a)
            }
        }
        let r: Remote
        do { r = try Remote.connect(Automation.controlAddr(port)) } catch {
            throw CLIFailure("no DeckCraft app on port \(port) (\(error)); start it with `deckcraft --control \(port)`")
        }
        func parse(_ s: String?) throws(CLIFailure) -> JSON {
            guard let s else { return .emptyObject }
            do { return try parseJSON(s) } catch { throw CLIFailure("bad JSON: \(error)") }
        }
        let v: JSON
        do {
            if let m = method {
                v = try r.call(m, try parse(rest.first))
            } else {
                guard let id = rest.first else { throw CLIFailure("app needs a COMMAND or --method") }
                v = try r.call("engine.execute", ["command": .string(id), "params": try parse(rest.count > 1 ? rest[1] : nil)])
            }
        } catch let e as CLIFailure {
            throw e
        } catch let e as AutomationError {
            throw CLIFailure(e.message)
        } catch {
            throw CLIFailure("\(error)")
        }
        Out.line(v.pretty)
    }

    // MARK: mcp

    static func mcp(_ args: [String]) throws(CLIFailure) {
        var connect: String?
        var sample = false
        var roots = AutomationArgs()
        var it = ArgStream(args)
        while let a = it.next() {
            if try roots.consume(a, &it) { continue }
            switch a {
            case "--connect":
                guard let v = it.next() else { throw CLIFailure("--connect needs a port or host:port") }
                connect = v
            case "--sample": sample = true
            case "--help", "-h":
                Out.line(helpPage("mcp"))
                return
            default:
                throw CLIFailure("unknown mcp option `\(a)`")
            }
        }
        let confined: AutomationRoots?
        do { confined = try AutomationRoots.make(read: roots.readRoot, write: roots.writeRoot) } catch { throw CLIFailure(error.message) }
        if confined != nil && connect != nil {
            throw CLIFailure("--automation-read-root and --automation-write-root confine the in-process server; a running app is not confined by them, so drop --connect (or use --connect without the roots)")
        }
        let backend: Backend
        if let c = connect {
            do { backend = try Remote.connect(Automation.controlAddr(c)) } catch { throw CLIFailure("can't reach the app at \(c): \(error)") }
        } else {
            let h = Headless()
            // `--sample` is the operator's own choice, made before the roots come into force.
            if sample {
                do { try Sample.openSample(h.session) } catch { throw CLIFailure(error.description) }
            }
            if let r = confined {
                // Every thread of this process, not only the server's: nothing reaches past the roots.
                FileAccess.confineProcess(r)
                Out.err("deckcraft-cli: files confined: read root \(r.readRoot ?? "none"), write root \(r.writeRoot ?? "none")")
                h.withAutomationRoots(r)
            }
            backend = h
        }
        let server = MCPServer(backend)
        let done = DispatchSemaphore(value: 0)
        let outcome = OutcomeBox()
        Task.detached {
            do throws(IOFailure) { try await server.serveStdio() } catch { outcome.failure = error }
            await server.stop()
            done.signal()
        }
        done.wait()
        if let e = outcome.failure { throw CLIFailure(e.message) }
    }
}

/// The MCP session's failure, handed back from its task.
final class OutcomeBox: @unchecked Sendable {
    var failure: IOFailure?
}
