// DCApp — presenter view: the elapsed time (pause, reset), the clock, the slide counter, the current slide with
// the zoom marked, the next slide, the speaker notes (size control), black and white screens, See All Slides of
// its own (#1130) and Zoom. Port of `presenter_window` and `presenter_notes` in deckcraft
// `crates/ui-egui/src/show.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors), as SwiftUI
// with DesignScaffold's tokens.
import AppKit
import DCAppModel
import DCCore
import DCModel
import DesignScaffold
import SwiftUI

/// What presenter view shows, refreshed from the show on every tick (values set only when they change).
@MainActor @Observable
final class PresenterModel {
    @ObservationIgnored let coord: ShowCoordinator
    @ObservationIgnored weak var windows: ShowWindows?
    var elapsed = "00:00:00"
    var paused = false
    var clock = "--:--"
    var counter = ""
    var current: CGImage?
    var next: CGImage?
    var hasNext = false
    var notes: [ShowNotesParagraph]?
    var notesPx = ShowController.notesDefault
    var blank: ShowBlank?
    var zoomUV: CGRect?
    var zoomArm = false
    var zoomLabel = String(localized: "Zoom", bundle: .module, comment: "Zoom into part of the slide")
    var grid = false
    var slideCount = 0
    var currentSlide = 0
    var aspect = 16.0 / 9.0
    var hiddenSlides: Set<Int> = []
    /// Bumps when thumbnails arrive, so the grid redraws.
    var thumbsRevision = 0
    @ObservationIgnored private var notesKey: (Int, Double)?

    init(coord: ShowCoordinator, windows: ShowWindows) {
        self.coord = coord
        self.windows = windows
    }

    private func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<PresenterModel, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    func refresh() {
        guard let s = coord.show, let doc = coord.showState?.doc else { return }
        let now = ShowCoordinator.now()
        set(\.elapsed, PresenterTimer.format(s.timer.elapsed(now)))
        set(\.paused, s.timer.paused)
        set(\.clock, PresenterTimer.wallClock())
        set(\.counter, String(localized: "Slide \(s.state.slide + 1) of \(doc.slides.count)", bundle: .module))
        set(\.blank, s.blank)
        set(\.zoomUV, s.zoom?.uv)
        set(\.zoomArm, s.zoomArm)
        set(\.zoomLabel, s.zoomLabel)
        set(\.grid, s.presenterGrid)
        set(\.slideCount, doc.slides.count)
        set(\.currentSlide, s.state.slide)
        set(\.aspect, ShowGeometry.slideAspect(doc))
        set(\.hiddenSlides, Set(doc.slides.indices.filter { doc.slides[$0].hidden }))
        set(\.notesPx, s.notesPx)
        if let stage = windows?.showView?.stage {
            let img = stage.currentImage()
            if img !== current { current = img }
            let n = s.ended ? nil : s.state.peekNext(doc)
            set(\.hasNext, n != nil)
            let ni = n.flatMap { stage.nextImage($0) }
            if ni !== next { next = ni }
        }
        let key = (s.state.slide, s.notesPx)
        if notesKey.map({ $0 != key }) ?? true {
            notesKey = key
            notes = doc.slides.at(s.state.slide).flatMap { ShowNotes.paragraphs($0.notes, size: s.notesPx) }
        }
    }

    // MARK: Actions

    private func after(_ keep: Bool) {
        if !keep { coord.endShow() } else { windows?.showView?.handle(ShowOutcome()) }
        refresh()
    }

    func previous() { after(coord.navigate(false, now: ShowCoordinator.now())) }
    func nextSlide() { after(coord.navigate(true, now: ShowCoordinator.now())) }
    func end() { coord.endShow() }
    func toggleTimer() {
        coord.show?.timer.toggle(ShowCoordinator.now())
        refresh()
    }

    func resetTimer() {
        coord.show?.timer.reset(ShowCoordinator.now())
        refresh()
    }

    func blank(_ c: ShowBlank) {
        coord.show?.toggleBlank(c)
        after(true)
    }

    func toggleGrid() {
        guard let s = coord.show else { return }
        s.presenterGrid.toggle()
        refresh()
    }

    func zoom() {
        coord.show?.zoomKey()
        after(true)
    }

    func notesSize(_ delta: Double) {
        coord.show?.nudgeNotes(delta)
        refresh()
    }

    func pick(_ i: Int) {
        coord.goto(i, now: ShowCoordinator.now())
        after(true)
    }

    /// A click on the current slide while Zoom is armed zooms the audience's slide there.
    func zoomAt(_ nx: Double, _ ny: Double) {
        guard let s = coord.show, s.zoomArm else { return }
        s.zoom = .at(nx, ny)
        s.zoomArm = false
        after(true)
    }

    func thumb(_ i: Int) -> CGImage? {
        var budget = 1
        let t = windows?.showView?.stage.thumb(i, budget: &budget)
        if t == nil { DispatchQueue.main.async { [weak self] in self?.thumbsRevision += 1 } }
        return t
    }
}

struct PresenterView: View {
    let model: PresenterModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            header
            controls
            GeometryReader { geo in
                if model.grid { grid(geo.size) } else { slides(geo.size) }
            }
        }
        .padding(Tokens.Space.l)
        .frame(minWidth: 640, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.l) {
            Text(model.elapsed).font(Tokens.Font.metricValue)
                .foregroundStyle(model.paused ? Tokens.Color.secondaryLabel : Tokens.Color.label)
                .accessibilityLabel(String(localized: "Elapsed time", bundle: .module))
            Text(model.clock).font(Tokens.Font.body.monospacedDigit()).foregroundStyle(Tokens.Color.secondaryLabel)
            Text(model.counter).font(Tokens.Font.body).foregroundStyle(Tokens.Color.secondaryLabel)
            Spacer()
            Button(String(localized: "◀ Previous", bundle: .module, comment: "Go to the previous slide")) { model.previous() }
            Button(String(localized: "Next ▶", bundle: .module, comment: "Go to the next slide")) { model.nextSlide() }
            Button(String(localized: "End Show", bundle: .module)) { model.end() }
        }
        .buttonStyle(.bordered)
        .focusable(false)
    }

    private var controls: some View {
        HStack(spacing: Tokens.Space.s) {
            Button(model.paused ? String(localized: "Resume", bundle: .module, comment: "Resume the timer") : String(localized: "Pause", bundle: .module, comment: "Pause the timer")) { model.toggleTimer() }
            Button(String(localized: "Reset", bundle: .module, comment: "Reset the timer")) { model.resetTimer() }
            Toggle(String(localized: "Black", bundle: .module, comment: "Blank the screen to black"), isOn: Binding(get: { model.blank == .black }, set: { _ in model.blank(.black) }))
            Toggle(String(localized: "White", bundle: .module, comment: "Blank the screen to white"), isOn: Binding(get: { model.blank == .white }, set: { _ in model.blank(.white) }))
            Toggle(String(localized: "All slides", bundle: .module), isOn: Binding(get: { model.grid }, set: { _ in model.toggleGrid() }))
            Button(model.zoomLabel) { model.zoom() }
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .focusable(false)
    }

    private func slides(_ size: CGSize) -> some View {
        let leftW = size.width * 0.62
        let right = CGRect(x: leftW + Tokens.Space.l, y: 0, width: Swift.max(size.width - leftW - Tokens.Space.l, 0), height: size.height)
        let fitted = fit(CGSize(width: leftW, height: size.height * 0.8))
        return ZStack(alignment: .topLeading) {
            current(fitted)
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("Next", bundle: .module, comment: "Heading over the next slide's preview").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                nextPreview(right)
                notesHeader.padding(.top, Tokens.Space.m)
                ScrollView { notes.frame(maxWidth: .infinity, alignment: .leading) }
            }
            .frame(width: right.width, height: right.height, alignment: .topLeading)
            .offset(x: right.minX)
        }
    }

    private func fit(_ box: CGSize) -> CGSize {
        let a = model.aspect
        let w = Swift.min(box.width, box.height * a)
        return CGSize(width: Swift.max(w, 1), height: Swift.max(w / a, 1))
    }

    private func current(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let img = model.current {
                Image(decorative: img, scale: 1).resizable().interpolation(.high)
            } else {
                Rectangle().fill(.black)
            }
            if let uv = model.zoomUV {
                Rectangle().stroke(.white, lineWidth: 2)
                    .frame(width: uv.width * size.width, height: uv.height * size.height)
                    .offset(x: uv.minX * size.width, y: uv.minY * size.height)
            }
            if let b = model.blank { Rectangle().fill(b == .black ? Color.black : Color.white) }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { p in
            if model.zoomArm { model.zoomAt(p.x / size.width, p.y / size.height) }
        }
        .accessibilityLabel(String(localized: "Current slide", bundle: .module))
    }

    private func nextPreview(_ right: CGRect) -> some View {
        // The column's width, kept inside its top 60 % whatever the slide's shape (`next_rect`).
        let box = fit(CGSize(width: right.width, height: Swift.max(right.height - 22, 0) * 0.6))
        return Group {
            if let img = model.next, model.hasNext {
                Image(decorative: img, scale: 1).resizable().interpolation(.high)
            } else {
                ZStack {
                    Rectangle().fill(Tokens.Color.fillElevated)
                    Text("End of slide show", bundle: .module).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                }
            }
        }
        .frame(width: box.width, height: box.height)
        .accessibilityLabel(String(localized: "Next slide", bundle: .module))
    }

    private var notesHeader: some View {
        HStack(spacing: Tokens.Space.s) {
            Text("Notes", bundle: .module).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            Button(String(localized: "A-", bundle: .module, comment: "Make the notes text smaller")) { model.notesSize(-ShowController.notesStep) }.accessibilityLabel(String(localized: "Smaller notes", bundle: .module))
            Text(verbatim: "\(Int(model.notesPx))").font(Tokens.Font.metricInline).foregroundStyle(Tokens.Color.secondaryLabel)
            Button(String(localized: "A+", bundle: .module, comment: "Make the notes text larger")) { model.notesSize(ShowController.notesStep) }.accessibilityLabel(String(localized: "Larger notes", bundle: .module))
        }
        .buttonStyle(.borderless)
        .focusable(false)
    }

    /// The notes with their bullets, numbers and bold, selectable (#1128).
    private var notes: some View {
        Group {
            if let paras = model.notes {
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    ForEach(Array(paras.enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                            if let m = p.marker { Text(m).font(.system(size: model.notesPx)) }
                            Text(attributed(p))
                        }
                        .padding(.leading, Double(Swift.max(p.level - 1, 0)) * model.notesPx)
                    }
                }
                .textSelection(.enabled)
            } else {
                Text("No notes.", bundle: .module).font(.system(size: model.notesPx)).foregroundStyle(Tokens.Color.secondaryLabel)
            }
        }
        .foregroundStyle(Tokens.Color.label)
    }

    private func attributed(_ p: ShowNotesParagraph) -> AttributedString {
        var out = AttributedString()
        for r in p.runs {
            var a = AttributedString(r.text)
            var f = Font.system(size: r.size, weight: r.bold ? .bold : .regular)
            if r.italic { f = f.italic() }
            a.font = f
            if r.underline { a.underlineStyle = .single }
            if r.strike { a.strikethroughStyle = .single }
            out += a
        }
        return out
    }

    /// Presenter view's own See All Slides: the audience keeps the slide (#1130).
    private func grid(_ size: CGSize) -> some View {
        let full = CGRect(origin: .zero, size: size)
        let slides = ShowGeometry.gridIndices(model.slideCount)
        let cells = ShowGeometry.seeAllCells(full, slides.count, model.aspect)
        _ = model.thumbsRevision
        return ZStack(alignment: .topLeading) {
            Text("All slides", bundle: .module).font(Tokens.Font.panelTitle).frame(width: size.width).offset(y: 16)
            ForEach(Array(zip(slides, cells)), id: \.0) { i, r in
                VStack(spacing: Tokens.Space.xs) {
                    Group {
                        if let t = model.thumb(i) { Image(decorative: t, scale: 1).resizable() } else { Rectangle().fill(Tokens.Color.fillElevated) }
                    }
                    .frame(width: r.width, height: r.height)
                    .overlay(Rectangle().stroke(i == model.currentSlide ? Color.white : Tokens.Color.separator, lineWidth: i == model.currentSlide ? 3 : 1))
                    Text(model.hiddenSlides.contains(i) ? String(localized: "\(i + 1)  Hidden", bundle: .module, comment: "A slide number in See All Slides, for a hidden slide") : "\(i + 1)").font(Tokens.Font.caption)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.pick(i) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(String(localized: "Slide \(i + 1)", bundle: .module))
                .offset(x: r.minX, y: r.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
