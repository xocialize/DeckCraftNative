// DCApp — Animate: deckcraft's Animations ribbon tab (`animations`: preview, the effect gallery, Effect
// Options, Add Animation, Trigger, Animation Painter, timing), the Animation Pane with its advanced timeline
// (`animation` in `panes.rs`, `animtimeline.rs`), and the Transitions tab (`transitions`: the gallery by
// category, Effect Options, sound, duration, advance, Apply To All) from `crates/ui-egui/src/ribbon.rs`.
// MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DesignScaffold
import SwiftUI
import UniformTypeIdentifiers

struct AnimateView: View {
    let ctl: InspectorController
    @State private var part: String?

    var body: some View {
        let hasSel = !(ctl.doc?.selection.shapes.isEmpty ?? true)
        let shown = part ?? (hasSel ? "animations" : "transition")
        Section {
            Picker("Show", selection: Binding(get: { shown }, set: { part = $0 })) {
                Text("Animations").tag("animations")
                Text("Transition").tag("transition")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        if shown == "transition" {
            TransitionView(ctl: ctl)
        } else {
            AnimationsView(ctl: ctl)
            Section("Animation Pane") { AnimationPaneView(ctl: ctl) }
        }
    }
}

struct AnimationsView: View {
    let ctl: InspectorController

    var body: some View {
        let hasSel = !(ctl.doc?.selection.shapes.isEmpty ?? true)
        let cur = ctl.currentAnimation
        Section("Animation") {
            Button { ctl.run("animation.preview") } label: { Label("Preview", systemImage: "play") }
                .help("Play this slide's animations on the canvas")
            Picker("Effect", selection: Binding(get: { cur.map { "\($0.class.rawValue):\($0.effect)" } ?? "" }, set: { set($0, "animation.set") })) {
                if cur == nil { Text("None").tag("") }
                ForEach([AnimClass.entrance, .emphasis, .exit, .path], id: \.self) { cls in
                    Section(InspectorMotion.className(cls)) {
                        ForEach(animations.filter { $0.animClass == cls }, id: \.id) { a in Text(a.label).tag("\(cls.rawValue):\(a.id)") }
                    }
                }
                if let c = cur, animationInfo(c.effect, c.class) == nil { Text(c.effect).tag("\(c.class.rawValue):\(c.effect)") }
            }
            .disabled(!hasSel)
            Menu("Add Animation") {
                ForEach([AnimClass.entrance, .emphasis, .exit, .path], id: \.self) { cls in
                    Section(InspectorMotion.className(cls)) {
                        ForEach(animations.filter { $0.animClass == cls }, id: \.id) { a in
                            Button(a.label) { ctl.run("animation.add", ["effect": .string(a.id), "class": .string(cls.rawValue)]) }
                        }
                    }
                }
            }
            .disabled(!hasSel)
            if let c = cur {
                let rows = InspectorMotion.animationEffectRows(c.effect, c.class, c.option)
                if !rows.isEmpty {
                    Picker("Effect Options", selection: Binding(get: { c.option }, set: { ctl.run("animation.options", ["option": .string($0)]) })) {
                        if !rows.contains(where: \.1) { Text("—").tag(c.option) }
                        ForEach(rows, id: \.0) { Text(InspectorMotion.optionLabel($0.0)).tag($0.0) }
                    }
                }
                Picker("Sequence", selection: Binding(get: { InspectorMotion.textBuildId(c.textBuild) }, set: { ctl.run("animation.options", ["textBuild": .string($0)]) })) {
                    Text("As One Object").tag("asOne")
                    Text("By Paragraph").tag("byParagraph")
                    if ![.asOne, .byParagraph].contains(c.textBuild) { Text(InspectorMotion.optionLabel(c.textBuild.rawValue)).tag(c.textBuild.rawValue) }
                }
            }
        }
        Section("Timing") {
            Picker("Start", selection: Binding(get: { cur?.start.rawValue ?? "" }, set: { ctl.run("animation.timing", ["start": .string($0)]) })) {
                if cur == nil { Text("—").tag("") }
                ForEach(InspectorMotion.starts, id: \.1) { Text($0.0).tag($0.1) }
            }
            .disabled(cur == nil)
            NumberField(label: "Duration", value: Double(cur?.durationMs ?? 500) / 1000, step: 0.25, suffix: " s", range: 0 ... 600) {
                ctl.run("animation.timing", ["duration": InspectorMotion.ms($0)])
            }
            .disabled(cur == nil)
            NumberField(label: "Delay", value: Double(cur?.delayMs ?? 0) / 1000, step: 0.25, suffix: " s", range: 0 ... 600) {
                ctl.run("animation.timing", ["delay": InspectorMotion.ms($0)])
            }
            .disabled(cur == nil)
            Picker("Trigger", selection: Binding(get: { cur?.trigger.map { Int($0.rawValue) } ?? -1 }, set: { v in
                ctl.run("animation.timing", ["trigger": v < 0 ? .null : .integer(v)])
            })) {
                Text("On Click Sequence").tag(-1)
                ForEach(ctl.doc?.shapes ?? [], id: \.id) { s in Text("On Click of \(s.name)").tag(Int(s.id.rawValue)) }
            }
            .disabled(cur == nil)
            Toggle(isOn: Binding(get: { ctl.session.animPainter != nil }, set: { on in
                if on { ctl.run("animation.painter") } else { ctl.session.animPainter = nil; ctl.model.changed() }
            })) { Label("Animation Painter", systemImage: "paintbrush") }
                .toggleStyle(.button)
                .disabled(!ctl.enabled("animation.painter") && ctl.session.animPainter == nil)
                .help("Animation Painter: copy this animation to the next object you click")
        }
    }

    /// A gallery pick: `class:effect` → `animation.set`.
    private func set(_ tag: String, _ cmd: String) {
        let parts = tag.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        ctl.run(cmd, ["effect": .string(parts[1]), "class": .string(parts[0])])
    }
}

/// The Animation Pane: Play From / Play All, one row per effect with its click number, class, shape and timing
/// bar (drag the bar for the delay, its right edge for the duration), a context menu, and the seconds ruler.
struct AnimationPaneView: View {
    let ctl: InspectorController
    @State private var drag: (index: Int, edge: Bool, dx: Double)?

    var body: some View {
        let pane = ctl.animationPane()
        let selected = ctl.doc?.selection.shapes ?? []
        let from = pane.playFrom(pick: ctl.currentAnimPick, selected: selected)
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack {
                let play = AnimPane.playButton(playing: false, from: from)
                Button { ctl.run("animation.preview", play.params) } label: { Label(play.label, systemImage: "play.fill") }
                Button { ctl.run("animation.preview", ["on": false]) } label: { Label("Stop", systemImage: "stop.fill") }
            }
            if pane.rows.isEmpty {
                InspectorNote(text: "Select an object on the slide and add an animation to it.")
            } else {
                GeometryReader { geo in
                    let track = Swift.max(geo.size.width * 0.45, Tokens.Space.xxl * 2)
                    let pps = AnimTimeline.pixelsPerSecond(track, pane.seconds)
                    VStack(spacing: 0) {
                        ForEach(pane.rows, id: \.index) { row in
                            rowView(row, selected.contains(row.shape), from == row.index, track: track, pps: pps, x0: geo.size.width - track)
                        }
                        ruler(pane.seconds, track: track, pps: pps, x0: geo.size.width - track)
                    }
                }
                .frame(height: Double(pane.rows.count) * Tokens.Layout.controlHeight * 1.25 + Tokens.Space.l)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: AnimPaneRow, _ sel: Bool, _ isFrom: Bool, track: Double, pps: Double, x0: Double) -> some View {
        HStack(spacing: Tokens.Space.xs) {
            Text(row.click).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                .frame(width: Tokens.Space.l, alignment: .trailing)
            Image(systemName: Self.symbol(row.animClass)).foregroundStyle(Self.color(row.animClass))
            Text(row.name).lineLimit(1)
            Spacer(minLength: track)
        }
        .frame(height: Tokens.Layout.controlHeight * 1.25)
        .padding(.horizontal, Tokens.Space.xs)
        .background(sel ? Tokens.Color.selectionWash : Color.clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.control / 2))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control / 2).strokeBorder(isFrom ? Tokens.Color.accent : Color.clear, lineWidth: Tokens.Layout.hairline))
        .overlay(alignment: .leading) { if let b = row.bar { bar(row, b, pps: pps, x0: x0, track: track) } }
        .contentShape(Rectangle())
        .onTapGesture { ctl.clickAnimation(row) }
        .contextMenu {
            ForEach(InspectorMotion.starts, id: \.1) { l, v in
                Button("Start \(l)") { ctl.run("animation.timing", ["index": .integer(row.index), "start": .string(v)]) }
            }
            Divider()
            Button("Move Up") { ctl.animationEdit("animation.move", ["index": .integer(row.index), "to": .integer(Swift.max(row.index - 1, 0))]) }
            Button("Move Down") { ctl.animationEdit("animation.move", ["index": .integer(row.index), "to": .integer(row.index + 1)]) }
            Button("Remove") { ctl.animationEdit("animation.remove", ["index": .integer(row.index)]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.click) \(row.name)")
    }

    @ViewBuilder
    private func bar(_ row: AnimPaneRow, _ b: AnimTimeline.Bar, pps: Double, x0: Double, track: Double) -> some View {
        let xOf = { (sec: Double) in x0 + Swift.min(sec * pps, track) }
        let iter = Double(row.durationMs) / 1000
        let factor = iter > 0 && b.span > 0 ? b.span / iter : 1
        let d = drag?.index == row.index ? drag : nil
        let (start, end): (Double, Double) = {
            guard let d else { return (xOf(b.start), Swift.max(xOf(b.start + b.span), xOf(b.start) + Tokens.Space.xs)) }
            if d.edge {
                let ms = AnimTimeline.draggedDuration(row.durationMs, d.dx, pps, factor)
                return (xOf(b.start), Swift.max(xOf(b.start + Double(ms) / 1000 * factor), xOf(b.start) + Tokens.Space.xs))
            }
            let ms = AnimTimeline.draggedDelay(row.delayMs, d.dx, pps)
            let shift = (Double(ms) - Double(row.delayMs)) / 1000
            let w = Swift.max(xOf(b.start + b.span), xOf(b.start) + Tokens.Space.xs) - xOf(b.start)
            let s = xOf(Swift.max(b.start + shift, 0))
            return (s, s + w)
        }()
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: Tokens.Radius.control / 3).fill(Self.color(row.animClass))
                .gesture(DragGesture(minimumDistance: 1).onChanged { v in drag = (row.index, false, v.translation.width) }.onEnded { v in
                    let ms = AnimTimeline.draggedDelay(row.delayMs, v.translation.width, pps)
                    drag = nil
                    if ms != row.delayMs { ctl.run("animation.timing", ["index": .integer(row.index), "delay": .integer(ms)]) }
                })
                .help(AnimTimeline.label(b))
                .accessibilityLabel("Timing bar \(row.index + 1)")
            Rectangle().fill(Color.clear).frame(width: Tokens.Space.s).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1).onChanged { v in drag = (row.index, true, v.translation.width) }.onEnded { v in
                    let ms = AnimTimeline.draggedDuration(row.durationMs, v.translation.width, pps, factor)
                    drag = nil
                    if ms != row.durationMs { ctl.run("animation.timing", ["index": .integer(row.index), "duration": .integer(ms)]) }
                })
                .accessibilityLabel("Duration handle \(row.index + 1)")
        }
        .frame(width: Swift.max(end - start, Tokens.Space.xs), height: Tokens.Space.s)
        .offset(x: start)
        .overlay(alignment: .trailing) {
            if row.repeatForever { Image(systemName: "arrow.clockwise").font(Tokens.Font.caption).offset(x: Tokens.Space.m) }
        }
    }

    private func ruler(_ seconds: UInt32, track: Double, pps: Double, x0: Double) -> some View {
        let every = Swift.max(seconds / 6, 1)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Tokens.Color.separator).frame(width: track, height: Tokens.Layout.hairline).offset(x: x0)
            ForEach(Array(stride(from: 0, through: seconds, by: Int(every))), id: \.self) { s in
                let x = x0 + Double(s) * pps
                if x <= x0 + track + 0.5 {
                    Text("\(s)s").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).offset(x: x - Tokens.Space.xs, y: Tokens.Space.xs)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Tokens.Space.l, alignment: .topLeading)
    }

    static func symbol(_ c: AnimClass) -> String {
        switch c {
        case .entrance: "arrow.down.right.circle"
        case .emphasis: "star.circle"
        case .exit: "arrow.up.left.circle"
        default: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    /// The bar colours by class: the status hues of the design vocabulary.
    static func color(_ c: AnimClass) -> Color {
        switch c {
        case .entrance: Tokens.Color.ready
        case .emphasis: Tokens.Color.degraded
        case .exit: Tokens.Color.failure
        default: Tokens.Color.accent
        }
    }
}

struct TransitionView: View {
    let ctl: InspectorController

    var body: some View {
        let cur = ctl.doc?.currentSlide?.transition
        let kind = cur?.kind ?? "none"
        Section("Transition to This Slide") {
            Picker("Transition", selection: Binding(get: { kind }, set: { ctl.run("transition.set", ["kind": .string($0)]) })) {
                ForEach(["Subtle", "Exciting", "Dynamic Content"], id: \.self) { cat in
                    Section(cat) {
                        ForEach(transitions.filter { $0.category == cat }, id: \.id) { Text($0.label).tag($0.id) }
                    }
                }
                if !transitions.contains(where: { $0.id == kind }) { Text(kind).tag(kind) }
            }
            let rows = InspectorMotion.transitionEffectRows(kind, cur?.option)
            if !rows.isEmpty {
                Picker("Effect Options", selection: Binding(get: { cur?.option ?? "" }, set: { ctl.run("transition.options", ["option": .string($0)]) })) {
                    if !rows.contains(where: \.1) { Text("—").tag(cur?.option ?? "") }
                    ForEach(rows, id: \.0) { Text(transitionOptionLabel(kind, $0.0)).tag($0.0) }
                }
            }
            Button { ctl.run("show.start", ["from": .integer(ctl.doc?.selection.slide ?? 0), "preview": true]) } label: { Label("Preview", systemImage: "play") }
        }
        Section("Sound") {
            Picker("Sound", selection: Binding(get: { soundTag(cur) }, set: setSound)) {
                Text("[No Sound]").tag("none")
                Text("[Stop Previous Sound]").tag("stop")
                Divider()
                ForEach(Sounds.builtin, id: \.0) { Text($0.1).tag("builtin:\($0.0)") }
                if let name = mediaName(cur) { Text(name).tag("media") }
                Divider()
                Text("Other Sound…").tag("other")
            }
            Toggle("Loop Until Next Sound", isOn: Binding(get: { cur?.soundLoop ?? false }, set: { ctl.run("transition.sound", ["loop": .bool($0)]) }))
                .disabled(cur?.sound == nil)
        }
        Section("Timing") {
            NumberField(label: "Duration", value: Double(cur?.durationMs ?? 1000) / 1000, step: 0.25, suffix: " s", range: 0 ... 600) {
                ctl.run("transition.timing", ["duration": InspectorMotion.ms($0)])
            }
            Toggle("On Mouse Click", isOn: Binding(get: { cur?.advanceOnClick ?? true }, set: { ctl.run("transition.timing", ["onClick": .bool($0)]) }))
            Toggle("After", isOn: Binding(get: { cur?.advanceAfterMs != nil }, set: { on in
                ctl.run("transition.timing", ["after": on ? .integer(cur?.advanceAfterMs ?? 0) : .null])
            }))
            NumberField(label: "After (seconds)", value: Double(cur?.advanceAfterMs ?? 0) / 1000, step: 1, suffix: " s", range: 0 ... 86_400) {
                ctl.run("transition.timing", ["after": InspectorMotion.ms($0)])
            }
            Button("Apply To All") { ctl.run("transition.applyAll") }.disabled(!ctl.enabled("transition.applyAll"))
        }
    }

    private func soundTag(_ t: DCModel.Transition?) -> String {
        guard let t else { return "none" }
        if t.sound != nil { return "media" }
        return t.stopSound ? "stop" : "none"
    }

    private func mediaName(_ t: DCModel.Transition?) -> String? {
        guard let id = t?.sound, let item = ctl.doc?.doc.media(id) else { return nil }
        return item.name.hasSuffix(".wav") ? String(item.name.dropLast(4)) : item.name
    }

    private func setSound(_ tag: String) {
        let loop = ctl.doc?.currentSlide?.transition?.soundLoop ?? false
        switch tag {
        case "none": ctl.run("transition.sound", ["none": true])
        case "stop": ctl.run("transition.sound", ["stopPrevious": true])
        case "media": break
        case "other":
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.audio]
            if panel.runModal() == .OK, let url = panel.url, let bytes = try? Data(contentsOf: url) {
                ctl.run("transition.sound", ["data": .string(Cmd.base64Encode([UInt8](bytes))), "name": .string(url.lastPathComponent), "loop": .bool(loop)])
            }
        default:
            ctl.run("transition.sound", ["builtin": .string(String(tag.dropFirst("builtin:".count))), "loop": .bool(loop)])
        }
    }
}
