// DCAppModel — the app's side of the slide show without a window: starting and ending shows (Play from Start,
// from the current slide, a custom show, Reading View, the engine's `startShow` request), the canvas animation
// preview, the show's media (auto-play, carry-over, transition sounds, the steps' media cues), the engine's
// `media.*` requests, and what a click, a wheel or a key on the show does. Ports `start_show`,
// `start_custom_show`, `show_from`, `show_start_index`, the animation preview, `drain_requests`' show and media
// arms and `tick_media_clock` of deckcraft `crates/ui-egui/src/lib.rs`, and `show_media`, `run_media_cues` and
// the input half of `ui` in `show.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import CoreGraphics
import DCAnim
import DCCore
import DCEngine
import DCGeometry
import DCMedia
import DCModel
import DCRender
import Foundation

/// The canvas animation preview's playhead (`AnimPreview`).
public struct AnimPreview {
    public var uid: UInt64
    public var slide: Int
    /// The slide when the preview started: an edit stops playback.
    public var slideValue: Slide
    /// The monotonic time the first frame latched (nil until then).
    public var started: Double?
    /// Where on the play-everything clock playback began (Play From the selected effect).
    public var from: Double
    public var elapsed: Double
    public var timeline: Timeline
}

/// The pointer's look over the show.
public enum ShowCursorKind: Equatable, Sendable {
    case arrow, crosshair, hidden, pointingHand
}

/// What an input on the show asks of its window.
public struct ShowOutcome: Equatable, Sendable {
    /// False: end the show.
    public var keep = true
    /// A link to open outside the show.
    public var openURL: String?
    /// The show changed: redraw.
    public var redraw = false
    public init(keep: Bool = true, openURL: String? = nil, redraw: Bool = false) {
        self.keep = keep
        self.openURL = openURL
        self.redraw = redraw
    }
}

@MainActor
public final class ShowCoordinator {
    public let model: AppModel
    public let media: MediaHost
    /// The running show (`SlideApp::show`).
    public private(set) var show: ShowController?
    /// The presentation the show plays (`DocState.uid`).
    public private(set) var showDoc: UInt64?
    public private(set) var animPreview: AnimPreview?
    private var showInstance: UInt64 = 0
    /// The voice id of slide transition sounds (no shape has it).
    public static let transitionSound = ShapeId(UInt32.max)
    /// How long the preview holds the last frame (`preview::HOLD_SECS`).
    public static let previewHold = 0.45

    /// Called after a show starts or ends, so the window side opens or closes its windows.
    public var onShowStarted: (@MainActor (ShowController) -> Void)?
    public var onShowEnded: (@MainActor () -> Void)?
    /// Called when the animation preview starts or stops.
    public var onPreviewChanged: (@MainActor () -> Void)?

    public init(model: AppModel, media: MediaHost = MediaHost()) {
        self.model = model
        self.media = media
    }

    /// A monotonic clock in seconds (deckcraft's `monotonic_secs`).
    public static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    var session: Session { model.session }

    /// The show's document: the one it started on while it is open, else the active one.
    public var showState: DocState? {
        // A show whose presentation was closed has nothing to play: its next tick ends it.
        if let uid = showDoc { return session.documents.first { $0.uid == uid } }
        return session.activeDoc
    }

    // MARK: Starting and ending

    /// The first slide Play from Start opens: the custom show or range, skipping hidden slides.
    public var showStartIndex: Int { session.activeDoc.flatMap { showOrder($0.doc).first } ?? 0 }

    /// The slide `show.start {from}` names: nil when absent; an error when it is not a slide of the open deck
    /// (`show_from`).
    public func showFrom(_ p: JSON) -> Result<Int?, CommandError> {
        guard let v = p["from"], v != .null else { return .success(nil) }
        guard let i = v.asU64, let from = Int(exactly: i) else { return .failure(CommandError("`from` is not a valid index: \(v)")) }
        let count = session.activeDoc?.doc.slides.count ?? 0
        if from >= count { return .failure(CommandError("no slide \(from)")) }
        return .success(from)
    }

    /// Leave the animation preview, stop the editor's media and start a show at `from` (`start_show`).
    public func startShow(from: Int, reading: Bool, preview: Bool = false, rehearse: Bool = false) {
        stopAnimPreview()
        media.stopOwned(.editor)
        guard let d = session.activeDoc else { return }
        if show != nil { endShow(record: false) }
        showInstance = Swift.max(showInstance &+ 1, 1)
        let s = ShowController(d.doc, from: from, reading: reading, presenter: model.ui.presenterView && !reading)
        s.instance = showInstance
        s.previewOnly = preview
        s.rehearse = rehearse
        show = s
        showDoc = d.uid
        onShowStarted?(s)
    }

    /// Play custom show `name` from its first slide (`start_custom_show`).
    public func startCustomShow(_ name: String, reading: Bool) {
        guard let d = session.activeDoc, let state = ShowState.playCustom(d.doc, name) else { return }
        startShow(from: state.slide, reading: reading)
        show?.state = state
    }

    /// End the show: stop its media, keep rehearsed timings, and leave the editor on the last slide shown.
    public func endShow(record: Bool = true) {
        guard let s = show else { return }
        let uid = showDoc
        show = nil
        showDoc = nil
        media.stopOwned(.show)
        if record {
            if s.rehearse {
                for (i, secs) in s.closeTimings(Self.now()) {
                    let ms = UInt64(rustCast: (secs * 1000).rounded())
                    _ = try? session.execute("transition.timing", ["index": .integer(i), "after": .integer(Int(clamping: ms))])
                }
                model.status = "Slide timings recorded."
            }
            if session.activeDoc?.uid == uid {
                _ = try? session.execute("slide.go", ["index": .integer(s.state.slide)])
            }
        }
        onShowEnded?()
        model.changed()
    }

    /// The UI commands of the show (`run_ui`'s arms): nil for any other id.
    public func command(_ id: String, _ p: JSON) -> Result<JSON, CommandError>? {
        switch id {
        case "show.start":
            let reading = p["reading"]?.asBool ?? false
            if let name = p["custom"]?.asStr, !name.isEmpty {
                startCustomShow(name, reading: reading)
            } else {
                switch showFrom(p) {
                case .failure(let e): return .failure(e)
                case .success(let from):
                    let rehearse = p["rehearse"]?.asBool ?? false
                    let preview = p["preview"]?.asBool ?? false
                    let current = session.activeDoc?.selection.slide ?? 0
                    startShow(from: from ?? (preview ? current : showStartIndex), reading: reading || preview, preview: preview, rehearse: rehearse)
                }
            }
            return .success(.null)
        case "view.reading":
            startShow(from: session.activeDoc?.selection.slide ?? 0, reading: true)
            return .success(.null)
        case "show.end":
            endShow()
            return .success(.null)
        case "animation.preview":
            if p["on"]?.asBool == false {
                stopAnimPreview()
                return .success(["playing": false])
            }
            var from: Int?
            if let v = p["from"], v != .null {
                guard let n = v.asU64 else { return .failure("`from` must be an effect index") }
                from = Int(exactly: n) ?? Int.max
            }
            return startAnimPreview(from)
        default:
            return nil
        }
    }

    /// The engine's requests the show and media take (`drain_requests`); false for the others.
    public func request(_ r: UiRequest) -> Bool {
        switch r {
        case .startShow(let from):
            startShow(from: from, reading: false)
            return true
        case .media(let action, let shape, let ms):
            let owner: MediaOwner = show != nil ? .show : .editor
            // The command resolved `shape` on the editor's slide, also while a show runs.
            if let d = session.activeDoc {
                media.request(d.uid, d.doc, d.selection.slide, action, shape, ms, owner: owner)
            }
            return true
        default:
            return false
        }
    }

    // MARK: Media

    /// Media clocks: closing the last presentation or switching decks stops the voices; the editor's media stops
    /// when its slide is left (`tick_media_clock`). Returns whether anything plays.
    @discardableResult
    public func tickMedia(_ now: Double) -> Bool {
        media.setDocument(show != nil ? showDoc : session.activeDoc?.uid)
        if !media.anyActive {
            session.mediaStatus.removeAll()
            return false
        }
        if show == nil, let d = session.activeDoc {
            let here = d.selection.target == .slides ? MediaHost.slideMedia(d.doc, d.selection.slide).map(\.id) : []
            for id in media.ids where !here.contains(id) && media.owner(id) == .editor { media.stop(id) }
        }
        return media.tickClock(now, session)
    }

    /// Start the media of a newly shown slide (`show_media`): media from the previous slide stops unless it plays
    /// across slides; the slide's transition sound and auto-play media start; everything stops at the end.
    public func showMedia() {
        guard let s = show, let d = showState else { return }
        let doc = d.doc
        let cur: Int? = s.ended ? nil : s.state.slide
        if s.mediaSlide == cur { return }
        s.mediaSlide = cur
        let trans = cur.flatMap { doc.slides.at($0) }?.transition
        let sound = trans?.sound
        let soundLoop = trans?.soundLoop ?? false
        // [Stop Previous Sound] ends a transition sound still playing.
        let stopPrevious = trans?.stopSound ?? false
        var keep: [ShapeId] = []
        if let i = cur {
            keep = media.ids.filter { id in media.clip(id).map { MediaHost.carriesOver($0, doc, id, i) } ?? false }
            // A transition sound plays to its end, as in PowerPoint, unless the new slide has its own.
            if sound == nil && !stopPrevious && media.isPlaying(Self.transitionSound) { keep.append(Self.transitionSound) }
        }
        for id in media.ids where !keep.contains(id) { media.stop(id) }
        if let m = sound {
            // Loop Until Next Sound: it repeats until another slide's sound or Stop Previous Sound.
            let clip = MediaClip(media: m, volume: 1, loopPlay: soundLoop)
            media.play(d.uid, doc, Self.transitionSound, clip, from: nil, owner: .show)
        }
        if let i = cur {
            for m in MediaHost.slideMedia(doc, i) where m.clip.autoplay && !keep.contains(m.id) {
                media.play(d.uid, doc, m.id, m.clip, from: nil, owner: .show)
            }
        }
    }

    /// Carry out the media effects the steps set off (`run_media_cues`): Play starts from the beginning unless the
    /// clip is playing, Pause toggles, Stop stops.
    public func runMediaCues() {
        guard let s = show, let d = showState else { return }
        let cues = s.mediaCues
        s.mediaCues.removeAll()
        for (id, effect) in cues {
            guard let clip = MediaHost.findClip(d.doc, id, near: s.state.slide) else { continue }
            switch effect {
            case "pause": media.toggle(d.uid, d.doc, id, clip, owner: .show)
            case "stop": media.stop(id)
            default:
                if !media.isPlaying(id) { media.play(d.uid, d.doc, id, clip, from: 0, owner: .show) }
            }
        }
    }

    /// Media of the shown slide hidden now: set to hide while not playing and not playing (or ended).
    public func hiddenMedia(_ doc: Presentation, _ idx: Int) -> [ShapeId] {
        MediaHost.slideMedia(doc, idx).filter { m in
            m.clip.hideWhileNotPlaying && !(media.status(m.id).map { $0.state != .ended } ?? false)
        }.map(\.id)
    }

    // MARK: One frame of logic

    /// The show's clock at `now` (`advance_hidden` plus the media): steps, auto-advance, triggers and media.
    /// False when the show should close.
    public func tick(_ now: Double) -> Bool {
        guard let s = show, let d = showState else { return false }
        if !s.started { s.begin(d.doc, now) }
        // Edits from elsewhere (a script, the control channel) can remove slides under the show.
        if !s.ended && s.state.slide >= d.doc.slides.count { s.ended = true }
        let keep = s.advance(d.doc, now)
        showMedia()
        runMediaCues()
        tickMedia(now)
        return keep
    }

    /// Apply a key; false when the show should close.
    public func key(_ k: ShowKey, _ m: ShowMods, presenter: Bool, now: Double) -> (handled: Bool, keep: Bool) {
        guard let s = show, let d = showState else { return (false, true) }
        let r = s.key(k, m, d.doc, now, presenter: presenter)
        showMedia()
        return r
    }

    /// A navigation answer from a button (Previous, Next): false when the show should close.
    public func navigate(_ forward: Bool, now: Double) -> Bool {
        guard let s = show, let d = showState else { return false }
        if forward && s.ended { return false }
        if !forward { s.ended = false }
        let a = forward ? s.state.next(d.doc) : s.state.prev(d.doc)
        let keep = s.apply(a, d.doc, now)
        showMedia()
        return keep
    }

    /// Go to slide `i` (See All Slides, `show.goto`).
    public func goto(_ i: Int, now: Double) {
        guard let s = show, let d = showState, d.doc.slides.indices.contains(i) else { return }
        s.grid = false
        s.presenterGrid = false
        s.blank = nil
        s.zoom = nil
        s.zoomArm = false
        s.apply(s.state.goto(d.doc, i), d.doc, now)
        showMedia()
    }

    // MARK: Pointer

    /// Whether `p` is on the on-screen controls (the reading bar or the toolbar), so a click there doesn't also
    /// advance (`reading_bar_hit`).
    public func controlsHit(_ p: CGPoint, _ full: CGRect) -> Bool {
        guard let s = show else { return false }
        if s.reading { return p.y > full.maxY - ShowGeometry.readingBarHeight }
        return ShowGeometry.contains(ShowGeometry.toolBarRect(full).insetBy(dx: -8, dy: -8), p)
    }

    /// The clip whose bar or shape is under `p`, with its bar, when Show Media Controls is on (`media_bar_target`).
    public func mediaBarTarget(_ p: CGPoint, _ full: CGRect) -> (id: ShapeId, clip: MediaClip, bar: CGRect)? {
        guard let s = show, let d = showState, d.doc.show.showMediaControls, !s.pen, !s.ended, s.blank == nil else { return nil }
        let items = ShowGeometry.slideMediaBars(ShowGeometry.slideRect(full, reading: s.reading, d.doc), d.doc, s.state.slide)
        if let m = items.last(where: { ShowGeometry.contains($0.bar, p) }) { return (m.id, m.clip, m.bar) }
        if let m = items.last(where: { ShowGeometry.contains($0.rect, p) }) { return (m.id, m.clip, m.bar) }
        return nil
    }

    /// True when `p` is on a visible playback bar (`pointer_on_media_bar`).
    public func pointerOnMediaBar(_ p: CGPoint, _ full: CGRect, _ now: Double) -> Bool {
        guard let s = show, let d = showState, d.doc.show.showMediaControls, s.pointerAwake(now), !s.pen, !s.ended, s.blank == nil else {
            return false
        }
        let srect = ShowGeometry.slideRect(full, reading: s.reading, d.doc)
        return ShowGeometry.slideMediaBars(srect, d.doc, s.state.slide).contains { ShowGeometry.contains($0.bar, p) }
    }

    /// Whether a click at `p` lands on the slide itself (not a mode, a control or a media bar).
    func onSlide(_ p: CGPoint, _ full: CGRect, _ now: Double) -> Bool {
        guard let s = show else { return false }
        return !s.grid && !s.pen && !s.laser && !s.ended && s.blank == nil && s.zoom == nil && !s.zoomArm && !controlsHit(p, full)
            && !pointerOnMediaBar(p, full, now)
    }

    /// The GIF whose play/pause button is under `p` (`gif_hit`).
    func gifHit(_ p: CGPoint, _ full: CGRect, _ now: Double) -> ShapeId? {
        guard let s = show, let d = showState else { return nil }
        let srect = ShowGeometry.slideRect(full, reading: s.reading, d.doc)
        let k = srect.width / Swift.max(d.doc.slideSize.width, 1)
        let gifs = media.gifs(d.uid, d.doc, s.state.slide, now, session.gifPaused)
        return gifs.last { ShowGeometry.contains(ShowGeometry.gifButtonRect(ShowGeometry.onScreen(srect, k, $0.rect)), p) }?.id
    }

    /// The media shape under `p` (`media_hit`).
    func mediaHit(_ p: CGPoint, _ full: CGRect) -> (ShapeId, MediaClip)? {
        guard let s = show, let d = showState else { return nil }
        let srect = ShowGeometry.slideRect(full, reading: s.reading, d.doc)
        let k = srect.width / Swift.max(d.doc.slideSize.width, 1)
        return MediaHost.slideMedia(d.doc, s.state.slide).last { ShowGeometry.contains(ShowGeometry.onScreen(srect, k, $0.xfrm), p) }.map { ($0.id, $0.clip) }
    }

    /// What is under `p` on the shown slide.
    public func under(_ p: CGPoint, _ full: CGRect, _ now: Double) -> ShowUnder? {
        guard let s = show, let d = showState else { return nil }
        let srect = ShowGeometry.slideRect(full, reading: s.reading, d.doc)
        let k = srect.width / Swift.max(d.doc.slideSize.width, 1)
        guard k > 0, k.isFinite else { return nil }
        return s.under(d.doc, (p.x - srect.minX) / k, (p.y - srect.minY) / k, now)
    }

    /// Whether the pointer at `p` would act on something (the pointing hand).
    public func pointing(_ p: CGPoint, _ full: CGRect, _ now: Double) -> Bool {
        onSlide(p, full, now) ? under(p, full, now)?.pick != nil : false
    }

    /// The pointer the show wants at `p`: a crosshair for the pen, a zoom being armed and See All Slides; none
    /// for the laser and an idle pointer (#968: idle wins over a clickable shape); a hand over a link or trigger.
    public func cursor(_ p: CGPoint?, _ full: CGRect, _ now: Double) -> ShowCursorKind {
        guard let s = show else { return .arrow }
        if s.pen || s.zoomArm || s.grid { return .crosshair }
        if s.laser || (!s.pointerAwake(now) && !s.reading) { return .hidden }
        if let p, pointing(p, full, now) { return .pointingHand }
        return .arrow
    }

    /// A primary click at `p` in a window of `full` (the click half of `show::ui`).
    public func click(_ p: CGPoint, _ full: CGRect, _ now: Double) -> ShowOutcome {
        guard let s = show, let d = showState else { return ShowOutcome(keep: false) }
        let doc = d.doc
        var out = ShowOutcome(redraw: true)
        // The media bar's own buttons and timeline.
        if pointerOnMediaBar(p, full, now), let (id, clip, bar) = mediaBarTarget(p, full) {
            let st = media.status(id)
            let duration = st.map(\.duration).flatMap { $0 > 0 ? $0 : nil } ?? Double(clip.durationMs) / 1000
            switch ShowGeometry.mediaBarAction(bar, p, duration: duration) {
            case .toggle: media.toggle(d.uid, doc, id, clip, owner: .show)
            case .seek(let t): media.seek(d.uid, doc, id, clip, t, owner: .show)
            case .nudge(let dt): media.seek(d.uid, doc, id, clip, Swift.max((st?.position ?? 0) + dt, 0), owner: .show)
            case nil: break
            }
            return out
        }
        let slideHit = onSlide(p, full, now)
        let gif = slideHit && doc.show.showMediaControls && s.pointerAwake(now) ? gifHit(p, full, now) : nil
        let mediaClick = slideHit && gif == nil ? mediaHit(p, full) : nil
        let under = slideHit && gif == nil && mediaClick == nil ? under(p, full, now) : nil
        var actions: [ShowAction] = []
        if let id = gif {
            _ = try? session.execute("media.gifPlay", ["id": .integer(Int(id.rawValue))])
        } else if let (id, clip) = mediaClick {
            media.toggle(d.uid, doc, id, clip, owner: .show)
        } else if case .text(let l)? = under?.pick {
            switch s.state.followLink(doc, l, s.lastViewed) {
            case .show(let a): actions.append(a)
            case .open(let url): out.openURL = url
            case .exit: out.keep = false
            case .none_: break
            }
        } else if s.grid {
            let slides = ShowGeometry.gridIndices(doc.slides.count)
            if let n = ShowGeometry.seeAllHit(full, slides.count, ShowGeometry.slideAspect(doc), p), let i = slides.at(n) {
                s.grid = false
                s.blank = nil
                s.zoom = nil
                s.zoomArm = false
                actions.append(s.state.goto(doc, i))
            }
        } else if s.zoomArm && !controlsHit(p, full) {
            let srect = ShowGeometry.slideRect(full, reading: s.reading, doc)
            if let (nx, ny) = ShowGeometry.normOnSlide(srect, ShowGeometry.unitUV, p) {
                s.zoom = .at(nx, ny)
                s.zoomArm = false
            }
        } else if s.zoom != nil && !s.pen && !controlsHit(p, full) {
            s.dismissZoom()
        } else if !s.pen && !controlsHit(p, full) && !pointerOnMediaBar(p, full, now) {
            if s.ended {
                out.keep = false
            } else if s.blank != nil {
                s.blank = nil
            } else {
                // A shape with an action or a triggered animation, or the background.
                switch s.clickSlide(doc, under ?? ShowUnder(), now) {
                case .show(let a): actions.append(a)
                case .open(let url): out.openURL = url
                case .exit: out.keep = false
                case .animated, .none_: break
                }
            }
        }
        for a in actions where !s.apply(a, doc, now) { out.keep = false }
        showMedia()
        return out
    }

    /// A secondary click: back a step, unless a mode is open.
    public func secondaryClick(_ now: Double) -> ShowOutcome {
        guard let s = show, let d = showState else { return ShowOutcome(keep: false) }
        if !s.ended && !s.grid && s.zoom == nil && !s.zoomArm {
            let keep = s.apply(s.state.prev(d.doc), d.doc, now)
            showMedia()
            return ShowOutcome(keep: keep, redraw: true)
        }
        return ShowOutcome()
    }

    /// A scroll: ⌘/Ctrl turns it into a zoom around `p` (`lines` notches, up positive, #1286); otherwise a flick of
    /// `points` (the stronger axis, negative = next) turns the page, once per 0.35 s (`page_flick`).
    public func scroll(_ p: CGPoint, _ full: CGRect, zoomLines: Double?, flick: (Double, Double), now: Double) -> ShowOutcome {
        guard let s = show, let d = showState else { return ShowOutcome(keep: false) }
        if let lines = zoomLines {
            if !s.grid && !s.ended && s.blank == nil {
                s.wheelZoom(ShowGeometry.slideRect(full, reading: s.reading, d.doc), p, lines.isFinite ? lines : 0)
            }
            return ShowOutcome(redraw: true)
        }
        guard !s.pen, let next = Self.pageFlick(flick), now - s.lastSwipe > 0.35 else { return ShowOutcome() }
        s.lastSwipe = now
        var keep = true
        if next {
            if s.ended { keep = false } else { keep = s.apply(s.state.next(d.doc), d.doc, now) }
        } else {
            s.ended = false
            keep = s.apply(s.state.prev(d.doc), d.doc, now)
        }
        showMedia()
        return ShowOutcome(keep: keep, redraw: true)
    }

    /// A trackpad flick or wheel notch that turns the page (`page_flick`): the stronger axis wins; negative
    /// movement is the next slide; under 18 points is ignored.
    public nonisolated static func pageFlick(_ wheel: (Double, Double)) -> Bool? {
        let along = Swift.abs(wheel.0) > Swift.abs(wheel.1) ? wheel.0 : wheel.1
        return Swift.abs(along) > 18 ? along < 0 : nil
    }

    /// `ui.inspect`'s `showing`.
    public func showingValue(_ full: CGRect) -> JSON {
        guard let s = show else { return .null }
        let doc = showState?.doc
        let n = doc?.slides.count ?? 0
        let aspect = doc.map(ShowGeometry.slideAspect) ?? 16.0 / 9.0
        return s.showingValue(nSlides: n, aspect: aspect, full: full, now: Self.now())
    }

    // MARK: Animation preview on the canvas

    /// Play the current slide's animations on the canvas from effect `from` (`start_anim_preview`).
    public func startAnimPreview(_ from: Int?) -> Result<JSON, CommandError> {
        guard let d = session.activeDoc else { return .failure("no presentation is open") }
        guard d.selection.target == .slides else { return .failure("animation preview plays the current slide") }
        let slide = d.selection.slide
        guard let s = d.doc.slides.at(slide) else { return .failure("no slide to preview") }
        let timeline = ShowState.timeline(d.doc, slide)
        if timeline.isEmpty {
            stopAnimPreview()
            model.status = "This slide has no animations"
            return .success(["playing": false])
        }
        var fromSecs = 0.0
        if let i = from {
            guard let t = timeline.startOf(i) else { return .failure(CommandError("no effect \(i) in this slide's click sequence")) }
            fromSecs = t
        }
        if model.ui.view == .sorter || model.ui.view == .notesPage { model.ui.view = .normal }
        animPreview = AnimPreview(uid: d.uid, slide: slide, slideValue: s, started: nil, from: fromSecs, elapsed: fromSecs, timeline: timeline)
        model.status = "Previewing animations"
        onPreviewChanged?()
        return .success(["playing": true, "slide": .integer(slide), "duration": .double(timeline.totalDuration), "from": .double(fromSecs)])
    }

    public func stopAnimPreview() {
        guard animPreview != nil else { return }
        animPreview = nil
        onPreviewChanged?()
    }

    /// Advance the preview clock (`tick_anim_preview`): it stops when the slide changes or is edited, or when the
    /// sequence (and a short hold) has played. Returns whether it still plays.
    @discardableResult
    public func tickAnimPreview(_ now0: Double) -> Bool {
        guard let p = animPreview else { return false }
        let alive = show == nil && session.activeDoc.map { d in
            d.uid == p.uid && d.selection.target == .slides && d.selection.slide == p.slide && d.doc.slides.at(p.slide) == p.slideValue
        } ?? false
        if !alive {
            stopAnimPreview()
            return false
        }
        let now = now0.isFinite ? now0 : (p.started ?? 0)
        let start = p.started ?? now
        let elapsed = p.from + Swift.max(now - start, 0)
        if !elapsed.isFinite || elapsed > p.timeline.totalDuration + Self.previewHold {
            stopAnimPreview()
            return false
        }
        animPreview?.started = start
        animPreview?.elapsed = elapsed
        return true
    }

    /// `ui.inspect`'s `animPreview`.
    public var animPreviewValue: JSON {
        guard let p = animPreview else { return .null }
        return ["slide": .integer(p.slide), "time": .double(p.elapsed), "duration": .double(p.timeline.totalDuration)]
    }

    /// A shape's state at preview time `time` on the play-everything clock (`preview::shape_state_at`).
    public nonisolated static func previewState(_ tl: Timeline, _ id: ShapeId, _ time: Double) -> ShapeState {
        let (step, t) = tl.locate(time)
        let a = tl.state(id, nil, step, t)
        var s = ShapeState()
        s.visible = a.visible
        s.opacity = a.opacity
        s.offset = Vec2(a.offsetX, a.offsetY)
        s.scale = (a.scaleX, a.scaleY)
        s.rotate = a.rotate
        s.clip = a.clip.map { [$0[0], $0[1], $0[2], $0[3]] }
        s.tint = a.tint
        s.paras = tl.paragraphTargets(id).map { i in
            let pa = tl.state(id, i, step, t)
            var ps = ParaState()
            ps.visible = pa.visible
            ps.opacity = pa.opacity
            ps.offset = Vec2(pa.offsetX, pa.offsetY)
            return (i, ps)
        }
        return s
    }
}
