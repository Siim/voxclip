import SwiftUI
import VoxClipCore

@MainActor @Observable final class VoxConvoExportState {
    struct Approval {
        let handle: String
        let text: String
        let addDisclosure: Bool
    }

    struct Finished {
        let target: ExportTarget
        let fingerprint: String
        let draft: VoxConvoPublishDraft
        let fileStamp: FileStamp?

        var fileUnchanged: Bool {
            guard let fileStamp else { return false }
            return FileStamp(draft.file) == fileStamp
        }
    }

    struct FileStamp: Equatable {
        let size: NSNumber
        let inode: NSNumber
        let modified: Date

        init?(_ file: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            self.size = size; self.inode = inode; self.modified = modified
        }
    }

    var optedInHandle: String?
    var addDisclosure = false
    var text = ""
    var draftTarget: ExportTarget?
    var approval: Approval?
    var finished: Finished?
    var uploaded: VoxConvoUploadedVideo?
    var progress: String?
    var finalPost = false
    var postedURL: URL?
    var error: String?
    var running = false

    func capture(_ approval: Approval, target: ExportTarget, fingerprint: String, result: ExportResult,
                 render: RenderRequest, snapshot: EditorRenderSnapshot) {
        self.approval = approval
        let sourceWords = render.captions.words.isEmpty ? snapshot.exportedWords(target: target, render: render) : render.captions.words
        let words = sourceWords.map {
            CaptionWord(id: $0.id, text: $0.text, start: min(result.durationSeconds, $0.start / render.speed),
                        end: min(result.durationSeconds, $0.end / render.speed))
        }.filter { $0.end > $0.start }
        let transcript = words.map(\.text).joined(separator: " ")
        let disclosure = approval.addDisclosure ? render.voiceLab?.prepared.disclosure.postText : nil
        let credit = render.music?.entry.creditLine
        let suffix = [disclosure, credit].compactMap { $0 }.filter { !approval.text.contains($0) }.joined(separator: "\n\n")
        let withSuffix = suffix.isEmpty ? approval.text : [approval.text, suffix].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let caption = (try? SharePostText.composerText(withSuffix, destination: .voxConvo, disclosureLine: suffix.isEmpty ? nil : suffix)) ?? withSuffix
        let draft = VoxConvoPublishDraft(file: result.outputURL, duration: result.durationSeconds, text: caption, transcript: transcript, words: words)
        finished = Finished(target: target, fingerprint: fingerprint, draft: draft, fileStamp: FileStamp(result.outputURL))
    }
}

extension EditorRenderSnapshot {
    func exportedWords(target: ExportTarget, render: RenderRequest) -> [CaptionWord] {
        let effects = render.effects?.effects ?? []
        if render.clipControls?.muteSource == true { return [] }
        if let voice = render.voiceLab?.prepared.outputPlan { return ClipEffects.maskingBleeps(voice, effects: effects).captions }
        let clip = project.edits.clips.first { $0.id == ExportLedger.clipID(target) }
        if let state, let segments = try? buildSegments(state, activeClip: clip) {
            return captionCopy(ClipEffects.maskingBleeps(segments, effects: effects), plan: render.plan)
        }
        return []
    }
}

@MainActor struct VoxConvoExportOffer: View {
    let model: EditorModel
    let targets: [ExportTarget]
    private var state: VoxConvoExportState { model.exportJob.voxConvo }
    private var handle: String? { model.app.voxConvo.handle }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(toggleTitle, isOn: Binding(get: { approval != nil }, set: { select($0) }))
                .disabled(!VoxConvoConnection.available || handle == nil || targets.count != 1)
            if !VoxConvoConnection.available {
                Text(VoxConvoConnection.unavailableReason).foregroundStyle(.secondary)
            } else if handle == nil {
                Text("Connect VoxConvo in Accounts settings to post here.").foregroundStyle(.secondary)
                Button("Accounts Settings") { openVoxClipSettings(pane: "accounts") }
            } else if targets.count != 1 {
                Text("Choose one video to post to VoxConvo.").foregroundStyle(.secondary)
            } else if approval != nil {
                TextField("Post text", text: Binding(get: { state.text }, set: { state.text = String($0.prefix(2_048)) }), axis: .vertical)
                if model.exportDisclosure(targets) != nil {
                    Toggle("Add 'AI MODIFIED' line to the post", isOn: Binding(get: { state.addDisclosure }, set: { state.addDisclosure = $0 }))
                }
                Text("Export & post uploads this video and its edited transcript to VoxConvo.").foregroundStyle(.secondary)
            }
        }.task { await model.app.voxConvo.refresh() }
    }

    var approval: VoxConvoExportState.Approval? {
        guard VoxConvoConnection.available, let handle, state.optedInHandle == handle, targets.count == 1, state.draftTarget == targets.first else { return nil }
        return VoxConvoExportState.Approval(handle: handle, text: state.text, addDisclosure: state.addDisclosure)
    }

    private var toggleTitle: String { handle.map { "Also post to VoxConvo @\($0)" } ?? "Also post to VoxConvo" }

    private func select(_ enabled: Bool) {
        state.optedInHandle = enabled ? handle : nil
        guard enabled, let target = targets.first else { return }
        if state.draftTarget != target {
            state.text = ""
            state.addDisclosure = false
        }
        state.draftTarget = target
    }
}

@MainActor struct VoxConvoExportReview: View {
    let model: EditorModel
    private var state: VoxConvoExportState { model.exportJob.voxConvo }
    var body: some View {
        if let url = state.postedURL {
            Link("Posted · Open", destination: url)
        } else if let progress = state.progress {
            ProgressView(progress)
        } else if let error = state.error {
            InlineNotice(text: error)
            let reason = model.publishUnavailable(state)
            Button("Try posting again") { Task { await model.postVoxConvo(state) } }.disabled(reason != nil)
            if let reason { Text(reason).foregroundStyle(.secondary) }
        }
    }
}

extension EditorModel {
    func publishUnavailable(_ state: VoxConvoExportState) -> String? {
        guard VoxConvoConnection.available else { return VoxConvoConnection.unavailableReason }
        guard !state.running, let finished = state.finished, finished.fileUnchanged else { return "Export the video again before posting." }
        guard let approval = state.approval, app.voxConvo.handle == approval.handle else { return "Reconnect the same VoxConvo account before posting." }
        guard (try? ExportFingerprint.value(project, target: finished.target, labelPosition: app.voiceLabLabelPosition)) == finished.fingerprint else {
            return "This edit changed after export. Export it again before posting."
        }
        return nil
    }

    func postVoxConvo(_ state: VoxConvoExportState) async {
        guard !state.running, state.postedURL == nil, let finished = state.finished else { return }
        let folder = finished.draft.file.deletingLastPathComponent().lastPathComponent
        if let reason = publishUnavailable(state) {
            state.error = "Saved to \(folder). Posting to VoxConvo failed: \(reason)"
            return
        }
        let connection = app.voxConvo
        state.running = true; state.error = nil; state.progress = "Preparing upload…"
        defer { state.running = false; state.progress = nil; state.finalPost = false }
        do {
            guard let token = try await connection.session() else { throw VoxConvoPublishError.unauthorized }
            let uploaded: VoxConvoUploadedVideo
            if let prior = state.uploaded, prior.isReusable(file: finished.draft.file, session: token) { uploaded = prior }
            else {
                uploaded = try await connection.api.prepare(finished.draft, session: token) { [weak state] progress in
                    Task { @MainActor in
                        guard let state, state.running, !state.finalPost else { return }
                        switch progress {
                        case .uploading(let percent): state.progress = "Uploading \(percent)%"
                        case .processing: state.progress = "Processing…"
                        }
                    }
                }
                state.uploaded = uploaded
            }
            try Task.checkCancellation()
            guard finished.fileUnchanged, (try? ExportFingerprint.value(project, target: finished.target,
                    labelPosition: app.voiceLabLabelPosition)) == finished.fingerprint else { throw VoxConvoPublishError.invalidVideo }
            guard connection.handle == state.approval?.handle, try await connection.session() == token else { throw VoxConvoPublishError.unauthorized }
            state.finalPost = true; state.progress = "Posting…"
            let url = try await connection.api.post(finished.draft, uploaded: uploaded, session: token)
            state.postedURL = url
            announce("Posted to VoxConvo")
            NSWorkspace.shared.open(url)
        } catch is CancellationError {} catch let error as URLError where error.code == .cancelled {} catch {
            if error as? VoxConvoPublishError == .unauthorized { await connection.show(error) }
            state.error = "Saved to \(folder). Posting to VoxConvo failed: \(VoxConvoConnection.message(error))"
            if let error = state.error { announce(error) }
        }
    }
}
