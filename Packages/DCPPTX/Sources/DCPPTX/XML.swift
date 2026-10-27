// DCPPTX — a small, bounded XML DOM for reading parts, plus an escaping string builder for writing
// them. Port of deckcraft crates/pptx/src/xml.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// Reading is lenient about namespaces: elements and attributes are matched by local name, which is how
// real-world files are best understood (prefixes are conventional and stable in practice).
//
// The parser is byte-level and reproduces quick-xml 0.41.0 (MIT, © Johann Tuffe and the quick-xml
// contributors) exactly as xml.rs configures it (no `encoding` feature, `trim_text(false)`,
// `check_end_names = false`, `allow_unmatched_ends = true`, `expand_empty_elements = false`, the rest at
// their defaults): where markup ends, which errors stop a parse (an unclosed tag, comment, CDATA, PI or
// DOCTYPE; a `&` without its `;`; `<!DOCTYPE>` without a name), how attributes are split (`with_checks
// (false)`, malformed ones skipped), and how entity and character references resolve and attribute
// values are normalised (XML 1.0 §3.3.3). Foundation's `XMLParser` is stricter than quick-xml and would
// refuse parts deckcraft reads, so it isn't used.
import DCCore

// MARK: - DOM

/// `xml::Node`: an element or a run of text.
public enum XMLNode: Sendable, Equatable {
    case el(XMLEl)
    case text(String)

    public static func == (a: XMLNode, b: XMLNode) -> Bool {
        switch (a, b) {
        case (.el(let x), .el(let y)): x == y
        case (.text(let x), .text(let y)): bytesEqual(x, y)
        default: false
        }
    }
}

/// `xml::El` (re-exported by deckcraft as `XmlEl`).
public struct XMLEl: Sendable, Equatable {
    /// Qualified name as written (`p:sp`).
    public var name: String
    public var attrs: [(key: String, value: String)]
    public var children: [XMLNode]

    public init(name: String = "", attrs: [(key: String, value: String)] = [], children: [XMLNode] = []) {
        self.name = name
        self.attrs = attrs
        self.children = children
    }

    /// Rust's derived `PartialEq`: names, attributes and children byte for byte.
    public static func == (a: XMLEl, b: XMLEl) -> Bool {
        guard bytesEqual(a.name, b.name), a.attrs.count == b.attrs.count, a.children == b.children else { return false }
        for (x, y) in zip(a.attrs, b.attrs) where !bytesEqual(x.key, y.key) || !bytesEqual(x.value, y.value) {
            return false
        }
        return true
    }

    /// The local name: after the last `:` (`sp` for `p:sp`).
    public var local: Substring { localOf(name) }

    /// The prefix: before the first `:`, or empty.
    public var prefix: Substring {
        guard let colon = name.utf8.firstIndex(of: UInt8(ascii: ":")) else { return name[name.endIndex...] }
        return name[..<colon]
    }

    /// Is the local name `local`? (`is` as a member name needs no backticks at the call site:
    /// `e.is("sp")`.)
    public func `is`(_ local: String) -> Bool {
        bytesEqual(localOf(name), local)
    }

    /// Attribute by local name (`id` matches `id`; `r:id` matches `id` only when no plain `id` exists).
    /// Pass a qualified name (`r:id`) to require that prefix's local name with any prefix.
    public func attr(_ name: String) -> String? {
        if let colon = name.utf8.firstIndex(of: UInt8(ascii: ":")) {
            let l = name[name.utf8.index(after: colon)...]
            return attrs.first {
                $0.key.utf8.contains(UInt8(ascii: ":")) && !hasBytePrefix($0.key, "xmlns") && bytesEqual(localOf($0.key), l)
            }?.value
        }
        if let a = attrs.first(where: { bytesEqual($0.key, name) }) { return a.value }
        return attrs.first { !hasBytePrefix($0.key, "xmlns") && bytesEqual(localOf($0.key), name) }?.value
    }

    public func hasAttr(_ name: String) -> Bool {
        attr(name) != nil
    }

    /// Set (or add, at the end) the attribute with exactly this qualified name.
    public mutating func setAttr(_ name: String, _ value: String) {
        if let i = attrs.firstIndex(where: { bytesEqual($0.key, name) }) {
            attrs[i].value = value
        } else {
            attrs.append((name, value))
        }
    }

    /// The attribute as an integer: Rust's `str::parse::<i64>` of the trimmed value, else its `f64`
    /// parse (finite only) clamped to ±9e18 and truncated.
    public func i64(_ name: String) -> Int64? {
        guard let raw = attr(name) else { return nil }
        let v = rustTrim(raw)
        if let i = Int64(v, radix: 10) { return i }
        guard let f = rustParseF64(v), f.isFinite else { return nil }
        return Int64(rustCast: f.clamped(-9.0e18, 9.0e18))
    }

    /// `i64`, clamped to `i32`.
    public func i32(_ name: String) -> Int32? {
        i64(name).map { Int32(clamping: $0) }
    }

    /// `i64`, clamped to `0 … u32::MAX`.
    public func u32(_ name: String) -> UInt32? {
        i64(name).map { UInt32(clamping: $0) }
    }

    /// The trimmed attribute parsed as Rust parses an `f64`; finite values only.
    public func f64(_ name: String) -> Double? {
        guard let raw = attr(name), let f = rustParseF64(rustTrim(raw)), f.isFinite else { return nil }
        return f
    }

    /// `1`/`true`/`on` and `0`/`false`/`off` (trimmed); anything else is nil.
    public func bool(_ name: String) -> Bool? {
        guard let raw = attr(name) else { return nil }
        switch rustTrim(raw) {
        case "1", "true", "on": return true
        case "0", "false", "off": return false
        default: return nil
        }
    }

    /// The child elements, in order (`elements()`).
    public var elements: XMLElements { XMLElements(children, nil) }

    /// `elements_mut()`: calls `body` on each child element, in order, in place.
    public mutating func elementsMut(_ body: (inout XMLEl) throws -> Void) rethrows {
        for i in children.indices {
            guard case .el(var e) = children[i] else { continue }
            children[i] = .text("") // drop the second reference so `e` mutates in place
            defer { children[i] = .el(e) }
            try body(&e)
        }
    }

    /// The first child element with this local name.
    public func child(_ local: String) -> XMLEl? {
        for case .el(let e) in children where e.is(local) { return e }
        return nil
    }

    /// The child elements with this local name, in order (`children_named`).
    public func childrenNamed(_ local: String) -> XMLElements {
        XMLElements(children, local)
    }

    /// Follow a chain of child local names.
    public func path(_ names: [String]) -> XMLEl? {
        var cur = self
        for n in names {
            guard let c = cur.child(n) else { return nil }
            cur = c
        }
        return cur
    }

    /// `path`, with the names as arguments: `e.path("spPr", "xfrm")`.
    public func path(_ names: String...) -> XMLEl? {
        path(names)
    }

    /// First descendant (depth-first, bounded) with this local name.
    public func find(_ local: String) -> XMLEl? {
        func rec(_ e: XMLEl, _ depth: Int) -> XMLEl? {
            if depth > XML.maxDepth { return nil }
            for case .el(let c) in e.children {
                if c.is(local) { return c }
                if let f = rec(c, depth + 1) { return f }
            }
            return nil
        }
        return rec(self, 0)
    }

    /// All descendants with this local name (bounded depth), appended to `out` (`find_all`).
    public func findAll(_ local: String, into out: inout [XMLEl]) {
        func rec(_ e: XMLEl, _ depth: Int, _ out: inout [XMLEl]) {
            if depth > XML.maxDepth { return }
            for case .el(let c) in e.children {
                if c.is(local) { out.append(c) }
                rec(c, depth + 1, &out)
            }
        }
        rec(self, 0, &out)
    }

    /// All descendants with this local name (bounded depth).
    public func findAll(_ local: String) -> [XMLEl] {
        var out: [XMLEl] = []
        findAll(local, into: &out)
        return out
    }

    /// Concatenated text content of this element and its descendants.
    public var text: String {
        var s = ""
        func rec(_ e: XMLEl, _ depth: Int) {
            if depth > XML.maxDepth { return }
            for c in e.children {
                switch c {
                case .text(let t): s += t
                case .el(let e): rec(e, depth + 1)
                }
            }
        }
        rec(self, 0)
        return s
    }

    /// Value of `<x val="…"/>` child.
    public func childVal(_ local: String) -> String? {
        child(local)?.attr("val")
    }

    /// Serialize to a string (no XML declaration). Elements nested deeper than `XML.maxDepth` are
    /// left out.
    public func toXML() -> String {
        var s = ""
        XML.writeEl(self, &s, 0)
        return s
    }
}

/// The child elements of an element, optionally only those with one local name (`elements()`,
/// `children_named()`).
public struct XMLElements: Sequence, Sendable {
    let children: [XMLNode]
    let local: String?

    init(_ children: [XMLNode], _ local: String?) {
        self.children = children
        self.local = local
    }

    public struct Iterator: IteratorProtocol {
        var inner: IndexingIterator<[XMLNode]>
        let local: String?

        public mutating func next() -> XMLEl? {
            while let n = inner.next() {
                if case .el(let e) = n, local.map({ e.is($0) }) ?? true { return e }
            }
            return nil
        }
    }

    public func makeIterator() -> Iterator {
        Iterator(inner: children.makeIterator(), local: local)
    }
}

/// `xml::Doc` (re-exported as `XmlDoc`): a parsed document's root element.
public struct XMLDoc: Sendable, Equatable {
    public var root: XMLEl

    public init(root: XMLEl = XMLEl()) {
        self.root = root
    }

    /// Namespace declarations (`xmlns:x`, `xmlns`) on the root element.
    public func nsDecls() -> [(key: String, value: String)] {
        root.attrs.filter { bytesEqual($0.key, "xmlns") || hasBytePrefix($0.key, "xmlns:") }
    }
}

/// Parse XML bytes into a DOM (`parse_xml`). Bounded depth and node count; entity references are
/// resolved.
public func parseXML(_ bytes: [UInt8]) throws(PPTXError) -> XMLDoc {
    try XML.parse(bytes)
}

/// `parseXML` of a string's UTF-8.
public func parseXML(_ text: String) throws(PPTXError) -> XMLDoc {
    try XML.parse(Array(text.utf8))
}

// MARK: - Byte-wise string helpers (Rust compares strings byte for byte)

/// Rust's `==` on `str`.
@inline(__always)
func bytesEqual(_ a: some StringProtocol, _ b: some StringProtocol) -> Bool {
    a.utf8.elementsEqual(b.utf8)
}

/// Rust's `str::starts_with`.
@inline(__always)
func hasBytePrefix(_ s: some StringProtocol, _ prefix: some StringProtocol) -> Bool {
    s.utf8.starts(with: prefix.utf8)
}

/// Rust's `str::ends_with`.
@inline(__always)
func hasByteSuffix(_ s: some StringProtocol, _ suffix: some StringProtocol) -> Bool {
    s.utf8.count >= suffix.utf8.count && s.utf8.reversed().starts(with: suffix.utf8.reversed())
}

/// Rust's `str::eq_ignore_ascii_case`.
func eqIgnoreASCIICase(_ a: some StringProtocol, _ b: some StringProtocol) -> Bool {
    a.utf8.count == b.utf8.count && zip(a.utf8, b.utf8).allSatisfy { x, y in
        (x >= 0x41 && x <= 0x5A ? x + 32 : x) == (y >= 0x41 && y <= 0x5A ? y + 32 : y)
    }
}

/// Rust's `str::parse` for an unsigned integer: an optional `+`, then ASCII digits; nil on overflow.
func rustParseUnsigned<T: FixedWidthInteger & UnsignedInteger>(_ s: some StringProtocol, as: T.Type = T.self) -> T? {
    var u = Substring(s).utf8[...]
    if u.first == UInt8(ascii: "+") { u = u.dropFirst() }
    guard !u.isEmpty, u.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
    return T(String(decoding: u, as: UTF8.self), radix: 10)
}

/// After the last `:`.
@inline(__always)
func localOf(_ name: String) -> Substring {
    guard let colon = name.utf8.lastIndex(of: UInt8(ascii: ":")) else { return name[...] }
    return name[name.utf8.index(after: colon)...]
}

// MARK: - Parsing

/// The `xml` module's constants, parser, serializer and escapes.
enum XML {
    /// Maximum element nesting accepted when parsing.
    static let maxDepth = 256
    /// Maximum number of elements in one part.
    static let maxNodes = 4_000_000

    /// quick-xml's `SyntaxError` and `IllFormedError` messages, as `format!("{e}")` prints them.
    enum Fail {
        static let invalidBangMarkup = "syntax error: unknown or missed symbol in markup"
        static let unclosedPI = "syntax error: processing instruction not closed: `?>` not found before end of input"
        static let unclosedXmlDecl = "syntax error: XML declaration not closed: `?>` not found before end of input"
        static let unclosedComment = "syntax error: comment not closed: `-->` not found before end of input"
        static let unclosedDoctype = "syntax error: DOCTYPE not closed: `>` not found before end of input"
        static let unclosedCData = "syntax error: CDATA not closed: `]]>` not found before end of input"
        static let unclosedTag = "syntax error: tag not closed: `>` not found before end of input"
        static let unclosedSingleQuoted = "syntax error: attribute value not closed: `'` not found before end of input"
        static let unclosedDoubleQuoted = "syntax error: attribute value not closed: `\"` not found before end of input"
        static let missingDoctypeName = "ill-formed document: `<!DOCTYPE>` declaration does not contain a name of a document type"
        static let unclosedReference = "ill-formed document: entity or character reference not closed: `;` not found before end of input"
    }

    private static let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), amp = UInt8(ascii: "&"), semi = UInt8(ascii: ";")
    private static let quot = UInt8(ascii: "\""), apos = UInt8(ascii: "'"), bang = UInt8(ascii: "!")
    private static let slash = UInt8(ascii: "/"), question = UInt8(ascii: "?"), dash = UInt8(ascii: "-")
    private static let lbracket = UInt8(ascii: "["), rbracket = UInt8(ascii: "]")

    /// quick-xml's `is_whitespace`: space, CR, LF, tab.
    @inline(__always)
    static func isWS(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x0D || b == 0x0A || b == 0x09
    }

    /// One element being built, with the text that has arrived since its last child element (merged
    /// into one text node, as `push_text` merges into the last child).
    private struct Frame {
        var el: XMLEl
        var pending: String = ""

        mutating func flush() {
            if !pending.isEmpty {
                el.children.append(.text(pending))
                pending = ""
            }
        }
    }

    /// `xml::parse`.
    static func parse(_ input: [UInt8]) throws(PPTXError) -> XMLDoc {
        // Skip a UTF-8 BOM; UTF-16 parts (rare) are decoded first.
        let b: [UInt8]
        var pos = 0
        if input.starts(with: [0xFF, 0xFE]) || input.starts(with: [0xFE, 0xFF]) {
            b = Array(decodeUTF16(input).utf8)
        } else {
            b = input
            if b.starts(with: [0xEF, 0xBB, 0xBF]) { pos = 3 }
        }
        // quick-xml removes a UTF-8 BOM of its own (a second one, or one in decoded UTF-16).
        if b.count - pos >= 3, b[pos] == 0xEF, b[pos + 1] == 0xBB, b[pos + 2] == 0xBF { pos += 3 }

        var stack: [Frame] = []
        var root: XMLEl?
        var nodes = 0
        let n = b.count

        func pushText(_ s: String) {
            if s.isEmpty || stack.isEmpty { return }
            stack[stack.count - 1].pending += s
        }
        func attach(_ el: XMLEl) {
            if stack.isEmpty {
                root = el
            } else {
                stack[stack.count - 1].flush()
                stack[stack.count - 1].el.children.append(.el(el))
            }
        }

        while pos < n {
            let c = b[pos]
            if c == lt {
                guard pos + 1 < n else { throw .xml(Fail.unclosedTag) }
                switch b[pos + 1] {
                case bang:
                    pos = try bangElement(b, pos) { content in pushText(lineEnds(String(decoding: content, as: UTF8.self))) }
                case slash:
                    let end = try elementEnd(b, pos + 1)
                    // `End`: check_end_names is off and unmatched ends are allowed, so it only pops.
                    if var f = stack.popLast() {
                        f.flush()
                        attach(f.el)
                    }
                    pos = end + 1
                case question:
                    pos = try processingInstruction(b, pos)
                default:
                    let end = try elementEnd(b, pos + 1)
                    let empty = end >= pos + 2 && b[end - 1] == slash
                    let contentEnd = empty ? end - 1 : end
                    if root == nil {
                        nodes += 1
                        if empty {
                            if nodes > maxNodes { throw .xml("document too large") }
                            attach(startEl(b, pos + 1, contentEnd))
                        } else {
                            if nodes > maxNodes || stack.count >= maxDepth {
                                throw .xml("document too large or too deeply nested")
                            }
                            stack.append(Frame(el: startEl(b, pos + 1, contentEnd)))
                        }
                    }
                    // Content after the root element: ignored.
                    pos = end + 1
                }
            } else if c == amp {
                // A reference runs to the next `;`; a `&` or `<` (or the end) before it is an error.
                var j = pos + 1
                while j < n, b[j] != semi, b[j] != amp, b[j] != lt { j += 1 }
                guard j < n, b[j] == semi else { throw .xml(Fail.unclosedReference) }
                pushText(generalRef(b[(pos + 1) ..< j]))
                pos = j + 1
            } else {
                var j = pos
                while j < n, b[j] != lt, b[j] != amp { j += 1 }
                // A text chunk that isn't UTF-8 reads as nothing (`decode().unwrap_or_default()`).
                if !stack.isEmpty, let s = String(validating: b[pos ..< j], as: UTF8.self) {
                    pushText(lineEnds(s))
                }
                pos = j
            }
        }
        // Unclosed elements (truncated document): fold them up so partial content is still usable.
        while var f = stack.popLast() {
            f.flush()
            attach(f.el)
        }
        guard let root else { throw .xml("no root element") }
        return XMLDoc(root: root)
    }

    /// quick-xml's `ElementParser` from `start`: the index of the `>` that ends the tag (quotes hide
    /// `>`), or the error for an unclosed tag or attribute value.
    static func elementEnd(_ b: [UInt8], _ start: Int) throws(PPTXError) -> Int {
        var quote: UInt8 = 0
        var j = start
        while j < b.count {
            let x = b[j]
            if quote == 0 {
                if x == gt { return j }
                if x == quot || x == apos { quote = x }
            } else if x == quote {
                quote = 0
            }
            j += 1
        }
        switch quote {
        case apos: throw .xml(Fail.unclosedSingleQuoted)
        case quot: throw .xml(Fail.unclosedDoubleQuoted)
        default: throw .xml(Fail.unclosedTag)
        }
    }

    /// `<!…>` at `pos`: a comment (ignored), CDATA (its content goes to `cdata`) or a DOCTYPE
    /// (ignored). Returns the position after the closing `>`.
    private static func bangElement(_ b: [UInt8], _ pos: Int, cdata: (ArraySlice<UInt8>) -> Void) throws(PPTXError) -> Int {
        let n = b.count
        let chunk = pos + 2 // after `<!`
        guard chunk < n else { throw .xml(Fail.invalidBangMarkup) }
        switch b[chunk] {
        case lbracket:
            // The first `>` after `]]`.
            var j = chunk + 2
            while j < n, !(b[j] == gt && b[j - 1] == rbracket && b[j - 2] == rbracket) { j += 1 }
            guard j < n else { throw .xml(Fail.unclosedCData) }
            // `]]` can't overlap `<![CDATA[`, so a match has `j - 2 >= pos + 9`.
            guard b[pos ... j].starts(with: "<![CDATA[".utf8), j - 2 >= pos + 9 else { throw .xml(Fail.unclosedCData) }
            cdata(b[(pos + 9) ..< (j - 2)])
            return j + 1
        case dash:
            // The first `>` after `--`, at least `<!---->` long.
            var j = chunk + 4
            while j < n, !(b[j] == gt && b[j - 1] == dash && b[j - 2] == dash) { j += 1 }
            guard j < n else { throw .xml(Fail.unclosedComment) }
            guard b[pos ... j].starts(with: "<!--".utf8) else { throw .xml(Fail.unclosedComment) }
            return j + 1
        case UInt8(ascii: "D"), UInt8(ascii: "d"):
            guard let j = doctypeEnd(b, chunk) else { throw .xml(Fail.unclosedDoctype) }
            let buf = b[pos ... j]
            let doctype = "<!DOCTYPE".utf8
            guard buf.count >= 9, zip(buf.prefix(9), doctype).allSatisfy({ asciiLower($0) == asciiLower($1) }) else {
                throw .xml(Fail.unclosedDoctype)
            }
            // `<!DOCTYPE` then `>`: at least ten bytes, so `j >= pos + 9`.
            guard j >= pos + 9, b[(pos + 9) ..< j].contains(where: { !isWS($0) }) else { throw .xml(Fail.missingDoctypeName) }
            return j + 1
        default:
            throw .xml(Fail.invalidBangMarkup)
        }
    }

    @inline(__always)
    private static func asciiLower(_ x: UInt8) -> UInt8 {
        x >= 0x41 && x <= 0x5A ? x + 32 : x
    }

    /// quick-xml's `DtdParser` over the rest of the input from `start` (after `<!`): the index of the
    /// DOCTYPE's closing `>`, skipping quoted literals and the internal subset with its comments,
    /// processing instructions and declarations; nil at the end of input.
    private static func doctypeEnd(_ b: [UInt8], _ start: Int) -> Int? {
        enum State {
            case before(UInt8)
            case inside
            case after
            case comment
            case pi
            case elementDecl
            case quoteSensitive
        }
        let n = b.count
        var state = State.before(0)
        var cur = start
        while cur < n {
            switch state {
            case .before(0):
                guard let i = b[cur...].firstIndex(where: { $0 == apos || $0 == quot || $0 == lbracket || $0 == gt }) else {
                    return nil
                }
                switch b[i] {
                case apos, quot: state = .before(b[i])
                case lbracket: state = .inside
                default: return i
                }
                cur = i + 1
            case .before(let q):
                guard let i = b[cur...].firstIndex(of: q) else { return nil }
                state = .before(0)
                cur = i + 1
            case .inside:
                guard let i = b[cur...].firstIndex(where: { $0 == rbracket || $0 == lt }) else { return nil }
                if b[i] == rbracket {
                    state = .after
                    cur = i + 1
                    continue
                }
                // The markup after `<`.
                let m = b[(i + 1)...]
                if m.starts(with: [question]) {
                    state = .pi
                    cur = i + 2
                } else if m.starts(with: "!--".utf8) {
                    state = .comment
                    cur = i + 4
                } else if m.starts(with: "!ELEMENT".utf8) {
                    state = .elementDecl
                    cur = i + 9
                } else if m.starts(with: "!ENTITY".utf8) {
                    state = .quoteSensitive
                    cur = i + 8
                } else if m.starts(with: "!ATTLIST".utf8) {
                    state = .quoteSensitive
                    cur = i + 9
                } else if m.starts(with: "!NOTATION".utf8) {
                    state = .quoteSensitive
                    cur = i + 10
                } else if let g = m.firstIndex(of: gt) {
                    // Unknown markup ends at its `>`.
                    cur = g + 1
                } else {
                    // Undecided markup at the end of input.
                    return nil
                }
            case .after:
                return b[cur...].firstIndex(of: gt)
            case .comment:
                // `CommentParser`: the first `>` after `--`, both within this stretch.
                var j = cur + 2
                while j < n, !(b[j] == gt && b[j - 1] == dash && b[j - 2] == dash) { j += 1 }
                guard j < n else { return nil }
                state = .inside
                cur = j + 1
            case .pi:
                // `PiParser`: the first `?>`, resuming at its `>`.
                var j = cur + 1
                while j < n, !(b[j] == gt && b[j - 1] == question) { j += 1 }
                guard j < n else { return nil }
                state = .inside
                cur = j
            case .elementDecl:
                guard let i = b[cur...].firstIndex(of: gt) else { return nil }
                state = .inside
                cur = i + 1
            case .quoteSensitive:
                // An `ElementParser`: the first `>` outside quotes, resuming at it.
                guard let i = try? elementEnd(b, cur) else { return nil }
                state = .inside
                cur = i
            }
        }
        return nil
    }

    /// `<?…?>` at `pos` (declaration or processing instruction, both ignored): the position after it.
    private static func processingInstruction(_ b: [UInt8], _ pos: Int) throws(PPTXError) -> Int {
        let n = b.count
        // The first `>` preceded by `?`, counting the `?` of `<?`.
        var j = pos + 2
        while j < n, !(b[j] == gt && b[j - 1] == question) { j += 1 }
        guard j < n, j - pos + 1 > 3 else {
            // `PiParser::eof_error` of what was read: `<?xml` then whitespace, `?` or the end is a
            // declaration. `<?>` is read whole and reported the same way.
            let content = j < n ? b[pos ... j] : b[pos...]
            let isDecl = content.starts(with: "<?xml".utf8) && (content.count == 5 || isWS(content[content.startIndex + 5])
                || content[content.startIndex + 5] == question)
            throw .xml(isDecl ? Fail.unclosedXmlDecl : Fail.unclosedPI)
        }
        return j + 1
    }

    /// An element from the bytes of its tag between `<` and `>` (or `/>`): the name is the bytes up to
    /// the first whitespace; attributes as `attributes().with_checks(false).flatten()` yields them.
    private static func startEl(_ b: [UInt8], _ start: Int, _ end: Int) -> XMLEl {
        var nameEnd = start
        while nameEnd < end, !isWS(b[nameEnd]) { nameEnd += 1 }
        let name = String(decoding: b[start ..< nameEnd], as: UTF8.self)
        var attrs: [(key: String, value: String)] = []
        var it = AttrIterator(b: b, start: start, end: end, offset: nameEnd)
        while let a = it.next() {
            if let (k, v) = a {
                let key = String(decoding: b[k], as: UTF8.self)
                attrs.append((key, attributeValue(b[v])))
            }
        }
        return XMLEl(name: name, attrs: attrs, children: [])
    }

    /// quick-xml's attribute iterator (`IterState::next`, XML rules, duplicate checks off): each step
    /// yields an attribute's key and value ranges, or nil for a malformed one (skipped by `flatten`).
    private struct AttrIterator {
        enum State {
            case next(Int)
            case skipValue(Int)
            case done
        }

        let b: [UInt8]
        let start: Int
        let end: Int
        var state: State

        init(b: [UInt8], start: Int, end: Int, offset: Int) {
            self.b = b
            self.start = start
            self.end = end
            state = .next(offset)
        }

        /// nil when iteration is over; `.some(nil)` for an error item.
        mutating func next() -> (Range<Int>, Range<Int>)?? {
            var i: Int
            switch state {
            case .done: return nil
            case .next(let o): i = o
            case .skipValue(let o):
                // To the first whitespace after the unquoted value; the end of input ends iteration.
                var e = o
                while e < end, !XML.isWS(b[e]) { e += 1 }
                if e >= end { return nil }
                i = e
            }
            // The key starts at the next non-whitespace byte.
            while i < end, XML.isWS(b[i]) { i += 1 }
            guard i < end else {
                state = .done
                return nil
            }
            let startKey = i
            i += 1
            while i < end, b[i] != UInt8(ascii: "="), !XML.isWS(b[i]) { i += 1 }
            guard i < end else {
                // `key` then the end: expected `=`.
                state = .done
                return .some(nil)
            }
            let keyEnd = i
            if b[i] != UInt8(ascii: "=") {
                // Whitespace after the key: `=` must be the next non-whitespace byte.
                i += 1
                while i < end, XML.isWS(b[i]) { i += 1 }
                guard i < end else {
                    state = .done
                    return .some(nil)
                }
                if b[i] != UInt8(ascii: "=") {
                    state = .next(i)
                    return .some(nil)
                }
            }
            i += 1 // past `=`
            while i < end, XML.isWS(b[i]) { i += 1 }
            guard i < end else {
                state = .done
                return .some(nil)
            }
            let q = b[i]
            guard q == XML.quot || q == XML.apos else {
                state = .skipValue(i)
                return .some(nil)
            }
            let valueStart = i + 1
            var e = valueStart
            while e < end, b[e] != q { e += 1 }
            guard e < end else {
                state = .done
                return .some(nil)
            }
            state = .next(e + 1)
            return .some((startKey ..< keyEnd, valueStart ..< e))
        }
    }

    /// An attribute value: `decoded_and_normalized_value` (UTF-8, then XML 1.0 normalisation), or
    /// the raw bytes, lossily decoded, when either step fails.
    private static func attributeValue(_ raw: ArraySlice<UInt8>) -> String {
        guard String(validating: raw, as: UTF8.self) != nil, let normalized = normalizeAttribute(raw) else {
            return String(decoding: raw, as: UTF8.self)
        }
        return normalized
    }

    /// XML 1.0 attribute-value normalisation as quick-xml does it: tab, CR LF, CR and LF each become a
    /// space; `&#…;` and `&#x…;` become their character; `&amp;`, `&lt;`, `&gt;`, `&apos;`, `&quot;`
    /// their text. An unterminated or unknown reference, or a bad character reference, is an error
    /// (nil). `raw` is valid UTF-8.
    static func normalizeAttribute(_ raw: ArraySlice<UInt8>) -> String? {
        guard raw.contains(where: { $0 == 0x09 || $0 == 0x0D || $0 == 0x0A || $0 == amp }) else {
            return String(decoding: raw, as: UTF8.self)
        }
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var i = raw.startIndex
        let end = raw.endIndex
        while i < end {
            let x = raw[i]
            switch x {
            case 0x09, 0x0A:
                out.append(0x20)
                i += 1
            case 0x0D:
                out.append(0x20)
                i += (i + 1 < end && raw[i + 1] == 0x0A) ? 2 : 1
            case amp:
                guard let s = raw[(i + 1)...].firstIndex(of: semi) else { return nil }
                let pat = raw[(i + 1) ..< s]
                if pat.first == UInt8(ascii: "#") {
                    guard let c = parseNumber(pat.dropFirst()) else { return nil }
                    out.append(contentsOf: String(Character(c)).utf8)
                } else if let r = predefinedEntity(pat) {
                    out.append(contentsOf: r.utf8)
                } else {
                    return nil
                }
                i = s + 1
            default:
                out.append(x)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `resolve_xml_entity`.
    private static func predefinedEntity(_ name: some Collection<UInt8>) -> String? {
        if name.elementsEqual("lt".utf8) { return "<" }
        if name.elementsEqual("gt".utf8) { return ">" }
        if name.elementsEqual("amp".utf8) { return "&" }
        if name.elementsEqual("apos".utf8) { return "'" }
        if name.elementsEqual("quot".utf8) { return "\"" }
        return nil
    }

    /// quick-xml's `parse_number`: `x` then hex digits, or decimal digits; no sign; not 0, a surrogate
    /// or beyond U+10FFFF.
    static func parseNumber(_ num: some Collection<UInt8>) -> Unicode.Scalar? {
        var digits = num[...]
        var radix: UInt32 = 10
        if digits.first == UInt8(ascii: "x") {
            digits = digits.dropFirst()
            radix = 16
        }
        guard let first = digits.first, first != UInt8(ascii: "+"), first != UInt8(ascii: "-") else { return nil }
        var code: UInt32 = 0
        for d in digits {
            let v: UInt32
            switch d {
            case 0x30 ... 0x39: v = UInt32(d - 0x30)
            case 0x61 ... 0x66 where radix == 16: v = UInt32(d - 0x61 + 10)
            case 0x41 ... 0x46 where radix == 16: v = UInt32(d - 0x41 + 10)
            default: return nil
            }
            let (m, o1) = code.multipliedReportingOverflow(by: radix)
            let (a, o2) = m.addingReportingOverflow(v)
            if o1 || o2 { return nil }
            code = a
        }
        guard code != 0 else { return nil }
        return Unicode.Scalar(code)
    }

    /// The text of a reference in content (`&…;`, between the `&` and the `;`): a character
    /// reference's character, a predefined entity's text, otherwise nothing.
    private static func generalRef(_ content: ArraySlice<UInt8>) -> String {
        guard String(validating: content, as: UTF8.self) != nil else { return "" }
        if content.first == UInt8(ascii: "#") {
            return parseNumber(content.dropFirst()).map { String(Character($0)) } ?? ""
        }
        return predefinedEntity(content) ?? ""
    }

    /// XML 1.0 §2.11: a literal CR LF or lone CR in the document reads as LF. A `&#13;` reference is
    /// not literal and arrives as a reference, so it stays a CR.
    static func lineEnds(_ s: String) -> String {
        guard s.utf8.contains(0x0D) else { return s }
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        var it = s.utf8.makeIterator()
        var pendingCR = false
        while let x = it.next() {
            if pendingCR {
                pendingCR = false
                out.append(0x0A)
                if x == 0x0A { continue }
            }
            if x == 0x0D {
                pendingCR = true
            } else {
                out.append(x)
            }
        }
        if pendingCR { out.append(0x0A) }
        return String(decoding: out, as: UTF8.self)
    }

    /// A UTF-16 part (after its BOM) as a string, lossily, with its XML declaration dropped so the
    /// rest reads as UTF-8.
    static func decodeUTF16(_ bytes: [UInt8]) -> String {
        let le = bytes.starts(with: [0xFF, 0xFE])
        var units: [UInt16] = []
        let pairs = max(0, (bytes.count - 2) / 2)
        units.reserveCapacity(pairs)
        for k in 0 ..< pairs {
            let a = UInt16(bytes[2 + 2 * k]), b = UInt16(bytes[3 + 2 * k])
            units.append(le ? a | b << 8 : a << 8 | b)
        }
        let s = String(decoding: units, as: UTF16.self)
        // Drop the encoding declaration so the parser reads it as UTF-8.
        let u = Array(s.utf8)
        guard u.starts(with: "<?xml".utf8) else { return s }
        var i = 5
        while i + 1 < u.count {
            if u[i] == question, u[i + 1] == gt { return String(decoding: u[(i + 2)...], as: UTF8.self) }
            i += 1
        }
        return s
    }

    // MARK: - Writing

    /// `write_el`.
    static func writeEl(_ e: XMLEl, _ s: inout String, _ depth: Int) {
        if depth > maxDepth { return }
        s += "<"
        s += e.name
        for (k, v) in e.attrs {
            s += " "
            s += k
            s += "=\""
            s += escAttr(v)
            s += "\""
        }
        if e.children.isEmpty {
            s += "/>"
            return
        }
        s += ">"
        for c in e.children {
            switch c {
            case .text(let t): s += esc(t)
            case .el(let c): writeEl(c, &s, depth + 1)
            }
        }
        s += "</"
        s += e.name
        s += ">"
    }

    /// Escape text content (and drop characters XML 1.0 forbids): `&`, `<`, `>` and CR (`&#13;`);
    /// C0 controls other than tab and LF, U+FFFE and U+FFFF are dropped.
    static func esc(_ s: String) -> String {
        escape(s, attribute: false)
    }

    /// Escape an attribute value: `esc`'s escapes plus `"`, LF (`&#10;`) and tab (`&#9;`).
    static func escAttr(_ s: String) -> String {
        escape(s, attribute: true)
    }

    private static func escape(_ s: String, attribute: Bool) -> String {
        let u = s.utf8
        // Most text needs nothing.
        let clean = !u.contains { x in
            x == amp || x == lt || x == gt || x < 0x20 || x == 0xEF || (attribute && x == quot)
        }
        if clean { return s }
        let bytes = Array(u)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 16)
        var i = 0
        while i < bytes.count {
            let x = bytes[i]
            switch x {
            case amp: out.append(contentsOf: "&amp;".utf8)
            case lt: out.append(contentsOf: "&lt;".utf8)
            case gt: out.append(contentsOf: "&gt;".utf8)
            case 0x0D: out.append(contentsOf: "&#13;".utf8)
            case quot where attribute: out.append(contentsOf: "&quot;".utf8)
            case 0x0A where attribute: out.append(contentsOf: "&#10;".utf8)
            case 0x09 where attribute: out.append(contentsOf: "&#9;".utf8)
            case 0x09, 0x0A: out.append(x)
            case 0 ..< 0x20: break
            case 0xEF where i + 2 < bytes.count && bytes[i + 1] == 0xBF && (bytes[i + 2] == 0xBE || bytes[i + 2] == 0xBF):
                // U+FFFE, U+FFFF
                i += 3
                continue
            default: out.append(x)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Building

/// `xml::A`: an attribute list for `W`, values formatted as Rust's `ToString` formats them.
struct A {
    var v: [(key: String, value: String)] = []

    init() {}

    /// `A::new()`.
    static func new() -> A { A() }

    /// Add `k="v"`.
    func a(_ k: String, _ v: some RustDisplayable) -> A {
        var x = self
        x.v.append((k, v.rustDisplay))
        return x
    }

    /// Add `k="v"` when `v` is present.
    func o<T: RustDisplayable>(_ k: String, _ v: T?) -> A {
        guard let v else { return self }
        return a(k, v)
    }

    /// Boolean attribute written as `1`/`0` when present.
    func b(_ k: String, _ v: Bool?) -> A {
        guard let v else { return self }
        return a(k, v ? "1" : "0")
    }

    /// Boolean attribute written only when true.
    func t(_ k: String, _ v: Bool) -> A {
        v ? a(k, "1") : self
    }
}

/// `xml::W`: a string builder for XML parts. `W.new()` starts with the XML declaration; `W.frag()`
/// (and `W()`, Rust's `W::default()`) start empty.
struct W {
    var s: String

    /// `W::default()`: empty.
    init() { s = "" }

    /// `W::new()`: the standalone UTF-8 declaration and a newline.
    static func new() -> W {
        var w = W()
        w.s = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        return w
    }

    /// `W::frag()`: empty, for fragments.
    static func frag() -> W { W() }

    private mutating func attrs(_ a: A) {
        for (k, v) in a.v {
            s += " "
            s += k
            s += "=\""
            s += XML.escAttr(v)
            s += "\""
        }
    }

    mutating func open(_ name: String, _ a: A) {
        s += "<"
        s += name
        attrs(a)
        s += ">"
    }

    mutating func open0(_ name: String) {
        s += "<"
        s += name
        s += ">"
    }

    mutating func close(_ name: String) {
        s += "</"
        s += name
        s += ">"
    }

    mutating func empty(_ name: String, _ a: A) {
        s += "<"
        s += name
        attrs(a)
        s += "/>"
    }

    mutating func empty0(_ name: String) {
        s += "<"
        s += name
        s += "/>"
    }

    /// `<name val="v"/>`
    mutating func val(_ name: String, _ v: some RustDisplayable) {
        empty(name, A().a("val", v))
    }

    mutating func text(_ t: String) {
        s += XML.esc(t)
    }

    /// `<name>text</name>`
    mutating func elt(_ name: String, _ t: String) {
        open0(name)
        text(t)
        close(name)
    }

    mutating func raw(_ xml: String) {
        s += xml
    }

    func finish() -> [UInt8] {
        Array(s.utf8)
    }
}
