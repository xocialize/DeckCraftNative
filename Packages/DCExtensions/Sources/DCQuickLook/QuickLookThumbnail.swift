// DCQuickLook — the Quick Look thumbnail of a presentation (Finder icons, Cover Flow, the preview's sidebar):
// its first slide, drawn by DCRender at the pixel size asked for. A file too large to read whole gives the
// picture its package carries of its first slide (`docProps/thumbnail.jpeg`, PowerPoint's), else its first
// slide read without pictures; a file the engine can't read gives that package picture or nothing (Quick
// Look then shows the generic icon). Not a port: deckcraft has no Quick Look extension.
import CoreGraphics
import DCCore
import DCExtensionKit
import DCModel
import DCRender
import Foundation
import ImageIO

/// A thumbnail ready to draw: the picture and the size, in points, of the context to draw it in.
public struct DeckThumbnail: @unchecked Sendable {
    public var image: CGImage
    public var contextSize: CGSize
    /// Where it came from.
    public var source: Source

    public enum Source: Sendable, Equatable {
        /// The first slide, drawn (`textOnly`: read without its pictures).
        case slide(textOnly: Bool)
        /// The picture the package carries.
        case embedded
        /// A deck without slides: a blank page of its slide size.
        case blank
    }

    /// Draws the picture over the whole of `ctx` (Quick Look's bitmap context, in Core Graphics' coordinates).
    public func draw(in ctx: CGContext) -> Bool {
        let box = ctx.boundingBoxOfClipPath
        guard box.width > 0, box.height > 0, box.width.isFinite, box.height.isFinite else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: box)
        return true
    }
}

public enum QuickLookThumbnail {
    /// The longest side, in pixels, a thumbnail is drawn at, whatever is asked.
    public static let maxPixelSide = 2048

    /// The context size for content of `aspect` (width, height) fitted in `maximum` points: one side meets
    /// `maximum`'s, as Quick Look prefers.
    public static func contextSize(aspect: (Double, Double), maximum: CGSize) -> CGSize {
        let (w, h) = (aspect.0.isFinite && aspect.0 > 0 ? aspect.0 : 4, aspect.1.isFinite && aspect.1 > 0 ? aspect.1 : 3)
        let mw = maximum.width.isFinite && maximum.width > 0 ? Double(maximum.width) : 256
        let mh = maximum.height.isFinite && maximum.height > 0 ? Double(maximum.height) : 256
        let k = Swift.min(mw / w, mh / h)
        return CGSize(width: Swift.max(1, (w * k).rounded()), height: Swift.max(1, (h * k).rounded()))
    }

    /// The pixel size of a context of `size` points at `scale`, its longest side at most `maxPixelSide`.
    static func pixelSize(_ size: CGSize, scale: CGFloat) -> (Int, Int) {
        let s = scale.isFinite && scale > 0 ? Double(scale) : 1
        var (w, h) = (Double(size.width) * s, Double(size.height) * s)
        let longest = Swift.max(w, h, 1)
        if longest > Double(maxPixelSide) {
            let k = Double(maxPixelSide) / longest
            (w, h) = (w * k, h * k)
        }
        return (Swift.max(1, Int(rustCast: w.rounded())), Swift.max(1, Int(rustCast: h.rounded())))
    }

    /// The thumbnail of the file at `url` for a request of `maximumSize` points at `scale`; nil when there is
    /// nothing to show.
    public static func make(fileAt url: URL, maximumSize: CGSize, scale: CGFloat, limits: DeckLimits = .thumbnail) -> DeckThumbnail? {
        ExtensionFonts.prepare()
        let file: DeckFile
        do {
            file = try DeckReader.read(url, limits: limits, orText: false)
        } catch DeckFileError.tooLarge {
            if let t = embedded(url, maximumSize, scale) { return t }
            guard let f = try? DeckReader.readText(url, limits: limits) else { return nil }
            file = f
        } catch {
            return embedded(url, maximumSize, scale)
        }
        return make(file, maximumSize: maximumSize, scale: scale)
    }

    /// The thumbnail of a deck already read: its first slide (hidden or not, as PowerPoint's own).
    public static func make(_ file: DeckFile, maximumSize: CGSize, scale: CGFloat) -> DeckThumbnail? {
        let p = file.presentation
        let (sw, sh) = (p.slideSize.width.rustMax(1), p.slideSize.height.rustMax(1))
        let size = contextSize(aspect: (sw, sh), maximum: maximumSize)
        let (pw, ph) = pixelSize(size, scale: scale)
        if p.slides.isEmpty {
            return blank(pw, ph).map { DeckThumbnail(image: $0, contextSize: size, source: .blank) }
        }
        var opts = RenderOpts(scale: Double(pw) / sw)
        opts.size = (pw, ph)
        guard let image = renderSlide(p, 0, opts).cgImage() else { return nil }
        return DeckThumbnail(image: image, contextSize: size, source: .slide(textOnly: file.textOnly))
    }

    /// The package's own picture of its first slide, decoded no larger than the request.
    static func embedded(_ url: URL, _ maximumSize: CGSize, _ scale: CGFloat) -> DeckThumbnail? {
        guard let bytes = DeckReader.embeddedThumbnail(url),
              let src = CGImageSourceCreateWithData(Data(bytes) as CFData, nil) else { return nil }
        let (pw, ph) = pixelSize(maximumSize, scale: scale)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Swift.max(pw, ph),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let size = contextSize(aspect: (Double(image.width), Double(image.height)), maximum: maximumSize)
        return DeckThumbnail(image: image, contextSize: size, source: .embedded)
    }

    /// A white page.
    static func blank(_ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
