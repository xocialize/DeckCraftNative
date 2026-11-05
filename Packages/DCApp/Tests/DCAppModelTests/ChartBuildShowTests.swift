// The port's own: a chart build played in the show (AB-T-0443). Frames of the show, drawn from the timeline's
// states as the show draws them, reveal the chart's series one click at a time. CHARTBUILD_FRAMES=<folder> also
// writes the frames as PNGs, to look at.
import DCAnim
import DCColor
import DCAppModel
import DCEngine
import DCGeometry
import DCModel
import DCRender
import Foundation
import Testing

@Suite struct ChartBuildShowTests {
    /// Pixels of `img` within a few levels of `c`.
    private func count(_ img: RenderImage, _ c: Rgba) -> Int {
        let s = img.toStraight()
        var n = 0
        var i = 0
        while i + 3 < s.count {
            if s[i + 3] > 200 && abs(Int(s[i]) - Int(c.r)) <= 6 && abs(Int(s[i + 1]) - Int(c.g)) <= 6 && abs(Int(s[i + 2]) - Int(c.b)) <= 6 { n += 1 }
            i += 4
        }
        return n
    }

    @Test func showFramesRevealTheSeriesOneClickAtATime() throws {
        var p = Presentation.default
        var shape = Shape.default
        shape.id = ShapeId(9)
        shape.xfrm = Xfrm(80, 60, 800, 420)
        shape.kind = .chart(Chart.sample(.column))
        p.slides[0].shapes = [shape]
        var a = Animation.default
        a.shape = shape.id
        a.effect = "fade"
        a.chartBuild = .bySeries
        p.slides[0].animations = [a]
        let tl = Timeline(p.slides[0], p.slideSize.width, p.slideSize.height)
        #expect(tl.steps == 4)
        let theme = p.masters[0].theme.colors
        let colors = [theme.get(.accent1), theme.get(.accent2), theme.get(.accent3)]
        let text = Rgba.rgb(0x59, 0x59, 0x59)
        let out = ProcessInfo.processInfo.environment["CHARTBUILD_FRAMES"]
        var frames: [[Int]] = []
        // Before the first click, after each click, and halfway into the third.
        for (step, t) in [(0, 0.0), (1, 0.0), (2, 0.0), (2, 0.25), (3, 0.0), (4, 0.0)] {
            let img = renderSlide(p, 0, {
                var o = RenderOpts()
                o.state = { id in showShapeState(tl, id, step, t, [], []) }
                return o
            }())
            if let dir = out {
                try Data(ImageEncoding.png(img)).write(to: URL(fileURLWithPath: dir).appendingPathComponent("step\(step)-t\(t).png"))
            }
            frames.append([count(img, text)] + colors.map { count(img, $0) })
        }
        // [label text, series 1, series 2, series 3] pixels in each frame.
        let (none, bg, s1, half, s2, s3) = (frames[0], frames[1], frames[2], frames[3], frames[4], frames[5])
        #expect(none.allSatisfy { $0 == 0 }, "before the first click the chart is hidden: \(none)")
        #expect(bg[0] > 100, "the background (labels, legend) comes first: \(bg)")
        // Its legend keys come with the background; the bars come one series per click.
        let key = bg[1]
        #expect(key > 0 && bg[2] < key * 2 && bg[3] < key * 2, "\(bg)")
        #expect(s1[1] > key * 20 && s1[2] == bg[2] && s1[3] == bg[3], "series 1 only: \(s1)")
        #expect(half[2] == s1[2], "series 2 halfway through its fade is not at full strength yet: \(half)")
        #expect(s2[2] > key * 20 && s2[3] == bg[3], "series 2: \(s2)")
        #expect(s3[3] > key * 20, "series 3: \(s3)")
        // Once played out, the frame is the chart as drawn without a build.
        let plain = renderSlide(p, 0, RenderOpts())
        let last = renderSlide(p, 0, { var o = RenderOpts(); o.state = { id in showShapeState(tl, id, 4, 0, [], []) }; return o }())
        #expect(last.pixels == plain.pixels)
    }
}
