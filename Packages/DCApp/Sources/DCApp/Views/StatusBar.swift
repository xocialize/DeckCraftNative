// DCApp — the status bar under the slide. Port of `status_bar` in deckcraft `crates/ui-egui/src/status.rs`
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors): the slide counter, the selection's
// proofing language (a click opens Review › Language) and the slide's spelling state, the latest status
// message; on the right Notes and Comments, the views, and the zoom (out, slider 10–400 % on a log scale,
// in, the percentage that opens Zoom…, Fit). In the Slide Sorter the slider sizes the thumbnails.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCModel
import DesignScaffold
import SwiftUI

/// The spelling problems of the current slide, counted once per slide value.
@MainActor
final class SpellingState {
    private var last: (slide: Slide, count: Int)?

    func issues(_ slide: Slide?) -> Int {
        guard let slide else { return 0 }
        if let l = last, l.slide == slide { return l.count }
        let n = StatusLogic.spellingIssues(slide)
        last = (slide, n)
        return n
    }
}

struct StatusBarView: View {
    let link: DocLink
    let spelling: SpellingState
    /// A status message stops showing a few seconds after it appeared (`fresh_status`).
    @State private var expired: String?

    var body: some View {
        let model = link.model
        _ = model.revision
        let st = link.state
        let view = model.ui.view
        return HStack(spacing: Tokens.Space.s) {
            if let st {
                Text(StatusLogic.slideText(st))
                    .accessibilityLabel(StatusLogic.slideText(st))
                    .fixedSize()
                language(st)
                proofing(st)
            }
            if let s = model.status, s != expired {
                Text(s)
                    .foregroundStyle(Tokens.Color.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(s)
                    .task(id: s) {
                        try? await Task.sleep(for: .seconds(6))
                        expired = s
                    }
            }
            Spacer(minLength: Tokens.Space.s)
            // The controls on the right never clip: in a narrow window they shed the zoom slider, then the view
            // buttons, keeping the zoom percentage and Fit; they take their width before the status message.
            ViewThatFits(in: .horizontal) {
                controls(model, st, view, slider: true, views: true, panes: true)
                controls(model, st, view, slider: false, views: true, panes: true)
                controls(model, st, view, slider: false, views: false, panes: true)
                controls(model, st, view, slider: false, views: false, panes: false)
            }
            .layoutPriority(1)
        }
        .font(Tokens.Font.caption)
        .foregroundStyle(Tokens.Color.secondaryLabel)
        .padding(.horizontal, Tokens.Space.m)
        .frame(height: Tokens.Layout.controlHeight + Tokens.Space.xs, alignment: .leading)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(.bar)
    }

    /// The buttons and zoom on the right, with the zoom slider, the four view buttons and the two pane toggles
    /// each optional.
    private func controls(_ model: AppModel, _ st: DocState?, _ view: ViewMode, slider: Bool, views: Bool, panes: Bool) -> some View {
        HStack(spacing: Tokens.Space.s) {
            if panes {
                toggle(String(localized: "Notes", bundle: .module, comment: "Status bar button: shows or hides the notes pane"), "note.text", on: model.ui.notes) { link.run("view.notes") }
                toggle(String(localized: "Comments", bundle: .module, comment: "Status bar button: shows or hides the comments pane"), "text.bubble", on: model.ui.pane == "comments") { link.run("view.pane", ["pane": "comments", "toggle": true]) }
                Divider().frame(height: Tokens.Space.l)
            }
            if views {
                toggle(String(localized: "Normal", bundle: .module, comment: "The Normal view (status bar button)"), "rectangle.split.2x1", on: view == .normal || view == .outline) { link.run("view.normal") }
                toggle(String(localized: "Slide Sorter", bundle: .module), "square.grid.2x2", on: view == .sorter) { link.run("view.sorter") }
                toggle(String(localized: "Reading View", bundle: .module), "book", on: view == .reading) { link.run("view.reading") }
                toggle(String(localized: "Slide Show", bundle: .module), "play.rectangle", on: false) { link.run("show.start", ["from": .integer(st?.selection.slide ?? 0)]) }
                Divider().frame(height: Tokens.Space.l)
            }
            if view == .sorter { sorterZoom(model, slider: slider) } else { zoom(model, slider: slider) }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func language(_ st: DocState) -> some View {
        let (lang, noProof) = StatusLogic.selectedLanguage(st)
        let langName = StatusLogic.languageName(lang)
        let name = noProof ? String(localized: "\(langName) (not checked)", bundle: .module, comment: "Status bar: the selection's proofing language, marked do-not-check") : langName
        Button { link.run("app.dialog", ["id": "language"]) } label: {
            Text(name).lineLimit(1).truncationMode(.tail)
        }
            .buttonStyle(.plain)
            .frame(minWidth: Tokens.Space.xxl, alignment: .leading)
            .help(String(localized: "Language", bundle: .module, comment: "Proofing language (status bar)"))
            .accessibilityLabel(String(localized: "Language", bundle: .module, comment: "Proofing language (status bar)"))
            .accessibilityValue(name)
    }

    @ViewBuilder
    private func proofing(_ st: DocState) -> some View {
        let n = st.selection.target == .slides ? spelling.issues(st.currentSlide) : 0
        let tip = n == 0 ? String(localized: "No spelling problems on this slide", bundle: .module) : String(localized: "\(n) spelling problems on this slide", bundle: .module)
        Button {
            link.run("app.dialog", ["id": "spelling"])
        } label: {
            Image(systemName: n == 0 ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundStyle(n == 0 ? Tokens.Color.secondaryLabel : Tokens.Color.working)
        }
        .buttonStyle(.plain)
        .help(tip)
        .accessibilityLabel(String(localized: "Spelling", bundle: .module))
        .accessibilityValue(tip)
    }

    private func toggle(_ label: String, _ symbol: String, on: Bool, _ action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: Tokens.Layout.controlHeight, height: Tokens.Layout.controlHeight - Tokens.Space.xs)
                .background(on ? Tokens.Color.selectionWash : Color.clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder
    private func zoom(_ model: AppModel, slider: Bool) -> some View {
        let z = model.ui.zoom ?? model.canvasScale
        let pct = Int((z * 100).rounded())
        Button { link.run("view.zoomOut") } label: { Image(systemName: "minus.magnifyingglass") }
            .buttonStyle(.plain).help(String(localized: "Zoom Out", bundle: .module)).accessibilityLabel(String(localized: "Zoom Out", bundle: .module))
        if slider {
            Slider(value: Binding(
                get: { StatusLogic.sliderValue(z) },
                set: { link.run("view.zoom", ["percent": .double(StatusLogic.percent($0))]) }
            ), in: StatusLogic.sliderRange)
                .controlSize(.mini)
                .frame(width: Tokens.Space.xxl * 3)
                .accessibilityLabel(String(localized: "Zoom", bundle: .module, comment: "The zoom slider"))
                .accessibilityValue(String(localized: "\(pct)%", bundle: .module, comment: "A zoom percentage"))
        }
        Button { link.run("view.zoomIn") } label: { Image(systemName: "plus.magnifyingglass") }
            .buttonStyle(.plain).help(String(localized: "Zoom In", bundle: .module)).accessibilityLabel(String(localized: "Zoom In", bundle: .module))
        Button(String(localized: "\(pct)%", bundle: .module, comment: "A zoom percentage")) { link.run("view.zoomDialog") }
            .buttonStyle(.plain)
            .font(Tokens.Font.metricInline)
            .frame(minWidth: Tokens.Space.xxl + Tokens.Space.s, alignment: .trailing)
            .help(String(localized: "Zoom…", bundle: .module))
            .accessibilityLabel(String(localized: "Zoom level", bundle: .module))
            .accessibilityValue(String(localized: "\(pct)%", bundle: .module, comment: "A zoom percentage"))
        Button { link.run("view.fit") } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
            .buttonStyle(.plain).help(String(localized: "Fit slide to current window", bundle: .module)).accessibilityLabel(String(localized: "Fit slide to current window", bundle: .module))
    }

    @ViewBuilder
    private func sorterZoom(_ model: AppModel, slider: Bool) -> some View {
        let r = StatusLogic.sorterZoomRange
        Image(systemName: "square.grid.3x3").accessibilityHidden(true)
        if slider {
            Slider(value: Binding(
                get: { model.ui.sorterZoom },
                set: { v in
                    model.ui.sorterZoom = min(max(v, r.lowerBound), r.upperBound)
                    model.changed()
                }
            ), in: r)
                .controlSize(.mini)
                .frame(width: Tokens.Space.xxl * 3)
                .accessibilityLabel(String(localized: "Thumbnail size", bundle: .module))
        }
        Image(systemName: "square.grid.2x2").accessibilityHidden(true)
    }
}
