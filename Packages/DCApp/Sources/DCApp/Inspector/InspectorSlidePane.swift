// DCApp — Slide: deckcraft's Design ribbon tab (`design`: themes, variants, colours, fonts, effects,
// background styles, slide size), the Format Background task pane (`background`, `picture_background_options`
// in `panes.rs`), Design Ideas (`designer`), Home ▸ Slides' Layout and Reset, Slide Show ▸ Hide Slide, and the
// Slide, Notes and Handout Master tabs (`slide_master`, `notes_master`, `handout_master`) from
// `crates/ui-egui/src/ribbon.rs`. MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors.
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

struct SlideDesignView: View {
    let ctl: InspectorController

    var body: some View {
        MasterViewSections(ctl: ctl)
        SlideLayoutSection(ctl: ctl)
        SlideShowSection(ctl: ctl)
        ThemesSection(ctl: ctl)
        BackgroundSection(ctl: ctl)
        DesignIdeasSection(ctl: ctl)
        InsertZoomSection(ctl: ctl)
    }
}

/// Slide Show ▸ Set Up and Monitors: presenter view, timings, narrations, media controls, the dialogs.
struct SlideShowSection: View {
    let ctl: InspectorController

    var body: some View {
        let show = ctl.doc?.doc.show
        Section("Slide Show") {
            Toggle("Presenter View", isOn: Binding(get: { ctl.model.ui.presenterView }, set: { ctl.run("show.presenter", ["on": .bool($0)]) }))
            Toggle("Use Timings", isOn: Binding(get: { show?.useTimings ?? true }, set: { ctl.run("show.setup", ["useTimings": .bool($0)]) }))
            Toggle("Play Narrations", isOn: Binding(get: { !(show?.withoutNarration ?? false) }, set: { ctl.run("show.setup", ["noNarration": .bool(!$0)]) }))
            Toggle("Show Media Controls", isOn: Binding(get: { show?.showMediaControls ?? true }, set: { ctl.run("show.setup", ["showMediaControls": .bool($0)]) }))
            Button("Set Up Slide Show…") { ctl.run("app.dialog", ["id": "setupShow"]) }
            Button("Custom Shows…") { ctl.run("app.dialog", ["id": "customShow"]) }
        }
    }
}

/// Insert ▸ Zoom (`zoom_menu`): Slide, Section or Summary Zoom of the checked slides or sections.
struct InsertZoomSection: View {
    let ctl: InspectorController
    @State private var kind = "slide"
    @State private var picked: Set<Int> = []

    var body: some View {
        Section("Insert Zoom") {
            Picker("Zoom", selection: Binding(get: { kind }, set: { kind = $0; picked = [] })) {
                ForEach(InspectorShape.zoomKinds, id: \.1) { Text($0.0).tag($0.1) }
            }
            if let doc = ctl.doc?.doc {
                let items = InspectorShape.zoomItems(doc, kind)
                if items.isEmpty {
                    InspectorNote(text: kind == "section" ? "The presentation has no sections. Add one with New Slide ▸ Add Section." : "No slides.")
                }
                ForEach(Array(items.enumerated()), id: \.offset) { i, label in
                    Toggle(label, isOn: Binding(get: { picked.contains(i) }, set: { if $0 { picked.insert(i) } else { picked.remove(i) } }))
                }
            }
            Button("Insert") {
                if let p = InspectorShape.zoomParams(kind, picked) {
                    ctl.run("insert.zoom", p)
                    picked = []
                }
            }
            .disabled(picked.isEmpty || !ctl.enabled("insert.zoom"))
        }
    }
}

struct SlideLayoutSection: View {
    let ctl: InspectorController

    var body: some View {
        let st = ctl.doc
        let layouts = st?.doc.masters.first?.layouts ?? []
        let current = st?.currentSlide?.layout
        Section("Slide") {
            Picker("Layout", selection: Binding(get: { current?.rawValue ?? 0 }, set: { ctl.run("slide.layout", ["layout": .integer($0)]) })) {
                if !layouts.contains(where: { $0.id == current }) { Text("—").tag(current?.rawValue ?? 0) }
                ForEach(layouts, id: \.id) { Text($0.name).tag($0.id.rawValue) }
            }
            .disabled(!ctl.enabled("slide.layout"))
            HStack {
                Button("Reset Slide") { ctl.run("slide.reset") }.disabled(!ctl.enabled("slide.reset"))
                Toggle("Hide Slide", isOn: Binding(get: { st?.currentSlide?.hidden ?? false }, set: { _ in ctl.run("slide.hide") }))
            }
            Menu("Slide Size") {
                Button("Standard (4:3)") { ctl.run("design.slideSize", ["preset": "standard"]) }
                Button("Widescreen (16:9)") { ctl.run("design.slideSize", ["preset": "widescreen"]) }
                Button("Page Setup…") { ctl.run("app.dialog", ["id": "slideSize"]) }
            }
        }
    }
}

struct ThemesSection: View {
    let ctl: InspectorController

    var body: some View {
        let themes = builtinThemes()
        let theme = ctl.doc?.doc.masters.first?.theme
        Section("Themes") {
            TileGallery(count: themes.count, columns: 3, selected: themes.firstIndex { $0.name == theme?.name }, tip: { themes.at($0)?.name ?? "" },
                        tile: { ThemeTile(colors: themes.at($0)?.colors ?? Theme.default.colors) },
                        pick: { if let t = themes.at($0) { ctl.run("design.theme", ["name": .string(t.name)]) } })
            Button("Browse for Themes…") { ctl.run("app.browseThemeDialog") }
        }
        if let theme {
            let variants = themeVariants(theme)
            Section("Variants") {
                TileGallery(count: variants.count, columns: 4, selected: variants.firstIndex { $0.colors == theme.colors.colors }, tip: { variants.at($0)?.name ?? "" },
                            tile: { ThemeTile(colors: variants.at($0) ?? theme.colors) },
                            pick: { ctl.run("design.variant", ["index": .integer($0)]) })
                Picker("Colors", selection: Binding(get: { theme.colors.name }, set: { name in
                    if name == "\u{0}customize" { ctl.run("design.colors") } else { ctl.run("design.colors", ["name": .string(name)]) }
                })) {
                    if !builtinColorSchemes().contains(where: { $0.name == theme.colors.name }) { Text(theme.colors.name).tag(theme.colors.name) }
                    ForEach(builtinColorSchemes(), id: \.name) { cs in
                        Label { Text(cs.name) } icon: { Image(nsImage: Self.schemeImage(cs)) }.tag(cs.name)
                    }
                    Divider()
                    Text("Customize Colors…").tag("\u{0}customize")
                }
                Picker("Fonts", selection: Binding(get: { theme.fonts.name }, set: { name in
                    if name == "\u{0}customize" { ctl.run("design.fonts") } else { ctl.run("design.fonts", ["name": .string(name)]) }
                })) {
                    if !builtinFontSchemes().contains(where: { $0.name == theme.fonts.name }) { Text(theme.fonts.name).tag(theme.fonts.name) }
                    ForEach(builtinFontSchemes(), id: \.name) { fs in Text("\(fs.name) — \(fs.major.latin) / \(fs.minor.latin)").tag(fs.name) }
                    Divider()
                    Text("Customize Fonts…").tag("\u{0}customize")
                }
                Picker("Effects", selection: Binding(get: { theme.format.name }, set: { ctl.run("design.effects", ["name": .string($0)]) })) {
                    if !builtinFormatSchemes().contains(where: { $0.name == theme.format.name }) { Text(theme.format.name).tag(theme.format.name) }
                    ForEach(builtinFormatSchemes(), id: \.name) { Text($0.name).tag($0.name) }
                }
                Menu("Background Styles") {
                    ForEach(1 ... 12, id: \.self) { i in Button("Style \(i)") { ctl.run("design.background", ["style": .integer(i), "all": true]) } }
                    Divider()
                    Button("Reset Slide Background") { ctl.run("design.background", ["reset": true]) }
                }
            }
        }
    }

    /// A colour scheme's swatch strip for the Colors menu (the eight colours after the two text colours).
    static func schemeImage(_ cs: DCColor.ColorScheme) -> NSImage {
        let cell = Tokens.Space.m
        let img = NSImage(size: NSSize(width: cell * 8, height: cell), flipped: false) { _ in
            for (k, c) in cs.colors.dropFirst(2).prefix(8).enumerated() {
                NSColor(srgbRed: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, alpha: 1).setFill()
                NSRect(x: Double(k) * cell, y: 0, width: cell - Tokens.Layout.hairline, height: cell).fill()
            }
            return true
        }
        return img
    }
}

/// Format Background (`background`): the fill kind, its options, Hide background graphics, Apply to All,
/// Reset Background.
struct BackgroundSection: View {
    let ctl: InspectorController

    var body: some View {
        let scheme = InspectorColors.scheme(ctl.session)
        let bg = ctl.doc?.currentSlide?.background
        let fill = InspectorFill.backgroundFill(bg)
        Section("Format Background") {
            Picker("Fill", selection: Binding(get: { InspectorFill.backgroundKind(bg) }, set: { k in
                guard k != InspectorFill.backgroundKind(bg) else { return }
                if k == "picture" {
                    if let p = pickPictureBase64() { ctl.run("design.background", ["picture": .string(p.data), "name": .string(p.name)]) }
                } else if let p = InspectorFill.backgroundKindParams(k) {
                    ctl.run("design.background", p)
                }
            })) {
                ForEach(InspectorFill.backgroundKinds, id: \.kind) { Text($0.label).tag($0.kind) }
            }
            .pickerStyle(.radioGroup)
            switch fill {
            case .solid(let color)?:
                ColorButton(label: "Color", color: color.resolve(scheme, nil), scheme: scheme) { c in
                    if let c { ctl.run("design.background", ["color": InspectorColors.param(c)]) }
                }
                CommitSlider(label: "Transparency", value: (1 - color.alpha) * 100, range: 0 ... 100, suffix: "%") {
                    ctl.run("design.background", ["transparency": .num(Swift.min(Swift.max($0 / 100, 0), 1))])
                }
            case .gradient(let g)?:
                GradientEditor(gradient: g, scheme: scheme) { ctl.run("design.background", ["gradient": InspectorFill.gradientJSON($0)]) }
            case .pattern(let pt)?:
                PatternEditor(pattern: pt, scheme: scheme) { ctl.run("design.background", ["pattern": InspectorFill.patternJSON($0)]) }
            case .picture(let pf)?:
                CommitSlider(label: "Transparency", value: (1 - (pf.alpha ?? 1)) * 100, range: 0 ... 100, suffix: "%") {
                    ctl.run("design.background", ["transparency": .num(Swift.min(Swift.max($0 / 100, 0), 1))])
                }
                PictureFillOptions(fill: pf) { ctl.run("design.background", ["pictureProps": $0]) } replace: {
                    if let p = pickPictureBase64() { ctl.run("design.background", ["picture": .string(p.data), "name": .string(p.name)]) }
                }
            default:
                EmptyView()
            }
            Toggle("Hide background graphics", isOn: Binding(get: { !(ctl.doc?.currentSlide?.showMasterShapes ?? true) }, set: {
                ctl.run("design.hideBackgroundGraphics", ["hide": .bool($0)])
            }))
            HStack {
                Button("Apply to All") { if let p = InspectorFill.applyToAllParams(bg) { ctl.run("design.background", p) } }
                    .disabled(InspectorFill.applyToAllParams(bg) == nil)
                Button("Reset Background") { ctl.run("design.background", ["reset": true]) }
            }
        }
    }
}

/// Design Ideas (`designer`): the current slide in each idea and each theme, drawn once per document
/// revision; a click runs `design.applyIdea` or `design.theme`.
struct DesignIdeasSection: View {
    let ctl: InspectorController
    @State private var expanded = false
    @State private var cache: (key: String, images: [String: NSImage])?

    var body: some View {
        Section("Design Ideas") {
            DisclosureGroup("Ideas for this slide", isExpanded: Binding(get: { expanded || ctl.model.ui.pane == "designer" }, set: { expanded = $0 })) {
                if let st = ctl.doc {
                    let idx = st.selection.slide
                    let ideas = IdeasCommands.ideasFor(st.doc, idx)
                    let images = thumbnails(st, idx, ideas)
                    InspectorNote(text: "Pick a design for this slide. Ideas are generated on your device.")
                    if ideas.isEmpty { InspectorNote(text: "Add a title with a picture or some text to get layout ideas.") }
                    ForEach(ideas, id: \.id) { idea in
                        thumb(images["layout:\(idea.id)"], idea.label) { ctl.run("design.applyIdea", ["id": .string(idea.id)]) }
                    }
                    InspectorNote(text: "Themes (whole presentation)")
                    ForEach(builtinThemes(), id: \.name) { th in
                        thumb(images["theme:\(th.name)"], th.name) { ctl.run("design.theme", ["name": .string(th.name)]) }
                    }
                }
            }
        }
    }

    private func thumb(_ image: NSImage?, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) } else { Rectangle().fill(Tokens.Color.fieldFill).aspectRatio(16 / 9, contentMode: .fit) }
            }
            .overlay(Rectangle().strokeBorder(Tokens.Color.separator, lineWidth: Tokens.Layout.hairline))
        }
        .buttonStyle(.plain)
        .help(tip)
        .accessibilityLabel(tip)
    }

    /// The ideas' and themes' pictures, kept until the deck or slide changes (`IdeaThumbs`).
    private func thumbnails(_ st: DocState, _ idx: Int, _ ideas: [IdeasCommands.Idea]) -> [String: NSImage] {
        let key = "\(st.uid):\(st.revision):\(idx)"
        if let c = cache, c.key == key { return c.images }
        var out: [String: NSImage] = [:]
        let width = Tokens.Layout.inspectorWidth * 2
        func render(_ name: String, _ d: Presentation) {
            let scale = width / Swift.max(d.slideSize.width, 1)
            if let cg = renderSlide(d, idx, RenderOpts(scale: scale)).cgImage() { out[name] = NSImage(cgImage: cg, size: .zero) }
        }
        for idea in ideas {
            var d = st.doc
            if (try? IdeasCommands.applyIdea(&d, st.selection, idx, idea.id)) != nil { render("layout:\(idea.id)", d) }
        }
        for th in builtinThemes() {
            var d = st.doc
            if !d.masters.isEmpty { d.masters[0].theme = th }
            render("theme:\(th.name)", d)
        }
        DispatchQueue.main.async { cache = (key, out) }
        return out
    }
}

/// The Slide, Notes and Handout Master tabs, shown while one is open.
struct MasterViewSections: View {
    let ctl: InspectorController

    var body: some View {
        let ctx = ctl.contextual()
        if ctx.contains("Slide Master") {
            let (preserve, title, footers) = masterChecks
            Section("Slide Master") {
                HStack {
                    Button("Insert Layout") { ctl.run("master.insertLayout") }
                    Button("Delete") { ctl.run("master.deleteLayout") }.disabled(!ctl.enabled("master.deleteLayout"))
                    Button("Rename…") { ctl.run("app.dialog", ["id": "renameLayout"]) }
                }
                Toggle("Preserve", isOn: Binding(get: { preserve }, set: { ctl.run("master.preserve", ["preserve": .bool($0)]) }))
                Toggle("Title", isOn: Binding(get: { title }, set: { ctl.run("master.placeholders", ["title": .bool($0)]) }))
                Toggle("Footers", isOn: Binding(get: { footers }, set: { ctl.run("master.placeholders", ["footers": .bool($0)]) }))
                Menu("Insert Placeholder") {
                    ForEach([("Content", "content"), ("Text", "text"), ("Picture", "picture"), ("Chart", "chart"), ("Table", "table"), ("Media", "media")], id: \.1) { l, k in
                        Button(l) { ctl.run("master.insertPlaceholder", ["kind": .string(k)]) }
                    }
                }
                Button("Close Master View") { ctl.run("view.closeMaster") }
            }
        } else if ctx.contains("Notes Master") {
            Section("Notes Master") {
                ForEach([("Header", "header", PhType.header), ("Slide Image", "slideImage", .slideImage), ("Footer", "footer", .footer),
                         ("Date", "date", .date), ("Body", "body", .body), ("Page Number", "pageNumber", .slideNum)], id: \.1) { l, key, k in
                    Toggle(l, isOn: Binding(get: { shown(ctl.doc?.doc.notesMaster, k) }, set: { v in
                        var p: JSON = .emptyObject
                        p.set(key, .bool(v))
                        ctl.run("notes.placeholders", p)
                    }))
                }
                Button("Close Master View") { ctl.run("view.closeMaster") }
            }
        } else if ctx.contains("Handout Master") {
            Section("Handout Master") {
                Picker("Slides Per Page", selection: Binding(get: { ctl.model.ui.handoutPerPage }, set: { ctl.model.ui.handoutPerPage = $0 })) {
                    ForEach([1, 2, 3, 4, 6, 9], id: \.self) { n in Text("\(n) Slide\(n == 1 ? "" : "s")").tag(n) }
                }
                ForEach([("Header", "header", PhType.header), ("Date", "date", .date), ("Footer", "footer", .footer), ("Page Number", "pageNumber", .slideNum)], id: \.1) { l, key, k in
                    Toggle(l, isOn: Binding(get: { shown(ctl.doc?.doc.handoutMaster, k) }, set: { v in
                        var p: JSON = .emptyObject
                        p.set(key, .bool(v))
                        ctl.run("handout.placeholders", p)
                    }))
                }
                Button("Close Master View") { ctl.run("view.closeMaster") }
            }
        } else {
            Section("Master Views") {
                Menu("Edit Master") {
                    Button("Slide Master") { ctl.run("view.slideMaster") }
                    Button("Handout Master") { ctl.run("view.handoutMaster") }
                    Button("Notes Master") { ctl.run("view.notesMaster") }
                }
            }
        }
    }

    private func shown(_ m: Master?, _ k: PhType) -> Bool { m?.shapes.contains { $0.phType == k } ?? false }

    /// `master_checks`: Preserve, and whether the open master or layout has a title or a footer placeholder.
    private var masterChecks: (Bool, Bool, Bool) {
        guard let st = ctl.doc else { return (false, false, false) }
        let preserve: Bool
        switch st.selection.target {
        case .master(let m): preserve = st.doc.masters.at(m)?.preserve ?? false
        case .layout(let m, let l): preserve = st.doc.masters.at(m)?.layouts.at(l)?.preserve ?? false
        default: preserve = false
        }
        return (preserve, st.shapes.contains { $0.phType?.isTitle ?? false }, st.shapes.contains { $0.phType?.isFooterKind ?? false })
    }
}
