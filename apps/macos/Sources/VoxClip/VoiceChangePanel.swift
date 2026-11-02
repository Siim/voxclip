import SwiftUI
import VoxClipCore

@MainActor struct VoiceChangePanel: View {
    @Bindable var session: VoiceChangeSession
    let back: @MainActor () -> Void
    @State private var paidKeyGuard = PaidSendKeyGuard()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button { if session.close() { back() } } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(.plain).disabled(!session.canClose)
                    Text(session.snapshot.title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text("Source range: \(session.snapshot.window.start, specifier: "%.3f")–\(session.snapshot.window.end, specifier: "%.3f") s · \(session.snapshot.language)")
                        .font(.caption).textSelection(.enabled)
                    Text("Uses your own verified ElevenLabs clone. Your words and source video stay unchanged.")
                        .foregroundStyle(.secondary)
                    Text("Audio is sent only after you approve the exact cost below. No microphone recording, video upload, automatic playback or automatic retry.")
                        .font(.caption).foregroundStyle(.secondary)
                    if session.phase == .idle {
                        Text("Loading voices checks your ElevenLabs account, models and your own clones. It does not send source audio.")
                        Button("Load Voices and Models") { session.startDiscovery() }
                            .accessibilityIdentifier("voxclip.voiceChange.discover")
                    }
                    if !session.voices.isEmpty || !session.models.isEmpty {
                        Picker("Your voice", selection: Binding(get: { session.selectedVoiceID }, set: { session.chooseVoice($0) })) {
                            Text("Choose your voice").tag(Optional<String>.none)
                            ForEach(session.voices, id: \.id) { voice in
                                Text(voice.voiceName).tag(Optional(voice.id))
                            }
                        }.disabled(session.busy || session.hasPaidWork)
                            .accessibilityIdentifier("voxclip.voiceChange.voice")
                        Picker("Conversion model", selection: Binding(get: { session.selectedModelID }, set: { session.chooseModel($0) })) {
                            Text("Choose a model").tag(Optional<String>.none)
                            ForEach(session.models, id: \.id) { model in
                                Text(model.name).tag(Optional(model.id))
                            }
                        }.disabled(session.busy || session.hasPaidWork)
                            .accessibilityIdentifier("voxclip.voiceChange.model")
                    }
                    if session.phase == .choosing && (session.voices.isEmpty || session.models.isEmpty) {
                        Text("No eligible own voice or conversion model is available for this project's language. Create your own voice, finish provider verification or check your account. Nothing was sent for conversion.")
                            .foregroundStyle(.secondary)
                    }
                    if let prepared = session.prepared {
                        Text(session.costCopy).fontWeight(.semibold).textSelection(.enabled)
                            .accessibilityIdentifier("voxclip.voiceChange.cost")
                        Text("\(prepared.requests.count) sequential request(s) · \(prepared.estimate.units, specifier: "%.3f") s including real seam overlap")
                            .font(.caption).textSelection(.enabled)
                        Text("Only the quoted source range is sent to ElevenLabs. Each chunk uses the same seed. Accepted provider requests may still be charged if conversion fails or you stop.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if session.busy { ProgressView(progressCopy).accessibilityIdentifier("voxclip.voiceChange.progress") }
                    if session.hasPaidWork {
                        Text(session.chargeCopy).textSelection(.enabled)
                            .accessibilityIdentifier("voxclip.voiceChange.billing")
                        Text("Saved paid outputs: \(session.outputs.count). Finished output is kept even when review fails or you stop.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !session.unpublished.isEmpty {
                        Text("Paid audio is waiting to be saved. Keep this review open; do not buy another conversion.")
                            .foregroundStyle(DesignValues.color("status.warning"))
                        Button("Retry Saving Locally") { session.retrySaving() }.disabled(session.busy)
                    }
                    if !session.busy, session.phase != .ready, session.phase != .accepted,
                       let prepared = session.prepared, !session.outputs.isEmpty,
                       session.outputs.count == prepared.requests.count, session.unpublished.isEmpty {
                        Button("Retry Local Review — No Upload") { session.startLocalReview() }.disabled(!session.current)
                    }
                    if session.phase == .ready {
                        Label("Ready to review · AI MODIFIED", systemImage: "waveform.badge.checkmark")
                        Text("Listen before accepting. Accept changes the whole approved scope in one undo step. Saving the project keeps the reviewed recipe for reopening and export.")
                        Button("Play Reviewed Audio") { session.playReview() }
                            .disabled(!session.canAccept).accessibilityIdentifier("voxclip.voiceChange.play")
                    }
                    if session.phase == .accepted { Label("Voice change accepted", systemImage: "checkmark") }
                    if !session.spendWarnings.isEmpty {
                        Text("An accepted request could not be fully recorded in the spending ledger. Check ElevenLabs before any further paid action.")
                            .foregroundStyle(DesignValues.color("status.warning"))
                    }
                    if !session.problem.isEmpty {
                        Text(session.problem).textSelection(.enabled)
                            .foregroundStyle(DesignValues.color("status.warning"))
                            .accessibilityIdentifier("voxclip.voiceChange.problem")
                    }
                    Text("Your videos and edits are still here.").font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if session.busy {
                    Button("Stop") { session.cancel() }.accessibilityIdentifier("voxclip.voiceChange.stop")
                } else if session.canAccept {
                    Button("Accept Voice Change") { session.startAcceptance() }
                        .accessibilityIdentifier("voxclip.voiceChange.accept")
                } else if session.canGenerate, let prepared = session.prepared {
                    Button("Approve and Change Voice") { approve(prepared) }
                        .accessibilityIdentifier("voxclip.voiceChange.approve")
                } else if session.canPrepare {
                    Button("Prepare Exact Cost") { session.startPreparation() }
                        .accessibilityIdentifier("voxclip.voiceChange.prepare")
                }
                Spacer(minLength: 0)
            }.padding(16)
        }
        .font(.system(size: 12))
        .foregroundStyle(DesignValues.color("text.primary"))
        .background(DesignValues.color("bg.window"))
        .accessibilityElement(children: .contain).accessibilityLabel(session.snapshot.title)
        .accessibilityIdentifier("voxclip.voiceChange.panel")
        .onDisappear { session.cancel() }
        .onExitCommand { session.cancel() }
        .onChange(of: session.prepared?.id) { _, _ in paidKeyGuard.reset() }
    }
    private func approve(_ prepared: VoiceChangeSession.Prepared) {
        if let event = NSApp.currentEvent, event.type == .keyDown {
            guard paidKeyGuard.accepts(timestamp: event.timestamp, now: ProcessInfo.processInfo.systemUptime,
                isRepeat: event.isARepeat, command: event.modifierFlags.contains(.command)) else { return }
        }
        session.startGeneration(approvedQuoteID: prepared.id)
    }
    private var progressCopy: String {
        switch session.phase {
        case .discovering: "Checking your ElevenLabs account…"
        case .preparing: "Preparing source ranges and exact quotes locally…"
        case .converting: "Changing your voice, one approved chunk at a time…"
        case .reviewing: "Checking timing, audio and the saved recipe locally…"
        default: "Working…"
        }
    }
}
