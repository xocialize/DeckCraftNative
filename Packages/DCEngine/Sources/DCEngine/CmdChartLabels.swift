// DCEngine — `chart.options`' data label position and contents, the port's own (AB-T-0438). deckcraft's labels are
// on or off; PowerPoint places them (Center, Inside End, Inside Base, Outside End, Data Callout; Left, Right,
// Above, Below on lines; Best Fit on pies) and composes them from the series name, category name, value and
// percentage with a separator. Keys of `chart.options`, not a new command: the registry is deckcraft's list.
import CNCore
import DCModel

extension InsertCommands {
    /// `labelPosition` (a `c:dLblPos` value, or null for the chart type's own), `labelContents` ({seriesName,
    /// categoryName, value, percent, legendKey, leaderLines}: booleans, the ones given change), `labelSeparator`
    /// (text, or null for ", ") and `labelCallout` (PowerPoint's Data Callout). Any of them turns the labels on.
    /// Parsed before the edit; a position the chart's series don't take is refused in it, changing nothing.
    struct LabelOptionsParams {
        var position: String??
        var contents: [String: Bool] = [:]
        var separator: String??
        var callout: Bool?

        static let contentKeys = ["seriesName", "categoryName", "value", "percent", "legendKey", "leaderLines"]

        init(_ p: JSON) throws {
            let cmd = "chart.options"
            if let v = p.get("labelPosition") {
                if v.isNull {
                    position = .some(nil)
                } else {
                    guard let s = v.asStr, PositionNames.all.contains(s) else {
                        throw Cmd.bad(cmd, "`labelPosition` is one of \(PositionNames.all.joined(separator: ", ")), or null")
                    }
                    position = .some(s)
                }
            }
            if let v = p.get("labelContents") {
                guard v.isObject else { throw Cmd.bad(cmd, "`labelContents` is an object of booleans") }
                for k in Self.contentKeys {
                    guard let x = v.get(k) else { continue }
                    guard let b = x.asBool else { throw Cmd.bad(cmd, "`labelContents.\(k)` is true or false") }
                    contents[k] = b
                }
            }
            if let v = p.get("labelSeparator") {
                if v.isNull {
                    separator = .some(nil)
                } else {
                    guard let s = v.asStr, s.unicodeScalars.count <= 255 else { throw Cmd.bad(cmd, "`labelSeparator` is text (up to 255 characters), or null") }
                    separator = .some(s)
                }
            }
            if let v = p.get("labelCallout") {
                guard let b = v.asBool else { throw Cmd.bad(cmd, "`labelCallout` is true or false") }
                callout = b
            }
        }

        var isEmpty: Bool { position == nil && contents.isEmpty && separator == nil && callout == nil }

        func apply(_ c: inout Chart) throws {
            guard !isEmpty else { return }
            let cmd = "chart.options"
            // One set of options for the whole chart: the series' own go, as `dataLabels` clears theirs.
            var o = c.labelOptions ?? LabelOptions()
            if let p = position {
                if let p, !c.labelPositions.contains(p) {
                    let takes = c.labelPositions
                    throw Cmd.bad(cmd, takes.isEmpty ? "this chart's data labels have no position" : "this chart's data labels go \(takes.joined(separator: ", ")), not \(p)")
                }
                o.position = p
            }
            for (k, b) in contents {
                switch k {
                case "seriesName": o.seriesName = b
                case "categoryName": o.categoryName = b
                case "value": o.hideValue = !b
                case "percent": o.percent = b
                case "legendKey": o.legendKey = b
                case "leaderLines": o.leaderLines = b
                default: break
                }
            }
            if let s = separator { o.separator = s }
            if let b = callout { o.callout = b }
            if !o.showsSomething { throw Cmd.bad(cmd, "data labels must show the value, the series name, the category name or the percentage") }
            if o.hideValue && !(o.seriesName || o.categoryName || o.percent) { o.hideValue = false }
            c.labelOptions = o == LabelOptions() ? nil : o
            c.dataLabels = true
            for i in c.series.indices {
                c.series[i].dataLabels = nil
                c.series[i].labelOptions = nil
            }
        }
    }

    enum PositionNames {
        static let all = ["ctr", "inEnd", "inBase", "outEnd", "bestFit", "l", "r", "t", "b"]
    }
}

extension InsertCommands {
    /// `chart.options` `dataTable`: `{keys?, horizontal?, vertical?, outline?}` (booleans; left out, PowerPoint's
    /// With Legend Keys: all on) or null for none. The port's own (AB-T-0439); refused on a chart that takes no data
    /// table (`Chart.takesDataTable`).
    struct DataTableParam {
        var table: DataTable??

        init(_ p: JSON) throws {
            let cmd = "chart.options"
            guard let v = p.get("dataTable") else { return }
            if v.isNull {
                table = .some(nil)
                return
            }
            guard v.isObject else { throw Cmd.bad(cmd, "`dataTable` is an object ({keys?, horizontal?, vertical?, outline?}) or null") }
            var t = DataTable.default
            for k in ["keys", "horizontal", "vertical", "outline"] {
                guard let x = v.get(k) else { continue }
                guard let b = x.asBool else { throw Cmd.bad(cmd, "`dataTable.\(k)` is true or false") }
                switch k {
                case "keys": t.keys = b
                case "horizontal": t.horizontal = b
                case "vertical": t.vertical = b
                default: t.outline = b
                }
            }
            table = .some(t)
        }

        func apply(_ c: inout Chart) throws {
            guard let t = table else { return }
            if t != nil && !c.takesDataTable { throw Cmd.bad("chart.options", "a data table goes under a column, line, area or stock chart") }
            c.dataTable = t
        }
    }
}
