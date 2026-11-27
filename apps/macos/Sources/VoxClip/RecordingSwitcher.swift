import SwiftUI
import UniformTypeIdentifiers
import VoxClipCore

struct RecordingFeedback: Equatable {
    let text: String
    let revision: Int
}

@MainActor struct RecordingEditToast: View {
    let editor: EditorModel

    var body: some View {
        if let feedback = editor.recordingFeedback, feedback.revision == editor.projectRevision {
            HStack {
                Text(feedback.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if editor.undoManager?.canUndo == true {
                    Button("Undo") { editor.recordingFeedback = nil; editor.undoManager?.undo() }
                }
                Button("Dismiss", systemImage: "xmark") { editor.recordingFeedback = nil }.labelStyle(.iconOnly)
            }
            .font(.system(size: 11)).padding(8).background(DesignValues.color("bg.muted"))
            .task(id: feedback.revision) {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled, editor.recordingFeedback == feedback { editor.recordingFeedback = nil }
            }
        }
    }
}

@MainActor struct RecordingSwitcher: View {
    let editor: EditorModel

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                recordingChips
            }
            .scrollIndicators(.hidden)
            AddRecordingMenu(editor: editor)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .dropDestination(for: URL.self) { urls, _ in
            guard editor.addRecordingReason == nil, let url = urls.first, url.isFileURL,
                  let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, type.conforms(to: .movie) else { return false }
            editor.addRecording(at: url)
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript recordings")
    }

    private var recordingChips: some View {
        HStack(spacing: 6) {
                if let clip = editor.activeClip, editor.storyRecordingRegions.count > 1 {
                    chip(.playOrder) { Text("\(editor.scopeName(clip.id)) · play order") }
                }
                if editor.hasSeveralRecordings || editor.pendingRecording != nil {
                    ForEach(Array(editor.recordingRegions.enumerated()), id: \.element.key) { index, region in
                        chip(.recording(region.key)) {
                            HStack(spacing: 5) {
                                RecordingLabel(region: region)
                                Text("· \(storyTakeTime(Double(region.durationSamples) / Double(editor.recordingClock?.sampleRate ?? 48_000)))")
                                if region.gainDb != 0, let primary = editor.recordingRegions.first {
                                    let gain = region.gainDb
                                    Text("· \(gain < 0 ? "−" : "+")\(toFixed1(abs(gain))) dB to match \(primary.label)").foregroundStyle(.secondary)
                                } else {
                                    Text("· Transcribed").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityLabel("Recording \(region.label), \(index + 1) of \(editor.recordingRegions.count), transcribed")
                    }
                }
                if editor.hasSeveralRecordings { chip(.all) { Text("All") } }
                ForEach(editor.recordingCompanions.filter { $0.contentKey != editor.pendingRecording?.reference.contentKey }, id: \.contentKey) { source in
                    HStack(spacing: 5) {
                        Text("\(ProjectClock.label(source)) · Not transcribed")
                        Button("Transcribe on this Mac") {
                            editor.addRecording(at: editor.recordingURL(source), companion: source, onThisMac: true)
                        }
                        .disabled(editor.addRecordingReason != nil)
                    }
                    .font(.system(size: 11))
                }
                if let pending = editor.pendingRecording {
                    Text("\(pending.label) · \(pending.state)").font(.system(size: 11))
                    if pending.transcriber.isRunning {
                        Button("Cancel") { pending.transcriber.cancel() }
                    } else if !pending.transcriber.isVisible {
                        Button(pending.transcriber.paid ? "Transcribe with ElevenLabs" : "Transcribe on this Mac") {
                            Task { await pending.transcriber.open() }
                        }
                    }
                }
                if editor.recordingImportTask != nil && editor.pendingRecording == nil { Text("Reading recording…").font(.system(size: 11)) }
        }
    }

    private func chip<LabelContent: View>(_ choice: RecordingTranscriptChoice, @ViewBuilder label: () -> LabelContent) -> some View {
        let selected = choice == editor.transcriptRecordingScope
        return Button { editor.chooseRecordingTranscript(choice) } label: { label().font(.system(size: 11)) }
            .buttonStyle(.bordered)
            .tint(selected ? Color(nsColor: DesignValues.accentFill) : nil)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor struct RecordingPartPicker: View {
    let editor: EditorModel
    let clip: ClipRange
    let region: ProjectClock.Region

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Select words in \(region.label) to add them to \(editor.scopeName(clip.id)) · \(editor.partPickAfter.map { "after part \($0)" } ?? "at the end")")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Add as Part \(editor.recordingPartNumber)") { editor.addSelectionAsStoryPart() }
                    .disabled(editor.addStoryPartReason != nil)
                Button("Done") { editor.partPickKey = nil }
            }
            if let reason = editor.storyPartError ?? editor.addStoryPartReason {
                Text(reason).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(DesignValues.color("bg.muted"))
        .onExitCommand { editor.partPickKey = nil }
    }
}
