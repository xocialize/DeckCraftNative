// DCEngine — what a `.ppt` import needs drawn (DCPPT's `PPTHooks`, P4 of Docs/plans/Legacy-PPT-and-Encryption.md):
// PICT pictures, which only AppKit still draws, as PNG; and a pattern fill's bitmap as the DrawingML preset whose
// tile it shows (DCRender's tiles, read from PowerPoint's own patterns).
import AppKit
import CoreGraphics
import DCPPT
import DCRender
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum LegacyPictures {
    public static let hooks = PPTHooks(pict: { pictToPNG($0) }, pattern: { patternPreset($0) })

    /// Longest side a PICT is drawn at.
    static let maxSide = 4096.0

    /// A PICT file (its 512-byte header included) drawn by AppKit, as PNG at its own size (at most `maxSide`); nil
    /// when AppKit can't read it.
    static func pictToPNG(_ pict: [UInt8]) -> [UInt8]? {
        guard let rep = NSPICTImageRep(data: Data(pict)) else { return nil }
        let size = rep.boundingBox.size
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else { return nil }
        let k = min(1, maxSide / max(size.width, size.height))
        let w = max(1, Int((size.width * k).rounded())), h = max(1, Int((size.height * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let drawn = rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard drawn, let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](data as Data)
    }

    /// The preset whose tile a pattern bitmap shows: its top-left 8×8 pixels, dark ones the foreground (or, failing
    /// that, light ones: a file may store it either way).
    static func patternPreset(_ bitmap: [UInt8]) -> String? {
        guard let source = CGImageSourceCreateWithData(Data(bitmap) as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width >= 8, image.height >= 8,
              let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        // The top-left 8×8 at one pixel each: the image drawn at its own size, its top edge at the context's top.
        ctx.draw(image, in: CGRect(x: 0, y: 8 - image.height, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: 64)
        var rows = [UInt8](repeating: 0, count: 8)
        for y in 0 ..< 8 {
            for x in 0 ..< 8 where px[y * 8 + x] < 128 { rows[y] |= 0x80 >> UInt8(x) }
        }
        let inverted = rows.map { ~$0 }
        return Pattern.presets.first { Pattern.tile($0) == rows } ?? Pattern.presets.first { Pattern.tile($0) == inverted }
    }
}
