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
    /// The edited timeline's words; `ClipEffects.maskingBleeps` masks bleeped ones for a render.
    public internal(set) var captions: [CaptionWord]
    public let scope: VoiceLabOutputScope
    public var videoCuts: [String: [VoiceLabVideoCut]] = [:]
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
                if let id = piece.segmentId, let cuts = videoCuts[id], !cuts.isEmpty {
                    let removed = cuts.reduce(Int64(0)) { $0 + max(0, min(sample, $1.endSample) - $1.startSample) }
                    let kept: Int64 = sample - piece.sourceStartSample - removed
                    let scale = Self.cutScale(piece, cuts: cuts)
                    guard scale.kept != scale.output else { return Double(piece.outputStartSample + kept) / sampleRate }
                    let output: Double = Double(kept) * Double(scale.output) / Double(scale.kept)
                    return (Double(piece.outputStartSample) + output) / sampleRate
                }
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
            if let id = piece.segmentId, let cuts = videoCuts[id], !cuts.isEmpty {
                let scale = Self.cutScale(piece, cuts: cuts)
                let offset: Double = sample - Double(piece.outputStartSample)
                let kept: Double = scale.kept == scale.output ? offset : offset * Double(scale.kept) / Double(scale.output)
                var sourceSample = Double(piece.sourceStartSample) + kept
                for cut in cuts where sourceSample >= Double(cut.startSample) {
                    sourceSample += Double(cut.endSample - cut.startSample)
                }
                return sourceSample / sampleRate
            }
            let fraction = (sample - Double(piece.outputStartSample)) / Double(piece.outputEndSample - piece.outputStartSample)
            return (Double(piece.sourceStartSample) + fraction * Double(piece.sourceEndSample - piece.sourceStartSample)) / sampleRate
        }
        // Match EditPlan's endpoint convention, including when the chosen clip ends earlier.
        return Double(totalSourceSamples) / sampleRate
    }

    /// A cut piece's kept source samples (its span without `cuts`) and its output samples. A pause's jump cut and the
    /// clip's own cuts at 1× keep them equal; a whole clip's sped-up picture (ADR-R46, `retimeFactor`) plays `kept` in
    /// `output`, evenly, so every mapping scales the kept offset by `output ÷ kept`.
    public static func cutScale(_ piece: VoiceLabOutputPiece, cuts: [VoiceLabVideoCut]) -> (kept: Int64, output: Int64) {
        let removed = cuts.reduce(Int64(0)) { $0 + max(0, $1.endSample - $1.startSample) }
        let kept: Int64 = piece.sourceEndSample - piece.sourceStartSample - removed
        let output: Int64 = piece.outputEndSample - piece.outputStartSample
        guard kept > 0, output > 0 else { return (output, output) }
        return (kept, output)
    }
}

public enum VoiceLabOutputPlanner {
    private struct Replacement {
        let id: String
        let start: Double
        let end: Double
        let duration: Double
        let audio: VoiceLabAudio?
    }
    public static func build(_ project: Project, scope: VoiceLabOutputScope) throws -> VoiceLabOutputPlan {
        try build(project, scope: scope, placing: nil, pendingID: nil)
    }

    /// Geometry-only projection for pre-payment placement checks. No synthetic recipe, asset or consent is invented.
    static func build(_ project: Project, scope: VoiceLabOutputScope, placing window: VoiceLabWindow?,
                      pendingID: String?) throws -> VoiceLabOutputPlan {
        try build(project, scope: scope, placing: window.flatMap { window in pendingID.map { [(window, $0)] } } ?? [])
    }

    static func build(_ project: Project, scope: VoiceLabOutputScope,
                      placing windows: [(VoiceLabWindow, String)]) throws -> VoiceLabOutputPlan {
        try VoiceLabProject.validate(project)
        guard let transcript = project.transcript else { throw VoiceLabProjectError.invalidScope }
        let duration = project.media.source.durationSeconds
        let rate = Double(project.media.source.audio?.sampleRate ?? 48_000)
        let total = Int64(max(0, EditingPrimitives.jsRound(duration * rate)))
        // Words, a clip's range and the take's end meet a replace range on the source sample grid (§10.1).
        let grid = VoiceLabSampleGrid(rate: rate)
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
            clipRange = try clipTimes(transcript.words, clip: clip, startIndex: indices.lowerBound, endIndex: indices.upperBound)
        }
        let enabled = project.voiceLab.segments.filter { segment in
            guard segment.enabled else { return false }
            if let clipRange {
                if grid.sample(segment.replace.end) <= grid.sample(clipRange.start)
                    || grid.sample(segment.replace.start) >= grid.sample(clipRange.end) { return false }
            }
            return true
        }.sorted { $0.replace.start < $1.replace.start }
        if let clipRange {
            for segment in enabled where !grid.contains(clipRange.start, clipRange.end, start: segment.replace.start, end: segment.replace.end) {
                throw VoiceLabProjectError.invalidScope
            }
        }
        var replacements = enabled.map { Replacement(id: $0.id, start: $0.replace.start, end: $0.replace.end,
                                                     duration: $0.outDuration, audio: $0.audio) }
        for (window, pendingID) in windows {
            guard window.start.isFinite, window.end.isFinite, window.start >= 0,
                  grid.sample(window.end) <= grid.sample(duration), window.end > window.start else { throw VoiceLabProjectError.invalidRange }
            if let clipRange, !grid.contains(clipRange.start, clipRange.end, start: window.start, end: window.end) {
                throw VoiceLabProjectError.invalidScope
            }
            guard replacements.allSatisfy({ window.end <= $0.start || window.start >= $0.end }) else {
                throw VoiceLabProjectError.overlappingReplacement
            }
            replacements.append(Replacement(id: pendingID, start: window.start, end: window.end,
                                            duration: window.end - window.start, audio: nil))
            replacements.sort { $0.start < $1.start }
        }
        func inside(_ start: Double, _ end: Double) -> Bool {
            replacements.contains { grid.contains($0.start, $0.end, start: start, end: end) }
        }
        let segments = try buildSegments(state, activeClip: activeClip).filter { item in
            !(item.kind == .word || item.kind == .pause) || !inside(item.start, item.end)
        }
        let base = try buildEditPlan(segments, duration: duration, sampleRate: rate, pauseKeepSeconds: edits.pauseKeepSeconds)
        let synthRanges = replacements.map { segment in
            (segment, MediaInterval(startSample: Int64(EditingPrimitives.jsRound(segment.start * rate)),
                                    endSample: Int64(EditingPrimitives.jsRound(segment.end * rate))))
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
                let generated = Int64(EditingPrimitives.jsRound(segment.duration * rate))
                guard generated > 0 else { throw VoiceLabProjectError.invalidRange }
                try append(.synth, synth.startSample, synth.endSample, generated, segment.id, segment.audio)
                position = synth.endSample
            }
            try append(.source, position, interval.endSample, interval.endSample - position)
        }
        var plan = VoiceLabOutputPlan(sampleRate: rate, totalSourceSamples: total, pieces: pieces, captions: [], scope: scope)
        for segment in enabled {
            if segment.candidates.indices.contains(segment.selectedCandidateIndex),
               let video = segment.candidates[segment.selectedCandidateIndex].recipe?.video,
               video.mode == .cut { plan.videoCuts[segment.id] = video.cuts }
        }
        if !windows.isEmpty { return plan }
        if enabled.isEmpty {
            return VoiceLabOutputPlan(sampleRate: rate, totalSourceSamples: total, pieces: pieces,
                                      captions: captionCopy(segments, plan: base), scope: scope)
        }
        var captions: [CaptionWord] = []
        for word in transcript.words where word.kind == .word {
            if let covered = enabled.first(where: { $0.replace.covers(start: word.start, end: word.end, rate: rate) }) {
                guard covered.kind == .voiceChanger else { continue }
                let start = plan.mapTime(word.start), end = plan.mapTime(word.end)
                if end > start { captions.append(CaptionWord(id: word.id, text: word.text, start: start, end: end)) }
            } else if segments.contains(where: { $0.kind == .word && $0.id == word.id && !$0.cut }) {
                let start = plan.mapTime(word.start), end = plan.mapTime(word.end)
                if end > start { captions.append(CaptionWord(id: word.id, text: state.textOf(word), start: start, end: end)) }
            }
        }
        for segment in enabled where segment.kind != .voiceChanger {
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
