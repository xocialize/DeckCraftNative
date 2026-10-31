// DCPPT — a legacy shape type ([MS-ODRAW] 2.4.24 MSOSPT) as a DrawingML preset, its adjust values rescaled.
//
// A legacy shape's adjust values are positions in a 21,600-unit square stretched over its box (so they scale with
// the width or the height), where DrawingML's are fractions of 100,000, most of them of the box's shorter side. Each
// conversion below is the inverse of what PowerPoint 16 writes when it saves a preset as .ppt: `Tools/legacy/
// preset-deck.py` makes a deck of every preset (wide, tall, and with its adjusts moved), PowerPoint saves it, and
// `ShapeTests` checks the import against the original shape by shape. An adjust a shape leaves out takes its type's
// default, which is what PowerPoint leaves out. Types PowerPoint never writes (it saves those presets as freeforms)
// map to the nearest preset at its defaults.
//
// LibreOffice writes DrawingML's adjust values scaled to 21,600 instead (a right arrow's 50,000 as 10,800, where
// PowerPoint writes the head's position); its files follow PowerPoint's meaning here, as PowerPoint reads them.
import DCModel

enum LegacyShapes {
    static let unit = 21600.0

    /// A shape type's geometry for a box `w` × `h` (any unit) with adjust values `adj` (1-based, as set by the shape).
    static func geometry(_ type: UInt16, _ adj: [Int: Int32], w: Double, h: Double) -> Geom {
        let ss = max(1e-9, min(abs(w), abs(h)))
        let w = max(1e-9, abs(w)), h = max(1e-9, abs(h))
        let u = unit
        var defaults: [Double] = []
        func a(_ i: Int) -> Double { adj[i].map(Double.init) ?? (defaults.indices.contains(i - 1) ? defaults[i - 1] : 0) }
        func preset(_ name: String, _ d: [Double] = [], _ values: () -> [Double] = { [] }) -> Geom {
            defaults = d
            return .preset(name: name, adj: values().map { ($0 * 100_000).rounded() })
        }
        // Fractions of the shorter side, of the width and of the height.
        func s(_ v: Double) -> Double { v / u }
        func wide(_ v: Double) -> Double { v / u * w / ss }
        func tall(_ v: Double) -> Double { v / u * h / ss }

        switch type {
        case 1, 202: return preset("rect")
        case 2: return preset("roundRect", [3600]) { [s(a(1))] }
        case 3: return preset("ellipse")
        case 4: return preset("diamond")
        case 5: return preset("triangle", [10800]) { [s(a(1))] }
        case 6: return preset("rtTriangle")
        case 7: return preset("parallelogram", [5400]) { [wide(a(1))] }
        case 8:
            // Wide at the top, unlike DrawingML's trapezoid (which, flipped, would turn its text upside down).
            defaults = [5400]
            let x = min(max(a(1), 0), u)
            return .custom(paths: [CustomPath(w: u, h: u, d: "M 0 0 L \(x) \(u) L \(u - x) \(u) L \(u) 0 Z", fill: .norm, stroke: true)])
        case 9: return preset("hexagon", [5400]) { [wide(a(1))] }
        case 10: return preset("octagon", [6326]) { [s(a(1))] }
        case 11: return preset("plus", [5400]) { [s(a(1))] }
        case 12: return preset("star5")
        case 13, 14: return preset("rightArrow", [16200, 5400]) { [1 - 2 * s(a(2)), (u - a(1)) / u * w / ss] }
        case 15: return preset("homePlate", [16200]) { [(u - a(1)) / u * w / ss] }
        case 16: return preset("cube", [5400]) { [s(a(1))] }
        case 17: return preset("wedgeRoundRectCallout", [1350, 25920]) { [s(a(1) - 10800), s(a(2) - 10800)] }
        case 18: return preset("star16", [2700]) { [s(10800 - a(1))] }
        case 19: return preset("arc", [-90 * 65536, 0]) { [angle(a(1)), angle(a(2))] }
        case 20: return preset("line")
        case 21: return preset("plaque", [3600]) { [s(a(1))] }
        case 22: return preset("can", [5400]) { [tall(a(1))] }
        case 23: return preset("donut", [5400]) { [s(a(1))] }
        case 32: return preset("straightConnector1")
        case 33: return preset("bentConnector2")
        case 34: return preset("bentConnector3", [10800]) { [s(a(1))] }
        case 35: return preset("bentConnector4", [10800, 10800]) { [s(a(1)), s(a(2))] }
        case 36: return preset("bentConnector5", [10800, 10800, 10800]) { [s(a(1)), s(a(2)), s(a(3))] }
        case 37: return preset("curvedConnector2")
        case 38: return preset("curvedConnector3", [10800]) { [s(a(1))] }
        case 39: return preset("curvedConnector4", [10800, 10800]) { [s(a(1)), s(a(2))] }
        case 40: return preset("curvedConnector5", [10800, 10800, 10800]) { [s(a(1)), s(a(2)), s(a(3))] }
        // Callouts: the legacy adjusts run from the line's far end back to the box, x before y; DrawingML's from the
        // box out, y before x.
        case 41, 44, 47, 50, 178, 179, 180, 181:
            let name = ["callout1", "accentCallout1", "borderCallout1", "accentBorderCallout1"][callout(type)]
            return preset(name, [-8280, 24300, -1800, 4050]) { [s(a(4)), s(a(3)), s(a(2)), s(a(1))] }
        case 42, 45, 48, 51:
            let name = ["callout2", "accentCallout2", "borderCallout2", "accentBorderCallout2"][callout(type)]
            return preset(name, [-10080, 24300, -3600, 4050, -1800, 4050]) { (1 ... 6).reversed().map { s(a($0)) } }
        case 43, 46, 49, 52:
            let name = ["callout3", "accentCallout3", "borderCallout3", "accentBorderCallout3"][callout(type)]
            return preset(name, [23400, 24400, 25200, 21600, 25200, 4050, 23400, 4050]) { (1 ... 8).reversed().map { s(a($0)) } }
        case 53: return preset("ribbon", [5400, 2700]) { [s(a(2)), 1 - 2 * s(a(1))] }
        case 54: return preset("ribbon2", [5400, 18900]) { [s(u - a(2)), 1 - 2 * s(a(1))] }
        case 55: return preset("chevron", [16200]) { [(u - a(1)) / u * w / ss] }
        case 56: return preset("pentagon")
        case 57: return preset("noSmoking", [2700]) { [s(a(1))] }
        case 58: return preset("star8", [2538]) { [s(10800 - a(1))] }
        case 59: return preset("star16", [2700]) { [s(10800 - a(1))] }
        case 60: return preset("star32", [2700]) { [s(10800 - a(1))] }
        case 61: return preset("wedgeRectCallout", [1350, 25920]) { [s(a(1) - 10800), s(a(2) - 10800)] }
        case 62: return preset("wedgeRoundRectCallout", [1350, 25920]) { [s(a(1) - 10800), s(a(2) - 10800)] }
        case 63: return preset("wedgeEllipseCallout", [1350, 25920]) { [s(a(1) - 10800), s(a(2) - 10800)] }
        case 64: return preset("wave", [2809, 10800]) { [s(a(1)), s(a(2) - 10800)] }
        case 65: return preset("foldedCorner", [18900]) { [s(u - a(1))] }
        case 66: return preset("leftArrow", [5400, 5400]) { [1 - 2 * s(a(2)), wide(a(1))] }
        case 67: return preset("downArrow", [16200, 5400]) { [1 - 2 * s(a(2)), (u - a(1)) / u * h / ss] }
        case 68: return preset("upArrow", [5400, 5400]) { [1 - 2 * s(a(2)), tall(a(1))] }
        case 69: return preset("leftRightArrow", [4320, 5400]) { [1 - 2 * s(a(2)), wide(a(1))] }
        case 70: return preset("upDownArrow", [5400, 4320]) { [1 - 2 * s(a(1)), tall(a(2))] }
        case 71: return preset("irregularSeal1")
        case 72: return preset("irregularSeal2")
        case 73: return preset("lightningBolt")
        case 74: return preset("heart")
        case 76: return preset("quadArrow")
        // Arrow callouts: the box's edge, the head's side, the head's base and the shaft's side, as positions.
        case 77: return preset("leftArrowCallout", [7200, 5400, 3600, 8100]) {
            [(h - 2 * h * s(a(4))) / ss, (h / 2 - h * s(a(2))) / ss, w * s(a(3)) / ss, 1 - s(a(1))] }
        case 78: return preset("rightArrowCallout", [14400, 5400, 18000, 8100]) {
            [(h - 2 * h * s(a(4))) / ss, (h / 2 - h * s(a(2))) / ss, (w - w * s(a(3))) / ss, s(a(1))] }
        case 79: return preset("upArrowCallout", [7200, 5400, 3600, 8100]) {
            [(w - 2 * w * s(a(4))) / ss, (w / 2 - w * s(a(2))) / ss, h * s(a(3)) / ss, 1 - s(a(1))] }
        case 80: return preset("downArrowCallout", [14400, 5400, 18000, 8100]) {
            [(w - 2 * w * s(a(4))) / ss, (w / 2 - w * s(a(2))) / ss, (h - h * s(a(3))) / ss, s(a(1))] }
        case 81: return preset("leftRightArrowCallout", [5400, 5400, 2700, 8100]) {
            [(h - 2 * h * s(a(4))) / ss, (h / 2 - h * s(a(2))) / ss, w * s(a(3)) / ss, 1 - 2 * s(a(1))] }
        case 82: return preset("upDownArrowCallout", [5400, 5400, 2700, 8100]) {
            [(w - 2 * w * s(a(4))) / ss, (w / 2 - w * s(a(2))) / ss, h * s(a(3)) / ss, 1 - 2 * s(a(1))] }
        case 83: return preset("quadArrowCallout")
        case 84: return preset("bevel", [2700]) { [s(a(1))] }
        case 85: return preset("leftBracket", [1800]) { [tall(a(1))] }
        case 86: return preset("rightBracket", [1800]) { [tall(a(1))] }
        case 87: return preset("leftBrace", [1800, 10800]) { [tall(a(1)), s(a(2))] }
        case 88: return preset("rightBrace", [1800, 10800]) { [tall(a(1)), s(a(2))] }
        case 89: return preset("leftUpArrow")
        case 90: return preset("bentUpArrow")
        case 91: return preset("bentArrow")
        case 92: return preset("star24", [2700]) { [s(10800 - a(1))] }
        case 93: return preset("stripedRightArrow")
        case 94: return preset("notchedRightArrow", [16200, 5400]) { [1 - 2 * s(a(2)), (u - a(1)) / u * w / ss] }
        case 95: return preset("blockArc", [180 * 65536, 5400]) { [angle(a(1)), angle(180 * 65536 - a(1)), s(a(2))] }
        case 96: return preset("smileyFace", [17520]) { [s(a(1) - 16515)] }
        case 97: return preset("verticalScroll", [2700]) { [s(a(1))] }
        case 98: return preset("horizontalScroll", [2700]) { [s(a(1))] }
        case 99, 100: return preset("circularArrow")
        case 101: return preset("uturnArrow")
        // Curved arrows: the head's side, the shaft's middle, and the head's base, as positions.
        case 102: return preset("curvedRightArrow", [12960, 19440, 14400]) {
            [2 * h * (1 - s(a(2))) / ss, h * (1 - s(a(1))) / ss, w * (1 - s(a(3))) / ss] }
        case 103: return preset("curvedLeftArrow", [12960, 19440, 7200]) {
            [2 * h * (1 - s(a(2))) / ss, h * (1 - s(a(1))) / ss, w * s(a(3)) / ss] }
        case 104: return preset("curvedUpArrow", [12960, 19440, 7200]) {
            [2 * w * (1 - s(a(2))) / ss, w * (1 - s(a(1))) / ss, h * s(a(3)) / ss] }
        case 105: return preset("curvedDownArrow", [12960, 19440, 14400]) {
            [2 * w * (1 - s(a(2))) / ss, w * (1 - s(a(1))) / ss, h * (1 - s(a(3))) / ss] }
        case 106: return preset("cloudCallout", [1350, 25920]) { [s(a(1) - 10800), s(a(2) - 10800)] }
        case 107: return preset("ellipseRibbon", [5400, 5400, 18900]) { [s(a(2)), 1 - 2 * s(a(1)), s(u - a(3))] }
        case 108: return preset("ellipseRibbon2", [5400, 16200, 2700]) { [s(u - a(2)), 1 - 2 * s(a(1)), s(a(3))] }
        case 109 ... 135: return preset(flowcharts[Int(type) - 109])
        case 176: return preset("flowChartAlternateProcess")
        case 177: return preset("flowChartOffpageConnector")
        case 182: return preset("leftRightUpArrow")
        case 183: return preset("sun", [5400]) { [s(a(1))] }
        case 184: return preset("moon", [10800]) { [s(a(1))] }
        case 185: return preset("bracketPair", [3600]) { [s(a(1))] }
        case 186: return preset("bracePair", [1800]) { [s(a(1))] }
        case 187: return preset("star4", [8100]) { [s(10800 - a(1))] }
        case 188: return preset("doubleWave", [1404, 10800]) { [s(a(1)), s(a(2) - 10800)] }
        case 189 ... 200: return preset(actionButtons[Int(type) - 189])
        default: return preset("rect")
        }
    }

    /// Which of a callout family's four kinds (plain, accent, border, accent and border) a type is.
    static func callout(_ type: UInt16) -> Int {
        switch type {
        case 178: 0
        case 179: 1
        case 180: 2
        case 181: 3
        default: (Int(type) - 41) / 3 % 4
        }
    }

    /// A legacy angle (16.16 degrees, clockwise from the x axis) as DrawingML's (60,000ths of a degree), over 100,000
    /// so `preset` scales it back.
    static func angle(_ v: Double) -> Double {
        var d = (v / 65536).truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d * 60000 / 100_000
    }

    static let flowcharts = [
        "flowChartProcess", "flowChartDecision", "flowChartInputOutput", "flowChartPredefinedProcess",
        "flowChartInternalStorage", "flowChartDocument", "flowChartMultidocument", "flowChartTerminator",
        "flowChartPreparation", "flowChartManualInput", "flowChartManualOperation", "flowChartConnector",
        "flowChartPunchedCard", "flowChartPunchedTape", "flowChartSummingJunction", "flowChartOr", "flowChartCollate",
        "flowChartSort", "flowChartExtract", "flowChartMerge", "flowChartOfflineStorage", "flowChartOnlineStorage",
        "flowChartMagneticTape", "flowChartMagneticDisk", "flowChartMagneticDrum", "flowChartDisplay", "flowChartDelay",
    ]

    static let actionButtons = [
        "actionButtonBlank", "actionButtonHome", "actionButtonHelp", "actionButtonInformation",
        "actionButtonForwardNext", "actionButtonBackPrevious", "actionButtonEnd", "actionButtonBeginning",
        "actionButtonReturn", "actionButtonDocument", "actionButtonSound", "actionButtonMovie",
    ]

    /// WordArt shape types (the legacy text shapes and the text effects): DrawingML's text warp for each.
    static func warp(_ type: UInt16) -> String? {
        switch type {
        case 24 ... 31: "textPlain"
        case 136 ... 175: wordArt[Int(type) - 136]
        default: nil
        }
    }

    static let wordArt = [
        "textPlain", "textStop", "textTriangle", "textTriangleInverted", "textChevron", "textChevronInverted",
        "textRingInside", "textRingOutside", "textArchUp", "textArchDown", "textCircle", "textButton", "textArchUpPour",
        "textArchDownPour", "textCirclePour", "textButtonPour", "textCurveUp", "textCurveDown", "textCascadeUp",
        "textCascadeDown", "textWave1", "textWave2", "textDoubleWave1", "textWave4", "textInflate", "textDeflate",
        "textInflateBottom", "textDeflateBottom", "textInflateTop", "textDeflateTop", "textDeflateInflate",
        "textDeflateInflateDeflate", "textFadeRight", "textFadeLeft", "textFadeUp", "textFadeDown", "textSlantUp",
        "textSlantDown", "textCanUp", "textCanDown",
    ]
}
