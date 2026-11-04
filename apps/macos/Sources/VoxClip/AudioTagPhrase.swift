import SwiftUI
import VoxClipCore

@MainActor struct AudioTagPhrase: View {
    static let explanation = "Rewrite suggests tags where your original had a laugh, sigh or pause. Tags aren't spoken words and don't count in the word check."
    let text: String
    let tags: [VoiceLabAudioTag]
    let phrase: Int
    var insertionBoundary: Int? = nil
    var omitted = false
    let changed: ([VoiceLabAudioTag]) -> Void
    @State private var choosing = false

    var body: some View {
        let words = EditingPrimitives.splitWords(text)
        VStack(alignment: .leading, spacing: 5) {
            ExpressionFlow(spacing: 3) {
                Text("“")
                ForEach(0...words.count, id: \.self) { boundary in
                    ForEach(Array(tags.enumerated()).filter { $0.element.beforeToken == boundary }, id: \.offset) { annotation in
                        Button { changed(tags.enumerated().filter { $0.offset != annotation.offset }.map(\.element)) } label: {
                            HStack(spacing: 3) {
                                Text("[\(annotation.element.tag)]")
                                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                            }
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(DesignValues.color("bg.selectedRow"), in: .rect(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(annotation.element.tag) from phrase \(phrase)")
                    }
                    if boundary < words.count { Text(words[boundary]) }
                }
                Text("”")
            }
            .font(VCType.callout.font())
            .foregroundStyle(DesignValues.color("text.primary"))
            Button("+ Expression") { choosing.toggle() }
                .buttonStyle(.plain).font(VCType.small.font())
                .foregroundStyle(DesignValues.color("text.secondary"))
                .accessibilityLabel("Add expression to phrase \(phrase)")
                .accessibilityValue(choosing ? "Expanded" : "Collapsed")
                .modifier(PanelButtonEvidence(id: "expression.\(phrase)", title: "+ Expression"))
            if choosing {
                ExpressionFlow(spacing: 5) {
                    ForEach(VoiceLabAudioTags.definitions, id: \.tag) { definition in
                        Button(definition.tag) {
                            let boundary = min(words.count, max(0, insertionBoundary ?? words.count))
                            changed(tags + [VoiceLabAudioTag(beforeToken: boundary, tag: definition.tag)])
                            choosing = false
                        }
                        .buttonStyle(.plain).font(VCType.small.font())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(DesignValues.color("bg.selectedRow"), in: .rect(cornerRadius: 4))
                        .accessibilityLabel("Add \(definition.tag) to phrase \(phrase)")
                    }
                }
            }
            if omitted, !tags.isEmpty {
                Text("Tags left out with this model.").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Phrase \(phrase)")
        .columnLayoutEvidence("voice.quote.\(phrase)", text: "Phrase \(phrase): " + Self.drawn(text, tags: tags))
    }
}

/// Lays its subviews out in rows that wrap at the proposed width: expression chips and next-step chips.
struct ExpressionFlow: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measure(width: proposal.width ?? 320, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = measure(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let point = layout.positions[index]
            let size = subview.sizeThatFits(ProposedViewSize(width: max(1, bounds.width), height: nil))
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
        }
    }
    private func measure(width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let available = max(1, width)
        var positions: [CGPoint] = []
        var horizontal: CGFloat = 0, vertical: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: available, height: nil))
            if horizontal > 0, horizontal + size.width > available {
                vertical += rowHeight + spacing; horizontal = 0; rowHeight = 0
            }
            positions.append(CGPoint(x: horizontal, y: vertical))
            usedWidth = max(usedWidth, horizontal + size.width)
            horizontal += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: min(available, usedWidth), height: vertical + rowHeight), positions)
    }
}

extension AudioTagPhrase {
    /// The quote as the phrase card draws it, each tag in brackets before its word: the Rewrite smoke's evidence (I7).
    static func drawn(_ text: String, tags: [VoiceLabAudioTag]) -> String {
        let words = EditingPrimitives.splitWords(text)
        var pieces: [String] = []
        for boundary in 0...words.count {
            pieces += tags.filter { min($0.beforeToken, words.count) == boundary }.map { "[\($0.tag)]" }
            if boundary < words.count { pieces.append(words[boundary]) }
        }
        return "“" + pieces.joined(separator: " ") + "”"
    }
}
