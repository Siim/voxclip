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
    public let partSeams: [Int64]
    private(set) var recordingSeams: [Int64]
    private let sourceIndex: [VoiceLabOutputPiece]
    public var videoCuts: [String: [VoiceLabVideoCut]] = [:]

    init(sampleRate: Double, totalSourceSamples: Int64, pieces: [VoiceLabOutputPiece], captions: [CaptionWord],
         scope: VoiceLabOutputScope, partSeams: [Int64] = [], recordingRegions: [MediaInterval] = []) {
        self.sampleRate = sampleRate; self.totalSourceSamples = totalSourceSamples
        self.pieces = pieces; self.captions = captions; self.scope = scope; self.partSeams = partSeams
        self.sourceIndex = pieces.sorted { $0.sourceStartSample < $1.sourceStartSample }
        self.recordingSeams = recordingSeamSamples(pieces, regions: recordingRegions, source: \.sourceStartSample, output: \.outputStartSample)
    }
    public var outputSamples: Int64 { pieces.last?.outputEndSample ?? 0 }
    public var duration: Double { Double(outputSamples) / sampleRate }
    public var requiresSyntheticRendering: Bool { pieces.contains { $0.kind == .synth } }

    public func requireLegacyRendering() throws {
        if requiresSyntheticRendering { throw VoiceLabProjectError.unsupportedRendering }
    }
    public func mapTime(_ source: Double) -> Double {
        mapTime(source, end: false)
    }
    func mapTime(_ source: Double, end: Bool) -> Double {
        let sample = Int64(min(Double(totalSourceSamples), max(0, EditingPrimitives.jsRound(source.isFinite ? source * sampleRate : 0))))
        let probe = end && !partSeams.isEmpty && sample > 0 ? sample - 1 : sample
        guard let piece = sourceMapEntry(sourceIndex, at: probe, start: { $0.sourceStartSample }) else { return 0 }
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
        return Double(piece.outputEndSample) / sampleRate
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
                      placing windows: [(VoiceLabWindow, String)], partOverride: ClipRange? = nil) throws -> VoiceLabOutputPlan {
        try VoiceLabProject.validate(project)
        guard let state = try EditState(project: project) else { throw VoiceLabProjectError.invalidScope }
        let transcript = state.transcript
        let duration = project.media.source.durationSeconds
        let rate = Double(state.projectClock?.sampleRate ?? project.media.source.audio?.sampleRate ?? 48_000)
        let total = state.projectClock.map { Int64($0.totalSamples) } ?? Int64(max(0, EditingPrimitives.jsRound(duration * rate)))
        let regions = state.projectClock?.sampleRegions ?? []
        // Words, a clip's range and the take's end meet a replace range on the source sample grid (§10.1).
        let grid = VoiceLabSampleGrid(rate: rate)
        let edits = project.edits
        let activeClip: ClipRange?
        let clipRange: TimeRange?
        let recordingCopy: Bool
        switch scope {
        case .full: activeClip = nil; clipRange = nil; recordingCopy = false
        case .clip(let id):
            recordingCopy = RecordingEdits.isRecordingCopy(id, project: project)
            guard let clip = partOverride ?? edits.clips.first(where: { $0.id == id }) else { throw VoiceLabProjectError.invalidScope }
            if clip.parts != nil {
                guard windows.isEmpty, StoryClips.valid(clip, words: transcript.words) else { throw VoiceLabProjectError.invalidScope }
                try StoryClips.validatePlacement(clip, project: project, words: transcript.words)
                let plans = try clip.singlePartClips().map { try build(project, scope: scope, placing: [], partOverride: $0) }
                return try concatenate(plans, scope: scope, rate: rate, total: total, regions: regions)
            }
            guard let indices = clipIndices(clip, words: transcript.words) else { throw VoiceLabProjectError.invalidScope }
            activeClip = clip
            clipRange = try scopedClipTimes(state, bounds: indices, leadIn: clip.leadInSeconds)
        }
        let enabled = project.voiceLab.segments.filter { segment in
            guard segment.enabled else { return false }
            if let clipRange {
                if recordingCopy, let video = segment.candidates[segment.selectedCandidateIndex].recipe?.video, video.mode == .lipsync,
                   let start = video.windowStartSample, let end = video.windowEndSample,
                   (grid.sample(clipRange.start) > Double(start) || grid.sample(clipRange.end) < Double(end)) { return false }
                if partOverride != nil || recordingCopy { return grid.contains(clipRange.start, clipRange.end, start: segment.replace.start, end: segment.replace.end) }
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
        let base = try buildScopedEditPlan(segments, state: state, activeClip: activeClip, duration: duration, rate: rate)
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
        var plan = VoiceLabOutputPlan(sampleRate: rate, totalSourceSamples: total, pieces: pieces, captions: [], scope: scope, recordingRegions: regions)
        for segment in enabled {
            if segment.candidates.indices.contains(segment.selectedCandidateIndex),
               let video = segment.candidates[segment.selectedCandidateIndex].recipe?.video,
               video.mode == .cut { plan.videoCuts[segment.id] = video.cuts }
        }
        if !windows.isEmpty { return plan }
        if enabled.isEmpty {
            plan.captions = captionCopy(segments, plan: base)
            return plan
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
        for seam in plan.recordingSeams {
            if let index = captions.firstIndex(where: { grid.sample($0.start) >= Double(seam) }) { captions[index].startsPart = true }
        }
        plan.captions = captions
        return plan
    }

    private static func concatenate(_ plans: [VoiceLabOutputPlan], scope: VoiceLabOutputScope, rate: Double, total: Int64, regions: [MediaInterval]) throws -> VoiceLabOutputPlan {
        var pieces: [VoiceLabOutputPiece] = [], captions: [CaptionWord] = [], seams: [Int64] = [], offset: Int64 = 0
        var cuts: [String: [VoiceLabVideoCut]] = [:]
        for plan in plans where !plan.pieces.isEmpty {
            guard offset <= Int64.max - plan.outputSamples else { throw VoiceLabProjectError.invalidRange }
            if offset > 0 { seams.append(offset) }
            pieces += plan.pieces.map { piece in
                VoiceLabOutputPiece(kind: piece.kind, sourceStartSample: piece.sourceStartSample, sourceEndSample: piece.sourceEndSample,
                    outputStartSample: piece.outputStartSample + offset, outputEndSample: piece.outputEndSample + offset,
                    segmentId: piece.segmentId, assetId: piece.assetId, audio: piece.audio)
            }
            captions += shiftedPartCaptions(plan.captions, by: offset, rate: rate, startsPart: !captions.isEmpty)
            cuts.merge(plan.videoCuts) { first, _ in first }
            offset += plan.outputSamples
        }
        let sorted = pieces.sorted { $0.sourceStartSample < $1.sourceStartSample }
        guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.sourceEndSample <= $1.sourceStartSample }) else {
            throw VoiceLabProjectError.invalidRange
        }
        var result = VoiceLabOutputPlan(sampleRate: rate, totalSourceSamples: total, pieces: pieces, captions: captions, scope: scope, partSeams: seams, recordingRegions: regions)
        result.videoCuts = cuts
        return result
    }
}
