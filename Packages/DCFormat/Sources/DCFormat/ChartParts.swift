// DCFormat — keep opaque chart payloads out of the JSON manifest and within the media load budget. Port
// of deckcraft crates/format/src/chart_parts.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCModel
import DCZip

enum ChartParts {
    static let prefix = "chart-parts/"

    struct Payload {
        var name: String
        var contentType: String
        var bytes: [UInt8]
    }

    /// Moves every chart part's bytes out of the presentation, naming the zip entry each goes to.
    static func separate(_ p: inout Presentation) -> [Payload] {
        var payloads: [Payload] = []
        // The visitors are concrete over `FormatError`: generic typed throws specialised to `Never` here
        // crashed the optimizer (Swift 6.4 release builds: "swifterror value can only be loaded…").
        try? visitParts(&p) { (part: inout ChartPart) in
            // The native namespace is independent of the original OPC names, which may repeat when charts
            // from several decks are combined. No user-supplied path is extracted.
            let entry = "\(prefix)\(payloads.count)"
            part.nativeEntry = entry
            payloads.append(Payload(name: entry, contentType: part.contentType, bytes: part.bytes))
            part.bytes = []
        }
        return payloads
    }

    /// Reads each chart part's bytes back from its zip entry, charging them to the load budget.
    static func restore(
        _ p: inout Presentation, _ z: ZipReader, left: inout Int, items: Int, maxItems: Int, damaged: inout [String]
    ) throws(FormatError) {
        var items = items
        var seen = Set<String>()
        var leftNow = left
        try visitParts(&p) { (part: inout ChartPart) throws(FormatError) in
            if items >= maxItems { throw .damaged("media and chart parts exceed \(maxItems) items") }
            items += 1
            if let entry = part.nativeEntry {
                part.nativeEntry = nil
                // Accept only names produced by `separate`, and inflate each member once.
                let canonical = entry.hasPrefix(prefix)
                    && UInt(entry.dropFirst(prefix.count)).map { entry == "\(prefix)\($0)" } == true
                if !canonical || !seen.insert(entry).inserted || !part.bytes.isEmpty {
                    throw .damaged("invalid or ambiguous chart part reference")
                }
                guard let e = DeckFormat.entry(z, entry) else {
                    // Missing members consume no inflation work and can be reported for recovery.
                    damaged.append("\(entry): missing chart part")
                    return
                }
                if e.uncompressedSize > leftNow {
                    throw .damaged("embedded media and chart parts are larger than DeckCraft can open")
                }
                // A CRC/decode error may already have inflated bytes. Stop on that first error rather than
                // letting later corrupt members reuse the unchanged byte budget.
                let bytes = try DeckFormat.readEntry(z, entry, max: Swift.min(leftNow, DeckFormat.maxEntry))
                leftNow -= bytes.count
                part.bytes = bytes
            } else {
                // Older manifests used JSON byte arrays. Charge those too, so resaving migrates them
                // losslessly.
                let size = part.bytes.count
                if size > Swift.min(leftNow, DeckFormat.maxEntry) {
                    throw .damaged("inline chart part is larger than DeckCraft can open")
                }
                leftNow -= size
            }
        }
        left = leftNow
    }

    /// Every chart part on every slide, master and layout (notes and handout masters included), groups
    /// walked with an explicit stack.
    private static func visitParts(_ p: inout Presentation, _ visit: (inout ChartPart) throws(FormatError) -> Void) throws(FormatError) {
        for i in p.slides.indices { try shapes(&p.slides[i].shapes, visit) }
        for i in p.masters.indices { try masterParts(&p.masters[i], visit) }
        if var m = p.notesMaster {
            try masterParts(&m, visit)
            p.notesMaster = m
        }
        if var m = p.handoutMaster {
            try masterParts(&m, visit)
            p.handoutMaster = m
        }
    }

    private static func masterParts(_ m: inout Master, _ visit: (inout ChartPart) throws(FormatError) -> Void) throws(FormatError) {
        try shapes(&m.shapes, visit)
        for l in m.layouts.indices { try shapes(&m.layouts[l].shapes, visit) }
    }

    private static func shapes(_ shapes: inout [Shape], _ visit: (inout ChartPart) throws(FormatError) -> Void) throws(FormatError) {
        for i in shapes.indices {
            switch shapes[i].kind {
            case .group(var children, let child):
                shapes[i].kind = .shape
                defer { shapes[i].kind = .group(children: children, child: child) }
                try Self.shapes(&children, visit)
            case .chart(var chart):
                shapes[i].kind = .shape
                defer { shapes[i].kind = .chart(chart) }
                for k in chart.kept.parts.indices { try visit(&chart.kept.parts[k]) }
            default:
                break
            }
        }
    }
}
