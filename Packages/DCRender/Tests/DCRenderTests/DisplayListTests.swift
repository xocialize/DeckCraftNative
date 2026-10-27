// DCRenderTests — the recording canvas and its vector (PDF) and raster replays.
import CoreGraphics
import DCColor
import DCGeometry
import DCTestSupport
import Foundation
import Testing
@testable import DCRender

/// A small scene: a gradient rectangle, a dashed stroke, a clipped half-transparent ellipse group and,
/// when `effects`, a blurred layer and a soft edge (`DestIn` inside a plain layer).
private func scene(_ c: Canvas, effects: Bool) {
    c.setPaint(.linear(start: Point(0, 0), end: Point(200, 0), stops: [ColorStop(0, Rgba(r: 30, g: 90, b: 200, a: 255)), ColorStop(1, Rgba(r: 240, g: 200, b: 40, a: 255))], extend: .pad))
    c.fillRect(Rect(10, 10, 190, 90))
    c.setPaint(.color(Rgba(r: 20, g: 20, b: 20, a: 255)))
    c.setStroke(StrokeStyle(3).withDashes(0, [8, 4]))
    var line = BezPath()
    line.moveTo(Point(10, 110))
    line.lineTo(Point(190, 140))
    c.strokePath(line)
    c.pushLayer(clip: rectPath(Rect(40, 40, 160, 130)), opacity: 0.5)
    c.setTransform(Affine.translate(Vec2(100, 85)))
    c.setPaint(.color(Rgba(r: 200, g: 30, b: 60, a: 255)))
    c.fillPath(ellipse(70, 40))
    c.popLayer()
    c.setTransform(.identity)
    guard effects else { return }
    c.pushLayer(blur: 4)
    c.setPaint(.color(Rgba(r: 0, g: 140, b: 70, a: 255)))
    c.fillRect(Rect(20, 100, 80, 140))
    c.popLayer()
    c.pushLayer()
    c.setPaint(.color(Rgba(r: 90, g: 0, b: 160, a: 255)))
    c.fillRect(Rect(120, 100, 190, 140))
    c.pushLayer(blend: BlendMode(.normal, .destIn))
    c.setPaint(.color(Rgba(r: 0, g: 0, b: 0, a: 128)))
    c.fillRect(Rect(150, 90, 200, 150))
    c.popLayer()
    c.popLayer()
}

private func ellipse(_ rx: Double, _ ry: Double) -> BezPath {
    let k = 0.5522847498
    var p = BezPath()
    p.moveTo(Point(rx, 0))
    p.curveTo(Point(rx, ry * k), Point(rx * k, ry), Point(0, ry))
    p.curveTo(Point(-rx * k, ry), Point(-rx, ry * k), Point(-rx, 0))
    p.curveTo(Point(-rx, -ry * k), Point(-rx * k, -ry), Point(0, -ry))
    p.curveTo(Point(rx * k, -ry), Point(rx, -ry * k), Point(rx, 0))
    p.closePath()
    return p
}

/// The list drawn into a one-page PDF of `w` × `h` points, and the PDF's bytes.
private func pdf(_ list: DisplayList, scale: Double = 2) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: list.width, height: list.height)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
    ctx.beginPDFPage(nil)
    ctx.translateBy(x: 0, y: box.height)
    ctx.scaleBy(x: 1, y: -1)
    list.draw(in: ctx, view: .identity, bounds: box, rasterScale: scale)
    ctx.endPDFPage()
    ctx.closePDF()
    return data as Data
}

/// Page 1 of a PDF rendered at `scale` over white.
private func rasterise(_ data: Data, scale: Double) -> CGImage? {
    guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider), let page = doc.page(at: 1) else { return nil }
    let box = page.getBoxRect(.mediaBox)
    let w = Int(box.width * scale), h = Int(box.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    ctx.drawPDFPage(page)
    return ctx.makeImage()
}

private func imageCount(_ data: Data) -> Int {
    guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider), let page = doc.page(at: 1),
          let dict = page.dictionary else { return -1 }
    var res: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res else { return 0 }
    var xo: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { return 0 }
    var n = 0
    CGPDFDictionaryApplyBlock(xo, { _, obj, _ in
        var s: CGPDFStreamRef?
        if CGPDFObjectGetValue(obj, .stream, &s), let s, let d = CGPDFStreamGetDictionary(s) {
            var name: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(d, "Subtype", &name), let name, String(cString: name) == "Image" { n += 1 }
        }
        return true
    }, nil)
    return n
}

@Suite struct DisplayListTests {
    @Test func replayMatchesDirectDrawing() throws {
        for effects in [false, true] {
            let direct = try #require(Canvas(width: 200, height: 150))
            scene(direct, effects: effects)
            let rec = try #require(Canvas(recordingWidth: 200, height: 150))
            scene(rec, effects: effects)
            let list = rec.recording()
            let replayed = try #require(Canvas(width: 200, height: 150))
            list.replay(into: replayed)
            #expect(replayed.finish() == direct.finish())
        }
    }

    @Test func recordingDrawsNothing() throws {
        let rec = try #require(Canvas(recordingWidth: 50, height: 50))
        rec.fillRect(Rect(0, 0, 50, 50))
        #expect(rec.finish().pixels.allSatisfy { $0 == 0 })
        #expect(!rec.recording().isEmpty)
    }

    @Test func plainSceneIsAllVector() throws {
        let rec = try #require(Canvas(recordingWidth: 200, height: 150))
        scene(rec, effects: false)
        let list = rec.recording()
        #expect(!list.hasRaster)
        #expect(imageCount(pdf(list)) == 0)
    }

    @Test func effectsBecomeIsolatedRasters() throws {
        let rec = try #require(Canvas(recordingWidth: 200, height: 150))
        scene(rec, effects: true)
        let list = rec.recording()
        #expect(list.hasRaster)
        // The blurred layer and the soft-edged one, each its own image; the rest stays vector.
        #expect(imageCount(pdf(list)) == 2)
    }

    @Test func backdropComposeRastersTheWholePage() throws {
        let rec = try #require(Canvas(recordingWidth: 100, height: 100))
        rec.setPaint(.color(Rgba(r: 255, g: 0, b: 0, a: 255)))
        rec.fillRect(Rect(0, 0, 100, 100))
        rec.pushLayer(blend: BlendMode(.normal, .destOut))
        rec.fillRect(Rect(25, 25, 75, 75))
        rec.popLayer()
        #expect(imageCount(pdf(rec.recording())) == 1)
    }

    /// The vector PDF, rendered back, looks like the raster of the same drawing.
    @Test func vectorPDFMatchesRaster() throws {
        for effects in [false, true] {
            let scale = 2.0
            let direct = try #require(Canvas(width: 400, height: 300))
            let rec = try #require(Canvas(recordingWidth: 200, height: 150))
            scene(rec, effects: effects)
            let list = rec.recording()
            list.replay(into: direct, view: Affine.scale(scale))
            let reference = try #require(direct.finish().cgImage())
            let back = try #require(rasterise(pdf(list, scale: scale), scale: scale))
            let score = try #require(RenderParity.score(reference: reference, distorted: back))
            #expect(score > 85, "SSIMULACRA2 \(score) (effects: \(effects))")
        }
    }
}
