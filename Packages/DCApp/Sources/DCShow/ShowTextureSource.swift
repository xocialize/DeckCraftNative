// DCShow — a running show drawn into one texture its host composites: a host's own display loop calls `tick(now:)`
// once a frame, and the source draws the show into `texture` only when its picture changed, moving `generation` so a
// compositor knows. One texture is enough when the host samples it on the same command queue the source draws on:
// the queue runs the next draw after this frame's sample. DeckCraftNative's own; the show window draws into its
// drawable instead (`ShowView`), with the same renderer and pacer.
import CoreGraphics
import DCAppModel
import Metal
import QuartzCore

/// A slide show as a texture: one show (`ShowCoordinator`), drawn by one renderer into one BGRA texture of a size the
/// host chooses, on the host's device and queue (`ShowMetal(device:queue:)`). Main thread, like the coordinator.
@MainActor
public final class ShowTextureSource {
    public let coordinator: ShowCoordinator
    public let renderer: ShowRenderer
    /// When to draw: after a change, while the picture moves, otherwise never (no keep-alive by default: a resting
    /// slide costs nothing, here or in the compositor).
    public var pacer: ShowFramePacer
    /// The texture's size in pixels.
    public private(set) var width: Int
    public private(set) var height: Int
    /// The show's picture: `.bgra8Unorm`, a render target the host samples. nil until the first frame is drawn.
    public private(set) var texture: MTLTexture?
    /// Moves with each picture drawn into `texture` (the same texture each time).
    public private(set) var generation: UInt64 = 0

    /// What the source has drawn, for a status line and measurements.
    public struct Stats: Sendable, Equatable {
        public var framesDrawn = 0
        /// Wall time of the last frame's work on the CPU (the draw list, any slide render, encoding), ms.
        public var lastFrameMs = 0.0
        /// What the last frame was: still, animation, transition, morph, media (a playing video or GIF), end.
        public var lastKind = ""
    }

    public private(set) var stats = Stats()

    public var metal: ShowMetal { renderer.metal }

    /// Whether a show is running (between `start` and its end).
    public var isShowing: Bool { coordinator.show != nil }

    /// - Parameters:
    ///   - coordinator: the show to draw; the source starts and ends it, and ticks it.
    ///   - metal: a compositor on the host's device and queue.
    ///   - endText: the end screen's line; nil draws a plain black end screen.
    public init(coordinator: ShowCoordinator, metal: ShowMetal, width: Int, height: Int, keepAlive: Double? = nil, endText: String? = nil) {
        self.coordinator = coordinator
        renderer = ShowRenderer(coord: coordinator, metal: metal)
        renderer.endText = endText
        pacer = ShowFramePacer(keepAlive: keepAlive)
        self.width = Swift.max(1, Swift.min(width, 16_384))
        self.height = Swift.max(1, Swift.min(height, 16_384))
    }

    // MARK: The show

    /// Start the show at slide `from` (0-based; an index past the end starts an ended show).
    public func start(from: Int) {
        coordinator.startShow(from: from, reading: false)
        pacer.invalidate()
    }

    /// End the show now.
    public func end() {
        coordinator.endShow()
        pacer.invalidate()
    }

    /// A key, as the show window takes it (arrows, Page Up/Down, Space, B, W, digits, Esc…); true when the show used
    /// it. A key that ends the show (Esc, past the end) ends it.
    @discardableResult
    public func key(_ k: ShowKey, _ m: ShowMods = ShowMods(), now: Double) -> Bool {
        guard coordinator.show != nil else { return false }
        let (handled, keep) = coordinator.key(k, m, presenter: false, now: now)
        if !keep { coordinator.endShow() }
        pacer.invalidate()
        return handled
    }

    /// Something outside the show changed what the picture shows: draw on the next tick.
    public func invalidate() {
        pacer.invalidate()
    }

    /// A new texture size; the next tick draws at it.
    public func resize(width: Int, height: Int) {
        let (w, h) = (Swift.max(1, Swift.min(width, 16_384)), Swift.max(1, Swift.min(height, 16_384)))
        guard w != self.width || h != self.height else { return }
        self.width = w
        self.height = h
        texture = nil
        pacer.invalidate()
    }

    // MARK: A frame

    /// Advance the show to `now` (seconds, `ShowCoordinator.now()`'s clock) and, when its picture changed, draw it into
    /// `texture`, on `commandBuffer` when given (the host commits it) or on a command buffer of the compositor's queue
    /// that the source commits. True when a new picture was drawn and `generation` moved; false when nothing changed,
    /// no show runs, or the show just ended.
    @discardableResult
    public func tick(now: Double, commandBuffer: MTLCommandBuffer? = nil) -> Bool {
        guard coordinator.show != nil else { return false }
        if !coordinator.tick(now) {
            coordinator.endShow()
            pacer.invalidate()
            return false
        }
        if coordinator.media.syncVideoFrames() { pacer.invalidate() }
        guard let show = coordinator.show else { return false }
        pacer.observe(show)
        guard pacer.shouldDraw(now: now, transitioning: show.trans != nil) else { return false }
        guard let target = ensureTexture() else { return false }
        pacer.willDraw(now: now)
        let started = CACurrentMediaTime()
        let frame = renderer.frame(pixels: CGSize(width: width, height: height), now: now)
        let own = commandBuffer == nil
        guard let buffer = commandBuffer ?? metal.queue.makeCommandBuffer(),
              renderer.encode(frame, into: target, commandBuffer: buffer) else { return false }
        if own { buffer.commit() }
        pacer.drew(frame)
        generation &+= 1
        stats.framesDrawn += 1
        stats.lastFrameMs = (CACurrentMediaTime() - started) * 1000
        stats.lastKind = Self.kind(show, frame)
        return true
    }

    private func ensureTexture() -> MTLTexture? {
        if let t = texture, t.width == width, t.height == height { return t }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        texture = metal.device.makeTexture(descriptor: descriptor)
        return texture
    }

    static func kind(_ show: ShowController, _ frame: ShowFrame) -> String {
        if show.ended { return "end" }
        if let tr = show.trans { return tr.isMorph ? "morph" : "transition" }
        if show.animating { return "animation" }
        return frame.animating ? "media" : "still"
    }
}
