import SwiftUI
import VoxClipCore
import VoxClipMedia

struct RecordingPartVersion: Identifiable {
    let recording: ProjectClock.Region
    let span: TakeMatch.AlignedSpan
    let signals: TakeMatch.DeliverySignals
    var id: String { recording.key }

    func edit(clipID: String, partID: String) -> RecordingEdit {
        .swapTake(clipId: clipID, partId: partID, startWordId: span.startWordId, endWordId: span.endWordId)
    }
}

extension EditorModel {
    func recordingVersions(of part: ClipPart) -> [RecordingPartVersion] {
        guard hasSeveralRecordings, let clock = recordingClock, let region = clock.region(of: part.startWordId) else { return [] }
        if recordingMatchesClock != clock {
            recordingMatches = TakeMatch.build(clock: clock)
            recordingMatchesClock = clock
        }
        guard let beat = recordingMatches?.beats.first(where: { beat in
            beat.takes.contains { $0.key == region.key && $0.startWordId == part.startWordId && $0.endWordId == part.endWordId }
                || beat.spans.contains { $0.toKey == region.key && $0.startWordId == part.startWordId && $0.endWordId == part.endWordId }
        }) else { return [] }
        return recordingRegions.compactMap { candidate in
            guard let span = beat.spans.first(where: { $0.fromKey == region.key && $0.toKey == candidate.key }),
                  let take = beat.takes.first(where: { $0.key == candidate.key }) else { return nil }
            return .init(recording: candidate, span: span, signals: take.signals)
        }
    }

    func useRecordingVersion(_ version: RecordingPartVersion, partID: String) {
        guard let clip = activeClip, !recordingIsMissing(version.recording.key) else { return }
        if applyRecordingEdit(version.edit(clipID: clip.id, partID: partID)) {
            selectedStoryPartID = partID
            chooseRecordingTranscript(.recording(version.recording.key), scrollTo: version.span.startWordId, announceChange: false)
        }
    }

    func recordingCopyReason(_ clip: ClipRange, part: ClipPart, changed: Project) -> String? {
        guard changed.edits.activeClipId != clip.id, let copy = changed.edits.clips.first(where: { $0.id == changed.edits.activeClipId }),
              let position = clip.playParts.firstIndex(where: { $0.id == part.id }),
              let first = index(part.startWordId), let last = index(part.endWordId) else { return nil }
        let rate = Double(recordingClock?.sampleRate ?? 48_000)
        let start = words[first].start, end = words[last].end
        let window = project.voiceLab.segments.flatMap(\.candidates).compactMap { candidate -> TimeRange? in
            guard let video = candidate.recipe?.video, video.mode == .lipsync,
                  let lower = video.windowStartSample, let upper = video.windowEndSample,
                  Double(lower) / rate < end, Double(upper) / rate > start else { return nil }
            return .init(start: Double(lower) / rate, end: Double(upper) / rate)
        }.first ?? TimeRange(start: start, end: end)
        let label = scopeName(clip.id)
        return "Part \(position + 1) is lip-synced at \(storyTakeTime(window.start))–\(storyTakeTime(window.end)). Using another version makes a copy, “\(copy.title ?? label + " copy")”, and keeps the paid lip sync in \(label)."
    }

    func playRecordingVersion(_ version: RecordingPartVersion, partID: String) {
        guard let clip = activeClip, let position = clip.playParts.firstIndex(where: { $0.id == partID }),
              !recordingIsMissing(version.recording.key),
              let outcome = try? RecordingEdits.apply(version.edit(clipID: clip.id, partID: partID), project: project).get(),
              let changed = try? EditState(project: outcome.project), let candidate = changed.activeClip,
              let plan = try? EditPlan.build(transcript: changed.transcript, editState: changed, activeClip: candidate,
                  duration: outcome.project.media.source.durationSeconds, sampleRate: Double(recordingClock?.sampleRate ?? 48_000)),
              plan.partSeams.count == candidate.playParts.count - 1 else { return }
        let boundaries = [0] + plan.partSeams.map { Double($0) / plan.sampleRate } + [plan.duration]
        let start = position == 0 ? 0 : max(boundaries[position - 1], boundaries[position] - 1)
        let end = min(plan.duration, boundaries[position + 1] + 1)
        let snapshot = EditorRenderSnapshot(project: outcome.project, state: changed, plan: plan)
        let original = project
        stopRecordingAudition(restore: false)
        cancelPendingPreviewUpdate()
        recordingAuditionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = try await renderRequest(snapshot: snapshot)
                guard project == original, !Task.isCancelled, !isLeaving else { return }
                try await preview.update(request)
                guard project == original, !Task.isCancelled, !isLeaving else { return }
                recordingAuditionEnd = end
                try await preview.seek(to: start, exact: true)
                guard !Task.isCancelled else { return }
                preview.play()
                isPlaying = preview.isPlaying
            } catch is CancellationError {} catch {
                previewError = await app.safeError(error, context: .preview)
                stopRecordingAudition()
            }
        }
    }

    func stopRecordingAudition(restore: Bool = true) {
        guard recordingAuditionTask != nil || recordingAuditionEnd != nil else { return }
        recordingAuditionTask?.cancel()
        recordingAuditionTask = nil
        recordingAuditionEnd = nil
        preview.pause()
        isPlaying = false
        if restore { schedulePreviewUpdate(mediaChanged: false) }
    }
}

@MainActor struct RecordingPartVersions: View {
    let editor: EditorModel
    let part: ClipPart
    @State private var expanded = false

    var body: some View {
        let versions = editor.recordingVersions(of: part)
        if !versions.isEmpty || part.takeReason?.isEmpty == false {
            VStack(alignment: .leading, spacing: 5) {
                if let reason = part.takeReason { Text(reason).foregroundStyle(.secondary) }
                if !versions.isEmpty {
                    Button(expanded ? "Other versions" : "\(versions.count) \(versions.count == 1 ? "version" : "versions")",
                           systemImage: expanded ? "chevron.down" : "chevron.right") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(versions.count) other versions of part \(editor.activeClip?.playParts.firstIndex(where: { $0.id == part.id }).map { $0 + 1 } ?? 1)")
                        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                }
                if expanded { ForEach(versions) { version in versionRow(version) } }
            }
            .font(.system(size: 11))
            .padding(.leading, 20).padding(.bottom, 5)
        }
    }

    @ViewBuilder private func versionRow(_ version: RecordingPartVersion) -> some View {
        if let clip = editor.activeClip, let first = editor.index(version.span.startWordId), let last = editor.index(version.span.endWordId) {
            let outcome = RecordingEdits.apply(version.edit(clipID: clip.id, partID: part.id), project: editor.project)
            let copyReason = (try? outcome.get()).flatMap { editor.recordingCopyReason(clip, part: part, changed: $0.project) }
            let missing = editor.recordingMissingReason(version.recording)
            let offset = Double(version.recording.offsetSamples) / Double(editor.recordingClock?.sampleRate ?? 48_000)
            let start = editor.words[first].start - offset, end = editor.words[last].end - offset
            let changed = Set(version.span.changedWordIds)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    RecordingLabel(region: version.recording)
                    Text("\(storyTakeTime(start))–\(storyTakeTime(end))").monospacedDigit()
                }
                Text(editor.words[first...last].reduce(into: AttributedString()) { text, word in
                    if !text.characters.isEmpty { text += AttributedString(" ") }
                    var value = AttributedString(editor.text(word))
                    if changed.contains(word.id) { value.underlineStyle = .single }
                    text += value
                })
                Text("\(version.signals.fillers) \(version.signals.fillers == 1 ? "filler" : "fillers") · \(toFixed1(version.signals.longestPause)) s pause · \(toFixed1(end - start)) s")
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { versionActions(version, copy: copyReason != nil, disabled: missing != nil || (try? outcome.get()) == nil) }
                    VStack(alignment: .leading) { versionActions(version, copy: copyReason != nil, disabled: missing != nil || (try? outcome.get()) == nil) }
                }
                if let reason = missing ?? copyReason ?? outcome.failureMessage {
                    Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if missing != nil { Button("Locate…") { editor.locateRecording(version.recording) } }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignValues.color("bg.muted"), in: .rect(cornerRadius: 6))
        }
    }

    @ViewBuilder private func versionActions(_ version: RecordingPartVersion, copy: Bool, disabled: Bool) -> some View {
        Button("Play in Place", systemImage: "play.fill") { editor.playRecordingVersion(version, partID: part.id) }
            .disabled(disabled)
        Button(copy ? "Use in a Copy" : "Use This Version") { editor.useRecordingVersion(version, partID: part.id) }
            .disabled(disabled || !editor.capabilities.edit)
    }
}

private extension Result where Failure == RecordingEditRefusal {
    var failureMessage: String? { if case .failure(let refusal) = self { refusal.message } else { nil } }
}
