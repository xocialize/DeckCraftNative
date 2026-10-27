// DCEngine — animated GIF of the deck (the Export… dialog; `file.export` with format `gif`).
// Port of deckcraft crates/engine/src/gif_export.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). The frames are encoded by ImageIO instead of the `image` crate (NeuQuant), so the bytes
// differ; frame count, size and delay are the same.
//
// One frame per slide, drawn by the slide renderer and shown for `secondsPerSlide`. All parameters are
// hostile: sizes, delays and slide lists are checked against fixed bounds, and the total number of pixels
// encoded is capped.
import DCCore
import DCModel
import DCRender

public enum GifExport {
    static let cmd = "file.export"

    /// Size presets, by frame width in pixels.
    public static let sizePresets: [(String, UInt32)] = [("small", 640), ("medium", 960), ("large", 1280), ("extraLarge", 1920)]
    /// Frame width when none is given (the `medium` preset).
    public static let defaultWidth: UInt32 = 960
    public static let minWidth: UInt32 = 16
    public static let maxWidth: UInt32 = 3840
    /// Longest frame side: a very tall slide is scaled down to fit.
    public static let maxSide: UInt32 = 3840
    public static let defaultSeconds = 5.0
    public static let minSeconds = 0.1
    public static let maxSeconds = 600.0
    public static let maxFrames = 500
    /// Cap on frames × width × height.
    public static let maxTotalPixels: UInt64 = 200_000_000

    /// What to export.
    public struct Options: Sendable, Equatable {
        /// Frame width in pixels; the height follows the slide's aspect ratio.
        public var width: UInt32 = GifExport.defaultWidth
        public var secondsPerSlide = GifExport.defaultSeconds
        /// Loop forever (true) or play once.
        public var loopForever = true
        /// Slide indices in play order (default: all).
        public var slides: [Int]?
        /// Hidden slides are left out unless this is set.
        public var includeHidden = false
        public init() {}
    }

    /// An encoded GIF and what is in it.
    public struct Output: Sendable {
        public var bytes: [UInt8]
        public var frames: Int
        public var width: UInt32
        public var height: UInt32
        /// Per-frame delay in hundredths of a second, as written.
        public var delayCs: UInt16
    }

    static func widthValue(_ v: JSON) throws(EngineError) -> UInt32 {
        let err = Cmd.bad(cmd, "`width` must be a whole number of pixels from \(minWidth) to \(maxWidth), or one of small, medium, large, extraLarge")
        switch v {
        case .string(let s):
            let k = rustASCIILowercase(String(rustTrim(s)))
            guard let w = sizePresets.first(where: { rustASCIILowercase($0.0) == k })?.1 else { throw err }
            return w
        case .uint, .int, .double, .float:
            guard let w = v.asU64.flatMap({ UInt32(exactly: $0) }), (minWidth ... maxWidth).contains(w) else { throw err }
            return w
        default:
            throw err
        }
    }

    /// Check a per-slide duration (NaN, infinities and out-of-range values are errors).
    public static func checkSeconds(_ s: Double) throws(EngineError) -> Double {
        guard s >= minSeconds && s <= maxSeconds else {
            throw Cmd.bad(cmd, "`secondsPerSlide` must be from \(minSeconds.rustDisplay) to \(maxSeconds.rustDisplay)")
        }
        return s
    }

    /// Present and not `null`.
    private static func given(_ p: JSON, _ key: String) -> JSON? {
        guard let v = p.get(key), !v.isNull else { return nil }
        return v
    }

    /// Read `{width?: px | small|medium|large|extraLarge, secondsPerSlide?, loop?: bool | forever|once,
    /// slides?: [index], includeHidden?}`. Absent or `null` values take their defaults; anything else that
    /// is out of range or of the wrong type is an error.
    public static func options(_ p: JSON) throws(EngineError) -> Options {
        var o = Options()
        if let v = given(p, "width") { o.width = try widthValue(v) }
        if let v = given(p, "secondsPerSlide") {
            guard let s = v.asF64 else { throw Cmd.bad(cmd, "`secondsPerSlide` must be a number") }
            o.secondsPerSlide = try checkSeconds(s)
        }
        if let v = given(p, "loop") {
            switch v {
            case .bool(let b): o.loopForever = b
            case .string(let s) where rustASCIILowercase(s) == "forever": o.loopForever = true
            case .string(let s) where rustASCIILowercase(s) == "once": o.loopForever = false
            default: throw Cmd.bad(cmd, "`loop` must be true (forever), false (once), \"forever\" or \"once\"")
            }
        }
        if let v = given(p, "slides") {
            guard let a = v.asArray else { throw Cmd.bad(cmd, "`slides` must be a list of slide indices") }
            if a.isEmpty { throw Cmd.bad(cmd, "`slides` is empty") }
            if a.count > maxFrames { throw Cmd.bad(cmd, "a GIF can have at most \(maxFrames) slides") }
            var list: [Int] = []
            for x in a {
                guard let i = x.asUsize else { throw Cmd.bad(cmd, "`slides` must be a list of slide indices (0, 1, 2…)") }
                list.append(i)
            }
            o.slides = list
        }
        if let v = given(p, "includeHidden") {
            guard let b = v.asBool else { throw Cmd.bad(cmd, "`includeHidden` must be true or false") }
            o.includeHidden = b
        }
        return o
    }

    /// The slides that become frames, in order: the chosen ones (or all), without hidden slides unless
    /// `includeHidden`.
    public static func frames(_ o: Options, _ doc: Presentation) throws(EngineError) -> [Int] {
        let n = doc.slides.count
        let chosen: [Int]
        if let list = o.slides {
            if let i = list.first(where: { $0 >= n }) { throw Cmd.bad(cmd, "no slide \(i) (the presentation has \(n))") }
            chosen = list
        } else {
            chosen = Array(0 ..< n)
        }
        let frames = chosen.filter { o.includeHidden || doc.slides.at($0).map { !$0.hidden } == true }
        if frames.isEmpty { throw Cmd.bad(cmd, "no slides to export (they are all hidden, or the presentation is empty)") }
        if frames.count > maxFrames { throw Cmd.bad(cmd, "a GIF can have at most \(maxFrames) slides; choose a range") }
        return frames
    }

    /// Delay per frame in hundredths of a second.
    public static func delayCs(_ o: Options) throws(EngineError) -> UInt16 {
        let s = try checkSeconds(o.secondsPerSlide)
        return UInt16(rustCast: (s * 100).rounded().clamped(1, Double(UInt16.max)))
    }

    /// Frame size for a slide of `doc`'s size at `width` px: the height follows the aspect ratio and no
    /// side exceeds `maxSide`.
    public static func frameSize(_ doc: Presentation, _ width: UInt32) -> (UInt32, UInt32) {
        let (sw, sh) = (doc.slideSize.width, doc.slideSize.height)
        let aspect = sw.isFinite && sh.isFinite && sw > 0 && sh > 0 ? sh / sw : 9.0 / 16.0
        let w = Double(min(max(width, minWidth), maxWidth))
        var h = w * aspect
        var w2 = w
        if h > Double(maxSide) {
            w2 = w * Double(maxSide) / h
            h = Double(maxSide)
        }
        func side(_ v: Double) -> UInt32 { v.isFinite ? UInt32(rustCast: v.rounded().clamped(1, Double(maxSide))) : 1 }
        return (side(w2), side(h))
    }

    /// Straight RGBA of a premultiplied render composited onto white.
    static func onWhite(_ img: RenderImage, _ w: Int, _ h: Int) -> [UInt8] {
        let len = w * h * 4
        if img.width != w || img.height != h || img.pixels.count != len { return [UInt8](repeating: 255, count: len) }
        var px = img.pixels
        var i = 0
        while i + 3 < px.count {
            let back = 255 - px[i + 3]
            px[i] = px[i].addingReportingOverflow(back).overflow ? 255 : px[i] + back
            px[i + 1] = px[i + 1].addingReportingOverflow(back).overflow ? 255 : px[i + 1] + back
            px[i + 2] = px[i + 2].addingReportingOverflow(back).overflow ? 255 : px[i + 2] + back
            px[i + 3] = 255
            i += 4
        }
        return px
    }

    /// Render and encode the GIF.
    public static func encode(_ doc: Presentation, _ o: Options) throws(EngineError) -> Output {
        let frames = try frames(o, doc)
        let delay = try delayCs(o)
        let (w, h) = frameSize(doc, o.width)
        let total = UInt64(frames.count).multipliedReportingOverflow(by: UInt64(w)).partialValue.multipliedReportingOverflow(by: UInt64(h)).partialValue
        if total > maxTotalPixels {
            throw Cmd.bad(cmd, "\(frames.count) slides at \(w)×\(h) is too large for a GIF; choose a smaller size or fewer slides")
        }
        var scale = Double(w) / doc.slideSize.width
        if !(scale.isFinite && scale > 0) { scale = 1 }
        var pixels: [[UInt8]] = []
        for i in frames {
            var opts = RenderOpts(scale: scale)
            opts.size = (Int(w), Int(h))
            let img = renderSlide(doc, i, opts)
            pixels.append(onWhite(img, Int(w), Int(h)))
        }
        guard let bytes = ImageEncoding.gif(pixels, width: Int(w), height: Int(h), delayCs: delay, loop: o.loopForever) else {
            throw .other("GIF encoding failed")
        }
        return Output(bytes: bytes, frames: frames.count, width: w, height: h, delayCs: delay)
    }
}
