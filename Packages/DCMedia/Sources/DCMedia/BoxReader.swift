// DCMedia — box-level access to ISO BMFF data: the box header parser, the iterator over the boxes in a
// byte range and the bounds-checked big-endian reader for box payloads. Port of craft-media
// crates/media/src/isobmff/{boxes,bytes,error}.rs (craft-libs at the rev deckcraft's Cargo.toml pins,
// MIT OR Apache-2.0, © the craft-libs contributors), which deckcraft-isobmff re-exports.
//
// Every read checks the remaining length. Payloads are `ArraySlice`s of the one file buffer, so nothing
// is copied; their indices are the file's.

import DCCore

typealias Slice = ArraySlice<UInt8>

/// craft-media's `isobmff::Error`; `message` is its `Display`.
enum BMFFError: Error, Equatable {
    case truncated(String)
    case invalid(String)
    case unsupported(String)
    case tooLarge(String)
    case noMoov
    case noSuchTrack(Int)
    case noSuchSample(Int)

    var message: String {
        switch self {
        case .truncated(let s): "truncated data while reading \(s)"
        case .invalid(let s): "invalid data: \(s)"
        case .unsupported(let s): "unsupported: \(s)"
        case .tooLarge(let s): "size limit exceeded: \(s)"
        case .noMoov: "no moov box found"
        case .noSuchTrack(let i): "track index \(i) out of range"
        case .noSuchSample(let i): "sample index \(i) out of range"
        }
    }
}

/// A four-character code.
struct FourCC: Equatable, Hashable, Sendable {
    var value: UInt32

    init(_ value: UInt32) { self.value = value }
    init(_ s: StaticString) {
        var v: UInt32 = 0
        s.withUTF8Buffer { for b in $0.prefix(4) { v = v << 8 | UInt32(b) } }
        value = v
    }
    init(bytes: Slice) {
        var v: UInt32 = 0
        for b in bytes.prefix(4) { v = v << 8 | UInt32(b) }
        value = v
    }

    var bytes: [UInt8] { [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }

    /// `to_string_lossy`: 0xA9 is `©`, printable ASCII stays, anything else is `?`.
    var lossy: String {
        String(bytes.map { b -> Character in
            switch b {
            case 0xA9: "©"
            case 0x20...0x7E: Character(Unicode.Scalar(b))
            default: "?"
            }
        })
    }

    /// Rust's `{:?}` of a `FourCc`: `FourCc("mp4v")`, the string escaped as Rust's `str` Debug escapes it.
    var debug: String {
        var s = "FourCc(\""
        for ch in lossy {
            if ch == "\"" { s += "\\\"" } else if ch == "\\" { s += "\\\\" } else { s.append(ch) }
        }
        return s + "\")"
    }
}

/// Bounds-checked big-endian cursor (craft-media's `boxes::Reader`). A failed read leaves the position.
struct BoxCursor {
    let data: Slice
    private(set) var pos: Int
    let what: String

    init(_ data: Slice, _ what: String = "box payload") {
        self.data = data
        pos = data.startIndex
        self.what = what
    }

    var remaining: Int { max(0, data.endIndex - pos) }
    /// The unread bytes.
    var rest: Slice { pos < data.endIndex ? data[pos..<data.endIndex] : data[data.endIndex..<data.endIndex] }

    mutating func bytes(_ n: Int) throws(BMFFError) -> Slice {
        guard n >= 0, n <= remaining else { throw .truncated(what) }
        let s = data[pos..<(pos + n)]
        pos += n
        return s
    }
    mutating func skip(_ n: Int) throws(BMFFError) { _ = try bytes(n) }
    mutating func u8() throws(BMFFError) -> UInt8 { try bytes(1).first ?? 0 }
    mutating func uint(_ n: Int) throws(BMFFError) -> UInt64 {
        var v: UInt64 = 0
        for b in try bytes(n) { v = v << 8 | UInt64(b) }
        return v
    }
    mutating func u16() throws(BMFFError) -> UInt16 { UInt16(truncatingIfNeeded: try uint(2)) }
    mutating func i16() throws(BMFFError) -> Int16 { Int16(bitPattern: try u16()) }
    mutating func u24() throws(BMFFError) -> UInt32 { UInt32(truncatingIfNeeded: try uint(3)) }
    mutating func u32() throws(BMFFError) -> UInt32 { UInt32(truncatingIfNeeded: try uint(4)) }
    mutating func i32() throws(BMFFError) -> Int32 { Int32(bitPattern: try u32()) }
    mutating func u64() throws(BMFFError) -> UInt64 { try uint(8) }
    mutating func i64() throws(BMFFError) -> Int64 { Int64(bitPattern: try u64()) }
    mutating func f64() throws(BMFFError) -> Double { Double(bitPattern: try u64()) }
    mutating func fourcc() throws(BMFFError) -> FourCC { FourCC(try u32()) }
    /// Full-box header: (version, flags).
    mutating func fullHeader() throws(BMFFError) -> (UInt8, UInt32) {
        let v = try u32()
        return (UInt8(v >> 24), v & 0x00FF_FFFF)
    }
    /// A 32-bit entry count, checked against the bytes left for `entrySize`-byte entries.
    mutating func count(_ entrySize: Int) throws(BMFFError) -> Int {
        let n = Int(try u32())
        try checkCount(n, entrySize)
        return n
    }
    func checkCount(_ n: Int, _ entrySize: Int) throws(BMFFError) {
        let (b, o) = n.multipliedReportingOverflow(by: entrySize)
        guard !o, b <= remaining else { throw .truncated(what) }
    }
}

/// One box header.
struct BoxHeader {
    var kind: FourCC
    var headerLen: UInt64
    /// nil for a size field of 0 (the box runs to the end).
    var size: UInt64?

    static func parse(_ buf: Slice) throws(BMFFError) -> BoxHeader {
        var c = BoxCursor(buf, "box header")
        let size32 = try c.u32()
        let kind = try c.fourcc()
        var headerLen: UInt64 = 8
        var size: UInt64?
        switch size32 {
        case 0: size = nil
        case 1:
            headerLen += 8
            size = try c.u64()
        default: size = UInt64(size32)
        }
        if kind == FourCC("uuid") {
            headerLen += 16
            try c.skip(16)
        }
        if let s = size, s < headerLen {
            throw .invalid("box '\(kind.lossy)' size \(s) smaller than its header")
        }
        return BoxHeader(kind: kind, headerLen: headerLen, size: size)
    }
}

/// One box found by `BoxIterator`.
struct BoxRef {
    var kind: FourCC
    /// Index of the first header byte in the file buffer.
    var offset: Int
    var headerLen: Int
    var payload: Slice
}

/// Sibling boxes in a byte range. A malformed header or a box larger than the range yields one error
/// and ends the iteration. Fewer than 8 trailing zero bytes (QuickTime's terminator) end it silently.
struct BoxIterator: IteratorProtocol, Sequence {
    let data: Slice
    var pos: Int
    var done = false

    init(_ data: Slice) {
        self.data = data
        pos = data.startIndex
    }

    mutating func next() -> Result<BoxRef, BMFFError>? {
        if done { return nil }
        let item = step()
        if case .success = item {} else { done = true }
        return item
    }

    private mutating func step() -> Result<BoxRef, BMFFError>? {
        guard pos < data.endIndex else { return nil }
        let rest = data[pos..<data.endIndex]
        if rest.count < 8 {
            if rest.allSatisfy({ $0 == 0 }) { return nil }
            return .failure(.truncated("box header"))
        }
        let h: BoxHeader
        do { h = try BoxHeader.parse(rest) } catch { return .failure(error) }
        let avail = UInt64(rest.count)
        let size: UInt64
        if let s = h.size {
            guard s <= avail else {
                return .failure(.invalid("box '\(h.kind.lossy)' size \(s) exceeds its container (\(avail) bytes left)"))
            }
            size = s
        } else {
            size = avail
        }
        let hl = Int(h.headerLen), sz = Int(size)
        guard hl <= sz else { return nil }
        let b = BoxRef(kind: h.kind, offset: pos, headerLen: hl, payload: data[(pos + hl)..<(pos + sz)])
        pos += sz
        return .success(b)
    }
}

/// `for b in boxes(data) { let b = b?; body(b) }`: every good box, then the iterator's error.
func forEachBox(_ data: Slice, _ body: (BoxRef) throws(BMFFError) -> Void) throws(BMFFError) {
    for r in BoxIterator(data) {
        switch r {
        case .success(let b): try body(b)
        case .failure(let e): throw e
        }
    }
}

/// `boxes(data).map_while(|b| b.ok())`: the boxes before the first malformed one.
func goodBoxes(_ data: Slice) -> [BoxRef] {
    var out: [BoxRef] = []
    for r in BoxIterator(data) {
        guard case .success(let b) = r else { break }
        out.append(b)
    }
    return out
}

/// The payload of the first box of type `kind`; boxes after a malformed one are not searched.
func findBox(_ data: Slice, _ kind: FourCC) -> Slice? {
    goodBoxes(data).first { $0.kind == kind }?.payload
}
