// DCApp — a number field that can be left empty: a chart axis's minimum, maximum or major unit, which are
// automatic until set, as PowerPoint's Format Axis shows them with a Reset button. The port's own (AB-T-0436).
import CNCore
import DesignScaffold
import SwiftUI

/// Typing commits on Return or when the field loses focus; clearing it commits nil ("Auto").
struct OptionalNumberField: View {
    let label: String
    let value: Double?
    let commit: (Double?) -> Void
    @State private var text: String?
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: Binding(get: { text ?? value.map { NumberField.format($0, "") } ?? "" }, set: { text = $0 }),
                      prompt: Text("Auto", bundle: .module, comment: "An axis bound or unit left for the chart to choose"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(apply)
                .onChange(of: focused) { _, now in if !now { apply() } }
                .accessibilityLabel(label)
        }
    }

    private func apply() {
        guard let t = text else { return }
        text = nil
        let num = String(t.filter { $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-" || $0 == "e" || $0 == "E") })
        if num.isEmpty {
            if value != nil { commit(nil) }
        } else if let v = Double(num), v.isFinite, value.map({ abs(v - $0) > 1e-12 }) ?? true {
            commit(v)
        }
    }
}
