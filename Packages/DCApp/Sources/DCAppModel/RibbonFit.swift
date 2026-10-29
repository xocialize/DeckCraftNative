// DCAppModel — folding the ribbon at narrow widths (Docs/plans/Ribbon-and-StartScreen.md §5, R3): which size each
// group is drawn at for the width there is, which tabs the tab row shows, and the order keyboard focus moves in.
// Pure functions of measured widths, so they are tested without a window; DCApp measures each group once per size
// and asks. deckcraft doesn't fold (its ribbon scrolls behind ‹ › chevrons, `ribbon.rs:191-262`, which is our last
// resort); the order follows what PowerPoint for Mac does as its window narrows, written into `RibbonLayout`'s
// `foldOrder`. Not a port.
import DCCore
import Foundation

/// The sizes a group steps down through as the ribbon narrows, largest first.
public enum GroupSize: String, Sendable, CaseIterable, Comparable {
    /// Every control at its largest.
    case large
    /// Small icons with their labels.
    case medium
    /// Small icons only.
    case small
    /// One labelled button whose popover shows the whole group at `.large`.
    case collapsed

    var rank: Int {
        switch self {
        case .large: 0
        case .medium: 1
        case .small: 2
        case .collapsed: 3
        }
    }

    public static func < (a: GroupSize, b: GroupSize) -> Bool { a.rank < b.rank }
}

/// A group's measured width at each size it can take.
public struct GroupMeasure: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public var size: GroupSize
        public var width: Double
        public init(_ size: GroupSize, _ width: Double) {
            self.size = size
            self.width = width
        }
    }

    public var id: String
    /// 0 never folds; otherwise the highest gives way first.
    public var foldOrder: Int
    /// The sizes, largest first, with their widths.
    public var steps: [Step]

    public init(id: String, foldOrder: Int, steps: [Step]) {
        self.id = id
        self.foldOrder = foldOrder
        self.steps = steps
    }
}

public enum RibbonFit {
    /// What `fit` decided.
    public struct Fit: Sendable, Equatable {
        /// Each group's size, by group id.
        public var sizes: [String: GroupSize]
        /// The groups' total width at those sizes.
        public var width: Double
        /// False when every group that can fold has folded and they still don't fit: the ribbon scrolls.
        public var fits: Bool
    }

    /// The sizes `g` can take, largest first: those that draw some control differently from the size before, then
    /// `.collapsed`. A group with `foldOrder` 0 never folds, and one holding a control that is only ever large
    /// (Paste) never collapses: that control stays large at every width.
    public static func sizes(_ g: RibbonGroup) -> [GroupSize] {
        guard g.foldOrder > 0 else { return [.large] }
        var out: [GroupSize] = []
        var last: [RibbonSize]?
        for s in [GroupSize.large, .medium, .small] {
            let drawn = g.controls.map { size($0, s) }
            if drawn != last { out.append(s) }
            last = drawn
        }
        if !g.controls.contains(where: { $0.sizes == [.large] }) { out.append(.collapsed) }
        return out
    }

    /// The size a control is drawn at in a group of size `g`: the largest it can take that is no larger than the
    /// group's, else its smallest. In a collapsed group's popover, controls are drawn as at `.large`.
    public static func size(_ c: RibbonControl, _ g: GroupSize) -> RibbonSize {
        let cap: Int = switch g {
        case .large, .collapsed: 0
        case .medium: 1
        case .small: 2
        }
        func rank(_ s: RibbonSize) -> Int {
            switch s {
            case .large: 0
            case .medium: 1
            case .small: 2
            }
        }
        return c.sizes.first { rank($0) >= cap } ?? c.sizes.last ?? .medium
    }

    /// Each group's size for `available` points. Every group starts at its largest; while the total is wider than
    /// the space, the group with the highest `foldOrder` that can still step down does, the rightmost on a tie.
    /// The steps taken don't depend on `available`, only how many of them, so a narrower ribbon never draws a
    /// group larger than a wider one does, and the same input always gives the same answer.
    public static func fit(_ groups: [GroupMeasure], available: Double) -> Fit {
        // Widths come from measuring; a bad one counts as nothing rather than poisoning the total.
        func w(_ x: Double) -> Double { x.isFinite && x > 0 ? x : 0 }
        let space = available.isNaN ? 0 : available
        var level = Array(repeating: 0, count: groups.count)
        func width(_ i: Int) -> Double { groups[i].steps.at(level[i]).map { w($0.width) } ?? 0 }
        var total = groups.indices.reduce(0) { $0 + width($1) }
        // Each pass steps one group down one size, so there are at most as many passes as steps.
        var budget = groups.reduce(0) { $0 + $1.steps.count }
        while total > space, budget > 0 {
            budget -= 1
            var pick: Int?
            for i in groups.indices where groups[i].foldOrder > 0 && level[i] + 1 < groups[i].steps.count {
                if let p = pick, groups[p].foldOrder > groups[i].foldOrder { continue }
                pick = i
            }
            guard let i = pick else { break }
            total -= width(i)
            level[i] += 1
            total += width(i)
        }
        var sizes: [String: GroupSize] = [:]
        for (i, g) in groups.enumerated() { sizes[g.id] = g.steps.at(level[i])?.size ?? .large }
        return Fit(sizes: sizes, width: total, fits: total <= space)
    }

    /// Which tabs the tab row shows when they are `widths` wide and the row is `available`, with `more` for the
    /// "»" button that lists the rest. The tabs keep their order; the tail goes into "»" first. The selected tab is
    /// always shown, taking the place of the last tabs that fit if it would have gone into "»".
    public static func tabs(_ widths: [Double], selected: Int?, available: Double, more: Double) -> (shown: [Int], overflow: [Int]) {
        func w(_ x: Double) -> Double { x.isFinite && x > 0 ? x : 0 }
        let total = widths.reduce(0) { $0 + w($1) }
        if total <= available || widths.isEmpty { return (Array(widths.indices), []) }
        let budget = available - w(more)
        var shown: [Int] = []
        var used = 0.0
        for (i, x) in widths.enumerated() {
            guard used + w(x) <= budget else { break }
            shown.append(i)
            used += w(x)
        }
        if let s = selected, widths.indices.contains(s), !shown.contains(s) {
            while let last = shown.last, used + w(widths[s]) > budget {
                shown.removeLast()
                used -= w(widths[last])
            }
            shown.append(s)
        }
        return (shown, widths.indices.filter { !shown.contains($0) })
    }
}

/// Moving keyboard focus within the ribbon's controls (§6): the controls in reading order, column by column and
/// row by row, the way they are laid out at their fitted sizes.
@MainActor
public enum RibbonFocus {
    /// A focusable place: a control (its main half), a split's menu half, or a collapsed group's button.
    public static func controlID(_ c: RibbonControl) -> String { c.id }
    public static func menuID(_ c: RibbonControl) -> String { c.id + "#menu" }
    public static func groupID(_ g: RibbonGroup) -> String { "group:" + g.id }

    /// Whether a control is drawn as two halves, each focused on its own.
    public static func isSplit(_ c: RibbonControl) -> Bool {
        switch c.kind {
        case .split, .color: true
        default: false
        }
    }

    /// The focusable places of `tab` with its groups at `sizes`, in order, as columns: each column a list of places
    /// top to bottom. Left and right step through the flattened order; up and down move within a column. Controls
    /// in `disabled` are left out: a disabled control can't take focus, so stepping onto one (Format Painter with
    /// nothing copied) sent the keyboard back to the start of its group (0.1.4).
    public static func columns(_ tab: RibbonTab, _ sizes: [String: GroupSize], disabled: Set<String> = []) -> [[String]] {
        var out: [[String]] = []
        for g in tab.groups {
            let gs = sizes[g.id] ?? .large
            if gs == .collapsed {
                out.append([groupID(g)])
                continue
            }
            for column in RibbonModel.columns(g, gs) {
                var places: [String] = []
                for row in column {
                    for c in row where !disabled.contains(c.id) {
                        places.append(controlID(c))
                        if isSplit(c) { places.append(menuID(c)) }
                    }
                }
                if !places.isEmpty { out.append(places) }
            }
        }
        return out
    }

    public enum Move: Sendable { case left, right, up, down, first, last }

    /// Where focus goes from `from` on `move`; nil when it stays (the first or last place, or `from` isn't one).
    public static func next(_ from: String?, _ move: Move, in columns: [[String]]) -> String? {
        let flat = columns.flatMap { $0 }
        switch move {
        case .first: return flat.first
        case .last: return flat.last
        default: break
        }
        guard let from, let i = flat.firstIndex(of: from) else { return flat.first }
        switch move {
        case .left: return flat.at(i - 1)
        case .right: return flat.at(i + 1)
        case .up, .down:
            guard let col = columns.first(where: { $0.contains(from) }), let j = col.firstIndex(of: from) else { return nil }
            return col.at(move == .up ? j - 1 : j + 1)
        case .first, .last: return nil
        }
    }
}
