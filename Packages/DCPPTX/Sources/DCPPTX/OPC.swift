// DCPPTX — Open Packaging Conventions: the zip container, part names, relationships and content types.
// Port of deckcraft crates/pptx/src/opc.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// The archive is read with DCZip's `ZipReader` and each entry is inflated here, so the budgets charge
// what deckcraft's `zip` crate (3.0.0) reading charges: an entry is read through `take(cap + 1)` and
// its CRC is checked only when it was read to its end. Entries with the same name collapse as the zip
// crate's `IndexMap` collapses them: the first one's place, the last one's data. The archive written
// by `PackageOut` matches deckcraft's entry for entry (names, order, contents, store or deflate); its
// DEFLATE streams and timestamps don't.
import Compression
import DCCore
import DCZip
import Synchronization

/// The `opc` module's free functions and constants.
enum OPC {
    /// Largest single part we decompress (media included).
    static let maxPart = 512 * 1024 * 1024
    /// Largest XML part we parse.
    static let maxXMLPart = 96 * 1024 * 1024
    /// Total decompressed bytes accepted for one package.
    static let maxTotal = 2 * 1024 * 1024 * 1024
    /// Total bytes we are willing to decompress for one package, counting parts we then discard (too
    /// large, or failing part-way): bounds inflate work, not just what is kept.
    static let maxInflateWork = 2 * maxTotal
    /// Maximum number of zip entries.
    static let maxEntries = 50_000

    static let nsA = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let nsR = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let nsP = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let nsC = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    static let nsMC = "http://schemas.openxmlformats.org/markup-compatibility/2006"
    static let nsP14 = "http://schemas.microsoft.com/office/powerpoint/2010/main"
    static let nsP15 = "http://schemas.microsoft.com/office/powerpoint/2012/main"
    static let nsP159 = "http://schemas.microsoft.com/office/powerpoint/2015/09/main"
    static let nsA14 = "http://schemas.microsoft.com/office/drawing/2010/main"
    /// Modern (threaded) comments, Office 2018/8 schema.
    static let nsP188 = "http://schemas.microsoft.com/office/powerpoint/2018/8/main"

    static let rtBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    static let rtMedia = "http://schemas.microsoft.com/office/2007/relationships/media"
    /// A 3-D model part (`.glb`). Office relationship, not an ECMA-376 base type.
    static let rtModel3D = "http://schemas.microsoft.com/office/2017/06/relationships/model3d"
    static let rtCore = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"

    /// A part name normalised: no leading slashes, `\` as `/`, ASCII lowercase.
    static func norm(_ name: String) -> String {
        let trimmed = trimLeadingSlashes(name)
        return String(decoding: trimmed.utf8.map { b -> UInt8 in
            if b == UInt8(ascii: "\\") { return UInt8(ascii: "/") }
            return b >= 0x41 && b <= 0x5A ? b + 32 : b
        }, as: UTF8.self)
    }

    /// `trim_start_matches('/')`.
    static func trimLeadingSlashes(_ s: String) -> Substring {
        let u = s.utf8
        guard let i = u.firstIndex(where: { $0 != UInt8(ascii: "/") }) else { return s[s.endIndex...] }
        return s[i...]
    }

    /// A part a chart may carry along beside its own `chartN.xml` (workbook, style, drawing, picture).
    /// Chart documents themselves are rewritten, and nothing outside these folders is copied: a
    /// relationship must not be able to replace `ppt/slides/slide1.xml` on save.
    static func sidecarPart(_ name: String) -> Bool {
        let n = norm(name)
        let segs = n.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        if segs.contains(where: { $0 == "." || $0 == ".." }) { return false }
        guard segs.count >= 2 else { return false }
        let root = segs[0], area = segs[1]
        if root != "ppt" || !["embeddings", "charts", "drawings", "media"].contains(area) { return false }
        let file = segs.last ?? ""
        let stem = hasBytePrefix(file, "chart") ? String(file.utf8.dropFirst(5)) ?? "" : ""
        let num: String
        if hasByteSuffix(stem, ".xml.rels") {
            num = String(stem.utf8.dropLast(9)) ?? ""
        } else if hasByteSuffix(stem, ".xml") {
            num = String(stem.utf8.dropLast(4)) ?? ""
        } else {
            num = ""
        }
        if !bytesEqual(stem, file), !num.isEmpty, num.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
            return false
        }
        return true
    }

    /// The folder of a part: before the last `/`, leading slashes dropped.
    static func dirOf(_ part: String) -> String {
        let p = trimLeadingSlashes(part)
        guard let i = p.utf8.lastIndex(of: UInt8(ascii: "/")) else { return "" }
        return String(p[..<i])
    }

    /// The file name of a part: after the last `/`.
    static func fileOf(_ part: String) -> String {
        guard let i = part.utf8.lastIndex(of: UInt8(ascii: "/")) else { return part }
        return String(part[part.utf8.index(after: i)...])
    }

    /// `ppt/slides/slide1.xml` → `ppt/slides/_rels/slide1.xml.rels`.
    static func relsPath(_ part: String) -> String {
        let p = String(trimLeadingSlashes(part))
        let dir = dirOf(p)
        let file = fileOf(p)
        return dir.isEmpty ? "_rels/\(file).rels" : "\(dir)/_rels/\(file).rels"
    }

    /// `%XX` (two hex digits) decoded; the bytes read as UTF-8, lossily.
    static func percentDecode(_ s: some StringProtocol) -> String {
        let b = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        func hex(_ x: UInt8) -> UInt8? {
            switch x {
            case 0x30 ... 0x39: x - 0x30
            case 0x41 ... 0x46: x - 0x41 + 10
            case 0x61 ... 0x66: x - 0x61 + 10
            default: nil
            }
        }
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "%"), i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) {
                out.append(h << 4 | l)
                i += 3
                continue
            }
            out.append(c)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Resolve a relative target against a base directory into a part name.
    static func resolve(_ base: String, _ target: String) -> String {
        let beforeHash = target.utf8.split(separator: UInt8(ascii: "#"), maxSplits: 1, omittingEmptySubsequences: false).first ?? []
        let decoded = percentDecode(String(decoding: beforeHash, as: UTF8.self))
        let t = String(decoding: decoded.utf8.map { $0 == UInt8(ascii: "\\") ? UInt8(ascii: "/") : $0 }, as: UTF8.self)
        var segs: [Substring] = hasBytePrefix(t, "/") ? [] : splitSlash(base).filter { !$0.isEmpty }
        for s in splitSlash(t) {
            switch s {
            case "", ".": break
            case "..": _ = segs.popLast()
            default: segs.append(s)
            }
        }
        return segs.joined(separator: "/")
    }

    /// `split('/')`, keeping empty pieces.
    private static func splitSlash(_ s: String) -> [Substring] {
        var out: [Substring] = []
        var start = s.startIndex
        for i in s.utf8.indices where s.utf8[i] == UInt8(ascii: "/") {
            out.append(s[start ..< i])
            start = s.utf8.index(after: i)
        }
        out.append(s[start...])
        return out
    }

    /// Relative target from the directory of `from` to part `to` (both absolute part names).
    static func relative(_ from: String, _ to: String) -> String {
        let fd = splitSlash(dirOf(from)).filter { !$0.isEmpty }
        let td = splitSlash(dirOf(to)).filter { !$0.isEmpty }
        var common = 0
        while common < fd.count, common < td.count, bytesEqual(fd[common], td[common]) { common += 1 }
        var out = ""
        for _ in common ..< fd.count { out += "../" }
        for s in td.dropFirst(common) {
            out += s
            out += "/"
        }
        out += fileOf(to)
        return out
    }

    /// The relationships in a parsed rels part, with internal targets resolved against `part`'s folder.
    static func relsOf(_ doc: XMLDoc, _ part: String) -> Rels {
        let base = dirOf(part)
        var out = Rels()
        for r in doc.root.childrenNamed("Relationship") {
            guard let id = r.attr("Id"), let ty = r.attr("Type"), let target = r.attr("Target") else { continue }
            let external = r.attr("TargetMode").map { rustASCIILowercase($0) == "external" } ?? false
            let kind = ty.utf8.lastIndex(of: UInt8(ascii: "/")).map { String(ty[ty.utf8.index(after: $0)...]) } ?? ty
            out.items.append(Rel(
                id: id, kind: kind, ty: ty, targetRaw: target,
                target: external ? target : resolve(base, target), external: external
            ))
        }
        return out
    }

    /// The relationships of `part` from the bytes of its rels part (kept parts carried by a chart).
    static func relsFromBytes(_ bytes: [UInt8], _ part: String) -> Rels {
        do {
            return relsOf(try XML.parse(bytes), part)
        } catch {
            PPTXLog.warn("pptx: relationships of \(part): \(error)")
            return Rels()
        }
    }
}

/// A string compared and hashed byte for byte, as Rust's `HashMap<String, _>` keys are (Swift's `==`
/// equates canonically equivalent strings).
struct ByteKey: Hashable, Sendable {
    let s: String

    init(_ s: String) { self.s = s }

    static func == (a: ByteKey, b: ByteKey) -> Bool { bytesEqual(a.s, b.s) }

    func hash(into h: inout Hasher) {
        var s = s
        s.withUTF8 { h.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}

/// The files of a package, keyed by normalised part name (no leading slash, lowercase).
final class Package: Sendable {
    private let parts: [ByteKey: (name: String, data: [UInt8])]
    /// Content types: (part overrides, extension defaults), read on first use.
    private let ctCache = Mutex<(overrides: [ByteKey: String], defaults: [ByteKey: String])?>(nil)

    private init(parts: [ByteKey: (name: String, data: [UInt8])]) {
        self.parts = parts
    }

    static func open(_ bytes: [UInt8]) throws(PPTXError) -> Package {
        try openWithin(bytes, maxPart: OPC.maxPart, maxTotal: OPC.maxTotal, maxWork: OPC.maxInflateWork)
    }

    /// `open` with explicit limits: per part, kept in total, and inflated in total.
    static func openWithin(_ bytes: [UInt8], maxPart: Int, maxTotal: Int, maxWork: Int) throws(PPTXError) -> Package {
        let zip: ZipReader
        do {
            zip = try ZipReader(bytes)
        } catch {
            throw .notPptx("\(error)")
        }
        // The zip crate's `IndexMap` of names: a repeated name keeps the first one's place and takes
        // the last one's data.
        var entries: [ZipEntry] = []
        var seen: [ByteKey: Int] = [:]
        for e in zip.entries {
            let key = ByteKey(e.name)
            if let k = seen[key] {
                entries[k] = e
            } else {
                seen[key] = entries.count
                entries.append(e)
            }
        }
        if entries.count > OPC.maxEntries {
            throw .notPptx("too many entries (\(entries.count))")
        }
        var parts: [ByteKey: (name: String, data: [UInt8])] = [:]
        var total = 0
        var work = 0
        for (i, f) in entries.enumerated() {
            if work >= maxWork {
                PPTXLog.warn("pptx: decompression budget spent; skipping the remaining \(entries.count - i) entries")
                break
            }
            guard f.method == 0 || f.method == 8 else {
                PPTXLog.warn("pptx: skipping unreadable zip entry \(i): unsupported compression method \(f.method)")
                continue
            }
            if let last = f.name.unicodeScalars.last, last == "/" || last == "\\" { continue }
            let name = String(OPC.trimLeadingSlashes(f.name))
            let declared = f.uncompressedSize
            if declared > maxPart {
                PPTXLog.warn("pptx: skipping oversized part \(name) (\(declared) bytes)")
                continue
            }
            let cap = Swift.min(maxPart, Swift.min(Swift.max(0, maxTotal - total), Swift.max(0, maxWork - work)))
            let (data, failure) = readEntry(zip.bytes, f, limit: cap == .max ? cap : cap + 1)
            // Charge what was inflated whether or not the part is kept.
            work = work.addingReportingOverflow(data.count).overflow ? .max : work + data.count
            if let failure {
                PPTXLog.warn("pptx: could not read \(name): \(failure)")
                continue
            }
            if data.count > cap {
                PPTXLog.warn("pptx: part \(name) exceeds size limits; skipped")
                continue
            }
            total = total.addingReportingOverflow(data.count).overflow ? .max : total + data.count
            parts[ByteKey(rustASCIILowercase(name))] = (name, data)
        }
        return Package(parts: parts)
    }

    /// An entry's bytes as `take(limit).read_to_end` reads them through the zip crate: at most `limit`
    /// bytes; when the entry ended first, its CRC is checked. A failure keeps what was read before it.
    private static func readEntry(_ archive: [UInt8], _ e: ZipEntry, limit: Int) -> (data: [UInt8], failure: String?) {
        let (end, overflow) = e.dataOffset.addingReportingOverflow(e.compressedSize)
        guard !overflow, e.dataOffset >= 0, end <= archive.count else { return ([], "zip entry out of range") }
        let raw = archive[e.dataOffset ..< end]
        var data: [UInt8]
        if e.method == 0 {
            data = Array(raw.prefix(limit))
            if raw.count >= limit { return (data, nil) }
        } else {
            let (out, complete, error) = inflate(raw, limit: limit)
            data = out
            if let error { return (data, error) }
            if !complete { return (data, nil) }
        }
        if CRC32.checksum(data) != e.crc { return (data, "Invalid checksum") }
        return (data, nil)
    }

    /// Raw DEFLATE, stopping after `limit` bytes. `complete` is true when the stream ended within the
    /// limit; `error` is set (with what came out before it) when the stream is malformed or cut off.
    /// miniz (the zip crate's inflater) reads a cut-off stream as ending there and leaves the verdict
    /// to the CRC; Compression can't tell the two apart, so both fail here.
    private static func inflate(_ src: ArraySlice<UInt8>, limit: Int) -> (out: [UInt8], complete: Bool, error: String?) {
        var out: [UInt8] = []
        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummy.deallocate() }
        var stream = compression_stream(dst_ptr: dummy, dst_size: 0, src_ptr: UnsafePointer(dummy), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return ([], false, "inflate init failed")
        }
        defer { compression_stream_destroy(&stream) }
        let chunk = 1 << 16
        var buffer = [UInt8](repeating: 0, count: chunk)
        let input = Array(src)
        return input.withUnsafeBufferPointer { s in
            stream.src_ptr = s.baseAddress ?? UnsafePointer(dummy)
            stream.src_size = s.count
            var stalled = 0
            while true {
                let status: compression_status = buffer.withUnsafeMutableBufferPointer { b in
                    stream.dst_ptr = b.baseAddress ?? dummy
                    stream.dst_size = chunk
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = chunk - stream.dst_size
                if produced > 0 {
                    let room = limit - out.count
                    if produced >= room {
                        // `take(limit)` stops here without asking for more, so the CRC isn't checked.
                        out.append(contentsOf: buffer[0 ..< room])
                        return (out, false, nil)
                    }
                    out.append(contentsOf: buffer[0 ..< produced])
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return (out, true, nil)
                case COMPRESSION_STATUS_OK:
                    // With the input used up, Compression reports a malformed or cut-off stream on
                    // the next call; two calls without progress end it in any case.
                    if produced == 0, stream.src_size == 0 {
                        stalled += 1
                        if stalled >= 2 { return (out, false, "corrupt deflate stream") }
                    } else {
                        stalled = 0
                    }
                default:
                    return (out, false, "corrupt deflate stream")
                }
            }
        }
    }

    func get(_ name: String) -> [UInt8]? {
        parts[ByteKey(OPC.norm(name))]?.data
    }

    /// An XML part's bytes, when it is within the XML size limit.
    func xmlBytes(_ name: String) -> [UInt8]? {
        guard let b = get(name) else { return nil }
        if b.count > OPC.maxXMLPart {
            PPTXLog.warn("pptx: XML part \(name) too large")
            return nil
        }
        return b
    }

    /// Parse an XML part.
    func xml(_ name: String) -> XMLDoc? {
        guard let b = get(name) else { return nil }
        if b.count > OPC.maxXMLPart {
            PPTXLog.warn("pptx: XML part \(name) too large")
            return nil
        }
        do {
            return try XML.parse(b)
        } catch {
            PPTXLog.warn("pptx: \(name): \(error)")
            return nil
        }
    }

    /// Relationships of a part (`ppt/slides/slide1.xml` → `ppt/slides/_rels/slide1.xml.rels`).
    func rels(_ part: String) -> Rels {
        guard let doc = xml(OPC.relsPath(part)) else { return Rels() }
        return OPC.relsOf(doc, part)
    }

    /// The content type of a part: its `Override`, else its extension's `Default`.
    func contentType(_ part: String) -> String? {
        let (overrides, defaults) = ctCache.withLock { cache in
            if let cache { return cache }
            var ov: [ByteKey: String] = [:]
            var def: [ByteKey: String] = [:]
            if let doc = xml("[Content_Types].xml") {
                for o in doc.root.childrenNamed("Override") {
                    if let n = o.attr("PartName"), let ct = o.attr("ContentType") {
                        ov[ByteKey(rustASCIILowercase(n))] = ct
                    }
                }
                for d in doc.root.childrenNamed("Default") {
                    if let e = d.attr("Extension"), let ct = d.attr("ContentType") {
                        def[ByteKey(rustASCIILowercase(e))] = ct
                    }
                }
            }
            cache = (ov, def)
            return (ov, def)
        }
        if let ct = overrides[ByteKey("/" + OPC.norm(part))] { return ct }
        let ext = part.utf8.lastIndex(of: UInt8(ascii: ".")).map { String(part[part.utf8.index(after: $0)...]) } ?? part
        return defaults[ByteKey(rustASCIILowercase(ext))]
    }

    /// The part's name as the archive spells it.
    func originalName(_ name: String) -> String? {
        parts[ByteKey(OPC.norm(name))]?.name
    }
}

/// One relationship.
struct Rel: Sendable, Equatable {
    var id: String
    /// Last segment of the relationship type (`slide`, `image`, `media`…).
    var kind: String
    /// Full relationship type URI.
    var ty: String
    /// `Target` as written in the rels part (relative path or URL).
    var targetRaw: String
    /// Absolute part name for internal targets; the URL for external ones.
    var target: String
    var external: Bool

    init(id: String = "", kind: String = "", ty: String = "", targetRaw: String = "", target: String = "", external: Bool = false) {
        self.id = id
        self.kind = kind
        self.ty = ty
        self.targetRaw = targetRaw
        self.target = target
        self.external = external
    }
}

/// A part's relationships.
struct Rels: Sendable, Equatable {
    var items: [Rel] = []

    func get(_ id: String) -> Rel? {
        items.first { bytesEqual($0.id, id) }
    }

    func target(_ id: String) -> String? {
        get(id)?.target
    }

    func firstOf(_ kind: String) -> Rel? {
        items.first { bytesEqual($0.kind, kind) }
    }

    func allOf(_ kind: String) -> [Rel] {
        items.filter { bytesEqual($0.kind, kind) }
    }
}

// MARK: - Writing

/// Relationships being built for one part.
struct RelsOut {
    /// (id, type URI, target, external).
    var items: [(id: String, ty: String, target: String, external: Bool)] = []

    private static func type(_ kind: String) -> String {
        hasBytePrefix(kind, "http") ? kind : OPC.rtBase + kind
    }

    /// Add (or reuse) a relationship; `kind` is a full type URI or a suffix of the standard base.
    mutating func add(_ kind: String, _ target: String, _ external: Bool) -> String {
        let ty = Self.type(kind)
        if let r = items.first(where: { bytesEqual($0.ty, ty) && bytesEqual($0.target, target) && $0.external == external }) {
            return r.id
        }
        let id = "rId\(items.count + 1)"
        items.append((id, ty, target, external))
        return id
    }

    /// Always add a new relationship even if an identical one exists.
    mutating func addNew(_ kind: String, _ target: String, _ external: Bool) -> String {
        let id = "rId\(items.count + 1)"
        items.append((id, Self.type(kind), target, external))
        return id
    }

    func toXML() -> [UInt8] {
        var w = W.new()
        w.open("Relationships", A().a("xmlns", "http://schemas.openxmlformats.org/package/2006/relationships"))
        for (id, ty, target, ext) in items {
            var a = A().a("Id", id).a("Type", ty).a("Target", target)
            if ext { a = a.a("TargetMode", "External") }
            w.empty("Relationship", a)
        }
        w.close("Relationships")
        return w.finish()
    }
}

/// A package being written.
struct PackageOut {
    /// (name, data, compress).
    var files: [(name: String, data: [UInt8], compress: Bool)] = []
    var defaults: [(ext: String, contentType: String)] = [
        ("rels", "application/vnd.openxmlformats-package.relationships+xml"),
        ("xml", "application/xml"),
    ]
    var overrides: [(part: String, contentType: String)] = []

    /// Add an XML part with its content type override.
    mutating func xmlPart(_ name: String, _ contentType: String, _ data: [UInt8]) {
        overrides.append(("/" + name, contentType))
        files.append((name, data, true))
    }

    mutating func rels(_ part: String, _ rels: RelsOut) {
        if rels.items.isEmpty { return }
        let path = OPC.relsPath(part)
        if let i = files.firstIndex(where: { bytesEqual($0.name, path) }) {
            files[i].data = rels.toXML()
        } else {
            files.append((path, rels.toXML(), true))
        }
    }

    /// Add a part with no content type of its own (a relationships part).
    mutating func raw(_ name: String, _ data: [UInt8]) {
        files.append((name, data, true))
    }

    /// Add a binary part; its extension gets a Default content type.
    mutating func binary(_ name: String, _ contentType: String, _ data: [UInt8]) {
        let last = name.utf8.lastIndex(of: UInt8(ascii: ".")).map { String(name[name.utf8.index(after: $0)...]) } ?? name
        let ext = rustASCIILowercase(last)
        if !defaults.contains(where: { bytesEqual($0.ext, ext) }) {
            defaults.append((ext, contentType))
        } else if !defaults.contains(where: { bytesEqual($0.ext, ext) && bytesEqual($0.contentType, contentType) }) {
            overrides.append(("/" + name, contentType))
        }
        files.append((name, data, false))
    }

    /// `[Content_Types].xml`.
    func contentTypesXML() -> [UInt8] {
        var ct = W.new()
        ct.open("Types", A().a("xmlns", "http://schemas.openxmlformats.org/package/2006/content-types"))
        for (e, c) in defaults {
            ct.empty("Default", A().a("Extension", e).a("ContentType", c))
        }
        for (p, c) in overrides {
            ct.empty("Override", A().a("PartName", p).a("ContentType", c))
        }
        ct.close("Types")
        return ct.finish()
    }

    /// The zip: `[Content_Types].xml` first (deflated), then each part in order (XML deflated, binary
    /// stored); a second part under a name already written is dropped.
    func finish() throws(PPTXError) -> [UInt8] {
        do {
            var zw = ZipWriter()
            try zw.add("[Content_Types].xml", contentTypesXML(), compress: true)
            var written = Set<ByteKey>()
            for (name, data, compress) in files {
                // Zip entry names must be unique: a second part under a name already written is
                // dropped rather than producing a package readers reject or resolve differently.
                if !written.insert(ByteKey(OPC.norm(name))).inserted {
                    PPTXLog.warn("pptx: part \(name) written twice; keeping the first")
                    continue
                }
                try zw.add(name, data, compress: compress)
            }
            return try zw.finish()
        } catch {
            throw .write("\(error)")
        }
    }
}
