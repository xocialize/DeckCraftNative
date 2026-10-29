// DCApp — the ribbon's galleries (Docs/plans/Ribbon-and-StartScreen.md R2): an inline row of tiles with a "›"
// button that opens the whole gallery by category, the tiles themselves, and the shapes grid the Shapes buttons
// open. Ports the drawing of deckcraft `crates/ui-egui/src/widgets.rs` `gallery` and `ribbon/galleries.rs`
// (`shapes_gallery`, `quick_styles`, `smartart_gallery`), `paint_theme_tile`, `paint_transition_tile`,
// `paint_anim_tile` and `paint_picture_style` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors),
// with SwiftUI: a theme tile is the start window's picture of that theme (`StartFeature.art`), and the table-style
// and SmartArt tiles are DCRender's, drawn off the main thread (`RibbonArt`). No live preview on hover (§12).
import AppKit
import DCAppModel
import DCColor
import DCCore
import DCEngine
import DCModel
import DesignScaffold
import Observation
import SwiftUI

/// The table-style and SmartArt tiles' pictures, rendered one at a time off the main thread and kept for the
/// theme they were drawn in.
@MainActor @Observable
final class RibbonArt {
    static let shared = RibbonArt()
    /// Pixels a point: tiles are drawn for a Retina screen.
    static let scale = 2

    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var queue: [(key: String, art: RibbonGalleryItem.Art, pres: Presentation, slide: Int, width: Int)] = []
    @ObservationIgnored private var rendering = false

    /// The picture of `art` in the active presentation's theme, asking for it the first time.
    func image(_ art: RibbonGalleryItem.Art, width: CGFloat, _ model: AppModel) -> NSImage? {
        guard RibbonTileArt.rendered(art), let d = model.session.activeDoc else { return nil }
        let theme = d.doc.masters.first?.theme
        let key = "\(art)|\(theme?.name ?? "")|\(theme.map { String(describing: $0.colors.colors) } ?? "")"
        if let img = images[key] { return img }
        if asked.insert(key).inserted {
            // Keep the queue to what is on screen: a theme change asks again for every tile.
            if queue.count > 200 { queue.removeFirst(queue.count - 200) }
            queue.append((key, art, d.doc, d.selection.slide, Int(width) * Self.scale))
            renderNext()
        }
        return nil
    }

    private func renderNext() {
        guard !rendering, !queue.isEmpty else { return }
        rendering = true
        let job = queue.removeFirst()
        Task.detached(priority: .utility) { [weak self] in
            let png = RibbonTileArt.png(job.art, job.pres, slide: job.slide, width: job.width)
            await MainActor.run {
                guard let self else { return }
                if let png, let img = NSImage(data: Data(png)) { self.images[job.key] = img }
                self.rendering = false
                self.renderNext()
            }
        }
    }
}

/// A gallery source's tile size in points.
enum RibbonTileSize {
    static func of(_ source: String) -> CGSize {
        switch source {
        case "themes": CGSize(width: 80, height: 45)
        case "variants": CGSize(width: 66, height: 44)
        case "transitions", "animations": CGSize(width: 52, height: 54)
        case "tableStyles": CGSize(width: 50, height: 36)
        case "pictureStyles": CGSize(width: 50, height: 40)
        case "quickStyles": CGSize(width: 42, height: 28)
        case "smartArtLayouts", "smartArtStyles": CGSize(width: 66, height: 44)
        default: CGSize(width: 48, height: 40)
        }
    }
}

/// A gallery inline in the ribbon: the first tiles, then "›" for the whole gallery (`widgets::gallery` and its
/// drop button).
struct RibbonGalleryView: View {
    let control: RibbonControl
    let model: AppModel
    let enabled: Bool
    @State private var open = false

    var body: some View {
        if let g = RibbonGalleries.gallery(control, model) {
            let size = RibbonTileSize.of(g.source)
            HStack(spacing: 2) {
                ForEach(g.inlineItems, id: \.id) { item in
                    RibbonTileButton(item: item, size: size, selected: item.id == g.selected, model: model) { RibbonActions.run(item.command) }
                }
                Button { open.toggle() } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 14, height: size.height)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Show all \(RibbonModel.label(control))", bundle: .module, comment: "The button that expands a ribbon gallery; the gallery's name follows"))
                .accessibilityLabel(String(localized: "More \(RibbonModel.label(control))", bundle: .module, comment: "The button that expands a ribbon gallery"))
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    RibbonGalleryGrid(gallery: g, model: model) { open = false }
                }
            }
            .disabled(!enabled)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(RibbonModel.label(control))
        }
    }
}

/// A gallery as a button that opens the whole gallery: Home › Quick Styles, and any gallery its group has folded.
struct RibbonGalleryButton<Face: View>: View {
    let control: RibbonControl
    let model: AppModel
    /// Open: the ribbon opens it from the keyboard too (⌥↓).
    @Binding var open: Bool
    @ViewBuilder let face: () -> Face

    var body: some View {
        Button { open.toggle() } label: { face() }
            .buttonStyle(.borderless)
            .accessibilityLabel(RibbonModel.label(control))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                if let g = RibbonGalleries.gallery(control, model) { RibbonGalleryGrid(gallery: g, model: model) { open = false } }
            }
    }
}

/// The whole gallery, by category (the drop button's popup).
struct RibbonGalleryGrid: View {
    let gallery: RibbonGallery
    let model: AppModel
    let close: () -> Void

    var body: some View {
        let size = RibbonTileSize.of(gallery.source)
        let columns = Swift.max(Int(440 / (size.width + 4)), 1)
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                ForEach(Array(gallery.sections.enumerated()), id: \.offset) { _, section in
                    if let title = section.title { Text(title).font(Tokens.Font.headline) }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(size.width), spacing: 4), count: columns), alignment: .leading, spacing: 4) {
                        ForEach(section.items, id: \.id) { item in
                            RibbonTileButton(item: item, size: size, selected: item.id == gallery.selected, model: model) {
                                close()
                                RibbonActions.run(item.command)
                            }
                        }
                    }
                }
            }
            .padding(Tokens.Space.m)
        }
        .frame(width: 470)
        .frame(maxHeight: 440)
    }
}

/// One tile: its picture, outlined in the accent colour when it is the selection's.
struct RibbonTileButton: View {
    let item: RibbonGalleryItem
    let size: CGSize
    let selected: Bool
    let model: AppModel
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            RibbonTile(item: item, size: size, model: model)
                .frame(width: size.width, height: size.height)
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control / 2)
                    .strokeBorder(selected ? Tokens.Color.accent : Tokens.Color.separator, lineWidth: selected ? Tokens.Layout.hairline * 2 : Tokens.Layout.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.label)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A tile's picture.
struct RibbonTile: View {
    let item: RibbonGalleryItem
    let size: CGSize
    let model: AppModel

    var body: some View {
        switch item.art {
        case .startTile(let id):
            if let img = StartFeature.art.tile(id) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: size.width, height: size.height).clipped()
            } else {
                ThemeTile(colors: builtinThemes().first { "theme:\($0.name)" == id }?.colors ?? Theme.default.colors)
            }
        case .variant(let i):
            let theme = model.session.activeDoc?.doc.masters.first?.theme
            ThemeTile(colors: theme.flatMap { themeVariants($0).at(i) } ?? Theme.default.colors)
        case .transition(let symbol):
            labelled(Image(systemName: symbol).font(.system(size: 17)))
        case .animation(let cls):
            labelled(Image(systemName: cls == .path ? "point.topleft.down.to.point.bottomright.curvepath" : "star.fill")
                .font(.system(size: 17)).foregroundStyle(AnimationPaneView.color(cls)))
        case .quickStyle(let i):
            QuickStyleTile(scheme: InspectorColors.scheme(model.session), index: i)
        case .pictureStyle(let id):
            PictureStyleTile(look: PictureStyleCommands.look(id))
        case .tableStyle, .smartArt:
            // On white, as on a slide: a style without fills is otherwise lost on a dark tile.
            ZStack {
                Color.white
                if let img = RibbonArt.shared.image(item.art, width: size.width, model) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(2)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control / 2))
        }
    }

    /// A symbol over the item's name, as the transition and animation tiles are.
    private func labelled(_ icon: some View) -> some View {
        VStack(spacing: 2) {
            icon.frame(height: 24)
            Text(item.label).font(.system(size: 9)).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
        }
        .padding(2)
    }
}

/// A picture style (`paint_picture_style`): a landscape in the style's shape, with its frame, shadow and tilt.
struct PictureStyleTile: View {
    let look: PictureStyleCommands.Look?

    var body: some View {
        let shape = PictureStyleShape(preset: look?.preset ?? "rect")
        let frame = look?.frame
        shape
            .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.75, blue: 0.95), Color(red: 0.35, green: 0.6, blue: 0.35)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.stroke(frame.map { $0.0.swiftUI } ?? .clear, lineWidth: frame.map { Swift.min(Swift.max($0.1 / 3, 0.5), 3) } ?? 0))
            .shadow(color: look?.shadow == nil ? .clear : .black.opacity(0.35), radius: 2, x: 1, y: 1.5)
            .rotationEffect(.degrees(Swift.min(Swift.max(look?.rot ?? 0, -45), 45)))
            .padding(7)
    }
}

/// The outline a picture style crops to: an oval, a rounded or snipped rectangle, or a rectangle.
struct PictureStyleShape: SwiftUI.Shape {
    let preset: String

    func path(in r: CGRect) -> Path {
        switch preset {
        case "ellipse": return Path(ellipseIn: r)
        case "roundRect", "round2DiagRect": return Path(roundedRect: r, cornerRadius: Swift.min(r.width, r.height) / 5)
        case "snip2DiagRect":
            let k = Swift.min(r.width, r.height) / 5
            var p = Path()
            p.move(to: CGPoint(x: r.minX + k, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - k))
            p.addLine(to: CGPoint(x: r.maxX - k, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + k))
            p.closeSubpath()
            return p
        default: return Path(r)
        }
    }
}

/// The Shapes buttons' grid (`shapes_gallery`): every preset by category, the freeform tools with the lines, then
/// the rest of the Shapes menu (Icons, WordArt, Action Buttons, links, Draw) as a menu.
struct RibbonShapesGrid: View {
    let entries: [CommandMenuEntry]
    let model: AppModel
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                    if case .submenu(let title, let items) = e, items.contains(where: Self.isShape) {
                        Text(title).font(Tokens.Font.headline)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 1), count: 12), alignment: .leading, spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                if case .item(let label, let c, let preset) = item {
                                    Button {
                                        close()
                                        RibbonActions.run(c)
                                    } label: {
                                        Group {
                                            if let preset { Image(nsImage: PresetIcons.image(preset)) } else { Image(systemName: CommandSymbols.symbol(c) ?? "scribble") }
                                        }
                                        .frame(width: 26, height: 26)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.borderless)
                                    .help(label)
                                    .accessibilityLabel(label)
                                }
                            }
                        }
                    }
                }
                Divider()
                Menu(String(localized: "Icons, WordArt and More", bundle: .module, comment: "The rest of the Shapes menu, under its grid")) {
                    RibbonMenuItems(entries: entries.filter { e in
                        if case .submenu(_, let items) = e { return !items.contains(where: Self.isShape) }
                        return true
                    }, model: model)
                }
                .fixedSize()
            }
            .padding(Tokens.Space.m)
        }
        .frame(width: 360)
        .frame(maxHeight: 440)
    }

    /// Whether a menu entry draws a shape (a preset or a freeform tool).
    static func isShape(_ e: CommandMenuEntry) -> Bool {
        if case .item(_, let c, let preset) = e { return preset != nil || c.id == "tool.shape" }
        return false
    }
}
