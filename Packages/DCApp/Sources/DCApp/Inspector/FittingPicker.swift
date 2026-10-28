// DCApp — a choice between a few named parts of the inspector: a segmented control when its titles fit the row's
// width, else a pop-up menu. In a long language the segments ran past the pane's edge (pseudo-localized, Review's
// Comments / Thesaurus / Revisions clipped at the right). The fit is measured, not left to `ViewThatFits`: inside
// the inspector's form sections that chose the menu even where the segments fit.
import AppKit
import SwiftUI

struct FittingPicker<Selection: Hashable>: View {
    let title: String
    let selection: Binding<Selection>
    let options: [(label: String, value: Selection)]
    var hidesLabel = true
    /// The row's width, measured; until then the segments are assumed to fit.
    @State private var width: CGFloat = .infinity

    var body: some View {
        Group {
            if needed <= width + 1 {
                picker.pickerStyle(.segmented)
            } else {
                picker.pickerStyle(.menu).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
    }

    /// The segmented control's width: each title in the control font, plus the segment's padding (12 points,
    /// measured: Review's three English segments fill its 222-point row), plus the label when it shows.
    private var needed: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        func w(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let segments = options.reduce(0) { $0 + w($1.label) + 12 }
        return segments + (hidesLabel ? 0 : w(title) + 12)
    }

    @ViewBuilder private var picker: some View {
        let p = Picker(title, selection: selection) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in Text(verbatim: o.label).tag(o.value) }
        }
        if hidesLabel { p.labelsHidden() } else { p }
    }
}
