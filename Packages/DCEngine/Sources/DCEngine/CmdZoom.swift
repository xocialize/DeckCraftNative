// DCEngine — the `zoom` command module: Insert ▸ Zoom (Summary Zoom, Section Zoom and Slide Zoom).
//
// A zoom is a picture of the target slide that jumps to it in the slide show. With Return to Zoom (on for
// summary and section zooms, as in PowerPoint) the show comes back to the zoom slide after the target slide,
// or the target section's last slide. In .pptx a zoom is saved as the linked picture PowerPoint itself writes
// as the fallback for older versions.
// Port of deckcraft crates/engine/src/cmd/zoom.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCGeometry
import DCModel

public enum ZoomCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd(
                "insert.zoom",
                "Zoom",
                ["Insert", "Links"],
                nil,
                "{kind?: slide|section|summary (default slide); slides?: [index] (slide and summary zooms); sections?: [index] (section zoom); returnToZoom?: bool (default: on for section and summary, off for slide)}",
                Cmd.hasSlide,
                zoom
            ),
        ]
    }

    /// One zoom tile: the slide it shows and jumps to, and the slide after which the show returns.
    struct Target {
        var slide: SlideId
        var index: Int
        var last: SlideId
    }

    /// `n` tiles of `aspect` (w / h) laid out in a centred grid inside `area`.
    static func grid(_ n: Int, _ area: Xfrm, _ aspect: Double) -> [Xfrm] {
        let cols = Int(rustCast: Double(n).squareRoot().rounded(.up).rustMax(1.0))
        let rows = max((n + cols - 1) / max(cols, 1), 1)
        let gap = 12.0
        let cw = (area.w - gap * (Double(cols) - 1.0)) / Double(cols)
        let ch = (area.h - gap * (Double(rows) - 1.0)) / Double(rows)
        var (w, h) = cw / ch > aspect ? (ch * aspect, ch) : (cw, cw / aspect)
        // A single slide zoom is a quarter of the slide wide, as PowerPoint inserts it.
        if n == 1 { (w, h) = (w.rustMin(area.w / 2.0), h.rustMin(area.w / 2.0 / aspect)) }
        let shown = Double(min(cols, n))
        let totalW = shown * w + gap * (shown - 1.0)
        let totalH = Double(rows) * h + gap * (Double(rows) - 1.0)
        let (x0, y0) = (area.x + (area.w - totalW) / 2.0, area.y + (area.h - totalH) / 2.0)
        return (0 ..< max(n, 0)).map { k in Xfrm(x0 + Double(k % cols) * (w + gap), y0 + Double(k / cols) * (h + gap), w, h) }
    }

    static func indices(_ p: JSON, _ key: String, _ n: Int, _ what: String) throws -> [Int] {
        guard case .array(let a)? = p.get(key) else { return [] }
        var v: [Int] = []
        for x in a {
            guard let i = x.asU64.flatMap({ Int(exactly: $0) }), i < n else {
                throw Cmd.bad("insert.zoom", "there is no \(what) \(x.display) (indices count from 0)")
            }
            if !v.contains(i) { v.append(i) }
        }
        return v
    }

    @Sendable static func zoom(_ s: Session, _ p: JSON) throws -> JSON {
        let kind = Cmd.strParam(p, "kind") ?? "slide"
        let doc = try s.doc().doc
        let n = doc.slides.count
        var targets: [Target]
        switch kind {
        case "slide":
            targets = try indices(p, "slides", n, "slide").compactMap { i in doc.slides.at(i).map { Target(slide: $0.id, index: i, last: $0.id) } }
        case "section":
            targets = try indices(p, "sections", doc.sections.count, "section").compactMap { k in
                guard let sec = doc.sections.at(k), let first = sec.slides.first, let last = sec.slides.last, let index = doc.slideIndex(first) else { return nil }
                return Target(slide: first, index: index, last: last)
            }
        case "summary":
            var starts = try indices(p, "slides", n, "slide")
            if starts.isEmpty {
                // Default: the first slide of every section.
                starts = doc.sections.compactMap { sec in sec.slides.first.flatMap { doc.slideIndex($0) } }
            }
            starts.sort()
            targets = starts.enumerated().compactMap { k, i in
                // Each part runs to the slide before the next part (or the end).
                let end = max(starts.at(k + 1).map { max($0 - 1, 0) } ?? max(n - 1, 0), i)
                guard let sl = doc.slides.at(i), let last = doc.slides.at(end) else { return nil }
                return Target(slide: sl.id, index: i, last: last.id)
            }
        default:
            throw Cmd.bad("insert.zoom", "unknown zoom kind `\(kind)` (slide, section or summary)")
        }
        if targets.isEmpty { throw Cmd.bad("insert.zoom", "choose the slides (or sections) to zoom to") }
        let back = Cmd.boolOr(p, "returnToZoom", kind != "slide")
        let size = doc.slideSize
        // Pictures of the targets, about 480 px wide.
        let scale = (480.0 / size.width.rustMax(1.0)).clamped(0.05, 4.0)
        let pictures: [([UInt8], String)] = targets.map { t in
            let (png, _, _) = FileCommands.renderPNG(doc, t.index, scale, false)
            let title = doc.slides.at(t.index)?.title ?? ""
            let label = rustTrim(title).isEmpty ? "Slide \(t.index + 1)" : String(rustTrim(rustLines(title).first ?? ""))
            return (png, label)
        }
        let summary = kind == "summary"
        let firstTarget = targets.map(\.index).min() ?? 0
        let kindName = summary ? "Summary" : kind == "section" ? "Section" : "Slide"
        return try s.edit { doc, sel in
            let aspect = size.width / size.height.rustMax(1.0)
            let area: Xfrm
            if summary {
                area = Xfrm(size.width * 0.06, size.height * 0.26, size.width * 0.88, size.height * 0.66)
            } else if targets.count == 1 {
                area = Xfrm(size.width * 0.5, size.height * 0.5, size.width * 0.45, size.height * 0.45)
            } else {
                area = Xfrm(size.width * 0.08, size.height * 0.12, size.width * 0.84, size.height * 0.8)
            }
            let boxes = grid(targets.count, area, aspect)
            var shapes: [Shape] = []
            for ((t, (png, label)), b) in zip(zip(targets, pictures), boxes) {
                guard let media = doc.addMedia("zoom-\(t.index + 1).png", "image/png", png) else { throw Cmd.bad("insert.zoom", Cmd.noIdSpace) }
                guard let raw = doc.allocId() else { throw Cmd.bad("insert.zoom", Cmd.noIdSpace) }
                var sh = Shape.default
                sh.id = ShapeId(raw)
                sh.name = "\(kindName) Zoom \(t.index + 1)"
                sh.descr = label
                sh.xfrm = b
                sh.kind = .picture(fill: PictureFill(media: media))
                sh.click = Hyperlink(action: .slide(slide: t.slide), tooltip: label, highlightClick: false, sound: nil, stopSound: false, zoomReturn: back ? t.last : nil)
                shapes.append(sh)
            }
            let ids = shapes.map(\.id)
            if summary {
                // A new Title Only slide before the first part, as PowerPoint makes it.
                let layout = layoutOfKind(doc, .titleOnly) ?? doc.slides.at(firstTarget)?.layout ?? .default
                guard var slide = newSlide(&doc, layout) else { throw Cmd.bad("insert.zoom", Cmd.noIdSpace) }
                if let i = slide.shapes.firstIndex(where: { $0.phType?.isTitle == true }) {
                    slide.shapes[i].text = TextBody.fromText("Summary")
                }
                slide.shapes.append(contentsOf: shapes)
                let at = min(firstTarget, doc.slides.count)
                doc.slides.insert(slide, at: at)
                sel.slide = at
                sel.slides.removeAll()
            } else {
                try withShapes(&doc, sel, missing: Cmd.bad("insert.zoom", "no slide")) { list in list.append(contentsOf: shapes) }
            }
            sel.shapes = ids
            sel.text = nil
            return ["kind": .string(kind), "ids": ids.toJSON(), "returnToZoom": .bool(back), "slide": .integer(sel.slide)]
        }
    }
}
