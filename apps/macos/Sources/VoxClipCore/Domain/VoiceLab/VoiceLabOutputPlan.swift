import Foundation

public enum VoiceLabOutputScope: Sendable, Equatable { case full, clip(String) }
public enum VoiceLabOutputPieceKind: String, Codable, Sendable { case source, synth }
public struct VoiceLabOutputPiece: Sendable, Equatable {
    public let kind: VoiceLabOutputPieceKind
    public let sourceStartSample: Int64
    public let sourceEndSample: Int64
    public let outputStartSample: Int64
    public let outputEndSample: Int64
    public let segmentId: String?
    public let assetId: String?
    public let audio: VoiceLabAudio?
}
/// Media-free composition instructions. A legacy EditPlan cannot represent synthetic output length.
public struct VoiceLabOutputPlan: Sendable, Equatable {
    public let sampleRate: Double
    public let totalSourceSamples: Int64
    public let pieces: [VoiceLabOutputPiece]
    public let captions: [CaptionWord]
    public let scope: VoiceLabOutputScope
    public var outputSamples: Int64 { pieces.last?.outputEndSample ?? 0 }
    public var duration: Double { Double(outputSamples) / sampleRate }
    public var requiresSyntheticRendering: Bool { pieces.contains { $0.kind == .synth } }

    public func requireLegacyRendering() throws {
        if requiresSyntheticRendering { throw VoiceLabProjectError.unsupportedRendering }
    }
    public func mapTime(_ source: Double) -> Double {
        let sample = Int64(min(Double(totalSourceSamples), max(0, EditingPrimitives.jsRound(source.isFinite ? source * sampleRate : 0))))
        var prior: Int64 = 0
        for piece in pieces {
            if sample < piece.sourceStartSample { return Double(prior) / sampleRate }
            if sample <= piece.sourceEndSample {
                let fraction = Double(sample - piece.sourceStartSample) / Double(piece.sourceEndSample - piece.sourceStartSample)
                return (Double(piece.outputStartSample) + fraction * Double(piece.outputEndSample - piece.outputStartSample)) / sampleRate
            }
            prior = piece.outputEndSample
        }
        return duration
    }
    public func sourceTime(_ edited: Double) -> Double {
        let sample = min(Double(outputSamples), max(0, EditingPrimitives.jsRound(edited.isFinite ? edited * sampleRate : 0)))
        for piece in pieces where sample < Double(piece.outputEndSample) {
            let fraction = (sample - Double(piece.outputStartSample)) / Double(piece.outputEndSample - piece.outputStartSample)
            return (Double(piece.sourceStartSample) + fraction * Double(piece.sourceEndSample - piece.sourceStartSample)) / sampleRate
        }
        // Match EditPlan's endpoint convention, including when the chosen clip ends earlier.
        return Double(totalSourceSamples) / sampleRate
    }
}

public enum VoiceLabOutputPlanner {
    public static func build(_ project: Project, scope: VoiceLabOutputScope) throws -> VoiceLabOutputPlan {
        try VoiceLabProject.validate(project)
        guard let transcript = project.transcript else { throw VoiceLabProjectError.invalidScope }
        let duration = project.media.source.durationSeconds
        let rate = Double(project.media.source.audio?.sampleRate ?? 48_000)
        let total = Int64(max(0, EditingPrimitives.jsRound(duration * rate)))
        let edits = project.edits
        let pauses = try detectPauses(transcript.words, thresholdSeconds: edits.pauseThresholdSeconds)
        let state = EditState(transcript: transcript, pauses: pauses, pauseThresholdSeconds: edits.pauseThresholdSeconds,
                              pauseKeepSeconds: edits.pauseKeepSeconds, cutWordIds: Set(edits.cutWordIds),
                              cutPauseIds: Set(edits.cutPauseIds), corrections: edits.corrections, clips: edits.clips,
                              activeClipId: nil)
        let activeClip: ClipRange?
        let clipRange: TimeRange?
        switch scope {
        case .full: activeClip = nil; clipRange = nil
        case .clip(let id):
            guard let clip = edits.clips.first(where: { $0.id == id }),
                  let indices = clipIndices(clip, words: transcript.words) else { throw VoiceLabProjectError.invalidScope }
            activeClip = clip
            clipRange = try clipTimes(transcript.words, startIndex: indices.lowerBound, endIndex: indices.upperBound)
        }
        let enabled = project.voiceLab.segments.filter { segment in
            guard segment.enabled else { return false }
            if let clipRange {
                if segment.replace.end <= clipRange.start || segment.replace.start >= clipRange.end { return false }
            }
            return true
        }.sorted { $0.replace.start < $1.replace.start }
        if let clipRange {
            for segment in enabled where segment.replace.start < clipRange.start || segment.replace.end > clipRange.end {
                throw VoiceLabProjectError.invalidScope
            }
        }
        func inside(_ start: Double, _ end: Double) -> Bool {
            enabled.contains { start >= $0.replace.start && end <= $0.replace.end }
        }
        let segments = try buildSegments(state, activeClip: activeClip).filter { item in
            !(item.kind == .word || item.kind == .pause) || !inside(item.start, item.end)
        }
        let base = try buildEditPlan(segments, duration: duration, sampleRate: rate, pauseKeepSeconds: edits.pauseKeepSeconds)
        let synthRanges = enabled.map { segment in
            (segment, MediaInterval(startSample: Int64(EditingPrimitives.jsRound(segment.replace.start * rate)),
                                    endSample: Int64(EditingPrimitives.jsRound(segment.replace.end * rate))))
        }
        guard synthRanges.allSatisfy({ $0.1.endSample > $0.1.startSample }) else { throw VoiceLabProjectError.invalidRange }
        // Neighbour reach may enter a replacement. Remove only that portion of the cut.
        var cuts = base.cuts
        for (_, synth) in synthRanges {
            cuts = cuts.flatMap { cut -> [MediaInterval] in
                if cut.endSample <= synth.startSample || cut.startSample >= synth.endSample { return [cut] }
                var parts: [MediaInterval] = []
                if cut.startSample < synth.startSample { parts.append(MediaInterval(startSample: cut.startSample, endSample: synth.startSample)) }
                if cut.endSample > synth.endSample { parts.append(MediaInterval(startSample: synth.endSample, endSample: cut.endSample)) }
                return parts
            }
        }
        var kept: [MediaInterval] = [], cursor: Int64 = 0
        for cut in cuts {
            if cut.startSample > cursor { kept.append(MediaInterval(startSample: cursor, endSample: cut.startSample)) }
            cursor = cut.endSample
        }
        if cursor < total { kept.append(MediaInterval(startSample: cursor, endSample: total)) }
        var pieces: [VoiceLabOutputPiece] = []
        var output: Int64 = 0
        func append(_ kind: VoiceLabOutputPieceKind, _ start: Int64, _ end: Int64, _ length: Int64, _ segmentId: String? = nil, _ audio: VoiceLabAudio? = nil) throws {
            guard end > start, length > 0 else { return }
            guard output <= Int64.max - length else { throw VoiceLabProjectError.invalidRange }
            pieces.append(VoiceLabOutputPiece(kind: kind, sourceStartSample: start, sourceEndSample: end,
                                              outputStartSample: output, outputEndSample: output + length,
                                              segmentId: segmentId, assetId: audio?.assetId, audio: audio))
            output += length
        }
        for interval in kept {
            var position = interval.startSample
            for (segment, synth) in synthRanges where synth.endSample > position && synth.startSample < interval.endSample {
                guard synth.startSample >= position, synth.endSample <= interval.endSample else { throw VoiceLabProjectError.invalidRange }
                try append(.source, position, synth.startSample, synth.startSample - position)
                let generated = Int64(EditingPrimitives.jsRound(segment.outDuration * rate))
                guard generated > 0 else { throw VoiceLabProjectError.invalidRange }
                try append(.synth, synth.startSample, synth.endSample, generated, segment.id, segment.audio)
                position = synth.endSample
            }
            try append(.source, position, interval.endSample, interval.endSample - position)
        }
        var plan = VoiceLabOutputPlan(sampleRate: rate, totalSourceSamples: total, pieces: pieces, captions: [], scope: scope)
        if enabled.isEmpty {
            return VoiceLabOutputPlan(sampleRate: rate, totalSourceSamples: total, pieces: pieces,
                                      captions: captionCopy(segments, plan: base), scope: scope)
        }
        var captions: [CaptionWord] = []
        for word in transcript.words where word.kind == .word {
            if let covered = enabled.first(where: { word.start >= $0.replace.start && word.end <= $0.replace.end }) {
                guard covered.kind == .voiceChanger else { continue }
                let start = plan.mapTime(word.start), end = plan.mapTime(word.end)
                if end > start { captions.append(CaptionWord(id: word.id, text: word.text, start: start, end: end)) }
            } else if segments.contains(where: { $0.kind == .word && $0.id == word.id && !$0.cut }) {
                let start = plan.mapTime(word.start), end = plan.mapTime(word.end)
                if end > start { captions.append(CaptionWord(id: word.id, text: state.textOf(word), start: start, end: end)) }
            }
        }
        for (segment, _) in synthRanges where segment.kind == .tts {
            guard let piece = pieces.first(where: { $0.segmentId == segment.id }) else { continue }
            for (index, word) in (segment.words ?? []).enumerated() {
                let start = Double(piece.outputStartSample + Int64(EditingPrimitives.jsRound(word.start * rate))) / rate
                let end = Double(piece.outputStartSample + Int64(EditingPrimitives.jsRound(word.end * rate))) / rate
                if end > start { captions.append(CaptionWord(id: "\(segment.id):word:\(index)", text: word.text, start: start, end: end)) }
            }
        }
        captions.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        plan = VoiceLabOutputPlan(sampleRate: rate, totalSourceSamples: total, pieces: pieces, captions: captions, scope: scope)
        return plan
    }
}
