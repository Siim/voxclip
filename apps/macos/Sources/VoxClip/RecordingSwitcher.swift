import SwiftUI
import UniformTypeIdentifiers
import VoxClipCore

@MainActor struct RecordingSwitcher: View {
    let editor: EditorModel

    var body: some View {
        ScrollView(.horizontal) {
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
                                Text("· Transcribed").foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("Recording \(region.label), \(index + 1) of \(editor.recordingRegions.count), transcribed")
                    }
                }
                if editor.hasSeveralRecordings { chip(.all) { Text("All") } }
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
                AddRecordingMenu(editor: editor)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .dropDestination(for: URL.self) { urls, _ in
            guard editor.addRecordingReason == nil, let url = urls.first, url.isFileURL,
                  let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, type.conforms(to: .movie) else { return false }
            editor.addRecording(at: url)
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript recordings")
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
