import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxClipCore
import VoxClipMedia

@MainActor final class PendingSpokenRecording {
    let reference: MediaReference
    let transcriptionEditor: EditorModel
    var label: String { ProjectClock.label(reference) }
    var transcriber: InlineTranscription { transcriptionEditor.transcription }

    init(reference: MediaReference, transcriptionEditor: EditorModel) {
        self.reference = reference
        self.transcriptionEditor = transcriptionEditor
    }

    var state: String {
        guard transcriber.isRunning else { return "Not transcribed" }
        let engine = transcriber.paid ? "Transcribing with ElevenLabs" : "Transcribing on this Mac"
        guard let progress = transcriptionEditor.progressFraction else { return engine }
        return "\(engine) · \(Int((progress.clamped(to: 0...1) * 100).rounded()))%"
    }
}

extension EditorModel {
    var recordingCompanions: [MediaReference] {
        let active = Set(recordingRegions.map(\.key))
        var seen = active
        return project.media.additionalSources.filter { seen.insert($0.contentKey).inserted }
    }

    var addRecordingReason: String? {
        if !capabilities.edit { return "This project is read-only." }
        if !transcribed { return "Transcribe the first recording before adding another." }
        if recordingRegions.count >= 6 { return "A project can have up to six spoken recordings." }
        if pendingRecording != nil || recordingImportTask != nil { return "Finish or cancel the recording you're adding first." }
        return nil
    }

    func recordingURL(_ reference: MediaReference) -> URL {
        let original = URL(fileURLWithPath: reference.absolutePath)
        if FileManager.default.fileExists(atPath: original.path) { return original }
        if let relative = reference.relativePath, let documentURL = document.fileURL {
            let candidate = documentURL.deletingLastPathComponent().appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return JSONProjectStore.footageURL(original, beside: sourceURL)
    }

    func recordingIsMissing(_ key: String) -> Bool {
        if document.demo { return false }
        if key == project.media.source.contentKey { return mediaMissing }
        guard let reference = project.media.additionalSources.first(where: { $0.contentKey == key }) else { return true }
        return !FileManager.default.fileExists(atPath: recordingURL(reference).path)
    }

    func recordingMissingReason(_ region: ProjectClock.Region) -> String? {
        recordingIsMissing(region.key) ? "\(region.label) is missing. Locate it to use its words." : nil
    }

    func removeRecordingReason(_ region: ProjectClock.Region) -> String? {
        if !capabilities.edit { return "This project is read-only." }
        let outcome = RecordingEdits.apply(.removeSpokenSource(key: region.key), project: project)
        if case .failure(let refusal) = outcome {
            for clip in project.edits.clips {
                let count = clip.playParts.filter { recordingClock?.region(of: $0.startWordId) == region }.count
                if count == 1 { return "\(scopeName(clip.id)) uses 1 part from \(region.label). Remove that part first." }
                if count > 1 { return "\(scopeName(clip.id)) uses \(count) parts from \(region.label). Remove those parts first." }
            }
            return refusal.message
        }
        return nil
    }

    func chooseRecordingFile() {
        guard addRecordingReason == nil, let url = Self.recordingFilePanel() else { return }
        addRecording(at: url)
    }

    func addRecording(at url: URL, companion: MediaReference? = nil, onThisMac: Bool = false) {
        guard addRecordingReason == nil, url.isFileURL else { return }
        recordingImportError = nil
        recordingImportTask = Task { [weak self] in
            guard let self else { return }
            defer { recordingImportTask = nil }
            do {
                let imported = try await VoxClipDocument(importing: url)
                let probe = try await AVMediaProbe().probe(url)
                try Task.checkCancellation()
                var source = imported.project.media.source
                guard source.contentKey != project.media.source.contentKey,
                      !recordingRegions.contains(where: { $0.key == source.contentKey }) else {
                    recordingImportError = "This recording is already in the transcript."
                    return
                }
                guard probe.isPlayable, probe.video != nil, probe.audio != nil, probe.durationSeconds > 0 else {
                    recordingImportError = "Choose a video with audio to add a recording."
                    return
                }
                if let companion {
                    guard companion.contentKey == source.contentKey else { throw VoxClipError.mediaMissing(ProjectClock.label(companion)) }
                    source = companion
                    source.absolutePath = url.path
                }
                source.durationSeconds = probe.durationSeconds
                source.video = probe.video
                source.audio = probe.audio
                let key = source.contentKey, cache = app.locations.cache, recent = app.recent
                let cached = await Task.detached(priority: .utility) {
                    RecordingTranscriptCache.read(key, cache: cache, recent: recent)
                }.value
                try Task.checkCancellation()
                if let cached, try await commitRecording(source, transcript: cached) { return }
                var scratch = imported.project
                scratch.media.source = source
                imported.replaceProject(scratch)
                let transcribing = EditorModel(document: imported, app: app, preview: DemoPreviewEngine())
                transcribing.markRecordingMediaReady()
                let pending = PendingSpokenRecording(reference: source, transcriptionEditor: transcribing)
                transcribing.recordingTranscriptRecipient = { [weak self, weak pending] transcript in
                    guard let self, let pending, pendingRecording === pending else { return }
                    Task { [weak self, weak pending] in
                        guard let self, let pending, pendingRecording === pending else { return }
                        _ = try? await commitRecording(pending.reference, transcript: transcript, pending: pending)
                    }
                }
                pendingRecording = pending
                await pending.transcriber.open(automatic: true, onThisMac: onThisMac)
                pending.transcriber.remember = false
            } catch is CancellationError {} catch {
                recordingImportError = await app.safeError(error, context: .importMedia)
            }
        }
    }

    private func commitRecording(_ source: MediaReference, transcript: Transcript, pending: PendingSpokenRecording? = nil) async throws -> Bool {
        let label = ProjectClock.label(source)
        let original = project
        let gain = try? await RecordingLoudness.match(primary: sourceURL, project: original,
            recording: URL(fileURLWithPath: source.absolutePath), transcript: transcript)
        try Task.checkCancellation()
        guard !isLeaving, pendingRecording === pending, project.media.source.contentKey == original.media.source.contentKey else { return false }
        var base = project
        if let existing = base.media.additionalSources.firstIndex(where: { $0.contentKey == source.contentKey }) {
            base.media.additionalSources[existing] = source
        } else {
            base.media.additionalSources.append(source)
        }
        if applyRecordingEdit(.addSpokenSource(key: source.contentKey, label: nil, transcript: transcript, gainDb: gain),
                              preparing: base, message: "Added recording \(label)") {
            pendingRecording = nil
            recordingImportError = nil
            chooseRecordingTranscript(.recording(source.contentKey), announceChange: false)
            return true
        } else {
            recordingImportError = storyPartError
            return false
        }
    }

    func resetRecordingLevel(_ region: ProjectClock.Region) {
        guard capabilities.edit, let index = project.media.spokenSources?.firstIndex(where: { $0.sourceKey == region.key }),
              let gain = project.media.spokenSources?[index].gainDb, gain != 0 else { return }
        var next = project
        next.media.spokenSources?[index].gainDb = 0
        replace(next, name: "Don't match level")
    }

    func cancelRecordingImport() {
        recordingImportTask?.cancel()
        pendingRecording?.transcriber.close()
        pendingRecording = nil
    }

    func locateRecording(_ region: ProjectClock.Region) {
        if region.key == project.media.source.contentKey { locateMedia(); return }
        guard capabilities.edit, let url = Self.recordingFilePanel() else { return }
        Task {
            do {
                let key = try await Task.detached(priority: .userInitiated) { try JSONProjectStore.contentKey(for: url) }.value
                guard key == region.key, let index = project.media.additionalSources.firstIndex(where: { $0.contentKey == key }) else {
                    recordingImportError = "Choose the original file for \(region.label). Your edits are safe."
                    return
                }
                var next = project
                next.media.additionalSources[index].absolutePath = url.path
                replace(next, name: "Locate media")
                recordingImportError = nil
            } catch { recordingImportError = await app.safeError(error, context: .importMedia) }
        }
    }

    func openRecordingOnItsOwn(_ region: ProjectClock.Region) {
        guard !recordingIsMissing(region.key), let source = project.media.additionalSources.first(where: { $0.contentKey == region.key }) else { return }
        openMovie(recordingURL(source), app: app)
    }

    private static func recordingFilePanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor struct AddRecordingMenu: View {
    let editor: EditorModel

    var body: some View {
        Menu {
            ForEach(editor.recordingCompanions, id: \.contentKey) { source in
                Button("\(ProjectClock.label(source)) · in this project as B-roll") {
                    editor.addRecording(at: editor.recordingURL(source), companion: source)
                }
            }
            Button("Choose a file…") { editor.chooseRecordingFile() }
        } label: { Label("Add a recording", systemImage: "plus").font(.system(size: 11)) }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(editor.addRecordingReason != nil)
        .accessibilityHint(editor.addRecordingReason ?? "")
    }
}
