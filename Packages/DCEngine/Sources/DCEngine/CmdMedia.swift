// DCEngine — the `media` command module: media playback (Playback tab, the media control bar, agents).
// Play / pause / stop / seek are requests the UI host carries out with its player (`UiRequest.media`); the
// host reports back through `Session.mediaStatus`, which `media.info` returns with the probe.
// Port of deckcraft crates/engine/src/cmd/media.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCMedia
import DCModel
import DCRender

public enum MediaCommands {
    public static func specs() -> [CommandSpec] {
        [
            .noundo("media.play", "Play", ["Playback", "Preview"], "Alt+P", "{id?, from?: ms}", Cmd.hasDoc, play),
            .noundo("media.pause", "Pause", ["Playback", "Preview"], nil, "{id?}", Cmd.hasDoc, pause),
            .noundo("media.toggle", "Play/Pause", [], nil, "{id?}", Cmd.hasDoc, toggle),
            .noundo("media.stop", "Stop", ["Playback", "Preview"], nil, "{id?}", Cmd.hasDoc, stop),
            .noundo("media.seek", "Seek", [], nil, "{id?, ms}", Cmd.hasDoc, seek),
            .query(
                "media.info",
                "Media Info",
                [],
                nil,
                "{id?} → {id, name, contentType, bytes, durationMs, video, width, height, probe: {container, audio?, video?}, options, status?}",
                Cmd.hasDoc,
                info
            ),
            .cmd(
                "media.posterFrame",
                "Poster Frame",
                ["Video Format", "Adjust"],
                nil,
                "{id?, ms?: frame time (default: current position)}",
                Cmd.hasDoc,
                posterFrame
            ),
            .noundo("media.gifPlay", "Play/Pause GIF", [], nil, "{id?, play?: bool (default: toggle)} → {id, playing}", Cmd.hasDoc, gifPlay),
        ]
    }

    /// The media shape a command acts on: `id` / `ids` / the selection, else the only media shape on the
    /// current slide.
    static func target(_ s: Session, _ p: JSON, _ cmd: String) throws -> (ShapeId, MediaClip) {
        let st = try s.doc()
        func mediaOf(_ id: ShapeId) -> (ShapeId, MediaClip)? {
            guard let sh = st.shape(id), case .media(let m) = sh.kind else { return nil }
            return (id, m)
        }
        let ids = try Cmd.targets(s, p)
        if let found = ids.lazy.compactMap(mediaOf).first { return found }
        if !ids.isEmpty && (p.get("id") != nil || p.get("ids") != nil) { throw Cmd.bad(cmd, "not a media shape") }
        let all = st.shapes.compactMap { mediaOf($0.id) }
        switch all.count {
        case 1: return all[0]
        case 0: throw Cmd.bad(cmd, "no audio or video on this slide")
        default: throw Cmd.bad(cmd, "select an audio or video, or pass `id`")
        }
    }

    static func request(_ s: Session, _ p: JSON, _ cmd: String, _ action: String, _ ms: UInt64?) throws -> JSON {
        let (shape, _) = try target(s, p, cmd)
        s.uiRequests.append(.media(action: action, shape: shape, ms: ms))
        return ["id": shape.toJSON()]
    }

    static func msParam(_ p: JSON, _ key: String) -> UInt64? {
        guard let v = p.get(key)?.asF64, v.isFinite, v >= 0.0 else { return nil }
        return UInt64(rustCast: v)
    }

    @Sendable static func play(_ s: Session, _ p: JSON) throws -> JSON { try request(s, p, "media.play", "play", msParam(p, "from")) }
    @Sendable static func pause(_ s: Session, _ p: JSON) throws -> JSON { try request(s, p, "media.pause", "pause", nil) }
    @Sendable static func toggle(_ s: Session, _ p: JSON) throws -> JSON { try request(s, p, "media.toggle", "toggle", nil) }
    @Sendable static func stop(_ s: Session, _ p: JSON) throws -> JSON { try request(s, p, "media.stop", "stop", nil) }

    @Sendable static func seek(_ s: Session, _ p: JSON) throws -> JSON {
        guard let ms = msParam(p, "ms") else { throw Cmd.bad("media.seek", "missing `ms`") }
        return try request(s, p, "media.seek", "seek", ms)
    }

    /// A probe as `media.info` and `insert.audio`/`insert.video` answer it (`probe_json`).
    public static func probeJSON(_ info: MediaInfo) -> JSON {
        let audio: JSON = info.audio.map { a in
            ["codec": .string(a.codec), "sampleRate": .uint(UInt64(a.sampleRate)), "channels": .uint(UInt64(a.channels)), "decodable": .bool(a.decodable)]
        } ?? .null
        let video: JSON = info.video.map { v in
            [
                "codec": .string(v.codec), "width": .uint(UInt64(v.width)), "height": .uint(UInt64(v.height)),
                "fps": .num((v.fps * 1000.0).rounded() / 1000.0), "frames": .uint(v.frames), "decodable": .bool(v.decodable),
            ]
        } ?? .null
        return [
            "container": .string(info.container),
            "durationMs": .uint(info.durationMs),
            "playable": .bool(info.playable),
            "audio": audio,
            "video": video,
        ]
    }

    static func statusJSON(_ st: MediaStatus) -> JSON {
        ["state": .string(st.state), "positionMs": .uint(st.positionMs), "durationMs": .uint(st.durationMs), "error": .opt(st.error)]
    }

    @Sendable static func info(_ s: Session, _ p: JSON) throws -> JSON {
        let (id, m) = try target(s, p, "media.info")
        let st = try s.doc()
        guard let item = st.doc.media(m.media) else { throw EngineError.other("the media data is missing") }
        let probe: JSON
        do {
            probe = probeJSON(try Media.probe(item.data))
        } catch {
            probe = ["error": .string(error.description)]
        }
        return [
            "id": id.toJSON(),
            "name": .string(item.name),
            "contentType": .string(item.contentType),
            "bytes": .integer(item.data.count),
            "video": .bool(m.video),
            "durationMs": .uint(UInt64(m.durationMs)),
            "width": .uint(UInt64(m.width)),
            "height": .uint(UInt64(m.height)),
            "poster": .bool(m.poster != nil),
            "probe": probe,
            "options": [
                "autoplay": .bool(m.autoplay), "loop": .bool(m.loopPlay), "rewind": .bool(m.rewind), "acrossSlides": .bool(m.playAcrossSlides),
                "hide": .bool(m.hideWhileNotPlaying), "fullScreen": .bool(m.fullScreen), "volume": .num(m.volume),
                "trimStart": .uint(UInt64(m.trimStartMs)), "trimEnd": .uint(UInt64(m.trimEndMs)), "fadeIn": .uint(UInt64(m.fadeInMs)),
                "fadeOut": .uint(UInt64(m.fadeOutMs)),
            ],
            "status": s.mediaStatus[id].map(statusJSON) ?? .null,
        ]
    }

    /// A poster frame PNG for video bytes at `ms` (`poster_png`). The PNG comes from AVFoundation and
    /// ImageIO, so its bytes differ from deckcraft's.
    public static func posterPNG(_ bytes: [UInt8], _ ms: UInt64) -> [UInt8]? {
        try? Media.posterPNG(bytes, Double(ms) / 1000.0)
    }

    @Sendable static func posterFrame(_ s: Session, _ p: JSON) throws -> JSON {
        let (id, m) = try target(s, p, "media.posterFrame")
        if !m.video { throw Cmd.bad("media.posterFrame", "only videos have poster frames") }
        let ms = msParam(p, "ms") ?? s.mediaStatus[id]?.positionMs ?? 0
        guard let data = try s.doc().doc.media(m.media)?.data else { throw EngineError.other("the media data is missing") }
        guard let png = posterPNG(data, ms) else { throw EngineError.other("no frame could be decoded there") }
        let name = "poster\(id).png"
        let poster = try s.edit { doc, _ in
            guard let pm = doc.addMedia(name, "image/png", png) else { throw Cmd.bad("media.posterFrame", Cmd.noIdSpace) }
            return pm
        }
        _ = try Cmd.editShapes(s, ["id": id.toJSON()], "media.posterFrame") { sh in
            if case .media(var mc) = sh.kind {
                mc.poster = poster
                sh.kind = .media(mc)
            }
        }
        return ["id": id.toJSON(), "ms": .uint(ms)]
    }

    /// Pause or play an animated GIF picture (`id` / `ids` / the selection, else the only one on the
    /// slide). The UI host keeps its clock: a paused GIF holds its frame and resumes from it.
    @Sendable static func gifPlay(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "media.gifPlay"
        let st = try s.doc()
        func isGif(_ id: ShapeId) -> Bool {
            guard let sh = st.shape(id), case .picture(let fill) = sh.kind, let m = st.doc.media(fill.media) else { return false }
            return Images.gifFrame(m.data, fill.adjust, 0.0) != nil
        }
        let ids = try Cmd.targets(s, p)
        let id: ShapeId
        if let found = ids.first(where: isGif) {
            id = found
        } else if !ids.isEmpty && (p.get("id") != nil || p.get("ids") != nil) {
            throw Cmd.bad(cmd, "not an animated GIF")
        } else {
            let gifs = st.shapes.map(\.id).filter(isGif)
            switch gifs.count {
            case 1: id = gifs[0]
            case 0: throw Cmd.bad(cmd, "no animated GIF on this slide")
            default: throw Cmd.bad(cmd, "select an animated GIF, or pass `id`")
            }
        }
        let play = Cmd.boolParam(p, "play") ?? s.gifPaused.contains(id)
        if play { s.gifPaused.remove(id) } else { s.gifPaused.insert(id) }
        return ["id": id.toJSON(), "playing": .bool(play)]
    }
}
