import Foundation

extension EditState {
    public init(transcript: Transcript, edits: ProjectEdits) throws {
        self.init(transcript: transcript, pauses: try detectPauses(transcript.words, thresholdSeconds: edits.pauseThresholdSeconds),
                  pauseThresholdSeconds: edits.pauseThresholdSeconds, pauseKeepSeconds: edits.pauseKeepSeconds,
                  cutWordIds: Set(edits.cutWordIds), cutPauseIds: Set(edits.cutPauseIds), corrections: edits.corrections, clips: edits.clips, activeClipId: edits.activeClipId)
    }

    public var activeClip: ClipRange? { clips.first { $0.id == activeClipId } }
    public func textOf(_ word: TimedWord) -> String { corrections[word.id] ?? word.text }
    public var transcriptText: String { transcript.words.filter { $0.kind == .word }.map(textOf).joined(separator: " ") }
    public var projectEdits: ProjectEdits {
        ProjectEdits(pauseThresholdSeconds: pauseThresholdSeconds, pauseKeepSeconds: pauseKeepSeconds,
                     cutWordIds: transcript.words.map(\.id).filter { cutWordIds.contains($0) }, cutPauseIds: pauses.map(\.id).filter { cutPauseIds.contains($0) },
                     corrections: corrections, clips: clips, activeClipId: activeClipId)
    }
    func filler(_ word: TimedWord) -> Bool { word.kind == .unlabeledSpeech || (word.kind == .word && EditingPrimitives.filler(textOf(word))) }

    public var summary: EditSummary {
        let bounds = clipIndices(activeClip, words: transcript.words)
        let words = transcript.words.enumerated().filter { inScope($0.offset, bounds: bounds) }.map(\.element)
        let scopedPauses = pauses.filter { pauseInScope($0, bounds: bounds) }
        let fillers = words.filter { !cutWordIds.contains($0.id) && filler($0) }.count
        let cutWords = words.filter { cutWordIds.contains($0.id) }.count
        let cutPauses = scopedPauses.filter { cutPauseIds.contains($0.id) }.count
        return EditSummary(fillerCount: fillers, cutWordCount: cutWords, pauseCount: scopedPauses.count, cutPauseCount: cutPauses,
                           canCutFillers: fillers > 0, canTighten: !scopedPauses.isEmpty && cutPauses != scopedPauses.count,
                           hasEdits: cutWords > 0 || cutPauses > 0, canExport: words.isEmpty || cutWords != words.count)
    }
}

func inScope(_ index: Int, bounds: ClosedRange<Int>?) -> Bool { bounds?.contains(index) ?? true }
func pauseInScope(_ pause: Pause, bounds: ClosedRange<Int>?) -> Bool {
    inScope(pause.afterIndex, bounds: bounds) && inScope(pause.afterIndex + 1, bounds: bounds)
}

func reduceEditingState(_ state: EditState, command: EditCommand, aiResults: [ProjectAIResult]? = nil) -> EditState {
    var result = state
    let words = state.transcript.words
    let bounds = clipIndices(state.activeClip, words: words)
    let wordIDs = Set(words.map(\.id)), pauseIDs = Set(state.pauses.map(\.id))
    func isCut(_ id: String) -> Bool { pauseIDs.contains(id) ? result.cutPauseIds.contains(id) : wordIDs.contains(id) && result.cutWordIds.contains(id) }
    func setCut(_ id: String, _ cut: Bool) {
        if pauseIDs.contains(id) {
            if cut { result.cutPauseIds.insert(id) } else { result.cutPauseIds.remove(id) }
        } else if wordIDs.contains(id) {
            if cut { result.cutWordIds.insert(id) } else { result.cutWordIds.remove(id) }
        }
    }
    func validClipID(_ id: String) -> Bool { id.range(of: "\\A(?:" + EditingLimits.clipIDPattern + ")\\z", options: .regularExpression) != nil }
    func validClip(_ clip: ClipRange) -> Bool {
        guard validClipID(clip.id), (clip.title?.unicodeScalars.count ?? 0) <= EditingLimits.maxClipTitleScalars,
              clipIndices(clip, words: words) != nil, clip.aiResultId.map(validClipID) ?? true,
              (clip.aiClipIndex ?? 0) >= 0 else { return false }
        guard let aiResults else { return true }
        guard let id = clip.aiResultId else { return clip.aiClipIndex == nil }
        guard let result = aiResults.first(where: { $0.id == id }) else { return false }
        return clip.aiClipIndex.map { result.clips.indices.contains($0) } ?? true
    }
    switch command {
    case .toggle(let id): setCut(id, !isCut(id))
    case .cutSelection(let ids):
        let cut = !ids.allSatisfy(isCut)
        for id in ids { setCut(id, cut) }
    case .restoreSelection(let ids): for id in ids { setCut(id, false) }
    case .cutFillers:
        for (index, word) in words.enumerated() where inScope(index, bounds: bounds) && state.filler(word) { result.cutWordIds.insert(word.id) }
    case .tightenPauses:
        for pause in state.pauses where pauseInScope(pause, bounds: bounds) { result.cutPauseIds.insert(pause.id) }
    case .restoreCuts:
        for (index, word) in words.enumerated() where inScope(index, bounds: bounds) { result.cutWordIds.remove(word.id) }
        for pause in state.pauses where pauseInScope(pause, bounds: bounds) { result.cutPauseIds.remove(pause.id) }
    case .correct(let id, let text):
        let corrected = EditingPrimitives.jsTrim(text.precomposedStringWithCanonicalMapping)
        guard corrected.unicodeScalars.count <= EditingLimits.maxCorrectionScalars else { return state }
        if let word = words.first(where: { $0.id == id && $0.kind == .word }), !corrected.isEmpty, corrected != state.textOf(word) {
            if corrected == word.text { result.corrections.removeValue(forKey: id) } else { result.corrections[id] = corrected }
        }
    case .setActiveClip(let id):
        if id == nil || state.clips.contains(where: { $0.id == id }) { result.activeClipId = id }
    case .addClip(var clip):
        if validClip(clip), !result.clips.contains(where: { $0.id == clip.id }) { clip.selected = true; result.clips.append(clip) }
    case .addAIClips(let resultID, let clips):
        guard validClipID(resultID) else { return state }
        if let aiResults {
            guard let result = aiResults.first(where: { $0.id == resultID }), clips.count <= result.clips.count else { return state }
        }
        for (index, prepared) in clips.enumerated() {
            var clip = prepared
            clip.origin = .ai; clip.aiResultId = resultID; clip.aiClipIndex = index; clip.selected = true
            guard validClip(clip), !result.clips.contains(where: { $0.id == clip.id || ($0.startWordId == clip.startWordId && $0.endWordId == clip.endWordId) }) else { continue }
            result.clips.append(clip)
        }
    case .updateClip(let id, let start, let end):
        if start >= 0, end >= start, end < words.count, let index = result.clips.firstIndex(where: { $0.id == id }) {
            result.clips[index].startWordId = words[start].id; result.clips[index].endWordId = words[end].id
        }
    case .renameClip(let id, let title):
        if validClipID(id), let index = result.clips.firstIndex(where: { $0.id == id }) {
            let trimmed = title.map(EditingPrimitives.jsTrim)
            guard (trimmed?.unicodeScalars.count ?? 0) <= EditingLimits.maxClipTitleScalars else { return state }
            result.clips[index].title = trimmed?.isEmpty == false ? trimmed : nil
        }
    case .setClipSelected(let id, let selected):
        if let index = result.clips.firstIndex(where: { $0.id == id }) { result.clips[index].selected = selected }
    case .removeClip(let id):
        result.clips.removeAll { $0.id == id }
        if result.activeClipId == id { result.activeClipId = nil }
    case .setPauseKeep(let seconds):
        if seconds.isFinite, (0...1).contains(seconds) { result.pauseKeepSeconds = seconds }
    case .setPauseThreshold(let seconds):
        if seconds.isFinite, seconds > 0, seconds <= 10, let pauses = try? detectPauses(words, thresholdSeconds: seconds) {
            result.pauseThresholdSeconds = seconds; result.pauses = pauses; result.cutPauseIds.formIntersection(pauses.map(\.id))
        }
    }
    return result
}

extension Project {
    public mutating func applyEditing(_ command: EditCommand) throws {
        guard let transcript else { return }
        edits = EditReducer.reduce(try EditState(transcript: transcript, edits: edits), command: command, aiResults: ai.results).projectEdits
        if case .removeClip(let id) = command { share.captions.removeValue(forKey: id) }
    }

    public mutating func replaceTranscript(_ replacement: Transcript) {
        transcript = replacement
        edits = ProjectEdits(pauseThresholdSeconds: replacement.refined ? 0.8 : 1, pauseKeepSeconds: edits.pauseKeepSeconds)
        ai = ProjectAI()
        share = ProjectShare()
        voiceLab.segments = [] // New source words invalidate replacement ranges; retain paid assets.
    }
}
