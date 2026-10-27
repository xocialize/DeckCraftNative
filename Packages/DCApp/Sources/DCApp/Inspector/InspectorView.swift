// DCApp — the inspector beside the canvas: the Mac's home for deckcraft's task panes and the ribbon's
// formatting groups (`crates/ui-egui/src/panes.rs`, `ribbon.rs`; MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). Keynote-like tabs — Format, Arrange, Animate, Slide, Review — follow `ui.pane`
// (`view.pane` opens the right one) and the Format tab follows `ui.formatTab` and the selection's contextual
// tabs. It redraws from the session after every command (`AppModel.revision`).
import DCAppModel
import DCEngine
import DCGeometry
import DCModel
import DesignScaffold
import SwiftUI

struct InspectorView: View {
    let document: DocumentRef

    var body: some View {
        if let ctl = InspectorFeature.controller {
            InspectorRoot(ctl: ctl)
        } else {
            InspectorNote(text: String(localized: "The inspector isn't available.", bundle: .module)).padding(Tokens.Space.l)
        }
    }
}

struct InspectorRoot: View {
    let ctl: InspectorController

    var body: some View {
        // Every command bumps the revision: reading it here redraws the inspector from the session.
        let _ = ctl.model.revision
        VStack(spacing: 0) {
            Picker(String(localized: "Inspector", bundle: .module), selection: Binding(get: { ctl.tab }, set: { ctl.show($0) })) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Image(systemName: Self.symbol(tab)).help(tab.label).accessibilityLabel(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, Tokens.Space.s)
            .accessibilityLabel(String(localized: "Inspector", bundle: .module))
            Text(ctl.tab.label).font(Tokens.Font.sectionTitle).padding(.bottom, Tokens.Space.xs)
            Separator(.horizontal)
            Form {
                switch ctl.tab {
                case .format: FormatView(ctl: ctl)
                case .arrange: ArrangeView(ctl: ctl)
                case .animate: AnimateView(ctl: ctl)
                case .slide: SlideDesignView(ctl: ctl)
                case .review: ReviewView(ctl: ctl)
                }
            }
            .formStyle(.grouped)
            .controlSize(.small)
            .disabled(ctl.doc == nil)
        }
        .frame(minWidth: Tokens.Layout.inspectorWidth * 0.75, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func symbol(_ t: InspectorTab) -> String {
        switch t {
        case .format: "paintbrush"
        case .arrange: "square.3.layers.3d"
        case .animate: "sparkles"
        case .slide: "rectangle.on.rectangle"
        case .review: "text.bubble"
        }
    }
}

/// Format: deckcraft's Format Shape tabs, plus the contextual Picture, Table, Chart, SmartArt and Playback.
struct FormatView: View {
    let ctl: InspectorController

    var body: some View {
        let st = ctl.doc
        let sh = ctl.selectedShape ?? st?.selection.text.flatMap { st?.shape($0.shape) }
        if sh == nil {
            Section {
                InspectorNote(text: String(localized: "Select a shape to format it.", bundle: .module))
            }
        } else {
            Section {
                Picker(String(localized: "Format", bundle: .module, comment: "The inspector's Format tab (noun)"), selection: Binding(get: { ctl.formatTab }, set: { ctl.showFormatTab($0) })) {
                    ForEach(ctl.formatTabs(), id: \.id) { t in
                        Image(systemName: Self.symbol(t.id)).help(t.label).accessibilityLabel(t.label).tag(t.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(ctl.formatTabs().first { $0.id == ctl.formatTab }?.label ?? "").font(Tokens.Font.sectionTitle)
                FormatPainterRow(ctl: ctl)
            }
            if let sh {
                switch ctl.formatTab {
                case "effects": EffectsView(ctl: ctl, sh: sh)
                case "size": SizeView(ctl: ctl, sh: sh)
                case "text": TextFormatView(ctl: ctl, sh: sh)
                case "picture": PictureView(ctl: ctl, sh: sh)
                case "table": TableFormatView(ctl: ctl)
                case "chart": ChartFormatView(ctl: ctl)
                case "smartart": SmartArtFormatView(ctl: ctl)
                case "media": MediaFormatView(ctl: ctl)
                default: FillLineView(ctl: ctl, sh: sh)
                }
            }
        }
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "effects": "sparkles.rectangle.stack"
        case "size": "ruler"
        case "text": "textformat"
        case "picture": "photo"
        case "table": "tablecells"
        case "chart": "chart.bar"
        case "smartart": "rectangle.3.group"
        case "media": "play.rectangle"
        default: "paintbrush.pointed"
        }
    }
}

/// Home ▸ Clipboard's Format Painter (the main half picks the formatting up; Keep On is deckcraft's
/// double-click) and Paste Formatting.
struct FormatPainterRow: View {
    let ctl: InspectorController

    var body: some View {
        let on = ctl.session.painter != nil
        HStack {
            Menu {
                Button(String(localized: "Keep Format Painter On", bundle: .module)) { ctl.run("format.painter", ["sticky": true]) }
                Button(String(localized: "Paste Formatting", bundle: .module)) { ctl.run("format.painterApply") }.disabled(!on)
            } label: {
                Label(on ? String(localized: "Format Painter (on)", bundle: .module) : String(localized: "Format Painter", bundle: .module), systemImage: on ? "paintbrush.fill" : "paintbrush")
            } primaryAction: {
                if on {
                    ctl.session.painter = nil
                    ctl.model.changed()
                } else {
                    ctl.run("format.painter")
                }
            }
            .fixedSize()
            .disabled(!on && !ctl.enabled("format.painter"))
            .help(String(localized: "Format Painter (⇧⌘C): copy this formatting to the next object you click", bundle: .module))
        }
    }
}
