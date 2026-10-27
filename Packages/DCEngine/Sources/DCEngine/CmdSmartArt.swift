// DCEngine — the `smartart` command module: a diagram's outline (the Text Pane) and the shapes generated
// from it.
// Port of deckcraft crates/engine/src/cmd/smartart.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// A SmartArt graphic is a group whose `diagram` holds its layout and its nodes (text + outline level).
// Every edit changes the nodes and regenerates the group's children inside the group's child rectangle,
// so the diagram keeps its size and place. Text typed straight into a diagram shape is read back into the
// nodes before each regeneration.
import DCColor
import DCCore
import DCGeometry
import DCModel
import Foundation

public enum SmartArtCommands {
    /// Deepest outline level the Text Pane allows.
    public static let maxLevel: UInt8 = 8
    /// Most top-level shapes a layout draws.
    static let maxShapes = 40

    /// DeckCraft's layouts, with the names PowerPoint's gallery gives them.
    public static let layouts: [(String, String)] = [
        ("list", "Vertical Bullet List"),
        ("blockList", "Basic Block List"),
        ("hBulletList", "Horizontal Bullet List"),
        ("process", "Basic Process"),
        ("chevron", "Basic Chevron Process"),
        ("verticalProcess", "Vertical Process"),
        ("stepUp", "Step Up Process"),
        ("cycle", "Basic Cycle"),
        ("blockCycle", "Block Cycle"),
        ("radial", "Basic Radial"),
        ("hierarchy", "Hierarchy"),
        ("pyramid", "Basic Pyramid"),
        ("invertedPyramid", "Inverted Pyramid"),
        ("matrix", "Basic Matrix"),
        ("titledMatrix", "Titled Matrix"),
        ("pictureList", "Vertical Picture List"),
        ("pictureCaption", "Picture Caption List"),
        ("pictureProcess", "Picture Accent Process"),
        ("pictureHList", "Horizontal Picture List"),
        ("timeline", "Basic Timeline"),
        ("venn", "Basic Venn"),
        ("target", "Basic Target"),
        ("textCycle", "Text Cycle"),
        ("continuousCycle", "Continuous Cycle"),
        ("horizontalHierarchy", "Horizontal Hierarchy"),
        ("gridMatrix", "Grid Matrix"),
        ("gear", "Gear"),
        ("funnel", "Funnel"),
        ("segmentedCycle", "Segmented Cycle"),
        ("multidirectionalCycle", "Multidirectional Cycle"),
        ("orgChart", "Organization Chart"),
        ("halfCircleOrgChart", "Half Circle Organization Chart"),
        ("cycleMatrix", "Cycle Matrix"),
        ("segmentedPyramid", "Segmented Pyramid"),
        ("pie", "Basic Pie"),
        ("nameTitleOrgChart", "Name and Title Organization Chart"),
        ("verticalBoxList", "Vertical Box List"),
        ("trapezoidList", "Trapezoid List"),
        ("tableList", "Table List"),
        ("accentProcess", "Accent Process"),
        ("continuousBlockProcess", "Continuous Block Process"),
        ("bendingProcess", "Basic Bending Process"),
        ("linearVenn", "Linear Venn"),
        ("stackedVenn", "Stacked Venn"),
        ("nestedTarget", "Nested Target"),
    ]

    /// SmartArt Styles.
    public static let styles: [(String, String)] = [
        ("flat", "Simple Fill"),
        ("subtle", "Subtle Effect"),
        ("intense", "Intense Effect"),
        ("outline", "White Outline"),
        ("polished", "Polished"),
        ("inset", "Inset"),
        ("cartoon", "Cartoon"),
        ("powder", "Powder"),
        ("brick", "Brick Scene"),
    ]

    /// Change Colors.
    public static let colors: [(String, String)] = [
        ("colorful", "Colorful"),
        ("range23", "Colorful Range - Accent Colors 2 to 3"),
        ("range34", "Colorful Range - Accent Colors 3 to 4"),
        ("range45", "Colorful Range - Accent Colors 4 to 5"),
        ("range56", "Colorful Range - Accent Colors 5 to 6"),
        ("accent1", "Accent 1"),
        ("accent2", "Accent 2"),
        ("accent3", "Accent 3"),
        ("accent4", "Accent 4"),
        ("accent5", "Accent 5"),
        ("accent6", "Accent 6"),
        ("accent1Grad", "Gradient Range - Accent 1"),
        ("accent2Grad", "Gradient Range - Accent 2"),
        ("accent3Grad", "Gradient Range - Accent 3"),
        ("accent4Grad", "Gradient Range - Accent 4"),
        ("accent5Grad", "Gradient Range - Accent 5"),
        ("accent6Grad", "Gradient Range - Accent 6"),
    ]

    /// Brick Scene's camera: the diagram's shapes seen from above and to the side.
    public static let brickCamera = "isometricOffAxis2Top"

    /// The gallery category a layout is shown under in Convert to SmartArt and Change Layout.
    public static func category(_ kind: String) -> String {
        switch kind {
        case "pictureList", "pictureCaption", "pictureProcess", "pictureHList": "picture"
        case "process", "chevron", "verticalProcess", "stepUp", "timeline", "gear", "funnel", "accentProcess", "continuousBlockProcess", "bendingProcess": "process"
        case "cycle", "blockCycle", "textCycle", "continuousCycle", "segmentedCycle", "multidirectionalCycle", "pie": "cycle"
        case "hierarchy", "horizontalHierarchy", "orgChart", "halfCircleOrgChart", "nameTitleOrgChart": "hierarchy"
        case "radial", "venn", "target", "linearVenn", "stackedVenn", "nestedTarget": "relationship"
        case "matrix", "titledMatrix", "gridMatrix", "cycleMatrix": "matrix"
        case "pyramid", "invertedPyramid", "segmentedPyramid": "pyramid"
        default: "list"
        }
    }

    /// A layout's gallery picture: the graphic drawn with sample nodes (or `nodes`) in a 320 × 200 pt group at
    /// the origin, in the style and colours given, with no text in the samples.
    public static func preview(_ kind: String, _ style: String, _ colors: String, _ nodes: [DiagramNode]?) -> Shape {
        func sample(_ levels: [UInt8]) -> [DiagramNode] { levels.map { DiagramNode(level: $0) } }
        let ns: [DiagramNode]
        if let n = nodes, !n.isEmpty {
            ns = n
        } else {
            switch category(kind) {
            case "hierarchy": ns = sample([0, 1, 2, 2, 1])
            case "matrix": ns = sample([0, 0, 0, 0, 0])
            case "list" where kind != "blockList" && kind != "tableList": ns = sample([0, 1, 0, 1, 0, 1])
            default: ns = sample([0, 0, 0, 0])
            }
        }
        let d = Diagram(kind: kind, nodes: ns, style: style, colors: colors)
        let area = Xfrm(0.0, 0.0, 320.0, 200.0)
        var children = layout(d, area)
        for k in children.indices { children[k].id = ShapeId(UInt32(truncatingIfNeeded: 10_000 + k)) }
        var g = Shape.default
        g.id = ShapeId(9_999)
        g.name = "SmartArt preview"
        g.xfrm = area
        g.kind = .group(children: children, child: area)
        return g
    }

    public static func isKind(_ k: String) -> Bool { layouts.contains { $0.0 == k } }

    public static func specs() -> [CommandSpec] {
        [
            .query(
                "smartArt.nodes",
                "Text Pane",
                ["SmartArt Design", "Create Graphic"],
                nil,
                "{id?} → {id, kind, nodes: [{text, level}]} (id: the SmartArt group or one of its shapes; default the selection)",
                Cmd.hasSelection,
                nodesCmd
            ),
            .cmd(
                "smartArt.setNodes",
                "Edit SmartArt Text",
                ["SmartArt Design", "Create Graphic"],
                nil,
                "{id?, nodes?: [{text, level}], lines?: [string] (leading tabs set the level), index?, text?, title?} (index + text edits one node; title: its Name and Title box)",
                Cmd.hasSelection,
                setNodes
            ),
            .cmd(
                "smartArt.addNode",
                "Add Shape",
                ["SmartArt Design", "Create Graphic"],
                nil,
                "{id?, index?, position?: after|before|below|above|assistant, text?} → {index} (default: after the last node)",
                Cmd.hasSelection,
                addNode
            ),
            .cmd(
                "smartArt.removeNode",
                "Remove Shape",
                ["SmartArt Design", "Create Graphic"],
                nil,
                "{id?, index} (its sub-points move up one level)",
                Cmd.hasSelection,
                removeNode
            ),
            .cmd("smartArt.promote", "Promote", ["SmartArt Design", "Create Graphic"], nil, "{id?, index}", Cmd.hasSelection, promote),
            .cmd("smartArt.demote", "Demote", ["SmartArt Design", "Create Graphic"], nil, "{id?, index}", Cmd.hasSelection, demote),
            .cmd(
                "smartArt.layout",
                "Change Layout",
                ["SmartArt Design", "Layouts"],
                nil,
                "{id?, kind: list|blockList|hBulletList|process|chevron|verticalProcess|stepUp|cycle|blockCycle|radial|hierarchy|pyramid|invertedPyramid|matrix|titledMatrix|pictureList|pictureCaption|pictureProcess|pictureHList|timeline|venn|target|textCycle|continuousCycle|horizontalHierarchy|gridMatrix|gear|funnel|segmentedCycle|multidirectionalCycle|orgChart|halfCircleOrgChart|cycleMatrix|segmentedPyramid|pie|nameTitleOrgChart|verticalBoxList|trapezoidList|tableList|accentProcess|continuousBlockProcess|bendingProcess|linearVenn|stackedVenn|nestedTarget}",
                Cmd.hasSelection,
                changeLayout
            ),
            .cmd(
                "smartArt.fromText",
                "Convert to SmartArt",
                ["Home", "Paragraph"],
                nil,
                "{id?, kind?} → {id} (a text box or placeholder becomes a SmartArt graphic in its place: one node per paragraph, indent levels kept)",
                Cmd.hasSelection,
                fromText
            ),
            .cmd(
                "smartArt.toText",
                "Convert to Text",
                ["SmartArt Design", "Reset"],
                nil,
                "{id?} → {id} (the graphic becomes a text box of its outline, bulleted by level)",
                Cmd.hasSelection,
                toText
            ),
            .cmd(
                "smartArt.toShapes",
                "Convert to Shapes",
                ["SmartArt Design", "Reset"],
                nil,
                "{id?} (the graphic becomes a plain group of its shapes; the outline is dropped)",
                Cmd.hasSelection,
                toShapes
            ),
            .cmd(
                "smartArt.picture",
                "Insert Picture in SmartArt",
                ["SmartArt Design", "Create Graphic"],
                nil,
                "{id?, index, data?: base64 | path?: string | reset?: bool} (the node's picture placeholder in picture layouts)",
                Cmd.hasSelection,
                setPicture
            ),
            .cmd(
                "smartArt.style",
                "SmartArt Styles",
                ["SmartArt Design", "SmartArt Styles"],
                nil,
                "{id?, style: flat|subtle|intense|outline|polished|inset|cartoon|powder|brick}",
                Cmd.hasSelection,
                changeStyle
            ),
            .cmd(
                "smartArt.colors",
                "Change Colors",
                ["SmartArt Design", "SmartArt Styles"],
                nil,
                "{id?, colors: colorful|range23|range34|range45|range56|accent1|…|accent6|accent1Grad|…|accent6Grad}",
                Cmd.hasSelection,
                changeColors
            ),
        ]
    }

    // MARK: - The outline

    /// Nodes from text lines: each leading tab is one outline level (`nodes_from_lines`).
    public static func nodesFromLines(_ lines: [String]) -> [DiagramNode] {
        lines.filter { !rustTrim($0).isEmpty }.map { l in
            let tabs = l.unicodeScalars.prefix { $0 == "\t" }.count
            return DiagramNode(text: String(rustTrim(l)), level: UInt8(min(tabs, Int(maxLevel))), picture: nil, assistant: false, title: "")
        }
    }

    /// Levels made consistent: the first node is top level and no node is more than one level deeper than
    /// the node before it.
    public static func normalize(_ nodes: inout [DiagramNode]) {
        var prev: UInt8?
        for i in nodes.indices {
            let lv: UInt8 = if let p = prev { min(nodes[i].level, p == UInt8.max ? p : p + 1, maxLevel) } else { 0 }
            nodes[i].level = lv
            prev = lv
        }
    }

    /// Index one past the last descendant of node `i`.
    static func subtreeEnd(_ nodes: [DiagramNode], _ i: Int) -> Int {
        let lv = nodes.at(i)?.level ?? 0
        var j = i + 1
        while let n = nodes.at(j), n.level > lv { j += 1 }
        return j
    }

    private static func up(_ l: UInt8) -> UInt8 { min(Int(l) + 1, Int(maxLevel)).toU8 }

    /// Add a node next to node `index` (PowerPoint's Add Shape After/Before/Below/Above). Returns the new
    /// node's index.
    @discardableResult
    public static func add(_ nodes: inout [DiagramNode], _ index: Int?, _ position: String, _ text: String) -> Int {
        guard let i = index, i >= 0, i < nodes.count else {
            nodes.append(DiagramNode(text: text, level: 0, picture: nil, assistant: false, title: ""))
            return nodes.count - 1
        }
        let lv = nodes[i].level
        let at: Int
        let level: UInt8
        switch position {
        case "before":
            (at, level) = (i, lv)
        case "below":
            (at, level) = (subtreeEnd(nodes, i), up(lv))
        case "above":
            let end = subtreeEnd(nodes, i)
            for k in i ..< end { nodes[k].level = up(nodes[k].level) }
            (at, level) = (i, lv)
        case "assistant":
            (at, level) = (i + 1, up(lv))
        default:
            (at, level) = (subtreeEnd(nodes, i), lv)
        }
        let a = min(at, nodes.count)
        nodes.insert(DiagramNode(text: text, level: level, picture: nil, assistant: position == "assistant", title: ""), at: a)
        return a
    }

    /// Remove node `i`; its sub-points move up one level.
    @discardableResult
    public static func remove(_ nodes: inout [DiagramNode], _ i: Int) -> Bool {
        guard i >= 0, i < nodes.count else { return false }
        let end = subtreeEnd(nodes, i)
        if i + 1 < end {
            for k in (i + 1) ..< end where nodes[k].level > 0 { nodes[k].level -= 1 }
        }
        nodes.remove(at: i)
        normalize(&nodes)
        return true
    }

    /// Move node `i` and its sub-points one level up. False when it is already top level.
    @discardableResult
    public static func promoteNode(_ nodes: inout [DiagramNode], _ i: Int) -> Bool {
        guard let n = nodes.at(i), n.level != 0 else { return false }
        let end = subtreeEnd(nodes, i)
        for k in i ..< end where nodes[k].level > 0 { nodes[k].level -= 1 }
        return true
    }

    /// Move node `i` and its sub-points one level down, under the node before it. False when there is
    /// nothing to go under.
    @discardableResult
    public static func demoteNode(_ nodes: inout [DiagramNode], _ i: Int) -> Bool {
        guard i >= 1, let prev = nodes.at(i - 1), let cur = nodes.at(i) else { return false }
        if cur.level > prev.level || cur.level >= maxLevel { return false }
        let end = subtreeEnd(nodes, i)
        if nodes[i ..< end].contains(where: { $0.level >= maxLevel }) { return false }
        for k in i ..< end { nodes[k].level += 1 }
        return true
    }

    // MARK: - Layout

    /// A generated shape and the nodes whose text it shows (none for arrows and lines).
    typealias Item = (Shape, [Int])

    /// Top-level nodes, each with its sub-points.
    static func groups(_ d: Diagram) -> [[Int]] {
        var out: [[Int]] = []
        for (i, n) in d.nodes.enumerated() {
            if n.level > 0, !out.isEmpty {
                out[out.count - 1].append(i)
            } else {
                out.append([i])
            }
        }
        if out.count > maxShapes { out.removeLast(out.count - maxShapes) }
        return out
    }

    /// Read text typed into the diagram's shapes back into its nodes.
    static func syncText(_ d: inout Diagram, _ children: [Shape]) {
        if d.imported { return }
        let map = layoutItems(d, Xfrm(0.0, 0.0, 100.0, 100.0)).map(\.1)
        for (shape, idx) in zip(children, map) {
            guard let body = shape.text else { continue }
            if idx.isEmpty || body.paragraphs.count != idx.count { continue }
            for (p, i) in zip(body.paragraphs, idx) where i >= 0 && i < d.nodes.count {
                d.nodes[i].text = p.text
            }
        }
    }

    static func slot(_ i: Int) -> SchemeSlot {
        [SchemeSlot.accent1, .accent2, .accent3, .accent4, .accent5, .accent6][i % 6]
    }

    /// The accent shape `i` is drawn in under Change Colors: `colorful` cycles the accents, `accentN` keeps
    /// one.
    static func accent(_ d: Diagram, _ i: Int) -> SchemeSlot {
        func digit(_ s: Substring, _ k: Int) -> Int? {
            let cs = Array(s)
            guard k < cs.count, let v = cs[k].wholeNumberValue, cs[k].isASCII else { return nil }
            return v
        }
        if d.colors.hasPrefix("range"), let a = digit(d.colors.dropFirst(5), 0), (1 ... 6).contains(a) {
            // Colorful Range: alternate between two neighbouring accents.
            return slot(a - 1 + i % 2)
        }
        if d.colors.hasPrefix("accent"), let n = digit(d.colors.dropFirst(6), 0), (1 ... 6).contains(n) {
            return slot(n - 1)
        }
        return slot(i)
    }

    /// Gradient Range: each shape a step darker than the one before (the steps cycle).
    static func shade(_ d: Diagram, _ i: Int) -> ColorTransform? {
        d.colors.hasSuffix("Grad") ? .lumMod(Int32(100_000 - (i % 4) * 15_000)) : nil
    }

    /// The 3-D XML (`scene3d` + `sp3d`) for a 3-D SmartArt Style: a top bevel (`w`, `h` in points) lit by the
    /// three-point rig.
    static func threeD(_ bevel: String, _ w: Double, _ h: Double, _ camera: String) -> String {
        let we = Int64(rustCast: (w * 12700.0).rounded())
        let he = Int64(rustCast: (h * 12700.0).rounded())
        return "<a:scene3d><a:camera prst=\"\(camera)\"/><a:lightRig rig=\"threePt\" dir=\"t\"/></a:scene3d><a:sp3d prstMaterial=\"matte\"><a:bevelT w=\"\(we)\" h=\"\(he)\" prst=\"\(bevel)\"/></a:sp3d>"
    }

    /// Whether `style` is one of the 3-D SmartArt Styles.
    public static func is3d(_ style: String) -> Bool {
        ["polished", "inset", "cartoon", "powder", "brick"].contains(style)
    }

    private static let noLine = Line(fill: .none_)

    /// Fill, outline, text colour and effects for the SmartArt style. `light` shapes (the bullet boxes of
    /// the bullet lists) are a pale tint of the accent with dark text.
    static func paint(_ d: Diagram, _ sh: inout Shape, _ i: Int, _ light: Bool) {
        let a = accent(d, i)
        let base: ColorRef = if let t = shade(d, i) { ColorRef.scheme(a).with(t) } else { .scheme(a) }
        func tint(_ pct: Int32) -> ColorRef {
            ColorRef.scheme(a).with(.lumMod(100_000 - pct * 1000)).with(.lumOff(pct * 1000))
        }
        let darkText = light || d.style == "outline" || d.style == "powder"
        sh.style = ShapeStyle.accent(a)
        if light {
            sh.fill = .solid(tint(80))
            sh.line = .solid(tint(60), 1.0)
        } else {
            switch d.style {
            case "outline":
                sh.fill = .solid(.scheme(.lt1))
                sh.line = .solid(base, 2.25)
            case "subtle":
                sh.fill = .solid(base)
                sh.line = .solid(.scheme(.lt1), 1.5)
                sh.effects = Effects(outerShadow: shadow(4.0, 3.0))
            case "polished", "inset", "cartoon", "powder", "brick":
                let bevel: String
                let bw: Double
                let line: Line?
                let fill: ColorRef
                switch d.style {
                case "polished": (bevel, bw, line, fill) = ("circle", 12.0, .solid(.scheme(.lt1), 0.75), base)
                case "inset": (bevel, bw, line, fill) = ("relaxedInset", 10.0, nil, base)
                case "cartoon": (bevel, bw, line, fill) = ("softRound", 8.0, .solid(.scheme(.tx1), 2.0), base)
                case "powder": (bevel, bw, line, fill) = ("convex", 14.0, nil, tint(40))
                default: (bevel, bw, line, fill) = ("slope", 6.0, .solid(.scheme(.lt1), 1.0), base)
                }
                sh.fill = .solid(fill)
                sh.line = line ?? noLine
                sh.effects = Effects(
                    outerShadow: d.style != "inset" ? shadow(6.0, 4.0) : nil,
                    bevel: bevel,
                    raw3d: threeD(bevel, bw, bw * 0.6, d.style == "brick" ? brickCamera : "orthographicFront")
                )
            case "intense":
                sh.fill = .gradient(Gradient(
                    stops: [
                        GradientStop(pos: 0.0, color: tint(30)),
                        GradientStop(pos: 1.0, color: base.with(.lumMod(75_000))),
                    ],
                    shape: .linear(angle: 90.0, scaled: false),
                    rotateWithShape: true,
                    tile: [0.0, 0.0, 0.0, 0.0]
                ))
                sh.line = .solid(.scheme(.lt1), 1.0)
                sh.effects = Effects(outerShadow: shadow(8.0, 5.0))
            default:
                sh.fill = .solid(base)
                sh.line = .solid(.scheme(.lt1), 1.5)
            }
        }
        if sh.text != nil {
            let c: ColorRef = darkText ? .scheme(.tx1) : .scheme(.lt1)
            setRunFill(&sh, c)
        }
    }

    private static func setRunFill(_ sh: inout Shape, _ c: ColorRef) {
        guard var body = sh.text else { return }
        for p in body.paragraphs.indices {
            for r in body.paragraphs[p].runs.indices { body.paragraphs[p].runs[r].props.fill = .solid(c) }
        }
        sh.text = body
    }

    static func shadow(_ blur: Double, _ dist: Double) -> Shadow {
        Shadow(
            color: ColorRef.rgb(Rgba(r: 0, g: 0, b: 0, a: 255)).with(.alpha(40_000)),
            blur: blur, dist: dist, dir: 90.0, inner: false, sx: 1.0, sy: 1.0, kx: 0.0, ky: 0.0, align: "", rotateWithShape: false
        )
    }

    /// A shape with text: the first line as the title (centred, larger), the rest as bullets. With `title`
    /// false every line is a bullet (the bullet boxes of the bullet lists).
    static func textShape(_ preset: String, _ x: Xfrm, _ lines: [DiagramNode], _ title: Bool) -> Shape {
        var body = TextBody.default
        body.body.autofit = .shrink(fontScale: 1.0, lineReduction: 0.0)
        let top: UInt8 = lines.first.map { title ? $0.level : $0.level.subSat(1) } ?? 0
        for (k, n) in lines.enumerated() {
            var para = Paragraph(n.text)
            let head = title && k == 0
            if head {
                para.props.align = .center
            } else {
                para.level = min(n.level.subSat(top).subSat(1), maxLevel)
                para.props.align = .left
                para.props.bullet = .char(char: "•")
                para.props.marginLeft = 12.0 * (Double(para.level) + 1.0)
                para.props.indent = -10.0
            }
            let size = head ? 20.0 : 14.0
            for r in para.runs.indices { para.runs[r].props.size = size }
            para.endProps.size = size
            body.paragraphs.append(para)
        }
        if body.paragraphs.isEmpty { body.paragraphs.append(Paragraph("")) }
        if !title { body.body.anchor = .top }
        var s = Shape.default
        s.name = "SmartArt shape"
        s.xfrm = x
        s.geom = .preset(preset)
        s.text = body
        return s
    }

    /// A plain shape with no text (arrows between steps).
    static func deco(_ preset: String, _ x: Xfrm, _ rot: Double) -> Shape {
        var x = x
        x.rot = rot
        var s = Shape.default
        s.name = "SmartArt arrow"
        s.xfrm = x
        s.geom = .preset(preset)
        return s
    }

    static func lineShape(_ a: (Double, Double), _ b: (Double, Double)) -> Shape {
        var x = Xfrm(a.0.rustMin(b.0), a.1.rustMin(b.1), abs(b.0 - a.0), abs(b.1 - a.1))
        x.flipH = (b.0 < a.0) != (b.1 < a.1)
        var s = Shape.default
        s.name = "SmartArt connector"
        s.xfrm = x
        s.geom = .preset("line")
        s.fill = .none_
        s.line = .solid(ColorRef.scheme(.accent1).with(.lumMod(60_000)), 1.25)
        return s
    }

    /// The diagram's shapes laid out in `area` (ids not yet assigned).
    public static func layout(_ d: Diagram, _ area: Xfrm) -> [Shape] {
        layoutItems(d, area).map(\.0)
    }

    /// Lay out `d`, painted with its style and colours, each shape with the nodes it shows; text is shrunk
    /// per shape so its longest word fits on a line.
    static func layoutItems(_ d: Diagram, _ area: Xfrm) -> [Item] {
        var v = layoutRaw(d, area)
        for k in v.indices { fitWords(&v[k].0) }
        return v
    }

    /// Rough advance of a character as a fraction of the font size (a sans text face).
    static let charW = 0.6
    /// Smallest font scale shrinking to fit goes to.
    static let minScale = 0.25

    /// Shrink the shape's text (all paragraphs together, as PowerPoint's per-shape font size does) so no word
    /// is wider than its line and would break mid-word. Overflow in height is left to the body's
    /// shrink-on-overflow autofit.
    static func fitWords(_ sh: inout Shape) {
        guard let w = sh.xfrm?.w else { return }
        // Round shapes keep their text in the inscribed rectangle (about 71% of the width).
        let textW: Double
        if case .preset(let name, _) = sh.geom, ["ellipse", "gear6", "gear9"].contains(name) {
            textW = w * 0.71
        } else {
            textW = w
        }
        guard var body = sh.text else { return }
        let avail = textW - (body.body.insetL ?? 7.2) - (body.body.insetR ?? 7.2)
        var scale = 1.0
        for p in body.paragraphs {
            let line = avail - (p.props.marginLeft ?? 0.0).rustMax(0.0)
            for r in p.runs {
                let size = r.props.size ?? 18.0
                let word = Double(r.text.split(whereSeparator: { $0.unicodeScalars.allSatisfy(\.properties.isWhitespace) }).map { $0.unicodeScalars.count }.max() ?? 0)
                let need = word * size * charW
                if need > 0.0 { scale = scale.rustMin(line.rustMax(0.0) / need) }
            }
        }
        scale = scale.rustMax(minScale)
        if scale >= 0.999 { return }
        func shrink(_ v: inout Double?) {
            if let x = v { v = (x * scale * 2.0).rounded(.down) / 2.0 }
        }
        for p in body.paragraphs.indices {
            for r in body.paragraphs[p].runs.indices { shrink(&body.paragraphs[p].runs[r].props.size) }
            shrink(&body.paragraphs[p].endProps.size)
            shrink(&body.paragraphs[p].props.marginLeft)
            if let i = body.paragraphs[p].props.indent { body.paragraphs[p].props.indent = i * scale }
        }
        sh.text = body
    }

    /// A picture placeholder for node `node`: its picture when it has one, else a pale box.
    static func pictureShape(_ d: Diagram, _ preset: String, _ x: Xfrm, _ i: Int, _ node: Int) -> Shape {
        var sh = Shape.default
        sh.name = "SmartArt picture"
        sh.xfrm = x
        sh.geom = .preset(preset)
        paint(d, &sh, i, true)
        if let m = d.nodes.at(node)?.picture {
            sh.fill = .picture(PictureFill(media: m))
            sh.line = .solid(.scheme(.lt1), 1.5)
        }
        return sh
    }

    private static func clearBox(_ t: inout Shape) {
        t.fill = .none_
        t.line = noLine
        t.effects = nil
    }

    private static func ex(_ v: Double) -> Int { Int(rustCast: v) }

    static func layoutRaw(_ d: Diagram, _ area: Xfrm) -> [Item] {
        let gs = groups(d)
        func nodes(_ g: [Int]) -> [DiagramNode] { g.compactMap { d.nodes.at($0) } }
        let n = max(gs.count, 1)
        let nf = Double(n)
        let pi = Double.pi
        var out: [Item] = []
        // A titled shape for top-level group `i`, painted in its accent.
        func titled(_ preset: String, _ x: Xfrm, _ i: Int, _ g: [Int]) {
            var sh = textShape(preset, x, nodes(g), true)
            paint(d, &sh, i, false)
            out.append((sh, g))
        }
        func arrow(_ x: Xfrm, _ rot: Double, _ i: Int) {
            var sh = deco("rightArrow", x, rot)
            paint(d, &sh, i, true)
            out.append((sh, []))
        }
        func head(_ g: [Int]) -> [Int] { Array(g.prefix(1)) }
        func tail(_ g: [Int]) -> [Int] { Array(g.dropFirst()) }
        func first(_ g: [Int]) -> Int { g.first ?? 0 }
        switch d.kind {
        case "hierarchy":
            return hierarchy(d, area, false)
        case "horizontalHierarchy":
            return hierarchy(d, area, true)
        case "orgChart", "halfCircleOrgChart", "nameTitleOrgChart":
            return orgChart(d, area)
        case "list", "hBulletList":
            // Vertical / Horizontal Bullet List: a coloured title bar, sub-points in a pale box below.
            let vertical = d.kind == "list"
            for (i, g) in gs.enumerated() {
                let cell: Xfrm
                var barH: Double
                if vertical {
                    cell = Xfrm(area.x, area.y + Double(i) * area.h / nf, area.w, area.h / nf * 0.92)
                    barH = (area.h / nf * 0.92).rustMin(area.h * 0.12).rustMax(18.0)
                } else {
                    let w = area.w / nf
                    cell = Xfrm(area.x + Double(i) * w + w * 0.03, area.y, w * 0.94, area.h)
                    barH = area.h * 0.22
                }
                let hasSub = g.count > 1
                barH = barH.rustMin(cell.h)
                titled("roundRect", Xfrm(cell.x, cell.y, cell.w, barH), i, head(g))
                if hasSub {
                    let pad = cell.w * 0.03
                    let x = Xfrm(cell.x + pad, cell.y + barH, cell.w - 2.0 * pad, (cell.h - barH).rustMax(1.0))
                    var sh = textShape("rect", x, nodes(tail(g)), false)
                    paint(d, &sh, i, true)
                    out.append((sh, tail(g)))
                }
            }
        case "blockList":
            // Basic Block List: equal blocks in rows, as square as the area allows.
            let cols = min(max(ex((nf * area.w / area.h.rustMax(1.0) / 1.6).squareRoot().rounded(.up)), 1), n)
            let rows = (n + cols - 1) / cols
            let (w, h) = (area.w / Double(cols), area.h / Double(rows))
            let (bw, bh) = (w * 0.9, (h * 0.85).rustMin(w * 0.9 * 0.6))
            for (i, g) in gs.enumerated() {
                let (c, r) = (i % cols, i / cols)
                let inRow = r + 1 == rows ? n - r * cols : cols
                let x0 = area.x + (area.w - Double(inRow) * w) / 2.0
                titled("rect", Xfrm(x0 + Double(c) * w + (w - bw) / 2.0, area.y + Double(r) * h + (h - bh) / 2.0, bw, bh), i, g)
            }
        case "process", "chevron":
            let chevron = d.kind == "chevron"
            let gap = chevron ? -area.w * 0.02 : area.w * 0.06
            let w = ((area.w - gap * (nf - 1.0)) / nf).rustMax(1.0)
            let h = (area.h * 0.5).rustMin(w * (chevron ? 0.45 : 0.65))
            let y = area.y + (area.h - h) / 2.0
            for (i, g) in gs.enumerated() {
                let x = area.x + Double(i) * (w + gap)
                titled(chevron ? "chevron" : "roundRect", Xfrm(x, y, w, h), i, g)
                if !chevron && i + 1 < n {
                    let aw = gap * 0.7
                    arrow(Xfrm(x + w + gap * 0.15, y + h / 2.0 - aw * 0.45, aw, aw * 0.9), 0.0, i)
                }
            }
        case "verticalProcess":
            let gap = area.h * 0.06
            let h = ((area.h - gap * (nf - 1.0)) / nf).rustMax(1.0)
            let w = area.w * 0.6
            let x = area.x + (area.w - w) / 2.0
            for (i, g) in gs.enumerated() {
                let y = area.y + Double(i) * (h + gap)
                titled("roundRect", Xfrm(x, y, w, h), i, g)
                if i + 1 < n {
                    let s = gap * 0.8
                    // A right arrow turned to point down.
                    arrow(Xfrm(area.x + area.w / 2.0 - s / 2.0, y + h + gap * 0.1, s, s), 90.0, i)
                }
            }
        case "stepUp":
            // Step Up Process: each step higher than the one before.
            let w = area.w / nf
            let h = area.h / (nf + 1.0) * 1.6
            for (i, g) in gs.enumerated() {
                let y = area.y + area.h - h - Double(i) * (area.h - h) / (nf - 1.0).rustMax(1.0)
                titled("rect", Xfrm(area.x + Double(i) * w + w * 0.04, y, w * 0.92, h), i, g)
            }
        case "cycle", "blockCycle":
            let block = d.kind == "blockCycle"
            let r = area.h.rustMin(area.w) * 0.36
            let (cx, cy) = (area.x + area.w / 2.0, area.y + area.h / 2.0)
            let dd = (r * (block ? 0.75 : 0.8)).rustMin(2.0 * pi * r / nf * 0.62)
            for (i, g) in gs.enumerated() {
                let a = (Double(i) / nf * 360.0 - 90.0).toRadians
                let (w, h) = block ? (dd * 1.3, dd * 0.75) : (dd, dd)
                titled(block ? "roundRect" : "ellipse", Xfrm(cx + r * cos(a) - w / 2.0, cy + r * sin(a) - h / 2.0, w, h), i, g)
                if n > 1 {
                    // An arrow halfway to the next node, along the circle.
                    let m = ((Double(i) + 0.5) / nf * 360.0 - 90.0).toRadians
                    let s = (dd * 0.35).rustMax(6.0)
                    let rot = (Double(i) + 0.5) / nf * 360.0
                    arrow(Xfrm(cx + r * cos(m) - s / 2.0, cy + r * sin(m) - s * 0.4, s, s * 0.8), rot, i)
                }
            }
        case "radial":
            // Basic Radial: the first node in the middle, the others around it with spokes.
            guard let centre = gs.first else { return out }
            let rest = Array(gs.dropFirst())
            let m = Double(max(rest.count, 1))
            let r = area.h.rustMin(area.w) * 0.36
            let (cx, cy) = (area.x + area.w / 2.0, area.y + area.h / 2.0)
            let dc = r * 0.75
            let dd = (r * 0.75).rustMin(2.0 * pi * r / m * 0.7)
            for k in rest.indices {
                let a = (Double(k) / m * 360.0 - 90.0).toRadians
                let (ex, ey) = (cx + (r - dd / 2.0) * cos(a), cy + (r - dd / 2.0) * sin(a))
                out.append((lineShape((cx + dc / 2.0 * cos(a), cy + dc / 2.0 * sin(a)), (ex, ey)), []))
            }
            titled("ellipse", Xfrm(cx - dc / 2.0, cy - dc / 2.0, dc, dc), 0, centre)
            for (k, g) in rest.enumerated() {
                let a = (Double(k) / m * 360.0 - 90.0).toRadians
                titled("ellipse", Xfrm(cx + r * cos(a) - dd / 2.0, cy + r * sin(a) - dd / 2.0, dd, dd), k + 1, g)
            }
        case "pyramid", "invertedPyramid":
            // One triangle cut into bands; inverted, the wide band is on top. Each band is drawn as its own
            // polygon so the sides keep the triangle's slope and the text stays upright.
            let inverted = d.kind == "invertedPyramid"
            let h = area.h / nf
            let pw = area.h.rustMin(area.w) * 1.15
            let px = area.x + (area.w - pw) / 2.0
            for (i, g) in gs.enumerated() {
                let (a, b) = (Double(i) / nf, (Double(i) + 1.0) / nf)
                let (t, bt) = inverted ? (1.0 - a, 1.0 - b) : (a, b)
                let (wt, wb) = (pw * t, pw * bt)
                let w = wt.rustMax(wb).rustMax(1.0)
                let bh = h * 0.96
                let x = px + (pw - w) / 2.0
                let (it, ib) = ((w - wt) / 2.0, (w - wb) / 2.0)
                let path = "M \(f2(it)) 0 L \(f2(w - it)) 0 L \(f2(w - ib)) \(f2(bh)) L \(f2(ib)) \(f2(bh)) Z"
                var sh = textShape("rect", Xfrm(x, area.y + Double(i) * h, w, bh), nodes(g), true)
                sh.geom = .custom(paths: [CustomPath(w: w, h: bh, d: path, fill: .norm, stroke: true)])
                // Keep the text inside the sloped sides: inset it to a bit past the band's mid width.
                // The tip band is a triangle: its text sits at the wide end, inset to the width there.
                let tip = wt.rustMin(wb) < 1e-6
                let inset = tip ? w * 0.22 : (it + ib) / 2.0 + abs(it - ib) / 4.0 + 4.0
                if var b = sh.text {
                    b.body.insetL = inset
                    b.body.insetR = inset
                    if tip { b.body.anchor = inverted ? .top : .bottom }
                    sh.text = b
                }
                paint(d, &sh, i, false)
                out.append((sh, g))
            }
        case "matrix", "titledMatrix":
            let titledM = d.kind == "titledMatrix"
            let s = area.h.rustMin(area.w)
            let (x0, y0) = (area.x + (area.w - s) / 2.0, area.y + (area.h - s) / 2.0)
            let quads: [[Int]]
            let title: [Int]?
            if titledM {
                if let t = gs.first { (quads, title) = (Array(gs.dropFirst()), t) } else { (quads, title) = ([], nil) }
            } else {
                (quads, title) = (gs, nil)
            }
            for (i, g) in quads.prefix(4).enumerated() {
                let x = Xfrm(x0 + Double(i % 2) * s / 2.0 + 3.0, y0 + Double(i / 2) * s / 2.0 + 3.0, s / 2.0 - 6.0, s / 2.0 - 6.0)
                titled("roundRect", x, i + (titledM ? 1 : 0), g)
            }
            if let t = title {
                let c = s * 0.42
                var sh = textShape("roundRect", Xfrm(x0 + (s - c) / 2.0, y0 + (s - c * 0.6) / 2.0, c, c * 0.6), nodes(t), true)
                paint(d, &sh, 0, true)
                out.append((sh, t))
            }
        case "pictureList":
            // Vertical Picture List: a picture square at the left of each row, the text beside it.
            let h = area.h / nf
            let bh = h * 0.88
            for (i, g) in gs.enumerated() {
                let y = area.y + Double(i) * h
                let s = bh.rustMin(area.w * 0.3)
                out.append((pictureShape(d, "rect", Xfrm(area.x, y, s, bh), i, first(g)), []))
                titled("roundRect", Xfrm(area.x + s + bh * 0.08, y, (area.w - s - bh * 0.08).rustMax(1.0), bh), i, g)
            }
        case "pictureCaption", "pictureProcess":
            // Picture Caption List: a picture over each caption, in rows. Picture Accent Process: one row,
            // arrows between the steps.
            let process = d.kind == "pictureProcess"
            let cols = process ? n : min(max(ex((nf * area.w / area.h.rustMax(1.0) / 1.2).squareRoot().rounded(.up)), 1), n)
            let rows = (n + cols - 1) / cols
            let gap = process ? area.w * 0.05 : 0.0
            let w = (area.w - gap * (Double(cols) - 1.0)) / Double(cols)
            let h = area.h / Double(rows)
            let bw = process ? w : w * 0.9
            let ch = (h * 0.9).rustMin(bw * 1.1)
            for (i, g) in gs.enumerated() {
                let (c, r) = (i % cols, i / cols)
                let inRow = r + 1 == rows ? n - r * cols : cols
                let x0 = area.x + (area.w - Double(inRow) * w - gap * (Double(inRow) - 1.0)) / 2.0
                let x = x0 + Double(c) * (w + gap) + (w - bw) / 2.0
                let y = area.y + Double(r) * h + (h - ch) / 2.0
                let ph = ch * 0.62
                out.append((pictureShape(d, process ? "ellipse" : "rect", Xfrm(x + (bw - ph.rustMin(bw)) / 2.0, y, ph.rustMin(bw), ph), i, first(g)), []))
                titled(process ? "roundRect" : "rect", Xfrm(x, y + ph + ch * 0.03, bw, ch * 0.35), i, g)
                if process && i + 1 < n {
                    let a = (gap * 0.7).rustMin(ch * 0.2)
                    arrow(Xfrm(x + bw + (gap - a) / 2.0, y + ph / 2.0 - a / 2.0, a, a), 0.0, i)
                }
            }
        case "textCycle", "continuousCycle":
            // Text Cycle: the text alone around a circle, arrows between. Continuous Cycle: boxes on a ring.
            let textOnly = d.kind == "textCycle"
            let r = area.h.rustMin(area.w) * 0.36
            let (cx, cy) = (area.x + area.w / 2.0, area.y + area.h / 2.0)
            let dd = (r * 0.8).rustMin(2.0 * pi * r / nf * 0.62)
            if !textOnly {
                let ring = r * 2.0 + dd * 0.3
                var sh = deco("donut", Xfrm(cx - ring / 2.0, cy - ring / 2.0, ring, ring), 0.0)
                sh.geom = .preset(name: "donut", adj: [7000.0])
                paint(d, &sh, 0, true)
                out.append((sh, []))
            }
            for (i, g) in gs.enumerated() {
                let a = (Double(i) / nf * 360.0 - 90.0).toRadians
                let (w, h) = (dd * 1.35, dd * 0.7)
                var sh = textShape("roundRect", Xfrm(cx + r * cos(a) - w / 2.0, cy + r * sin(a) - h / 2.0, w, h), nodes(g), true)
                paint(d, &sh, i, false)
                if textOnly {
                    sh.fill = .none_
                    sh.line = noLine
                    sh.effects = nil
                    let c = ColorRef.scheme(accent(d, i)).with(.lumMod(75_000))
                    setRunFill(&sh, c)
                    if n > 1 {
                        let m = ((Double(i) + 0.5) / nf * 360.0 - 90.0).toRadians
                        let s = (dd * 0.3).rustMax(6.0)
                        arrow(Xfrm(cx + r * cos(m) - s / 2.0, cy + r * sin(m) - s * 0.4, s, s * 0.8), (Double(i) + 0.5) / nf * 360.0, i)
                    }
                }
                out.append((sh, g))
            }
        case "segmentedCycle", "pie":
            // Segmented Cycle: a ring cut into one arc per node. Basic Pie: a disc cut into wedges. The text
            // sits in a clear box over each segment's middle.
            let ring = d.kind == "segmentedCycle"
            let s = area.h.rustMin(area.w)
            let (cx, cy) = (area.x + area.w / 2.0, area.y + area.h / 2.0)
            let gap = ring ? 2.0 : 0.0
            for (i, g) in gs.enumerated() {
                // Angles clockwise from 3 o'clock, starting at the top.
                let a0 = Double(i) / nf * 360.0 - 90.0 + gap / 2.0
                let a1 = (Double(i) + 1.0) / nf * 360.0 - 90.0 - gap / 2.0
                var sh = deco(ring ? "blockArc" : "pie", Xfrm(cx - s / 2.0, cy - s / 2.0, s, s), 0.0)
                func ang(_ a: Double) -> Double { (remEuclid(a, 360.0) * 60_000.0).rounded() }
                // blockArc runs from its first angle to its second clockwise; so does pie.
                sh.geom = .preset(name: ring ? "blockArc" : "pie", adj: ring ? [ang(a0), ang(a1), 25_000.0] : [ang(a0), ang(a1)])
                paint(d, &sh, i, false)
                out.append((sh, []))
                let m = ((a0 + a1) / 2.0).toRadians
                let rr = ring ? s * 0.4375 : s * 0.3
                let tw = (s * (ring ? 0.22 : 0.3)).rustMin(pi * 2.0 * rr / nf * 0.9)
                let th = s * 0.16
                var t = textShape("rect", Xfrm(cx + rr * cos(m) - tw / 2.0, cy + rr * sin(m) - th / 2.0, tw, th), nodes(g), true)
                paint(d, &t, i, false)
                clearBox(&t)
                out.append((t, g))
            }
        case "multidirectionalCycle":
            // Multidirectional Cycle: nodes around a circle, double-headed arrows between them.
            let r = area.h.rustMin(area.w) * 0.36
            let (cx, cy) = (area.x + area.w / 2.0, area.y + area.h / 2.0)
            let dd = (r * 0.75).rustMin(2.0 * pi * r / nf * 0.55)
            for (i, g) in gs.enumerated() {
                let a = (Double(i) / nf * 360.0 - 90.0).toRadians
                titled("roundRect", Xfrm(cx + r * cos(a) - dd * 0.65, cy + r * sin(a) - dd * 0.4, dd * 1.3, dd * 0.8), i, g)
                if n > 1 {
                    let m = ((Double(i) + 0.5) / nf * 360.0 - 90.0).toRadians
                    let s = (dd * 0.5).rustMax(8.0)
                    var sh = deco("leftRightArrow", Xfrm(cx + r * cos(m) - s / 2.0, cy + r * sin(m) - s * 0.2, s, s * 0.4), (Double(i) + 0.5) / nf * 360.0)
                    paint(d, &sh, i, true)
                    out.append((sh, []))
                }
            }
        case "cycleMatrix":
            // Cycle Matrix: four quarters of a circle in the middle with the top-level text, each quarter's
            // sub-points in a box at its corner.
            let s = area.h.rustMin(area.w)
            let (cx, cy) = (area.x + area.w / 2.0, area.y + area.h / 2.0)
            let c = s * 0.56
            let sxs = [-1.0, 1.0, 1.0, -1.0]
            let sys = [-1.0, -1.0, 1.0, 1.0]
            for (i, g) in gs.prefix(4).enumerated() {
                let (sx, sy) = (sxs[i], sys[i])
                let b = s * 0.4
                let bx = Xfrm(cx + (sx < 0.0 ? -s / 2.0 : s / 2.0 - b), cy + (sy < 0.0 ? -s / 2.0 : s / 2.0 - b), b, b)
                if g.count > 1 {
                    var sh = textShape("roundRect", bx, nodes(tail(g)), false)
                    paint(d, &sh, i, true)
                    if var body = sh.text {
                        // Text in the box's outer part, clear of the circle.
                        body.body.insetL = sx > 0.0 ? b * 0.35 : 6.0
                        body.body.insetR = sx < 0.0 ? b * 0.35 : 6.0
                        body.body.anchor = sy < 0.0 ? .top : .bottom
                        sh.text = body
                    }
                    out.append((sh, tail(g)))
                }
            }
            for (i, g) in gs.prefix(4).enumerated() {
                let (sx, sy) = (sxs[i], sys[i])
                let a0 = [180.0, 270.0, 0.0, 90.0][i] + 1.5
                var sh = deco("pie", Xfrm(cx - c / 2.0, cy - c / 2.0, c, c), 0.0)
                sh.geom = .preset(name: "pie", adj: [a0 * 60_000.0, (a0 + 87.0) * 60_000.0])
                paint(d, &sh, i, false)
                out.append((sh, []))
                let q = c * 0.3
                var t = textShape("rect", Xfrm(cx + sx * c * 0.2 - q / 2.0, cy + sy * c * 0.2 - q / 2.0, q, q), nodes(head(g)), true)
                paint(d, &t, i, false)
                clearBox(&t)
                out.append((t, head(g)))
            }
        case "segmentedPyramid":
            // Segmented Pyramid: a triangle cut into rows of triangles (1, 3, 5, …), one per node, every
            // other one upside down.
            let rows = max(ex(nf.squareRoot().rounded(.up)), 1)
            let s = area.h.rustMin(area.w / 1.15)
            let pw = s * 1.15
            let (x0, y0) = (area.x + (area.w - pw) / 2.0, area.y + (area.h - s) / 2.0)
            let (tw, th) = (pw / Double(rows), s / Double(rows))
            var k = 0
            rowsLoop: for r in 0 ..< rows {
                let left = x0 + pw / 2.0 - (Double(r) + 1.0) * tw / 2.0
                for c in 0 ..< (2 * r + 1) {
                    guard let g = gs.at(k) else { break rowsLoop }
                    let x = Xfrm(left + Double(c) * tw / 2.0, y0 + Double(r) * th, tw, th)
                    var sh = textShape("rect", x, nodes(g), true)
                    // Drawn as a polygon (not a flipped preset) so upside-down text stays upright.
                    let path = c % 2 == 1
                        ? "M 0 0 L \(f2(tw)) 0 L \(f2(tw / 2.0)) \(f2(th)) Z"
                        : "M \(f2(tw / 2.0)) 0 L \(f2(tw)) \(f2(th)) L 0 \(f2(th)) Z"
                    sh.geom = .custom(paths: [CustomPath(w: tw, h: th, d: path, fill: .norm, stroke: true)])
                    if var b = sh.text {
                        // The text in the triangle's wide half.
                        b.body.insetL = tw * 0.22
                        b.body.insetR = tw * 0.22
                        if c % 2 == 1 {
                            b.body.anchor = .top
                            b.body.insetB = th * 0.35
                        } else {
                            b.body.anchor = .bottom
                            b.body.insetT = th * 0.35
                        }
                        sh.text = b
                    }
                    paint(d, &sh, k, false)
                    out.append((sh, g))
                    k += 1
                }
            }
        case "verticalBoxList":
            // Vertical Box List: a pale box per node with its sub-points, its title on a tab overlapping the
            // box's top left.
            let h = area.h / nf
            for (i, g) in gs.enumerated() {
                let y = area.y + Double(i) * h
                let tabH = (h * 0.3).rustMin(40.0)
                var bx = textShape("rect", Xfrm(area.x, y + tabH / 2.0, area.w, h * 0.9 - tabH / 2.0), nodes(tail(g)), false)
                paint(d, &bx, i, true)
                if var b = bx.text {
                    b.body.insetT = tabH * 0.6
                    bx.text = b
                }
                out.append((bx, tail(g)))
                titled("roundRect", Xfrm(area.x + area.w * 0.05, y, area.w * 0.6, tabH), i, head(g))
            }
        case "trapezoidList", "tableList":
            // Trapezoid List: a column per node, each a trapezoid with its sub-points. Table List: the first
            // node as a header bar over a column per other node.
            let table = d.kind == "tableList"
            let headG: [Int]?
            let cols: [[Int]]
            if table {
                if let h = gs.first { (headG, cols) = (h, Array(gs.dropFirst())) } else { (headG, cols) = (nil, []) }
            } else {
                (headG, cols) = (nil, gs)
            }
            let top = headG != nil ? area.h * 0.28 : 0.0
            if let h = headG {
                titled("rect", Xfrm(area.x, area.y, area.w, top * 0.9), 0, h)
            }
            let m = Double(max(cols.count, 1))
            let w = area.w / m
            for (k, g) in cols.enumerated() {
                let i = k + (table ? 1 : 0)
                let x = Xfrm(area.x + Double(k) * w + w * 0.02, area.y + top, w * 0.96, area.h - top)
                var sh = textShape(table ? "rect" : "trapezoid", x, nodes(g), true)
                if var b = sh.text {
                    b.body.anchor = .top
                    if !table {
                        b.body.insetL = x.w * 0.2
                        b.body.insetR = x.w * 0.2
                        b.body.insetT = x.h * 0.08
                    }
                    sh.text = b
                }
                paint(d, &sh, i, table)
                out.append((sh, g))
            }
        case "accentProcess":
            // Accent Process: a title box per step with its sub-points in a pale box below and to the right,
            // arrows between the titles.
            let gap = area.w * 0.05
            let w = (area.w - gap * (nf - 1.0)) / nf
            for (i, g) in gs.enumerated() {
                let x = area.x + Double(i) * (w + gap)
                let th = area.h * 0.22
                if g.count > 1 {
                    var sh = textShape("rect", Xfrm(x + w * 0.12, area.y + th * 0.7, w * 0.88, area.h - th * 0.7), nodes(tail(g)), false)
                    paint(d, &sh, i, true)
                    if var b = sh.text {
                        b.body.insetT = th * 0.45
                        sh.text = b
                    }
                    out.append((sh, tail(g)))
                }
                titled("roundRect", Xfrm(x, area.y, w * 0.85, th), i, head(g))
                if i + 1 < n {
                    let a = gap * 0.8
                    arrow(Xfrm(x + w + (gap - a) / 2.0 - w * 0.07, area.y + th / 2.0 - a / 2.0, a, a), 0.0, i)
                }
            }
        case "continuousBlockProcess":
            // Continuous Block Process: one big pale arrow behind a row of boxes.
            var big = deco("rightArrow", Xfrm(area.x, area.y + area.h * 0.15, area.w, area.h * 0.7), 0.0)
            paint(d, &big, 0, true)
            out.append((big, []))
            let w = area.w * 0.85 / nf
            let h = area.h * 0.32
            for (i, g) in gs.enumerated() {
                let x = area.x + area.w * 0.02 + Double(i) * w
                titled("roundRect", Xfrm(x + w * 0.05, area.y + (area.h - h) / 2.0, w * 0.9, h), i, g)
            }
        case "bendingProcess":
            // Basic Bending Process: rows of boxes read left to right, wrapping, arrows between.
            let cols = min(max(ex((nf * area.w / area.h.rustMax(1.0) / 1.5).squareRoot().rounded(.up)), 1), n)
            let rows = (n + cols - 1) / cols
            let (cw, rh) = (area.w / Double(cols), area.h / Double(rows))
            let (bw, bh) = (cw * 0.72, (rh * 0.75).rustMin(cw * 0.72 * 0.6))
            for (i, g) in gs.enumerated() {
                let (c, r) = (i % cols, i / cols)
                let x = area.x + Double(c) * cw
                let y = area.y + Double(r) * rh + (rh - bh) / 2.0
                titled("rect", Xfrm(x, y, bw, bh), i, g)
                if i + 1 < n {
                    let a = (cw - bw) * 0.7
                    if c + 1 < cols {
                        arrow(Xfrm(x + bw + (cw - bw - a) / 2.0, y + bh / 2.0 - a / 2.0, a, a), 0.0, i)
                    } else {
                        // The bend: down from the row's last box towards the next row's first.
                        let a = (rh - bh).rustMin(a * 1.5).rustMax(6.0)
                        arrow(Xfrm(x + bw / 2.0 - a / 2.0, y + bh + (rh - bh - a) / 2.0, a, a), 90.0, i)
                    }
                }
            }
        case "linearVenn", "stackedVenn":
            // Linear Venn: overlapping circles in a row. Stacked Venn: circles nested from the bottom, the text
            // near each one's top.
            let linear = d.kind == "linearVenn"
            if linear {
                let dc = (area.w / (nf * 0.75 + 0.25)).rustMin(area.h)
                let step = dc * 0.75
                let x0 = area.x + (area.w - (step * (nf - 1.0) + dc)) / 2.0
                for (i, g) in gs.enumerated() {
                    var sh = textShape("ellipse", Xfrm(x0 + Double(i) * step, area.y + (area.h - dc) / 2.0, dc, dc), nodes(g), true)
                    paint(d, &sh, i, false)
                    if case .solid(let c)? = sh.fill { sh.fill = .solid(color: c.with(.alpha(55_000))) }
                    out.append((sh, g))
                }
            } else {
                let s = area.h.rustMin(area.w)
                let (cx, bottom) = (area.x + area.w / 2.0, area.y + (area.h + s) / 2.0)
                for i in gs.indices {
                    let dc = s * (1.0 - Double(i) / nf)
                    var sh = deco("ellipse", Xfrm(cx - dc / 2.0, bottom - dc, dc, dc), 0.0)
                    paint(d, &sh, i, false)
                    out.append((sh, []))
                }
                // Each circle's text in the band between its top and the next circle's.
                let band = s / nf
                for (i, g) in gs.enumerated() {
                    let dc = s * (1.0 - Double(i) / nf)
                    let top = bottom - dc
                    let h = i + 1 < n ? band : dc
                    let w = dc * (i + 1 < n ? 0.6 : 0.7)
                    var t = textShape("rect", Xfrm(cx - w / 2.0, top + (i + 1 < n ? band * 0.05 : 0.0), w, h * 0.9), nodes(g), true)
                    paint(d, &t, i, false)
                    clearBox(&t)
                    out.append((t, g))
                }
            }
        case "nestedTarget":
            // Nested Target: rounded boxes nested inside each other, the text on each one's top band.
            let bandX = area.w / 2.0 / nf * 0.6
            let bandY = area.h / nf * 0.9 / 2.0
            for i in gs.indices {
                let (dx, dy) = (bandX * Double(i), bandY * Double(i))
                var sh = deco("roundRect", Xfrm(area.x + dx, area.y + dy, area.w - 2.0 * dx, area.h - 2.0 * dy), 0.0)
                paint(d, &sh, i, false)
                out.append((sh, []))
            }
            for (i, g) in gs.enumerated() {
                let (dx, dy) = (bandX * Double(i), bandY * Double(i))
                let h = i + 1 < n ? bandY : area.h - 2.0 * dy
                var t = textShape("rect", Xfrm(area.x + dx + bandX * 0.3, area.y + dy, (area.w - 2.0 * dx - bandX * 0.6).rustMax(1.0), h), nodes(g), true)
                paint(d, &t, i, false)
                clearBox(&t)
                out.append((t, g))
            }
        case "gridMatrix":
            // Grid Matrix: four quadrants on crossed axes.
            let s = area.h.rustMin(area.w)
            let (x0, y0) = (area.x + (area.w - s) / 2.0, area.y + (area.h - s) / 2.0)
            let t = s * 0.06
            for (preset, x) in [("leftRightArrow", Xfrm(x0, y0 + (s - t) / 2.0, s, t)), ("upDownArrow", Xfrm(x0 + (s - t) / 2.0, y0, t, s))] {
                var sh = deco(preset, x, 0.0)
                paint(d, &sh, 0, true)
                out.append((sh, []))
            }
            let q = s / 2.0 - t * 1.2
            for (i, g) in gs.prefix(4).enumerated() {
                let (c, r) = (Double(i % 2), Double(i / 2))
                let x = Xfrm(x0 + c * (s / 2.0 + t * 0.7) + t * 0.5 * (1.0 - c), y0 + r * (s / 2.0 + t * 0.7) + t * 0.5 * (1.0 - r), q, q)
                titled("rect", x, i, g)
            }
        case "gear":
            // Gear: up to three interlocking gears, the first the biggest.
            let s = area.h.rustMin(area.w * 0.62)
            let (x0, y0) = (area.x + (area.w - s / 0.62) / 2.0, area.y + (area.h - s) / 2.0)
            let spots: [(Double, Double, Double, String)] = [(0.0, 0.18, 0.66, "gear9"), (0.5, 0.0, 0.48, "gear6"), (0.56, 0.48, 0.42, "gear6")]
            for (i, g) in gs.prefix(3).enumerated() {
                let (fx, fy, fs, preset) = spots[i]
                let z = s * fs
                titled(preset, Xfrm(x0 + fx * s * 1.3, y0 + fy * s, z, z), i, g)
            }
        case "funnel":
            // Funnel: the ideas poured in at the top (up to three), the last one coming out below.
            let s = area.h.rustMin(area.w)
            let (cx, y0) = (area.x + area.w / 2.0, area.y)
            let fw = s * 0.8
            let fh = s * 0.62
            var f = deco("funnel", Xfrm(cx - fw / 2.0, y0, fw, fh), 0.0)
            paint(d, &f, 0, true)
            out.append((f, []))
            let inside: [[Int]]
            let last: [Int]?
            if gs.count >= 2, let l = gs.last {
                (inside, last) = (Array(gs.dropLast()), l)
            } else {
                (inside, last) = (gs, nil)
            }
            let k = min(inside.count, 3)
            let dc = fw * 0.27
            let spots: [(Double, Double)] = [(0.0, 0.04), (-0.2, 0.3), (0.2, 0.3)]
            for (i, g) in inside.prefix(3).enumerated() {
                let (dx, dy) = k == 1 ? (0.0, 0.15) : spots[i]
                titled("ellipse", Xfrm(cx + dx * fw - dc / 2.0, y0 + dy * fh + fh * 0.05, dc, dc), i, g)
            }
            if let g = last {
                let a = s * 0.12
                var ar = deco("downArrow", Xfrm(cx - a / 2.0, y0 + fh, a, a * 1.2), 0.0)
                paint(d, &ar, k, true)
                out.append((ar, []))
                titled("roundRect", Xfrm(cx - fw * 0.35, y0 + fh + a * 1.3, fw * 0.7, (s - fh - a * 1.3).rustMax(10.0)), k, g)
            }
        case "pictureHList":
            // Horizontal Picture List: a column per node, a big picture over its text.
            let w = area.w / nf
            for (i, g) in gs.enumerated() {
                let x = area.x + Double(i) * w + w * 0.04
                let bw = w * 0.92
                let ph = area.h * 0.55
                out.append((pictureShape(d, "rect", Xfrm(x, area.y, bw, ph), i, first(g)), []))
                var sh = textShape("rect", Xfrm(x, area.y + ph, bw, area.h - ph), nodes(g), true)
                if var b = sh.text {
                    b.body.anchor = .top
                    sh.text = b
                }
                paint(d, &sh, i, false)
                out.append((sh, g))
            }
        case "timeline":
            // Basic Timeline: an arrow across the middle, a dot per node on it, the text above and below in
            // turn.
            let mid = area.y + area.h / 2.0
            let bar = (area.h * 0.08).rustMax(6.0)
            var sh = deco("rightArrow", Xfrm(area.x, mid - bar, area.w, bar * 2.0), 0.0)
            paint(d, &sh, 0, true)
            out.append((sh, []))
            let w = area.w * 0.92 / nf
            for (i, g) in gs.enumerated() {
                let cx = area.x + w * (Double(i) + 0.5)
                let dot = bar * 1.4
                var dsh = deco("ellipse", Xfrm(cx - dot / 2.0, mid - dot / 2.0, dot, dot), 0.0)
                paint(d, &dsh, i, false)
                out.append((dsh, []))
                let th = area.h / 2.0 - bar * 1.6
                let y = i % 2 == 0 ? area.y : mid + bar * 1.6
                var t = textShape("rect", Xfrm(cx - w * 0.48, y, w * 0.96, th.rustMax(1.0)), nodes(g), true)
                if var b = t.text {
                    b.body.anchor = i % 2 == 0 ? .bottom : .top
                    t.text = b
                }
                paint(d, &t, i, true)
                t.fill = .none_
                t.line = noLine
                out.append((t, g))
            }
        case "venn":
            // Basic Venn: see-through circles overlapping in a ring (two or three in a row/triangle).
            let s = area.h.rustMin(area.w)
            let (cx, cy) = (area.x + area.w / 2.0, area.y + area.h / 2.0)
            let dc = n == 1 ? s : s * 0.62
            let r = n == 1 ? 0.0 : (s - dc) / 2.0
            for (i, g) in gs.enumerated() {
                let a = (Double(i) / nf * 360.0 + (n == 2 ? 180.0 : -90.0)).toRadians
                var sh = textShape("ellipse", Xfrm(cx + r * cos(a) - dc / 2.0, cy + r * sin(a) - dc / 2.0, dc, dc), nodes(g), true)
                paint(d, &sh, i, false)
                if case .solid(let c)? = sh.fill { sh.fill = .solid(color: c.with(.alpha(50_000))) }
                if var b = sh.text {
                    // Text towards the circle's outer side, clear of the overlap.
                    let p = dc * 0.36
                    let (dx, dy) = (cos(a) * p, sin(a) * p)
                    b.body.insetL = (7.2 + dx).rustMax(2.0)
                    b.body.insetR = (7.2 - dx).rustMax(2.0)
                    b.body.insetT = (3.6 + dy).rustMax(2.0)
                    b.body.insetB = (3.6 - dy).rustMax(2.0)
                    sh.text = b
                }
                out.append((sh, g))
            }
        case "target":
            // Basic Target: nested rings, the outermost first, each ring's text in a box beside it with a line
            // from the ring.
            let s = area.h.rustMin(area.w * 0.5)
            let (cx, cy) = (area.x + s / 2.0, area.y + area.h / 2.0)
            let band = s / 2.0 / nf
            for i in gs.indices {
                let dc = s - 2.0 * band * Double(i)
                var sh = deco("ellipse", Xfrm(cx - dc / 2.0, cy - dc / 2.0, dc, dc), 0.0)
                paint(d, &sh, i, false)
                out.append((sh, []))
            }
            let tx = area.x + s + area.w * 0.06
            let rh = area.h / nf
            for (i, g) in gs.enumerated() {
                let ty = area.y + rh * (Double(i) + 0.5)
                // The point on ring i's band level with the text, else its top.
                let ry = cy - s / 2.0 + band * (Double(i) + 0.5)
                out.append((lineShape((cx, ry.rustMin(ty)), (tx, ty)), []))
                var t = textShape("rect", Xfrm(tx, ty - rh * 0.45, (area.x + area.w - tx).rustMax(1.0), rh * 0.9), nodes(g), true)
                paint(d, &t, i, true)
                t.fill = .none_
                t.line = noLine
                if var b = t.text {
                    for p in b.paragraphs.indices { b.paragraphs[p].props.align = .left }
                    t.text = b
                }
                out.append((t, g))
            }
        default:
            break
        }
        return out
    }

    /// Rust's `{:.2}`.
    private static func f2(_ v: Double) -> String { rustFixed(v, places: 2) }

    /// Rust's `f64::rem_euclid`.
    private static func remEuclid(_ a: Double, _ b: Double) -> Double {
        let r = a.rem(b)
        return r < 0.0 ? r + abs(b) : r
    }

    /// Each node's parent: the nearest node before it at a lower level.
    private static func parents(_ nodes: [DiagramNode]) -> [Int?] {
        var parent: [Int?] = Array(repeating: nil, count: nodes.count)
        var stack: [Int] = []
        for (i, n) in nodes.enumerated() {
            while let p = stack.last, nodes[p].level >= n.level { stack.removeLast() }
            parent[i] = stack.last
            stack.append(i)
        }
        return parent
    }

    /// Organization Chart: `hierarchy` with elbow connectors, and assistants beside their parent on a row of
    /// their own between the parent and its other children. `halfCircle` draws each node as its text in an
    /// open half ring (Half Circle Organization Chart).
    static func orgChart(_ d: Diagram, _ area: Xfrm) -> [Item] {
        let halfCircle = d.kind == "halfCircleOrgChart"
        let nameTitle = d.kind == "nameTitleOrgChart"
        let nodes = Array(d.nodes.prefix(maxShapes))
        if nodes.isEmpty { return [] }
        let parent = parents(nodes)
        func asst(_ i: Int) -> Bool { nodes[i].assistant && parent[i] != nil }
        func kids(_ i: Int?) -> [Int] { nodes.indices.filter { parent[$0] == i && !asst($0) } }
        var leaves = Array(repeating: 0, count: nodes.count)
        for i in nodes.indices.reversed() {
            let k = kids(i)
            leaves[i] = k.isEmpty ? 1 : k.reduce(0) { $0 + leaves[$1] }
        }
        // Row slots: a node's level is 2 per depth; assistants take the odd slot under their parent.
        var slot = Array(repeating: 0, count: nodes.count)
        for i in nodes.indices {
            if let p = parent[i] {
                slot[i] = asst(i) ? slot[p] + 1 : slot[p] + 2
            } else {
                slot[i] = 0
            }
        }
        let used = Array(Set(slot)).sorted()
        func row(_ i: Int) -> Int { used.firstIndex(of: slot[i]) ?? 0 }
        let rows = max(used.count, 1)
        let total = max(kids(nil).reduce(0) { $0 + leaves[$1] }, 1)
        let cellW = area.w / Double(total)
        let rowH = area.h / Double(rows)
        let (bw, bh) = ((cellW * 0.85).rustMin(area.w * 0.3), rowH * 0.62)
        var left = Array(repeating: 0, count: nodes.count)
        var nextRoot = 0
        for i in nodes.indices {
            if asst(i) { continue }
            var start: Int
            if let p = parent[i] {
                start = left[p]
                for s in kids(p) {
                    if s == i { break }
                    start += leaves[s]
                }
            } else {
                start = nextRoot
                nextRoot += leaves[i]
            }
            left[i] = start
        }
        let boxes: [Xfrm] = nodes.indices.map { i in
            let y = area.y + Double(row(i)) * rowH + (rowH - bh) / 2.0
            if let p = parent[i], asst(i) {
                // Assistants alternate right and left of the parent's trunk.
                let k = (0 ..< i).filter { parent[$0] == p && asst($0) }.count
                let pc = area.x + (Double(left[p]) + Double(leaves[p]) / 2.0) * cellW
                let off = bw * 0.15 + Double(k / 2) * bw * 1.1
                let x = k % 2 == 0 ? pc + off : pc - off - bw
                return Xfrm(x.clamped(area.x, area.x + area.w - bw), y, bw, bh)
            }
            let cx = area.x + (Double(left[i]) + Double(leaves[i]) / 2.0) * cellW
            return Xfrm(cx - bw / 2.0, y, bw, bh)
        }
        var out: [Item] = []
        for i in nodes.indices {
            guard let p = parent[i] else { continue }
            let (a, b) = (boxes[p], boxes[i])
            let pc = a.x + a.w / 2.0
            if asst(i) {
                let my = b.y + b.h / 2.0
                out.append((lineShape((pc, a.y + a.h), (pc, my)), []))
                let ex = b.x > pc ? b.x : b.x + b.w
                out.append((lineShape((pc, my), (ex, my)), []))
            } else {
                let mid = b.y - (rowH - bh) / 2.0
                let cc = b.x + b.w / 2.0
                out.append((lineShape((pc, a.y + a.h), (pc, mid)), []))
                out.append((lineShape((pc.rustMin(cc), mid), (pc.rustMax(cc), mid)), []))
                out.append((lineShape((cc, mid), (cc, b.y)), []))
            }
        }
        for (i, n) in nodes.enumerated() {
            let depth = slot[i] / 2
            if halfCircle {
                // Two half rings round the text: the upper left one in the accent, the lower right one in its
                // tint.
                let x = boxes[i]
                for (k, (a0, a1)) in [(140.0, 310.0), (320.0, 130.0)].enumerated() {
                    var arc = deco("blockArc", x, 0.0)
                    arc.geom = .preset(name: "blockArc", adj: [a0 * 60_000.0, a1 * 60_000.0, 4_000.0])
                    paint(d, &arc, depth, false)
                    if k == 1 {
                        let c = ColorRef.scheme(accent(d, depth)).with(.lumMod(60_000)).with(.lumOff(40_000))
                        arc.fill = .solid(c)
                    }
                    arc.line = noLine
                    arc.effects = nil
                    out.append((arc, []))
                }
                var t = textShape("rect", x, [n], true)
                paint(d, &t, depth, true)
                t.fill = .none_
                t.line = noLine
                out.append((t, [i]))
            } else {
                var x = boxes[i]
                if nameTitle {
                    // The name in the upper part; the title box overlaps the lower edge.
                    x.h *= 0.85
                }
                var sh = textShape("rect", x, [n], true)
                paint(d, &sh, depth, false)
                out.append((sh, [i]))
                if nameTitle {
                    let tb = Xfrm(x.x + x.w * 0.12, x.y + x.h * 0.72, x.w * 0.8, x.h * 0.42)
                    let title = DiagramNode(text: n.title)
                    var t = textShape("rect", tb, [title], true)
                    paint(d, &t, depth, true)
                    t.fill = .solid(.scheme(.lt1))
                    if var b = t.text {
                        for p in b.paragraphs.indices {
                            for r in b.paragraphs[p].runs.indices { b.paragraphs[p].runs[r].props.size = 11.0 }
                            b.paragraphs[p].endProps.size = 11.0
                        }
                        t.text = b
                    }
                    out.append((t, []))
                }
            }
        }
        return out
    }

    /// An organisation chart: one box per node, rows by level, each subtree as wide as its leaves.
    static func hierarchy(_ d: Diagram, _ area: Xfrm, _ horizontal: Bool) -> [Item] {
        let nodes = Array(d.nodes.prefix(maxShapes))
        if nodes.isEmpty { return [] }
        let parent = parents(nodes)
        func kids(_ i: Int?) -> [Int] { nodes.indices.filter { parent[$0] == i } }
        var leaves = Array(repeating: 0, count: nodes.count)
        for i in nodes.indices.reversed() {
            let k = kids(i)
            leaves[i] = k.isEmpty ? 1 : k.reduce(0) { $0 + leaves[$1] }
        }
        let depth: [Int] = nodes.indices.map { i in
            var dd = 0
            var p = parent[i]
            while let q = p {
                dd += 1
                p = parent[q]
            }
            return dd
        }
        let rows = (depth.max() ?? 0) + 1
        let total = max(kids(nil).reduce(0) { $0 + leaves[$1] }, 1)
        // Horizontal Hierarchy: the same tree turned a quarter, levels from left to right.
        let (span, across) = horizontal ? (area.h, area.w) : (area.w, area.h)
        let cellW = span / Double(total)
        let rowH = across / Double(rows)
        let (bw, bh) = horizontal ? (cellW * 0.8, rowH * 0.7) : (cellW * 0.85, rowH * 0.6)
        // Left edge (in leaves) of each node's span.
        var left = Array(repeating: 0, count: nodes.count)
        var nextRoot = 0
        for i in nodes.indices {
            var start: Int
            if let p = parent[i] {
                start = left[p]
                for s in kids(p) {
                    if s == i { break }
                    start += leaves[s]
                }
            } else {
                start = nextRoot
                nextRoot += leaves[i]
            }
            left[i] = start
        }
        let boxes: [Xfrm] = nodes.indices.map { i in
            let c = (Double(left[i]) + Double(leaves[i]) / 2.0) * cellW
            let r = Double(depth[i]) * rowH + (rowH - bh) / 2.0
            return horizontal ? Xfrm(area.x + r, area.y + c - bw / 2.0, bh, bw) : Xfrm(area.x + c - bw / 2.0, area.y + r, bw, bh)
        }
        var out: [Item] = nodes.enumerated().map { i, n in
            var sh = textShape("roundRect", boxes[i], [n], true)
            paint(d, &sh, depth[i], false)
            return (sh, [i])
        }
        for i in nodes.indices {
            guard let p = parent[i] else { continue }
            let (a, b) = (boxes[p], boxes[i])
            let (pp, q) = horizontal
                ? ((a.x + a.w, a.y + a.h / 2.0), (b.x, b.y + b.h / 2.0))
                : ((a.x + a.w / 2.0, a.y + a.h), (b.x + b.w / 2.0, b.y))
            out.append((lineShape(pp, q), []))
        }
        return out
    }

    // MARK: - Finding the graphic

    /// The SmartArt group that `id` is, or is inside.
    static func diagramGroup(_ shapes: [Shape], _ id: ShapeId, _ depth: Int = 0) -> Shape? {
        if depth > 64 { return nil }
        for sh in shapes {
            if sh.id == id && sh.diagram != nil { return sh }
            if case .group(let children, _) = sh.kind {
                if sh.diagram != nil && findShape(children, id) != nil { return sh }
                if let g = diagramGroup(children, id, depth + 1) { return g }
            }
        }
        return nil
    }

    /// The SmartArt graphic the selection is (or is inside), with its outline as the Text Pane shows it.
    public static func selected(_ st: DocState) -> (ShapeId, Diagram)? {
        guard let shapes = Cmd.currentShapes(st.doc, st.selection) else { return nil }
        guard let g = st.selection.shapes.lazy.compactMap({ diagramGroup(shapes, $0) }).first, var d = g.diagram else { return nil }
        if case .group(let children, _) = g.kind { syncText(&d, children) }
        return (g.id, d)
    }

    static func targetGroup(_ s: Session, _ p: JSON, _ cmd: String) throws -> ShapeId {
        let st = try s.doc()
        guard let shapes = Cmd.currentShapes(st.doc, st.selection) else { throw Cmd.bad(cmd, "no slide") }
        let ids = try Cmd.targets(s, p)
        guard let g = ids.lazy.compactMap({ diagramGroup(shapes, $0) }).first else { throw Cmd.bad(cmd, "select a SmartArt graphic") }
        return g.id
    }

    /// Children with fresh ids for diagram `d` inside a group whose child space is `area`.
    static func regenerate(_ cmd: String, _ doc: inout Presentation, _ d: Diagram, _ area: Xfrm) throws -> [Shape] {
        var v = layout(d, area)
        for k in v.indices {
            guard let id = doc.allocId() else { throw Cmd.bad(cmd, Cmd.noIdSpace) }
            v[k].id = ShapeId(id)
        }
        return v
    }

    /// Read the diagram (with typed text synced), let `f` change it, and regenerate the group.
    static func editDiagram<T>(_ s: Session, _ p: JSON, _ cmd: String, _ f: (inout Diagram) throws -> T) throws -> T {
        let gid = try targetGroup(s, p, cmd)
        return try s.edit { doc, sel in
            guard let g = Cmd.currentShapes(doc, sel).flatMap({ findShape($0, gid) }) else { throw Cmd.bad(cmd, "no such shape") }
            guard case .group(let children, let child) = g.kind, var d = g.diagram else { throw Cmd.bad(cmd, "not a SmartArt graphic") }
            syncText(&d, children)
            let out = try f(&d)
            normalize(&d.nodes)
            d.imported = false
            let kids = try regenerate(cmd, &doc, d, child)
            let found = try withShapes(&doc, sel, missing: Cmd.bad(cmd, "no slide")) { (shapes: inout [Shape]) -> Bool in
                let hit: Void? = withShape(&shapes, gid) { (sh: inout Shape) in
                    sh.kind = .group(children: kids, child: child)
                    sh.diagram = d
                }
                return hit != nil
            }
            if !found { throw Cmd.bad(cmd, "no such shape") }
            sel.shapes = [gid]
            sel.text = nil
            return out
        }
    }

    static func index(_ p: JSON, _ cmd: String) throws -> Int {
        guard let v = p.get("index")?.asU64, let i = Int(exactly: v) else { throw Cmd.bad(cmd, "index is required") }
        return i
    }

    /// Insert a new SmartArt graphic (`insert.smartArt`).
    public static func insert(_ s: Session, _ kind: String, _ nodes: [DiagramNode]) throws -> JSON {
        let kind = isKind(kind) ? kind : "process"
        var nodes = nodes
        if nodes.isEmpty {
            nodes = (0 ..< 3).map { _ in DiagramNode(text: "Text", level: 0, picture: nil, assistant: false, title: "") }
        }
        normalize(&nodes)
        let d = Diagram(kind: kind, nodes: nodes)
        let size = try s.doc().doc.slideSize
        let area = Xfrm(size.width * 0.1, size.height * 0.28, size.width * 0.8, size.height * 0.6)
        let id: ShapeId = try s.edit { doc, sel in
            let children = try regenerate("insert.smartArt", &doc, d, area)
            guard let raw = doc.allocId() else { throw Cmd.bad("insert.smartArt", Cmd.noIdSpace) }
            let id = ShapeId(raw)
            var g = Shape.default
            g.id = id
            g.name = "SmartArt (\(kind))"
            g.xfrm = area
            g.kind = .group(children: children, child: area)
            g.diagram = d
            try withShapes(&doc, sel, missing: EngineError.other("no slide")) { $0.append(g) }
            sel.shapes = [id]
            sel.text = nil
            return id
        }
        return ["id": .integer(id.rawValue)]
    }

    // MARK: - Commands

    @Sendable static func nodesCmd(_ s: Session, _ p: JSON) throws -> JSON {
        let gid = try targetGroup(s, p, "smartArt.nodes")
        let g = try Cmd.shapeOf(s, gid)
        var d = g.diagram ?? Diagram.default
        if case .group(let children, _) = g.kind { syncText(&d, children) }
        return ["id": .integer(gid.rawValue), "kind": .string(d.kind), "nodes": d.nodes.toJSON()]
    }

    @Sendable static func setNodes(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "smartArt.setNodes"
        var given: [DiagramNode]?
        if let v = p.get("nodes") {
            do { given = try [DiagramNode](fromJSON: v) } catch { throw Cmd.bad(cmd, error.description) }
        } else if let a = p.get("lines")?.asArray {
            given = nodesFromLines(a.compactMap(\.asStr))
        }
        let one: Int? = try p.get("index") != nil ? index(p, cmd) : nil
        let text = Cmd.strParam(p, "text")
        let title = Cmd.strParam(p, "title")
        return try editDiagram(s, p, cmd) { d in
            if let n = given { d.nodes = n }
            if let i = one, let t = text {
                guard i < d.nodes.count else { throw Cmd.bad(cmd, "no such node") }
                d.nodes[i].text = t
            }
            if let i = one, let t = title {
                guard i < d.nodes.count else { throw Cmd.bad(cmd, "no such node") }
                d.nodes[i].title = t
            }
            return .null
        }
    }

    @Sendable static func addNode(_ s: Session, _ p: JSON) throws -> JSON {
        let i = p.get("index")?.asU64.flatMap { Int(exactly: $0) }
        let pos = Cmd.strParam(p, "position") ?? "after"
        let text = Cmd.strParam(p, "text") ?? ""
        return try editDiagram(s, p, "smartArt.addNode") { d in
            let at = add(&d.nodes, i, pos, text)
            return ["index": .integer(at)]
        }
    }

    @Sendable static func removeNode(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "smartArt.removeNode"
        let i = try index(p, cmd)
        return try editDiagram(s, p, cmd) { d in
            if remove(&d.nodes, i) { return .null }
            throw Cmd.bad(cmd, "no such node")
        }
    }

    @Sendable static func promote(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "smartArt.promote"
        let i = try index(p, cmd)
        return try editDiagram(s, p, cmd) { d in
            if promoteNode(&d.nodes, i) { return .null }
            throw Cmd.bad(cmd, "already at the top level")
        }
    }

    @Sendable static func demote(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "smartArt.demote"
        let i = try index(p, cmd)
        return try editDiagram(s, p, cmd) { d in
            if demoteNode(&d.nodes, i) { return .null }
            throw Cmd.bad(cmd, "nothing above to demote under")
        }
    }

    /// Convert to SmartArt: the selected text shape's paragraphs become the nodes of a new graphic in the
    /// shape's place.
    @Sendable static func fromText(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "smartArt.fromText"
        let kind = Cmd.strParam(p, "kind").flatMap { isKind($0) ? $0 : nil } ?? "list"
        guard let id = try Cmd.targets(s, p).first else { throw Cmd.bad(cmd, "select a text box") }
        let area: Xfrm
        let nodes: [DiagramNode]
        do {
            let st = try s.doc()
            guard let shapes = Cmd.currentShapes(st.doc, st.selection) else { throw Cmd.bad(cmd, "no slide") }
            guard let sh = shapes.first(where: { $0.id == id }) else { throw Cmd.bad(cmd, "select a text box on the slide") }
            guard let body = sh.text, body.paragraphs.contains(where: { !rustTrim($0.text).isEmpty }) else { throw Cmd.bad(cmd, "the shape has no text") }
            var ns: [DiagramNode] = body.paragraphs.filter { !rustTrim($0.text).isEmpty }.map {
                DiagramNode(text: String(rustTrim($0.text)), level: min($0.level, maxLevel))
            }
            normalize(&ns)
            // A small text box grows to a size a diagram can use, keeping its top left on the slide.
            var a = Cmd.xfrmOf(st.doc, st.selection, sh)
            let size = st.doc.slideSize
            a.w = a.w.rustMax(size.width * 0.5).rustMin(size.width)
            a.h = a.h.rustMax(size.height * 0.35).rustMin(size.height)
            a.x = a.x.rustMin(size.width - a.w).rustMax(0.0)
            a.y = a.y.rustMin(size.height - a.h).rustMax(0.0)
            a.rot = 0.0
            (area, nodes) = (a, ns)
        }
        let d = Diagram(kind: kind, nodes: nodes)
        let gid: ShapeId = try s.edit { doc, sel in
            let children = try regenerate(cmd, &doc, d, area)
            guard let raw = doc.allocId() else { throw Cmd.bad(cmd, Cmd.noIdSpace) }
            let gid = ShapeId(raw)
            var g = Shape.default
            g.id = gid
            g.name = "SmartArt (\(kind))"
            g.xfrm = area
            g.kind = .group(children: children, child: area)
            g.diagram = d
            try withShapes(&doc, sel, missing: Cmd.bad(cmd, "no slide")) { shapes in
                guard let at = shapes.firstIndex(where: { $0.id == id }) else { throw Cmd.bad(cmd, "no such shape") }
                // In the text shape's place in the z-order.
                shapes[at] = g
            }
            sel.shapes = [gid]
            sel.text = nil
            return gid
        }
        return ["id": .integer(gid.rawValue)]
    }

    /// Convert to Text: a text box with the outline, one bulleted paragraph per node.
    @Sendable static func toText(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "smartArt.toText"
        let gid = try targetGroup(s, p, cmd)
        guard let (_, d) = selectedFor(s, gid) else { throw Cmd.bad(cmd, "select a SmartArt graphic") }
        // The sizes the graphic's text shows at: its titles' and its bullets' (shrunk to fit included).
        let titlePt: Double
        let bulletPt: Double
        do {
            let st = try s.doc()
            guard let shapes = Cmd.currentShapes(st.doc, st.selection) else { throw Cmd.bad(cmd, "no slide") }
            guard let g = diagramGroup(shapes, gid) else { throw Cmd.bad(cmd, "select a SmartArt graphic") }
            (titlePt, bulletPt) = textSizes(g.children)
        }
        let new: ShapeId = try s.edit { doc, sel in
            let found = try withShapes(&doc, sel, missing: Cmd.bad(cmd, "no slide")) { shapes -> (Int, Xfrm)? in
                guard let at = shapes.firstIndex(where: { $0.id == gid }) else { return nil }
                return (at, shapes[at].xfrm ?? Xfrm())
            }
            guard let (at, area) = found else { throw Cmd.bad(cmd, "the graphic isn't at the top of the slide") }
            var body = TextBody.default
            for n in d.nodes {
                var para = Paragraph(n.text)
                para.level = min(n.level, maxLevel)
                let size = n.level == 0 ? titlePt : bulletPt
                for r in para.runs.indices { para.runs[r].props.size = size }
                para.endProps.size = size
                para.props.bullet = .char(char: "•")
                para.props.marginLeft = 18.0 * (Double(para.level) + 1.0)
                para.props.indent = -14.0
                body.paragraphs.append(para)
            }
            if body.paragraphs.isEmpty { body.paragraphs.append(Paragraph("")) }
            body.body.wrap = true
            body.body.autofit = .shrink(fontScale: 1.0, lineReduction: 0.0)
            guard let raw = doc.allocId() else { throw Cmd.bad(cmd, Cmd.noIdSpace) }
            let id = ShapeId(raw)
            var tb = Shape.default
            tb.id = id
            tb.name = "Text"
            tb.xfrm = area
            tb.textBox = true
            tb.text = body
            tb.geom = .preset("rect")
            try withShapes(&doc, sel, missing: Cmd.bad(cmd, "no slide")) { shapes in
                guard at < shapes.count else { throw Cmd.bad(cmd, "no slide") }
                shapes[at] = tb
            }
            sel.shapes = [id]
            sel.text = nil
            return id
        }
        return ["id": .integer(new.rawValue)]
    }

    /// Convert to Shapes: keep the drawing as an ordinary group.
    @Sendable static func toShapes(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "smartArt.toShapes"
        let gid = try targetGroup(s, p, cmd)
        try s.edit { doc, sel in
            let found = try withShapes(&doc, sel, missing: Cmd.bad(cmd, "no slide")) { (shapes: inout [Shape]) -> Bool in
                let hit: Void? = withShape(&shapes, gid) { (g: inout Shape) in
                    g.diagram = nil
                    g.name = "Group"
                }
                return hit != nil
            }
            if !found { throw Cmd.bad(cmd, "no such shape") }
            sel.shapes = [gid]
        }
        return .null
    }

    /// The most common title and bullet font sizes in a diagram's shapes (20 and 14 pt when none).
    static func textSizes(_ children: [Shape]) -> (Double, Double) {
        var titles: [Double] = []
        var bullets: [Double] = []
        for c in children {
            guard let b = c.text else { continue }
            for p in b.paragraphs {
                guard let sz = p.runs.lazy.compactMap({ $0.props.size }).first else { continue }
                if p.props.bullet != nil { bullets.append(sz) } else { titles.append(sz) }
            }
        }
        func mode(_ v: [Double], _ d: Double) -> Double {
            let v = v.sorted { totalLess($0, $1) }
            var best = (d, 0)
            var k = 0
            while k < v.count {
                let vk = v[k]
                let j = v[k...].prefix { abs($0 - vk) < 1e-9 }.count
                if j > best.1 { best = (vk, j) }
                k += max(j, 1)
            }
            return best.0
        }
        return (mode(titles, 20.0), mode(bullets, 14.0))
    }

    /// `f64::total_cmp` as a less-than.
    private static func totalLess(_ a: Double, _ b: Double) -> Bool {
        func key(_ x: Double) -> Int64 {
            let bits = Int64(bitPattern: x.bitPattern)
            return bits ^ Int64(bitPattern: UInt64(bitPattern: bits >> 63) >> 1)
        }
        return key(a) < key(b)
    }

    /// The graphic `gid` with its outline (typed text synced).
    static func selectedFor(_ s: Session, _ gid: ShapeId) -> (ShapeId, Diagram)? {
        guard let st = s.activeDoc, let shapes = Cmd.currentShapes(st.doc, st.selection), let g = diagramGroup(shapes, gid), var d = g.diagram else { return nil }
        if case .group(let children, _) = g.kind { syncText(&d, children) }
        return (g.id, d)
    }

    @Sendable static func setPicture(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "smartArt.picture"
        let i = try index(p, cmd)
        var media: MediaId?
        if !Cmd.boolOr(p, "reset", false) {
            let (name, bytes) = try InsertCommands.mediaBytes(p, cmd)
            let ct = InsertCommands.contentType(name, bytes)
            _ = try targetGroup(s, p, cmd)
            media = try s.edit { doc, _ in
                guard let m = doc.addMedia(name, ct, bytes) else { throw Cmd.bad(cmd, Cmd.noIdSpace) }
                return m
            }
        }
        return try editDiagram(s, p, cmd) { d in
            // A sub-point's picture is its top-level node's: that's the node the placeholder shows.
            let hi = min(i, max(d.nodes.count - 1, 0))
            let top = (0 ... hi).reversed().first { d.nodes.at($0)?.level == 0 } ?? i
            guard top >= 0, top < d.nodes.count else { throw Cmd.bad(cmd, "no such node") }
            d.nodes[top].picture = media
            return .null
        }
    }

    @Sendable static func changeStyle(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "smartArt.style"
        guard let v = Cmd.strParam(p, "style"), styles.contains(where: { $0.0 == v }) else { throw Cmd.bad(cmd, "unknown style") }
        return try editDiagram(s, p, cmd) { d in
            if d.style != v { d.styleXml = nil }
            d.style = v
            return .null
        }
    }

    @Sendable static func changeColors(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "smartArt.colors"
        guard let v = Cmd.strParam(p, "colors"), colors.contains(where: { $0.0 == v }) else { throw Cmd.bad(cmd, "unknown colours") }
        return try editDiagram(s, p, cmd) { d in
            if d.colors != v { d.colorsXml = nil }
            d.colors = v
            return .null
        }
    }

    @Sendable static func changeLayout(_ s: Session, _ p: JSON) throws -> JSON {
        let cmd = "smartArt.layout"
        guard let kind = Cmd.strParam(p, "kind"), isKind(kind) else { throw Cmd.bad(cmd, "unknown layout") }
        return try editDiagram(s, p, cmd) { d in
            if d.kind != kind {
                // PowerPoint's own layout no longer applies.
                d.layoutId = ""
                d.layoutXml = nil
            }
            d.kind = kind
            return .null
        }
    }
}

private extension UInt8 {
    func subSat(_ b: UInt8) -> UInt8 { self > b ? self - b : 0 }
}

private extension Int {
    var toU8: UInt8 { UInt8(clamping: self) }
}
