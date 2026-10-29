// DCAppModelTests — R3 of Docs/plans/Ribbon-and-StartScreen.md: folding the ribbon (`RibbonFit`) and moving keyboard
// focus through it (`RibbonFocus`), without a window. The widths are made up here; the app measures its own.
import DCCore
import Testing
@testable import DCAppModel

@MainActor
@Suite struct RibbonFitTests {
    /// A small deterministic generator, so a failure names its seed.
    struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        mutating func width(_ lo: Double, _ hi: Double) -> Double { lo + Double(next() % 1000) / 1000 * (hi - lo) }
    }

    /// Measures for `tab`: each size narrower than the one before, as drawing smaller makes it.
    static func measures(_ tab: RibbonTab, _ seed: UInt64) -> [GroupMeasure] {
        var r = Rand(state: seed)
        return tab.groups.map { g in
            var w = r.width(120, 360)
            return GroupMeasure(id: g.id, foldOrder: g.foldOrder, steps: RibbonFit.sizes(g).map { s in
                defer { w = s == .collapsed ? w : max(w * r.width(0.5, 0.9), 50) }
                return .init(s, s == .collapsed ? 60 : w)
            })
        }
    }

    // R3: "the fold order is monotonic as the width falls" — no group is drawn larger in a narrower ribbon.
    @Test func theFoldOrderIsMonotonicAsTheWidthFalls() {
        for (n, tab) in RibbonModel.allTabs.enumerated() {
            for seed in 1 ... 8 as ClosedRange<UInt64> {
                let m = Self.measures(tab, seed &* 31 &+ UInt64(n))
                var last: [String: GroupSize]?
                for w in stride(from: 3000.0, through: 0, by: -7) {
                    let fit = RibbonFit.fit(m, available: w)
                    if let last {
                        for (id, s) in fit.sizes { #expect(s >= last[id] ?? .large, "\(tab.id) seed \(seed) at \(w): \(id) grew to \(s)") }
                    }
                    #expect(!fit.fits || fit.width <= w)
                    last = fit.sizes
                }
            }
        }
    }

    // R3: "Paste and Designer never fold"; nor does a Close Master group.
    @Test func pasteAndDesignerNeverFold() throws {
        let home = try #require(RibbonModel.allTabs.first { $0.id == "home" })
        let clipboard = try #require(home.groups.first { $0.id == "home.clipboard" })
        #expect(!RibbonFit.sizes(clipboard).contains(.collapsed), "Clipboard holds Paste, which never folds")
        let paste = try #require(clipboard.controls.first { $0.id == "home.paste" })
        for s in GroupSize.allCases { #expect(RibbonFit.size(paste, s) == .large) }
        for tab in RibbonModel.allTabs {
            for g in tab.groups where g.id.hasSuffix(".designer") || g.id.hasSuffix(".close") || g.foldOrder == 0 {
                #expect(RibbonFit.sizes(g) == [.large], "\(g.id)")
            }
        }
        // However narrow, Paste and Designer are drawn large.
        let fit = RibbonFit.fit(Self.measures(home, 7), available: 0)
        #expect(!fit.fits)
        #expect(fit.sizes["home.designer"] == .large)
        #expect(fit.sizes["home.clipboard"].map { RibbonFit.size(paste, $0) } == .large)
        #expect(fit.sizes["home.drawing"] == .collapsed && fit.sizes["home.font"] == .collapsed)
    }

    // §5: the highest fold order goes first, the rightmost on a tie; 0 never folds; the same input, the same answer.
    @Test func theOrderIsTheFoldOrderAndTheSameInputGivesTheSameOutput() {
        func g(_ id: String, _ fold: Int) -> GroupMeasure { .init(id: id, foldOrder: fold, steps: [.init(.large, 100), .init(.collapsed, 40)]) }
        let m = [g("a", 1), g("b", 3), g("c", 1), g("d", 0), g("e", 2)]
        #expect(RibbonFit.fit(m, available: 500).sizes.values.allSatisfy { $0 == .large })
        #expect(RibbonFit.fit(m, available: 499).sizes.filter { $0.value == .collapsed }.keys.sorted() == ["b"])
        #expect(RibbonFit.fit(m, available: 439).sizes.filter { $0.value == .collapsed }.keys.sorted() == ["b", "e"])
        // a and c tie: c, to the right, goes first.
        #expect(RibbonFit.fit(m, available: 379).sizes.filter { $0.value == .collapsed }.keys.sorted() == ["b", "c", "e"])
        let all = RibbonFit.fit(m, available: 0)
        #expect(all.sizes["d"] == .large && !all.fits && all.width == 260)
        for w in [0.0, 250, 380, 440, 1000] { #expect(RibbonFit.fit(m, available: w) == RibbonFit.fit(m, available: w)) }
        for tab in RibbonModel.allTabs {
            let ms = Self.measures(tab, 3)
            for w in [1600.0, 1150, 920, 700] { #expect(RibbonFit.fit(ms, available: w) == RibbonFit.fit(ms, available: w), "\(tab.id)") }
        }
    }

    // Widths come from measuring: a bad one counts as nothing, and a bad width available folds everything.
    @Test func hostileWidthsDoNotTrap() {
        let m = [GroupMeasure(id: "a", foldOrder: 2, steps: [.init(.large, .nan), .init(.collapsed, -.infinity)]),
                 GroupMeasure(id: "b", foldOrder: 1, steps: [.init(.large, .infinity), .init(.small, 1e300), .init(.collapsed, 10)]),
                 GroupMeasure(id: "c", foldOrder: 1, steps: [])]
        for w in [Double.nan, .infinity, -.infinity, -1, 0, 1e308] {
            let fit = RibbonFit.fit(m, available: w)
            #expect(fit.sizes.count == 3 && fit.width.isFinite, "\(w)")
        }
        let t = RibbonFit.tabs([.nan, -5, .infinity, 40], selected: 3, available: .nan, more: .nan)
        #expect(t.shown.contains(3) && Set(t.shown + t.overflow) == [0, 1, 2, 3])
        #expect(RibbonFit.tabs([], selected: 0, available: 0, more: 30) == ([], []))
    }

    // R3: "the selected tab never overflows" — the tail goes into "»", the selected tab takes the last place.
    @Test func theSelectedTabNeverOverflows() {
        var r = Rand(state: 42)
        for _ in 0 ..< 300 {
            let widths = (0 ..< Int(3 + r.next() % 14)).map { _ in r.width(30, 140) }
            let available = r.width(0, widths.reduce(0, +) * 1.1)
            for s in widths.indices {
                let t = RibbonFit.tabs(widths, selected: s, available: available, more: 32)
                #expect(t.shown.contains(s) && !t.overflow.contains(s))
                #expect(t.shown == t.shown.sorted() && t.overflow == t.overflow.sorted())
                #expect(Set(t.shown + t.overflow) == Set(widths.indices) && t.shown.count + t.overflow.count == widths.count)
                let used = t.shown.reduce(0) { $0 + widths[$1] }
                if !t.overflow.isEmpty, t.shown != [s] { #expect(used <= available - 32 + 1e-9) }
                if t.overflow.isEmpty { #expect(widths.reduce(0, +) <= available) }
            }
        }
        // Everything fits: nothing in "»".
        #expect(RibbonFit.tabs([50, 50], selected: 1, available: 100, more: 30) == ([0, 1], []))
        // The selected tab replaces the last that fit.
        #expect(RibbonFit.tabs([50, 50, 50, 50], selected: 3, available: 140, more: 30) == ([0, 3], [1, 2]))
    }

    // §6: with its groups at any of their sizes, every control of every tab is reachable with the arrow keys from
    // the first place, each split by both halves, each collapsed group by its button; up and down stay in a column.
    @Test func everyControlIsReachableFromTheKeyboard() {
        for tab in RibbonModel.allTabs {
            for level in 0 ..< 4 {
                var sizes: [String: GroupSize] = [:]
                for g in tab.groups {
                    let s = RibbonFit.sizes(g)
                    sizes[g.id] = s[min(level, s.count - 1)]
                }
                let cols = RibbonFocus.columns(tab, sizes)
                var want: Set<String> = []
                for g in tab.groups {
                    if sizes[g.id] == .collapsed {
                        want.insert(RibbonFocus.groupID(g))
                        continue
                    }
                    for c in g.controls {
                        want.insert(c.id)
                        if RibbonFocus.isSplit(c) { want.insert(RibbonFocus.menuID(c)) }
                    }
                }
                var seen: Set<String> = []
                var at = RibbonFocus.next(nil, .first, in: cols)
                while let p = at, !seen.contains(p) {
                    seen.insert(p)
                    at = RibbonFocus.next(p, .right, in: cols)
                }
                #expect(seen == want, "\(tab.id) level \(level): missing \(want.subtracting(seen).sorted())")
                // Left retraces right, and up and down never leave the column.
                for col in cols {
                    for (i, p) in col.enumerated() {
                        #expect(RibbonFocus.next(p, .down, in: cols) == col.at(i + 1))
                        #expect(RibbonFocus.next(p, .up, in: cols) == col.at(i - 1))
                    }
                }
                let flat = cols.flatMap { $0 }
                for (i, p) in flat.enumerated().dropFirst() { #expect(RibbonFocus.next(p, .left, in: cols) == flat[i - 1]) }
                #expect(RibbonFocus.next(flat.last, .right, in: cols) == nil)
            }
        }
    }

    // A disabled control can't take focus, so the keyboard steps past it: from Copy, with Format Painter disabled,
    // right goes on to the Slides group and down stays put (0.1.4 sent both back to the start of Clipboard).
    @Test func theKeyboardStepsPastDisabledControls() throws {
        let home = try #require(RibbonModel.allTabs.first { $0.id == "home" })
        let all = RibbonFocus.columns(home, [:])
        let cols = RibbonFocus.columns(home, [:], disabled: ["home.formatPainter"])
        #expect(all.joined().contains("home.formatPainter") && !cols.joined().contains("home.formatPainter"))
        let right = try #require(RibbonFocus.next("home.copy", .right, in: cols))
        let slides = try #require(home.groups.first { $0.controls.contains { $0.id == "home.newSlide" } })
        #expect(slides.controls.contains { RibbonFocus.controlID($0) == right || RibbonFocus.menuID($0) == right }, "\(right)")
        #expect(RibbonFocus.next("home.copy", .down, in: cols) == nil)
    }

    // §5: a group's sizes are those that draw something differently, largest first, then collapsed.
    @Test func aGroupsSizesAreThoseThatDiffer() throws {
        for tab in RibbonModel.allTabs {
            for g in tab.groups {
                let s = RibbonFit.sizes(g)
                #expect(s.first == .large && s == s.sorted() && Set(s).count == s.count, "\(g.id) \(s)")
            }
        }
        let font = try #require(RibbonModel.allTabs.flatMap(\.groups).first { $0.id == "home.font" })
        // B I U are icons at every size, and the font list and size are drawn the same small; only Font… loses its
        // label before the group collapses.
        #expect(RibbonFit.sizes(font) == [.large, .small, .collapsed])
        let insert = try #require(RibbonModel.allTabs.flatMap(\.groups).first { $0.id == "home.insert" })
        #expect(RibbonFit.sizes(insert) == [.large, .medium, .small, .collapsed])
    }
}
