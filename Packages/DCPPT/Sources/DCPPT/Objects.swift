// DCPPT — a `.ppt`'s external objects (P4; [MS-PPT] 2.10): the document's ExObjList holds OLE objects, movies and
// sounds, each with an id that a shape names in its ExObjRefAtom. The shape itself is a picture: an OLE object's
// preview, a movie's first frame, a sound's icon.
//
// - **OLE objects** (embedded, linked, ActiveX controls) become DCModel `opaque` shapes showing their preview, labelled
//   with their program id (`MSGraph.Chart.8`…) or menu name; saved as `.pptx` they are that picture. Their data isn't
//   carried over.
// - **Movies** (ExMCIMovie, ExAviMovie) are links to a file: a linked video with the shape's picture as its poster.
// - **Sounds**: a WAV embedded in the document's SoundCollection becomes embedded audio; a linked WAV or MIDI file a
//   linked one. CD audio has no file and is left out.
import DCModel

struct ExObject {
    enum Kind {
        case ole(label: String)
        case video(path: String)
        case audio(path: String)
        case embeddedSound(id: String)
    }
    var kind: Kind
    var loop = false
    var rewind = false
}

struct ExObjects {
    var objects: [UInt32: ExObject] = [:]
    /// The SoundCollection's sounds by their id: name, extension and data.
    var sounds: [String: (name: String, ext: String, data: [UInt8])] = [:]
    /// Each object's media, once added.
    var media: [UInt32: MediaId] = [:]

    static func read(_ b: [UInt8], _ document: [Record]) -> ExObjects {
        var out = ExObjects()
        if let list = document.first(where: { $0.type == RT.externalObjectList }) {
            for c in list.children(b) {
                let kids = c.children(b)
                func string(_ instance: UInt16) -> String? {
                    kids.first { $0.type == RT.cString && $0.instance == instance }.map { Document.unicode(b, $0.body) }
                }
                func media() -> (id: UInt32, loop: Bool, rewind: Bool)? {
                    // An ExVideoContainer wraps a movie's atom and path.
                    let atoms = kids + kids.filter { $0.type == RT.exVideo }.flatMap { $0.children(b) }
                    guard let a = atoms.first(where: { $0.type == RT.exMediaAtom }), a.body.count >= 8 else { return nil }
                    let flags = le16(b, a.body.lowerBound + 4)
                    return (le32(b, a.body.lowerBound), flags & 1 != 0, flags & 2 != 0)
                }
                func path() -> String? {
                    let video = kids.first { $0.type == RT.exVideo }.map { $0.children(b) } ?? []
                    return (video + kids).first { $0.type == RT.cString }.map { Document.unicode(b, $0.body) }
                }
                switch c.type {
                case RT.exOleEmbed, RT.exOleLink, RT.exControl:
                    guard let atom = kids.first(where: { $0.type == RT.exOleObjAtom }), atom.body.count >= 16 else { continue }
                    let id = le32(b, atom.body.lowerBound + 8)
                    let label = [string(2), string(1), string(3)].compactMap { $0 }.first { !$0.isEmpty } ?? "Object"
                    out.objects[id] = ExObject(kind: .ole(label: label))
                case RT.exMciMovie, RT.exAviMovie:
                    guard let m = media(), let p = path(), !p.isEmpty else { continue }
                    out.objects[m.id] = ExObject(kind: .video(path: p), loop: m.loop, rewind: m.rewind)
                case RT.exWavAudioLink, RT.exMidiAudio:
                    guard let m = media(), let p = path(), !p.isEmpty else { continue }
                    out.objects[m.id] = ExObject(kind: .audio(path: p), loop: m.loop, rewind: m.rewind)
                case RT.exWavAudioEmbedded:
                    guard let m = media(), let a = kids.first(where: { $0.type == RT.exWavAudioEmbeddedAtom }), a.body.count >= 4
                    else { continue }
                    out.objects[m.id] = ExObject(kind: .embeddedSound(id: String(le32(b, a.body.lowerBound))), loop: m.loop, rewind: m.rewind)
                default: continue
                }
            }
        }
        if let collection = document.first(where: { $0.type == RT.soundCollection }) {
            for s in collection.children(b) where s.type == RT.sound {
                let kids = s.children(b)
                func string(_ instance: UInt16) -> String {
                    kids.first { $0.type == RT.cString && $0.instance == instance }.map { Document.unicode(b, $0.body) } ?? ""
                }
                guard let data = kids.first(where: { $0.type == RT.soundDataBlob }) else { continue }
                out.sounds[string(2)] = (string(0), string(1), Array(b[data.body]))
            }
        }
        return out
    }

    /// The media of object `id` (a movie or a sound), adding it to `p` the first time.
    mutating func media(_ id: UInt32, _ p: inout Presentation) -> MediaId? {
        if let m = media[id] { return m }
        guard let o = objects[id] else { return nil }
        let added: MediaId?
        switch o.kind {
        case .ole: return nil
        case .video(let path), .audio(let path):
            guard let raw = p.allocId() else { return nil }
            let name = Self.fileName(path)
            p.media.append(MediaItem(id: MediaId(raw), name: name, contentType: Self.contentType(name), data: [], link: Self.url(path)))
            added = MediaId(raw)
        case .embeddedSound(let sid):
            guard let s = sounds[sid], !s.data.isEmpty else { return nil }
            var ext = s.ext.lowercased()
            if ext.hasPrefix(".") { ext.removeFirst() }
            if ext.isEmpty { ext = "wav" }
            let name = (s.name.isEmpty ? "sound\(id)" : s.name) + "." + ext
            added = p.addMedia(name, Self.contentType(name), s.data)
        }
        if let added { media[id] = added }
        return added
    }

    /// A Windows or Mac path's last component.
    static func fileName(_ path: String) -> String {
        String(path.split(whereSeparator: { $0 == "\\" || $0 == "/" || $0 == ":" }).last ?? Substring(path))
    }

    /// A UNC or local path as a `file:` URL (a URL is kept as it is).
    static func url(_ path: String) -> String {
        if path.contains("://") { return path }
        let slashed = path.replacingOccurrences(of: "\\", with: "/")
        let encoded = slashed.addingPercentEncodingForURL()
        if slashed.hasPrefix("//") { return "file:" + encoded }
        return slashed.hasPrefix("/") ? "file://" + encoded : "file:///" + encoded
    }

    /// The media type of a file by its extension.
    static func contentType(_ name: String) -> String {
        let ext = name.split(separator: ".").last.map { $0.lowercased() } ?? ""
        return switch ext {
        case "wav": "audio/wav"
        case "mid", "midi", "rmi": "audio/midi"
        case "mp3": "audio/mpeg"
        case "wma": "audio/x-ms-wma"
        case "aif", "aiff": "audio/aiff"
        case "avi": "video/x-msvideo"
        case "wmv", "asf": "video/x-ms-wmv"
        case "mpg", "mpeg", "mpe": "video/mpeg"
        case "mov", "qt": "video/quicktime"
        case "mp4", "m4v": "video/mp4"
        default: "application/octet-stream"
        }
    }
}

extension String {
    /// Percent-encodes what a `file:` URL's path can't hold (spaces, `#`, `%`, `?` and non-ASCII), keeping `/` and
    /// the drive letter's `:`.
    func addingPercentEncodingForURL() -> String {
        var out = ""
        for byte in utf8 {
            let c = Character(Unicode.Scalar(byte))
            if byte < 0x80, c.isLetter || c.isNumber || "/:-._~!$&'()*+,;=@".contains(c) {
                out.append(c)
            } else {
                out += "%" + String(byte, radix: 16, uppercase: true).leftPad(2)
            }
        }
        return out
    }

    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}

extension Document {
    /// A slide's comments ([MS-PPT] 2.5.15 Comment10Container), in its PowerPoint 2002 binary tag: each one's author,
    /// initials, text, date and position.
    static func comments(_ b: [UInt8], _ slide: Record) -> [Comment] {
        guard let tags = slide.children(b).first(where: { $0.type == RT.progTags }) else { return [] }
        var out: [Comment] = []
        func walk(_ r: Record, _ depth: Int) {
            guard depth < 8 else { return }
            for c in r.children(b) {
                if c.type == RT.comment10 {
                    let kids = c.children(b)
                    func string(_ instance: UInt16) -> String {
                        kids.first { $0.type == RT.cString && $0.instance == instance }.map { unicode(b, $0.body) } ?? ""
                    }
                    var comment = Comment(author: string(0), initials: string(2), text: string(1))
                    if let atom = kids.first(where: { $0.type == RT.comment10Atom }), atom.body.count >= 28 {
                        // index, then a SYSTEMTIME (year, month, day of week, day, hour, minute, second, ms), then the
                        // anchor in master units.
                        let p = atom.body.lowerBound + 4
                        let t = (0 ..< 8).map { Int(le16(b, p + 2 * $0)) }
                        if (1601 ... 9999).contains(t[0]), (1 ... 12).contains(t[1]), (1 ... 31).contains(t[3]), t[4] < 24, t[5] < 60, t[6] < 61 {
                            func two(_ v: Int) -> String { v < 10 ? "0\(v)" : String(v) }
                            comment.date = "\(t[0])-\(two(t[1]))-\(two(t[3]))T\(two(t[4])):\(two(t[5])):\(two(t[6]))Z"
                        }
                        comment.x = Double(i32(b, p + 16)) * PPT.pointsPerMasterUnit
                        comment.y = Double(i32(b, p + 20)) * PPT.pointsPerMasterUnit
                    }
                    out.append(comment)
                } else if c.isContainer || c.type == RT.binaryTagDataBlob {
                    walk(c, depth + 1)
                }
            }
        }
        walk(tags, 0)
        return out
    }
}
