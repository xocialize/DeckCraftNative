// DCApp — Format ▸ Fill & Line, Effects, Size and Picture: deckcraft's Format Shape task pane
// (`format_shape`, `line_details`, `fx_slider`, `three_d_options`, `picture_fill_options` in
// `crates/ui-egui/src/panes.rs`), its gradient and pattern editors (`fillui.rs`), and the Shape Format,
// Picture Format and Size ribbon groups (`ribbon.rs`). MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors. Every control runs a registry command and reads the shape back from the session.
import AppKit
import DCAppModel
import DCColor
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DesignScaffold
import SwiftUI
import UniformTypeIdentifiers

/// Asks for a picture file and returns its bytes base64-encoded (`pick_fill_picture`).
@MainActor
func pickPictureBase64() -> (data: String, name: String)? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url, let bytes = try? Data(contentsOf: url) else { return nil }
    return (Cmd.base64Encode([UInt8](bytes)), url.lastPathComponent)
}

// MARK: - Fill & Line

struct FillLineView: View {
    let ctl: InspectorController
    let sh: DCModel.Shape

    var body: some View {
        let scheme = InspectorColors.scheme(ctl.session)
        Section(String(localized: "Fill", bundle: .module, comment: "Noun: a shape's fill")) {
            Picker(String(localized: "Fill", bundle: .module, comment: "Noun: a shape's fill"), selection: Binding(get: { InspectorFill.kind(sh.fill) }, set: setKind)) {
                ForEach(InspectorFill.shapeKinds, id: \.kind) { Text($0.label).tag($0.kind) }
            }
            .pickerStyle(.radioGroup)
            if InspectorFill.showsColor(sh.fill) {
                ColorButton(label: String(localized: "Color", bundle: .module), color: fillColor(scheme), scheme: scheme, noneLabel: String(localized: "No Fill", bundle: .module)) { ctl.pickFill($0) }
            }
            if InspectorFill.showsTransparency(sh.fill) {
                let seed = InspectorFill.fillTransparencySeed(sh.fill)
                CommitSlider(label: String(localized: "Transparency", bundle: .module), value: seed, range: 0 ... 100, suffix: "%") { v in
                    if let t = InspectorFill.fillTransparencyToApply(v, seed) { ctl.run("shape.fill", ["transparency": .num(t)]) }
                }
            }
            if case .picture(let pf)? = sh.fill {
                PictureFillOptions(fill: pf) { props in ctl.run("shape.fill", ["pictureProps": props]) } replace: {
                    if let p = pickPictureBase64() { ctl.run("shape.fill", ["picture": .string(p.data)]) }
                }
            }
            if case .gradient(let g)? = sh.fill {
                GradientEditor(gradient: g, scheme: scheme) { ctl.run("shape.fill", ["gradient": InspectorFill.gradientJSON($0)]) }
                Toggle(String(localized: "Rotate with shape", bundle: .module), isOn: Binding(get: { g.rotateWithShape }, set: { on in
                    var n = g
                    n.rotateWithShape = on
                    ctl.run("shape.fill", ["gradient": InspectorFill.gradientJSON(n)])
                }))
            }
            if case .pattern(let pt)? = sh.fill {
                PatternEditor(pattern: pt, scheme: scheme) { ctl.run("shape.fill", ["pattern": InspectorFill.patternJSON($0)]) }
            }
        }
        LineSection(ctl: ctl, sh: sh, scheme: scheme)
        Section(String(localized: "Shape Styles", bundle: .module)) {
            QuickStyleGrid(scheme: scheme) { ctl.run("shape.quickStyle", ["index": .integer($0)]) }
        }
    }

    private func fillColor(_ scheme: DCColor.ColorScheme) -> Rgba? {
        if case .solid(let c)? = sh.fill { return c.resolve(scheme, nil) }
        return nil
    }

    private func setKind(_ k: String) {
        guard k != InspectorFill.kind(sh.fill) else { return }
        if k == "picture" {
            if let p = pickPictureBase64() { ctl.run("shape.fill", ["picture": .string(p.data)]) }
        } else if let p = InspectorFill.shapeKindParams(k) {
            ctl.run("shape.fill", p)
        }
    }
}

struct LineSection: View {
    let ctl: InspectorController
    let sh: DCModel.Shape
    let scheme: DCColor.ColorScheme

    var body: some View {
        let l = InspectorFill.lineChoices(sh.line)
        Section(String(localized: "Line", bundle: .module, comment: "Noun: a shape's outline")) {
            Picker(String(localized: "Line", bundle: .module, comment: "Noun: a shape's outline"), selection: Binding(get: { InspectorFill.lineKind(sh.line) }, set: { k in
                switch k {
                case "none": ctl.run("shape.line", ["none": true])
                case "solid": ctl.run("shape.line", ["color": "tx1", "width": 1])
                default: ctl.run("shape.line", ["reset": true])
                }
            })) {
                Text("No line", bundle: .module).tag("none")
                Text("Solid line", bundle: .module).tag("solid")
                Text("Automatic", bundle: .module).tag("auto")
            }
            .pickerStyle(.radioGroup)
            ColorButton(label: String(localized: "Color", bundle: .module), color: lineColor, scheme: scheme, noneLabel: String(localized: "No Outline", bundle: .module)) { ctl.pickOutline($0) }
            NumberField(label: String(localized: "Width", bundle: .module), value: sh.line?.width ?? 0.75, step: 0.25, suffix: " pt", range: 0 ... 1584) {
                ctl.run("shape.line", ["width": .num($0)])
            }
            ChoicePicker(label: String(localized: "Dash", bundle: .module), options: InspectorFill.dashes, current: dashName) { ctl.run("shape.line", ["dash": .string($0)]) }
            ChoicePicker(label: String(localized: "Compound type", bundle: .module), options: InspectorFill.compounds, current: l.compound) { ctl.run("shape.line", ["compound": .string($0)]) }
            ChoicePicker(label: String(localized: "Cap type", bundle: .module), options: InspectorFill.caps, current: l.cap) { ctl.run("shape.line", ["cap": .string($0)]) }
            ChoicePicker(label: String(localized: "Join type", bundle: .module), options: InspectorFill.joins, current: l.join) { ctl.run("shape.line", ["join": .string($0)]) }
            ChoicePicker(label: String(localized: "Begin arrow", bundle: .module), options: InspectorFill.arrows, current: l.head) { ctl.run("shape.line", ["head": .string($0)]) }
            if let w = l.headSize {
                ChoicePicker(label: String(localized: "Begin size", bundle: .module), options: InspectorFill.arrowSizes, current: w) { ctl.run("shape.line", ["headSize": .string($0)]) }
            }
            ChoicePicker(label: String(localized: "End arrow", bundle: .module), options: InspectorFill.arrows, current: l.tail) { ctl.run("shape.line", ["tail": .string($0)]) }
            if let w = l.tailSize {
                ChoicePicker(label: String(localized: "End size", bundle: .module), options: InspectorFill.arrowSizes, current: w) { ctl.run("shape.line", ["tailSize": .string($0)]) }
            }
        }
    }

    private var lineColor: Rgba? {
        if case .solid(let c)? = sh.line?.fill { return c.resolve(scheme, nil) }
        return nil
    }

    private var dashName: String {
        if case .preset(let name)? = sh.line?.dash { return name }
        return "solid"
    }
}

/// Picture or texture fill's options (`picture_fill_options`, `picture_background_options`).
struct PictureFillOptions: View {
    let fill: PictureFill
    let set: (JSON) -> Void
    let replace: () -> Void

    var body: some View {
        LabeledContent(String(localized: "Picture source", bundle: .module)) { Button(String(localized: "Insert…", bundle: .module), action: replace) }
        Toggle(String(localized: "Tile picture as texture", bundle: .module), isOn: Binding(get: { if case .tile = fill.mode { true } else { false } }, set: { set(["tile": .bool($0)]) }))
        switch fill.mode {
        case .tile(let tx, let ty, let sx, let sy, let flip, let align):
            NumberField(label: String(localized: "Offset X", bundle: .module), value: tx, suffix: " pt") { set(["offsetX": .num($0)]) }
            NumberField(label: String(localized: "Offset Y", bundle: .module), value: ty, suffix: " pt") { set(["offsetY": .num($0)]) }
            NumberField(label: String(localized: "Scale X", bundle: .module), value: sx * 100, step: 5, suffix: "%") { set(["scaleX": .num($0 * 0.01)]) }
            NumberField(label: String(localized: "Scale Y", bundle: .module), value: sy * 100, step: 5, suffix: "%") { set(["scaleY": .num($0 * 0.01)]) }
            ChoicePicker(label: String(localized: "Alignment", bundle: .module), options: InspectorFill.tileAlignments.map { ($0.label, $0.key) }, current: align) { set(["align": .string($0)]) }
            ChoicePicker(label: String(localized: "Mirror", bundle: .module), options: InspectorFill.mirrors.map { ($0.label, $0.key) }, current: flip) { set(["mirror": .string($0)]) }
        case .stretch(let rect):
            ForEach(Array([
                String(localized: "Offset left", bundle: .module), String(localized: "Offset top", bundle: .module),
                String(localized: "Offset right", bundle: .module), String(localized: "Offset bottom", bundle: .module),
            ].enumerated()), id: \.offset) { i, label in
                NumberField(label: label, value: (rect.at(i) ?? 0) * 100, suffix: "%") { v in
                    var r = rect.count == 4 ? rect : [0, 0, 0, 0]
                    r[i] = v / 100
                    set(["stretch": .array(r.map { .num($0) })])
                }
            }
        }
        Toggle(String(localized: "Rotate with shape", bundle: .module), isOn: Binding(get: { !fill.upright }, set: { set(["rotateWithShape": .bool($0)]) }))
    }
}

/// The gradient editor (`gradient_editor`): presets, type, direction, angle, the stop bar and the selected
/// stop's colour, position and transparency.
struct GradientEditor: View {
    let gradient: DCModel.Gradient
    let scheme: DCColor.ColorScheme
    let apply: (DCModel.Gradient) -> Void
    @State private var selected = 0

    var body: some View {
        let g = gradient
        let sel = Swift.min(selected, Swift.max(g.stops.count - 1, 0))
        LabeledContent(String(localized: "Preset gradients", bundle: .module)) {
            HStack(spacing: Tokens.Space.xs) {
                ForEach(Array(InspectorFill.presets(g).enumerated()), id: \.offset) { i, v in
                    Button { apply(v) } label: { GradientBar(gradient: v, scheme: scheme).frame(width: Tokens.Space.xl, height: Tokens.Space.l) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Preset gradient \(i + 1)", bundle: .module))
                }
            }
        }
        Picker(String(localized: "Type", bundle: .module), selection: Binding(get: { InspectorFill.typeName(g) }, set: { if let n = InspectorFill.withType(g, $0) { apply(n) } })) {
            ForEach(InspectorFill.types, id: \.self) { Text($0).tag($0) }
        }
        switch g.shape {
        case .linear(let angle, _):
            LabeledContent(String(localized: "Direction", bundle: .module)) {
                HStack(spacing: Tokens.Layout.hairline) {
                    ForEach(InspectorFill.linearDirections, id: \.angle) { d in
                        IconToggle(symbol: arrowSymbol(d.angle), help: "\(Int(d.angle))°", on: abs(angle - d.angle) < 0.5) { apply(InspectorFill.withAngle(g, d.angle)) }
                    }
                }
            }
            NumberField(label: String(localized: "Angle", bundle: .module), value: angle, step: 15, suffix: "°") { apply(InspectorFill.withAngle(g, $0)) }
        case .path(_, let focus):
            Picker(String(localized: "Direction", bundle: .module), selection: Binding(get: { InspectorFill.pathDirections.firstIndex { zip($0.focus, focus).allSatisfy { abs($0 - $1) < 1e-3 } } ?? -1 },
                                                   set: { if let d = InspectorFill.pathDirections.at($0) { apply(InspectorFill.withFocus(g, d.focus)) } })) {
                if !InspectorFill.pathDirections.contains(where: { zip($0.focus, focus).allSatisfy { abs($0 - $1) < 1e-3 } }) { Text("Custom", bundle: .module).tag(-1) }
                ForEach(Array(InspectorFill.pathDirections.enumerated()), id: \.offset) { Text($0.element.label).tag($0.offset) }
            }
        }
        LabeledContent(String(localized: "Gradient stops", bundle: .module)) {
            StopBar(gradient: g, scheme: scheme, selected: sel, select: { selected = $0 }, apply: apply, add: { pos in
                if let (n, i) = InspectorFill.addStop(g, at: pos) {
                    selected = i
                    apply(n)
                }
            })
        }
        if let stop = g.stops.at(sel) {
            ColorButton(label: String(localized: "Stop color", bundle: .module), color: stop.color.resolve(scheme, nil), scheme: scheme) { c in
                if let c { apply(InspectorFill.setStopColor(g, sel, c)) }
            }
            NumberField(label: String(localized: "Position", bundle: .module), value: (stop.pos * 100).rounded(), step: 5, suffix: "%", range: 0 ... 100) { apply(InspectorFill.setStopPosition(g, sel, percent: $0)) }
            CommitSlider(label: String(localized: "Stop transparency", bundle: .module), value: (1 - InspectorFill.alphaOf(stop.color)) * 100, range: 0 ... 100, suffix: "%") {
                apply(InspectorFill.setStopTransparency(g, sel, percent: $0))
            }
            Button(String(localized: "Remove stop", bundle: .module)) {
                if let (n, i) = InspectorFill.removeStop(g, sel) {
                    selected = i
                    apply(n)
                }
            }
            .disabled(g.stops.count <= 2)
        }
    }

    private func arrowSymbol(_ a: Double) -> String {
        switch Int(a) {
        case 0: "arrow.right"
        case 45: "arrow.down.right"
        case 90: "arrow.down"
        case 135: "arrow.down.left"
        case 180: "arrow.left"
        case 225: "arrow.up.left"
        case 270: "arrow.up"
        default: "arrow.up.right"
        }
    }
}

/// The stop bar: click to add a stop, drag a stop to move it, click a stop to select it.
struct StopBar: View {
    let gradient: DCModel.Gradient
    let scheme: DCColor.ColorScheme
    let selected: Int
    let select: (Int) -> Void
    let apply: (DCModel.Gradient) -> Void
    let add: (Double) -> Void
    @State private var drag: (Int, Double)?

    var body: some View {
        GeometryReader { geo in
            let w = Swift.max(geo.size.width, 1)
            ZStack(alignment: .topLeading) {
                GradientBar(gradient: gradient, scheme: scheme)
                    .frame(height: Tokens.Space.m)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in add(p.x / w) }
                    .accessibilityLabel(String(localized: "Gradient bar", bundle: .module))
                ForEach(Array(gradient.stops.enumerated()), id: \.offset) { i, s in
                    let pos = drag?.0 == i ? drag?.1 ?? s.pos : s.pos
                    Image(systemName: "triangle.fill")
                        .foregroundStyle(s.color.resolve(scheme, nil).swiftUI)
                        .overlay(Image(systemName: "triangle").foregroundStyle(i == selected ? Tokens.Color.accent : Tokens.Color.secondaryLabel))
                        .position(x: Swift.min(Swift.max(pos, 0), 1) * w, y: Tokens.Space.m + Tokens.Space.s)
                        .accessibilityLabel(String(localized: "Gradient stop \(i + 1)", bundle: .module))
                        .onTapGesture { select(i) }
                        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                            select(i)
                            drag = (i, Swift.min(Swift.max(v.location.x / w, 0), 1))
                        }.onEnded { _ in
                            if let (di, dp) = drag { apply(InspectorFill.moveStop(gradient, di, to: dp)) }
                            drag = nil
                        })
                }
            }
        }
        .frame(height: Tokens.Space.xl + Tokens.Space.xs)
    }
}

/// The pattern editor (`pattern_editor`): the gallery drawn in the pattern's colours, then Foreground and
/// Background colour menus.
struct PatternEditor: View {
    let pattern: PatternFill
    let scheme: DCColor.ColorScheme
    let apply: (PatternFill) -> Void

    var body: some View {
        let fg = pattern.fg.resolve(scheme, nil), bg = pattern.bg.resolve(scheme, nil)
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            Text("Pattern", bundle: .module)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Tokens.Space.xl), spacing: Tokens.Space.xs / 2), count: 8), spacing: Tokens.Space.xs / 2) {
                ForEach(InspectorFill.patternGallery, id: \.self) { name in
                    Button { if let n = InspectorFill.withPreset(pattern, name) { apply(n) } } label: {
                        PatternSwatch(preset: name, fg: fg, bg: bg)
                            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control / 3)
                                .strokeBorder(pattern.preset == name ? Tokens.Color.accent : Tokens.Color.separator,
                                              lineWidth: pattern.preset == name ? Tokens.Layout.hairline * 2 : Tokens.Layout.hairline))
                    }
                    .buttonStyle(.plain)
                    .help(InspectorFill.patternLabel(name))
                    .accessibilityLabel(InspectorFill.patternLabel(name))
                    .accessibilityAddTraits(pattern.preset == name ? .isSelected : [])
                }
            }
        }
        ColorButton(label: String(localized: "Foreground color", bundle: .module), color: fg, scheme: scheme) { c in
            if let c { var n = pattern; n.fg = c; apply(n) }
        }
        ColorButton(label: String(localized: "Background color", bundle: .module), color: bg, scheme: scheme) { c in
            if let c { var n = pattern; n.bg = c; apply(n) }
        }
    }
}

// MARK: - Effects

struct EffectsView: View {
    let ctl: InspectorController
    let sh: DCModel.Shape

    var body: some View {
        let scheme = InspectorColors.scheme(ctl.session)
        let fx = sh.effects ?? Effects()
        Section(String(localized: "Shadow", bundle: .module)) {
            Picker(String(localized: "Shadow", bundle: .module), selection: Binding(get: { "" }, set: { ctl.run("shape.effects", ["shadow": .string($0)]) })) {
                Text("Choose…", bundle: .module).tag("")
                ForEach(Self.shadows, id: \.1) { Text($0.0).tag($0.1) }
            }
            if let sw = fx.outerShadow ?? fx.innerShadow {
                ColorButton(label: String(localized: "Color", bundle: .module), color: sw.color.resolve(scheme, nil), scheme: scheme) { c in
                    ctl.run("shape.effects", ["shadowProps": ["color": c.map(InspectorColors.param) ?? .null]])
                }
                fxSlider(String(localized: "Transparency", bundle: .module), (1 - sw.color.alpha) * 100, 0 ... 100, "%", "shadowProps", "transparency", 0.01)
                fxSlider(String(localized: "Blur", bundle: .module), sw.blur, 0 ... 100, " pt", "shadowProps", "blur", 1)
                fxSlider(String(localized: "Angle", bundle: .module), sw.dir, 0 ... 359, "°", "shadowProps", "dir", 1)
                fxSlider(String(localized: "Distance", bundle: .module), sw.dist, 0 ... 200, " pt", "shadowProps", "dist", 1)
            }
        }
        Section(String(localized: "Reflection", bundle: .module)) {
            Picker(String(localized: "Reflection", bundle: .module), selection: Binding(get: { "" }, set: { ctl.run("shape.effects", ["reflection": .string($0)]) })) {
                Text("Choose…", bundle: .module).tag("")
                ForEach([
                    (String(localized: "None", bundle: .module), "none"), (String(localized: "Tight", bundle: .module, comment: "A reflection preset"), "tight"),
                    (String(localized: "Half", bundle: .module, comment: "A reflection preset"), "half"), (String(localized: "Full", bundle: .module, comment: "A reflection preset"), "full"),
                ], id: \.1) { Text($0.0).tag($0.1) }
            }
            if let r = fx.reflection {
                fxSlider(String(localized: "Transparency", bundle: .module), (1 - r.startAlpha) * 100, 0 ... 100, "%", "reflectionProps", "transparency", 0.01)
                fxSlider(String(localized: "Size", bundle: .module), r.endPos * 100, 0 ... 100, "%", "reflectionProps", "size", 0.01)
                fxSlider(String(localized: "Distance", bundle: .module), r.dist, 0 ... 100, " pt", "reflectionProps", "dist", 1)
                fxSlider(String(localized: "Blur", bundle: .module), r.blur, 0 ... 100, " pt", "reflectionProps", "blur", 1)
            }
        }
        Section(String(localized: "Glow", bundle: .module)) {
            fxSlider(String(localized: "Size", bundle: .module), fx.glow?.radius ?? 0, 0 ... 150, " pt", "glowProps", "radius", 1)
            if let g = fx.glow {
                ColorButton(label: String(localized: "Color", bundle: .module), color: g.color.resolve(scheme, nil), scheme: scheme) { c in
                    ctl.run("shape.effects", ["glowProps": ["color": c.map(InspectorColors.param) ?? .null]])
                }
                fxSlider(String(localized: "Transparency", bundle: .module), (1 - g.color.alpha) * 100, 0 ... 100, "%", "glowProps", "transparency", 0.01)
            }
        }
        Section(String(localized: "Soft Edges", bundle: .module)) {
            CommitSlider(label: String(localized: "Size", bundle: .module), value: fx.softEdge ?? 0, range: 0 ... 50, suffix: " pt") { ctl.run("shape.effects", ["softEdges": .num($0)]) }
        }
        ThreeDSection(ctl: ctl, raw: fx.raw3d)
        Section {
            Button(String(localized: "Reset Effects", bundle: .module)) { ctl.run("shape.effects", ["reset": true]) }
        }
    }

    static let shadows: [(String, String)] = [
        (String(localized: "None", bundle: .module), "none"), (String(localized: "Outer", bundle: .module, comment: "A shadow preset"), "outer"),
        (String(localized: "Bottom", bundle: .module, comment: "A shadow preset"), "bottom"), (String(localized: "Center", bundle: .module, comment: "A shadow preset"), "center"),
        (String(localized: "Inner", bundle: .module, comment: "A shadow preset"), "inner"), (String(localized: "Perspective", bundle: .module, comment: "A shadow preset"), "perspective"),
    ]

    /// `fx_slider`: one property of an effect, committed as `{key: {prop: shown × scale}}`.
    private func fxSlider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ suffix: String, _ key: String, _ prop: String, _ scale: Double) -> some View {
        CommitSlider(label: label, value: value, range: range, suffix: suffix) { v in
            var inner = JSONObject()
            inner.set(prop, .num(v * scale))
            var p = JSONObject()
            p.set(key, .object(inner))
            ctl.run("shape.effects", .object(p))
        }
    }
}

/// Format Shape ▸ Effects ▸ 3-D Format and 3-D Rotation (`three_d_options`).
struct ThreeDSection: View {
    let ctl: InspectorController
    let raw: String?

    var body: some View {
        let s3 = raw.map(ThreeDCommands.Shape3d.parse) ?? ThreeDCommands.Shape3d()
        Section(String(localized: "3-D Format", bundle: .module)) {
            bevel(String(localized: "Top bevel", bundle: .module), "bevelTop", s3.top)
            bevel(String(localized: "Bottom bevel", bundle: .module), "bevelBottom", s3.bottom)
            drag(String(localized: "Depth", bundle: .module), s3.depth, " pt", "depth")
            drag(String(localized: "Contour", bundle: .module), s3.contour, " pt", "contour")
            combo(String(localized: "Material", bundle: .module), "material", s3.material, ThreeDCommands.materials)
            combo(String(localized: "Lighting", bundle: .module), "lighting", s3.light, ThreeDCommands.lights)
        }
        Section(String(localized: "3-D Rotation", bundle: .module)) {
            combo(String(localized: "Presets", bundle: .module), "camera", s3.camera, ThreeDCommands.cameras)
            drag(String(localized: "X Rotation", bundle: .module), s3.rot?.x ?? 0, "°", "rotX")
            drag(String(localized: "Y Rotation", bundle: .module), s3.rot?.y ?? 0, "°", "rotY")
            drag(String(localized: "Z Rotation", bundle: .module), s3.rot?.z ?? 0, "°", "rotZ")
            drag(String(localized: "Distance from ground", bundle: .module), s3.z, " pt", "z")
            Button(String(localized: "Reset 3-D", bundle: .module)) { set("reset", true) }.disabled(raw == nil)
        }
    }

    @ViewBuilder private func bevel(_ label: String, _ key: String, _ b: ThreeDCommands.Bevel?) -> some View {
        combo(label, key, b?.preset ?? "none", ["none"] + ThreeDCommands.bevels)
        if let b {
            drag(String(localized: "Width", bundle: .module), b.w, " pt", "\(key)W")
            drag(String(localized: "Height", bundle: .module), b.h, " pt", "\(key)H")
        }
    }

    private func combo(_ label: String, _ key: String, _ cur: String, _ options: [String]) -> some View {
        ChoicePicker(label: label, options: options.map { (InspectorFill.presetLabel($0), $0) }, current: cur) { set(key, .string($0)) }
    }

    private func drag(_ label: String, _ v: Double, _ suffix: String, _ key: String) -> some View {
        NumberField(label: label, value: v, suffix: suffix) { set(key, .num($0)) }
    }

    private func set(_ key: String, _ v: JSON) {
        var inner = JSONObject()
        inner.set(key, v)
        ctl.run("shape.effects", ["threeD": .object(inner)])
    }
}

// MARK: - Size

struct SizeView: View {
    let ctl: InspectorController
    let sh: DCModel.Shape
    @State private var lockAspect = false

    var body: some View {
        let x = ctl.box(sh) ?? Xfrm(0, 0, 0, 0)
        let unit = ctl.session.prefs.units
        let ppu = unit.pointsPerUnit
        Section(String(localized: "Size", bundle: .module)) {
            NumberField(label: String(localized: "Height", bundle: .module), value: x.h / ppu, step: 0.1, suffix: unit.suffix) { resize("h", $0 * ppu) }
            NumberField(label: String(localized: "Width", bundle: .module), value: x.w / ppu, step: 0.1, suffix: unit.suffix) { resize("w", $0 * ppu) }
            NumberField(label: String(localized: "Rotation", bundle: .module), value: x.rot, step: 1, suffix: "°") { ctl.run("shape.rotate", ["deg": .num($0)]) }
            Toggle(String(localized: "Lock aspect ratio", bundle: .module), isOn: $lockAspect)
            Button(String(localized: "Size and Position…", bundle: .module)) { ctl.run("shape.sizePosition") }
        }
        Section(String(localized: "Position", bundle: .module)) {
            NumberField(label: String(localized: "Horizontal", bundle: .module), value: x.x / ppu, step: 0.1, suffix: unit.suffix) { ctl.run("shape.move", ["x": .num($0 * ppu)]) }
            NumberField(label: String(localized: "Vertical", bundle: .module), value: x.y / ppu, step: 0.1, suffix: unit.suffix) { ctl.run("shape.move", ["y": .num($0 * ppu)]) }
        }
        Section(String(localized: "Alt Text", bundle: .module)) {
            AltTextField(text: sh.descr) { ctl.run("shape.altText", ["text": .string($0)]) }
            Button(String(localized: "Alt Text…", bundle: .module)) { ctl.run("app.dialog", ["id": "altText"]) }
        }
    }

    private func resize(_ key: String, _ v: Double) {
        var p: JSON = .emptyObject
        p.set(key, .num(Swift.max(v, 0)))
        if lockAspect { p.set("lockAspect", true) }
        ctl.run("shape.resize", p)
    }
}

/// A multi-line field that commits when it loses focus (`text_draft`: a draft is kept while the stored text
/// is unchanged, and dropped when it changes underneath).
struct AltTextField: View {
    let text: String
    let commit: (String) -> Void
    @State private var draft: (base: String, text: String)?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(String(localized: "Alt text", bundle: .module), text: Binding(get: { InspectorText.draft(draft, text) }, set: { draft = (text, $0) }), axis: .vertical)
            .lineLimit(3 ... 6)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onChange(of: focused) { _, now in
                if !now, let d = draft {
                    draft = nil
                    if d.base == text && d.text != text { commit(d.text) }
                }
            }
    }
}

// MARK: - Picture

struct PictureView: View {
    let ctl: InspectorController
    let sh: DCModel.Shape
    @State private var compress = (ppi: 220, onlySelected: true, deleteCropped: true)

    var body: some View {
        let pf: PictureFill? = { if case .picture(let f) = sh.kind { return f } else { return nil } }()
        let adj = pf?.adjust
        Section(String(localized: "Corrections", bundle: .module)) {
            CommitSlider(label: String(localized: "Brightness", bundle: .module), value: adj?.brightness ?? 0, range: -1 ... 1, decimals: 2) { ctl.run("picture.adjust", ["brightness": .num($0)]) }
            CommitSlider(label: String(localized: "Contrast", bundle: .module), value: adj?.contrast ?? 0, range: -1 ... 1, decimals: 2) { ctl.run("picture.adjust", ["contrast": .num($0)]) }
            CommitSlider(label: String(localized: "Saturation", bundle: .module), value: adj?.saturation ?? 1, range: 0 ... 4, decimals: 2) { ctl.run("picture.adjust", ["saturation": .num($0)]) }
            CommitSlider(label: String(localized: "Transparency", bundle: .module), value: 1 - (pf?.alpha ?? 1), range: 0 ... 1, decimals: 2) { ctl.run("picture.adjust", ["transparency": .num($0)]) }
            Button(String(localized: "Reset Picture", bundle: .module)) { ctl.run("picture.reset") }
        }
        Section(String(localized: "Adjust", bundle: .module, comment: "Section heading: picture adjustments")) {
            Menu(String(localized: "Remove Background", bundle: .module)) {
                ForEach([
                    (String(localized: "Remove Background", bundle: .module), 20.0), (String(localized: "Remove More (looser)", bundle: .module), 35.0),
                    (String(localized: "Remove Less (tighter)", bundle: .module), 10.0),
                ], id: \.1) { l, tol in
                    Button(l) { ctl.run("picture.removeBackground", ["tolerance": .num(tol)]) }
                }
            }
            .disabled(!ctl.enabled("picture.removeBackground"))
            Menu(String(localized: "Recolor", bundle: .module)) {
                ForEach(RecolorCommands.presets(), id: \.0) { id, label in Button(label) { ctl.run("picture.recolor", ["preset": .string(id)]) } }
            }
            Menu(String(localized: "Artistic Effects", bundle: .module)) {
                Button(String(localized: "None", bundle: .module)) { ctl.run("picture.artisticEffect", ["effect": "none"]) }
                ForEach(ArtisticCommands.effects, id: \.0) { e, l in Button(l) { ctl.run("picture.artisticEffect", ["effect": .string(e)]) } }
            }
            .disabled(!ctl.enabled("picture.artisticEffect"))
            Button(String(localized: "Set Transparent Color", bundle: .module)) {
                // As in PowerPoint, a click on the picture itself picks the colour (the canvas's eyedropper);
                // without a canvas, the system's colour sampler.
                if CanvasFeature.setTransparentColor() { return }
                NSColorSampler().show { c in
                    if let rgba = c.flatMap(ColorGrid.rgba) { MainActor.assumeIsolated { _ = ctl.run("picture.transparentColor", ["color": .string("#\(rgba.hex)")]) } }
                }
            }
            .help(String(localized: "Pick the colour in the picture that becomes transparent", bundle: .module))
            Button(String(localized: "Change Picture…", bundle: .module)) { ctl.run("app.changePictureDialog") }
        }
        Section(String(localized: "Picture Styles", bundle: .module)) {
            Picker(String(localized: "Style", bundle: .module), selection: Binding(get: { "" }, set: { ctl.run("picture.style", ["style": .string($0)]) })) {
                Text("Choose…", bundle: .module).tag("")
                ForEach(PictureStyleCommands.styles, id: \.0) { Text($0.1).tag($0.0) }
                Divider()
                Text("Reset Style", bundle: .module).tag("none")
            }
            ColorButton(label: String(localized: "Picture Border", bundle: .module), color: borderColor, scheme: InspectorColors.scheme(ctl.session), noneLabel: String(localized: "No Outline", bundle: .module)) { c in
                if let c { ctl.run("shape.line", ["color": InspectorColors.param(c)]) } else { ctl.run("shape.line", ["none": true]) }
            }
        }
        Section(String(localized: "Crop", bundle: .module, comment: "Section heading for cropping a picture")) {
            ShapesMenu(includeFreeform: false, pick: { ctl.run("shape.change", ["preset": .string($0)]) }) { Text("Crop to Shape", bundle: .module) }
            ForEach([
                (String(localized: "Crop 10% each side", bundle: .module), 0.1), (String(localized: "Crop 20% each side", bundle: .module), 0.2),
                (String(localized: "Reset Crop", bundle: .module), 0.0),
            ], id: \.0) { l, v in
                Button(l) { ctl.run("picture.crop", ["left": .num(v), "top": .num(v), "right": .num(v), "bottom": .num(v)]) }
            }
        }
        Section(String(localized: "Compress Pictures", bundle: .module)) {
            Toggle(String(localized: "Apply only to this picture", bundle: .module), isOn: $compress.onlySelected)
            Toggle(String(localized: "Delete cropped areas of pictures", bundle: .module), isOn: $compress.deleteCropped)
            Picker(String(localized: "Resolution", bundle: .module), selection: $compress.ppi) {
                Text("HD (330 ppi)", bundle: .module).tag(330)
                Text("Print (220 ppi)", bundle: .module).tag(220)
                Text("Web (150 ppi)", bundle: .module).tag(150)
                Text("E-mail (96 ppi)", bundle: .module).tag(96)
            }
            Button(String(localized: "Compress", bundle: .module, comment: "Verb: compress the pictures")) { compressNow() }.disabled(!ctl.enabled("picture.compress"))
        }
    }

    private var borderColor: Rgba? {
        if case .solid(let c)? = sh.line?.fill { return c.resolve(InspectorColors.scheme(ctl.session), nil) }
        return nil
    }

    /// `compress_menu`'s Compress: the result goes to the status line.
    private func compressNow() {
        let p: JSON = ["ppi": .integer(compress.ppi), "deleteCropped": .bool(compress.deleteCropped), "all": .bool(!compress.onlySelected)]
        if case .success(let r) = ctl.run("picture.compress", p) {
            let kb = { (v: JSON?) in (v?.asU64 ?? 0) / 1024 }
            let n = r["pictures"]?.asU64 ?? 0
            ctl.model.status = n == 0 ? String(localized: "Pictures are already at or below that resolution", bundle: .module)
                : String(localized: "Compressed \(Int(clamping: n)) picture(s): \(String(kb(r["before"]))) KB → \(String(kb(r["after"]))) KB", bundle: .module)
        }
    }
}

/// Quick Styles (`quick_styles`): six theme-style rows by Dark 1 and the six accents, drawn as "Abc" tiles.
struct QuickStyleGrid: View {
    let scheme: DCColor.ColorScheme
    let pick: (Int) -> Void

    var body: some View {
        Grid(horizontalSpacing: Tokens.Space.xs, verticalSpacing: Tokens.Space.xs) {
            ForEach(0 ..< InspectorShape.quickStyleRows, id: \.self) { row in
                GridRow {
                    ForEach(0 ..< InspectorShape.quickStyleSlots.count, id: \.self) { col in
                        let index = InspectorShape.quickStyleIndex(row: row, column: col)
                        Button { pick(index) } label: { QuickStyleTile(scheme: scheme, index: index).frame(height: Tokens.Space.xl) }
                            .buttonStyle(.plain)
                            .help(String(localized: "Style \(index + 1)", bundle: .module))
                            .accessibilityLabel(String(localized: "Quick Style \(index + 1)", bundle: .module))
                    }
                }
            }
        }
    }
}

/// One Quick Style tile as deckcraft paints it: outlined on the light colour, a light tint, a darker fill, or solid.
/// The inspector's grid and the ribbon's gallery both draw it.
struct QuickStyleTile: View {
    let scheme: DCColor.ColorScheme
    let index: Int

    var body: some View {
        let n = Swift.max(InspectorShape.quickStyleSlots.count, 1)
        let row = index / n
        let slot = InspectorShape.quickStyleSlots.at(index % n) ?? .accent1
        let light = scheme.get(.lt1).swiftUI, dark = scheme.get(.dk1).swiftUI, accent = scheme.get(slot).swiftUI
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.control / 2)
        let (fill, stroke, text): (Color, Color, Color) = switch row {
        case 0: (light, accent, dark)
        case 2: (accent.opacity(0.25), .clear, accent)
        case 5: (accent.mix(with: dark, by: 0.25), light, light)
        default: (accent, accent.mix(with: dark, by: 0.3), light)
        }
        shape.fill(fill)
            .overlay(shape.strokeBorder(stroke, lineWidth: Tokens.Layout.hairline * 1.5))
            .overlay(Text(verbatim: "Abc").font(Tokens.Font.caption).foregroundStyle(text))
    }
}
