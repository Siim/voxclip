import SwiftUI
import VoxClipCore

struct RecordingClipLine: Identifiable, Equatable {
    let beat: TakeMatch.Beat
    let number: Int
    let partID: String
    let take: TakeMatch.Take
    let start: String
    let end: String

    var id: String { beat.id }
    var alternatives: [TakeMatch.Take] {
        beat.takes.filter { candidate in span(to: candidate.key) != nil }
    }
    func span(to key: String) -> TakeMatch.AlignedSpan? {
        beat.spans.first { $0.fromKey == take.key && $0.toKey == key }
    }
}

struct RecordingOmittedLine: Identifiable, Equatable {
    let take: TakeMatch.Take
    let after: String
    var id: String { take.startWordId }
    var label: String { take.flags.contains("restart") ? "restart" : "false start" }
}

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
        guard recordingRegions.count > 1 else { return }
        findClips(preset: .bestTakes, instruction: "")
    }

    var recordingClipLines: [RecordingClipLine] {
        guard let clip = activeClip, let matches = recordingTakeMatches,
              let bounds = clip.playPartIndices(in: words) else { return [] }
        var seen: Set<String> = []
        var result: [RecordingClipLine] = []
        for (part, range) in zip(clip.playParts, bounds) {
            guard let key = recordingClock?.region(of: part.startWordId)?.key else { continue }
            let lines = matches.beats.compactMap { beat -> (TakeMatch.Beat, TakeMatch.Take, ClosedRange<Int>)? in
                guard !seen.contains(beat.id), let take = beat.takes.first(where: { $0.key == key }) else { return nil }
                @MainActor func contained(_ start: String, _ end: String) -> ClosedRange<Int>? {
                    guard let first = index(start), let last = index(end), first <= last,
                          range.contains(first), range.contains(last) else { return nil }
                    return first...last
                }
                let span = contained(take.startWordId, take.endWordId) ?? beat.spans.lazy.filter { $0.toKey == key }
                    .compactMap { contained($0.startWordId, $0.endWordId) }.max { $0.count < $1.count }
                return span.map { (beat, take, $0) }
            }.sorted { $0.2.lowerBound < $1.2.lowerBound }
            for (beat, take, line) in lines {
                seen.insert(beat.id)
                result.append(.init(beat: beat, number: result.count + 1, partID: part.id, take: take,
                                    start: words[line.lowerBound].id, end: words[line.upperBound].id))
            }
        }
        return result
    }

    var recordingOmittedLines: [RecordingOmittedLine] {
        guard let clip = activeClip, clip.id.hasPrefix("recording-clip"), let clock = recordingClock else { return [] }
        let parts = clip.playParts
        let keys = Set(parts.compactMap { clock.region(of: $0.startWordId)?.key })
        return keys.flatMap(recordingTakes).compactMap { take in
            guard take.flags.contains("restart") || take.flags.contains("falseStart"), let first = index(take.startWordId),
                  !parts.contains(where: { part in index(part.startWordId).map { $0 <= first } == true && index(part.endWordId).map { $0 >= first } == true }),
                  let before = parts.first(where: { index($0.endWordId) == first - 1 }) else { return nil }
            return .init(take: take, after: before.endWordId)
        }.sorted { (index($0.id) ?? 0) < (index($1.id) ?? 0) }
    }

    var otherRecordingLines: [TakeMatch.SoloRun] {
        guard let bounds = activeClip?.playPartIndices(in: words) else { return [] }
        let lines = recordingClipLines
        let runs = recordingTakeMatches?.solo.filter { run in
            guard let first = index(run.startWordId), let last = index(run.endWordId) else { return false }
            return !bounds.contains { $0.lowerBound <= last && first <= $0.upperBound }
        } ?? []
        let order = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.number) })
        return runs.sorted { (order[$0.afterBeatId ?? ""] ?? Int.max) < (order[$1.afterBeatId ?? ""] ?? Int.max) }
    }

    var otherRecordingLinesExpanded: Bool {
        get { app.bool("outline.otherRecordings.\(project.id)") }
        set { app.set("outline.otherRecordings.\(project.id)", .bool(newValue)) }
    }

    func wordsBetween(_ first: String, _ last: String) -> ArraySlice<TimedWord> {
        guard let lower = index(first), let upper = index(last), lower <= upper else { return [] }
        return words[lower...upper]
    }

    func recordingLineText(_ first: String, _ last: String) -> String {
        wordsBetween(first, last).map { text($0) }.joined(separator: " ")
    }

    func recordingLineTime(_ first: String, _ last: String, region: ProjectClock.Region) -> String {
        let offset = Double(region.offsetSamples) / Double(recordingClock?.sampleRate ?? 48_000)
        let words = wordsBetween(first, last)
        return "\(storyTakeTime((words.first?.start ?? offset) - offset))–\(storyTakeTime((words.last?.end ?? offset) - offset))"
    }

    func putBackRecordingLine(_ line: RecordingOmittedLine) {
        guard let clip = activeClip, !recordingIsMissing(line.take.key) else { return }
        applyRecordingEdit(.insertLine(clipId: clip.id, key: line.take.key,
                                      startWordId: line.take.startWordId, endWordId: line.take.endWordId, afterWordId: line.after),
                           message: "\(line.label.capitalized) put back in \(scopeName(clip.id)).")
    }

    func recordingLineEdit(_ line: RecordingClipLine, key: String) -> RecordingEdit? {
        guard let clip = activeClip, line.span(to: key) != nil, !recordingIsMissing(key) else { return nil }
        return .useLineVersion(clipId: clip.id, beatId: line.id, key: key)
    }

    func recordingVersionsAccessibility(_ line: RecordingClipLine) -> String {
        let labels = line.alternatives.compactMap { take in recordingRegions.first { $0.key == take.key }?.label }
        return "Line \(line.number), \(labels.count) other version\(labels.count == 1 ? "" : "s"), in \(ListFormatter.localizedString(byJoining: labels))"
    }

    func showRecordingLineVersions(_ line: RecordingClipLine) {
        recordingOpenLineID = line.id
        recordingSelectedVersionKey = line.alternatives.first?.key
        announce(recordingVersionsAccessibility(line))
    }

    func handleRecordingVersionKey(_ key: RecordingVersionKey, for line: RecordingClipLine) {
        let takes = [line.take] + line.alternatives
        let selected = takes.firstIndex { $0.key == recordingSelectedVersionKey } ?? 0
        switch key {
        case .up: recordingSelectedVersionKey = takes[max(0, selected - 1)].key
        case .down: recordingSelectedVersionKey = takes[min(takes.count - 1, selected + 1)].key
        case .play: playRecordingLineVersion(line, key: takes[selected].key)
        case .use: useRecordingLineVersion(line, key: takes[selected].key)
        case .close:
            recordingOpenLineID = nil
            stopRecordingAudition()
        }
    }

    func recordingLineWithVersions(at wordID: String?) -> RecordingClipLine? {
        guard let wordID, let position = index(wordID), transcriptRecordingScope == .playOrder else { return nil }
        return recordingClipLines.first { line in
            !line.alternatives.isEmpty && index(line.start).map { $0 <= position } == true && index(line.end).map { $0 >= position } == true
        }
    }

    func playRecordingLineVersion(_ line: RecordingClipLine, key: String) {
        if key == line.take.key {
            auditionRecordingWords(from: line.start, to: line.end, in: project)
        } else if let span = line.span(to: key), let edit = recordingLineEdit(line, key: key),
                  let outcome = try? RecordingEdits.apply(edit, project: project).get() {
            auditionRecordingWords(from: span.startWordId, to: span.endWordId, in: outcome.project)
        }
    }

    func recordingLineCopyReason(_ line: RecordingClipLine, key: String) -> String? {
        guard let clip = activeClip, let part = clip.playParts.first(where: { $0.id == line.partID }),
              let edit = recordingLineEdit(line, key: key),
              let outcome = try? RecordingEdits.apply(edit, project: project).get() else { return nil }
        return recordingCopyReason(clip, part: part, changed: outcome.project)
    }

    func useRecordingLineVersion(_ line: RecordingClipLine, key: String) {
        guard let edit = recordingLineEdit(line, key: key), let region = recordingRegions.first(where: { $0.key == key }),
              let clip = activeClip else { return }
        let part = (clip.playParts.firstIndex { $0.id == line.partID } ?? 0) + 1
        if applyRecordingEdit(edit, feedback: { outcome in
            let message = "Line \(line.number) now uses \(region.label)'s version" + (outcome.details?.splitPartId == nil ? "" : " · part \(part) split")
            return (message, message)
        }) {
            recordingOpenLineID = nil
            chooseRecordingTranscript(.playOrder, scrollTo: line.span(to: key)?.startWordId, announceChange: false)
        }
    }

    func recordingPlacement(_ run: TakeMatch.SoloRun) -> String? {
        activeClip.flatMap { RecordingEdits.placement(clipId: $0.id, soloRun: run, project: project) }
    }

    func playRecordingLineThere(_ run: TakeMatch.SoloRun) {
        guard let clip = activeClip, !recordingIsMissing(run.key), let after = recordingPlacement(run),
              let outcome = try? RecordingEdits.apply(.insertLine(clipId: clip.id, key: run.key, startWordId: run.startWordId,
                                                                  endWordId: run.endWordId, afterWordId: after), project: project).get() else { return }
        auditionRecordingWords(from: run.startWordId, to: run.endWordId, in: outcome.project)
    }

    func recordingPlacementQuote(_ run: TakeMatch.SoloRun) -> String? {
        let line = recordingClipLines.first { $0.id == run.afterBeatId }
        let take = recordingTakeMatches?.beats.first { $0.id == run.afterBeatId }?.takes.first { $0.key == run.key }
        let words = line.map { wordsBetween($0.start, $0.end) } ?? take.map { wordsBetween($0.startWordId, $0.endWordId) } ?? []
        guard !words.isEmpty else { return nil }
        let phrase = words.suffix(4).map { text($0) }.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
        return "“\(words.count > 4 ? "…" : "")\(phrase)”"
    }

    func insertRecordingLine(_ run: TakeMatch.SoloRun, atEnd: Bool = false) {
        guard let clip = activeClip, !recordingIsMissing(run.key) else { return }
        let after = atEnd ? nil : recordingPlacement(run)
        guard atEnd || after != nil else { return }
        let quote = recordingPlacementQuote(run)
        let label = recordingRegions.first { $0.key == run.key }?.label ?? run.key
        applyRecordingEdit(.insertLine(clipId: clip.id, key: run.key, startWordId: run.startWordId, endWordId: run.endWordId, afterWordId: after),
                           feedback: { _ in
            let number = self.activeClip?.playParts.firstIndex { part in
                self.wordsBetween(part.startWordId, part.endWordId).contains { $0.id == run.startWordId }
            }.map { $0 + 1 } ?? 1
            let suffix = atEnd ? "at the end" : quote.map { "after \($0)" } ?? "in place"
            let message = "Part \(number) added from \(label), \(suffix)"
            return (message, message)
        })
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
