import SwiftUI
import VoxClipCore

extension EditorModel {
    func recordingTakes(_ key: String) -> [TakeMatch.Take] {
        recordingTakeMatches?.beats.compactMap { beat in beat.takes.first { $0.key == key } } ?? []
    }

    func recordingOmission(_ takes: [TakeMatch.Take]) -> String? {
        let restarts = takes.filter { $0.flags.contains("restart") }.count
        let starts = takes.filter { !$0.flags.contains("restart") && $0.flags.contains("falseStart") }.count
        let groups = [restarts == 0 ? nil : "\(restarts) restart\(restarts == 1 ? "" : "s")",
                      starts == 0 ? nil : "\(starts) false start\(starts == 1 ? "" : "s")"].compactMap { $0 }
        return groups.isEmpty ? nil : groups.joined(separator: " and ") + " left out"
    }

    func canStartFromRecording(_ region: ProjectClock.Region) -> Bool {
        capabilities.edit && !recordingIsMissing(region.key) && project.edits.clips.count < 64 && recordingTakes(region.key).contains {
            !$0.flags.contains("restart") && !$0.flags.contains("falseStart")
        }
    }

    func startFromRecording(_ region: ProjectClock.Region) {
        guard canStartFromRecording(region) else { return }
        if applyRecordingEdit(.startFromRecording(key: region.key), feedback: { outcome in
            let details = outcome.details
            let title = "\(self.scopeName(details?.clipId)) made from \(region.label)"
            let count = details?.madePartIds.count ?? 0
            let omission = self.recordingOmission(details?.leftOut ?? [])
            return (title + (omission.map { " · " + $0 } ?? ""),
                    title + ", \(count) part\(count == 1 ? "" : "s")" + (omission.map { ", " + $0 } ?? ""))
        }) {
            chooseRecordingTranscript(.playOrder)
        }
    }

    func requestBestRecordingVersions() {
        requestFindClips(from: .sidebar)
    }

}

@MainActor struct RecordingStartOutline: View {
    let editor: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let count = editor.recordingRegions.count
            Text("\(count) spoken recordings of the same idea").fontWeight(.semibold)
            if let first = editor.recordingRegions.first {
                let takes = editor.recordingTakes(first.key)
                let shared = editor.recordingTakeMatches?.beats.filter { $0.takes.count > 1 && $0.takes.contains { $0.key == first.key } }.count ?? 0
                Text("\(shared) of \(first.label)'s \(takes.count) lines are also said in another recording.").foregroundStyle(.secondary)
            }
            ForEach(editor.recordingRegions, id: \.key) { region in
                let takes = editor.recordingTakes(region.key)
                let duration = storyTakeTime(Double(region.durationSamples) / Double(editor.recordingClock?.sampleRate ?? 48_000))
                Button { editor.startFromRecording(region) } label: {
                    HStack(spacing: 4) {
                        Text("Start from")
                        RecordingLabel(region: region)
                        Text("· \(duration) · \(takes.count) lines")
                    }
                }.disabled(!editor.canStartFromRecording(region))
                if let reason = editor.recordingMissingReason(region) {
                    Text(reason).foregroundStyle(.secondary)
                    Button("Locate…") { editor.locateRecording(region) }
                } else if let omission = editor.recordingOmission(takes) {
                    Text(omission).foregroundStyle(.secondary)
                }
            }
            if let pending = editor.pendingRecording {
                Button("Start from \(pending.label)") {}.disabled(true)
                if pending.transcriber.isRunning {
                    Text("Start from \(pending.label) needs its words. It's ready when transcribing finishes.")
                    Button("Cancel") { pending.transcriber.cancel() }
                } else {
                    Text("\(pending.label) isn't transcribed yet.")
                    Button(pending.transcriber.paid ? "Transcribe with ElevenLabs" : "Transcribe on this Mac") {
                        Task { await pending.transcriber.open() }
                    }
                }
            }
            ForEach(editor.recordingCompanions.filter { $0.contentKey != editor.pendingRecording?.reference.contentKey }, id: \.contentKey) { source in
                let label = ProjectClock.label(source)
                Button("Start from \(label)") {}.disabled(true)
                Text("\(label) isn't transcribed yet.")
                Button("Transcribe on this Mac") { editor.addRecording(at: editor.recordingURL(source), companion: source, onThisMac: true) }
                    .disabled(editor.addRecordingReason != nil)
            }
            Button { editor.requestBestRecordingVersions() } label: {
                Label("Make one clip from the best parts of these \(count) recordings", systemImage: "sparkle")
            }.disabled(editor.findConnector == nil || !editor.capabilities.ai)
            if editor.findConnector == nil {
                Text("Choose an AI connector in Settings › AI. Start from a recording works without one.").foregroundStyle(.secondary)
            }
            Text("or select words in any recording and press **Make Clip** ⌥⌘K").foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
    }
}
