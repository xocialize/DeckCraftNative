// DCMedia — the Matroska / WebM demuxer: the EBML header, the Segment walk (with resync over damage),
// SeekHead, Info and Tracks, and the cluster scan that builds per-track frame tables. Port of craft-media
// crates/media/src/matroska/{ebml,demux,track,codec,meta,ids}.rs (craft-libs at the rev deckcraft's
// Cargo.toml pins, MIT OR Apache-2.0, © the craft-libs contributors), which deckcraft-matroska re-exports.
//
// Ported: everything that decides what `open` returns or which error it fails with, and what deckcraft-media
// reads. Left out because nothing in deckcraft-media reads them and they can't fail: the contents of Cues,
// Chapters, Tags and Attachments (their elements are still walked and charged against the metadata
// budget), CRC checking (off by default) and the packet-streaming `Demuxer`.

import DCCore

private enum EBMLID {
    static let ebml: UInt32 = 0x1A45_DFA3
    static let ebmlMaxIDLength: UInt32 = 0x42F2
    static let ebmlMaxSizeLength: UInt32 = 0x42F3
    static let docType: UInt32 = 0x4282
    static let crc32: UInt32 = 0xBF
    static let void: UInt32 = 0xEC
    static let segment: UInt32 = 0x1853_8067
    static let seekHead: UInt32 = 0x114D_9B74
    static let info: UInt32 = 0x1549_A966
    static let tracks: UInt32 = 0x1654_AE6B
    static let cluster: UInt32 = 0x1F43_B675
    static let cues: UInt32 = 0x1C53_BB6B
    static let attachments: UInt32 = 0x1941_A469
    static let chapters: UInt32 = 0x1043_A770
    static let tags: UInt32 = 0x1254_C367
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC
    static let timestampScale: UInt32 = 0x2A_D7B1
    static let duration: UInt32 = 0x4489
    static let timestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let blockDuration: UInt32 = 0x9B
    static let referenceBlock: UInt32 = 0xFB
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let flagDefault: UInt32 = 0x88
    static let defaultDuration: UInt32 = 0x23_E383
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let codecDelay: UInt32 = 0x56AA
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let audio: UInt32 = 0xE1
    static let samplingFrequency: UInt32 = 0xB5
    static let outputSamplingFrequency: UInt32 = 0x78B5
    static let channels: UInt32 = 0x9F
    static let bitDepth: UInt32 = 0x6264
    static let contentEncodings: UInt32 = 0x6D80
    static let contentEncoding: UInt32 = 0x6240
    static let contentEncodingOrder: UInt32 = 0x5031
    static let contentEncodingScope: UInt32 = 0x5032
    static let contentEncodingType: UInt32 = 0x5033
    static let contentCompression: UInt32 = 0x5034
    static let contentCompAlgo: UInt32 = 0x4254
    static let contentCompSettings: UInt32 = 0x4255

    static func isTopLevel(_ id: UInt32) -> Bool {
        [ebml, segment, seekHead, info, tracks, cluster, cues, attachments, chapters, tags].contains(id)
    }
}

/// craft-media's `matroska::Error`; `message` is its `Display`.
enum MKVError: Error, Equatable {
    case io(String)
    case invalid(String)
    case unsupported(String)
    case notMatroska(String)
    case noSuchTrack(Int)
    case noSuchSample(Int)
    case tooLarge(String)

    var message: String {
        switch self {
        case .io(let s): "I/O error: \(s)"
        case .invalid(let s): "invalid data: \(s)"
        case .unsupported(let s): "unsupported: \(s)"
        case .notMatroska(let s): "not a Matroska/WebM file: \(s)"
        case .noSuchTrack(let i): "track index \(i) out of range"
        case .noSuchSample(let i): "sample index \(i) out of range"
        case .tooLarge(let s): "size limit exceeded: \(s)"
        }
    }
}

// MARK: EBML primitives

enum EBML {
    enum Size: Equatable {
        case known(UInt64)
        case unknown

        var known: UInt64? { if case .known(let n) = self { n } else { nil } }
    }

    /// An unsigned VINT: (value, length, all value bits set).
    static func readVint(_ d: Slice) -> (UInt64, Int, Bool)? {
        guard let first = d.first, first != 0 else { return nil }
        let len = first.leadingZeroBitCount + 1
        guard d.count >= len else { return nil }
        let mask: UInt8 = len == 8 ? 0 : 0xFF >> len
        var v = UInt64(first & mask)
        for b in d.dropFirst().prefix(len - 1) { v = v << 8 | UInt64(b) }
        let ones = v == (UInt64(1) << UInt64(7 * len)) &- 1
        return (v, len, ones)
    }

    static func readSize(_ d: Slice) -> (Size, Int)? {
        guard let (v, len, ones) = readVint(d) else { return nil }
        return (ones ? .unknown : .known(v), len)
    }

    /// An element ID (marker bits kept, 1–4 bytes).
    static func readID(_ d: Slice) -> (UInt32, Int)? {
        guard let first = d.first, first != 0 else { return nil }
        let len = first.leadingZeroBitCount + 1
        guard len <= 4, d.count >= len else { return nil }
        guard let (v, _, ones) = readVint(d.prefix(len)) else { return nil }
        if ones || (v == 0 && len > 1) { return nil }
        var id: UInt32 = 0
        for b in d.prefix(len) { id = id << 8 | UInt32(b) }
        return (id, len)
    }

    /// A signed VINT as EBML lacing uses it.
    static func readSvint(_ d: Slice) -> (Int64, Int)? {
        guard let (v, len, _) = readVint(d) else { return nil }
        let bias = (Int64(1) << Int64(7 * len - 1)) - 1
        return (Int64(bitPattern: v) &- bias, len)
    }

    static func uint(_ d: Slice) -> UInt64 { d.prefix(8).reduce(0) { $0 << 8 | UInt64($1) } }

    static func int(_ d: Slice) -> Int64 {
        let n = min(d.count, 8)
        if n == 0 { return 0 }
        let v = uint(d.prefix(n))
        let shift = UInt64(64 - 8 * n)
        return Int64(bitPattern: v << shift) >> Int64(shift)
    }

    static func float(_ d: Slice) -> Double {
        switch d.count {
        case 4: Double(Float(bitPattern: UInt32(truncatingIfNeeded: uint(d))))
        case 8: Double(bitPattern: uint(d))
        default: 0
        }
    }

    /// Bytes up to the first NUL, lossily decoded.
    static func string(_ d: Slice) -> String {
        let end = d.firstIndex(of: 0) ?? d.endIndex
        return String(decoding: d[d.startIndex..<end], as: UTF8.self)
    }

    struct Elem {
        var id: UInt32
        var data: Slice
    }

    /// The children of an in-memory master element; damage ends the iteration and oversize elements
    /// are cut at the parent's end.
    static func children(_ d: Slice) -> [Elem] {
        var out: [Elem] = []
        var pos = d.startIndex
        while pos < d.endIndex {
            let rest = d[pos..<d.endIndex]
            guard let (id, il) = readID(rest), let (size, sl) = readSize(rest.dropFirst(il)) else { break }
            let hl = il + sl
            let avail = UInt64(rest.count - hl)
            let len: Int
            switch size {
            case .known(let n) where n <= avail: len = Int(n)
            default: len = Int(avail)
            }
            out.append(Elem(id: id, data: d[(pos + hl)..<(pos + hl + len)]))
            pos += hl + len
        }
        return out
    }

    enum Lacing { case none, xiph, fixedSize, ebml }

    static func lacing(_ flags: UInt8) -> Lacing {
        switch (flags >> 1) & 3 {
        case 0: .none
        case 1: .xiph
        case 2: .fixedSize
        default: .ebml
        }
    }

    /// Frames of a laced block as (offset, length) relative to `data` (which starts after the flags).
    static func parseLacing(_ lacing: Lacing, _ data: Slice) -> [(Int, Int)]? {
        if lacing == .none { return [(0, data.count)] }
        guard let n1 = data.first else { return nil }
        let count = Int(n1) + 1
        let s = data.startIndex
        var pos = 1
        var sizes: [Int] = []
        sizes.reserveCapacity(count)
        switch lacing {
        case .none: return [(0, data.count)]
        case .xiph:
            for _ in 0..<(count - 1) {
                var size = 0
                while true {
                    guard pos < data.count else { return nil }
                    let b = data[s + pos]
                    pos += 1
                    size += Int(b)
                    if b != 255 { break }
                }
                sizes.append(size)
            }
        case .ebml:
            if count > 1 {
                guard let (first, l, _) = readVint(data.dropFirst(pos)) else { return nil }
                pos += l
                var prev = Int64(bitPattern: first)
                sizes.append(Int(truncatingIfNeeded: first))
                for _ in 1..<(count - 1) {
                    guard let (d, l2) = readSvint(data.dropFirst(pos)) else { return nil }
                    pos += l2
                    prev &+= d
                    if prev < 0 { return nil }
                    sizes.append(Int(prev))
                }
            }
        case .fixedSize:
            let rest = data.count - pos
            if rest % count != 0 { return nil }
            sizes.append(contentsOf: repeatElement(rest / count, count: count - 1))
        }
        var used = 0
        for x in sizes {
            let (u, o) = used.addingReportingOverflow(x)
            if o {
                used = Int.max
                break
            }
            used = u
        }
        if pos > data.count || used > data.count - pos { return nil }
        sizes.append(data.count - pos - used)
        var out: [(Int, Int)] = []
        out.reserveCapacity(count)
        for x in sizes {
            out.append((pos, x))
            pos += x
        }
        return out
    }
}

// MARK: Model

enum MKVTrackKind: Equatable { case video, audio, other }

/// A track's codec (craft-media's `matroska::Codec`), keeping what the decoders need.
enum MKVCodec: Equatable {
    case avc(avcc: [UInt8])
    case hevc(hvcc: [UInt8])
    case vp8
    case vp9(privateData: [UInt8])
    case av1(av1c: [UInt8])
    case apv, mjpeg
    /// `V_PRORES`; the FourCC from `CodecPrivate`, if present.
    case proRes(fourcc: [UInt8]?)
    case vfw(String)
    case aac(asc: [UInt8])
    case opus(head: [UInt8])
    case vorbis
    case flac(privateData: [UInt8])
    case pcm(float: Bool, bigEndian: Bool, bits: UInt16)
    case ac3, eac3, mp3, mp2, mp1, subrip, webvtt
    case ass(ssa: Bool)
    case other(String)

    /// craft-media's `Codec::name`.
    var shortName: String {
        switch self {
        case .avc: "h264"
        case .hevc: "hevc"
        case .vp8: "vp8"
        case .vp9: "vp9"
        case .av1: "av1"
        case .apv: "apv"
        case .proRes: "prores"
        case .mjpeg: "mjpeg"
        case .vfw(let s): s
        case .aac: "aac"
        case .opus: "opus"
        case .vorbis: "vorbis"
        case .flac: "flac"
        case .pcm(let float, let big, let bits):
            if bits == 8 { "pcm_\(float ? "f" : "u")8" } else { "pcm_\(float ? "f" : "s")\(bits)\(big ? "be" : "le")" }
        case .ac3: "ac3"
        case .eac3: "eac3"
        case .mp3: "mp3"
        case .mp2: "mp2"
        case .mp1: "mp1"
        case .subrip: "subrip"
        case .webvtt: "webvtt"
        case .ass(let ssa): ssa ? "ssa" : "ass"
        case .other(let id): id
        }
    }

    /// deckcraft-media's `mkv_codec_name`.
    var name: String {
        switch self {
        case .avc: "H.264"
        case .hevc: "HEVC"
        case .vp8: "VP8"
        case .vp9: "VP9"
        case .av1: "AV1"
        case .aac: "AAC"
        case .opus: "Opus"
        case .vorbis: "Vorbis"
        case .flac: "FLAC"
        case .mp3: "MP3"
        case .pcm: "PCM"
        default: shortName
        }
    }
}

struct MKVAudio {
    var samplingFrequency: Double = 8000
    var outputSamplingFrequency: Double?
    var channels: UInt64 = 1
    var bitDepth: UInt64?
}

enum MKVEncoding {
    case headerStripping(bytes: [UInt8], scope: UInt64)
    case compression(scope: UInt64)
    case encryption(scope: UInt64)
}

struct MKVSample {
    var offset: UInt64
    var size: UInt32
    var pts: Int64
    var duration: UInt64
    var keyframe: Bool
}

struct MKVTrack {
    var number: UInt64 = 0
    var kind: MKVTrackKind = .other
    var isDefault = true
    var defaultDurationNs: UInt64?
    var codecID = ""
    var codecPrivate: [UInt8] = []
    var codec: MKVCodec = .other("")
    var codecDelayNs: UInt64 = 0
    var pixelWidth: UInt32?
    var pixelHeight: UInt32?
    var audio: MKVAudio?
    var encodings: [MKVEncoding] = []
    /// Seconds per tick (num, den).
    var timebase: (UInt64, UInt64) = (1, 1000)
    var samples: [MKVSample] = []

    var strippedHeader: [UInt8]? {
        for e in encodings {
            if case .headerStripping(let bytes, let scope) = e, scope & 1 != 0 { return bytes }
        }
        return nil
    }

    var framesReadable: Bool {
        encodings.allSatisfy {
            switch $0 {
            case .headerStripping: true
            case .compression(let scope), .encryption(let scope): scope & 1 == 0
            }
        }
    }

    func framePrefix(_ storedSize: UInt64) -> [UInt8] {
        var p = strippedHeader ?? []
        if case .proRes = codec {
            let total = storedSize &+ UInt64(p.count) &+ 8
            let t = UInt32(truncatingIfNeeded: total)
            p = [UInt8(t >> 24), UInt8(truncatingIfNeeded: t >> 16), UInt8(truncatingIfNeeded: t >> 8), UInt8(truncatingIfNeeded: t)]
                + Array("icpf".utf8) + p
        }
        return p
    }
}

struct MKVFile {
    var docType = "matroska"
    var segmentDataStart: UInt64 = 0
    var segmentEnd: UInt64 = 0
    var timestampScale: UInt64 = 1_000_000
    var duration: Double?
    var tracks: [MKVTrack] = []
    var seekHead: [(UInt32, UInt64)] = []
    var firstCluster: UInt64?

    var isWebM: Bool { docType == "webm" }

    /// Segment duration in ns: `Info/Duration` if present, else the end of the last indexed frame.
    var durationNs: UInt64? {
        if let d = duration { return UInt64(rustCast: (d * Double(timestampScale)).rounded()) }
        var end: Int64?
        for t in tracks {
            for s in t.samples {
                let e = s.pts.addingSaturating(Int64(min(s.duration, UInt64(Int64.max))))
                end = max(end ?? e, e)
            }
        }
        guard let end else { return nil }
        return UInt64(max(end, 0)).multipliedSaturating(timestampScale)
    }

    func readSample(_ src: [UInt8], _ track: Int, _ index: Int) throws(MKVError) -> [UInt8] {
        guard let t = tracks.at(track) else { throw .noSuchTrack(track) }
        guard let s = t.samples.at(index) else { throw .noSuchSample(index) }
        if !t.framesReadable { throw .unsupported("content encoding of track \(t.number) (compression/encryption)") }
        let (end, o) = s.offset.addingReportingOverflow(UInt64(s.size))
        guard !o, end <= UInt64(src.count) else { throw .io("read past end of byte source") }
        return t.framePrefix(UInt64(s.size)) + src[Int(s.offset)..<Int(end)]
    }
}

// MARK: Open

private let window = 64 * 1024
private let maxMeta: UInt64 = 256 << 20
private let maxFrames = 1 << 26
private let fileBytesPerFrame: UInt64 = 8
private let minFrameAllowance = 1 << 20
private let maxTracks = 1 << 16
private let maxTimestampScale: UInt64 = 1 << 32
private let maxStrippedHeader = 256

private struct Hdr {
    var id: UInt32
    var pos: UInt64
    var size: EBML.Size
    var hlen: Int

    var dataStart: UInt64 { pos &+ UInt64(hlen) }
    func end(_ limit: UInt64) -> UInt64 {
        switch size {
        case .known(let n): min(dataStart.addingSaturating(n), limit)
        case .unknown: limit
        }
    }
    func overruns(_ limit: UInt64) -> Bool {
        if case .known(let n) = size { return dataStart.addingSaturating(n) > limit }
        return false
    }
}

private struct FrameBudget {
    var frames: Int
    var bytes: UInt64

    init(_ fileLen: UInt64) {
        frames = min(max(Int(clamping: fileLen / fileBytesPerFrame), minFrameAllowance), maxFrames)
        bytes = fileLen
    }

    mutating func take(_ f: [(UInt64, UInt32)]) throws(MKVError) {
        guard f.count <= frames else { throw .tooLarge("frame count") }
        frames -= f.count
        let b = f.reduce(UInt64(0)) { $0 &+ UInt64(max($1.1, 1)) }
        guard b <= bytes else { throw .tooLarge("frame count") }
        bytes -= b
    }
}

private struct BlockRef {
    var track: Int
    var ts: Int64
    var frames: [(UInt64, UInt32)]
    var blockDuration: UInt64?
    var keyframe: Bool
}

/// The file in memory, with craft-media's windowed reads (`peek` returns at most 64 KiB).
private struct IO {
    let src: [UInt8]
    var len: UInt64 { UInt64(src.count) }

    func peek(_ pos: UInt64, _ n: Int) -> Slice {
        let n = min(n, window)
        if pos >= len { return src[src.endIndex..<src.endIndex] }
        let end = min(pos + UInt64(n), len)
        return src[Int(pos)..<Int(end)]
    }

    func readVec(_ pos: UInt64, _ n: UInt64) throws(MKVError) -> Slice {
        let (e, o) = pos.addingReportingOverflow(n)
        if o || e > len { throw .io("read past end of file") }
        return src[Int(pos)..<Int(e)]
    }

    func header(_ pos: UInt64, _ limit: UInt64) -> Hdr? {
        if pos >= limit { return nil }
        let b = peek(pos, 12)
        guard let (id, il) = EBML.readID(b), let (size, sl) = EBML.readSize(b.dropFirst(il)) else { return nil }
        let hlen = il + sl
        if pos + UInt64(hlen) > limit { return nil }
        return Hdr(id: id, pos: pos, size: size, hlen: hlen)
    }

    /// Scan forward for a plausible level-1 element (Cluster preferred).
    func resync(_ from: UInt64, _ limit: UInt64) -> UInt64? {
        var pos = from
        while pos + 4 <= limit {
            let chunk = peek(pos, window)
            if chunk.count < 4 { return nil }
            let s = chunk.startIndex
            for i in 0..<(chunk.count - 3) {
                if chunk[s + i] & 0xF0 != 0x10 { continue }
                let id = UInt32(chunk[s + i]) << 24 | UInt32(chunk[s + i + 1]) << 16 | UInt32(chunk[s + i + 2]) << 8 | UInt32(chunk[s + i + 3])
                if !EBMLID.isTopLevel(id) || id == EBMLID.ebml || id == EBMLID.segment { continue }
                let p = pos + UInt64(i)
                if plausible(p, id, limit) { return p }
            }
            pos += UInt64(chunk.count - 3)
        }
        return nil
    }

    func plausible(_ p: UInt64, _ id: UInt32, _ limit: UInt64) -> Bool {
        guard let h = header(p, limit), h.id == id, !h.overruns(limit) else { return false }
        if h.size == .unknown && id != EBMLID.cluster { return false }
        var cp = h.dataStart
        let end = h.end(limit)
        for _ in 0..<3 {
            guard let c = header(cp, end), !c.overruns(end) else { return false }
            if id != EBMLID.cluster { return true }
            switch c.id {
            case EBMLID.timestamp: return true
            case EBMLID.crc32, EBMLID.void: cp = c.end(end)
            default: return false
            }
        }
        return false
    }

    func unknownEnd(_ dataStart: UInt64, _ limit: UInt64) -> UInt64 {
        var pos = dataStart
        while pos < limit {
            guard let h = header(pos, limit) else { return pos }
            if EBMLID.isTopLevel(h.id) || h.size == .unknown { return pos }
            pos = h.end(limit)
        }
        return limit
    }
}

enum Matroska {
    /// Open a Matroska/WebM file and index every frame.
    static func open(_ src: [UInt8]) throws(MKVError) -> MKVFile {
        let io = IO(src: src)
        let len = io.len
        let head = io.peek(0, window)
        guard let startIdx = findMagic(head) else { throw .notMatroska("no EBML header") }
        let start = UInt64(startIdx - head.startIndex)
        guard let eh = io.header(start, len) else { throw .notMatroska("bad EBML header") }
        let hdrEnd = eh.end(len)
        let hdr = try io.readVec(eh.dataStart, hdrEnd - eh.dataStart)
        var docType = "matroska"
        for e in EBML.children(hdr) {
            switch e.id {
            case EBMLID.docType: docType = EBML.string(e.data)
            case EBMLID.ebmlMaxIDLength where EBML.uint(e.data) > 4: throw .unsupported("EBMLMaxIDLength > 4")
            case EBMLID.ebmlMaxSizeLength where EBML.uint(e.data) > 8: throw .unsupported("EBMLMaxSizeLength > 8")
            default: break
            }
        }
        if docType != "matroska" && docType != "webm" { throw .notMatroska("DocType \(rustDebug(docType))") }
        var pos = hdrEnd
        var seg: Hdr
        while true {
            guard let h = io.header(pos, len) else { throw .invalid("no Segment") }
            if h.id == EBMLID.segment {
                seg = h
                break
            }
            if h.size == .unknown { throw .invalid("unknown-size element before Segment") }
            pos = h.end(len)
        }
        var file = MKVFile(docType: docType, segmentDataStart: seg.dataStart, segmentEnd: seg.end(len))
        var w = Walker(metaLeft: len, budget: FrameBudget(len))
        try w.walk(io, &file)
        let g = gcd(file.timestampScale, 1_000_000_000)
        for i in file.tracks.indices { file.tracks[i].timebase = (file.timestampScale / g, 1_000_000_000 / g) }
        return file
    }

    private static func findMagic(_ b: Slice) -> Int? {
        guard b.count >= 4 else { return nil }
        let s = b.startIndex
        for i in s...(b.endIndex - 4) where b[i] == 0x1A && b[i + 1] == 0x45 && b[i + 2] == 0xDF && b[i + 3] == 0xA3 { return i }
        return nil
    }

    static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }

    /// Rust's `{:?}` of a `String`.
    static func rustDebug(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\0": out += "\\0"
            default:
                if u.value < 0x20 || u.value == 0x7F || (0x80..<0xA0).contains(u.value) {
                    out += "\\u{\(String(u.value, radix: 16))}"
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    fileprivate struct Walker {
        var parsed: [UInt64: UInt64] = [:]
        var metaLeft: UInt64
        var lookup: [UInt64: Int]?
        var budget: FrameBudget

        mutating func walk(_ io: IO, _ file: inout MKVFile) throws(MKVError) {
            let segEnd = file.segmentEnd
            var pos = file.segmentDataStart
            while pos < segEnd {
                guard let h = io.header(pos, segEnd) else {
                    if let p = io.resync(pos + 1, segEnd) {
                        pos = p
                        continue
                    }
                    break
                }
                switch h.id {
                case EBMLID.cluster:
                    if file.firstCluster == nil {
                        file.firstCluster = h.pos
                        try followSeekHead(io, &file, [EBMLID.info, EBMLID.tracks])
                    }
                    if lookup == nil { lookup = trackIndex(file.tracks) }
                    let (end, blocks) = try scanCluster(io, h, segEnd, lookup ?? [:])
                    addBlocks(&file, blocks)
                    pos = max(end, h.dataStart)
                case EBMLID.seekHead, EBMLID.info, EBMLID.tracks, EBMLID.cues, EBMLID.chapters, EBMLID.tags, EBMLID.attachments:
                    pos = try level1(io, &file, h, segEnd)
                case EBMLID.ebml, EBMLID.segment:
                    pos = segEnd
                default:
                    if h.size == .unknown {
                        pos = io.unknownEnd(h.dataStart, segEnd)
                    } else if h.overruns(segEnd) && h.id != EBMLID.void {
                        guard let p = io.resync(pos + 1, segEnd) else {
                            pos = segEnd
                            continue
                        }
                        pos = p
                    } else {
                        pos = h.end(segEnd)
                    }
                }
            }
            try followSeekHead(io, &file, [EBMLID.info, EBMLID.tracks, EBMLID.cues, EBMLID.chapters, EBMLID.tags, EBMLID.attachments, EBMLID.seekHead])
            try followSeekHead(io, &file, [EBMLID.cues, EBMLID.chapters, EBMLID.tags, EBMLID.attachments])
        }

        mutating func followSeekHead(_ io: IO, _ file: inout MKVFile, _ ids: [UInt32]) throws(MKVError) {
            for (id, position) in file.seekHead where ids.contains(id) {
                let (abs, o) = file.segmentDataStart.addingReportingOverflow(position)
                if o || parsed[abs] != nil || abs >= file.segmentEnd { continue }
                if let h = io.header(abs, file.segmentEnd), h.id == id {
                    _ = try level1(io, &file, h, file.segmentEnd)
                }
            }
        }

        /// Parse a level-1 metadata element; returns its end.
        mutating func level1(_ io: IO, _ file: inout MKVFile, _ h: Hdr, _ limit: UInt64) throws(MKVError) -> UInt64 {
            if let end = parsed[h.pos] { return end }
            let end: UInt64
            switch h.size {
            case .unknown: end = io.unknownEnd(h.dataStart, min(limit, h.dataStart.addingSaturating(metaLeft)))
            case .known: end = h.end(limit)
            }
            parsed[h.pos] = end
            let n = end - h.dataStart
            if n > metaLeft || (h.size == .unknown && n == metaLeft && end < limit) {
                metaLeft = 0
                return end
            }
            metaLeft -= n
            if h.id == EBMLID.attachments { return end }
            if n > maxMeta { return end }
            let data = try io.readVec(h.dataStart, n)
            switch h.id {
            case EBMLID.seekHead:
                for s in EBML.children(data) where s.id == EBMLID.seek {
                    var id: UInt32?
                    var p: UInt64?
                    for e in EBML.children(s.data) {
                        if e.id == EBMLID.seekID { id = UInt32(truncatingIfNeeded: EBML.uint(e.data)) }
                        if e.id == EBMLID.seekPosition { p = EBML.uint(e.data) }
                    }
                    if let id, let p { file.seekHead.append((id, p)) }
                }
            case EBMLID.info:
                file.timestampScale = 1_000_000
                file.duration = nil
                for e in EBML.children(data) {
                    if e.id == EBMLID.timestampScale {
                        let v = EBML.uint(e.data)
                        if v > 0 && v <= maxTimestampScale { file.timestampScale = v }
                    } else if e.id == EBMLID.duration {
                        let v = EBML.float(e.data)
                        file.duration = v.isFinite && v >= 0 ? v : nil
                    }
                }
            case EBMLID.tracks where file.tracks.isEmpty:
                if EBML.children(data).count(where: { $0.id == EBMLID.trackEntry }) > maxTracks { throw .tooLarge("track count") }
                file.tracks = parseTracks(data)
                lookup = nil
            default: break
            }
            return end
        }

        mutating func scanCluster(_ io: IO, _ h: Hdr, _ limit: UInt64, _ lookup: [UInt64: Int]) throws(MKVError) -> (UInt64, [BlockRef]) {
            let knownEnd: UInt64? = h.size == .unknown ? nil : h.end(limit)
            let lim = knownEnd ?? limit
            var ts: Int64 = 0
            var blocks: [BlockRef] = []
            var pos = h.dataStart
            var end: UInt64
            while true {
                if pos >= lim {
                    end = lim
                    break
                }
                guard let c = io.header(pos, lim) else {
                    end = io.resync(pos + 1, limit) ?? limit
                    break
                }
                if knownEnd == nil && EBMLID.isTopLevel(c.id) {
                    end = pos
                    break
                }
                if c.size == .unknown || c.overruns(lim) {
                    if c.overruns(lim) && (c.id == EBMLID.simpleBlock || c.id == EBMLID.blockGroup)
                        && io.len <= c.dataStart &+ (c.size.known ?? 0)
                    {
                        end = lim
                        break
                    }
                    end = io.resync(pos + 1, limit) ?? limit
                    break
                }
                let ce = c.end(lim)
                switch c.id {
                case EBMLID.timestamp:
                    ts = Int64(clamping: EBML.uint(io.peek(c.dataStart, Int(clamping: ce - c.dataStart))))
                case EBMLID.simpleBlock, EBMLID.blockGroup:
                    if let b = try parseBlockElem(io, c, ce, ts, lookup) {
                        try budget.take(b.frames)
                        blocks.append(b)
                    }
                default: break
                }
                pos = ce
            }
            return (end, blocks)
        }

        func parseBlock(_ io: IO, _ dataStart: UInt64, _ len: UInt64, _ lookup: [UInt64: Int]) throws(MKVError) -> (Int, Int16, UInt8, [(UInt64, UInt32)])? {
            let head = io.peek(dataStart, Int(min(16, len)))
            guard let (tn, tl, _) = EBML.readVint(head), head.count >= tl + 3 else { return nil }
            let s = head.startIndex
            let rel = Int16(bitPattern: UInt16(head[s + tl]) << 8 | UInt16(head[s + tl + 1]))
            let flags = head[s + tl + 2]
            guard let track = lookup[tn] else { return nil }
            let hdr = UInt64(tl + 3)
            let lacing = EBML.lacing(flags)
            if lacing == .none {
                return (track, rel, flags, [(dataStart + hdr, UInt32(truncatingIfNeeded: len - hdr))])
            }
            let body = try io.readVec(dataStart + hdr, len - hdr)
            guard let f = EBML.parseLacing(lacing, body) else { return nil }
            return (track, rel, flags, f.map { (dataStart + hdr + UInt64($0.0), UInt32(truncatingIfNeeded: $0.1)) })
        }

        func parseBlockElem(_ io: IO, _ h: Hdr, _ end: UInt64, _ clusterTs: Int64, _ lookup: [UInt64: Int]) throws(MKVError) -> BlockRef? {
            let ds = h.dataStart
            switch h.id {
            case EBMLID.simpleBlock:
                guard let (track, rel, flags, frames) = try parseBlock(io, ds, end - ds, lookup) else { return nil }
                return BlockRef(track: track, ts: clusterTs.addingSaturating(Int64(rel)), frames: frames, blockDuration: nil, keyframe: flags & 0x80 != 0)
            case EBMLID.blockGroup:
                var pos = ds
                var block: (Int, Int16, UInt8, [(UInt64, UInt32)])?
                var dur: UInt64?
                var hasRef = false
                while pos < end {
                    guard let c = io.header(pos, end) else { break }
                    let ce = c.end(end)
                    switch c.id {
                    case EBMLID.block: block = try parseBlock(io, c.dataStart, ce - c.dataStart, lookup)
                    case EBMLID.blockDuration: dur = EBML.uint(io.peek(c.dataStart, Int(clamping: ce - c.dataStart)))
                    case EBMLID.referenceBlock: hasRef = true
                    default: break
                    }
                    pos = ce
                }
                guard let (track, rel, _, frames) = block else { return nil }
                return BlockRef(track: track, ts: clusterTs.addingSaturating(Int64(rel)), frames: frames, blockDuration: dur, keyframe: !hasRef)
            default:
                return nil
            }
        }
    }

    private static func trackIndex(_ tracks: [MKVTrack]) -> [UInt64: Int] {
        var m: [UInt64: Int] = [:]
        for (i, t) in tracks.enumerated() where m[t.number] == nil { m[t.number] = i }
        return m
    }

    private static func satI64(_ v: Int128) -> Int64 {
        v > Int128(Int64.max) ? .max : v < Int128(Int64.min) ? .min : Int64(v)
    }

    /// Expand blocks into frames with per-lace timestamps and append them to their tracks.
    fileprivate static func addBlocks(_ file: inout MKVFile, _ blocks: [BlockRef]) {
        let scale = file.timestampScale
        let scaleI = Int128(scale)
        for b in blocks {
            guard file.tracks.indices.contains(b.track) else { continue }
            let t = file.tracks[b.track]
            let n = UInt128(b.frames.count)
            var blockNs: UInt128?
            if let d = b.blockDuration {
                blockNs = UInt128(d) * UInt128(scale)
            } else if let dd = t.defaultDurationNs {
                blockNs = UInt128(dd) * n
            }
            func toTicks(_ ns: Int128) -> Int64 {
                satI64(ns >= 0 ? (ns + scaleI / 2) / scaleI : (ns - scaleI / 2) / scaleI)
            }
            let delayTicks = toTicks(Int128(t.codecDelayNs))
            let baseNs = Int128(b.ts) * scaleI
            for (i, f) in b.frames.enumerated() {
                var start: Int128 = 0
                var endNs: Int128?
                if let total = blockNs {
                    start = Int128(truncatingIfNeeded: total * UInt128(i) / n)
                    endNs = Int128(truncatingIfNeeded: total * UInt128(i + 1) / n)
                }
                let pts = toTicks(baseNs + start).subtractingSaturating(delayTicks)
                let duration: UInt64 = endNs.map { UInt64(max(toTicks($0).subtractingSaturating(toTicks(start)), 0)) } ?? 0
                file.tracks[b.track].samples.append(MKVSample(offset: f.0, size: f.1, pts: pts, duration: duration, keyframe: b.keyframe))
            }
        }
    }

    // MARK: Tracks

    static func parseTracks(_ d: Slice) -> [MKVTrack] {
        var out: [MKVTrack] = []
        for te in EBML.children(d) where te.id == EBMLID.trackEntry {
            var t = MKVTrack()
            for e in EBML.children(te.data) {
                switch e.id {
                case EBMLID.trackNumber: t.number = EBML.uint(e.data)
                case EBMLID.trackType:
                    switch EBML.uint(e.data) {
                    case 1: t.kind = .video
                    case 2: t.kind = .audio
                    default: t.kind = .other
                    }
                case EBMLID.flagDefault: t.isDefault = EBML.uint(e.data) != 0
                case EBMLID.defaultDuration:
                    let v = EBML.uint(e.data)
                    t.defaultDurationNs = v > 0 ? v : nil
                case EBMLID.codecID: t.codecID = EBML.string(e.data)
                case EBMLID.codecPrivate: t.codecPrivate = Array(e.data)
                case EBMLID.codecDelay: t.codecDelayNs = EBML.uint(e.data)
                case EBMLID.video:
                    var w: UInt32 = 0, h: UInt32 = 0
                    for x in EBML.children(e.data) {
                        if x.id == EBMLID.pixelWidth { w = UInt32(truncatingIfNeeded: EBML.uint(x.data)) }
                        if x.id == EBMLID.pixelHeight { h = UInt32(truncatingIfNeeded: EBML.uint(x.data)) }
                    }
                    t.pixelWidth = w
                    t.pixelHeight = h
                case EBMLID.audio:
                    var a = MKVAudio()
                    for x in EBML.children(e.data) {
                        switch x.id {
                        case EBMLID.samplingFrequency: a.samplingFrequency = EBML.float(x.data)
                        case EBMLID.outputSamplingFrequency: a.outputSamplingFrequency = EBML.float(x.data)
                        case EBMLID.channels: a.channels = EBML.uint(x.data)
                        case EBMLID.bitDepth: a.bitDepth = EBML.uint(x.data)
                        default: break
                        }
                    }
                    t.audio = a
                case EBMLID.contentEncodings: t.encodings = parseEncodings(e.data)
                default: break
                }
            }
            if t.number == 0 { continue }
            if t.kind == .audio && t.audio == nil { t.audio = MKVAudio() }
            var prefix: [UInt8] = []
            for enc in t.encodings.reversed() {
                if case .headerStripping(let bytes, let scope) = enc, scope & 2 != 0 { prefix += bytes }
            }
            if !prefix.isEmpty { t.codecPrivate = prefix + t.codecPrivate }
            t.codec = mapCodec(t.codecID, t.codecPrivate, t.audio)
            out.append(t)
        }
        return out
    }

    private static func parseEncodings(_ d: Slice) -> [MKVEncoding] {
        var list: [(UInt64, MKVEncoding)] = []
        for ce in EBML.children(d) where ce.id == EBMLID.contentEncoding {
            var order: UInt64 = 0, scope: UInt64 = 1, ty: UInt64 = 0
            var comp: (UInt64, [UInt8])?
            for e in EBML.children(ce.data) {
                switch e.id {
                case EBMLID.contentEncodingOrder: order = EBML.uint(e.data)
                case EBMLID.contentEncodingScope: scope = EBML.uint(e.data)
                case EBMLID.contentEncodingType: ty = EBML.uint(e.data)
                case EBMLID.contentCompression:
                    var algo: UInt64 = 0
                    var settings: [UInt8] = []
                    for x in EBML.children(e.data) {
                        if x.id == EBMLID.contentCompAlgo { algo = EBML.uint(x.data) }
                        if x.id == EBMLID.contentCompSettings { settings = Array(x.data) }
                    }
                    comp = (algo, settings)
                default: break
                }
            }
            let enc: MKVEncoding
            if ty == 1 {
                enc = .encryption(scope: scope)
            } else {
                let (algo, settings) = comp ?? (0, [])
                enc = algo == 3 && settings.count <= maxStrippedHeader ? .headerStripping(bytes: settings, scope: scope) : .compression(scope: scope)
            }
            list.append((order, enc))
        }
        // Highest order first (stable).
        return list.enumerated().sorted { a, b in a.element.0 != b.element.0 ? a.element.0 > b.element.0 : a.offset < b.offset }.map(\.element.1)
    }

    private static let aacRates: [UInt32] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    private static func synthASC(_ objectType: UInt8, _ rate: Double, _ outRate: Double?, _ channels: UInt64, _ sbr: Bool) -> [UInt8] {
        func rateIndex(_ r: Double) -> UInt8 { UInt8(aacRates.firstIndex { Double($0) == r } ?? 4) }
        let ri = rateIndex(rate)
        let ch = UInt8(min(channels, 7))
        var v: [UInt8] = [objectType << 3 | ri >> 1, (ri & 1) << 7 | ch << 3]
        if sbr {
            let ext = rateIndex(outRate ?? rate * 2)
            v += [0x56, 0xE5, 0x80 | ext << 3]
        }
        return v
    }

    static func mapCodec(_ id: String, _ p: [UInt8], _ audio: MKVAudio?) -> MKVCodec {
        switch id {
        case "V_MPEG4/ISO/AVC": return .avc(avcc: p)
        case "V_MPEGH/ISO/HEVC": return .hevc(hvcc: p)
        case "V_VP8": return .vp8
        case "V_VP9": return .vp9(privateData: p)
        case "V_AV1": return .av1(av1c: p)
        case "V_APV": return .apv
        case "V_PRORES": return .proRes(fourcc: p.count >= 4 ? Array(p.prefix(4)) : nil)
        case "V_MJPEG": return .mjpeg
        case "V_MS/VFW/FOURCC":
            let f: [UInt8] = p.count >= 20 ? Array(p[16..<20]) : Array("    ".utf8)
            switch String(decoding: f, as: UTF8.self) {
            case "MJPG", "mjpg", "AVRn", "AVDJ": return .mjpeg
            case "H264", "h264", "avc1", "X264", "x264": return .avc(avcc: [])
            case "apch", "apcn", "apcs", "apco", "ap4h", "ap4x": return .proRes(fourcc: f)
            case "apv1", "APV1": return .apv
            default:
                return .vfw(rustASCIILowercaseTrim(String(decoding: f, as: UTF8.self)))
            }
        case "A_AAC": return .aac(asc: p)
        case "A_OPUS": return .opus(head: p)
        case "A_VORBIS": return .vorbis
        case "A_FLAC": return .flac(privateData: p)
        case "A_PCM/INT/LIT", "A_PCM/INT/BIG", "A_PCM/FLOAT/IEEE":
            let bits = UInt16(truncatingIfNeeded: audio?.bitDepth ?? (id == "A_PCM/FLOAT/IEEE" ? 32 : 16))
            return .pcm(float: id == "A_PCM/FLOAT/IEEE", bigEndian: id == "A_PCM/INT/BIG", bits: bits)
        case "A_AC3", "A_AC3/BSID9", "A_AC3/BSID10": return .ac3
        case "A_EAC3": return .eac3
        case "A_MPEG/L3": return .mp3
        case "A_MPEG/L2": return .mp2
        case "A_MPEG/L1": return .mp1
        case "S_TEXT/UTF8": return .subrip
        case "S_TEXT/WEBVTT", "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS", "D_WEBVTT/DESCRIPTIONS", "D_WEBVTT/METADATA": return .webvtt
        case "S_TEXT/ASS", "S_ASS": return .ass(ssa: false)
        case "S_TEXT/SSA", "S_SSA": return .ass(ssa: true)
        default:
            if id.hasPrefix("A_AAC/") {
                if !p.isEmpty { return .aac(asc: p) }
                let (rate, outRate, ch) = audio.map { ($0.samplingFrequency, $0.outputSamplingFrequency, $0.channels) } ?? (48000, nil, 2)
                let ot: UInt8 = id.hasSuffix("/MAIN") ? 1 : id.hasSuffix("/SSR") ? 3 : id.hasSuffix("/LTP") ? 4 : 2
                return .aac(asc: synthASC(ot, rate, outRate, ch, id.hasSuffix("/SBR")))
            }
            return .other(id)
        }
    }

    /// `String::from_utf8_lossy(fourcc).trim().to_ascii_lowercase()`.
    private static func rustASCIILowercaseTrim(_ s: String) -> String {
        rustASCIILowercase(String(rustTrim(s)))
    }
}

extension MKVFile {
    init(docType: String, segmentDataStart: UInt64, segmentEnd: UInt64) {
        self.init()
        self.docType = docType
        self.segmentDataStart = segmentDataStart
        self.segmentEnd = segmentEnd
    }
}
