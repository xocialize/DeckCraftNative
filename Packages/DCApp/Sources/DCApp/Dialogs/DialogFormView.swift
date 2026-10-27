// DCApp — draws a dialog's form (`DialogController.form`) and its buttons in SwiftUI. Every control reads
// and writes the dialog's fields through the controller, so the window, the tests and the control channel
// change a dialog the same way. Replaces the egui drawing in deckcraft `crates/ui-egui/src/dialogs.rs`
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCAppModel
import DesignScaffold
import DesignScaffoldPicker
import SwiftUI

/// The open dialog: its form, then its buttons.
struct DialogView: View {
    let controller: DialogController

    var body: some View {
        // Reading the revision redraws the form after a command (a spelling change, a deleted custom show).
        let _ = controller.model.revision
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            // A sheet has no title bar: the dialog's title heads it, as in the Mac's own sheets.
            if let id = controller.current?.id, !DialogCatalog.isWindow(id) {
                Text(controller.title).font(Tokens.Font.headline)
            }
            ScrollView {
                Form {
                    ForEach(Array(controller.form.enumerated()), id: \.offset) { _, row in
                        FormRowView(row: row, controller: controller)
                    }
                }
                .formStyle(.columns)
                .padding(.trailing, Tokens.Space.s)
            }
            .frame(maxHeight: Tokens.Layout.minWindowHeight * 0.75)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tokens.Space.s) {
                Spacer()
                ForEach(controller.buttons, id: \.id) { b in
                    DialogButtonView(button: b) { controller.press(b.id) }
                }
            }
        }
        .padding(Tokens.Space.l)
        .frame(width: Self.width(controller.current?.id))
        // Esc is Cancel, also in the dialogs whose one button is Close.
        .onExitCommand { controller.press("cancel") }
        .font(Tokens.Font.body)
    }

    /// Dialogs keep one width, as the Mac's do: wide forms (two columns of colours, the gallery, the symbols)
    /// two inspector widths, the rest one and a half.
    static func width(_ id: String?) -> CGFloat {
        switch id {
        // AutoCorrect's Replace … With … Add row and Settings' labels beside their checkboxes don't fit one and a
        // half in a long language (pseudo-localized, they spilled past the dialog's edges).
        case "themeColors", "new", "themeFonts", "symbol", "photoAlbum", "spelling", "autocorrect", "preferences": Tokens.Layout.inspectorWidth * 2.2
        default: Tokens.Layout.inspectorWidth * 1.5
        }
    }
}

struct DialogButtonView: View {
    let button: DialogButton
    let action: () -> Void

    var body: some View {
        switch button.role {
        case .primary:
            Button(button.label, action: action).keyboardShortcut(.defaultAction).disabled(!button.enabled)
        case .cancel:
            Button(button.label, action: action).keyboardShortcut(.cancelAction).disabled(!button.enabled)
        case .normal:
            Button(button.label, action: action).disabled(!button.enabled)
        }
    }
}

/// One row of a form.
struct FormRowView: View {
    let row: FormRow
    let controller: DialogController

    func text(_ key: String) -> Binding<String> {
        Binding(get: { controller.current?.value(key) ?? "" }, set: { controller.set(key, $0) })
    }

    func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { controller.current?.flag(key) ?? false }, set: { controller.set(key, $0 ? "1" : "0") })
    }

    var body: some View {
        switch row {
        case .heading(let t):
            Text(t).font(Tokens.Font.sectionTitle).padding(.top, Tokens.Space.xs)
        case .note(let t):
            Text(t).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).fixedSize(horizontal: false, vertical: true)
        case .error(let t):
            Text(t).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.failure).fixedSize(horizontal: false, vertical: true)
        case .text(let label, let key, let placeholder):
            TextField(label, text: text(key), prompt: placeholder.isEmpty ? nil : Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
        case .multiline(let label, let key, let lines):
            TextField(label, text: text(key), prompt: Text(label), axis: .vertical)
                .lineLimit(lines, reservesSpace: true)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel(label)
        case .check(let label, let key):
            Toggle(label, isOn: flag(key)).toggleStyle(.checkbox)
        case .choice(let label, let key, let options):
            Picker(label, selection: text(key)) {
                if !options.contains(where: { $0.value == controller.current?.value(key) }) {
                    Text(controller.current?.value(key) ?? "").tag(controller.current?.value(key) ?? "")
                }
                ForEach(options, id: \.value) { o in Text(o.label).tag(o.value).disabled(!o.enabled) }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(label.isEmpty ? key : label)
        case .radio(let label, let key, let options):
            LabeledContent(label) {
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    ForEach(options, id: \.value) { o in RadioRow(option: o, selected: controller.current?.value(key) == o.value) { controller.set(key, o.value) } }
                }
            }
        case .tabs(let key, let options):
            // Segments when they fit the dialog, else a pop-up menu (SmartArt's categories overflowed, more so in a
            // long language).
            ViewThatFits(in: .horizontal) {
                Picker(key, selection: text(key)) {
                    ForEach(options, id: \.value) { o in Text(o.label).tag(o.value) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker(key, selection: text(key)) {
                    ForEach(options, id: \.value) { o in Text(o.label).tag(o.value) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        case .list(let label, let key, let options, let findable):
            LabeledContent(label) {
                if findable {
                    SearchablePicker(
                        options.map { PickerItem(id: $0.value, name: $0.label, systemImage: "textformat") },
                        placeholder: String(localized: "Find", bundle: .module, comment: "Placeholder of a searchable list in a dialog"),
                        emptyMessage: String(localized: "No matches.", bundle: .module), allowsTagScoping: false, selected: controller.current?.value(key)
                    ) { controller.set(key, $0) }
                    .frame(height: Tokens.Layout.rowHeight * 5)
                } else {
                    SelectList(options: options, selected: controller.current?.value(key) ?? "") { controller.set(key, $0) }
                }
            }
        case .actions(let actions):
            FlowLayout(spacing: Tokens.Space.xs) {
                ForEach(actions, id: \.id) { a in
                    Button(a.label) { controller.press(a.id) }.disabled(!a.enabled)
                }
            }
        case .item(let t, let actions):
            HStack(spacing: Tokens.Space.s) {
                Text(t).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Tokens.Space.s)
                ForEach(actions, id: \.id) { a in
                    Button(a.label) { controller.press(a.id) }.controlSize(.small).disabled(!a.enabled)
                }
            }
        case .color(let label, let key):
            LabeledContent(label) {
                HStack(spacing: Tokens.Space.xs) {
                    TextField(label, text: text(key)).textFieldStyle(.roundedBorder).labelsHidden()
                    ColorPicker(label, selection: Binding(
                        get: { HexColor.color(controller.current?.value(key) ?? "") ?? Tokens.Color.fieldFill },
                        set: { controller.set(key, HexColor.hex($0)) }
                    ), supportsOpacity: false).labelsHidden()
                }
            }
        case .grid(let cells):
            Grid(horizontalSpacing: Tokens.Space.xs, verticalSpacing: Tokens.Space.xs) {
                ForEach(Array(cells.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, _ in
                            TextField(String(localized: "Chart cell", bundle: .module, comment: "Accessibility label of a cell in the Chart Data grid"), text: text("cell:\(r):\(c)")).textFieldStyle(.roundedBorder).labelsHidden()
                                .frame(minWidth: Tokens.Layout.metricTileMinWidth / 2)
                        }
                    }
                }
            }
        case .tiles(let tiles):
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tokens.Layout.metricTileMinWidth), spacing: Tokens.Space.m)], spacing: Tokens.Space.m) {
                ForEach(tiles, id: \.id) { t in TileView(tile: t) { controller.press(t.id) } }
            }
        case .sample(let s):
            Text(s.text)
                .font(.custom(s.family, size: s.size).weight(s.bold ? .bold : .regular))
                .italic(s.italic)
                .underline(s.underline)
                .strikethrough(s.strike)
                .lineLimit(1)
        case .row(let rows):
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.m) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in FormRowView(row: r, controller: controller) }
            }
        case .disabled(let rows):
            VStack(alignment: .leading) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in FormRowView(row: r, controller: controller) }
            }
            .disabled(true)
        }
    }
}

/// A radio button row (individual choices can be unavailable, which a radio-group picker can't show).
struct RadioRow: View {
    let option: FormOption
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.xs) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Tokens.Color.accent : Tokens.Color.secondaryLabel)
                Text(option.label)
            }
        }
        .buttonStyle(.plain)
        .disabled(!option.enabled)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel(option.label)
    }
}

/// A short selectable list.
struct SelectList: View {
    let options: [FormOption]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(options, id: \.value) { o in
                    Button { pick(o.value) } label: {
                        Text(o.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Tokens.Layout.fieldInset)
                            .padding(.vertical, Tokens.Space.xs)
                            .background(o.value == selected ? Tokens.Color.selectionWash : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!o.enabled)
                    .accessibilityAddTraits(o.value == selected ? [.isSelected] : [])
                }
            }
        }
        .frame(height: Tokens.Layout.rowHeight * 4)
        .background(Tokens.Color.fieldFill, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(Tokens.Color.separator, lineWidth: Tokens.Layout.hairline))
    }
}

/// A gallery tile: a theme's swatches and its name.
struct TileView: View {
    let tile: FormTile
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Tokens.Space.xs) {
                ZStack(alignment: .bottom) {
                    (tile.colors.first.flatMap(HexColor.color) ?? Tokens.Color.surface)
                    HStack(spacing: 0) {
                        ForEach(Array(tile.colors.dropFirst(2).enumerated()), id: \.offset) { _, hex in
                            (HexColor.color(hex) ?? Tokens.Color.surface)
                        }
                    }
                    .frame(height: Tokens.Space.s)
                    Text(verbatim: "Aa")
                        .font(Tokens.Font.panelTitle)
                        .foregroundStyle(tile.colors.dropFirst().first.flatMap(HexColor.color) ?? Tokens.Color.label)
                        .frame(maxHeight: .infinity)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(Tokens.Color.separator, lineWidth: Tokens.Layout.hairline))
                Text(tile.label).font(Tokens.Font.caption).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
        .help(tile.detail)
        .accessibilityLabel(tile.label)
    }
}

/// Lays its children out in rows, wrapping at the proposed width (a row of symbols, a row of buttons).
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.map { $0.isFinite ? $0 : Tokens.Layout.inspectorWidth * 2 } ?? Tokens.Layout.inspectorWidth * 2
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// `RRGGBB` text as a colour and back: the presentation's colours are data, not the interface's.
enum HexColor {
    static func color(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static func hex(_ c: Color) -> String {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
        func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(ns.redComponent), byte(ns.greenComponent), byte(ns.blueComponent))
    }
}
