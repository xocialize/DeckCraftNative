// DCAppModel — the pictures of the ribbon's table-style and SmartArt tiles: DCRender's render of a sample table
// in the style, or of the layout's preview graphic (`SmartArtCommands.preview`, as deckcraft's `smartart_gallery`
// draws its tiles), in the presentation's own theme. Pure and safe off the main thread: the presentation is a
// value, and nothing is written to it. Not a port beyond what it names.
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DCRender
import Foundation

public enum RibbonTileArt {
    /// The widest tile, in pixels.
    public static let maxWidth = 512

    /// Whether `art` is drawn by this renderer (the other tiles are drawn by the view).
    public static func rendered(_ art: RibbonGalleryItem.Art) -> Bool {
        switch art {
        case .tableStyle, .smartArt: true
        default: false
        }
    }

    /// The PNG of `art` about `width` pixels wide, on slide `slide` of `pres` (for its layout's theme and colour
    /// map); nil for a tile this renderer doesn't draw or a failed render.
    public static func png(_ art: RibbonGalleryItem.Art, _ pres: Presentation, slide: Int, width: Int) -> [UInt8]? {
        let w = Double(Swift.min(Swift.max(width, 16), maxWidth))
        guard let shape = sample(art) else { return nil }
        var s = pres.slides.at(slide) ?? pres.slides.first ?? Slide.default
        s.shapes = [shape]
        let bw = shape.xfrm?.w ?? 0
        guard bw.isFinite, bw > 0 else { return nil }
        guard let image = renderShape(pres, s, shape.id, w / (bw + 16)) else { return nil }
        let png = ImageEncoding.png(image)
        return png.isEmpty ? nil : png
    }

    /// The shape a tile shows.
    static func sample(_ art: RibbonGalleryItem.Art) -> Shape? {
        switch art {
        case .tableStyle(let style):
            // A small table with its header row and banded rows on, as a new table has them.
            var t = Table(rows: 4, cols: 4, width: 160, rowHeight: 24)
            t.style = style
            var shape = Shape.default
            shape.xfrm = Xfrm(0, 0, 160, 96)
            shape.kind = .table(t)
            return shape
        case .smartArt(let kind, let style, let colors):
            return SmartArtCommands.preview(kind, style, colors, nil)
        default:
            return nil
        }
    }
}
