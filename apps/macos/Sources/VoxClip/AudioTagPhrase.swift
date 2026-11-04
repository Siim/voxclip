import SwiftUI
import VoxClipCore

@MainActor struct AudioTagPhrase: View {
    static let explanation = "Rewrite suggests tags where your original had a laugh, sigh or pause. Tags aren't spoken words and don't count in the word check."
    static let placementHint = "Click a word to put the expression before it."
    let text: String
    let tags: [VoiceLabAudioTag]
    let phrase: Int
    /// Where a new tag goes unless a word is clicked: before the first changed word (after the left bridge words).
    var insertionBoundary: Int? = nil
    var omitted = false
    /// False while the wording is being fitted: the tags read as text and no + Expression shows (no control that can't act).
    var editable = true
    let changed: ([VoiceLabAudioTag]) -> Void
    @State private var choosing = false
    /// The word boundary the user clicked while choosing: the tag goes before that word.
    @State private var chosen: Int?

    /// The quote's pieces in order: words with the quote marks attached, so no space sits inside them, and the tags.
    enum Piece: Hashable { case word(Int, String), tag(Int), open, close, caret }
    static func pieces(words: [String], tags: [VoiceLabAudioTag], caret: Int?) -> [Piece] {
        var pieces: [Piece] = []
        let startsWithTag = tags.contains { $0.beforeToken == 0 } || caret == 0 || words.isEmpty
        let endsWithTag = tags.contains { $0.beforeToken >= words.count } || caret == words.count || words.isEmpty
        if startsWithTag { pieces.append(.open) }
        for boundary in 0...words.count {
            pieces += tags.enumerated().filter { min($0.element.beforeToken, words.count) == boundary }.map { .tag($0.offset) }
            if caret == boundary { pieces.append(.caret) }
            guard boundary < words.count else { continue }
            var word = words[boundary]
            if boundary == 0, !startsWithTag { word = "“" + word }
            if boundary == words.count - 1, !endsWithTag { word += "”" }
            pieces.append(.word(boundary, word))
        }
        if endsWithTag { pieces.append(.close) }
        return pieces
    }

    var body: some View {
        let words = EditingPrimitives.splitWords(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let boundary = min(words.count, max(0, chosen ?? insertionBoundary ?? words.count))
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {
            ExpressionFlow(spacing: 3) {
                ForEach(Self.pieces(words: words, tags: tags, caret: choosing ? boundary : nil), id: \.self) { piece in
                    switch piece {
                    case .open: Text("“")
                    case .close: Text("”")
                    case .caret:
                        Text("|").foregroundStyle(DesignValues.color("ai.tint")).accessibilityLabel("Expression goes here")
                    case .word(let index, let word):
                        if choosing {
                            Button { chosen = index } label: { Text(word) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Put the expression before \(words[index])")
                        } else { Text(word) }
                    case .tag(let offset) where !editable:
                        Text("[\(tags[offset].tag)]")
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(DesignValues.color("bg.selectedRow"), in: .rect(cornerRadius: 4))
                    case .tag(let offset):
                        Button { changed(tags.enumerated().filter { $0.offset != offset }.map(\.element)) } label: {
                            HStack(spacing: 3) {
                                Text("[\(tags[offset].tag)]")
                                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                            }
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(DesignValues.color("bg.selectedRow"), in: .rect(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(tags[offset].tag) from phrase \(phrase)")
                    }
                }
            }
            .font(VCType.callout.font())
            .foregroundStyle(DesignValues.color("text.primary"))
            if editable {
                Button("+ Expression") { choosing.toggle(); if !choosing { chosen = nil } }
                    .buttonStyle(.plain).font(VCType.small.font())
                    .foregroundStyle(DesignValues.color("text.secondary"))
                    .accessibilityLabel("Add expression to phrase \(phrase)")
                    .accessibilityValue(choosing ? "Expanded" : "Collapsed")
                    .modifier(PanelButtonEvidence(id: "expression.\(phrase)", title: "+ Expression"))
            }
            if choosing, editable {
                Text(Self.placementHint).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                ExpressionFlow(spacing: VCTokens.spacingChipGap) {

                    ForEach(VoiceLabAudioTags.definitions, id: \.tag) { definition in
                        Button(definition.tag) {
                            changed(tags + [VoiceLabAudioTag(beforeToken: boundary, tag: definition.tag)])
                            choosing = false; chosen = nil
                        }
                        .buttonStyle(.plain).font(VCType.small.font())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(DesignValues.color("bg.selectedRow"), in: .rect(cornerRadius: 4))
                        .accessibilityLabel("Add \(definition.tag) to phrase \(phrase)" + (boundary < words.count ? ", before \(words[boundary])" : ", at the end"))
                    }
                    if boundary < words.count {
                        Button("At the end") { chosen = words.count }
                            .buttonStyle(.plain).font(VCType.small.font())
                            .foregroundStyle(DesignValues.color("text.secondary"))
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
