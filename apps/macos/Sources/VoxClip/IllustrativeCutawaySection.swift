import ImagePlayground
import SwiftUI

@MainActor struct IllustrativeCutawaySection: View {
    let model: EditorModel
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @State private var session: IllustrativeCutawaySession?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Generated illustration", isExpanded: $expanded) {
            if let session { controls(session) }
        }
        .accessibilityIdentifier("voxclip.demo.illustration")
        .onChange(of: expanded) { _, open in
            if open {
                if session == nil { session = IllustrativeCutawaySession(model: model) }
            }
            else { session?.reset(); session = nil }
        }
        .onChange(of: model.contextDemoSession?.illustrationReviewRequest?.id, initial: true) { _, _ in
            openRequestedReview()
        }
        .onChange(of: model.projectRevision) { _, _ in session?.followEditor() }
        .onChange(of: model.selectedWordIDs) { _, _ in session?.followEditor() }
        .onChange(of: model.selectedPauseIDs) { _, _ in session?.followEditor() }
        .onChange(of: model.activeClip?.id) { _, _ in session?.followEditor() }
        .onChange(of: model.contextDemoUnavailableReason) { _, _ in session?.followEditor() }
        .onDisappear { session?.reset() }
        .background {
            if let session, let request = session.sheetRequest {
                IllustrativePlaygroundSheet(request: request, session: session).id(request.id)
            }
        }
    }

    private func openRequestedReview() {
        guard let contextDemo = model.contextDemoSession, let request = contextDemo.illustrationReviewRequest else { return }
        contextDemo.illustrationReviewRequest = nil
        let reviewSession = session ?? IllustrativeCutawaySession(model: model)
        session = reviewSession
        expanded = true
        reviewSession.reviewSelection(expected: request)
    }

    private func controls(_ session: IllustrativeCutawaySession) -> some View {
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: 8) {
            Text("Show an illustration over a selected phrase. Your narration continues underneath.")
            if !supportsImagePlayground {
                Text("Apple Image Playground is unavailable. Enable Apple Intelligence on a supported Mac. VoxClip does not offer a fallback provider.")
                    .foregroundStyle(DesignValues.color("text.secondary"))
            } else if let selection = session.selection {
                Text("\(seconds(selection.duration)) seconds · Edited take \(seconds(selection.start))–\(seconds(selection.end))")
                    .monospacedDigit()
                Text(selection.phrase).foregroundStyle(DesignValues.color("text.secondary"))
                if let draft = session.draft {
                    Image(decorative: draft.image, scale: 1).resizable().scaledToFit().frame(maxHeight: 180)
                        .accessibilityLabel("Generated illustration preview")
                    HStack {
                        Button("Place over phrase") { session.apply() }.disabled(!session.canApply)
                        Button("Discard") { session.reset() }
                    }
                } else if session.preparation != nil {
                    ProgressView("Preparing illustration…").controlSize(.small)
                    Button("Cancel") { session.reset() }
                } else {
                    TextField("Prompt shared with Image Playground", text: $session.prompt, axis: .vertical)
                        .lineLimit(2...5).disabled(session.busy)
                    Text("VoxClip passes only this prompt to Apple’s sheet and makes no paid API request ($0 from VoxClip).")
                        .foregroundStyle(DesignValues.color("text.secondary"))
                    if IllustrativeCutawaySelection.reviewedPrompt(session.prompt) == nil {
                        Text("Enter a prompt of up to 1,024 UTF-8 bytes.").foregroundStyle(DesignValues.color("text.secondary"))
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { reviewButtons(session) }
                        VStack(alignment: .leading, spacing: 6) { reviewButtons(session) }
                    }
                }
            } else {
                switch session.readiness {
                case .ready(let selected):
                    Button { session.reviewSelection() } label: {
                        Text("Illustrate “\(selected.phrase)”").lineLimit(1)
                    }
                    Text("\(seconds(selected.duration)) seconds").foregroundStyle(DesignValues.color("text.secondary"))
                case .unavailable(let reason):
                    Button("Illustrate selection") {}.disabled(true)
                    Text(reason).foregroundStyle(DesignValues.color("text.secondary"))
                }
            }
            ForEach(session.placed) { placement in
                HStack {
                    Text("\(seconds(placement.editedStartSeconds))–\(seconds(placement.editedEndSeconds)) seconds")
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Button("Remove") { session.remove(placement.id) }
                        .accessibilityLabel("Remove illustration at \(seconds(placement.editedStartSeconds)) edited seconds")
                        .disabled(session.busy || model.contextDemoUnavailableReason != nil)
                }
            }
            if let message = session.message {
                Text(message).foregroundStyle(DesignValues.color("text.secondary"))
                    .accessibilityIdentifier("voxclip.demo.illustration.message")
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder private func reviewButtons(_ session: IllustrativeCutawaySession) -> some View {
        Button("Create in Image Playground…") { session.openSheet(supported: supportsImagePlayground) }
            .disabled(!session.canOpenSheet)
        Button("Discard") { session.reset() }.disabled(session.busy)
    }

    private func seconds(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
}

@MainActor private struct IllustrativePlaygroundSheet: View {
    let request: IllustrativeCutawaySession.SheetRequest
    let session: IllustrativeCutawaySession
    @State private var showing = false

    var body: some View {
        Color.clear
            .imagePlaygroundSheet(isPresented: $showing, concepts: [.text(request.prompt)]) { url in
                session.receive(url, requestID: request.id)
            } onCancellation: {
                session.cancelledSheet(request.id)
            }
            .imagePlaygroundGenerationStyle(.illustration, in: [.illustration, .sketch, .animation])
            .onAppear { showing = true }
    }
}
