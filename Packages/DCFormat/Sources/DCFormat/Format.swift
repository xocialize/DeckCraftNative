// DCFormat — the native `.deckcraft` format: a zip holding `presentation.json` (the model, minus media
// bytes), `media/<id>` and `chart-parts/<index>` binary entries, and `mimetype`. Readers ignore unknown
// fields, so newer files open in older builds with what those builds understand. Port of deckcraft
// crates/format/src/lib.rs and finite.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// `presentation.json` is written byte for byte as deckcraft writes it (DCCore's serde_json-compatible
// writer; non-finite floats as `0.0`, as `finite::Finite` does). The zip around it is ours: the entries
// and their contents match, the deflate streams and timestamps don't.
import DCCore
import DCGeometry
import DCModel
import DCZip

public enum DeckFormat {
    public static let mimetype = "application/vnd.storyteller.deckcraft+zip"
    /// Files written before the SlideCraft → DeckCraft rename (`.slidecraft`) are still read.
    public static let legacyMimetype = "application/vnd.storyteller." + "slide" + "craft+zip"
    public static let fileExtension = "deckcraft"
    /// Format version written into the manifest.
    public static let version: UInt32 = 1
    /// Written as the manifest's `generator`.
    public static let generator = "DeckCraftNative 0.1.5"
    /// Largest entry inflated (guards against zip bombs).
    static let maxEntry: Int = 2 << 30
    /// All embedded media and chart sidecars together, inflated (#393).
    static let maxTotalMedia: Int = 4 << 30
    /// Media items and chart sidecar parts one file may list.
    static let maxMediaItems = 100_000
}

public enum FormatError: Error, Sendable, Equatable, CustomStringConvertible {
    case notOurs(String)
    case damaged(String)
    case write(String)

    public var description: String {
        switch self {
        case .notOurs(let s): "not a DeckCraft file: \(s)"
        case .damaged(let s): "damaged file: \(s)"
        case .write(let s): "write failed: \(s)"
        }
    }
}

/// What one load may inflate.
struct Budget {
    var total: Int
    var items: Int
}

/// `presentation.json`: the format name and version, the writer, and the presentation.
struct Manifest {
    var format: String
    var version: UInt32
    var generator: String
    var presentation: Presentation

    func toJSON() -> JSON {
        var o = JSONObject()
        o.put("format", format)
        o.put("version", version)
        o.put("generator", generator)
        o.put("presentation", presentation)
        return .object(o)
    }

    init(format: String, version: UInt32, generator: String, presentation: Presentation) {
        self.format = format
        self.version = version
        self.generator = generator
        self.presentation = presentation
    }

    init(fromJSON json: JSON) throws(JSONDecodeError) {
        let f = try JSONFields(json, "Manifest")
        format = try f.required("format")
        version = try f.required("version")
        generator = try f.required("generator")
        presentation = try f.required("presentation")
    }
}

extension DeckFormat {
    /// Serialize a presentation.
    public static func save(_ p: Presentation) throws(FormatError) -> [UInt8] {
        do {
            var z = ZipWriter()
            try z.add("mimetype", Array(mimetype.utf8))
            var presentation = p
            let parts = ChartParts.separate(&presentation)
            let m = Manifest(format: "deckcraft", version: version, generator: generator, presentation: presentation)
            let json = JSONWriter(nonFiniteAsZero: true).bytes(m.toJSON())
            try z.add("presentation.json", json, compress: true)
            for item in p.media {
                if item.link != nil && item.data.isEmpty { continue }
                // Already-compressed media is stored, not deflated again.
                try z.add("media/\(item.id.rawValue)", item.data, compress: !isCompressed(item.contentType))
            }
            for part in parts {
                try z.add(part.name, part.bytes, compress: !isCompressed(part.contentType))
            }
            return try z.finish()
        } catch {
            throw .write(String(describing: error))
        }
    }

    static func isCompressed(_ ct: String) -> Bool {
        ct.hasPrefix("image/jpeg") || ct.hasPrefix("image/png") || ct.hasPrefix("video/") || ct.hasPrefix("audio/mpeg")
            || ct.hasPrefix("audio/mp4") || ct.contains("zip")
    }

    /// Does this look like a `.deckcraft` file? (`PK`, and a mimetype within the first bytes.)
    public static func sniff(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2, bytes[0] == 0x50, bytes[1] == 0x4B else { return false }
        return [mimetype, legacyMimetype].contains { m in
            let needle = Array(m.utf8)
            let windows = Swift.max(0, Swift.min(200, bytes.count - needle.count + 1))
            return (0 ..< windows).contains { bytes[$0 ..< $0 + needle.count].elementsEqual(needle) }
        }
    }

    /// The member named `name`. With duplicate names the last one wins, as in the Rust `zip` crate
    /// deckcraft reads with (DCZip's own lookup keeps the first).
    static func entry(_ z: ZipReader, _ name: String) -> ZipEntry? {
        z.entries.last { $0.name == name }
    }

    /// Read one member, refusing it before inflating if it declares more than `max` bytes.
    static func readEntry(_ z: ZipReader, _ name: String, max: Int) throws(FormatError) -> [UInt8] {
        guard let e = entry(z, name) else { throw .damaged("\(name): not found") }
        if e.uncompressedSize > max { throw .damaged("\(name) is too large") }
        do {
            let out = try z.read(e, max: max)
            if out.count > max { throw FormatError.damaged("\(name) is too large") }
            return out
        } catch let error as FormatError {
            throw error
        } catch {
            throw .damaged("\(name): \(error)")
        }
    }

    /// Read a presentation. Missing media/chart parts are left empty; use `loadChecked` to learn which.
    public static func load(_ bytes: [UInt8]) throws(FormatError) -> Presentation {
        try loadChecked(bytes).presentation
    }

    /// Read a presentation and list media that couldn't be read, plus missing chart members. A chart
    /// member that is present but fails decoding, CRC or its entry limit refuses the file. Linked media
    /// saved without its bytes isn't damage.
    public static func loadChecked(_ bytes: [UInt8]) throws(FormatError) -> (presentation: Presentation, damaged: [String]) {
        try load(bytes, within: Budget(total: maxTotalMedia, items: maxMediaItems))
    }

    static func load(_ bytes: [UInt8], within budget: Budget) throws(FormatError) -> (presentation: Presentation, damaged: [String]) {
        let z: ZipReader
        do {
            z = try ZipReader(bytes)
        } catch {
            throw .notOurs(String(describing: error))
        }
        let json: [UInt8]
        do {
            json = try readEntry(z, "presentation.json", max: maxEntry)
        } catch {
            throw .notOurs("no presentation.json")
        }
        let m = try parseManifest(json)
        if m.format != "deckcraft" { throw .notOurs(m.format) }
        var p = m.presentation
        var damaged: [String] = []
        let items = p.media.count
        if items > budget.items { throw .damaged("\(p.media.count) media items (at most \(budget.items))") }
        // A repeated id names the same member: keep the first item, so the member is inflated once and the
        // deck can be saved again (a zip can't hold two `media/<id>`).
        var seen = Set<MediaId>()
        p.media = p.media.filter { seen.insert($0.id).inserted }
        var left = budget.total
        for i in p.media.indices {
            let name = "media/\(p.media[i].id.rawValue)"
            let entry = Self.entry(z, name)
            let linkedOnly = p.media[i].link != nil && entry == nil
            if let e = entry, e.uncompressedSize > left {
                throw .damaged("embedded media is larger than DeckCraft can open")
            }
            do {
                let data = try readEntry(z, name, max: Swift.min(left, maxEntry))
                left -= data.count
                p.media[i].data = data
            } catch {
                if !linkedOnly { damaged.append(error.description) }
            }
        }
        try ChartParts.restore(&p, z, left: &left, items: items, maxItems: budget.items, damaged: &damaged)
        repair(&p)
        return (p, damaged)
    }

    /// Parse `presentation.json`. serde_json writes a NaN or infinite number as `null`, which then fails
    /// to read back as a number, so deckcraft could save a file it couldn't open: each such `null` reads
    /// as 0 instead (`repair` then brings the value into range); anything else that doesn't parse is
    /// damage. deckcraft finds those `null`s by patching and re-parsing; reading them as 0 where a float
    /// is required gives the same presentation.
    static func parseManifest(_ json: [UInt8]) throws(FormatError) -> Manifest {
        let value: JSON
        do {
            value = try JSONParser.parse(json)
        } catch {
            throw .damaged(error.description)
        }
        do {
            return try JSONDecoding.$nullFloatsAsZero.withValue(true) { try Manifest(fromJSON: value) }
        } catch {
            throw .damaged(String(describing: error))
        }
    }
}
