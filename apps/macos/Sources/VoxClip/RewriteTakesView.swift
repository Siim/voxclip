import SwiftUI
import VoxClipCore

@MainActor struct RewriteTakesView: View {
    @Bindable var session: RewriteSession
    @Bindable var generation: RewriteGenerationSession
    let generate: () -> Void
    /// The no-voice entry (design §6.3 item 4): it opens voice-lab.md §6 with this project's audio as the default source.
    static let createVoiceTitle = "Create Your Voice…"
    var body: some View {
        consentObservedContent
            .onChange(of: generation.announcement) { _, message in
                guard !message.isEmpty else { return }
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                    userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
            .task(id: generation.bestID) { await generation.autoplayBest() }
    }
    private var selectedConsent: VoiceConsentRecord? {
        guard let voiceID = generation.selectedVoiceID else { return nil }
        let editor: EditorModel = session.editor
        let app: AppModel = editor.app
        let voiceLab: VoiceLabSession = app.voiceLabSession
        let records: [VoiceConsentRecord] = voiceLab.records
        for record in records where record.id == voiceID { return record }
        return nil
    }
    private var consentObservedContent: some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: session.editor.app.bool("voiceLab.providerConsent.elevenlabs")) { _, _ in generation.inputsChanged() }
            .onChange(of: selectedConsent) { _, _ in generation.inputsChanged() }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice").font(.system(size: 12, weight: .semibold))
            if generation.voices.isEmpty {
                Text("No voice yet").foregroundStyle(.secondary)
                Button(Self.createVoiceTitle) {
                    openVoxClipSettings(pane: "voiceLab")
                    session.editor.app.voiceLabSession.openEnrollment()
                }
                Button("Refresh voices") { Task { await generation.discover(language: session.project.transcript?.language ?? "en") } }
            } else {
                Picker("Voice", selection: Binding(get: { generation.selectedVoiceID ?? "" }, set: { generation.chooseVoice($0) })) {
                    ForEach(generation.voices) { voice in
                        Text(voice.voiceName + " · consent " + VoiceLabSettings.createdDate(voice.createdAt, shared: session.editor.app.shared)).tag(voice.id)
                    }
                }.labelsHidden().accessibilityLabel("Consented voice")
                Picker("Speech model", selection: Binding(get: { generation.selectedModelID ?? "" }, set: { generation.chooseModel($0) })) {
                    ForEach(generation.models, id: \.id) { Text($0.name).tag($0.id) }
                }.accessibilityLabel("Speech model")
            }
            Text("Takes").font(.system(size: 12, weight: .semibold))
            Button(generation.buttonTitle, action: generate)
                .disabled(!generation.canExecute)
                .help("Generate up to 3 new takes")
                .accessibilityLabel(generation.buttonTitle)
            Text("Sends the new words and a short audio check to ElevenLabs with your key. No video.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !generation.rows.isEmpty {
                List(selection: Binding(get: { generation.selectedID }, set: { if let id = $0 { _ = generation.select(id) } })) {
                    ForEach(generation.rows) { row in
                        takeRow(row).tag(row.id).frame(height: 36).listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                }.listStyle(.plain).environment(\.defaultMinListRowHeight, 36).frame(height: takeListHeight)
                    .accessibilityLabel("Takes, choose one")
            }
            if generation.preparingQuote { ProgressView("Preparing takes…").controlSize(.small) }
            if generation.phase == .generating {
                ProgressView("Generating take \(min(3, generation.rows.count + 1)) of 3…").controlSize(.small)
                Button("Cancel") { generation.cancel() }
            }
            if generation.phase == .nonePassed {
                Text("These takes didn't sound right. Try different wording or re-record.").fixedSize(horizontal: false, vertical: true)
            }
            if generation.phase == .failed {
                InlineNotice(text: generation.problem)
                Button("Open Settings") { openVoxClipSettings(pane: "voiceLab") }
            }
            if generation.phase != .failed && !generation.problem.isEmpty { InlineNotice(text: generation.problem) }
            if generation.quotePreparationFailed || generation.phase == .failed {
                Button("Retry") { generation.requestQuote() }.disabled(!generation.canGenerate)
            }
            if generation.quote != nil, case .confirm(let copy) = generation.cost {
                Text(copy).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).accessibilityLabel("Cost confirmation. " + copy)
            }
            if generation.selected?.fits == false { lengthChoice }
        }
    }
    private var takeListHeight: CGFloat {
        let count: CGFloat = CGFloat(generation.rows.count)
        let rowHeight: CGFloat = 36
        let inset: CGFloat = 8
        return count * rowHeight + inset
    }
    @ViewBuilder private func takeRow(_ row: VoiceLabTakeRow) -> some View {
        if row.selectable {
            HStack(spacing: 6) {
                Button { Task { await generation.play(row) } } label: {
                    Image(systemName: generation.audition.isPlaying && generation.audition.takeId == row.id ? "pause.fill" : "play.fill").frame(width: 20, height: 24)
                }.buttonStyle(.plain).accessibilityLabel("\(generation.audition.isPlaying && generation.audition.takeId == row.id ? "Pause" : "Play") take \(row.index + 1)")
                Text("Take \(row.index + 1)").font(.system(size: 11))
                Text(duration(row)).font(DesignValues.mono(10))
                Spacer(minLength: 0)
                if row.id == generation.bestID {
                    Text("Best match").font(.system(size: 10)).padding(.horizontal, 4).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary, lineWidth: 1))
                } else { Text(note(row)).font(.system(size: 10)).foregroundStyle(.secondary) }
                Button { Task { await generation.reject(row) } } label: { Image(systemName: "xmark").frame(width: 20, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel("Reject take \(row.index + 1)")
            }.accessibilityElement(children: .contain)
                .accessibilityLabel("Take \(row.index + 1), \(duration(row)), \(row.id == generation.bestID ? "Best match" : note(row))")
                .accessibilityValue(row.id == generation.selectedID ? "Selected" : "Not selected")
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Label("Take \(row.index + 1) didn't pass the speech check.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(DesignValues.color("status.warning"))
                Button(generation.generationButtonTitle("Try Another", takes: 3), action: generate)
                    .font(.system(size: 10)).disabled(!generation.canExecute)
            }.accessibilityLabel("Take \(row.index + 1) didn't pass the speech check")
        }
    }
    #if DEBUG
    var snapshot: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice").font(.system(size: 12, weight: .semibold))
            Text(generation.voices.first?.voiceName ?? "No voice yet").font(.system(size: 12))
            if generation.voices.isEmpty { Text(Self.createVoiceTitle).foregroundStyle(DesignValues.color("accent.text")) }
            Text("Takes").font(.system(size: 12, weight: .semibold))
            Text(generation.buttonTitle).font(.system(size: 12, weight: .medium))
            Text("Sends the new words and a short audio check to ElevenLabs with your key. No video.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(generation.rows) { row in takeRow(row).frame(height: 36) }
            if generation.phase == .generating { Text("Generating take \(min(3, generation.rows.count + 1)) of 3…"); Text("Cancel") }
            if generation.phase == .nonePassed { Text("These takes didn't sound right. Try different wording or re-record.").fixedSize(horizontal: false, vertical: true) }
            if generation.phase == .failed { Text(generation.problem).fixedSize(horizontal: false, vertical: true); Text("Open Settings     Retry") }
            if generation.phase == .awaitingApproval, case .confirm(let copy) = generation.cost { Text(copy).fixedSize(horizontal: false, vertical: true); Text("Cancel     Continue") }
            if generation.selected?.fits == false { lengthChoice }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif
    private func duration(_ row: VoiceLabTakeRow) -> String {
        guard let audio = row.audio else { return "" }
        return String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), Double(audio.fit.plan.outputFrames) / Double(audio.sampleRate))
    }
    private func note(_ row: VoiceLabTakeRow) -> String {
        guard let audio = row.audio else { return "" }
        let frames = audio.fit.plan.edits.reduce(Int64(0)) { $0 + ($1.kind == .insert ? $1.count : -$1.count) }
        return RewriteGenerationSession.pauseFitNote(Double(frames) / Double(audio.sampleRate))
    }
    private var lengthChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(generation.lengthCopy).fixedSize(horizontal: false, vertical: true)
            Picker("How the video keeps up", selection: Binding(get: { generation.videoChoice?.rawValue ?? "" }, set: { if let mode = VoiceLabVideoMode(rawValue: $0) { _ = generation.chooseVideo(mode) } })) {
                Text("Lip sync").tag("lipsync").disabled(true)
                Text("Retimed source video").tag("retimed").disabled(!generation.canRetime)
            }.pickerStyle(.radioGroup)
            Text("Lip sync is not available in this build.").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(generation.retimeCopy).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
