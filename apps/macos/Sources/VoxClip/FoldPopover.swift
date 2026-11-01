import SwiftUI
import VoxClipCore

/// A fold's removed words and pauses (ux/v2 notes.md §5), as its popover and VoiceOver list them.
enum FoldItem: Equatable {
    case word(String)
    case pause(Double)
}

extension EditorModel {
    /// The words and pauses a fold holds, in reading order: words as corrected, without the
    /// comma that came with a filler.
    func foldItems(_ ids: [String]) -> [FoldItem] {
        ids.compactMap { id in
            if let pause = pauseIndex[id] { return .pause(pause.duration) }
            guard let position = index(id) else { return nil }
            return .word(DisplayPunctuation.withoutComma(text(words[position])))
        }
    }
    /// What VoiceOver reads for a fold (impl-plan §3.7): "1 cut: uh, pause 1.4 seconds". A
    /// fold is one cut, one place where the edit removes something.
    func foldDescription(_ ids: [String]) -> String {
        let items = foldItems(ids).map { item in
            switch item {
            case .word(let text): text
            case .pause(let seconds): "pause \(toFixed1(seconds)) seconds"
            }
        }
        return "1 cut: " + items.joined(separator: ", ")
    }
    /// Opens a fold in the transcript, as Show cuts shows it, and selects what it holds, so
    /// Restore (⇧⌫) is one key away. It folds again when the selection leaves it.
    func expandFold(_ ids: [String]) {
        guard let first = ids.first else { return }
        selectedWordIDs = Set(ids.filter { wordIndex[$0] != nil })
        selectedPauseIDs = Set(ids.filter { pauseIndex[$0] != nil })
        expandedFolds[first] = Set(ids)
    }
    /// The popover's Restore: the fold's words and pauses come back as one undo step.
    func restoreFold(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        apply(.restoreSelection(ids: ids), name: "Restore cut")
    }
    /// View › Show Cuts (⌥⌘C): every fold opens, in the transcript and, with the timeline's
    /// Source axis, on the timeline. A view setting: no undo step, no document change.
    func toggleShowsCuts() {
        showsCuts.toggle()
        expandedFolds = [:]
    }
    /// Folds a click opened stay open while the selection holds some of their words or pauses.
    func collapseFoldsOutsideSelection() {
        guard !expandedFolds.isEmpty else { return }
        let selection = selectedWordIDs.union(selectedPauseIDs)
        let open = expandedFolds.filter { !$0.value.isDisjoint(with: selection) }
        if open.count != expandedFolds.count { expandedFolds = open }
    }
}

/// The popover under a hovered fold (notes.md §5): its removed words, struck in `word.gone`,
/// and pause lengths in SF Mono 11, in reading order ("1.4 s uh"), then Restore. Raised fill,
/// a `line.strong` edge, radius 10. Restore shows only where the project can change.
struct FoldPopover: View {
    let items: [FoldItem]
    let description: String
    let canRestore: Bool
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    switch item {
                    case .pause(let seconds):
                        Text("\(toFixed1(seconds))\u{00A0}s").font(VCType.small.mono()).foregroundStyle(DesignValues.color("word.gone"))
                    case .word(let text):
                        Text(text).font(VCType.body.font()).strikethrough(true, color: DesignValues.color("word.gone")).foregroundStyle(DesignValues.color("word.gone"))
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(description)
            if canRestore {
                Button("Restore", action: restore)
                    .buttonStyle(FoldRestoreButtonStyle())
                    .help("Restore these words and pauses")
            }
        }
        .padding(.leading, 12).padding(.trailing, canRestore ? 4 : 12)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DesignValues.color("bg.input")))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DesignValues.color("line.strong"), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Removed")
    }
}

/// Restore in the fold popover: 13 pt medium `text.primary` on `bg.selectedRow`, 24 high, radius 6.
private struct FoldRestoreButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VCType.body.font(.medium))
            .foregroundStyle(DesignValues.color("text.primary"))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DesignValues.color("bg.selectedRow").opacity(configuration.isPressed ? 0.7 : 1)))
    }
}
