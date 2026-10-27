// DCAppModel — the Selection Pane without a window: its rows (front-most first, groups expanded), the pane's
// own state, where a dragged row lands, and what a click, Shift+click or arrow key selects. Port of deckcraft
// `crates/ui-egui/src/selpane.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCEngine
import DCModel

public enum SelectionPane {
    /// A row's height in points.
    public static let rowHeight = 24.0
    /// Indent per group level.
    public static let indent = 14.0

    /// One line of the list.
    public struct Row: Sendable, Equatable {
        public var id: UInt32
        public var name: String
        public var depth: Int
        public var group: Bool
        public var hidden: Bool
        /// Inside a hidden group: drawn dimmed.
        public var dimmed: Bool
        public var locked: Bool
        public var parent: UInt32?
    }

    /// Pane-only state (nothing here is part of the document).
    public struct State: Sendable, Equatable {
        /// Groups folded shut.
        public var collapsed: Set<UInt32> = []
        /// Object being renamed and the text typed so far.
        public var renaming: (id: UInt32, text: String)?
        /// Last row clicked without Shift (the start of a Shift+click run).
        public var anchor: UInt32?
        /// Document (by uid) the state belongs to.
        var owner: UInt64?

        public init() {}

        /// `bind`: shape ids repeat between documents, so switching documents drops the pending rename,
        /// folds and anchor.
        public mutating func bind(_ uid: UInt64) {
            if owner != uid { self = State(); owner = uid }
        }

        public static func == (a: State, b: State) -> Bool {
            a.collapsed == b.collapsed && a.renaming?.id == b.renaming?.id && a.renaming?.text == b.renaming?.text
                && a.anchor == b.anchor && a.owner == b.owner
        }
    }

    /// `rows`: front-most first, children under their group unless it's folded.
    public static func rows(_ shapes: [Shape], _ collapsed: Set<UInt32>) -> [Row] {
        var out: [Row] = []
        func rec(_ v: [Shape], _ depth: Int, _ parent: UInt32?, _ dim: Bool) {
            if depth > 64 { return }
            for sh in v.reversed() {
                out.append(Row(id: sh.id.rawValue, name: sh.name, depth: depth, group: sh.isGroup, hidden: sh.hidden,
                               dimmed: dim, locked: sh.locked, parent: parent))
                if sh.isGroup && !collapsed.contains(sh.id.rawValue) {
                    rec(sh.children, depth + 1, sh.id.rawValue, dim || sh.hidden)
                }
            }
        }
        rec(shapes, 0, nil, false)
        return out
    }

    /// One sibling's block: its row plus its shown children, top to bottom in pane points.
    public struct Block: Sendable, Equatable {
        public var id: UInt32
        public var top: Double
        public var bottom: Double
        public init(id: UInt32, top: Double, bottom: Double) {
            self.id = id
            self.top = top
            self.bottom = bottom
        }
    }

    /// `drop_target`: where a dragged row would land among the rows sharing its parent, the gap nearest
    /// `y`. Returns the index among the siblings in the file's order (0 = back) and the y of the line.
    public static func dropTarget(_ dragged: UInt32, _ siblings: [Block], _ y: Double) -> (index: Int, y: Double)? {
        let others = siblings.filter { $0.id != dragged }
        guard let first = others.first else { return nil }
        var gaps = [first.top]
        gaps += others.map(\.bottom)
        var best = 0
        for (i, g) in gaps.enumerated() where abs(g - y) < abs(gaps[best] - y) { best = i }
        // `best` siblings sit above the line; the dragged object goes behind them.
        return (others.count - best, gaps[best])
    }

    /// `sibling_blocks`: each sibling of `parent` with its shown children, rows `rowHeight` apart from 0.
    public static func siblingBlocks(_ rows: [Row], _ parent: UInt32?) -> [Block] {
        let depth = parent.flatMap { p in rows.first { $0.id == p } }.map { $0.depth + 1 } ?? 0
        var out: [Block] = []
        var current: Block?
        for (i, row) in rows.enumerated() {
            let top = Double(i) * rowHeight, bottom = top + rowHeight
            if row.parent == parent {
                if let c = current { out.append(c) }
                current = Block(id: row.id, top: top, bottom: bottom)
            } else if row.depth > depth, current != nil {
                current?.bottom = bottom
            } else if let c = current {
                out.append(c)
                current = nil
            }
        }
        if let c = current { out.append(c) }
        return out
    }

    /// `click`: the `selection.select` parameters for a click on row `k` (Cmd toggles; Shift selects the
    /// run of rows of the same kind from the anchor), and the anchor after it.
    public static func click(_ rows: [Row], _ k: Int, anchor: UInt32?, command: Bool, shift: Bool) -> (params: JSON, anchor: UInt32?)? {
        guard let row = rows.at(k) else { return nil }
        if shift, let a = anchor.flatMap({ a in rows.firstIndex { $0.id == a } }) {
            let (lo, hi) = a <= k ? (a, k) : (k, a)
            let top = row.parent == nil
            let ids = rows[lo ... hi].filter { ($0.parent == nil) == top }.map { JSON.integer($0.id) }
            return (["ids": .array(ids), "add": .bool(command)], anchor)
        }
        return (["id": .integer(row.id), "toggle": .bool(command)], row.id)
    }

    /// `keys`: the row an arrow, Home or End moves to from the last selected one; nil when it stays.
    public static func keyTarget(_ rows: [Row], selected: [UInt32], key: String) -> Int? {
        let cur = selected.last.flatMap { id in rows.firstIndex { $0.id == id } }
        let to: Int?
        switch key {
        case "Up": to = cur.map { Swift.max($0 - 1, 0) } ?? 0
        case "Down": to = cur.map { Swift.min($0 + 1, Swift.max(rows.count - 1, 0)) } ?? 0
        case "Home": to = 0
        case "End": to = Swift.max(rows.count - 1, 0)
        default: to = nil
        }
        guard let k = to, rows.indices.contains(k), k != cur else { return nil }
        return k
    }

    /// The rename a finished edit commits: nil for an empty or unchanged name.
    public static func renameParams(_ row: Row, _ text: String) -> JSON? {
        let t = rustTrim(text)
        guard !t.isEmpty, t != row.name else { return nil }
        return ["id": .integer(row.id), "name": .string(String(t))]
    }

    /// The order commands of the row's context menu.
    public static let orderCommands: [(String, String)] = [
        ("Bring to Front", "arrange.bringToFront"), ("Bring Forward", "arrange.bringForward"),
        ("Send Backward", "arrange.sendBackward"), ("Send to Back", "arrange.sendToBack"),
    ]
}
