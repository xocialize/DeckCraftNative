// DCGeometry — preset shape geometry. Port of deckcraft crates/geom/src/preset.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
//
// Each preset is identified by its Office Open XML name (`rect`, `roundRect`, `rightArrow`…) so files
// round-trip, but every outline is deckcraft's own construction, re-derived from what the shapes look
// like and what their adjust values mean, not from any reference geometry table. Adjust values use the
// file convention: ratios in 1/100 000 of the shorter side (or of the width/height), angles in 1/60 000
// degree.
import DCCore
import Darwin

/// How a sub-path is filled. `lighten`/`darken` variants shade the shape's fill (3-D looking faces).
public enum FillMode: String, JSONStringEnum, Sendable {
    case norm
    case none
    case lighten
    case lightenLess
    case darken
    case darkenLess
}

/// Rust's `preset` module.
public enum Preset {
    public struct SubPath: Sendable, Hashable {
        public var path: BezPath
        public var fill: FillMode
        public var stroke: Bool
        /// Even-odd fill (holes in donuts and frames).
        public var evenOdd: Bool

        public init(path: BezPath, fill: FillMode, stroke: Bool, evenOdd: Bool) {
            self.path = path
            self.fill = fill
            self.stroke = stroke
            self.evenOdd = evenOdd
        }
    }

    /// A draggable adjust handle (the yellow dot). `pos = origin + dir * value`; dragging projects the
    /// pointer onto `dir`. An `angle` handle instead measures the pointer's angle about `origin`
    /// (1/60 000 degree, y down, 0° at +x).
    public struct Handle: Sendable, Hashable {
        public var index: Int
        public var pos: Point
        public var origin: Point
        public var dir: Vec2
        public var min: Double
        public var max: Double
        public var angle: Bool

        public init(index: Int, pos: Point, origin: Point, dir: Vec2, min: Double, max: Double, angle: Bool) {
            self.index = index
            self.pos = pos
            self.origin = origin
            self.dir = dir
            self.min = min
            self.max = max
            self.angle = angle
        }

        static func new(_ index: Int, _ origin: Point, _ dir: Vec2, _ value: Double, _ min: Double, _ max: Double) -> Handle {
            Handle(index: index, pos: origin + dir * value, origin: origin, dir: dir, min: min, max: max, angle: false)
        }

        /// An angle handle on the `rx`×`ry` ellipse around `center` at visual angle `value`.
        static func angle(_ index: Int, _ center: Point, _ rx: Double, _ ry: Double, _ value: Double) -> Handle {
            let t = vis(value / 60000.0, rx, ry).radians
            let pos = Point(center.x + rx * sinCos(t).cos, center.y + ry * sinCos(t).sin)
            return Handle(index: index, pos: pos, origin: center, dir: .zero, min: 0.0, max: 21_600_000.0, angle: true)
        }

        /// The adjust value for a pointer at `p` (shape-local space).
        public func valueAt(_ p: Point) -> Double {
            if angle {
                let d = p - origin
                if !(d.x.isFinite && d.y.isFinite) || d.hypot < 1e-9 { return min }
                let v = (Darwin.atan2(d.y, d.x).degrees.remEuclid(360.0) * 60000.0).rounded()
                return v >= max ? min : v
            }
            let l2 = dir.hypot2
            if l2 < 1e-18 { return min }
            let v = (p - origin).dot(dir) / l2
            if !v.isFinite { return min }
            return v.clamp(fmin(min, max), fmax(max, min)).rounded()
        }
    }

    public struct Geometry: Sendable, Hashable {
        public var paths: [SubPath]
        /// Where text goes, in shape-local space.
        public var textRect: Rect
        public var handles: [Handle]
        /// Connector glue points, shape-local.
        public var sites: [Point]

        public init(paths: [SubPath], textRect: Rect, handles: [Handle], sites: [Point]) {
            self.paths = paths
            self.textRect = textRect
            self.handles = handles
            self.sites = sites
        }

        /// The union outline used for hit testing and selection (all filled or stroked sub-paths).
        public var outline: BezPath {
            var p = BezPath()
            for s in paths { p.extend(s.path.elements) }
            return p
        }

        /// Whether nothing is filled (lines, connectors, arcs, brackets).
        public var isOpen: Bool { paths.allSatisfy { $0.fill == .none } }
    }

    /// Gallery category, as in the Shapes menu.
    public enum Category: String, JSONStringEnum, Sendable {
        case lines
        case rectangles
        case basicShapes
        case blockArrows
        case equationShapes
        case flowchart
        case starsAndBanners
        case callouts
        case actionButtons

        public static let all: [Category] = allCases

        public var label: String {
            switch self {
            case .lines: "Lines"
            case .rectangles: "Rectangles"
            case .basicShapes: "Basic Shapes"
            case .blockArrows: "Block Arrows"
            case .equationShapes: "Equation Shapes"
            case .flowchart: "Flowchart"
            case .starsAndBanners: "Stars and Banners"
            case .callouts: "Callouts"
            case .actionButtons: "Action Buttons"
            }
        }
    }

    public struct Info: Sendable, Hashable {
        public var name: String
        public var label: String
        public var category: Category
        /// Default adjust values.
        public var defaults: [Double]
    }

    private static func p(_ n: String, _ l: String, _ c: Category, _ d: [Double] = []) -> Info {
        Info(name: n, label: l, category: c, defaults: d)
    }

    /// Every preset deckcraft generates, in gallery order.
    public static let catalog: [Info] = [
        p("line", "Line", .lines),
        p("straightConnector1", "Arrow", .lines),
        p("bentConnector3", "Connector: Elbow", .lines, [50000]),
        p("curvedConnector3", "Connector: Curved", .lines, [50000]),
        p("bentConnector2", "Connector: Elbow (one bend)", .lines),
        p("lineInv", "Line: Rising", .lines),
        p("rect", "Rectangle", .rectangles),
        p("roundRect", "Rectangle: Rounded Corners", .rectangles, [16667]),
        p("snip1Rect", "Rectangle: Single Corner Snipped", .rectangles, [16667]),
        p("snip2SameRect", "Rectangle: Top Corners Snipped", .rectangles, [16667, 0]),
        p("snip2DiagRect", "Rectangle: Diagonal Corners Snipped", .rectangles, [0, 16667]),
        p("snipRoundRect", "Rectangle: Top Corners One Rounded and One Snipped", .rectangles, [16667, 16667]),
        p("round1Rect", "Rectangle: Single Corner Rounded", .rectangles, [16667]),
        p("round2SameRect", "Rectangle: Top Corners Rounded", .rectangles, [16667, 0]),
        p("round2DiagRect", "Rectangle: Diagonal Corners Rounded", .rectangles, [16667, 0]),
        p("textBox", "Text Box", .basicShapes),
        p("ellipse", "Oval", .basicShapes),
        p("triangle", "Isosceles Triangle", .basicShapes, [50000]),
        p("rtTriangle", "Right Triangle", .basicShapes),
        p("parallelogram", "Parallelogram", .basicShapes, [25000]),
        p("trapezoid", "Trapezoid", .basicShapes, [25000]),
        p("nonIsoscelesTrapezoid", "Trapezoid: Uneven Sides", .basicShapes, [25000, 25000]),
        p("diamond", "Diamond", .basicShapes),
        p("pentagon", "Regular Pentagon", .basicShapes),
        p("hexagon", "Hexagon", .basicShapes, [25000]),
        p("heptagon", "Heptagon", .basicShapes),
        p("octagon", "Octagon", .basicShapes, [29289]),
        p("decagon", "Decagon", .basicShapes),
        p("dodecagon", "Dodecagon", .basicShapes),
        p("pie", "Partial Circle", .basicShapes, [0, 16_200_000]),
        p("pieWedge", "Quarter Wedge", .basicShapes),
        p("chord", "Chord", .basicShapes, [2_700_000, 16_200_000]),
        p("teardrop", "Teardrop", .basicShapes, [100_000]),
        p("frame", "Frame", .basicShapes, [12500]),
        p("cornerTabs", "Corner Tabs: Triangles", .basicShapes),
        p("squareTabs", "Corner Tabs: Squares", .basicShapes),
        p("plaqueTabs", "Corner Tabs: Quarter Circles", .basicShapes),
        p("halfFrame", "Half Frame", .basicShapes, [33333, 33333]),
        p("corner", "L-Shape", .basicShapes, [50000, 50000]),
        p("diagStripe", "Diagonal Stripe", .basicShapes, [50000]),
        p("plus", "Cross", .basicShapes, [25000]),
        p("plaque", "Plaque", .basicShapes, [16667]),
        p("can", "Cylinder", .basicShapes, [25000]),
        p("cube", "Cube", .basicShapes, [25000]),
        p("bevel", "Bevel", .basicShapes, [12500]),
        p("donut", "Donut", .basicShapes, [25000]),
        p("noSmoking", "\"Not Allowed\" Symbol", .basicShapes, [18750]),
        p("blockArc", "Block Arc", .basicShapes, [10_800_000, 0, 25000]),
        p("foldedCorner", "Folded Corner", .basicShapes, [16667]),
        p("smileyFace", "Smiley Face", .basicShapes, [4653]),
        p("heart", "Heart", .basicShapes),
        p("lightningBolt", "Lightning Bolt", .basicShapes),
        p("sun", "Sun", .basicShapes, [25000]),
        p("moon", "Moon", .basicShapes, [50000]),
        p("cloud", "Cloud", .basicShapes),
        p("gear6", "Gear: 6 Teeth", .basicShapes, [15000, 3526]),
        p("gear9", "Gear: 9 Teeth", .basicShapes, [10000, 1763]),
        p("funnel", "Funnel", .basicShapes),
        p("arc", "Arc", .basicShapes, [16_200_000, 0]),
        p("bracketPair", "Double Bracket", .basicShapes, [16667]),
        p("bracePair", "Double Brace", .basicShapes, [8333]),
        p("leftBracket", "Left Bracket", .basicShapes, [8333]),
        p("rightBracket", "Right Bracket", .basicShapes, [8333]),
        p("leftBrace", "Left Brace", .basicShapes, [8333, 50000]),
        p("rightBrace", "Right Brace", .basicShapes, [8333, 50000]),
        p("chartX", "Chart Marker: Cross Lines", .basicShapes),
        p("chartStar", "Chart Marker: Star Lines", .basicShapes),
        p("chartPlus", "Chart Marker: Plus Lines", .basicShapes),
        p("rightArrow", "Arrow: Right", .blockArrows, [50000, 50000]),
        p("leftArrow", "Arrow: Left", .blockArrows, [50000, 50000]),
        p("upArrow", "Arrow: Up", .blockArrows, [50000, 50000]),
        p("downArrow", "Arrow: Down", .blockArrows, [50000, 50000]),
        p("leftRightArrow", "Arrow: Left-Right", .blockArrows, [50000, 50000]),
        p("upDownArrow", "Arrow: Up-Down", .blockArrows, [50000, 50000]),
        p("quadArrow", "Arrow: Quad", .blockArrows, [22500, 22500, 22500]),
        p("leftRightUpArrow", "Arrow: Left-Right-Up", .blockArrows, [25000, 25000, 25000]),
        p("bentArrow", "Arrow: Bent", .blockArrows, [25000, 25000, 25000, 43750]),
        p("uturnArrow", "Arrow: U-Turn", .blockArrows, [25000, 25000, 25000, 43750, 75000]),
        p("curvedRightArrow", "Arrow: Curved Right", .blockArrows, [25000, 50000, 25000]),
        p("curvedLeftArrow", "Arrow: Curved Left", .blockArrows, [25000, 50000, 25000]),
        p("curvedUpArrow", "Arrow: Curved Up", .blockArrows, [25000, 50000, 25000]),
        p("curvedDownArrow", "Arrow: Curved Down", .blockArrows, [25000, 50000, 25000]),
        p("leftUpArrow", "Arrow: Left-Up", .blockArrows, [25000, 25000, 25000]),
        p("bentUpArrow", "Arrow: Bent-Up", .blockArrows, [25000, 25000, 25000]),
        p("stripedRightArrow", "Arrow: Striped Right", .blockArrows, [50000, 50000]),
        p("notchedRightArrow", "Arrow: Notched Right", .blockArrows, [50000, 50000]),
        p("homePlate", "Arrow: Pentagon", .blockArrows, [50000]),
        p("chevron", "Arrow: Chevron", .blockArrows, [50000]),
        p("circularArrow", "Arrow: Circular", .blockArrows, [12500, 1_142_319, 20_457_681, 10_800_000, 12500]),
        p("leftCircularArrow", "Arrow: Circular Counter-clockwise", .blockArrows, [12500, -1_142_319, 1_142_319, 10_800_000, 12500]),
        p("leftRightCircularArrow", "Arrow: Circular Two-headed", .blockArrows, [12500, 1_142_319, 20_457_681, 11_942_319, 12500]),
        p("swooshArrow", "Arrow: Swoosh", .blockArrows, [25000, 16667]),
        p("rightArrowCallout", "Callout: Right Arrow", .blockArrows, [25000, 25000, 25000, 64977]),
        p("downArrowCallout", "Callout: Down Arrow", .blockArrows, [25000, 25000, 25000, 64977]),
        p("leftArrowCallout", "Callout: Left Arrow", .blockArrows, [25000, 25000, 25000, 64977]),
        p("upArrowCallout", "Callout: Up Arrow", .blockArrows, [25000, 25000, 25000, 64977]),
        p("leftRightArrowCallout", "Callout: Left-Right Arrow", .blockArrows, [25000, 25000, 25000, 48123]),
        p("upDownArrowCallout", "Callout: Up-Down Arrow", .blockArrows, [25000, 25000, 25000, 48123]),
        p("quadArrowCallout", "Callout: Quad Arrow", .blockArrows, [18515, 18515, 18515, 48123]),
        p("mathPlus", "Plus Sign", .equationShapes, [23520]),
        p("mathMinus", "Minus Sign", .equationShapes, [23520]),
        p("mathMultiply", "Multiplication Sign", .equationShapes, [23520]),
        p("mathDivide", "Division Sign", .equationShapes, [23520, 5880, 11760]),
        p("mathEqual", "Equals", .equationShapes, [23520, 11760]),
        p("mathNotEqual", "Not Equal", .equationShapes, [23520, 6_600_000, 11760]),
        p("flowChartProcess", "Flowchart: Process", .flowchart),
        p("flowChartAlternateProcess", "Flowchart: Alternate Process", .flowchart),
        p("flowChartDecision", "Flowchart: Decision", .flowchart),
        p("flowChartInputOutput", "Flowchart: Data", .flowchart),
        p("flowChartPredefinedProcess", "Flowchart: Predefined Process", .flowchart),
        p("flowChartInternalStorage", "Flowchart: Internal Storage", .flowchart),
        p("flowChartDocument", "Flowchart: Document", .flowchart),
        p("flowChartMultidocument", "Flowchart: Multidocument", .flowchart),
        p("flowChartTerminator", "Flowchart: Terminator", .flowchart),
        p("flowChartPreparation", "Flowchart: Preparation", .flowchart),
        p("flowChartManualInput", "Flowchart: Manual Input", .flowchart),
        p("flowChartManualOperation", "Flowchart: Manual Operation", .flowchart),
        p("flowChartConnector", "Flowchart: Connector", .flowchart),
        p("flowChartOffpageConnector", "Flowchart: Off-page Connector", .flowchart),
        p("flowChartPunchedCard", "Flowchart: Card", .flowchart),
        p("flowChartPunchedTape", "Flowchart: Punched Tape", .flowchart),
        p("flowChartSummingJunction", "Flowchart: Summing Junction", .flowchart),
        p("flowChartOr", "Flowchart: Or", .flowchart),
        p("flowChartCollate", "Flowchart: Collate", .flowchart),
        p("flowChartSort", "Flowchart: Sort", .flowchart),
        p("flowChartExtract", "Flowchart: Extract", .flowchart),
        p("flowChartMerge", "Flowchart: Merge", .flowchart),
        p("flowChartOnlineStorage", "Flowchart: Stored Data", .flowchart),
        p("flowChartDelay", "Flowchart: Delay", .flowchart),
        p("flowChartMagneticTape", "Flowchart: Sequential Access Storage", .flowchart),
        p("flowChartMagneticDisk", "Flowchart: Magnetic Disk", .flowchart),
        p("flowChartMagneticDrum", "Flowchart: Direct Access Storage", .flowchart),
        p("flowChartDisplay", "Flowchart: Display", .flowchart),
        p("flowChartOfflineStorage", "Flowchart: Offline Storage", .flowchart),
        p("irregularSeal1", "Explosion: 8 Points", .starsAndBanners),
        p("irregularSeal2", "Explosion: 14 Points", .starsAndBanners),
        p("star4", "Star: 4 Points", .starsAndBanners, [12500]),
        p("star5", "Star: 5 Points", .starsAndBanners, [19098]),
        p("star6", "Star: 6 Points", .starsAndBanners, [28868]),
        p("star7", "Star: 7 Points", .starsAndBanners, [34601]),
        p("star8", "Star: 8 Points", .starsAndBanners, [37500]),
        p("star10", "Star: 10 Points", .starsAndBanners, [42533]),
        p("star12", "Star: 12 Points", .starsAndBanners, [37500]),
        p("star16", "Star: 16 Points", .starsAndBanners, [37500]),
        p("star24", "Star: 24 Points", .starsAndBanners, [37500]),
        p("star32", "Star: 32 Points", .starsAndBanners, [37500]),
        p("ribbon2", "Ribbon: Tilted Up", .starsAndBanners, [16667, 50000]),
        p("ribbon", "Ribbon: Tilted Down", .starsAndBanners, [16667, 50000]),
        p("ellipseRibbon2", "Ribbon: Curved and Tilted Up", .starsAndBanners, [25000, 50000, 12500]),
        p("ellipseRibbon", "Ribbon: Curved and Tilted Down", .starsAndBanners, [25000, 50000, 12500]),
        p("leftRightRibbon", "Ribbon: Left-Right Fold", .starsAndBanners, [50000, 50000, 16667]),
        p("verticalScroll", "Scroll: Vertical", .starsAndBanners, [12500]),
        p("horizontalScroll", "Scroll: Horizontal", .starsAndBanners, [12500]),
        p("wave", "Wave", .starsAndBanners, [12500, 0]),
        p("doubleWave", "Double Wave", .starsAndBanners, [6250, 0]),
        p("wedgeRectCallout", "Speech Bubble: Rectangle", .callouts, [-20833, 62500]),
        p("wedgeRoundRectCallout", "Speech Bubble: Rectangle with Corners Rounded", .callouts, [-20833, 62500, 16667]),
        p("wedgeEllipseCallout", "Speech Bubble: Oval", .callouts, [-20833, 62500]),
        p("cloudCallout", "Thought Bubble: Cloud", .callouts, [-20833, 62500]),
        p("borderCallout1", "Callout: Line", .callouts, [18750, -8333, 112_500, -38333]),
        p("borderCallout2", "Callout: Bent Line", .callouts, [18750, -8333, 18750, -16667, 112_500, -46667]),
        p("borderCallout3", "Callout: Double Bent Line", .callouts, [18750, -8333, 18750, -16667, 100_000, -16667, 112_963, -8333]),
        p("accentCallout1", "Callout: Line with Accent Bar", .callouts, [18750, -8333, 112_500, -38333]),
        p("accentCallout2", "Callout: Bent Line with Accent Bar", .callouts, [18750, -8333, 18750, -16667, 112_500, -46667]),
        p("accentCallout3", "Callout: Double Bent Line with Accent Bar", .callouts, [18750, -8333, 18750, -16667, 100_000, -16667, 112_963, -8333]),
        p("callout1", "Callout: Line with No Border", .callouts, [18750, -8333, 112_500, -38333]),
        p("callout2", "Callout: Bent Line with No Border", .callouts, [18750, -8333, 18750, -16667, 112_500, -46667]),
        p("callout3", "Callout: Double Bent Line with No Border", .callouts, [18750, -8333, 18750, -16667, 100_000, -16667, 112_963, -8333]),
        p("accentBorderCallout1", "Callout: Line with Border and Accent Bar", .callouts, [18750, -8333, 112_500, -38333]),
        p("accentBorderCallout2", "Callout: Bent Line with Border and Accent Bar", .callouts, [18750, -8333, 18750, -16667, 112_500, -46667]),
        p(
            "accentBorderCallout3", "Callout: Double Bent Line with Border and Accent Bar", .callouts,
            [18750, -8333, 18750, -16667, 100_000, -16667, 112_963, -8333]
        ),
        p("actionButtonBackPrevious", "Action Button: Go Back or Previous", .actionButtons),
        p("actionButtonForwardNext", "Action Button: Go Forward or Next", .actionButtons),
        p("actionButtonBeginning", "Action Button: Go to Beginning", .actionButtons),
        p("actionButtonEnd", "Action Button: Go to End", .actionButtons),
        p("actionButtonHome", "Action Button: Go Home", .actionButtons),
        p("actionButtonInformation", "Action Button: Get Information", .actionButtons),
        p("actionButtonReturn", "Action Button: Go Back", .actionButtons),
        p("actionButtonMovie", "Action Button: Video", .actionButtons),
        p("actionButtonDocument", "Action Button: Document", .actionButtons),
        p("actionButtonSound", "Action Button: Sound", .actionButtons),
        p("actionButtonHelp", "Action Button: Help", .actionButtons),
        p("actionButtonBlank", "Action Button: Custom", .actionButtons),
    ]

    public static func info(_ name: String) -> Info? {
        catalog.first { $0.name == name }
    }

    private static let mitred: Set<String> = [
        "plus", "rightArrow", "upArrow", "downArrow", "upDownArrow", "leftUpArrow", "bentUpArrow",
        "stripedRightArrow", "notchedRightArrow", "chevron", "leftArrowCallout", "leftRightArrowCallout",
        "upDownArrowCallout", "quadArrowCallout", "mathPlus", "mathMinus", "mathMultiply", "mathEqual",
        "mathNotEqual", "star5", "star6", "star8", "star10", "star12", "star16", "star24", "star32",
        "ellipseRibbon", "ellipseRibbon2",
    ]

    /// Whether PowerPoint joins this preset's outline with sharp (miter) corners when the line names no
    /// join (it rounds them otherwise). Observed per preset on its export: the plus, the right, up and
    /// down block arrows (not the left one), chevrons, stars from five points up, the equation shapes,
    /// curved ribbons and the action buttons are mitred.
    public static func mitredByDefault(_ name: String) -> Bool {
        mitred.contains(name) || name.hasPrefix("actionButton")
    }

    /// Lines, connectors and arcs: presets drawn as strokes.
    public static func isLineLike(_ name: String) -> Bool {
        ["line", "straightConnector1", "bentConnector2", "bentConnector3", "curvedConnector3", "arc"].contains(name)
            || name.hasPrefix("bentConnector")
            || name.hasPrefix("curvedConnector")
    }
}

// MARK: - Path builder

/// The path builder presets draw with (Rust `Pb`): a path plus the current point.
final class Pb {
    var p = BezPath()
    var cur = Point.zero

    @discardableResult func m(_ x: Double, _ y: Double) -> Pb {
        cur = Point(x, y)
        p.moveTo(cur)
        return self
    }

    @discardableResult func l(_ x: Double, _ y: Double) -> Pb {
        cur = Point(x, y)
        p.lineTo(cur)
        return self
    }

    @discardableResult func c(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double, _ y: Double) -> Pb {
        cur = Point(x, y)
        p.curveTo(Point(x1, y1), Point(x2, y2), cur)
        return self
    }

    @discardableResult func q(_ x1: Double, _ y1: Double, _ x: Double, _ y: Double) -> Pb {
        cur = Point(x, y)
        p.quadTo(Point(x1, y1), cur)
        return self
    }

    /// Elliptic arc continuing from the current point, which lies on the ellipse at parametric angle
    /// `st` (degrees); sweeps `sw` degrees (positive = clockwise on screen).
    @discardableResult func arc(_ wr: Double, _ hr: Double, _ st: Double, _ sw: Double) -> Pb {
        let s = st.radians
        let e = (st + sw).radians
        let c = Point(cur.x - wr * sinCos(s).cos, cur.y - hr * sinCos(s).sin)
        let a = Arc(c, Vec2(Swift.abs(wr), Swift.abs(hr)), s, e - s, 0.0)
        a.toCubicBeziers(0.05) { p1, p2, q in p.curveTo(p1, p2, q) }
        cur = Point(c.x + wr * sinCos(e).cos, c.y + hr * sinCos(e).sin)
        return self
    }

    /// A DrawingML `arcTo`: angles are where the ray from the ellipse's centre at that angle meets it
    /// (not the ellipse's parameter), so elliptical arcs start and end where the standard's shapes
    /// expect.
    @discardableResult func arcSpec(_ wr: Double, _ hr: Double, _ st: Double, _ sw: Double) -> Pb {
        func par(_ a: Double) -> Double {
            let a = a.radians
            return Darwin.atan2(wr * sinCos(a).sin, hr * sinCos(a).cos)
        }
        let t0 = par(st)
        var d = par(st + sw) - t0
        let tau = 2.0 * Double.pi
        if Swift.abs(sw) >= 360.0 {
            d = tau.copysign(sw)
        } else {
            while sw > 0.0 && d < 0.0 { d += tau }
            while sw < 0.0 && d > 0.0 { d -= tau }
        }
        return arc(wr, hr, t0.degrees, d.degrees)
    }

    @discardableResult func z() -> Pb {
        p.closePath()
        return self
    }

    @discardableResult func poly(_ pts: [(Double, Double)]) -> Pb {
        for (i, pt) in pts.enumerated() {
            if i == 0 { m(pt.0, pt.1) } else { l(pt.0, pt.1) }
        }
        return z()
    }

    @discardableResult func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Pb {
        m(cx + rx, cy)
        arc(rx, ry, 0.0, 360.0)
        return z()
    }

    func take() -> BezPath {
        let out = p
        p = BezPath()
        return out
    }
}

// MARK: - Helpers

extension Preset {
    static func fill(_ p: BezPath) -> SubPath { SubPath(path: p, fill: .norm, stroke: true, evenOdd: false) }
    static func fillEO(_ p: BezPath) -> SubPath { SubPath(path: p, fill: .norm, stroke: true, evenOdd: true) }
    static func shade(_ p: BezPath, _ m: FillMode) -> SubPath { SubPath(path: p, fill: m, stroke: true, evenOdd: false) }
    static func strokeOnly(_ p: BezPath) -> SubPath { SubPath(path: p, fill: .none, stroke: true, evenOdd: false) }
    static func fillOnly(_ p: BezPath) -> SubPath { SubPath(path: p, fill: .norm, stroke: false, evenOdd: false) }

    /// Parametric angle on an rx×ry ellipse for a visual angle `deg` (file angles are visual).
    static func vis(_ deg: Double, _ rx: Double, _ ry: Double) -> Double {
        let t = deg.radians
        return Darwin.atan2(rx * sinCos(t).sin, ry * sinCos(t).cos).degrees
    }

    static func polygonRegular(_ n: Int, _ w: Double, _ h: Double, _ phase: Double) -> [(Double, Double)] {
        let pts: [(Double, Double)] = (0 ..< n).map { i in
            let a = (phase + 360.0 * Double(i) / Double(n)).radians
            return (sinCos(a).cos, sinCos(a).sin)
        }
        return normalize(pts, w, h)
    }

    /// Scale `pts` so their bounding box fills 0..w × 0..h.
    static func normalize(_ pts: [(Double, Double)], _ w: Double, _ h: Double) -> [(Double, Double)] {
        var (x0, y0, x1, y1) = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        for (x, y) in pts {
            x0 = fmin(x0, x)
            y0 = fmin(y0, y)
            x1 = fmax(x1, x)
            y1 = fmax(y1, y)
        }
        let sx = x1 - x0 > 1e-12 ? w / (x1 - x0) : 0.0
        let sy = y1 - y0 > 1e-12 ? h / (y1 - y0) : 0.0
        return pts.map { ((($0.0 - x0) * sx), (($0.1 - y0) * sy)) }
    }

    /// An n-pointed star as ECMA-376 draws it: points on an ellipse around (hc, vc · vf) with radii half
    /// the box stretched by the preset's `hf` / `vf` (so a five-pointed star fills its box and looks
    /// regular in a square), the inner corners `inner` of the way out.
    static func star(_ n: Int, _ w: Double, _ h: Double, _ inner: Double) -> [(Double, Double)] {
        let (hf, vf): (Double, Double)
        switch n {
        case 5: (hf, vf) = (1.05146, 1.10557)
        case 6: (hf, vf) = (1.15470, 1.0)
        case 7: (hf, vf) = (1.02572, 1.05210)
        case 10: (hf, vf) = (1.05146, 1.0)
        default: (hf, vf) = (1.0, 1.0)
        }
        let (rx, ry, cy) = (w / 2.0 * hf, h / 2.0 * vf, h / 2.0 * vf)
        var pts: [(Double, Double)] = []
        pts.reserveCapacity(n * 2)
        for i in 0 ..< n * 2 {
            let a = (-90.0 + 180.0 * Double(i) / Double(n)).radians
            let r = i % 2 == 0 ? 1.0 : inner
            pts.append((w / 2.0 + r * rx * sinCos(a).cos, cy + r * ry * sinCos(a).sin))
        }
        return pts
    }

    /// The text rectangle ECMA-376's presetShapeDefinitions give a star (`inner` is the adjust value over
    /// 50000), where known: star4's is the square inside its inner points, star5's spans the inner
    /// pentagon from its upper side points to its bottom inner point.
    static func starTextRect(_ n: Int, _ w: Double, _ h: Double, _ inner: Double) -> Rect? {
        let (hc, vc) = (w / 2.0, h / 2.0)
        switch n {
        case 4:
            let (dx, dy) = (hc * inner * Darwin.cos(45.0.radians), vc * inner * Darwin.sin(45.0.radians))
            return Rect(hc - dx, vc - dy, hc + dx, vc + dy)
        case 5:
            let (swd2, shd2, svc) = (hc * 1.05146, vc * 1.10557, vc * 1.10557)
            let (iwd2, ihd2) = (swd2 * inner, shd2 * inner)
            let sdx1 = iwd2 * Darwin.cos(18.0.radians)
            let sdy1 = ihd2 * Darwin.sin(54.0.radians)
            return Rect(hc - sdx1, svc - sdy1, hc + sdx1, svc + ihd2)
        default:
            return nil
        }
    }

    enum Corner {
        case square
        case round(Double)
        case snip(Double)
    }

    /// A rectangle with each corner (TL, TR, BR, BL) square, rounded or snipped.
    static func cornerRect(_ w: Double, _ h: Double, _ c: [Corner]) -> BezPath {
        let b = Pb()
        func size(_ k: Corner) -> Double {
            switch k {
            case .square: 0.0
            case .round(let r), .snip(let r): fmax(r, 0.0)
            }
        }
        let c0 = c.at(0) ?? .square, c1 = c.at(1) ?? .square, c2 = c.at(2) ?? .square, c3 = c.at(3) ?? .square
        let s0 = size(c0)
        b.m(s0, 0.0)
        let s1 = size(c1)
        b.l(w - s1, 0.0)
        switch c1 {
        case .round(let r) where r > 0: b.arc(r, r, 270.0, 90.0)
        case .snip: b.l(w, s1)
        default: break
        }
        let s2 = size(c2)
        b.l(w, h - s2)
        switch c2 {
        case .round(let r) where r > 0: b.arc(r, r, 0.0, 90.0)
        case .snip: b.l(w - s2, h)
        default: break
        }
        let s3 = size(c3)
        b.l(s3, h)
        switch c3 {
        case .round(let r) where r > 0: b.arc(r, r, 90.0, 90.0)
        case .snip: b.l(0.0, h - s3)
        default: break
        }
        b.l(0.0, s0)
        switch c0 {
        case .round(let r) where r > 0: b.arc(r, r, 180.0, 90.0)
        case .snip: b.l(s0, 0.0)
        default: break
        }
        b.z()
        return b.take()
    }

    static func midSites(_ w: Double, _ h: Double) -> [Point] {
        [Point(w / 2.0, 0.0), Point(0.0, h / 2.0), Point(w / 2.0, h), Point(w, h / 2.0)]
    }

    /// Orientation for single-axis arrows built along +x.
    enum Dir {
        case right, left, up, down
    }

    /// Map canonical (u along the arrow's length L, v across thickness T) to shape space.
    static func orient(_ d: Dir, _ w: Double, _ h: Double, _ pts: [(Double, Double)]) -> [(Double, Double)] {
        pts.map { u, v in
            switch d {
            case .right: (u, v)
            case .left: (w - u, v)
            case .up: (v, h - u)
            case .down: (v, u)
            }
        }
    }

    static func lenThick(_ d: Dir, _ w: Double, _ h: Double) -> (Double, Double) {
        switch d {
        case .right, .left: (w, h)
        case .up, .down: (h, w)
        }
    }

    static func pt(_ t: (Double, Double)) -> Point { Point(t.0, t.1) }

    static func arrow(_ d: Dir, _ w: Double, _ h: Double, _ a1in: Double, _ a2: Double) -> Geometry {
        let (l, t) = lenThick(d, w, h)
        let ss = fmin(l, t)
        let a1 = a1in.clamp(0.0, 100_000.0) / 100_000.0
        let dx = fmin(ss * a2.clamp(0.0, 100_000.0 * l / fmax(ss, 1e-9)) / 100_000.0, l)
        let y1 = t / 2.0 - t * a1 / 2.0
        let y2 = t / 2.0 + t * a1 / 2.0
        let pts = orient(d, w, h, [(0.0, y1), (l - dx, y1), (l - dx, 0.0), (l, t / 2.0), (l - dx, t), (l - dx, y2), (0.0, y2)])
        let tr = orient(d, w, h, [(0.0, y1), (l - dx + dx * (y1 / fmax(t / 2.0, 1e-9)), y2)])
        let text = Rect.fromPoints(pt(tr[0]), pt(tr[1])).abs
        var g = Geometry(paths: [fill(Pb().poly(pts).take())], textRect: text, handles: [], sites: midSites(w, h))
        // handle 0: shaft thickness on the head base; handle 1: head length.
        let o = orient(d, w, h, [(l - dx, t / 2.0), (l, t / 2.0)])
        let (o0, o1) = (pt(o[0]), pt(o[1]))
        let across: Vec2
        switch d {
        case .right, .left: across = Vec2(0.0, -t / 2.0 / 100_000.0)
        case .up, .down: across = Vec2(-t / 2.0 / 100_000.0, 0.0)
        }
        let along = (o0 - o1) * (ss / 100_000.0 / fmax(dx, 1e-9))
        g.handles.append(.new(0, o0, across, a1 * 100_000.0, 0.0, 100_000.0))
        if dx > 1e-9 {
            g.handles.append(.new(1, o1, along, a2, 0.0, 100_000.0 * l / fmax(ss, 1e-9)))
        }
        return g
    }

    static func doubleArrow(_ vertical: Bool, _ w: Double, _ h: Double, _ a1in: Double, _ a2: Double) -> Geometry {
        let (l, t) = vertical ? (h, w) : (w, h)
        let ss = fmin(l, t)
        let a1 = a1in.clamp(0.0, 100_000.0) / 100_000.0
        let dx = fmin(ss * fmax(a2, 0.0) / 100_000.0, l / 2.0)
        let y1 = t / 2.0 - t * a1 / 2.0
        let y2 = t / 2.0 + t * a1 / 2.0
        let pts = orient(vertical ? .down : .right, w, h, [
            (0.0, t / 2.0), (dx, 0.0), (dx, y1), (l - dx, y1), (l - dx, 0.0), (l, t / 2.0), (l - dx, t), (l - dx, y2), (dx, y2), (dx, t),
        ])
        let r = vertical ? Rect(y1, dx, y2, h - dx) : Rect(dx, y1, w - dx, y2)
        return Geometry(paths: [fill(Pb().poly(pts).take())], textRect: r, handles: [], sites: midSites(w, h))
    }

    /// Points given in 21600ths of the box (as ECMA-376 defines many fixed shapes), scaled to it.
    static func specPts(_ pts: [(Int, Int)], _ w: Double, _ h: Double) -> [(Double, Double)] {
        pts.map { (w * Double($0.0) / 21600.0, h * Double($0.1) / 21600.0) }
    }

    static func simple(_ path: BezPath, _ text: Rect, _ w: Double, _ h: Double) -> Geometry {
        Geometry(paths: [fill(path)], textRect: text, handles: [], sites: midSites(w, h))
    }

    static func ellipseSites(_ w: Double, _ h: Double) -> [Point] {
        (0 ..< 8).map { i in
            let a = (-90.0 - 45.0 * Double(i)).radians
            return Point(w / 2.0 + w / 2.0 * sinCos(a).cos, h / 2.0 + h / 2.0 * sinCos(a).sin)
        }
    }

    static func tipHandle(_ w: Double, _ h: Double, _ tip: Point) -> Handle {
        // A free 2-D handle is represented as index 0 with zero direction; callers move both values.
        Handle(index: 0, pos: tip, origin: Point(w / 2.0, h / 2.0), dir: Vec2(w / 1e5, h / 1e5), min: -1e6, max: 1e6, angle: false)
    }
}

// MARK: - build

extension Preset {
    /// Builds the geometry for preset `name` at size `w`×`h` with adjust values `adj` (missing values use
    /// the preset's defaults). Unknown names return nil; the caller falls back to `rect`.
    public static func build(_ name: String, _ w: Double, _ h: Double, _ adj: [Double]) -> Geometry? {
        guard w.isFinite && h.isFinite else { return nil }
        let w = fmax(w, 0.0)
        let h = fmax(h, 0.0)
        let defaults = info(name)?.defaults ?? []
        let a: (Int) -> Double = { i in
            let v = adj.at(i) ?? defaults.at(i) ?? 0.0
            return v.isFinite ? v : 0.0
        }
        let ss = fmin(w, h)
        let full = Rect(0.0, 0.0, w, h)
        let b = Pb()
        let ell = Rect(w * 0.14645, h * 0.14645, w * 0.85355, h * 0.85355)
        var g: Geometry
        switch name {
        case "rect", "textBox", "flowChartProcess":
            g = simple(cornerRect(w, h, [.square, .square, .square, .square]), full, w, h)
        case "actionButtonBlank", "actionButtonBackPrevious", "actionButtonForwardNext", "actionButtonBeginning",
             "actionButtonEnd", "actionButtonHome", "actionButtonInformation", "actionButtonReturn", "actionButtonMovie",
             "actionButtonDocument", "actionButtonSound", "actionButtonHelp":
            g = actionButton(name, w, h)
        case "roundRect":
            let v = a(0).clamp(0.0, 50000.0)
            let r = ss * v / 100_000.0
            g = simple(cornerRect(w, h, Array(repeating: .round(r), count: 4)), full.inset(-r * 0.29289), w, h)
            g.handles.append(.new(0, .zero, Vec2(ss / 100_000.0, 0.0), v, 0.0, 50000.0))
        case "flowChartAlternateProcess":
            g = simple(cornerRect(w, h, Array(repeating: .round(ss / 6.0), count: 4)), full.inset(-ss / 6.0 * 0.29289), w, h)
        case "snip1Rect":
            let v = a(0).clamp(0.0, 50000.0)
            let d = ss * v / 100_000.0
            g = simple(cornerRect(w, h, [.square, .snip(d), .square, .square]), Rect(0.0, d / 2.0, w - d / 2.0, h), w, h)
            g.handles.append(.new(0, Point(w, 0.0), Vec2(-ss / 100_000.0, 0.0), v, 0.0, 50000.0))
        case "snip2SameRect":
            let (d1, d2) = (ss * a(0).clamp(0.0, 50000.0) / 1e5, ss * a(1).clamp(0.0, 50000.0) / 1e5)
            g = simple(cornerRect(w, h, [.snip(d1), .snip(d1), .snip(d2), .snip(d2)]), full.inset(-fmax(d1, d2) / 2.0), w, h)
        case "snip2DiagRect":
            let (d1, d2) = (ss * a(0).clamp(0.0, 50000.0) / 1e5, ss * a(1).clamp(0.0, 50000.0) / 1e5)
            g = simple(cornerRect(w, h, [.snip(d1), .snip(d2), .snip(d1), .snip(d2)]), full.inset(-fmax(d1, d2) / 2.0), w, h)
        case "snipRoundRect":
            let (r, d) = (ss * a(0).clamp(0.0, 50000.0) / 1e5, ss * a(1).clamp(0.0, 50000.0) / 1e5)
            g = simple(cornerRect(w, h, [.round(r), .snip(d), .square, .square]), full.inset(-fmax(r, d) / 2.0), w, h)
        case "round1Rect":
            let r = ss * a(0).clamp(0.0, 50000.0) / 1e5
            g = simple(cornerRect(w, h, [.square, .round(r), .square, .square]), full.inset(-r * 0.29289), w, h)
        case "round2SameRect":
            let (r1, r2) = (ss * a(0).clamp(0.0, 50000.0) / 1e5, ss * a(1).clamp(0.0, 50000.0) / 1e5)
            g = simple(cornerRect(w, h, [.round(r1), .round(r1), .round(r2), .round(r2)]), full.inset(-fmax(r1, r2) * 0.29289), w, h)
        case "round2DiagRect":
            let (r1, r2) = (ss * a(0).clamp(0.0, 50000.0) / 1e5, ss * a(1).clamp(0.0, 50000.0) / 1e5)
            g = simple(cornerRect(w, h, [.round(r1), .round(r2), .round(r1), .round(r2)]), full.inset(-fmax(r1, r2) * 0.29289), w, h)
        case "ellipse", "flowChartConnector":
            g = simple(b.ellipse(w / 2.0, h / 2.0, w / 2.0, h / 2.0).take(), ell, w, h)
            g.sites = ellipseSites(w, h)
        case "triangle", "flowChartExtract":
            let v = name == "triangle" ? a(0).clamp(0.0, 100_000.0) : 50000.0
            let ax = w * v / 100_000.0
            g = simple(b.poly([(0.0, h), (ax, 0.0), (w, h)]).take(), Rect(ax / 2.0, h / 2.0, (ax + w) / 2.0, h), w, h)
            g.sites = [Point(ax, 0.0), Point(ax / 2.0, h / 2.0), Point(0.0, h), Point(w / 2.0, h), Point(w, h), Point((ax + w) / 2.0, h / 2.0)]
            if name == "triangle" {
                g.handles.append(.new(0, .zero, Vec2(w / 100_000.0, 0.0), v, 0.0, 100_000.0))
            }
        case "flowChartMerge":
            g = simple(b.poly([(0.0, 0.0), (w, 0.0), (w / 2.0, h)]).take(), Rect(w / 4.0, 0.0, w * 0.75, h / 2.0), w, h)
        case "rtTriangle":
            g = simple(b.poly([(0.0, 0.0), (0.0, h), (w, h)]).take(), Rect(w / 12.0, h * 7.0 / 12.0, w * 7.0 / 12.0, h * 11.0 / 12.0), w, h)
        case "parallelogram", "flowChartInputOutput":
            let v = name == "parallelogram" ? a(0).clamp(0.0, 100_000.0 * w / fmax(ss, 1e-9)) : 20000.0 * w / fmax(ss, 1e-9)
            let off = ss * v / 100_000.0
            g = simple(
                b.poly([(0.0, h), (off, 0.0), (w, 0.0), (w - off, h)]).take(),
                Rect(off / 2.0 + off * 0.2, h * 0.08, w - off / 2.0 - off * 0.2, h * 0.92), w, h
            )
            if name == "parallelogram" {
                g.handles.append(.new(0, .zero, Vec2(ss / 100_000.0, 0.0), v, 0.0, 100_000.0 * w / fmax(ss, 1e-9)))
            }
        case "trapezoid":
            let v = a(0).clamp(0.0, 50000.0 * w / fmax(ss, 1e-9))
            let off = ss * v / 100_000.0
            g = simple(b.poly([(0.0, h), (off, 0.0), (w - off, 0.0), (w, h)]).take(), Rect(off * 0.66, h * 0.2, w - off * 0.66, h), w, h)
            g.handles.append(.new(0, .zero, Vec2(ss / 100_000.0, 0.0), v, 0.0, 50000.0 * w / fmax(ss, 1e-9)))
        case "flowChartManualOperation":
            g = simple(b.poly([(0.0, 0.0), (w, 0.0), (w * 0.8, h), (w * 0.2, h)]).take(), Rect(w * 0.2, 0.0, w * 0.8, h), w, h)
        case "diamond", "flowChartDecision":
            g = simple(b.poly([(w / 2.0, 0.0), (w, h / 2.0), (w / 2.0, h), (0.0, h / 2.0)]).take(), Rect(w / 4.0, h / 4.0, w * 0.75, h * 0.75), w, h)
        case "flowChartSort":
            let d = b.poly([(w / 2.0, 0.0), (w, h / 2.0), (w / 2.0, h), (0.0, h / 2.0)]).take()
            let line = Pb().m(0.0, h / 2.0).l(w, h / 2.0).take()
            g = Geometry(paths: [fill(d), strokeOnly(line)], textRect: Rect(w / 4.0, h / 4.0, w * 0.75, h * 0.75), handles: [], sites: midSites(w, h))
        case "pentagon":
            g = simple(b.poly(polygonRegular(5, w, h, -90.0)).take(), Rect(w * 0.2, h * 0.27, w * 0.8, h * 0.9), w, h)
        case "heptagon":
            g = simple(b.poly(polygonRegular(7, w, h, -90.0)).take(), Rect(w * 0.16, h * 0.2, w * 0.84, h * 0.86), w, h)
        case "decagon":
            g = simple(b.poly(polygonRegular(10, w, h, 0.0)).take(), Rect(w * 0.1, h * 0.17, w * 0.9, h * 0.83), w, h)
        case "dodecagon":
            g = simple(b.poly(polygonRegular(12, w, h, 15.0)).take(), Rect(w * 0.13, h * 0.13, w * 0.87, h * 0.87), w, h)
        case "hexagon", "flowChartPreparation":
            let v = name == "hexagon" ? a(0).clamp(0.0, 50000.0 * w / fmax(ss, 1e-9)) : 20000.0 * w / fmax(ss, 1e-9)
            let off = ss * v / 100_000.0
            g = simple(
                b.poly([(0.0, h / 2.0), (off, 0.0), (w - off, 0.0), (w, h / 2.0), (w - off, h), (off, h)]).take(),
                Rect(off * 0.6, h * 0.14, w - off * 0.6, h * 0.86), w, h
            )
            if name == "hexagon" {
                g.handles.append(.new(0, .zero, Vec2(ss / 100_000.0, 0.0), v, 0.0, 50000.0 * w / fmax(ss, 1e-9)))
            }
        case "octagon":
            let v = a(0).clamp(0.0, 50000.0)
            let d = ss * v / 100_000.0
            g = simple(b.poly([(d, 0.0), (w - d, 0.0), (w, d), (w, h - d), (w - d, h), (d, h), (0.0, h - d), (0.0, d)]).take(), full.inset(-d / 2.0), w, h)
            g.handles.append(.new(0, .zero, Vec2(ss / 100_000.0, 0.0), v, 0.0, 50000.0))
        case "plus":
            let v = a(0).clamp(0.0, 50000.0)
            let d = ss * v / 100_000.0
            g = simple(
                b.poly([
                    (d, 0.0), (w - d, 0.0), (w - d, d), (w, d), (w, h - d), (w - d, h - d),
                    (w - d, h), (d, h), (d, h - d), (0.0, h - d), (0.0, d), (d, d),
                ]).take(),
                Rect(0.0, d, w, h - d), w, h
            )
            g.handles.append(.new(0, .zero, Vec2(ss / 100_000.0, 0.0), v, 0.0, 50000.0))
        case "frame":
            let v = a(0).clamp(0.0, 50000.0)
            let t = ss * v / 100_000.0
            b.poly([(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)])
            b.poly([(t, t), (w - t, t), (w - t, h - t), (t, h - t)])
            g = Geometry(paths: [fillEO(b.take())], textRect: full.inset(-t), handles: [], sites: midSites(w, h))
            g.handles.append(.new(0, .zero, Vec2(ss / 100_000.0, 0.0), v, 0.0, 50000.0))
        case "halfFrame":
            let (t1, t2) = (ss * a(0).clamp(0.0, 50000.0) / 1e5, ss * a(1).clamp(0.0, 50000.0) / 1e5)
            g = simple(b.poly([(0.0, 0.0), (w, 0.0), (w - t1, t1), (t2, t1), (t2, h - t2), (0.0, h)]).take(), full, w, h)
        case "corner":
            let (t1, t2) = (ss * a(0).clamp(0.0, 100_000.0) / 1e5, ss * a(1).clamp(0.0, 100_000.0) / 1e5)
            g = simple(b.poly([(0.0, 0.0), (t2, 0.0), (t2, h - t1), (w, h - t1), (w, h), (0.0, h)]).take(), Rect(0.0, h - t1, w, h), w, h)
        case "diagStripe":
            let k = a(0).clamp(0.0, 100_000.0) / 1e5
            g = simple(b.poly([(0.0, h * k), (w * k, 0.0), (w, 0.0), (0.0, h)]).take(), Rect(0.0, 0.0, w / 2.0, h / 2.0), w, h)
        case "plaque":
            let v = a(0).clamp(0.0, 50000.0)
            let r = ss * v / 100_000.0
            b.m(0.0, r).arc(r, r, 90.0, -90.0).l(w - r, 0.0).arc(r, r, 180.0, -90.0).l(w, h - r)
                .arc(r, r, 270.0, -90.0).l(r, h).arc(r, r, 0.0, -90.0).z()
            g = simple(b.take(), full.inset(-r * 0.7), w, h)
            g.handles.append(.new(0, .zero, Vec2(ss / 100_000.0, 0.0), v, 0.0, 50000.0))
        case "can", "flowChartMagneticDisk":
            // The disk's ends are a third of its height (ECMA-376: ellipses of radius h/6).
            let v = name == "can" ? a(0).clamp(0.0, 50000.0 * h / fmax(ss, 1e-9)) : 100_000.0 / 3.0 * h / fmax(ss, 1e-9)
            let eh = ss * v / 100_000.0
            let r = eh / 2.0
            let body = Pb().m(0.0, r).l(0.0, h - r).arc(w / 2.0, r, 180.0, -180.0).l(w, r).arc(w / 2.0, r, 0.0, -180.0).z().take()
            let top = Pb().ellipse(w / 2.0, r, w / 2.0, r).take()
            g = Geometry(
                paths: [fill(body), shade(top, name == "can" ? .lighten : .norm)],
                textRect: Rect(0.0, eh, w, h - r), handles: [], sites: midSites(w, h)
            )
            if name == "can" {
                g.handles.append(.new(0, Point(w / 2.0, 0.0), Vec2(0.0, ss / 100_000.0), v, 0.0, 50000.0 * h / fmax(ss, 1e-9)))
            }
        case "flowChartMagneticDrum":
            // ECMA-376: end ellipses of radius w/6 across.
            let r = w / 6.0
            let body = Pb().m(r, 0.0).l(w - r, 0.0).arc(r, h / 2.0, 270.0, 180.0).l(r, h).arc(r, h / 2.0, 90.0, 180.0).z().take()
            let side = Pb().m(w - r, 0.0).arc(r, h / 2.0, 270.0, -180.0).take()
            g = Geometry(paths: [fill(body), strokeOnly(side)], textRect: Rect(r, 0.0, w - 2.0 * r, h), handles: [], sites: midSites(w, h))
        case "cube":
            let v = a(0).clamp(0.0, 100_000.0)
            let d = ss * v / 100_000.0
            let front = Pb().poly([(0.0, d), (w - d, d), (w - d, h), (0.0, h)]).take()
            let top = Pb().poly([(0.0, d), (d, 0.0), (w, 0.0), (w - d, d)]).take()
            let side = Pb().poly([(w - d, d), (w, 0.0), (w, h - d), (w - d, h)]).take()
            g = Geometry(
                paths: [fill(front), shade(top, .lightenLess), shade(side, .darkenLess)],
                textRect: Rect(0.0, d, w - d, h), handles: [], sites: midSites(w, h)
            )
            g.handles.append(.new(0, Point(0.0, 0.0), Vec2(0.0, ss / 100_000.0), v, 0.0, 100_000.0))
        case "bevel":
            let v = a(0).clamp(0.0, 50000.0)
            let d = ss * v / 100_000.0
            let inner = Pb().poly([(d, d), (w - d, d), (w - d, h - d), (d, h - d)]).take()
            let top = Pb().poly([(0.0, 0.0), (w, 0.0), (w - d, d), (d, d)]).take()
            let left = Pb().poly([(0.0, 0.0), (d, d), (d, h - d), (0.0, h)]).take()
            let right = Pb().poly([(w, 0.0), (w, h), (w - d, h - d), (w - d, d)]).take()
            let bottom = Pb().poly([(0.0, h), (d, h - d), (w - d, h - d), (w, h)]).take()
            g = Geometry(
                paths: [fill(inner), shade(top, .lightenLess), shade(left, .lighten), shade(right, .darkenLess), shade(bottom, .darken)],
                textRect: full.inset(-d), handles: [], sites: midSites(w, h)
            )
            g.handles.append(.new(0, .zero, Vec2(ss / 100_000.0, 0.0), v, 0.0, 50000.0))
        case "donut":
            let v = a(0).clamp(0.0, 50000.0)
            let t = ss * v / 100_000.0
            b.ellipse(w / 2.0, h / 2.0, w / 2.0, h / 2.0)
            b.ellipse(w / 2.0, h / 2.0, fmax(w / 2.0 - t, 0.0), fmax(h / 2.0 - t, 0.0))
            g = Geometry(paths: [fillEO(b.take())], textRect: ell, handles: [], sites: ellipseSites(w, h))
            g.handles.append(.new(0, Point(0.0, h / 2.0), Vec2(ss / 100_000.0, 0.0), v, 0.0, 50000.0))
        case "noSmoking":
            let v = a(0).clamp(0.0, 50000.0)
            let t = ss * v / 100_000.0
            let (rx, ry) = (fmax(w / 2.0 - t, 0.0), fmax(h / 2.0 - t, 0.0))
            b.ellipse(w / 2.0, h / 2.0, w / 2.0, h / 2.0)
            b.ellipse(w / 2.0, h / 2.0, rx, ry)
            let ring = b.take()
            let th = Darwin.atan2(h, w)
            let dir = Vec2(sinCos(th).cos, sinCos(th).sin)
            let rr: Double
            if rx > 0.0 && ry > 0.0 {
                let u = ry * sinCos(th).cos, v2 = rx * sinCos(th).sin
                rr = rx * ry / (u * u + v2 * v2).squareRoot()
            } else {
                rr = 0.0
            }
            let perp = Vec2(-dir.y, dir.x) * (t / 2.0)
            let c = Point(w / 2.0, h / 2.0)
            let q = [c - dir * rr - perp, c + dir * rr - perp, c + dir * rr + perp, c - dir * rr + perp]
            let bar = Pb().poly(q.map { ($0.x, $0.y) }).take()
            g = Geometry(
                paths: [fillEO(ring), fill(bar)], textRect: ell,
                handles: [.new(0, Point(0.0, h / 2.0), Vec2(ss / 100_000.0, 0.0), v, 0.0, 50000.0)], sites: ellipseSites(w, h)
            )
        case "blockArc":
            let st = a(0) / 60000.0
            let en = a(1) / 60000.0
            let t = ss * a(2).clamp(0.0, 50000.0) / 100_000.0
            var sw = en - st
            if sw <= 0.0 { sw += 360.0 }
            let (rx, ry) = (w / 2.0, h / 2.0)
            let (irx, iry) = (fmax(rx - t, 0.0), fmax(ry - t, 0.0))
            let s0 = vis(st, rx, ry)
            let e0 = vis(st + sw, rx, ry)
            var sweep = e0 - s0
            if sweep <= 0.0 { sweep += 360.0 }
            let si = vis(st + sw, irx, iry)
            let ei = vis(st, irx, iry)
            var isweep = ei - si
            if isweep >= 0.0 { isweep -= 360.0 }
            let p0 = Point(w / 2.0 + rx * sinCos(s0.radians).cos, h / 2.0 + ry * sinCos(s0.radians).sin)
            b.m(p0.x, p0.y).arc(rx, ry, s0, sweep)
            let pi = Point(w / 2.0 + irx * sinCos(si.radians).cos, h / 2.0 + iry * sinCos(si.radians).sin)
            b.l(pi.x, pi.y).arc(irx, iry, si, isweep).z()
            g = simple(b.take(), full, w, h)
            let c = Point(rx, ry)
            g.handles.append(.angle(0, c, rx - t / 2.0, ry - t / 2.0, a(0)))
            // Thickness: slides inward from the outer edge along the end angle's ray.
            let pe = Point(rx + rx * sinCos(e0.radians).cos, ry + ry * sinCos(e0.radians).sin)
            let u0 = (c - pe).normalize
            let u = u0.x.isFinite && u0.y.isFinite ? u0 : Vec2.zero
            g.handles.append(.new(2, pe, u * (ss / 100_000.0), a(2).clamp(0.0, 50000.0), 0.0, 50000.0))
        case "pie", "chord", "arc":
            let (rx, ry) = (w / 2.0, h / 2.0)
            let s = vis(a(0) / 60000.0, rx, ry)
            let e = vis(a(1) / 60000.0, rx, ry)
            var sw = e - s
            if sw <= 0.0 { sw += 360.0 }
            let p0 = Point(rx + rx * sinCos(s.radians).cos, ry + ry * sinCos(s.radians).sin)
            b.m(p0.x, p0.y).arc(rx, ry, s, sw)
            switch name {
            case "pie":
                b.l(rx, ry).z()
                g = simple(b.take(), ell, w, h)
            case "chord":
                b.z()
                g = simple(b.take(), ell, w, h)
            default:
                let open = b.take()
                var f = BezPath(open.elements)
                f.lineTo(Point(rx, ry))
                f.closePath()
                g = Geometry(paths: [fillOnly(f), strokeOnly(open)], textRect: ell, handles: [], sites: midSites(w, h))
            }
            let c = Point(rx, ry)
            g.handles.append(.angle(0, c, rx, ry, a(0)))
            g.handles.append(.angle(1, c, rx, ry, a(1)))
        case "teardrop":
            let k = a(0).clamp(0.0, 200_000.0) / 100_000.0
            let tip = (w / 2.0 + w / 2.0 * k, h / 2.0 - h / 2.0 * k)
            b.m(0.0, h / 2.0).arc(w / 2.0, h / 2.0, 180.0, 90.0)
            b.q(w / 2.0 + w / 4.0 * k, 0.0, tip.0, tip.1).q(w, h / 2.0 - h / 4.0 * k, w, h / 2.0)
            b.arc(w / 2.0, h / 2.0, 0.0, 180.0).z()
            g = simple(b.take(), ell, w, h)
        case "foldedCorner":
            let v = a(0).clamp(0.0, 50000.0)
            let d = ss * v / 100_000.0
            let body = Pb().poly([(0.0, 0.0), (w, 0.0), (w, h - d), (w - d, h), (0.0, h)]).take()
            let fold = Pb().m(w - d, h).l(w - d + d * 0.2, h - d + d * 0.2).l(w, h - d).z().take()
            g = Geometry(paths: [fill(body), shade(fold, .darkenLess)], textRect: Rect(0.0, 0.0, w, h - d), handles: [], sites: midSites(w, h))
        case "smileyFace":
            let k = a(0).clamp(-4653.0, 4653.0) / 100_000.0
            let face = Pb().ellipse(w / 2.0, h / 2.0, w / 2.0, h / 2.0).take()
            let eyes = Pb()
            eyes.ellipse(w * 0.35, h * 0.37, w * 0.05, h * 0.05)
            eyes.ellipse(w * 0.65, h * 0.37, w * 0.05, h * 0.05)
            let ys = h * (0.72 - k)
            let smile = Pb().m(w * 0.22, ys).q(w / 2.0, ys + h * k * 4.0 + h * 0.0, w * 0.78, ys).take()
            g = Geometry(paths: [fill(face), shade(eyes.take(), .darkenLess), strokeOnly(smile)], textRect: ell, handles: [], sites: ellipseSites(w, h))
        case "heart":
            // ECMA-376 heart: two cubic curves from the notch at the top to the point.
            let (dx1, dx2) = (w * 49.0 / 48.0, w * 10.0 / 48.0)
            let y1 = -h / 3.0
            b.m(w / 2.0, h / 4.0)
                .c(w / 2.0 + dx2, y1, w / 2.0 + dx1, h / 4.0, w / 2.0, h)
                .c(w / 2.0 - dx1, h / 4.0, w / 2.0 - dx2, y1, w / 2.0, h / 4.0)
                .z()
            g = simple(b.take(), Rect(w * 0.2, h * 0.25, w * 0.8, h * 0.7), w, h)
        case "lightningBolt":
            // ECMA-376 lightningBolt, in 21600ths of the box.
            let pts = specPts([
                (8472, 0), (12860, 6080), (11050, 6797), (16577, 12007), (14767, 12877), (21600, 21600),
                (10012, 14915), (12222, 13987), (5022, 9705), (7602, 8382), (0, 3890),
            ], w, h)
            g = simple(b.poly(pts).take(), Rect(w * 8757.0 / 21600.0, h * 7637.0 / 21600.0, w * 13917.0 / 21600.0, h * 12963.0 / 21600.0), w, h)
        case "sun":
            // ECMA-376 sun: eight triangular rays (their bases at fixed fractions of the core's margin)
            // around a circle of radius 50% - adj.
            let av = a(0).clamp(12500.0, 46875.0)
            let g0 = 50000.0 - av
            let (g1, g2) = (g0 * 30274.0 / 32768.0, g0 * 12540.0 / 32768.0)
            let (g10, g11) = ((50000.0 - g1) * 0.75, (50000.0 - g2) * 0.75)
            let (g12, g13, g14) = (g10 + 3662.0, g11 + 3662.0, g11 + 12500.0)
            let (g15, g16, g17, g18) = (100_000.0 - g10, 100_000.0 - g12, 100_000.0 - g13, 100_000.0 - g14)
            func x(_ gv: Double) -> Double { w * gv / 100_000.0 }
            func y(_ gv: Double) -> Double { h * gv / 100_000.0 }
            let (ox1, oy1, ox2, oy2) = (w * 18436.0 / 21600.0, h * 3163.0 / 21600.0, w * 3163.0 / 21600.0, h * 18436.0 / 21600.0)
            let (hc, vc) = (w / 2.0, h / 2.0)
            b.poly([(w, vc), (x(g15), y(g18)), (x(g15), y(g14))])
            b.poly([(ox1, oy1), (x(g16), y(g13)), (x(g17), y(g12))])
            b.poly([(hc, 0.0), (x(g18), y(g10)), (x(g14), y(g10))])
            b.poly([(ox2, oy1), (x(g13), y(g12)), (x(g12), y(g13))])
            b.poly([(0.0, vc), (x(g10), y(g14)), (x(g10), y(g18))])
            b.poly([(ox2, oy2), (x(g12), y(g17)), (x(g13), y(g16))])
            b.poly([(hc, h), (x(g14), y(g15)), (x(g18), y(g15))])
            b.poly([(ox1, oy2), (x(g17), y(g16)), (x(g16), y(g17))])
            b.ellipse(hc, vc, x(g0), y(g0))
            let g7 = g0 * 23170.0 / 32768.0
            g = simple(b.take(), Rect(x(50000.0 - g7), y(50000.0 - g7), x(50000.0 + g7), y(50000.0 + g7)), w, h)
            g.handles.append(.new(0, Point(0.0, vc), Vec2(w / 100_000.0, 0.0), av, 12500.0, 46875.0))
        case "moon":
            // ECMA-376 moon: the outer edge is the left half of an ellipse w × h/2 centred on the right
            // edge; the inner edge an arc through the corners and (adj · w, middle) of a larger ellipse
            // (rx = g18, ry = dy1) whose centre lies right of that point.
            let k = a(0).clamp(0.0, 87500.0) / 100_000.0
            let ssf = fmax(ss, 1e-9)
            let g0 = ss * k
            let g1 = fmax(ss - g0, 1e-9)
            let g2 = g0 * g0 / g1
            let g3 = ss * ss / g1
            let g5 = 2.0 * g3 - g2
            let g6 = g5 - g0
            let dy1 = (g5 / 2.0 - g0) * (h / 2.0) / ssf
            let (g0w, g6w) = (g0 * w / ssf, g6 * w / ssf)
            let rx = (g6w - g0w) / 2.0
            let cx = g0w + rx
            b.m(w, 0.0).arc(w, h / 2.0, 270.0, -180.0)
            if rx > 1e-9 && dy1 > 1e-9 {
                // From the bottom-right corner back up to the top-right through (g0w, h/2).
                let t0 = Darwin.atan2(((h / 2.0) / dy1).clamp(-1.0, 1.0), (w - cx) / rx)
                let t1 = Darwin.atan2((-(h / 2.0) / dy1).clamp(-1.0, 1.0), (w - cx) / rx) + 2.0 * Double.pi
                let arc = Arc(Point(cx, h / 2.0), Vec2(rx, dy1), t0, t1 - t0, 0.0)
                arc.toCubicBeziers(0.05) { p1, p2, q in b.p.curveTo(p1, p2, q) }
            }
            b.z()
            let g12 = g0 * 9598.0 / 32768.0
            let g13 = ss - g12
            let dy4 = fmax(ss * ss - g13 * g13, 0.0).squareRoot() * (h / 2.0) / ssf
            g = simple(b.take(), Rect(g12 * w / ssf, h / 2.0 - dy4, g0w, h / 2.0 + dy4), w, h)
        case "cloud", "cloudCallout":
            g = cloud(name, w, h, a(0), a(1))
        case "bracketPair":
            let r = ss * a(0).clamp(0.0, 50000.0) / 1e5
            let l = Pb()
            l.m(r, h).arc(r, r, 90.0, 90.0).l(0.0, r).arc(r, r, 180.0, 90.0)
            l.m(w - r, 0.0).arc(r, r, 270.0, 90.0).l(w, h - r).arc(r, r, 0.0, 90.0)
            let f = cornerRect(w, h, Array(repeating: .round(r), count: 4))
            g = Geometry(paths: [fillOnly(f), strokeOnly(l.take())], textRect: full.inset(-r * 0.29289), handles: [], sites: midSites(w, h))
        case "bracePair":
            let r = ss * a(0).clamp(0.0, 25000.0) / 1e5
            let l = Pb()
            l.m(2.0 * r, h).arc(r, r, 90.0, 90.0).l(r, h / 2.0 + r).arc(r, r, 0.0, -90.0).arc(r, r, 90.0, -90.0).l(r, r).arc(r, r, 180.0, 90.0)
            l.m(w - 2.0 * r, 0.0).arc(r, r, 270.0, 90.0).l(w - r, h / 2.0 - r).arc(r, r, 180.0, -90.0).arc(r, r, 270.0, -90.0)
                .l(w - r, h - r).arc(r, r, 0.0, 90.0)
            let f = cornerRect(w, h, Array(repeating: .round(r), count: 4))
            g = Geometry(paths: [fillOnly(f), strokeOnly(l.take())], textRect: full.inset(-r * 1.2), handles: [], sites: midSites(w, h))
        case "leftBracket", "rightBracket":
            let r = fmin(ss * a(0).clamp(0.0, 50000.0 * h / fmax(ss, 1e-9)) / 1e5, h / 2.0)
            let l = Pb()
            l.m(w, h).arc(w, r, 90.0, 90.0).l(0.0, r).arc(w, r, 180.0, 90.0)
            var path = l.take()
            if name == "rightBracket" { path.applyAffine(Affine(-1.0, 0.0, 0.0, 1.0, w, 0.0)) }
            // Filled (when the shape has a fill) out to the straight side, as PowerPoint does.
            var area = path
            area.closePath()
            g = Geometry(paths: [fillOnly(area), strokeOnly(path)], textRect: full, handles: [], sites: midSites(w, h))
        case "leftBrace", "rightBrace":
            let r = fmin(ss * a(0).clamp(0.0, 25000.0 * h / fmax(ss, 1e-9)) / 1e5, h / 4.0)
            let my = h * a(1).clamp(0.0, 100_000.0) / 1e5
            let hw = w / 2.0
            let l = Pb()
            l.m(w, h).arc(hw, r, 90.0, 90.0).l(hw, my + r).arc(hw, r, 0.0, -90.0).arc(hw, r, 90.0, -90.0).l(hw, r).arc(hw, r, 180.0, 90.0)
            var path = l.take()
            if name == "rightBrace" { path.applyAffine(Affine(-1.0, 0.0, 0.0, 1.0, w, 0.0)) }
            var area = path
            area.closePath()
            g = Geometry(paths: [fillOnly(area), strokeOnly(path)], textRect: full, handles: [], sites: midSites(w, h))
        case "rightArrow":
            g = arrow(.right, w, h, a(0), a(1))
        case "leftArrow":
            g = arrow(.left, w, h, a(0), a(1))
        case "upArrow":
            g = arrow(.up, w, h, a(0), a(1))
        case "downArrow":
            g = arrow(.down, w, h, a(0), a(1))
        case "leftRightArrow":
            g = doubleArrow(false, w, h, a(0), a(1))
        case "upDownArrow":
            g = doubleArrow(true, w, h, a(0), a(1))
        case "notchedRightArrow", "stripedRightArrow":
            g = arrow(.right, w, h, a(0), a(1))
            let k = a(0).clamp(0.0, 100_000.0) / 1e5
            let (y1, y2) = (h / 2.0 - h * k / 2.0, h / 2.0 + h * k / 2.0)
            let dx = fmin(ss * fmax(a(1), 0.0) / 1e5, w)
            if name == "notchedRightArrow" {
                // x1 = dy1 · dx2 / hd2 in presetShapeDefinitions, with dy1 = h·k/2: the notch's edges run
                // parallel to the head's
                let n = dx * k
                let pts = [(0.0, y1), (w - dx, y1), (w - dx, 0.0), (w, h / 2.0), (w - dx, h), (w - dx, y2), (0.0, y2), (n, h / 2.0)]
                g.paths = [fill(Pb().poly(pts).take())]
            } else {
                let s = ss / 32.0
                let start = 5.0 * s
                let pts = [(start, y1), (w - dx, y1), (w - dx, 0.0), (w, h / 2.0), (w - dx, h), (w - dx, y2), (start, y2)]
                let stripes = Pb()
                stripes.poly([(0.0, y1), (s, y1), (s, y2), (0.0, y2)])
                stripes.poly([(2.0 * s, y1), (4.0 * s, y1), (4.0 * s, y2), (2.0 * s, y2)])
                g.paths = [fill(stripes.take()), fill(Pb().poly(pts).take())]
            }
        case "homePlate", "chevron":
            let v = a(0).clamp(0.0, 100_000.0 * w / fmax(ss, 1e-9))
            let d = fmin(ss * v / 1e5, w)
            let pts: [(Double, Double)] = name == "homePlate"
                ? [(0.0, 0.0), (w - d, 0.0), (w, h / 2.0), (w - d, h), (0.0, h)]
                : [(0.0, 0.0), (w - d, 0.0), (w, h / 2.0), (w - d, h), (0.0, h), (d, h / 2.0)]
            // Text rectangles as presetShapeDefinitions give them: homePlate's runs to halfway along the
            // point; chevron's lies between the notch and the point's base (x1..x2) and covers the whole
            // width once those meet or cross (`?: dx x1 l`).
            let text: Rect
            if name == "homePlate" {
                text = Rect(0.0, 0.0, w - d / 2.0, h)
            } else if w - d > d {
                text = Rect(d, 0.0, w - d, h)
            } else {
                text = Rect(0.0, 0.0, w, h)
            }
            g = simple(b.poly(pts).take(), text, w, h)
            g.handles.append(.new(0, Point(w, 0.0), Vec2(-ss / 1e5, 0.0), v, 0.0, 100_000.0 * w / fmax(ss, 1e-9)))
        case "quadArrow":
            let (t, hw, hl) = (ss * a(0).clamp(0.0, 50000.0) / 1e5, ss * a(1).clamp(0.0, 50000.0) / 1e5, ss * a(2).clamp(0.0, 50000.0) / 1e5)
            let (cx, cy) = (w / 2.0, h / 2.0)
            let (t2, hw2) = (t / 2.0, hw)
            let pts = [
                (0.0, cy), (hl, cy - hw2), (hl, cy - t2), (cx - t2, cy - t2), (cx - t2, hl), (cx - hw2, hl), (cx, 0.0),
                (cx + hw2, hl), (cx + t2, hl), (cx + t2, cy - t2), (w - hl, cy - t2), (w - hl, cy - hw2), (w, cy),
                (w - hl, cy + hw2), (w - hl, cy + t2), (cx + t2, cy + t2), (cx + t2, h - hl), (cx + hw2, h - hl), (cx, h),
                (cx - hw2, h - hl), (cx - t2, h - hl), (cx - t2, cy + t2), (hl, cy + t2), (hl, cy + hw2),
            ]
            g = simple(b.poly(pts).take(), Rect(cx - t2, cy - t2, cx + t2, cy + t2), w, h)
        case "leftRightUpArrow":
            let (t, hw, hl) = (ss * a(0).clamp(0.0, 50000.0) / 1e5, ss * a(1).clamp(0.0, 50000.0) / 1e5, ss * a(2).clamp(0.0, 50000.0) / 1e5)
            let cx = w / 2.0
            let by = h - hw // horizontal shaft centre
            let pts = [
                (0.0, by), (hl, by - hw), (hl, by - t / 2.0), (cx - t / 2.0, by - t / 2.0), (cx - t / 2.0, hl), (cx - hw, hl),
                (cx, 0.0), (cx + hw, hl), (cx + t / 2.0, hl), (cx + t / 2.0, by - t / 2.0), (w - hl, by - t / 2.0), (w - hl, by - hw),
                (w, by), (w - hl, h), (w - hl, by + t / 2.0), (hl, by + t / 2.0), (hl, h),
            ]
            g = simple(b.poly(pts).take(), Rect(hl, by - t / 2.0, w - hl, by + t / 2.0), w, h)
        case "leftUpArrow", "bentUpArrow":
            let (t, hw, hl) = (ss * a(0).clamp(0.0, 50000.0) / 1e5, ss * a(1).clamp(0.0, 50000.0) / 1e5, ss * a(2).clamp(0.0, 50000.0) / 1e5)
            let pts: [(Double, Double)]
            if name == "leftUpArrow" {
                let cx = w - hw
                let cy = h - hw
                pts = [
                    (0.0, cy), (hl, cy - hw), (hl, cy - t / 2.0), (cx - t / 2.0, cy - t / 2.0), (cx - t / 2.0, hl), (cx - hw, hl),
                    (cx, 0.0), (w, hl), (cx + t / 2.0, hl), (cx + t / 2.0, cy + t / 2.0), (hl, cy + t / 2.0), (hl, h),
                ]
            } else {
                let cx = w - hw
                pts = [
                    (0.0, h - t), (cx - t / 2.0, h - t), (cx - t / 2.0, hl), (cx - hw, hl), (cx, 0.0), (w, hl),
                    (cx + t / 2.0, hl), (cx + t / 2.0, h), (0.0, h),
                ]
            }
            g = simple(b.poly(pts).take(), full, w, h)
        case "bentArrow":
            let (t, hw, hl, r) = (
                ss * a(0).clamp(0.0, 50000.0) / 1e5, ss * a(1).clamp(0.0, 50000.0) / 1e5,
                ss * a(2).clamp(0.0, 50000.0) / 1e5, ss * a(3).clamp(0.0, 100_000.0) / 1e5
            )
            let cy = hw // head centre line
            let ro = fmax(r, t)
            let ri = fmax(ro - t, 0.0)
            b.m(0.0, h).l(0.0, cy - t / 2.0 + ro).arc(ro, ro, 180.0, 90.0).l(w - hl, cy - t / 2.0).l(w - hl, 0.0)
                .l(w, cy).l(w - hl, 2.0 * hw).l(w - hl, cy + t / 2.0)
            b.l(t + ri, cy + t / 2.0)
            if ri > 0.0 { b.arc(ri, ri, 270.0, -90.0) }
            b.l(t, h).z()
            g = simple(b.take(), full, w, h)
        case "uturnArrow":
            let (t, hw, hl, r) = (
                ss * a(0).clamp(0.0, 25000.0) / 1e5, ss * a(1).clamp(0.0, 25000.0) / 1e5,
                ss * a(2).clamp(0.0, 25000.0) / 1e5, ss * a(3).clamp(0.0, 100_000.0) / 1e5
            )
            let hy = fmax(h * a(4).clamp(0.0, 100_000.0) / 1e5, hl + t)
            let ax = w - hw // arrow shaft centre x
            let ro = fmin(fmax(r, t), (ax + t / 2.0) / 2.0)
            let ri = fmax(ro - t, 0.0)
            b.m(0.0, h).l(0.0, ro).arc(ro, ro, 180.0, 90.0).l(ax + t / 2.0 - ro, 0.0).arc(ro, ro, 270.0, 90.0)
            b.l(ax + t / 2.0, hy - hl).l(w, hy - hl).l(ax, hy).l(ax - hw, hy - hl).l(ax - t / 2.0, hy - hl).l(ax - t / 2.0, ro)
            if ri > 0.0 { b.arc(ri, ri, 0.0, -90.0) }
            b.l(t + ri, t)
            if ri > 0.0 { b.arc(ri, ri, 270.0, -90.0) }
            b.l(t, h).z()
            g = simple(b.take(), full, w, h)
        case "rightArrowCallout", "leftArrowCallout", "upArrowCallout", "downArrowCallout":
            let d: Dir = switch name {
            case "rightArrowCallout": .right
            case "leftArrowCallout": .left
            case "upArrowCallout": .up
            default: .down
            }
            let (l, t) = lenThick(d, w, h)
            let ss2 = fmin(l, t)
            let shaft = ss2 * a(0).clamp(0.0, 100_000.0) / 1e5
            let head = ss2 * a(1).clamp(0.0, 100_000.0) / 1e5
            let hl = ss2 * a(2).clamp(0.0, 100_000.0) / 1e5
            let boxl = fmin(l * a(3).clamp(0.0, 100_000.0) / 1e5, l - hl)
            let c = t / 2.0
            let pts = orient(d, w, h, [
                (0.0, 0.0), (boxl, 0.0), (boxl, c - shaft / 2.0), (l - hl, c - shaft / 2.0), (l - hl, c - head), (l, c),
                (l - hl, c + head), (l - hl, c + shaft / 2.0), (boxl, c + shaft / 2.0), (boxl, t), (0.0, t),
            ])
            let tr = orient(d, w, h, [(0.0, 0.0), (boxl, t)])
            g = simple(b.poly(pts).take(), Rect.fromPoints(pt(tr[0]), pt(tr[1])).abs, w, h)
        case "mathPlus", "mathMinus", "mathEqual", "mathDivide", "mathMultiply", "mathNotEqual":
            g = math(name, w, h, a(0), a(1), a(2))
        case "flowChartPredefinedProcess":
            let r = Pb().poly([(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]).take()
            let l = Pb()
            l.m(w / 8.0, 0.0).l(w / 8.0, h).m(w * 7.0 / 8.0, 0.0).l(w * 7.0 / 8.0, h)
            g = Geometry(paths: [fill(r), strokeOnly(l.take())], textRect: Rect(w / 8.0, 0.0, w * 7.0 / 8.0, h), handles: [], sites: midSites(w, h))
        case "flowChartInternalStorage":
            let r = Pb().poly([(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]).take()
            let l = Pb()
            l.m(w / 8.0, 0.0).l(w / 8.0, h).m(0.0, h / 8.0).l(w, h / 8.0)
            g = Geometry(paths: [fill(r), strokeOnly(l.take())], textRect: Rect(w / 8.0, h / 8.0, w, h), handles: [], sites: midSites(w, h))
        case "flowChartDocument":
            func u(_ x: Double, _ y: Double) -> (Double, Double) { (w * x / 21600.0, h * y / 21600.0) }
            let (p1, p2, p3, p4) = (u(21600.0, 17322.0), u(10800.0, 17322.0), u(10800.0, 23922.0), u(0.0, 20172.0))
            b.m(0.0, 0.0).l(w, 0.0).l(p1.0, p1.1).c(p2.0, p2.1, p3.0, p3.1, p4.0, p4.1).z()
            g = simple(b.take(), Rect(0.0, 0.0, w, h * 17322.0 / 21600.0), w, h)
        case "flowChartMultidocument":
            // ECMA-376 multidocument (21600ths): two back pages peeking out above and right of the front
            // one; the back pages' edges are outlined only where they show.
            func x(_ v: Double) -> Double { w * v / 21600.0 }
            func y(_ v: Double) -> Double { h * v / 21600.0 }
            func front(_ b: Pb) {
                b.m(0.0, y(20782.0)).c(x(9298.0), y(23542.0), x(9298.0), y(18022.0), x(18595.0), y(18022.0))
                    .l(x(18595.0), y(3675.0)).l(0.0, y(3675.0)).z()
            }
            func mid(_ b: Pb) {
                b.m(x(1532.0), y(3675.0)).l(x(1532.0), y(1815.0)).l(x(20000.0), y(1815.0)).l(x(20000.0), y(16252.0))
                b.c(x(19298.0), y(16252.0), x(18595.0), y(16352.0), x(18595.0), y(16352.0))
            }
            func back(_ b: Pb) {
                b.m(x(2972.0), y(1815.0)).l(x(2972.0), 0.0).l(w, 0.0).l(w, y(14392.0))
                b.c(x(20800.0), y(14392.0), x(20000.0), y(14467.0), x(20000.0), y(14467.0))
            }
            let area = Pb()
            front(area)
            mid(area)
            area.l(x(18595.0), y(3675.0)).z()
            back(area)
            area.l(x(20000.0), y(1815.0)).z()
            let outline = Pb()
            outline.m(0.0, y(3675.0)).l(x(18595.0), y(3675.0)).l(x(18595.0), y(18022.0))
            outline.c(x(9298.0), y(18022.0), x(9298.0), y(23542.0), 0.0, y(20782.0)).z()
            mid(outline)
            back(outline)
            g = Geometry(
                paths: [fillOnly(area.take()), strokeOnly(outline.take())],
                textRect: Rect(0.0, y(3675.0), x(18595.0), y(17322.0)), handles: [], sites: midSites(w, h)
            )
        case "flowChartTerminator":
            let rx = fmin(w * 0.16, w / 2.0)
            b.m(rx, 0.0).l(w - rx, 0.0).arc(rx, h / 2.0, 270.0, 180.0).l(rx, h).arc(rx, h / 2.0, 90.0, 180.0).z()
            g = simple(b.take(), Rect(rx * 0.3, h * 0.15, w - rx * 0.3, h * 0.85), w, h)
        case "flowChartManualInput":
            g = simple(b.poly([(0.0, h / 5.0), (w, 0.0), (w, h), (0.0, h)]).take(), Rect(0.0, h / 5.0, w, h), w, h)
        case "flowChartOffpageConnector":
            g = simple(b.poly([(0.0, 0.0), (w, 0.0), (w, h * 0.8), (w / 2.0, h), (0.0, h * 0.8)]).take(), Rect(0.0, 0.0, w, h * 0.8), w, h)
        case "flowChartPunchedCard":
            g = simple(b.poly([(w * 0.2, 0.0), (w, 0.0), (w, h), (0.0, h), (0.0, h * 0.2)]).take(), Rect(0.0, h * 0.2, w, h), w, h)
        case "flowChartPunchedTape":
            // ECMA-376: each long edge is two half-ellipses a quarter of the width wide and a tenth of the
            // height deep, one bulging in and one out.
            let (rx, ry) = (w / 4.0, h / 10.0)
            b.m(0.0, ry).arc(rx, ry, 180.0, -180.0).arc(rx, ry, 180.0, 180.0).l(w, h - ry).arc(rx, ry, 0.0, -180.0).arc(rx, ry, 0.0, 180.0).z()
            g = simple(b.take(), Rect(0.0, h / 5.0, w, h * 0.8), w, h)
        case "flowChartSummingJunction", "flowChartOr":
            let e = Pb().ellipse(w / 2.0, h / 2.0, w / 2.0, h / 2.0).take()
            let l = Pb()
            if name == "flowChartOr" {
                l.m(w / 2.0, 0.0).l(w / 2.0, h).m(0.0, h / 2.0).l(w, h / 2.0)
            } else {
                let k = 0.707_106_781_186_547_524_400_844_362_104_849_039 // FRAC_1_SQRT_2
                let (dx, dy) = (w / 2.0 * k, h / 2.0 * k)
                l.m(w / 2.0 - dx, h / 2.0 - dy).l(w / 2.0 + dx, h / 2.0 + dy).m(w / 2.0 + dx, h / 2.0 - dy).l(w / 2.0 - dx, h / 2.0 + dy)
            }
            g = Geometry(paths: [fill(e), strokeOnly(l.take())], textRect: ell, handles: [], sites: ellipseSites(w, h))
        case "flowChartCollate":
            g = simple(b.poly([(0.0, 0.0), (w, 0.0), (0.0, h), (w, h)]).take(), Rect(w / 4.0, h / 4.0, w * 0.75, h * 0.75), w, h)
        case "flowChartOnlineStorage":
            let rx = w / 6.0
            b.m(rx, 0.0).l(w, 0.0).arc(rx, h / 2.0, 270.0, -180.0).l(rx, h).arc(rx, h / 2.0, 90.0, 180.0).z()
            g = simple(b.take(), Rect(rx, 0.0, w - rx, h), w, h)
        case "flowChartDelay":
            b.m(0.0, 0.0).l(w / 2.0, 0.0).arc(w / 2.0, h / 2.0, 270.0, 180.0).l(0.0, h).z()
            g = simple(b.take(), Rect(0.0, h * 0.15, w * 0.85, h * 0.85), w, h)
        case "flowChartMagneticTape":
            b.m(w / 2.0, h).arc(w / 2.0, h / 2.0, 90.0, 90.0).arc(w / 2.0, h / 2.0, 180.0, 90.0).arc(w / 2.0, h / 2.0, 270.0, 90.0)
                .arc(w / 2.0, h / 2.0, 0.0, 45.0)
            let p = b.cur
            b.l(w, p.y).l(w, h).z()
            g = simple(b.take(), ell, w, h)
        case "flowChartDisplay":
            let rx = w / 6.0
            b.m(0.0, h / 2.0).l(rx, 0.0).l(w - rx, 0.0).arc(rx, h / 2.0, 270.0, 180.0).l(rx, h).z()
            g = simple(b.take(), Rect(rx, 0.0, w - rx, h), w, h)
        case "star4", "star5", "star6", "star7", "star8", "star10", "star12", "star16", "star24", "star32":
            let n = Int(name.dropFirst(4)) ?? 5
            let v = a(0).clamp(0.0, 50000.0)
            let inner = v / 50000.0
            let text = starTextRect(n, w, h, inner) ?? full.inset(-ss * (0.5 - inner * 0.5) * 0.5)
            g = simple(b.poly(star(n, w, h, inner)).take(), text, w, h)
            g.handles.append(.new(0, Point(w / 2.0, h / 2.0), Vec2(0.0, -h / 2.0 / 50000.0), v, 0.0, 50000.0))
        case "irregularSeal1":
            // ECMA-376 irregularSeal1 ("Explosion: 8 Points"), in 21600ths of the box.
            let pts = specPts([
                (10800, 5800), (14522, 0), (14155, 5325), (18380, 4457), (16702, 7315), (21097, 8137), (17607, 10475),
                (21600, 13290), (16837, 12942), (18145, 18095), (14020, 14457), (13247, 19737), (10532, 14935),
                (8485, 21600), (7715, 15627), (4762, 17617), (5667, 13937), (135, 14587), (3722, 11775), (0, 8615),
                (4627, 7617), (370, 2295), (7312, 6320), (8352, 2295),
            ], w, h)
            g = simple(b.poly(pts).take(), Rect(w * 4627.0 / 21600.0, h * 6320.0 / 21600.0, w * 16702.0 / 21600.0, h * 13937.0 / 21600.0), w, h)
        case "irregularSeal2":
            // ECMA-376 irregularSeal2 ("Explosion: 14 Points"), in 21600ths of the box.
            let pts = specPts([
                (11462, 4342), (14790, 0), (14525, 5777), (18007, 3172), (16380, 6532), (21600, 6645), (16985, 9402),
                (18270, 11290), (16380, 12310), (18877, 15632), (14640, 14350), (14942, 17370), (12180, 15935),
                (11612, 18842), (9872, 17370), (8700, 19712), (7527, 18125), (4917, 21600), (4805, 18240), (1285, 17825),
                (3330, 15370), (0, 12877), (3935, 11592), (1172, 8270), (5372, 7817), (4502, 3625), (8550, 6382), (9722, 1887),
            ], w, h)
            g = simple(b.poly(pts).take(), Rect(w * 5372.0 / 21600.0, h * 6382.0 / 21600.0, w * 14640.0 / 21600.0, h * 15935.0 / 21600.0), w, h)
        case "ribbon", "ribbon2":
            g = ribbon(name == "ribbon2", w, h, a(0), a(1))
        case "verticalScroll", "horizontalScroll":
            g = scroll(name == "verticalScroll", w, h, a(0))
        case "wave", "doubleWave":
            // ECMA-376 wave / doubleWave: the top and bottom edges are cubic waves (one or two periods) of
            // amplitude adj1, shifted sideways by adj2.
            let a1 = a(0).clamp(0.0, name == "wave" ? 20000.0 : 12500.0)
            let a2 = a(1).clamp(-10000.0, 10000.0)
            let y1 = h * a1 / 100_000.0
            let dy2 = y1 * 10.0 / 3.0
            let (y2, y3, y4) = (y1 - dy2, y1 + dy2, h - y1)
            let (y5, y6) = (y4 - dy2, y4 + dy2)
            let of2 = w * a2 / 50000.0
            let dx2 = fmin(of2, 0.0)
            let dxr = fmax(of2, 0.0)
            let (x2, xr, xl, x10) = (-dx2, w - dxr, dxr, w + dx2)
            let textY = h * a1 / 50000.0
            if name == "wave" {
                let dx3 = (dx2 + xr) / 3.0
                let (x3, x7) = (x2 + dx3, xl + dx3)
                let (x4, x8) = ((x3 + xr) / 2.0, (x7 + x10) / 2.0)
                b.m(x2, y1).c(x3, y2, x4, y3, xr, y1).l(x10, y4).c(x8, y6, x7, y5, xl, y4).z()
            } else {
                let (dx3, dx4) = ((dx2 + xr) / 6.0, (dx2 + xr) / 3.0)
                let (x3, x4, x5) = (x2 + dx3, x2 + dx4, (x2 + xr) / 2.0)
                let x6 = x5 + dx3
                let x7 = (x6 + xr) / 2.0
                let (x10b, x11, x12) = (xl + dx3, xl + dx4, (xl + x10) / 2.0)
                let x13 = x12 + dx3
                let x14 = (x13 + x10) / 2.0
                b.m(x2, y1).c(x3, y2, x4, y3, x5, y1).c(x6, y2, x7, y3, xr, y1).l(x10, y4)
                b.c(x14, y6, x13, y5, x12, y4).c(x11, y6, x10b, y5, xl, y4).z()
            }
            g = simple(b.take(), Rect(fmax(x2, xl), textY, fmin(xr, x10), h - textY), w, h)
        case "wedgeRectCallout", "wedgeRoundRectCallout":
            let r = name == "wedgeRoundRectCallout" ? ss * a(2).clamp(0.0, 50000.0) / 1e5 : 0.0
            g = wedgeRect(w, h, a(0), a(1), r)
        case "wedgeEllipseCallout":
            let tip = Point(w / 2.0 + w * a(0) / 1e5, h / 2.0 + h * a(1) / 1e5)
            let ang = Darwin.atan2(tip.y - h / 2.0, tip.x - w / 2.0).degrees
            let s = vis(ang + 10.0, w / 2.0, h / 2.0)
            let p0 = Point(w / 2.0 + w / 2.0 * sinCos(s.radians).cos, h / 2.0 + h / 2.0 * sinCos(s.radians).sin)
            let e = vis(ang - 10.0, w / 2.0, h / 2.0)
            var sw = e - s
            if sw <= 0.0 { sw += 360.0 }
            b.m(p0.x, p0.y).arc(w / 2.0, h / 2.0, s, sw).l(tip.x, tip.y).z()
            g = simple(b.take(), ell, w, h)
            g.handles = [tipHandle(w, h, tip)]
        case "borderCallout1":
            let r = Pb().poly([(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]).take()
            let p1 = (w * a(1) / 1e5, h * a(0) / 1e5)
            let p2 = (w * a(3) / 1e5, h * a(2) / 1e5)
            let l = Pb().m(p1.0, p1.1).l(p2.0, p2.1).take()
            g = Geometry(paths: [fill(r), strokeOnly(l)], textRect: full, handles: [], sites: midSites(w, h))
        case "line", "straightConnector1":
            let l = Pb().m(0.0, 0.0).l(w, h).take()
            g = Geometry(paths: [strokeOnly(l)], textRect: full, handles: [], sites: [.zero, Point(w, h)])
        case "bentConnector2":
            let l = Pb().m(0.0, 0.0).l(w, 0.0).l(w, h).take()
            g = Geometry(paths: [strokeOnly(l)], textRect: full, handles: [], sites: [.zero, Point(w, h)])
        case "bentConnector3", "bentConnector4", "bentConnector5":
            let x = w * a(0) / 1e5
            let l = Pb().m(0.0, 0.0).l(x, 0.0).l(x, h).l(w, h).take()
            g = Geometry(paths: [strokeOnly(l)], textRect: full, handles: [], sites: [.zero, Point(w, h)])
            g.handles.append(.new(0, Point(0.0, h / 2.0), Vec2(w / 1e5, 0.0), a(0), -1e6, 1e6))
        case "curvedConnector2", "curvedConnector3", "curvedConnector4", "curvedConnector5":
            let x = w * (name == "curvedConnector2" ? 100_000.0 : a(0)) / 1e5
            let l = Pb().m(0.0, 0.0).c(x / 2.0, 0.0, x, h / 4.0, x, h / 2.0).c(x, h * 0.75, (x + w) / 2.0, h, w, h).take()
            g = Geometry(paths: [strokeOnly(l)], textRect: full, handles: [], sites: [.zero, Point(w, h)])
        default:
            return buildExtra(name, w, h, a)
        }
        return g
    }

    static func wedgeRect(_ w: Double, _ h: Double, _ a0: Double, _ a1: Double, _ rIn: Double) -> Geometry {
        let tip = Point(w / 2.0 + w * a0 / 1e5, h / 2.0 + h * a1 / 1e5)
        let inside = tip.x > 0.0 && tip.x < w && tip.y > 0.0 && tip.y < h
        let (dx, dy) = ((tip.x - w / 2.0) / fmax(w, 1e-9), (tip.y - h / 2.0) / fmax(h, 1e-9))
        let b = Pb()
        let r = fmin(fmin(rIn, w / 2.0), h / 2.0)
        // Walk clockwise from the top-left; insert the wedge on the edge facing the tip.
        let horiz = Swift.abs(dx) > Swift.abs(dy)
        // The wedge's base: 2..5 twelfths of the edge on the tip's side of the centre when it is before
        // it, 7..10 twelfths when after (presetShapeDefinitions' xg1/xg2, yg1/yg2).
        let (bx0, bx1) = tip.x < w / 2.0 ? (w * 2.0 / 12.0, w * 5.0 / 12.0) : (w * 7.0 / 12.0, w * 10.0 / 12.0)
        let (by0, by1) = tip.y < h / 2.0 ? (h * 2.0 / 12.0, h * 5.0 / 12.0) : (h * 7.0 / 12.0, h * 10.0 / 12.0)
        b.m(r, 0.0)
        if !inside && !horiz && dy < 0.0 { b.l(bx0, 0.0).l(tip.x, tip.y).l(bx1, 0.0) }
        b.l(w - r, 0.0)
        if r > 0.0 { b.arc(r, r, 270.0, 90.0) }
        if !inside && horiz && dx > 0.0 { b.l(w, by0).l(tip.x, tip.y).l(w, by1) }
        b.l(w, h - r)
        if r > 0.0 { b.arc(r, r, 0.0, 90.0) }
        if !inside && !horiz && dy > 0.0 { b.l(bx1, h).l(tip.x, tip.y).l(bx0, h) }
        b.l(r, h)
        if r > 0.0 { b.arc(r, r, 90.0, 90.0) }
        if !inside && horiz && dx < 0.0 { b.l(0.0, by1).l(tip.x, tip.y).l(0.0, by0) }
        b.l(0.0, r)
        if r > 0.0 { b.arc(r, r, 180.0, 90.0) }
        b.z()
        var g = simple(b.take(), Rect(0.0, 0.0, w, h).inset(-r * 0.29289), w, h)
        g.handles.append(tipHandle(w, h, tip))
        return g
    }

    /// ECMA-376 cloud outline arcs (radii in 43200ths of the box, angles in 60000ths of a degree, as
    /// DrawingML `arcTo` takes them), from the start point (3900, 14370).
    static let cloudArcs: [(Double, Double, Double, Double)] = [
        (6753.0, 9190.0, -11_429_249.0, 7_426_832.0),
        (5333.0, 7267.0, -8_646_143.0, 5_396_714.0),
        (4365.0, 5945.0, -8_748_475.0, 5_983_381.0),
        (4857.0, 6595.0, -7_859_164.0, 7_034_504.0),
        (5333.0, 7273.0, -4_722_533.0, 6_541_615.0),
        (6775.0, 9220.0, -2_776_035.0, 7_816_140.0),
        (5785.0, 7867.0, 37501.0, 6_842_000.0),
        (6752.0, 9215.0, 1_347_096.0, 6_910_353.0),
        (7720.0, 10543.0, 3_974_558.0, 4_542_661.0),
        (4360.0, 5918.0, -16_496_525.0, 8_804_134.0),
        (4345.0, 5945.0, -14_809_710.0, 9_151_131.0),
    ]

    /// The cloud's creases: short arcs inside the outline, each from its own start point.
    static let cloudCreases: [(Double, Double, Double, Double, Double, Double)] = [
        (4693.0, 26177.0, 4345.0, 5945.0, 5_204_520.0, 1_585_770.0),
        (6928.0, 34899.0, 4360.0, 5918.0, 4_416_628.0, 686_848.0),
        (16478.0, 39090.0, 6752.0, 9215.0, 8_257_449.0, 844_866.0),
        (28827.0, 34751.0, 6752.0, 9215.0, 387_196.0, 959_901.0),
        (34129.0, 22954.0, 5785.0, 7867.0, -4_217_541.0, 4_255_042.0),
        (41798.0, 15354.0, 5333.0, 7273.0, 1_819_082.0, 1_665_090.0),
        (38324.0, 5426.0, 4857.0, 6595.0, -824_660.0, 891_534.0),
        (29078.0, 3952.0, 4857.0, 6595.0, -8_950_887.0, 1_091_722.0),
        (22141.0, 4720.0, 4365.0, 5945.0, -9_809_656.0, 1_061_181.0),
        (14000.0, 5192.0, 6753.0, 9190.0, -4_002_417.0, 739_161.0),
        (4127.0, 15789.0, 6753.0, 9190.0, 9_459_261.0, 711_490.0),
    ]

    static func cloud(_ name: String, _ w: Double, _ h: Double, _ a0: Double, _ a1: Double) -> Geometry {
        // Drawn in the path's own 43200-unit square, then stretched to the box (as DrawingML lays out a
        // path with its own w and h), so the arcs keep their shape's proportions at any aspect.
        let toBox = Affine.scaleNonUniform(w / 43200.0, h / 43200.0)
        func deg(_ v: Double) -> Double { v / 60000.0 }
        let b = Pb()
        b.m(3900.0, 14370.0)
        for (wr, hr, st, sw) in cloudArcs { b.arcSpec(wr, hr, deg(st), deg(sw)) }
        b.z()
        let creases = Pb()
        for (x, y, wr, hr, st, sw) in cloudCreases { creases.m(x, y).arcSpec(wr, hr, deg(st), deg(sw)) }
        var outline = b.take()
        outline.applyAffine(toBox)
        var paths = [fill(outline)]
        if name == "cloud" {
            var c = creases.take()
            c.applyAffine(toBox)
            paths.append(strokeOnly(c))
        }
        let textRect = Rect(w * 2977.0 / 21600.0, h * 3262.0 / 21600.0, w * 17087.0 / 21600.0, h * 17337.0 / 21600.0)
        var handles: [Handle] = []
        if name == "cloudCallout" {
            let tip = Point(w / 2.0 + w * a0 / 1e5, h / 2.0 + h * a1 / 1e5)
            let c = Point(w / 2.0, h / 2.0)
            let bubbles = Pb()
            for (k, r) in [(0.55, 0.06), (0.75, 0.045), (0.95, 0.03)] {
                let p = c + (tip - c) * k
                if !(p.x > w * 0.1 && p.x < w * 0.9 && p.y > h * 0.1 && p.y < h * 0.9) || k > 0.9 {
                    bubbles.ellipse(p.x, p.y, w * r, h * r)
                }
            }
            paths.append(fill(bubbles.take()))
            handles.append(tipHandle(w, h, tip))
        }
        return Geometry(paths: paths, textRect: textRect, handles: handles, sites: midSites(w, h))
    }

    /// The equation shapes, by ECMA-376's formulas (checked against PowerPoint's outlines at several sizes
    /// and adjust values). Their bars span 73.49% of the width; the plus and multiply bars are `adj1` of
    /// the shorter side thick, the others' `adj1` of the height.
    static func math(_ name: String, _ w: Double, _ h: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Geometry {
        func pin(_ lo: Double, _ v: Double, _ hi: Double) -> Double { fmin(fmax(v, lo), fmax(hi, lo)) }
        let ss = fmin(w, h)
        let (hc, vc) = (w / 2.0, h / 2.0)
        let dx1 = w * 73490.0 / 200_000.0
        let (x1, x2) = (hc - dx1, hc + dx1)
        let b = Pb()
        let text: Rect
        switch name {
        case "mathPlus":
            let av = pin(0.0, a0, 73490.0)
            let dy1 = h * 73490.0 / 200_000.0
            let dx2 = ss * av / 200_000.0
            let (y1, y2, y3, y4) = (vc - dy1, vc - dx2, vc + dx2, vc + dy1)
            let (xa, xb) = (hc - dx2, hc + dx2)
            b.poly([(x1, y2), (xa, y2), (xa, y1), (xb, y1), (xb, y2), (x2, y2), (x2, y3), (xb, y3), (xb, y4), (xa, y4), (xa, y3), (x1, y3)])
            text = Rect(x1, y2, x2, y3)
        case "mathMinus":
            let dy1 = h * pin(0.0, a0, 100_000.0) / 200_000.0
            b.poly([(x1, vc - dy1), (x2, vc - dy1), (x2, vc + dy1), (x1, vc + dy1)])
            text = Rect(x1, vc - dy1, x2, vc + dy1)
        case "mathEqual":
            let av = pin(0.0, a0, 36745.0)
            let gv = pin(0.0, a1, 100_000.0 - 2.0 * av)
            let (dy1, dy2) = (h * av / 100_000.0, h * gv / 200_000.0)
            let (y2, y3) = (vc - dy2, vc + dy2)
            let (y1, y4) = (y2 - dy1, y3 + dy1)
            b.poly([(x1, y1), (x2, y1), (x2, y2), (x1, y2)])
            b.poly([(x1, y3), (x2, y3), (x2, y4), (x1, y4)])
            text = Rect(x1, y1, x2, y4)
        case "mathNotEqual":
            let av = pin(0.0, a0, 50000.0)
            let crAng = pin(4_200_000.0, a1, 6_600_000.0)
            let gv = pin(0.0, a2, 100_000.0 - 2.0 * av)
            let (dy1, dy2) = (h * av / 100_000.0, h * gv / 200_000.0)
            let hd2 = fmax(h / 2.0, 1e-9)
            let (y2, y3) = (vc - dy2, vc + dy2)
            let (y1, y4) = (y2 - dy1, y3 + dy1)
            let cadj2 = crAng - 5_400_000.0
            let xadj2 = hd2 * Darwin.tan((cadj2 / 60000.0).radians)
            let len = Darwin.hypot(xadj2, hd2)
            let bhw = len * dy1 / hd2
            let x7 = hc + xadj2 - bhw / 2.0
            func at(_ y: Double) -> Double { x7 - xadj2 * y / hd2 }
            let (x6, x5, x4, x3) = (at(y1), at(y2), at(y3), at(y4))
            let rx7 = x7 + bhw
            let dx7 = dy1 * hd2 / len
            let dy3 = dy1 * xadj2 / len
            let (rx, lx, ry, ly) = cadj2 > 0.0 ? (x7 + dx7, x7, dy3, 0.0) : (rx7, rx7 - dx7, 0.0, -dy3)
            b.poly([
                (x1, y1), (x6, y1), (lx, ly), (rx, ry), (x6 + bhw, y1), (x2, y1), (x2, y2), (x5 + bhw, y2), (x4 + bhw, y3),
                (x2, y3), (x2, y4), (x3 + bhw, y4), (w - lx, h - ly), (w - rx, h - ry), (x3, y4), (x1, y4), (x1, y3), (x4, y3),
                (x5, y2), (x1, y2),
            ])
            text = Rect(x1, y1, x2, y4)
        case "mathDivide":
            let av = pin(1000.0, a0, 36745.0)
            let max3 = fmin((73490.0 - av) / 4.0, 36745.0 * w / fmax(h, 1e-9))
            let r3 = pin(1000.0, a2, max3)
            let gv = pin(0.0, a1, 73490.0 - 4.0 * r3 - av)
            let dy1 = h * av / 200_000.0
            let yg = h * gv / 100_000.0
            let rad = h * r3 / 100_000.0
            let (y3, y4) = (vc - dy1, vc + dy1)
            let y2 = y3 - (yg + rad)
            let y1 = y2 - rad
            b.ellipse(hc, y1 + rad, rad, rad)
            b.ellipse(hc, h - y1 - rad, rad, rad)
            b.poly([(x1, y3), (x2, y3), (x2, y4), (x1, y4)])
            text = Rect(x1, y3, x2, y4)
        default:
            // mathMultiply: an X whose arms run along the box's diagonals.
            let th = ss * pin(0.0, a0, 51965.0) / 100_000.0
            let ang = Darwin.atan2(h, w)
            let (sa, ca, ta) = (sinCos(ang).sin, sinCos(ang).cos, fmax(Darwin.tan(ang), 1e-9))
            let lm = Darwin.hypot(w, h) * (1.0 - 51965.0 / 100_000.0)
            let (xm, ym) = (ca * lm / 2.0, sa * lm / 2.0)
            let (dxam, dyam) = (sa * th / 2.0, ca * th / 2.0)
            let (xa, ya, xb, yb) = (xm - dxam, ym + dyam, xm + dxam, ym - dyam)
            let yc = (hc - xb) * ta + yb
            let (xd, xe) = (w - xb, w - xa)
            let xfe = (vc - ya) / ta
            let (xf, xl) = (xe - xfe, xa + xfe)
            let (yg, yh, yi) = (h - ya, h - yb, h - yc)
            b.poly([(xa, ya), (xb, yb), (hc, yc), (xd, yb), (xe, ya), (xf, vc), (xe, yg), (xd, yh), (hc, yi), (xb, yh), (xa, yg), (xl, vc)])
            text = Rect(xa, yb, xe, yh)
        }
        return Geometry(paths: [fill(b.take())], textRect: text, handles: [], sites: midSites(w, h))
    }

    static func ribbon(_ up: Bool, _ w: Double, _ h: Double, _ a0: Double, _ a1: Double) -> Geometry {
        let fold = h * a0.clamp(0.0, 33333.0) / 1e5
        let cw = w * a1.clamp(25000.0, 75000.0) / 1e5 // centre band width
        let x0 = (w - cw) / 2.0
        let x1 = w - x0
        let ear = w / 8.0
        let (top, bot) = (0.0, h)
        let b = Pb()
        let shadeP = Pb()
        if up {
            // centre band sits high; ends hang low.
            b.poly([(x0, top), (x1, top), (x1, bot - fold), (x0, bot - fold)])
            let ends = Pb()
            ends.poly([(0.0, fold), (x0 + ear * 0.5, fold), (x0 + ear * 0.5, bot), (0.0, bot), (ear, (fold + bot) / 2.0)])
            ends.poly([(w, fold), (x1 - ear * 0.5, fold), (x1 - ear * 0.5, bot), (w, bot), (w - ear, (fold + bot) / 2.0)])
            shadeP.poly([(x0, bot - fold), (x0 + ear * 0.5, bot - fold), (x0 + ear * 0.5, bot)])
            shadeP.poly([(x1, bot - fold), (x1 - ear * 0.5, bot - fold), (x1 - ear * 0.5, bot)])
            let text = Rect(x0, top, x1, bot - fold)
            return Geometry(paths: [fill(ends.take()), shade(shadeP.take(), .darkenLess), fill(b.take())], textRect: text, handles: [], sites: midSites(w, h))
        }
        b.poly([(x0, top + fold), (x1, top + fold), (x1, bot), (x0, bot)])
        let ends = Pb()
        ends.poly([(0.0, top), (x0 + ear * 0.5, top), (x0 + ear * 0.5, bot - fold), (0.0, bot - fold), (ear, (bot - fold) / 2.0)])
        ends.poly([(w, top), (x1 - ear * 0.5, top), (x1 - ear * 0.5, bot - fold), (w, bot - fold), (w - ear, (bot - fold) / 2.0)])
        shadeP.poly([(x0, top + fold), (x0 + ear * 0.5, top + fold), (x0 + ear * 0.5, top)])
        shadeP.poly([(x1, top + fold), (x1 - ear * 0.5, top + fold), (x1 - ear * 0.5, top)])
        let text = Rect(x0, top + fold, x1, bot)
        return Geometry(paths: [fill(ends.take()), shade(shadeP.take(), .darkenLess), fill(b.take())], textRect: text, handles: [], sites: midSites(w, h))
    }

    static func scroll(_ vertical: Bool, _ w: Double, _ h: Double, _ a0: Double) -> Geometry {
        let ss = fmin(w, h)
        let r = ss * a0.clamp(0.0, 25000.0) / 1e5 / 2.0
        let b = Pb()
        let curl = Pb()
        if vertical {
            b.poly([(r, r * 2.0), (w - r, r * 2.0), (w - r, h - r), (r, h - r)])
            b.ellipse(w / 2.0, r, w / 2.0 - r * 0.0, r)
            curl.ellipse(r, h - r, r, r)
            curl.ellipse(w - r * 2.0, r, r * 0.5, r * 0.5)
            let text = Rect(r, r * 2.0, w - r, h - r)
            return Geometry(paths: [fill(b.take()), shade(curl.take(), .darkenLess)], textRect: text, handles: [], sites: midSites(w, h))
        }
        b.poly([(r * 2.0, r), (w - r, r), (w - r, h - r), (r * 2.0, h - r)])
        b.ellipse(r, h / 2.0, r, h / 2.0)
        curl.ellipse(w - r, r, r, r)
        curl.ellipse(r, h - r * 2.0, r * 0.5, r * 0.5)
        let text = Rect(r * 2.0, r, w - r, h - r)
        return Geometry(paths: [fill(b.take()), shade(curl.take(), .darkenLess)], textRect: text, handles: [], sites: midSites(w, h))
    }

    static func actionButton(_ name: String, _ w: Double, _ h: Double) -> Geometry {
        let body = cornerRect(w, h, [.square, .square, .square, .square])
        let ss = fmin(w, h)
        let (cx, cy) = (w / 2.0, h / 2.0)
        let s = ss * 0.3
        let g = Pb()
        switch name {
        case "actionButtonBackPrevious":
            g.poly([(cx + s, cy - s), (cx + s, cy + s), (cx - s, cy)])
        case "actionButtonForwardNext":
            g.poly([(cx - s, cy - s), (cx - s, cy + s), (cx + s, cy)])
        case "actionButtonBeginning":
            g.poly([(cx + s, cy - s), (cx + s, cy + s), (cx - s * 0.6, cy)])
            g.poly([(cx - s, cy - s), (cx - s * 0.7, cy - s), (cx - s * 0.7, cy + s), (cx - s, cy + s)])
        case "actionButtonEnd":
            g.poly([(cx - s, cy - s), (cx - s, cy + s), (cx + s * 0.6, cy)])
            g.poly([(cx + s * 0.7, cy - s), (cx + s, cy - s), (cx + s, cy + s), (cx + s * 0.7, cy + s)])
        case "actionButtonHome":
            g.poly([(cx, cy - s), (cx + s, cy), (cx + s * 0.7, cy), (cx + s * 0.7, cy + s), (cx - s * 0.7, cy + s), (cx - s * 0.7, cy), (cx - s, cy)])
        case "actionButtonInformation", "actionButtonHelp":
            g.ellipse(cx, cy, s, s)
        case "actionButtonReturn":
            g.m(cx + s, cy - s * 0.6).l(cx + s, cy + s * 0.2).q(cx + s, cy + s * 0.8, cx + s * 0.4, cy + s * 0.8).l(cx - s * 0.5, cy + s * 0.8)
            g.l(cx - s * 0.5, cy + s * 0.4).l(cx - s, cy + s * 0.9).l(cx - s * 0.5, cy + s * 1.4).l(cx - s * 0.5, cy + s)
                .l(cx + s * 0.6, cy + s).l(cx + s * 0.6, cy - s * 0.6).z()
        case "actionButtonMovie":
            g.poly([(cx - s, cy - s * 0.6), (cx + s * 0.4, cy - s * 0.6), (cx + s * 0.4, cy + s * 0.6), (cx - s, cy + s * 0.6)])
            g.poly([(cx + s * 0.4, cy), (cx + s, cy - s * 0.5), (cx + s, cy + s * 0.5)])
        case "actionButtonDocument":
            g.poly([(cx - s * 0.7, cy - s), (cx + s * 0.3, cy - s), (cx + s * 0.7, cy - s * 0.6), (cx + s * 0.7, cy + s), (cx - s * 0.7, cy + s)])
        case "actionButtonSound":
            g.poly([(cx - s, cy - s * 0.35), (cx - s * 0.5, cy - s * 0.35), (cx, cy - s), (cx, cy + s), (cx - s * 0.5, cy + s * 0.35), (cx - s, cy + s * 0.35)])
        default:
            break
        }
        return Geometry(paths: [fill(body), shade(g.take(), .darkenLess)], textRect: Rect(0.0, 0.0, w, h), handles: [], sites: midSites(w, h))
    }
}
