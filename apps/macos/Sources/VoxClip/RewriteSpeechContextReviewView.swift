import SwiftUI

@MainActor struct RewriteSpeechContextReviewView: View {
    @Bindable var session: RewriteSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let review = session.speechContextReview {
                Text("Review surrounding sentence").font(VCType.callout.font())
                Text("Change \(review.ordinal) · complete generated replacement")
                Text("“\(review.phrase.text)”").textSelection(.enabled)
                Text(sourceRange(review)).font(VCType.small.font())
                Text("This replaces the whole sentence, not just the changed word. It is not cropped back to the short phrase. Other changes and takes stay as they are.")
                Text("The longer text and source window need a fresh TTS + bounded audio-check quote. Any unsent short-phrase approval is discarded. This review sends nothing and approves no charge; you must approve the new price separately.")
                HStack {
                    Button("Keep short phrase") { session.cancelSpeechContextReview() }.modifier(PanelButtonEvidence(id: "context.keepShort", title: "Keep short phrase"))
                    Button("Accept sentence for new quote") { Task { await session.acceptSpeechContextReview() } }.modifier(PanelButtonEvidence(id: "context.accept", title: "Accept sentence for new quote"))
                }.disabled(session.takesBusy)
            } else if session.speechContextOffer != nil {
                Button("Use surrounding sentence") { session.reviewSpeechContext() }
                    .modifier(PanelButtonEvidence(id: "context.offer", title: "Use surrounding sentence")).disabled(session.takesBusy)
            }
            if !session.speechContextProblem.isEmpty {
                Text(session.speechContextProblem).foregroundStyle(DesignValues.color("status.warning"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Generated speech context review")
    }

    private func sourceRange(_ review: RewriteSpeechContextReview) -> String {
        let window = review.phrase.window
        return "Source words \(window.firstWordId)–\(window.lastWordId) · " +
            String(format: "%.3f–%.3f s", locale: Locale(identifier: "en_US_POSIX"), window.start, window.end) +
            " · samples \(window.startSample)–\(window.endSample)"
    }
}
