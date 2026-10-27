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
        Section("Fill") {
            Picker("Fill", selection: Binding(get: { InspectorFill.kind(sh.fill) }, set: setKind)) {
                ForEach(InspectorFill.shapeKinds, id: \.kind) { Text($0.label).tag($0.kind) }
            }
            .pickerStyle(.radioGroup)
            if InspectorFill.showsColor(sh.fill) {
                ColorButton(label: "Color", color: fillColor(scheme), scheme: scheme, noneLabel: "No Fill") { ctl.pickFill($0) }
            }
            if InspectorFill.showsTransparency(sh.fill) {
                let seed = InspectorFill.fillTransparencySeed(sh.fill)
                CommitSlider(label: "Transparency", value: seed, range: 0 ... 100, suffix: "%") { v in
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
                Toggle("Rotate with shape", isOn: Binding(get: { g.rotateWithShape }, set: { on in
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
        Section("Shape Styles") {
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
        Section("Line") {
            Picker("Line", selection: Binding(get: { InspectorFill.lineKind(sh.line) }, set: { k in
                switch k {
                case "none": ctl.run("shape.line", ["none": true])
                case "solid": ctl.run("shape.line", ["color": "tx1", "width": 1])
                default: ctl.run("shape.line", ["reset": true])
                }
            })) {
                Text("No line").tag("none")
                Text("Solid line").tag("solid")
                Text("Automatic").tag("auto")
            }
            .pickerStyle(.radioGroup)
            ColorButton(label: "Color", color: lineColor, scheme: scheme, noneLabel: "No Outline") { ctl.pickOutline($0) }
            NumberField(label: "Width", value: sh.line?.width ?? 0.75, step: 0.25, suffix: " pt", range: 0 ... 1584) {
                ctl.run("shape.line", ["width": .num($0)])
            }
            ChoicePicker(label: "Dash", options: InspectorFill.dashes, current: dashName) { ctl.run("shape.line", ["dash": .string($0)]) }
            ChoicePicker(label: "Compound type", options: InspectorFill.compounds, current: l.compound) { ctl.run("shape.line", ["compound": .string($0)]) }
            ChoicePicker(label: "Cap type", options: InspectorFill.caps, current: l.cap) { ctl.run("shape.line", ["cap": .string($0)]) }
            ChoicePicker(label: "Join type", options: InspectorFill.joins, current: l.join) { ctl.run("shape.line", ["join": .string($0)]) }
            ChoicePicker(label: "Begin arrow", options: InspectorFill.arrows, current: l.head) { ctl.run("shape.line", ["head": .string($0)]) }
            if let w = l.headSize {
                ChoicePicker(label: "Begin size", options: InspectorFill.arrowSizes, current: w) { ctl.run("shape.line", ["headSize": .string($0)]) }
            }
            ChoicePicker(label: "End arrow", options: InspectorFill.arrows, current: l.tail) { ctl.run("shape.line", ["tail": .string($0)]) }
            if let w = l.tailSize {
                ChoicePicker(label: "End size", options: InspectorFill.arrowSizes, current: w) { ctl.run("shape.line", ["tailSize": .string($0)]) }
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
        LabeledContent("Picture source") { Button("Insert…", action: replace) }
        Toggle("Tile picture as texture", isOn: Binding(get: { if case .tile = fill.mode { true } else { false } }, set: { set(["tile": .bool($0)]) }))
        switch fill.mode {
        case .tile(let tx, let ty, let sx, let sy, let flip, let align):
            NumberField(label: "Offset X", value: tx, suffix: " pt") { set(["offsetX": .num($0)]) }
            NumberField(label: "Offset Y", value: ty, suffix: " pt") { set(["offsetY": .num($0)]) }
            NumberField(label: "Scale X", value: sx * 100, step: 5, suffix: "%") { set(["scaleX": .num($0 * 0.01)]) }
            NumberField(label: "Scale Y", value: sy * 100, step: 5, suffix: "%") { set(["scaleY": .num($0 * 0.01)]) }
            ChoicePicker(label: "Alignment", options: InspectorFill.tileAlignments.map { ($0.label, $0.key) }, current: align) { set(["align": .string($0)]) }
            ChoicePicker(label: "Mirror", options: InspectorFill.mirrors.map { ($0.label, $0.key) }, current: flip) { set(["mirror": .string($0)]) }
        case .stretch(let rect):
            ForEach(Array(["Offset left", "Offset top", "Offset right", "Offset bottom"].enumerated()), id: \.offset) { i, label in
                NumberField(label: label, value: (rect.at(i) ?? 0) * 100, suffix: "%") { v in
                    var r = rect.count == 4 ? rect : [0, 0, 0, 0]
                    r[i] = v / 100
                    set(["stretch": .array(r.map { .num($0) })])
                }
            }
        }
        Toggle("Rotate with shape", isOn: Binding(get: { !fill.upright }, set: { set(["rotateWithShape": .bool($0)]) }))
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
        LabeledContent("Preset gradients") {
            HStack(spacing: Tokens.Space.xs) {
                ForEach(Array(InspectorFill.presets(g).enumerated()), id: \.offset) { i, v in
                    Button { apply(v) } label: { GradientBar(gradient: v, scheme: scheme).frame(width: Tokens.Space.xl, height: Tokens.Space.l) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Preset gradient \(i + 1)")
                }
            }
        }
        Picker("Type", selection: Binding(get: { InspectorFill.typeName(g) }, set: { if let n = InspectorFill.withType(g, $0) { apply(n) } })) {
            ForEach(InspectorFill.types, id: \.self) { Text($0).tag($0) }
        }
        switch g.shape {
        case .linear(let angle, _):
            LabeledContent("Direction") {
                HStack(spacing: Tokens.Layout.hairline) {
                    ForEach(InspectorFill.linearDirections, id: \.angle) { d in
                        IconToggle(symbol: arrowSymbol(d.angle), help: "\(Int(d.angle))°", on: abs(angle - d.angle) < 0.5) { apply(InspectorFill.withAngle(g, d.angle)) }
                    }
                }
            }
            NumberField(label: "Angle", value: angle, step: 15, suffix: "°") { apply(InspectorFill.withAngle(g, $0)) }
        case .path(_, let focus):
            Picker("Direction", selection: Binding(get: { InspectorFill.pathDirections.firstIndex { zip($0.focus, focus).allSatisfy { abs($0 - $1) < 1e-3 } } ?? -1 },
                                                   set: { if let d = InspectorFill.pathDirections.at($0) { apply(InspectorFill.withFocus(g, d.focus)) } })) {
                if !InspectorFill.pathDirections.contains(where: { zip($0.focus, focus).allSatisfy { abs($0 - $1) < 1e-3 } }) { Text("Custom").tag(-1) }
                ForEach(Array(InspectorFill.pathDirections.enumerated()), id: \.offset) { Text($0.element.label).tag($0.offset) }
            }
        }
        LabeledContent("Gradient stops") {
            StopBar(gradient: g, scheme: scheme, selected: sel, select: { selected = $0 }, apply: apply, add: { pos in
                if let (n, i) = InspectorFill.addStop(g, at: pos) {
                    selected = i
                    apply(n)
                }
            })
        }
        if let stop = g.stops.at(sel) {
            ColorButton(label: "Stop color", color: stop.color.resolve(scheme, nil), scheme: scheme) { c in
                if let c { apply(InspectorFill.setStopColor(g, sel, c)) }
            }
            NumberField(label: "Position", value: (stop.pos * 100).rounded(), step: 5, suffix: "%", range: 0 ... 100) { apply(InspectorFill.setStopPosition(g, sel, percent: $0)) }
            CommitSlider(label: "Stop transparency", value: (1 - InspectorFill.alphaOf(stop.color)) * 100, range: 0 ... 100, suffix: "%") {
                apply(InspectorFill.setStopTransparency(g, sel, percent: $0))
            }
            Button("Remove stop") {
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
                    .accessibilityLabel("Gradient bar")
                ForEach(Array(gradient.stops.enumerated()), id: \.offset) { i, s in
                    let pos = drag?.0 == i ? drag?.1 ?? s.pos : s.pos
                    Image(systemName: "triangle.fill")
                        .foregroundStyle(s.color.resolve(scheme, nil).swiftUI)
                        .overlay(Image(systemName: "triangle").foregroundStyle(i == selected ? Tokens.Color.accent : Tokens.Color.secondaryLabel))
                        .position(x: Swift.min(Swift.max(pos, 0), 1) * w, y: Tokens.Space.m + Tokens.Space.s)
                        .accessibilityLabel("Gradient stop \(i + 1)")
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
            Text("Pattern")
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
        ColorButton(label: "Foreground color", color: fg, scheme: scheme) { c in
            if let c { var n = pattern; n.fg = c; apply(n) }
        }
        ColorButton(label: "Background color", color: bg, scheme: scheme) { c in
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
        Section("Shadow") {
            Picker("Shadow", selection: Binding(get: { "" }, set: { ctl.run("shape.effects", ["shadow": .string($0)]) })) {
                Text("Choose…").tag("")
                ForEach(Self.shadows, id: \.1) { Text($0.0).tag($0.1) }
            }
            if let sw = fx.outerShadow ?? fx.innerShadow {
                ColorButton(label: "Color", color: sw.color.resolve(scheme, nil), scheme: scheme) { c in
                    ctl.run("shape.effects", ["shadowProps": ["color": c.map(InspectorColors.param) ?? .null]])
                }
                fxSlider("Transparency", (1 - sw.color.alpha) * 100, 0 ... 100, "%", "shadowProps", "transparency", 0.01)
                fxSlider("Blur", sw.blur, 0 ... 100, " pt", "shadowProps", "blur", 1)
                fxSlider("Angle", sw.dir, 0 ... 359, "°", "shadowProps", "dir", 1)
                fxSlider("Distance", sw.dist, 0 ... 200, " pt", "shadowProps", "dist", 1)
            }
        }
        Section("Reflection") {
            Picker("Reflection", selection: Binding(get: { "" }, set: { ctl.run("shape.effects", ["reflection": .string($0)]) })) {
                Text("Choose…").tag("")
                ForEach([("None", "none"), ("Tight", "tight"), ("Half", "half"), ("Full", "full")], id: \.1) { Text($0.0).tag($0.1) }
            }
            if let r = fx.reflection {
                fxSlider("Transparency", (1 - r.startAlpha) * 100, 0 ... 100, "%", "reflectionProps", "transparency", 0.01)
                fxSlider("Size", r.endPos * 100, 0 ... 100, "%", "reflectionProps", "size", 0.01)
                fxSlider("Distance", r.dist, 0 ... 100, " pt", "reflectionProps", "dist", 1)
                fxSlider("Blur", r.blur, 0 ... 100, " pt", "reflectionProps", "blur", 1)
            }
        }
        Section("Glow") {
            fxSlider("Size", fx.glow?.radius ?? 0, 0 ... 150, " pt", "glowProps", "radius", 1)
            if let g = fx.glow {
                ColorButton(label: "Color", color: g.color.resolve(scheme, nil), scheme: scheme) { c in
                    ctl.run("shape.effects", ["glowProps": ["color": c.map(InspectorColors.param) ?? .null]])
                }
                fxSlider("Transparency", (1 - g.color.alpha) * 100, 0 ... 100, "%", "glowProps", "transparency", 0.01)
            }
        }
        Section("Soft Edges") {
            CommitSlider(label: "Size", value: fx.softEdge ?? 0, range: 0 ... 50, suffix: " pt") { ctl.run("shape.effects", ["softEdges": .num($0)]) }
        }
        ThreeDSection(ctl: ctl, raw: fx.raw3d)
        Section {
            Button("Reset Effects") { ctl.run("shape.effects", ["reset": true]) }
        }
    }

    static let shadows: [(String, String)] = [("None", "none"), ("Outer", "outer"), ("Bottom", "bottom"), ("Center", "center"), ("Inner", "inner"), ("Perspective", "perspective")]

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
        Section("3-D Format") {
            bevel("Top bevel", "bevelTop", s3.top)
            bevel("Bottom bevel", "bevelBottom", s3.bottom)
            drag("Depth", s3.depth, " pt", "depth")
            drag("Contour", s3.contour, " pt", "contour")
            combo("Material", "material", s3.material, ThreeDCommands.materials)
            combo("Lighting", "lighting", s3.light, ThreeDCommands.lights)
        }
        Section("3-D Rotation") {
            combo("Presets", "camera", s3.camera, ThreeDCommands.cameras)
            drag("X Rotation", s3.rot?.x ?? 0, "°", "rotX")
            drag("Y Rotation", s3.rot?.y ?? 0, "°", "rotY")
            drag("Z Rotation", s3.rot?.z ?? 0, "°", "rotZ")
            drag("Distance from ground", s3.z, " pt", "z")
            Button("Reset 3-D") { set("reset", true) }.disabled(raw == nil)
        }
    }

    @ViewBuilder private func bevel(_ label: String, _ key: String, _ b: ThreeDCommands.Bevel?) -> some View {
        combo(label, key, b?.preset ?? "none", ["none"] + ThreeDCommands.bevels)
        if let b {
            drag("Width", b.w, " pt", "\(key)W")
            drag("Height", b.h, " pt", "\(key)H")
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
        Section("Size") {
            NumberField(label: "Height", value: x.h / ppu, step: 0.1, suffix: unit.suffix) { resize("h", $0 * ppu) }
            NumberField(label: "Width", value: x.w / ppu, step: 0.1, suffix: unit.suffix) { resize("w", $0 * ppu) }
            NumberField(label: "Rotation", value: x.rot, step: 1, suffix: "°") { ctl.run("shape.rotate", ["deg": .num($0)]) }
            Toggle("Lock aspect ratio", isOn: $lockAspect)
            Button("Size and Position…") { ctl.run("shape.sizePosition") }
        }
        Section("Position") {
            NumberField(label: "Horizontal", value: x.x / ppu, step: 0.1, suffix: unit.suffix) { ctl.run("shape.move", ["x": .num($0 * ppu)]) }
            NumberField(label: "Vertical", value: x.y / ppu, step: 0.1, suffix: unit.suffix) { ctl.run("shape.move", ["y": .num($0 * ppu)]) }
        }
        Section("Alt Text") {
            AltTextField(text: sh.descr) { ctl.run("shape.altText", ["text": .string($0)]) }
            Button("Alt Text…") { ctl.run("app.dialog", ["id": "altText"]) }
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
        TextField("Alt text", text: Binding(get: { InspectorText.draft(draft, text) }, set: { draft = (text, $0) }), axis: .vertical)
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
        Section("Corrections") {
            CommitSlider(label: "Brightness", value: adj?.brightness ?? 0, range: -1 ... 1, decimals: 2) { ctl.run("picture.adjust", ["brightness": .num($0)]) }
            CommitSlider(label: "Contrast", value: adj?.contrast ?? 0, range: -1 ... 1, decimals: 2) { ctl.run("picture.adjust", ["contrast": .num($0)]) }
            CommitSlider(label: "Saturation", value: adj?.saturation ?? 1, range: 0 ... 4, decimals: 2) { ctl.run("picture.adjust", ["saturation": .num($0)]) }
            CommitSlider(label: "Transparency", value: 1 - (pf?.alpha ?? 1), range: 0 ... 1, decimals: 2) { ctl.run("picture.adjust", ["transparency": .num($0)]) }
            Button("Reset Picture") { ctl.run("picture.reset") }
        }
        Section("Adjust") {
            Menu("Remove Background") {
                ForEach([("Remove Background", 20.0), ("Remove More (looser)", 35.0), ("Remove Less (tighter)", 10.0)], id: \.1) { l, tol in
                    Button(l) { ctl.run("picture.removeBackground", ["tolerance": .num(tol)]) }
                }
            }
            .disabled(!ctl.enabled("picture.removeBackground"))
            Menu("Recolor") {
                ForEach(RecolorCommands.presets(), id: \.0) { id, label in Button(label) { ctl.run("picture.recolor", ["preset": .string(id)]) } }
            }
            Menu("Artistic Effects") {
                Button("None") { ctl.run("picture.artisticEffect", ["effect": "none"]) }
                ForEach(ArtisticCommands.effects, id: \.0) { e, l in Button(l) { ctl.run("picture.artisticEffect", ["effect": .string(e)]) } }
            }
            .disabled(!ctl.enabled("picture.artisticEffect"))
            Button("Set Transparent Color") {
                // As in PowerPoint, a click on the picture itself picks the colour (the canvas's eyedropper);
                // without a canvas, the system's colour sampler.
                if CanvasFeature.setTransparentColor() { return }
                NSColorSampler().show { c in
                    if let rgba = c.flatMap(ColorGrid.rgba) { MainActor.assumeIsolated { _ = ctl.run("picture.transparentColor", ["color": .string("#\(rgba.hex)")]) } }
                }
            }
            .help("Pick the colour in the picture that becomes transparent")
            Button("Change Picture…") { ctl.run("app.changePictureDialog") }
        }
        Section("Picture Styles") {
            Picker("Style", selection: Binding(get: { "" }, set: { ctl.run("picture.style", ["style": .string($0)]) })) {
                Text("Choose…").tag("")
                ForEach(PictureStyleCommands.styles, id: \.0) { Text($0.1).tag($0.0) }
                Divider()
                Text("Reset Style").tag("none")
            }
            ColorButton(label: "Picture Border", color: borderColor, scheme: InspectorColors.scheme(ctl.session), noneLabel: "No Outline") { c in
                if let c { ctl.run("shape.line", ["color": InspectorColors.param(c)]) } else { ctl.run("shape.line", ["none": true]) }
            }
        }
        Section("Crop") {
            ShapesMenu(includeFreeform: false, pick: { ctl.run("shape.change", ["preset": .string($0)]) }) { Text("Crop to Shape") }
            ForEach([("Crop 10% each side", 0.1), ("Crop 20% each side", 0.2), ("Reset Crop", 0.0)], id: \.0) { l, v in
                Button(l) { ctl.run("picture.crop", ["left": .num(v), "top": .num(v), "right": .num(v), "bottom": .num(v)]) }
            }
        }
        Section("Compress Pictures") {
            Toggle("Apply only to this picture", isOn: $compress.onlySelected)
            Toggle("Delete cropped areas of pictures", isOn: $compress.deleteCropped)
            Picker("Resolution", selection: $compress.ppi) {
                Text("HD (330 ppi)").tag(330)
                Text("Print (220 ppi)").tag(220)
                Text("Web (150 ppi)").tag(150)
                Text("E-mail (96 ppi)").tag(96)
            }
            Button("Compress") { compressNow() }.disabled(!ctl.enabled("picture.compress"))
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
            ctl.model.status = n == 0 ? "Pictures are already at or below that resolution"
                : "Compressed \(n) picture(s): \(kb(r["before"])) KB → \(kb(r["after"])) KB"
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
                    ForEach(Array(InspectorShape.quickStyleSlots.enumerated()), id: \.offset) { col, slot in
                        let index = InspectorShape.quickStyleIndex(row: row, column: col)
                        Button { pick(index) } label: { tile(row, scheme.get(slot)) }
                            .buttonStyle(.plain)
                            .help("Style \(index + 1)")
                            .accessibilityLabel("Quick Style \(index + 1)")
                    }
                }
            }
        }
    }

    /// The tile as deckcraft paints it: outlined on the light colour, a light tint, a darker fill, or solid.
    private func tile(_ row: Int, _ c: Rgba) -> some View {
        let light = scheme.get(.lt1).swiftUI, dark = scheme.get(.dk1).swiftUI, accent = c.swiftUI
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.control / 2)
        let (fill, stroke, text): (Color, Color, Color) = switch row {
        case 0: (light, accent, dark)
        case 2: (accent.opacity(0.25), .clear, accent)
        case 5: (accent.mix(with: dark, by: 0.25), light, light)
        default: (accent, accent.mix(with: dark, by: 0.3), light)
        }
        return shape.fill(fill)
            .overlay(shape.strokeBorder(stroke, lineWidth: Tokens.Layout.hairline * 1.5))
            .overlay(Text("Abc").font(Tokens.Font.caption).foregroundStyle(text))
            .frame(height: Tokens.Space.xl)
    }
}
