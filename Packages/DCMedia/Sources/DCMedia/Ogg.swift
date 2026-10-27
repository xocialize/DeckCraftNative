// DCMedia — the Ogg demuxer (RFC 3533; pages, CRC, packet assembly across pages, codec headers) and
// Ogg Opus timing (RFC 7845 §4). Port of deckcraft crates/ogg/src/lib.rs and the `OpusHead` parser of
// crates/opus/src/header.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore

enum OggCodec: Equatable {
    case opus, vorbis, flac, theora, speex, unknown

    static func of(_ first: [UInt8]) -> OggCodec {
        func starts(_ m: [UInt8]) -> Bool { first.count >= m.count && Array(first.prefix(m.count)) == m }
        if starts(Array("OpusHead".utf8)) { return .opus }
        if starts([0x01] + Array("vorbis".utf8)) { return .vorbis }
        if starts([0x7F] + Array("FLAC".utf8)) { return .flac }
        if starts([0x80] + Array("theora".utf8)) { return .theora }
        if starts(Array("Speex   ".utf8)) { return .speex }
        return .unknown
    }

    var headerCount: Int {
        switch self {
        case .opus, .speex: 2
        case .vorbis, .theora: 3
        case .flac, .unknown: 1
        }
    }
}

struct OggPacket {
    var parts: [(UInt64, UInt32)]
    var size: UInt32
    var granule: Int64?
    var eos: Bool
    var prefix: (UInt8, UInt8)
}

struct OggStream {
    var serial: UInt32
    var codec: OggCodec = .unknown
    var headers: [[UInt8]] = []
    var packets: [OggPacket] = []
    var lastGranule: Int64?
}

struct OggFile {
    var streams: [OggStream]

    func streamOf(_ c: OggCodec) -> Int? { streams.firstIndex { $0.codec == c } }

    func readPacket(_ src: [UInt8], _ s: Int, _ i: Int) -> [UInt8]? {
        guard let p = streams.at(s)?.packets.at(i) else { return nil }
        return Ogg.readParts(src, p.parts)
    }
}

enum Ogg {
    /// RFC 3533 §6 CRC-32: polynomial 0x04C11DB7, initial 0, no reflection, no final XOR.
    private static let table: [UInt32] = (0..<256).map { i in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    static func crc32(_ data: Slice) -> UInt32 {
        data.reduce(UInt32(0)) { c, b in (c << 8) ^ table[Int(UInt8(truncatingIfNeeded: c >> 24) ^ b)] }
    }

    static func readParts(_ src: [UInt8], _ parts: [(UInt64, UInt32)]) -> [UInt8]? {
        var v: [UInt8] = []
        for (o, n) in parts {
            let (e, ov) = o.addingReportingOverflow(UInt64(n))
            guard !ov, e <= UInt64(src.count) else { return nil }
            v += src[Int(o)..<Int(e)]
        }
        return v
    }

    private struct Partial {
        var parts: [(UInt64, UInt32)] = []
        var size: UInt32 = 0
        var prefix: [UInt8] = []
    }

    /// Read every page and assemble the packets of every logical bitstream; nil when no page is found.
    static func open(_ src: [UInt8]) -> OggFile? {
        let len = UInt64(src.count)
        var streams: [OggStream] = []
        var bySerial: [UInt32: Int] = [:]
        var partial: [UInt32: Partial] = [:]
        var pos: UInt64 = 0
        var foundAny = false
        var scanBudget = 32 * 1024 * 1024
        var scanned: (start: UInt64, end: UInt64) = (0, 0)
        func capture(_ p: UInt64) -> Bool {
            let i = Int(p)
            return src[i] == 0x4F && src[i + 1] == 0x67 && src[i + 2] == 0x67 && src[i + 3] == 0x53
        }
        /// craft's `CaptureScanner::find`: the next `OggS` at or after `from`, reading in 64 KiB windows
        /// against a 32 MiB budget.
        func find(_ from: UInt64) -> UInt64? {
            var at = from
            while at + 4 <= len {
                if at >= scanned.start && at + 4 <= scanned.end {
                    var p = at
                    while p + 4 <= scanned.end {
                        if capture(p) { return p }
                        p += 1
                    }
                    at = scanned.end >= 3 ? scanned.end - 3 : 0
                    continue
                }
                if scanBudget == 0 { return nil }
                let n = min(min(Int(len - at), 64 * 1024), scanBudget)
                if n < 4 { break }
                scanned = (at, at + UInt64(n))
                scanBudget = max(0, scanBudget - n)
                var p = at
                while p + 4 <= scanned.end {
                    if capture(p) { return p }
                    p += 1
                }
                at += UInt64(n - 3)
            }
            return nil
        }
        while pos + 27 <= len {
            let p0 = Int(pos)
            if !(capture(pos) && src[p0 + 4] == 0) {
                guard let p = find(pos + 1) else { break }
                pos = p
                continue
            }
            let nseg = Int(src[p0 + 26])
            if pos + 27 + UInt64(nseg) > len { break }
            let lacing = Array(src[(p0 + 27)..<(p0 + 27 + nseg)])
            let bodyLen = lacing.reduce(UInt64(0)) { $0 + UInt64($1) }
            let pageLen = 27 + UInt64(nseg) + bodyLen
            if pos + pageLen > len { break }
            var page = Array(src[p0..<(p0 + Int(pageLen))])
            let stored = UInt32(page[22]) | UInt32(page[23]) << 8 | UInt32(page[24]) << 16 | UInt32(page[25]) << 24
            for i in 22..<26 { page[i] = 0 }
            if crc32(page[...]) != stored {
                pos += 1
                continue
            }
            foundAny = true
            let flags = page[5]
            var g: UInt64 = 0
            for i in (6..<14).reversed() { g = g << 8 | UInt64(page[i]) }
            let granule = Int64(bitPattern: g)
            let serial = UInt32(page[14]) | UInt32(page[15]) << 8 | UInt32(page[16]) << 16 | UInt32(page[17]) << 24
            let bodyOff = pos + 27 + UInt64(nseg)
            let si: Int
            if let i = bySerial[serial] {
                si = i
            } else {
                streams.append(OggStream(serial: serial))
                si = streams.count - 1
                bySerial[serial] = si
            }
            let continued = flags & 0x01 != 0
            if !continued { partial[serial] = nil }
            var completed: [OggPacket] = []
            var off: UInt64 = 0
            var segStart: UInt64 = 0
            var skipFragment = continued && partial[serial] == nil
            for (k, l) in lacing.enumerated() {
                off += UInt64(l)
                if l < 255 || k + 1 == nseg {
                    let (a, n) = (segStart, off - segStart)
                    segStart = off
                    if skipFragment {
                        if l < 255 { skipFragment = false }
                        continue
                    }
                    var p = partial[serial] ?? Partial()
                    if n > 0 {
                        p.parts.append((bodyOff + a, UInt32(n)))
                        p.size &+= UInt32(n)
                        let s = Int(bodyOff - pos + a)
                        let need = min(max(0, 2 - p.prefix.count), Int(n))
                        p.prefix += page[s..<(s + need)]
                    }
                    if l < 255 {
                        partial[serial] = nil
                        let pre = (p.prefix.at(0) ?? 0, p.prefix.at(1) ?? 0)
                        completed.append(OggPacket(parts: p.parts, size: p.size, granule: nil, eos: flags & 0x04 != 0, prefix: pre))
                    } else {
                        partial[serial] = p
                    }
                }
            }
            if granule != -1 {
                streams[si].lastGranule = granule
                if !completed.isEmpty { completed[completed.count - 1].granule = granule }
            }
            for pk in completed {
                if streams[si].headers.isEmpty && streams[si].packets.isEmpty {
                    streams[si].codec = OggCodec.of(readParts(src, pk.parts) ?? [])
                }
                if streams[si].headers.count < streams[si].codec.headerCount && streams[si].packets.isEmpty {
                    streams[si].headers.append(readParts(src, pk.parts) ?? [])
                } else {
                    streams[si].packets.append(pk)
                }
            }
            pos += pageLen
        }
        return foundAny ? OggFile(streams: streams) : nil
    }

    /// Samples (48 kHz) of an Opus packet from its TOC (RFC 6716 §3.1); nil if invalid.
    static func opusPacketSamples(_ prefix: (UInt8, UInt8), _ size: UInt32) -> UInt32? {
        if size == 0 { return nil }
        let toc = prefix.0
        let config = toc >> 3
        let frame: UInt32
        switch config {
        case 0...11: frame = [480, 960, 1920, 2880][Int(config & 3)]
        case 12...15: frame = [480, 960][Int(config & 1)]
        default: frame = [120, 240, 480, 960][Int(config & 3)]
        }
        let frames: UInt32
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            if size < 2 { return nil }
            frames = UInt32(prefix.1 & 0x3F)
        }
        let n = frame * frames
        return n > 0 && n <= 5760 ? n : nil
    }

    /// RFC 7845 §4 timing: playable samples after the pre-skip and end trimming (`OpusTiming::of`'s
    /// `total`). nil where deckcraft's timing reports an overflow.
    static func opusTotal(_ stream: OggStream, preSkip: UInt32) -> Int64? {
        let durations = stream.packets.map { opusPacketSamples($0.prefix, $0.size) ?? 0 }
        let n = durations.count
        var ends = [Int64?](repeating: nil, count: n)
        var i = 0
        var cursor: Int64?
        var trimmedEnd: Int64?
        func add(_ a: Int64, _ b: Int64) -> Int64? {
            let (v, o) = a.addingReportingOverflow(b)
            return o ? nil : v
        }
        func sub(_ a: Int64, _ b: Int64) -> Int64? {
            let (v, o) = a.subtractingReportingOverflow(b)
            return o ? nil : v
        }
        while i < n {
            var j = i
            while j < n && stream.packets[j].granule == nil { j += 1 }
            if j == n {
                var c = cursor ?? 0
                for k in i..<n {
                    guard let v = add(c, Int64(durations[k])) else { return nil }
                    c = v
                    ends[k] = c
                }
                break
            }
            guard let g = stream.packets[j].granule else { break }
            var sum: Int64 = 0
            for k in i...j {
                guard let v = add(sum, Int64(durations[k])) else { return nil }
                sum = v
            }
            var forward: Int64?
            if let c = cursor {
                guard let v = add(c, sum) else { return nil }
                forward = v
            }
            let end: Int64
            if let f = forward, stream.packets[j].eos && g < f {
                trimmedEnd = g
                end = f
            } else if let f = forward, f == g {
                end = f
            } else {
                end = g
            }
            var e = end
            for k in stride(from: j, through: i, by: -1) {
                ends[k] = e
                guard let v = sub(e, Int64(durations[k])) else { return nil }
                e = v
            }
            cursor = end
            i = j + 1
        }
        var rawStarts: [Int64] = []
        rawStarts.reserveCapacity(n)
        for (e, d) in zip(ends, durations) {
            guard let v = sub(e ?? 0, Int64(d)) else { return nil }
            rawStarts.append(v)
        }
        let base = max(rawStarts.first ?? 0, 0)
        guard let shift = add(base, Int64(preSkip)) else { return nil }
        for s in rawStarts { guard sub(s, shift) != nil else { return nil } }
        let endAll = trimmedEnd ?? cursor ?? 0
        guard let total = sub(endAll, shift) else { return nil }
        return max(total, 0)
    }
}

/// The fields of an `OpusHead` (RFC 7845 §5.1) deckcraft-media reads, after deckcraft-opus's checks.
struct OpusHead {
    var channels: Int
    var preSkip: UInt16

    init?(_ d: [UInt8]) {
        guard d.count >= 19, Array(d[0..<8]) == Array("OpusHead".utf8) else { return nil }
        if d[8] >> 4 != 0 { return nil }
        let channels = Int(d[9])
        let family = d[18]
        let rest = d[19...]
        if channels == 0 { return nil }
        if family == 0 {
            if channels > 2 { return nil }
        } else {
            if family == 3 { return nil }
            if rest.count < 2 + channels { return nil }
            let s = rest.startIndex
            let streams = Int(rest[s]), coupled = Int(rest[s + 1])
            if streams == 0 || coupled > streams || streams + coupled > 255 { return nil }
            if family == 1 && !(1...8).contains(channels) { return nil }
            if rest[(s + 2)..<(s + 2 + channels)].contains(where: { $0 != 255 && Int($0) >= streams + coupled }) { return nil }
        }
        self.channels = channels
        preSkip = UInt16(d[10]) | UInt16(d[11]) << 8
    }
}
