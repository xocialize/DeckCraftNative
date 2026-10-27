// DCExtensionKit — what the Quick Look and Spotlight extensions share: reading a presentation file inside an
// extension's memory budget. Not a port; deckcraft has no system extensions. The bytes go through the engine's
// own reader (`FileCommands.openChecked`, as the app opens files), with two bounds of its own:
//
// - a file larger than `DeckLimits.maxFileBytes` isn't read whole;
// - a *text* read (Spotlight, and a file too large to read whole) copies only the package's small parts —
//   the XML or JSON, never the pictures, media, embedded files or fonts — into a new archive in memory and
//   opens that. Missing media is something the engine already tolerates (it reports it as damage), so the
//   slides, their text, notes and comments read the same, at a cost proportional to the text.
import DCCore
import DCEngine
import DCFormat
import DCModel
import DCPPTX
import DCZip
import Foundation

/// Why a file couldn't be read.
public enum DeckFileError: Error, Equatable, Sendable {
    /// The file couldn't be opened or read (the system's reason).
    case unreadable(String)
    /// Larger than an extension reads (`bytes`, the limit).
    case tooLarge(bytes: Int, limit: Int)
    /// Neither a `.deckcraft` file nor an Open XML presentation.
    case notAPresentation
    /// A password-protected (encrypted) Office file.
    case encrypted
    /// The engine refused it; its message, shown as is.
    case damaged(String)
}

/// How much an extension reads.
public struct DeckLimits: Sendable, Equatable {
    /// Read the whole file only up to this size.
    public var maxFileBytes: Int
    /// In a text read: the largest part kept (uncompressed), and all parts kept together.
    public var maxPartBytes: Int
    public var maxTextBytes: Int

    public init(maxFileBytes: Int, maxPartBytes: Int, maxTextBytes: Int) {
        self.maxFileBytes = maxFileBytes
        self.maxPartBytes = maxPartBytes
        self.maxTextBytes = maxTextBytes
    }

    /// Quick Look's preview: a whole deck with its pictures.
    public static let preview = DeckLimits(maxFileBytes: 512 << 20, maxPartBytes: 64 << 20, maxTextBytes: 192 << 20)
    /// A thumbnail: one slide, many files in a row (Finder), so a tighter budget.
    public static let thumbnail = DeckLimits(maxFileBytes: 128 << 20, maxPartBytes: 32 << 20, maxTextBytes: 96 << 20)
    /// Spotlight: text only, always.
    public static let spotlight = DeckLimits(maxFileBytes: 0, maxPartBytes: 32 << 20, maxTextBytes: 96 << 20)
}

/// A presentation read by an extension.
public struct DeckFile: Sendable {
    public var presentation: Presentation
    /// What the engine reported lost: pictures and media, slides.
    public var damage: Damage
    /// Read without its pictures and media (`DeckReader.readText`).
    public var textOnly: Bool
    /// The file's name with its extension.
    public var fileName: String

    public init(presentation: Presentation, damage: Damage, textOnly: Bool, fileName: String) {
        self.presentation = presentation
        self.damage = damage
        self.textOnly = textOnly
        self.fileName = fileName
    }

    /// The title to show: the document's own (File › Properties), else the file name without its extension.
    public var title: String {
        let own = String(rustTrim(presentation.props.title))
        if !own.isEmpty { return own }
        let stem = (fileName as NSString).deletingPathExtension
        return stem.isEmpty ? fileName : stem
    }
}

public enum DeckReader {
    /// The whole file, pictures included, when it is within `limits.maxFileBytes`; otherwise a text read
    /// when `orText`, else `.tooLarge`.
    public static func read(_ url: URL, limits: DeckLimits, orText: Bool) throws(DeckFileError) -> DeckFile {
        let size = try fileSize(url)
        if size > limits.maxFileBytes {
            if orText { return try readText(url, limits: limits) }
            throw .tooLarge(bytes: size, limit: limits.maxFileBytes)
        }
        let bytes: [UInt8]
        do {
            bytes = [UInt8](try Data(contentsOf: url, options: .mappedIfSafe))
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        return try open(url.lastPathComponent, bytes, textOnly: false)
    }

    /// The file without its pictures, media, embedded objects and fonts: its slides, text, notes and comments.
    public static func readText(_ url: URL, limits: DeckLimits) throws(DeckFileError) -> DeckFile {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { throw .unreadable(String(cString: strerror(errno))) }
        let zip: ZipFileReader
        do {
            zip = try ZipFileReader(fileDescriptor: fd)
        } catch {
            // Not a zip. An encrypted Office file is a compound file holding an encrypted package.
            if let head = try? readHead(url, limits.maxPartBytes), PPTX.isEncrypted(head) { throw .encrypted }
            throw .notAPresentation
        }
        let bytes = try textPackage(zip, limits: limits)
        return try open(url.lastPathComponent, bytes, textOnly: true)
    }

    /// Is this entry worth keeping in a text read? Parts that hold no text: the media of either format
    /// (`.deckcraft`: `media/<id>`; PPTX: `ppt/media/`), embedded files and fonts, and the package thumbnail.
    static func keepsText(_ name: String) -> Bool {
        let lower = rustASCIILowercase(name)
        for prefix in ["media/", "ppt/media/", "ppt/embeddings/", "ppt/fonts/", "docprops/thumbnail"] where lower.hasPrefix(prefix) {
            return false
        }
        return true
    }

    /// A new archive of `zip`'s text parts, in their order (a `.deckcraft` file's `mimetype` stays first,
    /// where `DeckFormat.sniff` looks), stored uncompressed.
    static func textPackage(_ zip: ZipFileReader, limits: DeckLimits) throws(DeckFileError) -> [UInt8] {
        var out = ZipWriter()
        var total = 0
        var seen = Set<String>()
        do {
            for e in zip.entries where keepsText(e.name) && seen.insert(e.name).inserted {
                if e.uncompressedSize > limits.maxPartBytes || total + e.uncompressedSize > limits.maxTextBytes { continue }
                guard let data = try? zip.read(e, max: limits.maxPartBytes) else { continue }
                total += data.count
                try out.add(e.name, data, compress: false)
            }
            return try out.finish()
        } catch {
            throw .damaged(String(describing: error))
        }
    }

    /// Recognise `bytes` and read them with the engine.
    static func open(_ name: String, _ bytes: [UInt8], textOnly: Bool) throws(DeckFileError) -> DeckFile {
        guard DeckFormat.sniff(bytes) || PPTX.sniff(bytes) else {
            throw PPTX.isEncrypted(bytes) ? .encrypted : .notAPresentation
        }
        do {
            let (p, damage) = try FileCommands.openChecked(name, bytes)
            return DeckFile(presentation: p, damage: damage, textOnly: textOnly, fileName: name)
        } catch {
            throw .damaged(String(describing: error))
        }
    }

    static func fileSize(_ url: URL) throws(DeckFileError) -> Int {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile ?? false else { throw DeckFileError.notAPresentation }
            return values.fileSize ?? 0
        } catch let e as DeckFileError {
            throw e
        } catch {
            throw .unreadable(error.localizedDescription)
        }
    }

    static func readHead(_ url: URL, _ count: Int) throws -> [UInt8] {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        return [UInt8](try h.read(upToCount: count) ?? Data())
    }

    /// The picture an Office package carries of its first slide (`docProps/thumbnail.jpeg`, or whatever the
    /// package relationship of type `…/metadata/thumbnail` names), at most `maxBytes`; nil when there is none.
    public static func embeddedThumbnail(_ url: URL, maxBytes: Int = 8 << 20) -> [UInt8]? {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return nil }
        guard let zip = try? ZipFileReader(fileDescriptor: fd) else { return nil }
        var name = "docProps/thumbnail.jpeg"
        if let rels = try? zip.read(named: "_rels/.rels", max: 1 << 20), let target = thumbnailTarget(String(decoding: rels, as: UTF8.self)) {
            name = target
        }
        guard let e = zip.find(name), e.uncompressedSize <= maxBytes, let data = try? zip.read(e, max: maxBytes), !data.isEmpty else { return nil }
        return data
    }

    /// The target of the package-level thumbnail relationship in `_rels/.rels`, relative to the package root.
    static func thumbnailTarget(_ xml: String) -> String? {
        for rel in xml.components(separatedBy: "<Relationship").dropFirst() {
            guard rel.contains("/metadata/thumbnail\""), let target = attribute(rel, "Target") else { continue }
            let t = target.hasPrefix("/") ? String(target.dropFirst()) : target
            return t.isEmpty || t.contains("..") ? nil : t
        }
        return nil
    }

    static func attribute(_ tag: String, _ name: String) -> String? {
        guard let start = tag.range(of: name + "=\"") else { return nil }
        let rest = tag[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
