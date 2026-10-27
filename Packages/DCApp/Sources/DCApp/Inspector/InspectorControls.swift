// DCApp — the inspector's controls: committed number fields and sliders, the colour grid in a popover, colour
// split buttons and tiles. They replace deckcraft's ribbon and pane widgets (`crates/ui-egui/src/widgets.rs`:
// spinner, color_grid, color_split, drop_button, gallery; MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors) with SwiftUI controls: a stepper field, a slider that commits when released, a popover, and
// `Menu(primaryAction:)` for split buttons.
import AppKit
import DCAppModel
import DCColor
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DCRender
import DesignScaffold
import SwiftUI

extension Rgba {
    /// The colour as SwiftUI draws it (content colour, not chrome).
    var swiftUI: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255) }
}

/// A number field with a stepper, labelled by its row (`widgets::spinner`). Typing commits on Return or when
/// the field loses focus; the stepper commits each step. Shows `value` unless the field is being edited.
struct NumberField: View {
    let label: String
    let value: Double
    var step = 1.0
    var suffix = ""
    var range: ClosedRange<Double>? = nil
    let commit: (Double) -> Void
    @State private var text: String?
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: Tokens.Space.xs) {
                TextField(label, text: Binding(get: { text ?? Self.format(value, suffix) }, set: { text = $0 }))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit(apply)
                    .onChange(of: focused) { _, now in if !now { apply() } }
                    .accessibilityLabel("\(label) value")
                Stepper(label, onIncrement: { send(value + step) }, onDecrement: { send(value - step) })
                    .labelsHidden()
                    .accessibilityLabel(label)
            }
        }
    }

    private func apply() {
        guard let t = text else { return }
        text = nil
        // As deckcraft's spinner: the digits, the point and the sign of what was typed.
        let num = String(t.filter { $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") })
        if let v = Double(num), v.isFinite, abs(v - value) > 1e-9 { send(v) }
    }

    private func send(_ v: Double) {
        guard v.isFinite else { return }
        commit(range.map { Swift.min(Swift.max(v, $0.lowerBound), $0.upperBound) } ?? v)
    }

    /// `fmt_num`: two decimals at most, trailing zeros dropped.
    static func format(_ v: Double, _ suffix: String) -> String {
        var s = rustFixed(v, places: 2)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s + suffix
    }
}

/// A slider that holds its value while dragged and commits once, when released (one undo step per
/// adjustment, as deckcraft's `fx_slider`); otherwise it follows the document.
struct CommitSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var suffix = ""
    var decimals = 0
    let commit: (Double) -> Void
    @State private var draft: Double?

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: Tokens.Space.s) {
                Slider(value: Binding(get: { draft ?? clamped(value) }, set: { draft = $0 }), in: range) { editing in
                    if !editing, let d = draft {
                        draft = nil
                        if abs(d - value) > 1e-9 { commit(d) }
                    }
                }
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(text)
                Text(text)
                    .font(Tokens.Font.metricInline)
                    .foregroundStyle(Tokens.Color.secondaryLabel)
                    .accessibilityHidden(true)
            }
        }
    }

    private func clamped(_ v: Double) -> Double { v.isFinite ? Swift.min(Swift.max(v, range.lowerBound), range.upperBound) : range.lowerBound }
    private var text: String { rustFixed(draft ?? clamped(value), places: decimals) + suffix }
}

/// A choice among labelled values that runs a command when changed (deckcraft's combo boxes).
struct ChoicePicker: View {
    let label: String
    let options: [(String, String)]
    let current: String
    let pick: (String) -> Void

    var body: some View {
        Picker(label, selection: Binding(get: { current }, set: { if $0 != current { pick($0) } })) {
            if !options.contains(where: { $0.1 == current }) { Text(current).tag(current) }
            ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
        }
    }
}

// MARK: - Colours

/// The colour grid (`color_grid`): theme colours with their tints and shades, standard colours, an optional
/// "No Fill"-style entry, a hex field ("More Colors… #"), the system colour panel and the eyedropper
/// (`NSColorSampler`, macOS's own).
struct ColorGrid: View {
    let scheme: DCColor.ColorScheme
    var noneLabel: String?
    let pick: (ColorRef?) -> Void
    @State private var hex = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            SectionHeader("Theme Colors")
            Grid(horizontalSpacing: Tokens.Space.xs, verticalSpacing: Tokens.Space.xs / 2) {
                ForEach(Array(InspectorColors.themeGrid(scheme).enumerated()), id: \.offset) { row in
                    GridRow {
                        ForEach(Array(row.element.enumerated()), id: \.offset) { swatch($0.element) }
                    }
                    if row.offset == 0 { Color.clear.frame(height: Tokens.Space.xs).gridCellUnsizedAxes(.horizontal) }
                }
            }
            SectionHeader("Standard Colors")
            HStack(spacing: Tokens.Space.xs) {
                ForEach(Array(InspectorColors.standard.enumerated()), id: \.offset) { swatch($0.element) }
            }
            Divider()
            if let noneLabel { Button(noneLabel) { pick(nil) } }
            HStack(spacing: Tokens.Space.xs) {
                Text("More Colors… #")
                TextField("RRGGBB", text: $hex)
                    .accessibilityLabel("Hex color")
                    .onSubmit { if let c = InspectorColors.hex(hex) { pick(c) } }
            }
            HStack {
                Button("Eyedropper") {
                    NSColorSampler().show { color in
                        if let c = color.flatMap(Self.rgba) { MainActor.assumeIsolated { pick(.rgb(c)) } }
                    }
                }
                .help("Click anywhere on the screen to take the colour under the pointer")
            }
        }
        .padding(Tokens.Space.m)
        .controlSize(.small)
    }

    private func swatch(_ s: ColorSwatch) -> some View {
        Button { pick(s.ref) } label: {
            RoundedRectangle(cornerRadius: Tokens.Radius.control / 3)
                .fill(s.rgba.swiftUI)
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control / 3).strokeBorder(Tokens.Color.separator, lineWidth: Tokens.Layout.hairline))
                .frame(width: Tokens.Space.l, height: Tokens.Space.l)
        }
        .buttonStyle(.plain)
        .help(s.label)
        .accessibilityLabel(s.label)
    }

    nonisolated static func rgba(_ c: NSColor) -> Rgba? {
        guard let s = c.usingColorSpace(.sRGB) else { return nil }
        func b(_ v: CGFloat) -> UInt8 { UInt8(rustCast: (Double(v) * 255).rounded()) }
        return .rgb(b(s.redComponent), b(s.greenComponent), b(s.blueComponent))
    }
}

/// A labelled colour button that opens the colour grid in a popover.
struct ColorButton: View {
    let label: String
    let color: Rgba?
    let scheme: DCColor.ColorScheme
    var noneLabel: String?
    let pick: (ColorRef?) -> Void
    @State private var open = false

    var body: some View {
        LabeledContent(label) {
            Button { open.toggle() } label: {
                HStack(spacing: Tokens.Space.xs) {
                    ColorChip(color: color)
                    Image(systemName: "chevron.down").imageScale(.small)
                }
            }
            .accessibilityLabel(label)
            .popover(isPresented: $open, arrowEdge: .leading) {
                ColorGrid(scheme: scheme, noneLabel: noneLabel) { c in
                    open = false
                    pick(c)
                }
            }
        }
    }
}

/// A split colour control (`color_split`, Shape Fill / Shape Outline): the main half applies the last
/// colour; the chevron opens the grid.
struct ColorSplitButton: View {
    let title: String
    let symbol: String
    let color: Rgba?
    let scheme: DCColor.ColorScheme
    var noneLabel: String?
    var enabled = true
    let primary: () -> Void
    let pick: (ColorRef?) -> Void
    @State private var open = false

    var body: some View {
        LabeledContent(title) {
            ControlGroup {
                Button(action: primary) {
                    HStack(spacing: Tokens.Space.xs) {
                        Image(systemName: symbol)
                        ColorChip(color: color)
                    }
                }
                .help(title)
                .accessibilityLabel(title)
                Button { open.toggle() } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("\(title) options")
                    .help("\(title) options")
                    .popover(isPresented: $open, arrowEdge: .bottom) {
                        ColorGrid(scheme: scheme, noneLabel: noneLabel) { c in
                            open = false
                            pick(c)
                        }
                    }
            }
            .fixedSize()
        }
        .disabled(!enabled)
    }
}

/// A colour sample (a checkerboard-free square; "no colour" draws a slash).
struct ColorChip: View {
    let color: Rgba?
    var thin = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.control / 3)
        ZStack {
            if let color {
                shape.fill(color.swiftUI)
            } else {
                shape.fill(Tokens.Color.fieldFill)
                Image(systemName: "slash.circle").imageScale(.small).foregroundStyle(Tokens.Color.secondaryLabel)
            }
        }
        .overlay(shape.strokeBorder(Tokens.Color.separator, lineWidth: Tokens.Layout.hairline))
        .frame(width: thin ? Tokens.Space.l : Tokens.Space.l + Tokens.Space.xs, height: thin ? Tokens.Space.xs : Tokens.Space.l)
    }
}

/// A row of icon buttons that run commands (B I U, alignment…), each a toggle showing its state.
struct IconToggle: View {
    let symbol: String
    let help: String
    var on = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { _ in action() })) { Image(systemName: symbol) }
            .toggleStyle(.button)
            .help(help)
            .accessibilityLabel(help)
            .disabled(!enabled)
    }
}

/// A grid of selectable tiles (`widgets::gallery`): themes, variants, transitions.
struct TileGallery<Tile: View>: View {
    let count: Int
    var columns = 3
    let selected: Int?
    let tip: (Int) -> String
    let tile: (Int) -> Tile
    let pick: (Int) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.s), count: Swift.max(columns, 1)), spacing: Tokens.Space.s) {
            ForEach(0 ..< Swift.max(count, 0), id: \.self) { i in
                Button { pick(i) } label: {
                    tile(i)
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                            .strokeBorder(selected == i ? Tokens.Color.accent : Tokens.Color.separator,
                                          lineWidth: selected == i ? Tokens.Layout.hairline * 2 : Tokens.Layout.hairline))
                }
                .buttonStyle(.plain)
                .help(tip(i))
                .accessibilityLabel(tip(i))
                .accessibilityAddTraits(selected == i ? .isSelected : [])
            }
        }
    }
}

/// A theme tile (`paint_theme_tile`): the background, "Aa" in the text colour, the six accents.
struct ThemeTile: View {
    let colors: DCColor.ColorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .fill(colors.get(.lt1).swiftUI)
            .aspectRatio(3 / 2, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                Text("Aa").font(Tokens.Font.headline).foregroundStyle(colors.get(.dk1).swiftUI).padding(Tokens.Space.xs)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: Tokens.Layout.hairline) {
                    ForEach(4 ..< 10, id: \.self) { k in Rectangle().fill((colors.colors.at(k) ?? .black).swiftUI) }
                }
                .frame(height: Tokens.Space.xs)
                .padding(Tokens.Space.xs)
            }
    }
}

/// A pattern swatch drawn from DCRender's preset tile, in the pattern's colours.
struct PatternSwatch: View {
    let preset: String
    let fg: Rgba
    let bg: Rgba

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg.swiftUI))
            let tile = Pattern.tile(preset)
            let cell = Tokens.Layout.hairline * 2
            let nx = Int(size.width / cell), ny = Int(size.height / cell)
            var path = Path()
            for y in 0 ..< Swift.max(ny, 0) {
                for x in 0 ..< Swift.max(nx, 0) where Pattern.isFg(tile, x, y) {
                    path.addRect(CGRect(x: Double(x) * cell, y: Double(y) * cell, width: cell, height: cell))
                }
            }
            ctx.fill(path, with: .color(fg.swiftUI))
        }
        .frame(width: Tokens.Space.xl, height: Tokens.Space.xl)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control / 3))
    }
}

/// A gradient bar (`paint_bar`), stops left to right.
struct GradientBar: View {
    let gradient: DCModel.Gradient
    let scheme: DCColor.ColorScheme

    var body: some View {
        let stops = gradient.stops.map {
            SwiftUI.Gradient.Stop(color: $0.color.resolve(scheme, nil).swiftUI, location: Swift.min(Swift.max($0.pos, 0), 1))
        }
        RoundedRectangle(cornerRadius: Tokens.Radius.control / 3)
            .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control / 3).strokeBorder(Tokens.Color.separator, lineWidth: Tokens.Layout.hairline))
    }
}

/// A preset shape's outline as a template image (the shapes gallery's icons, `paint_preset`).
@MainActor
enum PresetIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage {
        if let i = cache[name] { return i }
        let side = Tokens.Space.l
        let inset = Tokens.Layout.hairline * 2
        let img = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let g = Preset.build(name, side - 2 * inset, side - 2 * inset, []), let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.translateBy(x: inset, y: inset)
            ctx.setLineWidth(Tokens.Layout.hairline)
            ctx.setStrokeColor(NSColor.black.cgColor)
            for sp in g.paths where sp.stroke {
                ctx.addPath(cgPath(sp.path))
                ctx.strokePath()
            }
            _ = rect
            return true
        }
        img.isTemplate = true
        cache[name] = img
        return img
    }

    static func cgPath(_ p: BezPath) -> CGPath {
        let path = CGMutablePath()
        var open = false
        for el in p.elements {
            switch el {
            case .moveTo(let q):
                path.move(to: CGPoint(x: q.x, y: q.y))
                open = true
            case .lineTo(let q):
                if open { path.addLine(to: CGPoint(x: q.x, y: q.y)) } else { path.move(to: CGPoint(x: q.x, y: q.y)); open = true }
            case .quadTo(let a, let b):
                if open { path.addQuadCurve(to: CGPoint(x: b.x, y: b.y), control: CGPoint(x: a.x, y: a.y)) }
            case .curveTo(let a, let b, let c):
                if open { path.addCurve(to: CGPoint(x: c.x, y: c.y), control1: CGPoint(x: a.x, y: a.y), control2: CGPoint(x: b.x, y: b.y)) }
            case .closePath:
                if open { path.closeSubpath() }
            }
        }
        return path
    }
}

/// The Shapes gallery as menus by category (`shapes_gallery`).
struct ShapesMenu<Label: View>: View {
    var includeFreeform = true
    let pick: (String) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            ForEach(Preset.Category.all, id: \.self) { cat in
                Menu(cat.label) {
                    ForEach(Preset.catalog.filter { $0.category == cat }, id: \.name) { p in
                        Button { pick(p.name) } label: { SwiftUI.Label { Text(p.label) } icon: { Image(nsImage: PresetIcons.image(p.name)) } }
                    }
                    if includeFreeform && cat == .lines {
                        Divider()
                        ForEach(Tools.freeformTools, id: \.0) { t in Button(t.1) { pick(t.0) } }
                    }
                }
            }
        } label: { label() }
    }
}

/// A section's empty state.
struct InspectorNote: View {
    let text: String
    var body: some View {
        Text(text).font(Tokens.Font.body).foregroundStyle(Tokens.Color.secondaryLabel).fixedSize(horizontal: false, vertical: true)
    }
}
