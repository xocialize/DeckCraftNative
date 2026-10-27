// Ported from deckcraft crates/render/src/images.rs `mod tests` and the picture-resolution tests in
// tests.rs / tests_wild.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors). The
// test pictures are encoded with ImageIO here (the `image` crate there).
import CoreGraphics
import DCColor
import DCCore
import DCModel
@testable import DCRender
import Foundation
import ImageIO
import Testing

/// A PNG's chunks other than `pHYs` (ImageIO may write one; the tests want untagged pictures).
func withoutPHYs(_ png: [UInt8]) -> [UInt8] {
    guard png.count > 8 else { return png }
    var out = Array(png[0 ..< 8])
    var i = 8
    while i + 12 <= png.count {
        let len = Int(png[i]) << 24 | Int(png[i + 1]) << 16 | Int(png[i + 2]) << 8 | Int(png[i + 3])
        let end = min(i + 12 + len, png.count)
        if Array(png[i + 4 ..< i + 8]) != Array("pHYs".utf8) { out += png[i ..< end] }
        i = end
    }
    return out
}

/// `png` with a pHYs chunk saying `dpi` inserted after its header.
func withDPI(_ png: [UInt8], _ dpi: Double) -> [UInt8] {
    Images.stampPNGDPI(withoutPHYs(png), dpi)
}

@Suite struct ImagesTests {
    func greyPNG(_ w: Int, _ h: Int) -> [UInt8] {
        withoutPHYs(png(w, h, [UInt8](repeating: 90, count: w * h * 4), gray: true))
    }

    func run(_ adj: PictureAdjust, _ px: [[UInt8]]) -> [[UInt8]] {
        var img = StraightImage(width: px.count, height: 1, pixels: px.flatMap { $0 })
        Images.applyAdjust(&img, adj)
        return Swift.stride(from: 0, to: img.pixels.count, by: 4).map { Array(img.pixels[$0 ..< $0 + 4]) }
    }

    @Test func rgbaConversionIsRefusedPastTheCap() throws {
        let p = greyPNG(100, 50)
        let rgba = UInt64(100 * 50 * 4)
        #expect(Images.decodeRaster(p, rgba - 1) == nil, "grey decodes small, its RGBA does not fit")
        let img = try #require(Images.decodeRaster(p, rgba))
        #expect(img.width == 100 && img.height == 50)
        #expect(img.pixels.prefix(4) == [90, 90, 90, 255])
        // A picture whose header claims a huge size is refused.
        var huge = p
        huge.replaceSubrange(16 ..< 20, with: [0, 0, 0xEA, 0x60])
        huge.replaceSubrange(20 ..< 24, with: [0, 0, 0xEA, 0x60])
        #expect(Images.decodeRaster(huge, Images.maxRGBA) == nil)
        #expect(!Images.fits(60_000, 60_000, Images.maxRGBA) && Images.fits(8192, 8192, Images.maxRGBA))
    }

    @Test func failedSourcesAreBoundedAndReleased() {
        var c = Images.Cache()
        let srcs: [[UInt8]] = (0 ..< Images.badMax + 50).map { [UInt8](repeating: UInt8($0 % 256), count: 1000) }
        for s in srcs { c.markBad(Images.address(s), s) }
        #expect(c.bad.count == Images.badMax)
        #expect(c.badBytes == Images.badMax * 1000)
        // The oldest were forgotten; the newest are still known.
        #expect(!c.isBad(Images.address(srcs[0]), srcs[0]))
        if let last = srcs.last { #expect(c.isBad(Images.address(last), last)) }
        // The byte budget holds too, and an input larger than it isn't kept at all.
        let big = [UInt8](repeating: 0, count: Images.badBudget / 2 + 1)
        c.markBad(Images.address(big), big)
        let big2 = [UInt8](repeating: 1, count: Images.badBudget / 2 + 1)
        c.markBad(Images.address(big2), big2)
        #expect(c.badBytes <= Images.badBudget)
        let huge = [UInt8](repeating: 0, count: Images.badBudget + 1)
        c.markBad(Images.address(huge), huge)
        #expect(!c.isBad(Images.address(huge), huge))
    }

    @Test func invalidPicturesFailAndValidOnesStillDecodeAndCache() throws {
        let bad = Array("not a picture at all".utf8)
        #expect(Images.decodeFor(bad, 64, PictureAdjust()) == nil)
        #expect(Images.decodeFor(bad, 64, PictureAdjust()) == nil)
        let good = greyPNG(20, 10)
        let a = try #require(Images.decodeFor(good, 64, PictureAdjust()))
        let b = try #require(Images.decodeFor(good, 64, PictureAdjust()))
        #expect(a === b, "cached")
        #expect(a.width == 20 && a.height == 10)
    }

    @Test func largePicturesAreDecodedNearTheSizeShown() throws {
        let big = withoutPHYs(png(512, 256, [UInt8](repeating: 200, count: 512 * 256 * 4)))
        let small = try #require(Images.decodeFor(big, 60, PictureAdjust()))
        #expect(small.width == 64 && small.height == 32, "\(small.width)×\(small.height)")
        let full = try #require(Images.decodeFor(big, 1000, PictureAdjust()))
        #expect(full.width == 512)
    }

    @Test func duotoneMapsLuminanceBetweenItsTwoColours() {
        let adj = PictureAdjust(duotone: Pair(ColorRef.rgb(.rgb(100, 40, 0)), ColorRef.rgb(.rgb(250, 240, 200))))
        let out = run(adj, [[0, 0, 0, 255], [128, 128, 128, 200], [255, 255, 255, 255]])
        #expect(out[0] == [100, 40, 0, 255], "black takes the dark colour")
        #expect(out[2] == [250, 240, 200, 255], "white takes the light colour")
        let mid = out[1]
        #expect(abs(Int(mid[0]) - 175) <= 1 && abs(Int(mid[1]) - 140) <= 1 && abs(Int(mid[2]) - 100) <= 1, "\(mid)")
        #expect(mid[3] == 200, "alpha is kept")
        // Different duotones are cached separately.
        let other = PictureAdjust(duotone: Pair(ColorRef.rgb(.rgb(0, 0, 0)), ColorRef.rgb(.rgb(255, 0, 0))))
        #expect(Images.adjustKey(adj) != Images.adjustKey(other))
        #expect(Images.adjustKey(adj) != Images.adjustKey(PictureAdjust()))
    }

    @Test func brightnessAndContrastMapGreysLikePowerPoint() {
        // Grey levels PowerPoint's export gives for inputs 0, 32, 64, 96 (and 128, 160).
        func levels(_ b: Double, _ c: Double, _ input: [UInt8]) -> [UInt8] {
            run(PictureAdjust(brightness: b, contrast: c), input.map { [$0, $0, $0, 255] }).map { $0[0] }
        }
        func close(_ got: [UInt8], _ want: [UInt8]) -> Bool { zip(got, want).allSatisfy { abs(Int($0) - Int($1)) <= 5 } }
        #expect(close(levels(0.4, 0.4, [0, 32, 64, 96]), [54, 105, 157, 210]), "\(levels(0.4, 0.4, [0, 32, 64, 96]))")
        #expect(close(levels(0.4, -0.4, [0, 32, 64, 96]), [133, 152, 171, 190]))
        #expect(close(levels(-0.4, 0.4, [128, 160, 192]), [0, 45, 97]))
        #expect(close(levels(0.0, -0.8, [0, 128, 255]), [102, 127, 152]))
    }

    @Test func grayscaleBlackAndWhiteAndInvertedAlphaLikePowerPoint() {
        let swatches: [[UInt8]] = [[255, 0, 0, 200], [0, 255, 0, 200], [0, 0, 255, 200], [200, 100, 50, 200], [60, 160, 110, 200], [120, 120, 130, 200]]
        // PowerPoint's export of these swatches in grayscale: 54, 182, 18, 117, 135, 120.
        for (got, want) in zip(run(PictureAdjust(grayscale: true), swatches), [54, 182, 18, 117, 135, 120]) {
            #expect(abs(Int(got[0]) - want) <= 1 && got[0] == got[1] && got[1] == got[2], "\(got) vs \(want)")
        }
        // Black and white at 50%: only green and the light green reach mid-grey.
        #expect(run(PictureAdjust(bilevel: 0.5), swatches).map { $0[0] } == [0, 255, 0, 0, 255, 0])
        // Inverted alpha: 200 becomes 55.
        #expect(run(PictureAdjust(alphaInv: true), swatches).allSatisfy { $0[3] == 55 })
        // Clear colour: within 8 of it becomes transparent.
        let cleared = run(PictureAdjust(clearColor: .rgb(255, 0, 0)), [[250, 4, 3, 255], [240, 0, 0, 255]])
        #expect(cleared[0][3] == 0 && cleared[1][3] == 255)
    }

    @Test func oppositeBrightnessAndContrastAreCachedApart() {
        let a = PictureAdjust(brightness: 0.4, contrast: 0.4)
        let b = PictureAdjust(brightness: -0.4, contrast: -0.4)
        #expect(Images.adjustKey(a) != Images.adjustKey(b))
        let c = PictureAdjust(brightness: 0.4, contrast: -0.4)
        let d = PictureAdjust(brightness: -0.4, contrast: 0.4)
        #expect(Images.adjustKey(c) != Images.adjustKey(d))
        #expect(Images.adjustKey(a) == Images.adjustKey(a))
    }

    func gif(_ frames: Int, delay: Double) -> [UInt8] {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, frames, nil) else { return [] }
        for i in 0 ..< frames {
            let px: [UInt8] = i % 2 == 0 ? [255, 0, 0, 255] : [0, 0, 255, 255]
            guard let img = RenderImage(width: 1, height: 1, pixels: px).cgImage() else { continue }
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(dest, img, props)
        }
        guard CGImageDestinationFinalize(dest) else { return [] }
        return [UInt8](data as Data)
    }

    @Test func aGifOfManyTinyFramesKeepsOnlyTheFrameCap() throws {
        let bytes = gif(Images.gifMaxFrames + 200, delay: 0.02)
        let a = try #require(Images.decodeAnim(bytes, PictureAdjust()))
        #expect(a.frames.count == Images.gifMaxFrames)
        #expect(a.ends.count == Images.gifMaxFrames)
    }

    @Test func animatedGifsLoopThroughTheirFrames() throws {
        let bytes = gif(3, delay: 0.5)
        // Frames 0.5 s each: 0.7 s in is the second, 1.6 s in the first again.
        let f = try #require(Images.gifFrame(bytes, PictureAdjust(), 0.7))
        #expect(f.0 == 1 && abs(f.1 - 0.3) < 1e-9)
        #expect(Images.gifFrame(bytes, PictureAdjust(), 1.6)?.0 == 0)
        #expect(Images.gifImage(bytes, PictureAdjust(), 0.7) != nil)
        // A still picture is not animated; nor are a single-frame GIF's frames.
        #expect(Images.gifFrame(greyPNG(2, 2), PictureAdjust(), 0) == nil)
        #expect(Images.gifFrame(gif(1, delay: 0.5), PictureAdjust(), 0) == nil)
        // Frames of 10 ms or less show for 100 ms, as in browsers.
        let fast = try #require(Images.decodeAnim(gif(2, delay: 0.0), PictureAdjust()))
        #expect(fast.ends.map { ($0 * 10).rounded() / 10 } == [0.1, 0.2])
    }

    @Test func pictureResolutionSizesTiles() {
        let p = withoutPHYs(halfRedHalfBlue())
        #expect(Images.dpi(p) == nil)
        let p48 = withDPI(p, 48)
        let d = Images.dpi(p48) ?? (0, 0)
        #expect(abs(d.0 - 48) < 0.01 && abs(d.1 - 48) < 0.01, "\(d)")
        // 8 × 4 px at 48 dpi is as big as 16 × 8 at 96.
        #expect(Images.naturalSize(p48).map { $0 == (16.0, 8.0) } == true)
        #expect(Images.naturalSize(p).map { $0 == (8.0, 4.0) } == true)
        // JFIF density in dots per inch.
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0, 16] + Array("JFIF\0".utf8) + [0x01, 0x01, 0x01, 0x00, 0x48, 0x00, 0x48]
        #expect(Images.dpi(jpeg).map { $0 == (72.0, 72.0) } == true)
    }

    @Test func aStampedPNGRecordsItsResolutionOnce() throws {
        let p = withoutPHYs(halfRedHalfBlue())
        let stamped = Images.stampPNGDPI(p, 144)
        #expect(Images.dpi(stamped).map { $0 == (144.0, 144.0) } == true)
        let decoded = try #require(Images.decodeRaster(stamped, Images.maxRGBA))
        #expect(decoded.width == 8 && decoded.height == 4)
        let again = Images.stampPNGDPI(stamped, 72)
        #expect(again.count == stamped.count, "a second pHYs chunk is not written")
        #expect(Images.dpi(again).map { $0 == (144.0, 144.0) } == true)
        // Not a PNG, or a resolution out of range: unchanged.
        #expect(Images.stampPNGDPI([1, 2, 3], 144) == [1, 2, 3])
        #expect(Images.stampPNGDPI(p, .nan) == p)
        // The chunk's CRC is the standard one (`IEND` with no data is AE 42 60 82).
        #expect(Images.pngCRC(Array("IEND".utf8)) == 0xAE42_6082)
    }
}
