// DCMedia — the ISO BMFF (MP4) and QuickTime (MOV) demuxer: box headers, `ftyp`, `moov` and `moof`,
// sample entries and per-track sample tables. Port of craft-media crates/media/src/isobmff/{demux,codec}.rs
// (craft-libs at the rev deckcraft's Cargo.toml pins, MIT OR Apache-2.0, © the craft-libs contributors),
// which deckcraft-isobmff re-exports.
//
// Ported: everything that decides what `open` returns or which error it fails with, and what deckcraft-media
// reads (timescales, durations, the first sample entry's codec and parameters, sample tables, the edit
// offset). Left out, because nothing in deckcraft-media reads it and it can't fail: `udta`/`meta`
// metadata, `tref`, `sdtp`, sample-group contents, the timecode start frame and the colour, HDR and
// aperture fields of visual sample entries (their boxes are still parsed where a parse can fail).

import DCCore

/// Hard cap on the samples of the whole file.
private let maxSamples = 1 << 26
private let fileBytesPerSample: UInt64 = 4
private let minSampleAllowance = 1 << 20
private let maxHeaderBox: UInt64 = 1 << 30
private let pcmMaxSampleBytes: UInt64 = 1 << 24

enum BMFFTrackKind: Equatable { case video, audio, timecode, subtitle, other }

struct BMFFSample: Equatable {
    var offset: UInt64
    var size: UInt32
    var dts: Int64
    var pts: Int64
    var duration: UInt32
    var isSync: Bool
}

struct PcmConfig: Equatable {
    var bits: UInt16 = 0
    var float = false
    var bigEndian = false
    var signed = false
    var channels: UInt32 = 0
    var sampleRate: Double = 0

    /// Bytes per interleaved frame; saturates for a hostile channel count.
    var bytesPerFrame: UInt32 {
        let (v, o) = ((UInt32(bits) + 7) / 8).multipliedReportingOverflow(by: max(channels, 1))
        return o ? UInt32.max : v
    }
}

/// Codec configuration from a sample entry (craft-media's `CodecConfig`), keeping the configuration
/// record bytes the decoders need.
enum BMFFCodec: Equatable {
    case avc(record: [UInt8])
    case hevc(record: [UInt8])
    case av1(record: [UInt8])
    case vp9(record: [UInt8])
    case proRes, jpeg, dnx, apv
    /// `asc` is the AudioSpecificConfig; `esds` the box payload (CoreAudio's magic cookie).
    case aac(asc: [UInt8], esds: [UInt8])
    case mp3
    case pcm(PcmConfig)
    case alac(cookie: [UInt8])
    case opus(dOps: [UInt8])
    case flac(dfLa: [UInt8])
    case ac3, eac3, timecode
    case unknown(FourCC)

    /// deckcraft-media's `codec_name`.
    var name: String {
        switch self {
        case .avc: "H.264"
        case .hevc: "HEVC"
        case .av1: "AV1"
        case .vp9: "VP9"
        case .apv: "APV"
        case .proRes: "Apple ProRes"
        case .jpeg: "Motion JPEG"
        case .dnx: "DNxHD"
        case .aac: "AAC"
        case .mp3: "MP3"
        case .pcm: "PCM"
        case .alac: "ALAC"
        case .opus: "Opus"
        case .flac: "FLAC"
        case .ac3: "AC-3"
        case .eac3: "E-AC-3"
        case .timecode: "timecode"
        case .unknown(let f): f.debug
        }
    }
}

struct BMFFAudioParams: Equatable {
    var qtVersion: UInt16 = 0
    var channels: UInt32 = 0
    var sampleSize: UInt16 = 0
    var sampleRate: Double = 0
    var samplesPerPacket: UInt32 = 0
    var bytesPerFrame: UInt32 = 0
    var constBitsPerChannel: UInt32 = 0
    var lpcmFlags: UInt32 = 0
    var littleEndian: Bool?
}

struct BMFFSampleEntry: Equatable {
    var format: FourCC
    var codec: BMFFCodec
    /// Visual sample entry width and height.
    var video: (width: UInt16, height: UInt16)?
    var audio: BMFFAudioParams?

    static func == (a: BMFFSampleEntry, b: BMFFSampleEntry) -> Bool {
        a.format == b.format && a.codec == b.codec && a.video?.width == b.video?.width && a.video?.height == b.video?.height && a.audio == b.audio
    }
}

struct BMFFTrack {
    var id: UInt32 = 0
    var kind: BMFFTrackKind = .other
    var handler = FourCC(0)
    var timescale: UInt32 = 0
    var duration: UInt64 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var entries: [BMFFSampleEntry] = []
    var samples: [BMFFSample] = []
    /// (segment duration, media time).
    var edits: [(UInt64, Int64)] = []
    /// Added to raw pts for presentation time (track timescale).
    var editOffset: Int64 = 0

    /// Presentation (edit-adjusted) pts of sample `i`.
    func presentationPts(_ i: Int) -> Int64? {
        samples.at(i).map { $0.pts.addingSaturating(editOffset) }
    }
}

struct BMFFFile {
    var isQuickTime = true
    var timescale: UInt32 = 0
    var duration: UInt64 = 0
    var tracks: [BMFFTrack] = []
    var fragmented = false

    func trackOfKind(_ k: BMFFTrackKind) -> Int? { tracks.firstIndex { $0.kind == k } }

    /// The bytes of sample `index` of track `track`.
    func readSample(_ src: [UInt8], _ track: Int, _ index: Int) throws(BMFFError) -> Slice {
        guard let t = tracks.at(track) else { throw .noSuchTrack(track) }
        guard let s = t.samples.at(index) else { throw .noSuchSample(index) }
        let (end, o) = s.offset.addingReportingOverflow(UInt64(s.size))
        if o { throw .truncated("sample") }
        guard end <= UInt64(src.count) else { throw .truncated("sample data") }
        return src[Int(s.offset)..<Int(end)]
    }
}

private struct SampleBudget {
    var samples: Int
    var impliedBytes: UInt64

    init(_ fileLen: UInt64) {
        let byLen = Int(clamping: fileLen / fileBytesPerSample)
        samples = min(max(byLen, minSampleAllowance), maxSamples)
        impliedBytes = fileLen
    }

    mutating func take(_ n: Int) throws(BMFFError) {
        guard n <= samples else { throw .tooLarge("sample count") }
        samples -= n
    }
}

private struct Trex { var descriptionIndex: UInt32 = 0, duration: UInt32 = 0, size: UInt32 = 0, flags: UInt32 = 0 }

extension Int64 {
    func addingSaturating(_ o: Int64) -> Int64 {
        let (v, ov) = addingReportingOverflow(o)
        return ov ? (o > 0 ? .max : .min) : v
    }
    func subtractingSaturating(_ o: Int64) -> Int64 {
        let (v, ov) = subtractingReportingOverflow(o)
        return ov ? (o < 0 ? .max : .min) : v
    }
}

extension UInt64 {
    func addingSaturating(_ o: UInt64) -> UInt64 {
        let (v, ov) = addingReportingOverflow(o)
        return ov ? .max : v
    }
    func multipliedSaturating(_ o: UInt64) -> UInt64 {
        let (v, ov) = multipliedReportingOverflow(by: o)
        return ov ? .max : v
    }
    func subtractingSaturating(_ o: UInt64) -> UInt64 { self >= o ? self - o : 0 }
}

private func clampI64(_ v: Int128) -> Int64 {
    v > Int128(Int64.max) ? .max : v < Int128(Int64.min) ? .min : Int64(v)
}

enum BMFF {
    /// Parse an MP4/MOV file: box headers, `ftyp`, `moov` and `moof`.
    static func open(_ src: [UInt8]) throws(BMFFError) -> BMFFFile {
        let len = UInt64(src.count)
        var offset: UInt64 = 0
        var ftyp: Slice?
        var moov: Slice?
        var moofs: [(UInt64, Slice)] = []
        while offset + 8 <= len {
            let o = Int(offset)
            let n = Int(min(len - offset, 32))
            let h = try BoxHeader.parse(src[o..<(o + n)])
            let size = h.size ?? (len - offset)
            let end = min(offset.addingSaturating(size), len)
            let bodyLen = end.subtractingSaturating(offset + h.headerLen)
            func readBody(_ max: UInt64) throws(BMFFError) -> Slice {
                if bodyLen > max { throw .tooLarge("header box") }
                let start = offset + h.headerLen
                guard start + bodyLen <= len else { throw .truncated("sample data") }
                return src[Int(start)..<Int(start + bodyLen)]
            }
            if h.kind == FourCC("ftyp"), ftyp == nil {
                ftyp = try readBody(1 << 16)
            } else if h.kind == FourCC("moov"), moov == nil {
                moov = try readBody(maxHeaderBox)
            } else if h.kind == FourCC("moof") {
                moofs.append((offset, try readBody(maxHeaderBox)))
            }
            if h.size == nil { break }
            offset = end
        }
        guard let moov else { throw .noMoov }
        var file = BMFFFile()
        if let f = ftyp {
            var c = BoxCursor(f, "ftyp")
            let major = try c.fourcc()
            file.isQuickTime = major == FourCC("qt  ")
        }
        var trex: [UInt32: Trex] = [:]
        var trakPayloads: [Slice] = []
        try forEachBox(moov) { (b) throws(BMFFError) in
            switch b.kind {
            case FourCC("cmov"):
                throw .unsupported("compressed movie header (cmov)")
            case FourCC("mvhd"):
                var c = BoxCursor(b.payload, "mvhd")
                let (v, _) = try c.fullHeader()
                if v == 1 {
                    try c.skip(16)
                    file.timescale = try c.u32()
                    file.duration = try c.u64()
                } else {
                    try c.skip(8)
                    file.timescale = try c.u32()
                    file.duration = UInt64(try c.u32())
                }
            case FourCC("trak"):
                trakPayloads.append(b.payload)
            case FourCC("mvex"):
                file.fragmented = true
                for m in goodBoxes(b.payload) where m.kind == FourCC("trex") {
                    var c = BoxCursor(m.payload, "trex")
                    _ = try c.fullHeader()
                    let id = try c.u32()
                    trex[id] = Trex(descriptionIndex: try c.u32(), duration: try c.u32(), size: try c.u32(), flags: try c.u32())
                }
            default: break
            }
        }
        var budget = SampleBudget(len)
        for p in trakPayloads {
            let t = try parseTrak(p, file, len, &budget)
            file.tracks.append(t)
        }
        var nextDts: [Int64] = file.tracks.map { t in t.samples.last.map { $0.dts.addingSaturating(Int64($0.duration)) } ?? 0 }
        var trackIndex: [UInt32: Int] = [:]
        for (i, t) in file.tracks.enumerated() where trackIndex[t.id] == nil { trackIndex[t.id] = i }
        for (off, moof) in moofs {
            try parseMoof(off, moof, &file.tracks, trackIndex, trex, &nextDts, &budget)
        }
        if file.fragmented && !moofs.isEmpty {
            for i in file.tracks.indices {
                let d = file.tracks[i].samples.reduce(UInt64(0)) { $0 &+ UInt64($1.duration) }
                file.tracks[i].duration = max(file.tracks[i].duration, d)
                let t = file.tracks[i]
                if t.timescale > 0 && file.timescale > 0 {
                    let md = UInt128(t.duration) * UInt128(file.timescale) / UInt128(t.timescale)
                    file.duration = max(file.duration, UInt64(truncatingIfNeeded: md))
                }
            }
        }
        return file
    }

    private static func rescale(_ v: Int128, _ from: UInt32, _ to: UInt32) -> Int64 {
        if from == 0 { return 0 }
        return clampI64(v * Int128(to) / Int128(from))
    }

    private static func parseTrak(_ p: Slice, _ file: BMFFFile, _ fileLen: UInt64, _ budget: inout SampleBudget) throws(BMFFError) -> BMFFTrack {
        var t = BMFFTrack()
        var mdia: Slice?
        try forEachBox(p) { (b) throws(BMFFError) in
            switch b.kind {
            case FourCC("tkhd"):
                var c = BoxCursor(b.payload, "tkhd")
                let (v, _) = try c.fullHeader()
                if v == 1 {
                    try c.skip(16)
                    t.id = try c.u32()
                    try c.skip(4)
                    _ = try c.u64()
                } else {
                    try c.skip(8)
                    t.id = try c.u32()
                    try c.skip(4)
                    _ = try c.u32()
                }
                try c.skip(8)
                _ = try c.i16()
                _ = try c.u16()
                _ = try c.i16()
                try c.skip(2)
                for _ in 0..<9 { _ = try c.i32() }
                t.width = try c.u32() >> 16
                t.height = try c.u32() >> 16
            case FourCC("edts"):
                if let e = findBox(b.payload, FourCC("elst")) {
                    var c = BoxCursor(e, "elst")
                    let (v, _) = try c.fullHeader()
                    let n = try c.count(v == 1 ? 20 : 12)
                    for _ in 0..<n {
                        let seg: UInt64, mt: Int64
                        if v == 1 {
                            seg = try c.u64()
                            mt = try c.i64()
                        } else {
                            seg = UInt64(try c.u32())
                            mt = Int64(try c.i32())
                        }
                        _ = try c.i32()
                        t.edits.append((seg, mt))
                    }
                }
            case FourCC("mdia"):
                mdia = b.payload
            default: break
            }
        }
        guard let mdia else { throw .invalid("trak without mdia") }
        var minf: Slice?
        try forEachBox(mdia) { (b) throws(BMFFError) in
            switch b.kind {
            case FourCC("mdhd"):
                var c = BoxCursor(b.payload, "mdhd")
                let (v, _) = try c.fullHeader()
                if v == 1 {
                    try c.skip(16)
                    t.timescale = try c.u32()
                    t.duration = try c.u64()
                } else {
                    try c.skip(8)
                    t.timescale = try c.u32()
                    t.duration = UInt64(try c.u32())
                }
                _ = try c.u16()
            case FourCC("hdlr"):
                var c = BoxCursor(b.payload, "hdlr")
                _ = try c.fullHeader()
                _ = try c.u32()
                t.handler = try c.fourcc()
                try c.skip(12)
            case FourCC("minf"):
                minf = b.payload
            default: break
            }
        }
        switch t.handler {
        case FourCC("vide"): t.kind = .video
        case FourCC("soun"): t.kind = .audio
        case FourCC("tmcd"): t.kind = .timecode
        case FourCC("text"), FourCC("sbtl"), FourCC("subt"), FourCC("clcp"): t.kind = .subtitle
        default: t.kind = .other
        }
        var empty: Int128 = 0
        for (seg, mt) in t.edits {
            if mt == -1 {
                empty += Int128(seg)
            } else {
                t.editOffset = rescale(empty, file.timescale, t.timescale).subtractingSaturating(mt)
                break
            }
        }
        if let m = minf, let stbl = findBox(m, FourCC("stbl")) {
            try parseStbl(stbl, &t, file.isQuickTime, fileLen, &budget)
        }
        return t
    }

    /// Run-length cursor over `stts`/`ctts` entries.
    private struct RunCursor {
        let runs: [(UInt32, UInt32)]
        var run = 0
        var used: UInt32 = 0

        /// Advance by `n` samples, returning the summed duration.
        mutating func take(_ count: UInt64) -> UInt64 {
            var n = count
            var total: UInt64 = 0
            while n > 0 && run < runs.count {
                let (c, delta) = runs[run]
                let avail = UInt64(c &- used)
                let k = min(avail, n)
                total = total.addingSaturating(k.multipliedSaturating(UInt64(delta)))
                n -= k
                used &+= UInt32(truncatingIfNeeded: k)
                if used >= c {
                    run += 1
                    used = 0
                }
            }
            return total
        }

        mutating func nextValue() -> UInt32 {
            while run < runs.count && runs[run].0 == 0 { run += 1 }
            guard run < runs.count else { return 0 }
            let d = runs[run].1
            _ = take(1)
            return d
        }
    }

    private static func parseStbl(_ stbl: Slice, _ t: inout BMFFTrack, _ isQT: Bool, _ fileLen: UInt64, _ budget: inout SampleBudget) throws(BMFFError) {
        var stts: [(UInt32, UInt32)] = []
        var ctts: [(UInt32, UInt32)] = []
        var stss: [UInt32]?
        var stsc: [(UInt32, UInt32, UInt32)] = []
        var constSize: UInt32 = 0
        var sampleCount = 0
        var sizes: [UInt32] = []
        var chunks: [UInt64] = []
        let handler = t.handler
        var entries = t.entries
        try forEachBox(stbl) { (b) throws(BMFFError) in
            var c = BoxCursor(b.payload, "stbl child")
            switch b.kind {
            case FourCC("stsd"):
                _ = try c.fullHeader()
                let n = try c.count(8)
                var k = 0
                for r in BoxIterator(c.rest) {
                    if k >= n { break }
                    k += 1
                    switch r {
                    case .success(let e): entries.append(try parseSampleEntry(e.kind, e.payload, handler, isQT))
                    case .failure(let err): throw err
                    }
                }
            case FourCC("stts"), FourCC("ctts"):
                _ = try c.fullHeader()
                let n = try c.count(8)
                var v: [(UInt32, UInt32)] = []
                v.reserveCapacity(n)
                for _ in 0..<n { v.append((try c.u32(), try c.u32())) }
                if b.kind == FourCC("stts") { stts = v } else { ctts = v }
            case FourCC("stss"):
                _ = try c.fullHeader()
                let n = try c.count(4)
                var v: [UInt32] = []
                v.reserveCapacity(n)
                for _ in 0..<n { v.append(try c.u32()) }
                v.sort()
                stss = v
            case FourCC("stsc"):
                _ = try c.fullHeader()
                let n = try c.count(12)
                var v: [(UInt32, UInt32, UInt32)] = []
                v.reserveCapacity(n)
                for _ in 0..<n { v.append((try c.u32(), try c.u32(), try c.u32())) }
                stsc = v
            case FourCC("stsz"):
                _ = try c.fullHeader()
                constSize = try c.u32()
                let n = Int(try c.u32())
                if constSize == 0 {
                    try c.checkCount(n, 4)
                    var v: [UInt32] = []
                    v.reserveCapacity(n)
                    for _ in 0..<n { v.append(try c.u32()) }
                    sizes = v
                    sampleCount = n
                } else {
                    sampleCount = Int(min(UInt64(n), fileLen / UInt64(constSize)))
                }
            case FourCC("stz2"):
                _ = try c.fullHeader()
                let field = try c.u32() & 0xFF
                let n = Int(try c.u32())
                guard field == 4 || field == 8 || field == 16 else { throw .invalid("stz2 field size \(field)") }
                let bits = Int(field)
                let (prod, o) = n.multipliedReportingOverflow(by: bits)
                if o || (prod + 7) / 8 > c.remaining { throw .truncated("stz2") }
                let d = c.rest
                let s = d.startIndex
                var v: [UInt32] = []
                v.reserveCapacity(n)
                for i in 0..<n {
                    switch bits {
                    case 4: v.append(UInt32((d[s + i / 2] >> (i % 2 == 0 ? 4 : 0)) & 0xF))
                    case 8: v.append(UInt32(d[s + i]))
                    default: v.append(UInt32(d[s + 2 * i]) << 8 | UInt32(d[s + 2 * i + 1]))
                    }
                }
                sizes = v
                sampleCount = n
            case FourCC("stco"):
                _ = try c.fullHeader()
                let n = try c.count(4)
                var v: [UInt64] = []
                v.reserveCapacity(n)
                for _ in 0..<n { v.append(UInt64(try c.u32())) }
                chunks = v
            case FourCC("co64"):
                _ = try c.fullHeader()
                let n = try c.count(8)
                var v: [UInt64] = []
                v.reserveCapacity(n)
                for _ in 0..<n { v.append(try c.u64()) }
                chunks = v
            case FourCC("sbgp"):
                let (v, _) = try c.fullHeader()
                _ = try c.fourcc()
                if v == 1 { _ = try c.u32() }
                let n = try c.count(8)
                for _ in 0..<n {
                    _ = try c.u32()
                    _ = try c.u32()
                }
            case FourCC("sgpd"):
                let (v, _) = try c.fullHeader()
                _ = try c.fourcc()
                let defaultLen = v >= 1 ? try c.u32() : 0
                if v >= 2 { _ = try c.u32() }
                let n = try c.count(0)
                for _ in 0..<n {
                    let l = v >= 1 && defaultLen == 0 ? try c.u32() : defaultLen
                    if l == 0 { break }
                    _ = try c.bytes(Int(l))
                }
            default: break
            }
        }
        t.entries = entries
        if sampleCount == 0 || chunks.isEmpty || stsc.isEmpty { return }
        if stsc[0].0 == 0 || zip(stsc, stsc.dropFirst()).contains(where: { $1.0 <= $0.0 }) {
            throw .invalid("stsc first_chunk values are not increasing from 1")
        }
        var pcm: PcmConfig?
        if case .pcm(let p)? = t.entries.first?.codec, constSize != 0 { pcm = p }
        var sttsC = RunCursor(runs: stts)
        var cttsC = RunCursor(runs: ctts)
        var samples: [BMFFSample] = []
        var sidx = 0
        var dts: Int64 = 0
        var stscI = 0
        if let p = pcm {
            let a = t.entries.first?.audio ?? BMFFAudioParams()
            let unit: UInt64, unitBytes: UInt64
            if a.qtVersion == 1 && a.bytesPerFrame > 0 && a.samplesPerPacket > 0 {
                (unit, unitBytes) = (UInt64(a.samplesPerPacket), UInt64(a.bytesPerFrame))
            } else if constSize > 1 {
                (unit, unitBytes) = (1, UInt64(constSize))
            } else {
                (unit, unitBytes) = (1, UInt64(p.bytesPerFrame))
            }
            let frameBytes = { (frames: UInt64) -> UInt64 in (frames / unit).multipliedSaturating(unitBytes) }
            let pieceFrames = max(pcmMaxSampleBytes / max(unitBytes, 1), 1) &* unit
            if chunks.count > budget.samples { throw .tooLarge("chunk count") }
            samples.reserveCapacity(chunks.count)
            for (ci, off) in chunks.enumerated() {
                while stscI + 1 < stsc.count && Int(stsc[stscI + 1].0) <= ci + 1 { stscI += 1 }
                let spc = min(Int(stsc[stscI].1), sampleCount - sidx)
                if spc == 0 { continue }
                var left = UInt64(spc)
                var pos = off
                while left > 0 {
                    if samples.count >= budget.samples { throw .tooLarge("sample count") }
                    let split = frameBytes(left) > pcmMaxSampleBytes
                    let frames = split ? pieceFrames : left
                    let dur = sttsC.take(frames)
                    let size = frameBytes(frames)
                    if split {
                        guard budget.impliedBytes >= size else { throw .tooLarge("PCM chunk size") }
                        budget.impliedBytes -= size
                    }
                    samples.append(BMFFSample(offset: pos, size: UInt32(min(size, UInt64(UInt32.max))), dts: dts, pts: dts,
                                              duration: UInt32(min(dur, UInt64(UInt32.max))), isSync: true))
                    dts = dts.addingSaturating(Int64(min(dur, UInt64(Int64.max))))
                    pos = pos.addingSaturating(size)
                    left = left >= frames ? left - frames : 0
                }
                sidx += spc
                if sidx >= sampleCount { break }
            }
        } else {
            if constSize != 0 {
                sampleCount = min(sampleCount, Int(clamping: budget.impliedBytes / UInt64(constSize)))
            }
            if sampleCount > budget.samples { throw .tooLarge("sample count") }
            var mapped = 0
            var mapI = 0
            for ci in 0..<chunks.count {
                while mapI + 1 < stsc.count && Int(stsc[mapI + 1].0) <= ci + 1 { mapI += 1 }
                mapped = mapped.addingReportingOverflow(Int(stsc[mapI].1)).overflow ? Int.max : mapped + Int(stsc[mapI].1)
                if mapped >= sampleCount { break }
            }
            samples.reserveCapacity(min(sampleCount, mapped))
            var stssI = 0
            chunkLoop: for (ci, off) in chunks.enumerated() {
                while stscI + 1 < stsc.count && Int(stsc[stscI + 1].0) <= ci + 1 { stscI += 1 }
                let spc = stsc[stscI].1
                var pos = off
                var k: UInt32 = 0
                while k < spc {
                    k += 1
                    if sidx >= sampleCount { break chunkLoop }
                    let size = constSize != 0 ? constSize : (sizes.at(sidx) ?? 0)
                    let duration = sttsC.nextValue()
                    let cts = Int64(Int32(bitPattern: cttsC.nextValue()))
                    var isSync = true
                    if let v = stss {
                        while stssI < v.count && Int(v[stssI]) < sidx + 1 { stssI += 1 }
                        isSync = stssI < v.count && Int(v[stssI]) == sidx + 1
                    }
                    samples.append(BMFFSample(offset: pos, size: size, dts: dts, pts: dts.addingSaturating(cts), duration: duration, isSync: isSync))
                    pos = pos.addingSaturating(UInt64(size))
                    dts = dts.addingSaturating(Int64(duration))
                    sidx += 1
                }
            }
        }
        if pcm == nil && constSize != 0 {
            budget.impliedBytes = budget.impliedBytes.subtractingSaturating(UInt64(samples.count) &* UInt64(constSize))
        }
        try budget.take(samples.count)
        t.samples = samples
    }

    private static func parseMoof(_ moofOff: UInt64, _ moof: Slice, _ tracks: inout [BMFFTrack], _ trackIndex: [UInt32: Int],
                                  _ trex: [UInt32: Trex], _ nextDts: inout [Int64], _ budget: inout SampleBudget) throws(BMFFError)
    {
        var prevEnd: UInt64?
        try forEachBox(moof) { (b) throws(BMFFError) in
            guard b.kind == FourCC("traf") else { return }
            var tfhd: Slice?
            var tfdt: Slice?
            var truns: [Slice] = []
            try forEachBox(b.payload) { (c) throws(BMFFError) in
                switch c.kind {
                case FourCC("tfhd"): tfhd = c.payload
                case FourCC("tfdt"): tfdt = c.payload
                case FourCC("trun"): truns.append(c.payload)
                default: break
                }
            }
            guard let tfhd else { throw .invalid("traf without tfhd") }
            var c = BoxCursor(tfhd, "tfhd")
            let (_, fl) = try c.fullHeader()
            let id = try c.u32()
            guard let ti = trackIndex[id] else { return }
            let d = trex[id] ?? Trex()
            let base: UInt64 = fl & 1 != 0 ? try c.u64() : (fl & 0x20000 != 0 ? moofOff : (prevEnd ?? moofOff))
            if fl & 2 != 0 { _ = try c.u32() }
            let defDur = fl & 8 != 0 ? try c.u32() : d.duration
            let defSize = fl & 0x10 != 0 ? try c.u32() : d.size
            let defFlags = fl & 0x20 != 0 ? try c.u32() : d.flags
            if let p = tfdt {
                var tc = BoxCursor(p, "tfdt")
                let (v, _) = try tc.fullHeader()
                let tt = v == 1 ? try tc.u64() : UInt64(try tc.u32())
                nextDts[ti] = Int64(min(tt, UInt64(Int64.max)))
            }
            var dataPos = base
            for tr in truns {
                var rc = BoxCursor(tr, "trun")
                let (v, tf) = try rc.fullHeader()
                let per = [UInt32(0x100), 0x200, 0x400, 0x800].filter { tf & $0 != 0 }.count * 4
                let n = Int(try rc.u32())
                if per > 0 {
                    try rc.checkCount(n, per)
                } else {
                    let implied = UInt64(n).multipliedSaturating(UInt64(max(defSize, 1)))
                    guard budget.impliedBytes >= implied else { throw .tooLarge("trun sample count") }
                    budget.impliedBytes -= implied
                }
                try budget.take(n)
                if tf & 1 != 0 {
                    let rel = Int64(try rc.i32())
                    dataPos = rel >= 0 ? base &+ UInt64(rel) : base &- UInt64(rel.magnitude)
                }
                let firstFlags: UInt32? = tf & 4 != 0 ? try rc.u32() : nil
                tracks[ti].samples.reserveCapacity(tracks[ti].samples.count + n)
                for i in 0..<n {
                    let dur = tf & 0x100 != 0 ? try rc.u32() : defDur
                    let size = tf & 0x200 != 0 ? try rc.u32() : defSize
                    var flags = tf & 0x400 != 0 ? try rc.u32() : defFlags
                    if i == 0, let f = firstFlags { flags = f }
                    var cto: Int64 = 0
                    if tf & 0x800 != 0 {
                        let raw = try rc.u32()
                        cto = v == 0 ? Int64(raw) : Int64(Int32(bitPattern: raw))
                    }
                    let dts = nextDts[ti]
                    tracks[ti].samples.append(BMFFSample(offset: dataPos, size: size, dts: dts, pts: dts.addingSaturating(cto),
                                                         duration: dur, isSync: flags & 0x1_0000 == 0))
                    dataPos = dataPos.addingSaturating(UInt64(size))
                    nextDts[ti] = dts.addingSaturating(Int64(dur))
                }
            }
            prevEnd = dataPos
        }
    }

    // MARK: Sample entries

    private static func isVideoFourCC(_ f: FourCC) -> Bool {
        ["avc1", "avc3", "hvc1", "hev1", "av01", "vp09", "vp08", "apch", "apcn", "apcs", "apco", "ap4h", "ap4x", "apv1", "jpeg", "mjpa",
         "mjpb", "AVdn", "AVdh", "mp4v", "encv", "raw ", "2vuy", "v210"].contains { FourCC(bytes: Slice(Array($0.utf8))) == f }
    }

    private static func isAudioFourCC(_ f: FourCC) -> Bool {
        ["mp4a", "lpcm", "sowt", "twos", "in24", "in32", "fl32", "fl64", "ipcm", "fpcm", "alac", "Opus", "fLaC", "ac-3", "ec-3", ".mp3",
         ".mp2", "enca", "ulaw", "alaw", "NONE"].contains { FourCC(bytes: Slice(Array($0.utf8))) == f }
    }

    /// One `stsd` entry (craft-media's `parse_sample_entry`).
    static func parseSampleEntry(_ format: FourCC, _ payload: Slice, _ handler: FourCC, _ isQT: Bool) throws(BMFFError) -> BMFFSampleEntry {
        var c = BoxCursor(payload, "sample entry")
        try c.skip(6)
        _ = try c.u16()
        let unknown = BMFFCodec.unknown(format)
        if format == FourCC("tmcd") || (handler == FourCC("tmcd") && !isVideoFourCC(format)) {
            try c.skip(4)
            _ = try c.u32()
            _ = try c.u32()
            _ = try c.u32()
            _ = try c.u8()
            try c.skip(1)
            return BMFFSampleEntry(format: format, codec: .timecode, video: nil, audio: nil)
        }
        let rawAudio = format == FourCC("raw ") && handler == FourCC("soun")
        let videoLike = (isVideoFourCC(format) && !rawAudio) || (handler == FourCC("vide") && !isAudioFourCC(format))
        let audioLike = isAudioFourCC(format) || (handler == FourCC("soun") && !videoLike)
        if videoLike {
            _ = try c.u16()
            _ = try c.u16()
            _ = try c.fourcc()
            _ = try c.u32()
            _ = try c.u32()
            let width = try c.u16()
            let height = try c.u16()
            _ = try c.u32()
            _ = try c.u32()
            try c.skip(4)
            _ = try c.u16()
            _ = try c.bytes(32)
            _ = try c.u16()
            _ = try c.i16()
            var codec: BMFFCodec?
            for b in goodBoxes(c.rest) {
                let p = b.payload
                switch b.kind {
                case FourCC("avcC") where format == FourCC("avc1") || format == FourCC("avc3"):
                    try validateAvcC(p)
                    codec = .avc(record: Array(p))
                case FourCC("hvcC") where format == FourCC("hvc1") || format == FourCC("hev1"):
                    try validateHvcC(p)
                    codec = .hevc(record: Array(p))
                case FourCC("av1C") where format == FourCC("av01"):
                    var r = BoxCursor(p, "av1C")
                    let m = try r.u8()
                    if m & 0x80 == 0 { throw .invalid("av1C marker bit not set") }
                    _ = try r.u8()
                    _ = try r.u8()
                    _ = try r.u8()
                    codec = .av1(record: Array(p))
                case FourCC("vpcC") where format == FourCC("vp09"):
                    try validateVpcC(p)
                    codec = .vp9(record: Array(p))
                case FourCC("apvC") where format == FourCC("apv1"):
                    try validateApvC(p)
                    codec = .apv
                case FourCC("pasp"):
                    var r = BoxCursor(p, "pasp")
                    _ = try r.u32()
                    _ = try r.u32()
                case FourCC("clap"):
                    var r = BoxCursor(p, "clap")
                    for _ in 0..<8 { _ = try r.u32() }
                case FourCC("fiel"):
                    var r = BoxCursor(p, "fiel")
                    _ = try r.u8()
                    _ = try r.u8()
                case FourCC("gama"):
                    var r = BoxCursor(p, "gama")
                    _ = try r.u32()
                case FourCC("btrt"):
                    var r = BoxCursor(p, "btrt")
                    for _ in 0..<3 { _ = try r.u32() }
                default: break
                }
            }
            let resolved: BMFFCodec
            if let codec {
                resolved = codec
            } else {
                switch format {
                case FourCC("apch"), FourCC("apcn"), FourCC("apcs"), FourCC("apco"), FourCC("ap4h"), FourCC("ap4x"): resolved = .proRes
                case FourCC("jpeg"), FourCC("mjpa"), FourCC("mjpb"): resolved = .jpeg
                case FourCC("AVdn"), FourCC("AVdh"): resolved = .dnx
                case FourCC("apv1"): resolved = .apv
                default: resolved = unknown
                }
            }
            return BMFFSampleEntry(format: format, codec: resolved, video: (width, height), audio: nil)
        }
        if audioLike {
            var a = BMFFAudioParams(qtVersion: try c.u16())
            _ = try c.u16()
            _ = try c.u32()
            a.channels = UInt32(try c.u16())
            a.sampleSize = try c.u16()
            _ = try c.i16()
            _ = try c.u16()
            a.sampleRate = Double(try c.u32()) / 65536.0
            if isQT && a.qtVersion == 1 {
                a.samplesPerPacket = try c.u32()
                _ = try c.u32()
                a.bytesPerFrame = try c.u32()
                _ = try c.u32()
            } else if isQT && a.qtVersion == 2 {
                _ = try c.u32()
                a.sampleRate = try c.f64()
                a.channels = try c.u32()
                if a.channels > UInt32(UInt16.max) { throw .invalid("QuickTime v2 sound entry with \(a.channels) channels") }
                _ = try c.u32()
                a.constBitsPerChannel = try c.u32()
                a.lpcmFlags = try c.u32()
                _ = try c.u32()
                _ = try c.u32()
            }
            var ext: [(FourCC, Slice)] = []
            for b in goodBoxes(c.rest) {
                if b.kind == FourCC("wave") {
                    for w in goodBoxes(b.payload) { ext.append((w.kind, w.payload)) }
                } else {
                    ext.append((b.kind, b.payload))
                }
            }
            func get(_ k: FourCC) -> Slice? { ext.first { $0.0 == k }?.1 }
            if let p = get(FourCC("enda")) {
                let v: UInt16 = p.count >= 2 ? UInt16(p[p.startIndex]) << 8 | UInt16(p[p.startIndex + 1]) : UInt16(p.first ?? 0)
                a.littleEndian = v != 0
            }
            let codec: BMFFCodec
            switch format {
            case FourCC("mp4a"):
                if let p = get(FourCC("esds")) { codec = try parseEsds(p) } else { codec = unknown }
            case FourCC(".mp3"), FourCC(".mp2"):
                codec = .mp3
            case FourCC("alac"):
                if let p = get(FourCC("alac")), p.count >= 4 { codec = .alac(cookie: Array(p.dropFirst(4))) } else { codec = unknown }
            case FourCC("Opus"):
                if let p = get(FourCC("dOps")) {
                    var r = BoxCursor(p, "dOps")
                    _ = try r.u8()
                    _ = try r.u8()
                    _ = try r.u16()
                    _ = try r.u32()
                    _ = try r.i16()
                    _ = try r.u8()
                    codec = .opus(dOps: Array(p))
                } else {
                    codec = unknown
                }
            case FourCC("fLaC"):
                if let p = get(FourCC("dfLa")) {
                    var r = BoxCursor(p, "dfLa")
                    _ = try r.fullHeader()
                    let blocks = r.rest
                    var br = BoxCursor(blocks, "dfLa")
                    let hdr = try br.u32()
                    if (hdr >> 24) & 0x7F == 0 { _ = try br.bytes(min(Int(hdr & 0xFF_FFFF), 34)) }
                    codec = .flac(dfLa: Array(p))
                } else {
                    codec = unknown
                }
            case FourCC("ac-3"): codec = .ac3
            case FourCC("ec-3"): codec = .eac3
            case FourCC("lpcm"), FourCC("sowt"), FourCC("twos"), FourCC("in24"), FourCC("in32"), FourCC("fl32"), FourCC("fl64"), FourCC("raw "),
                 FourCC("NONE"):
                codec = .pcm(try qtPcm(format, a))
            case FourCC("ipcm"), FourCC("fpcm"):
                var pcm = PcmConfig(bits: a.sampleSize, float: format == FourCC("fpcm"), bigEndian: true, signed: true, channels: a.channels,
                                    sampleRate: a.sampleRate)
                if let p = get(FourCC("pcmC")) {
                    var r = BoxCursor(p, "pcmC")
                    _ = try r.fullHeader()
                    let flags = try r.u8()
                    pcm.bigEndian = flags & 1 == 0
                    pcm.bits = UInt16(try r.u8())
                }
                codec = .pcm(pcm)
            default: codec = unknown
            }
            return BMFFSampleEntry(format: format, codec: codec, video: nil, audio: a)
        }
        return BMFFSampleEntry(format: format, codec: unknown, video: nil, audio: nil)
    }

    private static func qtPcm(_ f: FourCC, _ a: BMFFAudioParams) throws(BMFFError) -> PcmConfig {
        var p = PcmConfig(signed: true, channels: a.channels, sampleRate: a.sampleRate)
        switch f {
        case FourCC("lpcm"):
            guard a.constBitsPerChannel <= UInt32(UInt16.max) else { throw .invalid("lpcm with \(a.constBitsPerChannel) bits per channel") }
            p.bits = UInt16(a.constBitsPerChannel)
            p.float = a.lpcmFlags & 1 != 0
            p.bigEndian = a.lpcmFlags & 2 != 0
            p.signed = a.lpcmFlags & 4 != 0 || p.float
            if p.bits == 0 { p.bits = a.sampleSize }
        case FourCC("sowt"):
            p.bits = a.sampleSize == 0 ? 16 : a.sampleSize
        case FourCC("twos"):
            p.bits = a.sampleSize == 0 ? 16 : a.sampleSize
            p.bigEndian = true
        case FourCC("raw "), FourCC("NONE"):
            p.bits = a.sampleSize == 0 ? 8 : a.sampleSize
            p.signed = p.bits != 8
            p.bigEndian = true
        case FourCC("in24"), FourCC("in32"), FourCC("fl32"), FourCC("fl64"):
            p.bits = f == FourCC("in24") ? 24 : (f == FourCC("in32") || f == FourCC("fl32")) ? 32 : 64
            p.float = f.bytes.first == UInt8(ascii: "f")
            p.bigEndian = !(a.littleEndian ?? false)
        default: break
        }
        return p
    }

    private static func validateAvcC(_ data: Slice) throws(BMFFError) {
        var c = BoxCursor(data, "avcC")
        for _ in 0..<5 { _ = try c.u8() }
        let nsps = Int(try c.u8() & 0x1F)
        for _ in 0..<nsps { _ = try c.bytes(Int(try c.u16())) }
        let npps = Int(try c.u8())
        for _ in 0..<npps { _ = try c.bytes(Int(try c.u16())) }
    }

    private static func validateHvcC(_ data: Slice) throws(BMFFError) {
        var c = BoxCursor(data, "hvcC")
        _ = try c.u8()
        _ = try c.u8()
        _ = try c.u32()
        _ = try c.u16()
        _ = try c.u32()
        _ = try c.u8()
        _ = try c.u16()
        for _ in 0..<4 { _ = try c.u8() }
        _ = try c.u16()
        _ = try c.u8()
        let narrays = Int(try c.u8())
        for _ in 0..<narrays {
            _ = try c.u8()
            let n = Int(try c.u16())
            try c.checkCount(n, 2)
            for _ in 0..<n { _ = try c.bytes(Int(try c.u16())) }
        }
    }

    private static func validateVpcC(_ data: Slice) throws(BMFFError) {
        var c = BoxCursor(data, "vpcC")
        let (version, _) = try c.fullHeader()
        if version == 0 {
            for _ in 0..<4 { _ = try c.u8() }
            return
        }
        for _ in 0..<6 { _ = try c.u8() }
        _ = try c.bytes(Int(try c.u16()))
    }

    private static func validateApvC(_ data: Slice) throws(BMFFError) {
        func record(_ rec: Slice) throws(BMFFError) {
            var c = BoxCursor(rec, "apvC")
            let version = try c.u8()
            if version != 1 { throw .invalid("unsupported APVDecoderConfigurationRecord version \(version)") }
            let entries = try c.u8()
            if entries >= 1 && c.remaining >= 2 {
                _ = try c.u8()
                let numFi = try c.u8()
                if numFi >= 1 && c.remaining >= 14 {
                    let flags = try c.u8()
                    for _ in 0..<3 { _ = try c.u8() }
                    _ = try c.u32()
                    _ = try c.u32()
                    _ = try c.u8()
                    _ = try c.u8()
                    if flags & 0x02 != 0 && c.remaining >= 4 {
                        for _ in 0..<4 { _ = try c.u8() }
                    }
                }
            }
        }
        let s = data.startIndex
        if data.count >= 5 && data[s] == 0 && data[s + 1] == 0 && data[s + 2] == 0 && data[s + 3] == 0 && data[s + 4] == 1 {
            try record(data.dropFirst(4))
        } else if data.first == 1 {
            try record(data)
        } else {
            var c = BoxCursor(data, "apvC")
            let (v, _) = try c.fullHeader()
            if v != 0 { throw .invalid("unsupported apvC FullBox version \(v)") }
            try record(c.rest)
        }
    }

    private static func descriptor(_ c: inout BoxCursor) throws(BMFFError) -> (UInt8, Int) {
        let tag = try c.u8()
        var len = 0
        for _ in 0..<4 {
            let b = try c.u8()
            len = len << 7 | Int(b & 0x7F)
            if b & 0x80 == 0 { break }
        }
        return (tag, len)
    }

    private static func parseEsds(_ p: Slice) throws(BMFFError) -> BMFFCodec {
        var c = BoxCursor(p, "esds")
        _ = try c.fullHeader()
        let (tag, len) = try descriptor(&c)
        if tag != 3 { throw .invalid("esds: expected ES_Descriptor, got tag \(tag)") }
        let es = try c.bytes(min(len, c.remaining))
        var e = BoxCursor(es, "ES_Descriptor")
        _ = try e.u16()
        let fl = try e.u8()
        if fl & 0x80 != 0 { _ = try e.u16() }
        if fl & 0x40 != 0 { try e.skip(Int(try e.u8())) }
        if fl & 0x20 != 0 { _ = try e.u16() }
        while e.remaining > 0 {
            let (t, l) = try descriptor(&e)
            let body = try e.bytes(min(l, e.remaining))
            if t != 4 { continue }
            var d = BoxCursor(body, "DecoderConfigDescriptor")
            let oti = try d.u8()
            _ = try d.u8()
            _ = try d.u24()
            _ = try d.u32()
            _ = try d.u32()
            var asc: [UInt8] = []
            while d.remaining > 0 {
                let (t2, l2) = try descriptor(&d)
                let b = try d.bytes(min(l2, d.remaining))
                if t2 == 5 {
                    asc = Array(b)
                    break
                }
            }
            return oti == 0x69 || oti == 0x6B ? .mp3 : .aac(asc: asc, esds: Array(p.dropFirst(4)))
        }
        throw .invalid("esds without DecoderConfigDescriptor")
    }
}
