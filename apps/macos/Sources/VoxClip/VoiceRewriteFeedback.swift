import SwiftUI
import VoxClipCore

struct VoiceRewriteFeedback {
    struct Phrase: Identifiable {
        let id: String
        let text: String
        let take: Int
        let length: Double
        let start: Double
    }
    let project: Project
    let revision: Int
    let undoName: String
    let message: String
    let voiceName: String
    let phrases: [Phrase]
    let spent: CostEstimate
    var spendLine: String {
        let cost = spent.usd.map { "Spent " + VoiceLabCostPresentation.format($0) } ?? "Spend unavailable"
        let count = Int(spent.units)
        return cost + " on ElevenLabs for \(count) \(count == 1 ? "take" : "takes"). Exports carry an AI MODIFIED label."
    }
}

extension EditorModel {
    var currentVoiceFeedback: VoiceRewriteFeedback? {
        guard app.voiceLabRewriteEnabled, let feedback = voiceRewriteFeedback,
              projectRevision == feedback.revision, project == feedback.project else { return nil }
        return feedback
    }
    var canUndoVoiceRewrite: Bool {
        guard let feedback = currentVoiceFeedback, let undoManager else { return false }
        return capabilities.edit && undoManager.canUndo && undoManager.undoActionName == feedback.undoName
    }
    func finishVoiceRewrite(phrases: [ClipTakePlan.Phrase], segments: [VoiceLabSegment], voice: VoiceLabVoiceReference?,
                            spent: CostEstimate, scope: DirectorScope, cuts: Int, fixes: Int) {
        guard !segments.isEmpty, segments.allSatisfy({ project.voiceLab.segments.contains($0) }),
              phrases.count == segments.count else { return }
        let label = scope.name.prefix(1).uppercased() + scope.name.dropFirst()
        let message = "\(label) rewritten: \(segments.count) \(segments.count == 1 ? "phrase" : "phrases") in your voice, \(cuts) \(cuts == 1 ? "cut" : "cuts"), \(fixes) \(fixes == 1 ? "fix" : "fixes")."
        let used = zip(phrases, segments).map { phrase, segment in
            VoiceRewriteFeedback.Phrase(id: segment.id, text: phrase.text, take: phrase.selected?.number ?? 1,
                length: segment.outDuration, start: segment.replace.start)
        }
        voiceRewriteFeedback = VoiceRewriteFeedback(project: project, revision: projectRevision, undoName: scope.title,
            message: message, voiceName: voice?.displayName ?? "Your own take", phrases: used, spent: spent)
        voiceRewriteToastVisible = true
        voiceRewriteToastTask?.cancel()
        let revision = projectRevision
        voiceRewriteToastTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self, projectRevision == revision else { return }
            voiceRewriteToastVisible = false
        }
        announce(message)
    }
    @discardableResult func undoVoiceRewrite() -> Bool {
        guard canUndoVoiceRewrite else { return false }
        voiceRewriteToastTask?.cancel()
        voiceRewriteToastVisible = false
        voiceRewriteFeedback = nil
        undoManager?.undo()
        announce("Voice rewrite undone. Provider spend is not refunded.")
        return true
    }
}

@MainActor struct VoiceRewriteToast: View {
    @Bindable var model: EditorModel
    var body: some View {
        if model.voiceRewriteToastVisible, let feedback = model.currentVoiceFeedback {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(feedback.message).font(VCType.callout.font()).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.canUndoVoiceRewrite { Button("Undo") { model.undoVoiceRewrite() }.buttonStyle(.plain) }
            }
            .padding(12).background(DesignValues.color("bg.selectedRow"))
            .accessibilityElement(children: .contain).accessibilityLabel(feedback.message)
            .accessibilityIdentifier("voxclip.voice.rewriteToast")
        }
    }
}

@MainActor struct VoiceRewriteDone: View {
    @Bindable var model: EditorModel
    let feedback: VoiceRewriteFeedback
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(feedback.voiceName + " · your voice").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                    Text("\(feedback.phrases.count) \(feedback.phrases.count == 1 ? "phrase" : "phrases") in your voice · in use")
                        .font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    ForEach(feedback.phrases) { phrase in
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                model.seek(source: phrase.start)
                                if !model.isPlaying { model.transport(" ") }
                            } label: { Image(systemName: "play.fill").frame(width: 28, height: 28) }
                                .buttonStyle(.plain).accessibilityLabel("Play phrase in clip: " + phrase.text)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("“" + phrase.text + "”").font(VCType.callout.font())
                                Text("Take \(phrase.take) · " + String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), phrase.length) + " · fits")
                                    .font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
                            }
                        }.accessibilityElement(children: .contain)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(feedback.spendLine).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.canUndoVoiceRewrite { Button("Undo Voice") { model.undoVoiceRewrite() }.buttonStyle(.plain) }
            }
            .padding(16).overlay(alignment: .top) { Rectangle().fill(DesignValues.color("line.default")).frame(height: 1) }
            .columnLayoutEvidence("voice.done.footer", text: feedback.spendLine)
        }
        .foregroundStyle(DesignValues.color("text.primary")).background(DesignValues.color("bg.window"))
        .modifier(EditorPaneFocus(model: model, pane: .panel))
        .accessibilityElement(children: .contain).accessibilityLabel("Voice rewrite in use")
        .onKeyPress(keys: [.space], phases: [.down, .repeat]) { press in
            if press.phase == .down { model.transport(" ") }
            return .handled
        }
    }
}
