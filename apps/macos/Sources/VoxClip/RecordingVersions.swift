import SwiftUI
import VoxClipCore
import VoxClipMedia

struct RecordingPartVersion: Identifiable {
    let recording: ProjectClock.Region
    let startWordID: String
    let endWordID: String
    let changedWordIDs: Set<String>
    let fillers: Int
    let longestPause: Double
    var id: String { recording.key }

    func edit(clipID: String, partID: String) -> RecordingEdit {
        .swapTake(clipId: clipID, partId: partID, startWordId: startWordID, endWordId: endWordID)
    }
}

extension EditorModel {
    var recordingTakeMatches: TakeMatch.Result? {
        guard hasSeveralRecordings, let clock = recordingClock else { return nil }
        if recordingMatchesClock != clock {
            recordingMatches = TakeMatch.build(clock: clock)
            recordingMatchesClock = clock
        }
        return recordingMatches
    }

    func recordingVersions(of part: ClipPart) -> [RecordingPartVersion] {
        guard let region = recordingClock?.region(of: part.startWordId), let matches = recordingTakeMatches,
              let first = index(part.startWordId), let last = index(part.endWordId) else { return [] }
        let beats = matches.beats.compactMap { beat -> (beat: TakeMatch.Beat, range: ClosedRange<Int>)? in
            guard let take = beat.takes.first(where: { $0.key == region.key }),
                  let lower = index(take.startWordId), let upper = index(take.endWordId), lower <= last, upper >= first else { return nil }
            return (beat, lower...upper)
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        guard let opening = beats.first, let closing = beats.last else { return [] }
        let whole = opening.range.lowerBound == first && closing.range.upperBound == last
        let aligned = beats.count == 1 && opening.beat.spans.contains {
            $0.toKey == region.key && $0.startWordId == part.startWordId && $0.endWordId == part.endWordId
        }
        guard whole || aligned else { return [] }
        return recordingRegions.compactMap { candidate in
            let mapped = beats.compactMap { entry -> (TakeMatch.AlignedSpan, TakeMatch.Take)? in
                guard let span = entry.beat.spans.first(where: { $0.fromKey == region.key && $0.toKey == candidate.key }),
                      let take = entry.beat.takes.first(where: { $0.key == candidate.key }) else { return nil }
                return (span, take)
            }
            guard mapped.count == beats.count, let start = mapped.first, let end = mapped.last,
                  zip(mapped, mapped.dropFirst()).allSatisfy({ previous, next in
                      guard let upper = index(previous.1.endWordId), let lower = index(next.1.startWordId) else { return false }
                      return upper + 1 == lower
                  }) else { return nil }
            return .init(recording: candidate, startWordID: start.0.startWordId, endWordID: end.0.endWordId,
                changedWordIDs: Set(mapped.flatMap { $0.0.changedWordIds }), fillers: mapped.reduce(0) { $0 + $1.1.signals.fillers },
                longestPause: mapped.map { $0.1.signals.longestPause }.max() ?? 0)
        }
    }

    func useRecordingVersion(_ version: RecordingPartVersion, partID: String) {
        guard let clip = activeClip, !recordingIsMissing(version.recording.key) else { return }
        if applyRecordingEdit(version.edit(clipID: clip.id, partID: partID)) {
            selectedStoryPartID = partID
            chooseRecordingTranscript(.recording(version.recording.key), scrollTo: version.startWordID, announceChange: false)
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
        auditionRecordingSnapshot(.init(project: outcome.project, state: changed, plan: plan), start: start, end: end)
    }

    func auditionRecordingWords(from first: String, to last: String, in candidate: Project) {
        guard let lower = index(first), let upper = index(last), let changed = try? EditState(project: candidate),
              let clip = changed.activeClip,
              let plan = try? EditPlan.build(transcript: changed.transcript, editState: changed, activeClip: clip,
                  duration: candidate.media.source.durationSeconds, sampleRate: Double(recordingClock?.sampleRate ?? 48_000)) else { return }
        let start = max(0, plan.mapTime(words[lower].start) - 1)
        let end = min(plan.duration, plan.mapTime(words[upper].end) + 1)
        guard start < end else { return }
        auditionRecordingSnapshot(.init(project: candidate, state: changed, plan: plan), start: start, end: end)
    }

    private func auditionRecordingSnapshot(_ snapshot: EditorRenderSnapshot, start: Double, end: Double) {
        let original = project
        stopRecordingAudition(restore: false)
        cancelPendingPreviewUpdate()
        recordingAuditionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = try await renderRequest(snapshot: snapshot, previewBaseline: original)
                guard project == original, !Task.isCancelled, !isLeaving else { return }
                try await preview.update(request)
                guard project == original, !Task.isCancelled, !isLeaving else { return }
                recordingAuditionEnd = end
                try await preview.seek(to: start, exact: true)
                guard project == original, !Task.isCancelled, !isLeaving else { return }
                preview.play()
                isPlaying = preview.isPlaying
            } catch is CancellationError {} catch {
                guard project == original, !Task.isCancelled, !isLeaving else { return }
                let message = await app.safeError(error, context: .preview)
                guard project == original, !Task.isCancelled, !isLeaving else { return }
                previewError = message
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
    @State private var expanded: Bool

    init(editor: EditorModel, part: ClipPart, expanded: Bool = false) {
        self.editor = editor
        self.part = part
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        let versions = editor.recordingVersions(of: part)
        if !versions.isEmpty || part.takeReason?.isEmpty == false {
            VStack(alignment: .leading, spacing: 5) {
                if let reason = part.takeReason { Text(reason).foregroundStyle(.secondary) }
                if !versions.isEmpty {
                    Button(expanded ? "Other versions" : "\(versions.count + 1) versions",
                           systemImage: expanded ? "chevron.down" : "chevron.right") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(versions.count) other versions of part \(editor.activeClip?.playParts.firstIndex(where: { $0.id == part.id }).map { $0 + 1 } ?? 1)")
                        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                }
                if expanded {
                    currentVersion
                    ForEach(versions) { version in versionRow(version) }
                }
            }
            .font(.system(size: 11))
            .padding(.leading, 20).padding(.bottom, 5)
        }
    }

    @ViewBuilder private var currentVersion: some View {
        if let clock = editor.recordingClock, let region = clock.region(of: part.startWordId),
           let first = editor.index(part.startWordId), let last = editor.index(part.endWordId) {
            let offset = Double(region.offsetSamples) / Double(clock.sampleRate)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text("Playing").foregroundStyle(.secondary)
                    RecordingLabel(region: region)
                    Text("\(storyTakeTime(editor.words[first].start - offset))–\(storyTakeTime(editor.words[last].end - offset))").monospacedDigit()
                }
                Text(editor.words[first...last].map { editor.text($0) }.joined(separator: " "))
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignValues.color("bg.muted"), in: .rect(cornerRadius: 6))
        }
    }

    @ViewBuilder private func versionRow(_ version: RecordingPartVersion) -> some View {
        if let clip = editor.activeClip, let first = editor.index(version.startWordID), let last = editor.index(version.endWordID) {
            let outcome = RecordingEdits.apply(version.edit(clipID: clip.id, partID: part.id), project: editor.project)
            let copyReason = (try? outcome.get()).flatMap { editor.recordingCopyReason(clip, part: part, changed: $0.project) }
            let missing = editor.recordingMissingReason(version.recording)
            let offset = Double(version.recording.offsetSamples) / Double(editor.recordingClock?.sampleRate ?? 48_000)
            let start = editor.words[first].start - offset, end = editor.words[last].end - offset
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    RecordingLabel(region: version.recording)
                    Text("\(storyTakeTime(start))–\(storyTakeTime(end))").monospacedDigit()
                }
                Text(editor.words[first...last].reduce(into: AttributedString()) { text, word in
                    if !text.characters.isEmpty { text += AttributedString(" ") }
                    var value = AttributedString(editor.text(word))
                    if version.changedWordIDs.contains(word.id) { value.underlineStyle = .single }
                    text += value
                })
                Text("\(version.fillers) \(version.fillers == 1 ? "filler" : "fillers") · \(toFixed1(version.longestPause)) s pause · \(toFixed1(end - start)) s")
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
