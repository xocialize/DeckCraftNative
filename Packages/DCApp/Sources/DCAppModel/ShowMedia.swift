// DCAppModel — media playback in the app: DCMedia's `Player` (the audio output and the clock video follows),
// video feeds, animated GIF clocks, and the engine's `media.*` requests, for the editor's canvas and the slide
// show alike. Port of `MediaHost` and the helpers of deckcraft `crates/ui-egui/src/media.rs` (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors). Textures are the window side's: this keeps the current
// decoded frame of each video and a counter that changes with it.
import DCCore
import DCEngine
import DCGeometry
import DCMedia
import DCModel
import DCRender
import Foundation

/// Who started a voice: the editor's media stops when you leave its slide; the show manages its own.
public enum MediaOwner: Sendable, Equatable {
    case editor, show
}

/// An animated GIF picture on a slide (`Gif`): its slide-space box, play time, frame and seconds to the next one.
public struct ShowGif: Equatable, Sendable {
    public var id: ShapeId
    public var rect: Xfrm
    public var t: Double
    public var frame: Int
    public var next: Double
    public var paused: Bool
}

/// The app's media playback (`MediaHost`).
@MainActor
public final class MediaHost {
    struct Video {
        var feed: VideoFeed?
        var frame: Frame?
        /// Changes whenever `frame` does (the window side uploads it then).
        var serial: UInt64 = 0
    }

    struct Owned {
        var owner: MediaOwner
        var clip: MediaClip
        /// The bytes the voice was started with.
        var source: [UInt8]
    }

    let player: Player
    /// The presentation the voices and GIF clocks belong to.
    private(set) var doc: UInt64?
    var owners: [ShapeId: Owned] = [:]
    var videos: [ShapeId: Video] = [:]
    /// Probed durations by media, with the bytes they were probed from (at most 16).
    var durations: [MediaId: (source: [UInt8], duration: Double)] = [:]
    /// Animated GIF clocks: when each started and, while paused, the time it holds.
    var gifClocks: [ShapeId: (Double, Double?)] = [:]
    private var serial: UInt64 = 0

    /// A host over `out` (nil: silent, clocked by `tick`; the app passes an `AudioEngineOutput`).
    public init(_ out: AudioOut? = nil) {
        player = Player(out)
    }

    /// Bind playback to the open presentation. nil stops every voice; switching to another document stops the
    /// previous one's voices and GIF clocks (`set_document`).
    public func setDocument(_ uid: UInt64?) {
        if doc == uid { return }
        if uid == nil || doc != nil {
            stopVoices()
            gifClocks.removeAll()
        }
        doc = uid
    }

    private func stopVoices() {
        player.stopAll()
        owners.removeAll()
        videos.removeAll()
    }

    /// The player's key for a shape.
    static func key(_ id: ShapeId) -> UInt64 { UInt64(id.rawValue) }

    /// The player's key for some media bytes: the media id and the bytes' length and ends (the player also checks
    /// the bytes themselves before reusing decoded audio).
    static func mediaKey(_ id: MediaId, _ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ v: UInt64) {
            h ^= v
            h = h &* 0x0000_0100_0000_01B3
        }
        mix(UInt64(id.rawValue))
        mix(UInt64(bytes.count))
        for b in bytes.prefix(64) { mix(UInt64(b)) }
        for b in bytes.suffix(64) { mix(UInt64(b)) }
        return h
    }

    /// The length of `bytes` in seconds, remembered (`duration_of`).
    func durationOf(_ id: MediaId, _ bytes: [UInt8]) -> Double {
        if let hit = durations[id], hit.source == bytes { return hit.duration }
        if durations.count >= 16, let k = durations.keys.first { durations[k] = nil }
        let d = (try? Media.probe(bytes))?.duration ?? 0
        durations[id] = (bytes, d)
        return d
    }

    /// The animated GIF pictures on slide `index` at `now` (`gifs`): each plays from when it was first shown; a
    /// paused one holds its time and resumes from it.
    public func gifs(_ docUid: UInt64, _ doc: Presentation, _ index: Int, _ now: Double, _ paused: Set<ShapeId>) -> [ShowGif] {
        setDocument(docUid)
        guard let slide = doc.slides.at(index) else { return [] }
        var pictures: [(Shape, Xfrm)] = []
        Self.collectPictures(slide.shapes, nil, 0, &pictures)
        var out: [ShowGif] = []
        for (sh, rect) in pictures {
            guard case .picture(let fill) = sh.kind, let item = doc.media(fill.media), item.data.starts(with: Array("GIF8".utf8)) else { continue }
            let p = paused.contains(sh.id)
            var c = gifClocks[sh.id] ?? (now, nil)
            if p && c.1 == nil {
                c.1 = now - c.0
            } else if !p, let held = c.1 {
                c.0 = now - held
                c.1 = nil
            }
            gifClocks[sh.id] = c
            let t = c.1 ?? now - c.0
            if let (frame, next) = Images.gifFrame(item.data, fill.adjust, t) {
                out.append(ShowGif(id: sh.id, rect: rect, t: t, frame: frame, next: next, paused: p))
            }
        }
        return out
    }

    /// Pictures in `shapes` and their groups, each with its slide-space box (`collect_pictures`).
    static func collectPictures(_ shapes: [Shape], _ group: (Xfrm, Xfrm)?, _ depth: Int, _ out: inout [(Shape, Xfrm)]) {
        if depth > 32 { return }
        for sh in shapes {
            guard let x0 = sh.xfrm else { continue }
            let x = group.map { ArrangeCommands.childToParent($0.0, $0.1, x0) } ?? x0
            switch sh.kind {
            case .picture: out.append((sh, x))
            case .group(let children, let child): collectPictures(children, (x, child), depth + 1, &out)
            default: break
            }
        }
    }

    public func status(_ id: ShapeId) -> VoiceStatus? { player.status(Self.key(id)) }

    /// Playing or loading (not paused or ended).
    public func isPlaying(_ id: ShapeId) -> Bool {
        guard let s = status(id) else { return false }
        return s.state == .playing || s.state == .loading
    }

    public func owner(_ id: ShapeId) -> MediaOwner? { owners[id]?.owner }

    /// The clip voice `id` was started with.
    public func clip(_ id: ShapeId) -> MediaClip? { owners[id]?.clip }

    /// Shapes with a voice (playing, paused or ended).
    public var ids: [ShapeId] { Array(owners.keys).sorted() }

    public var anyActive: Bool { !owners.isEmpty }

    /// Start (or resume) shape `id` of presentation `docUid` from `from` seconds (`play`).
    public func play(_ docUid: UInt64, _ doc: Presentation, _ id: ShapeId, _ clip: MediaClip, from: Double?, owner: MediaOwner) {
        setDocument(docUid)
        guard let item = doc.media(clip.media) else { return }
        let bytes = item.data
        let duration = clip.durationMs > 0 ? Double(clip.durationMs) / 1000 : durationOf(clip.media, bytes)
        let spec = VoiceSpec(
            clip: ClipParams.fromMs(clip.trimStartMs, clip.trimEndMs, clip.fadeInMs, clip.fadeOutMs, clip.volume),
            looping: clip.loopPlay, duration: duration, audio: clip.volume > 0
        )
        let sourceChanged = owners[id].map { $0.source != bytes } ?? false
        if clip.video && (sourceChanged || videos[id] == nil) {
            // A codec without a decoder (VP8/VP9 with none registered) opens no feed: the clip's audio still
            // plays and the shape shows its "can't play" state.
            let feed = try? VideoFeed(bytes)
            videos[id] = Video(feed: feed, frame: nil)
        } else if !clip.video {
            videos[id] = nil
        }
        player.play(Self.key(id), mediaKey: Self.mediaKey(clip.media, bytes), bytes: bytes, spec: spec, from: from)
        owners[id] = Owned(owner: owner, clip: clip, source: bytes)
    }

    public func pause(_ id: ShapeId) { player.pause(Self.key(id)) }

    func sameSource(_ doc: Presentation, _ id: ShapeId, _ clip: MediaClip) -> Bool {
        guard let item = doc.media(clip.media), let o = owners[id] else { return false }
        return o.source == item.data
    }

    public func toggle(_ docUid: UInt64, _ doc: Presentation, _ id: ShapeId, _ clip: MediaClip, owner: MediaOwner) {
        setDocument(docUid)
        if isPlaying(id) && sameSource(doc, id, clip) { pause(id) } else { play(docUid, doc, id, clip, from: nil, owner: owner) }
    }

    public func stop(_ id: ShapeId) {
        player.stop(Self.key(id))
        owners[id] = nil
        videos[id] = nil
    }

    public func stopOwned(_ owner: MediaOwner) {
        for (id, o) in owners where o.owner == owner { stop(id) }
    }

    /// Move to `t` seconds; a shape that isn't playing, or whose clip changed, is cued there, paused (`seek`).
    public func seek(_ docUid: UInt64, _ doc: Presentation, _ id: ShapeId, _ clip: MediaClip, _ t: Double, owner: MediaOwner) {
        setDocument(docUid)
        if status(id) == nil || !sameSource(doc, id, clip) {
            play(docUid, doc, id, clip, from: t, owner: owner)
            pause(id)
        }
        player.seek(Self.key(id), t)
    }

    /// Whether video `id` opened a feed (false: a codec this Mac can't decode).
    public func hasVideoFeed(_ id: ShapeId) -> Bool { videos[id]?.feed != nil }

    /// Whether `id` is a video whose picture can't be shown (the "can't play" state).
    public func videoUnplayable(_ id: ShapeId) -> Bool { videos[id].map { $0.feed == nil } ?? false }

    /// The current decoded frame of video `id` and its serial.
    public func frame(_ id: ShapeId) -> (frame: Frame, serial: UInt64)? {
        guard let v = videos[id], let f = v.frame else { return nil }
        return (f, v.serial)
    }

    /// Run the media clocks, rewind clips set to, and report state to the engine (`tick_clock`). Returns whether
    /// anything plays.
    @discardableResult
    public func tickClock(_ now: Double, _ session: Session) -> Bool {
        player.tick(now)
        // Rewind after playing: back to the poster.
        for (id, o) in owners where o.clip.rewind && status(id)?.state == .ended { stop(id) }
        var statuses: [ShapeId: MediaStatus] = [:]
        for id in owners.keys {
            guard let s = status(id) else { continue }
            var m = MediaStatus()
            m.state = s.state.name
            m.positionMs = UInt64(rustCast: (Swift.max(s.position, 0) * 1000).rounded())
            m.durationMs = UInt64(rustCast: (Swift.max(s.duration, 0) * 1000).rounded())
            m.error = s.error ?? (videoUnplayable(id) ? L10n.text("this video's codec can't be played on this Mac; only its sound plays") : nil)
            statuses[id] = m
        }
        session.mediaStatus = statuses
        return owners.keys.contains { isPlaying($0) }
    }

    /// Bring each video's frame up to its voice's position (`sync_video_textures`, without the upload). Returns
    /// whether a frame changed.
    @discardableResult
    public func syncVideoFrames() -> Bool {
        var changed = false
        for (id, var v) in videos {
            guard let st = status(id), let feed = v.feed, let f = feed.frameAt(st.position) else { continue }
            if v.frame != nil && v.frame?.time == f.time && v.frame?.width == f.width { continue }
            v.frame = f
            serial &+= 1
            v.serial = serial
            videos[id] = v
            changed = true
        }
        return changed
    }

    /// Carry out a `media.*` request for presentation `docUid` (`request`); `slide` is the slide it comes from,
    /// as shape ids are unique only per slide.
    public func request(_ docUid: UInt64, _ doc: Presentation, _ slide: Int, _ action: String, _ id: ShapeId, _ ms: UInt64?, owner: MediaOwner) {
        setDocument(docUid)
        guard let clip = Self.findClip(doc, id, near: slide) else { return }
        let t = ms.map { Double($0) / 1000 }
        switch action {
        case "play": play(docUid, doc, id, clip, from: t, owner: owner)
        case "pause": pause(id)
        case "toggle": toggle(docUid, doc, id, clip, owner: owner)
        case "stop": stop(id)
        case "seek": seek(docUid, doc, id, clip, t ?? 0, owner: owner)
        default: break
        }
    }

    // MARK: Clips on slides

    /// The clip of media shape `id`: on slide `near` first, then anywhere in the deck (`find_clip`).
    public nonisolated static func findClip(_ doc: Presentation, _ id: ShapeId, near: Int?) -> MediaClip? {
        if let i = near, let c = clipOn(doc, i, id) { return c }
        for s in doc.slides { if let c = walkClip(s.shapes, id, 0) { return c } }
        return nil
    }

    /// The clip `id` on slide `index` only, in groups too (`clip_on`).
    public nonisolated static func clipOn(_ doc: Presentation, _ index: Int, _ id: ShapeId) -> MediaClip? {
        doc.slides.at(index).flatMap { walkClip($0.shapes, id, 0) }
    }

    nonisolated static func walkClip(_ shapes: [Shape], _ id: ShapeId, _ depth: Int) -> MediaClip? {
        if depth > 32 { return nil }
        for s in shapes {
            switch s.kind {
            case .media(let m) where s.id == id: return m
            case .group(let children, _): if let c = walkClip(children, id, depth + 1) { return c }
            default: break
            }
        }
        return nil
    }

    /// Whether a voice playing `clip` keeps playing on slide `to`: it plays across slides and `to` doesn't hold
    /// another clip under the same id (`carries_over`).
    public nonisolated static func carriesOver(_ clip: MediaClip, _ doc: Presentation, _ id: ShapeId, _ to: Int) -> Bool {
        clip.playAcrossSlides && (clipOn(doc, to, id).map { $0.media == clip.media } ?? true)
    }

    /// Media shapes directly on slide `index`: id, box in slide points, clip (`slide_media`).
    public nonisolated static func slideMedia(_ doc: Presentation, _ index: Int) -> [(id: ShapeId, xfrm: Xfrm, clip: MediaClip)] {
        guard let s = doc.slides.at(index) else { return [] }
        return s.shapes.compactMap { sh in
            guard case .media(let m) = sh.kind, let x = sh.xfrm else { return nil }
            return (sh.id, x, m)
        }
    }

    /// "01:05.25" (`clock`).
    public nonisolated static func clock(_ secs: Double) -> String {
        let s = secs.isFinite ? Swift.max(secs, 0) : 0
        return String(format: "%02d:%05.2f", Int(rustCast: (s / 60).rounded(.towardZero)), s.truncatingRemainder(dividingBy: 60))
    }

    /// Changes whenever a GIF shows another frame (`gif_key`).
    public nonisolated static func gifKey(_ gifs: [ShowGif]) -> UInt64 {
        gifs.reduce(0) { h, g in (h ^ ((UInt64(g.id.rawValue) << 32) | UInt64(truncatingIfNeeded: g.frame))) &* 1_099_511_628_211 }
    }
}
