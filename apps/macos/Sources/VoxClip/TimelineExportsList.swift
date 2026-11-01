import SwiftUI

/// V11b: the bottom panel's second tab uses V2b's projection and actions unchanged.
@MainActor struct TimelineExportsList: View {
    let model: EditorModel
    var body: some View {
        let list = model.exportsList
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if list.rows.isEmpty {
                    Text("No exports yet. Export a clip or the full edit to see it here.")
                        .font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                        .padding(12)
                } else {
                    ForEach(list.rows) { ExplorerExportRow(editor: model, row: $0) }
                }
            }.padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain).accessibilityLabel(list.accessibilityLabel)
        .columnLayoutEvidence("timeline.exports", text: list.accessibilityLabel)
    }
}
