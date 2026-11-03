import SwiftUI
import VoxClipCore

@MainActor struct RewriteWordingFitCard: View {
    let model: EditorModel?
    var body: some View {
        if let session = model?.openRewrite {
            VStack(alignment: .leading, spacing: 8) {
                if session.wordingFit.awaitingApproval {
                    Text("Fit wording automatically · up to 3 requests · \(session.wordingFitCostLine)")
                    HStack(spacing: 12) {
                        Button("Fit") { Task { await session.fitWording(approved: true) } }
                            .accessibilityIdentifier("voxclip.rewrite.fit.approve")
                        Button("Skip") { session.stopWordingFit() }
                            .accessibilityIdentifier("voxclip.rewrite.fit.skip")
                    }
                    Text("Sends only these phrases and their timing to \(session.aiName). That approval covers this reply only.")
                        .font(VCType.small.font())
                } else if session.wordingFit.running {
                    ProgressView(value: Double(session.wordingFit.round), total: 3)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Fitting wording, round \(session.wordingFit.round) of 3")
                    ForEach(session.wordingFit.phrases, id: \.ordinal) { phrase in
                        let count = EditingPrimitives.splitWords(phrase.proposed).count
                        let difference = phrase.direction == "longer" ? max(1, phrase.target.minimum - count) : max(1, count - phrase.target.maximum)
                        Text("Phrase \(phrase.ordinal) · ≈ \(toFixed1(phrase.estimateSeconds)) s, slot \(toFixed1(phrase.slotSeconds)) s · asking for about \(difference) \(phrase.direction == "longer" ? "more" : "fewer") words")
                            .font(VCType.small.font()).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(session.sendAsksFirst ? "Uses \(session.aiName), billed to your key. Making a take still needs your paid click."
                         : session.connector?.group == "cli" ? "Uses \(session.aiName) on your plan; nothing is paid until Get Price."
                         : "Uses \(session.aiName); nothing is paid until Get Price.")
                        .font(VCType.small.font())
                } else if session.wordingFit.stopped {
                    Text("Fitting stopped. Your latest proposal is kept.").font(VCType.small.font())
                }
                if !session.wordingFit.problem.isEmpty {
                    Text(session.wordingFit.problem).font(VCType.small.font())
                        .foregroundStyle(DesignValues.color("status.warning"))
                }
            }
            .font(VCType.callout.font())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Automatic wording fit")
        }
    }
}

@MainActor struct MeasuredWordingFitRow: View {
    @Bindable var session: RewriteSession
    let plan: ClipTakePlan
    var body: some View {
        if let suggestion = session.wordingFit.measured {
            VStack(alignment: .leading, spacing: 8) {
                Text("Take \(suggestion.number) · \(toFixed1(suggestion.measuredSeconds)) s · slot \(toFixed1(suggestion.slotSeconds)) s · too \(suggestion.tooLong ? "long" : "short")")
                    .font(VCType.small.font()).fixedSize(horizontal: false, vertical: true)
                if suggestion.awaitingApproval {
                    Text("Fit wording automatically · 1 request · price unavailable · billed to your key")
                        .font(VCType.small.font())
                    Button("Fit") { session.approveMeasuredFit(plan) }
                        .accessibilityLabel("Fit wording using the measured take length")
                } else if suggestion.preparing {
                    ProgressView("Rewording with the measured length…").controlSize(.small)
                } else if let text = suggestion.text {
                    Text("Reworded with the measured length: “\(text)”")
                        .font(VCType.callout.font()).fixedSize(horizontal: false, vertical: true)
                    if let action = session.pricedTakeAction(phrase: suggestion.phrase) {
                        Button(action.title, action: action.perform)
                            .accessibilityLabel("Make a new take with the reworded text. " + action.title)
                    }
                } else if suggestion.keepOriginal {
                    Text("This phrase cannot fit naturally. Keep the original words or keep this take.")
                        .font(VCType.small.font())
                }
                Button(suggestion.awaitingApproval ? "Skip" : "Keep Take \(suggestion.number)") { session.keepMeasuredTake() }
                    .accessibilityIdentifier("voxclip.rewrite.measured.keep")
                if !suggestion.problem.isEmpty {
                    Text(suggestion.problem).font(VCType.small.font()).foregroundStyle(DesignValues.color("status.warning"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Measured take wording recovery")
        }
    }
}
