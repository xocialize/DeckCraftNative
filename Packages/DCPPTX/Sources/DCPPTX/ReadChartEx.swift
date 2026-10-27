// DCPPTX — Office 2016 charts (`cx:chartSpace`, the `chartEx` part): waterfall, funnel, treemap, sunburst,
// histogram, Pareto and box & whisker. Their data sits in `cx:chartData` as levels of points, and each
// series names its layout (`layoutId`). Port of deckcraft crates/pptx/src/read/chartex.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCModel

extension PPTXRead {
    /// Points per level and levels per dimension we keep (guards against hostile parts).
    static let maxChartexLevelPoints = 100_000
    static let maxChartexPoints = 1_000_000
    /// deckcraft-model's `chart::MAX_LEVELS`.
    static let maxCategoryLevels = 16

    /// One `cx:data`: its categories (the innermost level) and named numeric dimensions.
    struct ChartexData {
        var categories: [String] = []
        /// Outer category levels, innermost first.
        var levels: [[String]] = []
        /// Rust keeps these in a `HashMap`; `numberOrder` records first insertion so the one lookup
        /// that takes "any" value (`values().next()`) is deterministic here.
        var numbers: [ByteKey: ([Double?], String?)] = [:]
        var numberOrder: [ByteKey] = []
    }

    /// A level's points, by `idx`.
    static func points(_ lvl: XMLEl, _ budget: inout Int) -> [String] {
        if budget == 0 { return [] }
        let cap = Swift.min(maxChartexLevelPoints, budget)
        var pts: [(Int, String)] = []
        var maxIdx = 0
        for pt in lvl.childrenNamed("pt").prefix(cap) {
            let i = Int(pt.u32("idx") ?? 0)
            if i >= cap { continue }
            maxIdx = Swift.max(maxIdx, i + 1)
            pts.append((i, pt.text))
        }
        if pts.isEmpty { return [] }
        let n = Swift.min(maxIdx, cap)
        var out = Array(repeating: "", count: n)
        for (i, s) in pts where i < out.count { out[i] = s }
        budget = Swift.max(budget - out.count, 0)
        return out
    }

    static func chartexData(_ d: XMLEl, _ budget: inout Int) -> ChartexData {
        var out = ChartexData()
        for dim in d.elements.prefix(64) {
            if budget == 0 { break }
            // The first level is the innermost: a treemap's leaves, a waterfall's categories.
            guard let lvl = dim.child("lvl") else { continue }
            let ty = dim.attr("type") ?? ""
            if dim.is("strDim") || (dim.is("numDim") && bytesEqual(ty, "cat")) {
                if bytesEqual(ty, "cat") || out.categories.isEmpty {
                    out.categories = points(lvl, &budget)
                    // Further levels are the hierarchy's parents, innermost first.
                    var levels: [[String]] = []
                    for l in dim.childrenNamed("lvl").dropFirst().prefix(maxCategoryLevels) {
                        levels.append(points(l, &budget))
                    }
                    out.levels = levels
                }
            } else if dim.is("numDim") {
                let vals: [Double?] = points(lvl, &budget).map { s in rustParseF64(rustTrim(s)).flatMap { $0.isFinite ? $0 : nil } }
                let key = ByteKey(ty)
                if out.numbers[key] == nil { out.numberOrder.append(key) }
                out.numbers[key] = (vals, lvl.attr("formatCode"))
            }
        }
        return out
    }

    static func chartexKind(_ layout: String) -> ChartType? {
        switch layout {
        case "waterfall": .waterfall
        case "funnel": .funnel
        case "treemap": .treemap
        case "sunburst": .sunburst
        case "clusteredColumn": .histogram
        case "boxWhisker": .boxWhisker
        case "regionMap": .regionMap
        default: nil
        }
    }

    /// Parse a `chartEx` part. nil for anything else, and for layouts DeckCraft has no type for.
    static func readChartexXML(_ bytes: [UInt8]) -> Chart? {
        guard let doc = try? XML.parse(bytes) else { return nil }
        var root = doc.root
        resolveMC(&root, 0)
        guard var c = chartexFrom(root) else { return nil }
        c.raw = String(decoding: bytes, as: UTF8.self)
        return c
    }

    static func chartexFrom(_ root: XMLEl) -> Chart? {
        if !root.is("chartSpace") { return nil }
        var decodeBudget = maxChartexPoints
        guard let chartData = root.child("chartData") else { return nil }
        var datas: [ByteKey: ChartexData] = [:]
        for d in chartData.childrenNamed("data").prefix(64) {
            let id = d.attr("id") ?? "0"
            datas[ByteKey(id)] = chartexData(d, &decodeBudget)
        }
        guard let ch = root.child("chart"), let region = ch.child("plotArea")?.child("plotAreaRegion") else { return nil }
        var c = Chart.default
        c.categories = []
        c.series = []
        c.title = nil
        c.legend = nil
        c.gridlines = false
        c.title = ch.child("title").map { t in richText(t).flatMap { $0.isEmpty ? nil : $0 } ?? "Chart Title" }
        c.legend = ch.child("legend").map { $0.attr("pos") ?? "t" }
        var kind: ChartType?
        var outputBudget = maxChartexPoints
        var categoriesSet = false
        for s in region.childrenNamed("series").prefix(1000) {
            let layout = s.attr("layoutId") ?? ""
            if bytesEqual(layout, "paretoLine") {
                // The cumulative line PowerPoint adds to a Pareto histogram.
                kind = .pareto
                continue
            }
            guard let k = chartexKind(layout) else { return nil }
            if s.bool("hidden") == true { continue }
            kind = kind == .pareto ? .pareto : k
            guard let d = datas[ByteKey(s.child("dataId")?.attr("val") ?? "0")] else { return nil }
            var found: ([Double?], String?)?
            for t in ["val", "size", "colorVal"] {
                if let x = d.numbers[ByteKey(t)] {
                    found = x
                    break
                }
            }
            if found == nil, let first = d.numberOrder.first { found = d.numbers[first] }
            let valuesSrc = found?.0 ?? []
            let format = found?.1
            let takeLen = Swift.min(valuesSrc.count, outputBudget)
            let values = Array(valuesSrc.prefix(takeLen))
            outputBudget = Swift.max(outputBudget - values.count, 0)
            if !categoriesSet && (!d.categories.isEmpty || !d.levels.isEmpty) {
                categoriesSet = true
                c.categories = d.categories
                c.categoryLevels = d.levels
                outputBudget = Swift.max(outputBudget - c.categories.count, 0)
                for lvl in c.categoryLevels { outputBudget = Swift.max(outputBudget - lvl.count, 0) }
            }
            if let st = s.child("layoutPr")?.child("statistics") {
                c.inclusiveQuartiles = attrIs(st.attr("quartileMethod"), "inclusive")
            }
            if let b = s.child("layoutPr")?.child("binning") {
                c.binCount = b.child("binCount")?.u32("val").flatMap { $0 > 0 ? $0 : nil }
                c.binSize = b.child("binSize")?.attr("val").flatMap { rustParseF64($0) }.flatMap { $0.isFinite && $0 > 0.0 ? $0 : nil }
            }
            if let st = s.child("layoutPr")?.child("subtotals") {
                c.subtotals = Array(st.childrenNamed("idx").compactMap { $0.u32("val") }.map { Int($0) }.prefix(maxChartexLevelPoints))
            }
            let name = s.child("tx")?.find("v")?.text ?? ""
            c.series.append(Series(
                name: name, values: values,
                dataLabels: s.child("dataLabels").map { $0.bool("hidden") != true },
                numberFormat: format
            ))
        }
        guard let kind else { return nil }
        c.kind = kind
        c.dataLabels = c.series.contains { $0.dataLabels == true }
        c.varyColors = [.funnel, .treemap, .sunburst, .waterfall].contains(c.kind)
        // Waterfall, histogram and box charts have a value axis with gridlines by default.
        c.gridlines = [.waterfall, .histogram, .pareto, .boxWhisker].contains(c.kind)
        return c
    }
}
