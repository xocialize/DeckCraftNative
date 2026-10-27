// DCApp — what every view of the Views area shares: the handle on one presentation (`DocLink`) and the
// thumbnail service, which draws slides off the main thread from snapshot values and caches them by
// value (deckcraft `crates/ui-egui/src/textures.rs` `thumb`, MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). A 1,000-slide deck asks only for the rows in view (`huge_deck_tests.rs`).
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCModel
import DCRender

extension Notification.Name {
    /// A thumbnail finished drawing: `object` is the `Thumbnails`, `userInfo["uid"]` the document.
    static let deckCraftThumbnailReady = Notification.Name("DeckCraftThumbnailReady")
}

/// One presentation as the views see it: the shared model and the document's engine uid. Commands run
/// through it make that document the active one first, so a click in a window that isn't key acts on
/// its own presentation.
@MainActor
final class DocLink {
    let model: AppModel
    private let uidSource: @MainActor () -> UInt64

    init(model: AppModel, uid: @escaping @MainActor () -> UInt64) {
        self.model = model
        uidSource = uid
    }

    /// The link for a window's document (the app's model).
    convenience init(document: PresentationDocument) {
        self.init(model: AppController.shared?.model ?? AppModel()) { [weak document] in document?.uid ?? 0 }
    }

    var uid: UInt64 { uidSource() }
    var state: DocState? {
        let u = uid
        return model.session.documents.first { $0.uid == u }
    }

    var index: Int? {
        let u = uid
        return model.session.documents.firstIndex { $0.uid == u }
    }

    /// Make this presentation the engine's active one.
    func activate() {
        guard let i = index, model.session.activeIndex != i else { return }
        model.session.setActive(i)
    }

    /// Run a command on this presentation.
    @discardableResult
    func run(_ id: String, _ params: JSON = .object(JSONObject())) -> Result<JSON, CommandError> {
        activate()
        return model.run(id, params)
    }
}

/// An image that crosses from the drawing task to the main thread (CGImage is immutable).
struct DrawnImage: @unchecked Sendable {
    let cg: CGImage?
}

/// Slide thumbnails for the navigator, the Slide Sorter and Notes Page: drawn on background tasks from a
/// snapshot of the presentation (a value), at most a few at a time with the newest request first, and
/// cached per document by slide value (`ThumbCache`).
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    /// Who asks: the navigator, the sorter and the notes page draw at different sizes, so each keeps
    /// its own thumbnails rather than replacing the others'.
    enum Kind: String, Sendable {
        case navigator, sorter, page
    }

    private struct CacheKey: Hashable, Sendable {
        var uid: UInt64
        var kind: Kind
    }

    private struct Key: Hashable, Sendable {
        var cache: CacheKey
        var slide: SlideId
        var width: Int
    }

    private struct Job: Sendable {
        var key: Key
        var doc: Presentation
        var index: Int
    }

    private var caches: [CacheKey: ThumbCache<CGImage>] = [:]
    private var pending: [Job] = []
    private var running: Set<Key> = []
    /// How many slides draw at once.
    let concurrency: Int
    /// Most requests kept waiting: older ones are dropped (the rows scrolled past).
    let maxPending = 64

    init(concurrency: Int = 3) {
        self.concurrency = Swift.max(1, concurrency)
    }

    /// Thumbnails held for `uid` (`thumb_count`).
    func count(_ uid: UInt64) -> Int { caches.filter { $0.key.uid == uid }.values.reduce(0) { $0 + $1.count } }
    /// Thumbnails drawn for `uid` (`thumb_renders`).
    func renders(_ uid: UInt64) -> UInt64 { caches.filter { $0.key.uid == uid }.values.reduce(0) { $0 + $1.renders } }
    /// Whether anything is drawing or waiting.
    var busy: Bool { !pending.isEmpty || !running.isEmpty }

    /// Forget a closed presentation's thumbnails.
    func drop(_ uid: UInt64) { caches = caches.filter { $0.key.uid != uid } }

    /// Keep only the thumbnails of the presentations still open.
    func keep(_ uids: Set<UInt64>) {
        caches = caches.filter { uids.contains($0.key.uid) }
    }

    /// The thumbnail of slide `index` of `doc` (document `uid`), `width` pixels wide. Returns what is
    /// cached (possibly stale) and asks for a fresh one when it isn't up to date; `.deckCraftThumbnailReady`
    /// is posted when it is.
    func image(_ doc: Presentation, uid: UInt64, index: Int, width: Int, kind: Kind = .navigator) -> CGImage? {
        guard let slide = doc.slides.at(index) else { return nil }
        let w = Swift.min(Swift.max(width, 16), 2048)
        let ck = CacheKey(uid: uid, kind: kind)
        let cache = caches[ck] ?? ThumbCache<CGImage>()
        caches[ck] = cache
        let master = doc.masterFor(slide)?.master
        let (image, fresh) = cache.lookup(slide, master: master, width: w)
        if !fresh { request(Job(key: Key(cache: ck, slide: slide.id, width: w), doc: doc, index: index)) }
        return image
    }

    private func request(_ job: Job) {
        if running.contains(job.key) { return }
        pending.removeAll { $0.key == job.key }
        pending.append(job)
        if pending.count > maxPending { pending.removeFirst(pending.count - maxPending) }
        pump()
    }

    private func pump() {
        while running.count < concurrency, let job = pending.popLast() {
            running.insert(job.key)
            let (doc, index, width) = (job.doc, job.index, job.key.width)
            Task.detached(priority: .userInitiated) {
                let drawn = Self.draw(doc, index, width)
                await self.finish(job, drawn)
            }
        }
    }

    private func finish(_ job: Job, _ drawn: DrawnImage) {
        running.remove(job.key)
        if let cg = drawn.cg, let slide = job.doc.slides.at(job.index) {
            let cache = caches[job.key.cache] ?? ThumbCache<CGImage>()
            caches[job.key.cache] = cache
            cache.store(cg, slide: slide, master: job.doc.masterFor(slide)?.master, width: job.key.width)
            NotificationCenter.default.post(name: .deckCraftThumbnailReady, object: self, userInfo: ["uid": job.key.cache.uid])
        }
        pump()
    }

    /// Slide `index` of `doc` drawn `width` pixels wide (off the main thread).
    nonisolated static func draw(_ doc: Presentation, _ index: Int, _ width: Int) -> DrawnImage {
        let sw = doc.slideSize.width
        guard sw > 0, sw.isFinite else { return DrawnImage(cg: nil) }
        return DrawnImage(cg: renderSlide(doc, index, RenderOpts(scale: Double(width) / sw)).cgImage())
    }
}

/// The ratio of a slide's height to its width (a damaged size gives 16:9).
func slideAspect(_ doc: Presentation) -> Double {
    let (w, h) = (doc.slideSize.width, doc.slideSize.height)
    guard w.isFinite, h.isFinite, w > 0, h > 0 else { return 0.5625 }
    return Swift.min(Swift.max(h / w, 0.05), 20)
}
