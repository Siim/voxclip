import Foundation

/// Structural v3 validation. Physical file verification remains the Media asset boundary.
public enum VoiceLabRenderValidation {
    public static func validate(_ project: Project) throws {
        guard let clean = project.voiceLab.cleanAudio, let voices = project.voiceLab.voices,
              let videoAssets = project.voiceLab.videoAssets,
              clean.mode == .off ? (clean.assetId == nil && clean.mix == nil) :
                (clean.assetId != nil && clean.mix.map { $0.isFinite && (0...1).contains($0) } == true),
              Set(voices.map(\.id)).count == voices.count else { throw VoiceLabProjectError.missingRenderPolicy }
        let assets = project.voiceLab.assets ?? []
        if let assetId = clean.assetId, !assets.contains(where: { $0.id == assetId }) { throw VoiceLabProjectError.danglingAsset }
        for voice in voices {
            guard validID(voice.id), validID(voice.consentRecordId), !voice.provider.isEmpty,
                  !voice.voiceId.isEmpty, !voice.displayName.isEmpty else { throw VoiceLabProjectError.consentUnverified }
        }
        guard Set(videoAssets.map(\.id)).count == videoAssets.count else { throw VoiceLabProjectError.invalidAsset }
        for video in videoAssets {
            guard video.id.range(of: "\\A[a-z0-9][a-z0-9_-]{0,63}\\z", options: .regularExpression) != nil,
                  video.id.range(of: "\\A(?:con|prn|aux|nul|com[1-9]|lpt[1-9])\\z", options: .regularExpression) == nil,
                  video.file == project.id + "/" + video.id + ".mp4",
                  video.sha256.range(of: "\\A[0-9a-f]{64}\\z", options: .regularExpression) != nil,
                  video.durationSeconds.isFinite, video.durationSeconds > 0,
                  video.frameRate.isFinite, video.frameRate > 0, video.durationSeconds * video.frameRate < Double(Int64.max),
                  video.width > 0, video.height > 0 else { throw VoiceLabProjectError.invalidAsset }
        }
        let rate = Double(project.media.source.audio?.sampleRate ?? 48_000)
        let total = samples(project.media.source.durationSeconds, rate)
        let segments = project.voiceLab.segments
        for segment in segments {
            guard let scope = segment.scope,
                  (scope == .passage && segment.groupId == nil) || (scope == .fullTake && segment.groupId.map(validID) == true)
            else { throw VoiceLabProjectError.missingRenderPolicy }
            for candidate in segment.candidates where candidate.rejected == nil {
                guard let recipe = candidate.recipe else { throw VoiceLabProjectError.missingRenderPolicy }
                try validate(recipe, segment: segment, project: project, rate: rate, total: total)
                guard candidate.assetId == recipe.audio.assetId else { throw VoiceLabProjectError.invalidCandidate }
            }
            guard let recipe = segment.candidates[segment.selectedCandidateIndex].recipe,
                  segment.audio == recipe.audio, segment.outDuration == recipe.outDuration, segment.words == recipe.words,
                  segment.provenance == recipe.provenance,
                  segment.qa == VoiceLabQA(transcriptMatch: recipe.qa.transcriptMatch, lufsJumpLu: recipe.qa.lufsJumpLu,
                                            peakDbfs: recipe.qa.peakDbfs, speakerScore: recipe.qa.speakerScore)
            else { throw VoiceLabProjectError.invalidCandidate }
        }
        for group in Set(segments.compactMap(\.groupId)) {
            let members = segments.filter { $0.groupId == group }.sorted { $0.replace.start < $1.replace.start }
            var cursor: Int64 = 0
            for segment in members {
                guard segment.scope == .fullTake, samples(segment.replace.start, rate) == cursor else { throw VoiceLabProjectError.invalidRange }
                cursor = samples(segment.replace.end, rate)
            }
            guard cursor == total else { throw VoiceLabProjectError.invalidRange }
        }
    }

    private static func validID(_ value: String) -> Bool {
        value.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\\z", options: .regularExpression) != nil
    }
    private static func samples(_ seconds: Double, _ rate: Double) -> Int64 { Int64(EditingPrimitives.jsRound(seconds * rate)) }
    private static func validate(_ recipe: VoiceLabRenderRecipe, segment: VoiceLabSegment, project: Project, rate: Double, total: Int64) throws {
        let assets = project.voiceLab.assets ?? []
        guard let asset = assets.first(where: { $0.id == recipe.audio.assetId }) else { throw VoiceLabProjectError.danglingAsset }
        let start = samples(segment.replace.start, rate), end = samples(segment.replace.end, rate)
        guard recipe.outDuration.isFinite, recipe.outDuration > 0, recipe.outDuration * rate < Double(Int64.max),
              asset.durationSeconds * Double(asset.sampleRate) < Double(Int64.max) else { throw VoiceLabProjectError.invalidRange }
        let out = samples(recipe.outDuration, rate)
        guard out > 0,
              recipe.audio.trimStart.isFinite, recipe.audio.trimEnd.isFinite, recipe.audio.gainDb.isFinite,
              recipe.audio.trimStart >= 0, recipe.audio.trimEnd <= asset.durationSeconds,
              recipe.audio.trimEnd > recipe.audio.trimStart, recipe.audio.stretch.isFinite,
              abs(recipe.audio.stretch - recipe.outDuration / (recipe.audio.trimEnd - recipe.audio.trimStart)) <= 1e-6,
              (0.92...1.08).contains((recipe.audio.trimEnd - recipe.audio.trimStart) / recipe.outDuration)
        else { throw VoiceLabProjectError.invalidRange }
        guard validID(recipe.cost.quoteId), recipe.cost.usd.map({ $0.isFinite && $0 >= 0 }) ?? true,
              recipe.provenance.region?.isEmpty == false,
              recipe.provenance.requestId.map(validID) == true,
              recipe.provenance.seed == recipe.seed else { throw VoiceLabProjectError.missingRenderPolicy }
        guard !recipe.chunks.isEmpty else { throw VoiceLabProjectError.missingRenderPolicy }
        var sourceCursor = start
        var assembledCursor = samples(recipe.audio.trimStart, Double(asset.sampleRate))
        for chunk in recipe.chunks {
            guard chunk.sourceStartSample == sourceCursor, chunk.sourceEndSample > sourceCursor,
                  chunk.assembledStartFrame == assembledCursor, chunk.assembledEndFrame > assembledCursor,
                  validID(chunk.requestId), let chunkAsset = assets.first(where: { $0.id == chunk.assetId }),
                  chunk.assetSha256 == chunkAsset.sha256, chunk.seed <= UInt32.max else { throw VoiceLabProjectError.invalidRange }
            sourceCursor = chunk.sourceEndSample; assembledCursor = chunk.assembledEndFrame
        }
        guard sourceCursor == end, assembledCursor == samples(recipe.audio.trimEnd, Double(asset.sampleRate)) else { throw VoiceLabProjectError.invalidRange }
        if let tone = recipe.roomTone {
            guard tone.sourceStartSample >= 0, tone.sourceEndSample <= total,
                  tone.sourceEndSample - tone.sourceStartSample == samples(0.5, rate), tone.gainDb.isFinite else { throw VoiceLabProjectError.missingRenderPolicy }
            if project.transcript?.words.contains(where: { samples($0.start, rate) < tone.sourceEndSample && samples($0.end, rate) > tone.sourceStartSample }) == true { throw VoiceLabProjectError.missingRenderPolicy }
        }
        if project.voiceLab.cleanAudio?.mode == .on && recipe.roomTone != nil { throw VoiceLabProjectError.missingRenderPolicy }
        if segment.kind == .tts && segment.scope == .passage && project.voiceLab.cleanAudio?.mode == .off && recipe.roomTone == nil { throw VoiceLabProjectError.missingRenderPolicy }
        try validateSeam(recipe.seams.in, edge: start == 0, sourceAvailable: end-start, asset: asset, trim: recipe.audio.trimStart, stretch: recipe.audio.stretch, rate: rate, incoming: true)
        try validateSeam(recipe.seams.out, edge: end == total, sourceAvailable: end-start, asset: asset, trim: recipe.audio.trimEnd, stretch: recipe.audio.stretch, rate: rate, incoming: false)
        let inRight = recipe.seams.in.fadeSamples - recipe.seams.in.fadeSamples / 2
        let outLeft = recipe.seams.out.fadeSamples / 2
        if inRight + outLeft > out { throw VoiceLabProjectError.overlappingFades }
        let video = recipe.video
        guard video.sourceStartSample == start, video.sourceEndSample == end, video.outputSamples == out else { throw VoiceLabProjectError.invalidRange }
        switch video.mode {
        case .source:
            guard video.retimeFactor == nil, video.zoom == nil, video.faceX == nil, video.faceY == nil,
                  video.assetId == nil, video.provider == nil, video.model == nil, video.requestId == nil,
                  video.windowStartSample == nil, video.windowEndSample == nil, video.syncMode == nil else { throw VoiceLabProjectError.invalidSegment }
        case .retimed, .zoomCover:
            guard let factor = video.retimeFactor, factor.isFinite, (0.80...1.25).contains(factor),
                  abs(factor - Double(end-start)/Double(out)) <= 1e-6 else { throw VoiceLabProjectError.invalidRange }
            if video.mode == .zoomCover {
                guard let zoom = video.zoom, zoom.isFinite, zoom >= 1, zoom <= 2,
                      let x = video.faceX, x.isFinite, (0...1).contains(x),
                      let y = video.faceY, y.isFinite, (0...1).contains(y) else { throw VoiceLabProjectError.invalidRange }
            }
            guard video.assetId == nil, video.provider == nil, video.model == nil, video.requestId == nil,
                  video.windowStartSample == nil, video.windowEndSample == nil, video.syncMode == nil,
                  video.mode == .zoomCover || (video.zoom == nil && video.faceX == nil && video.faceY == nil) else { throw VoiceLabProjectError.invalidSegment }
        case .lipsync:
            guard let videoAsset = project.voiceLab.videoAssets?.first(where: { $0.id == video.assetId }),
                  videoAsset.durationSeconds * rate >= Double(out),
                  video.provider?.isEmpty == false, video.model?.isEmpty == false,
                  video.requestId.map(validID) == true,
                  let first = video.windowStartSample, let last = video.windowEndSample,
                  first >= 0, first <= start, last <= total, last >= end, last > first, video.syncMode == "remap",
                  video.retimeFactor == nil, video.zoom == nil, video.faceX == nil, video.faceY == nil else { throw VoiceLabProjectError.missingRenderPolicy }
        }
        let qa = recipe.qa
        guard qa.lufsJumpLu.isFinite, abs(qa.lufsJumpLu) <= 2,
              qa.peakDbfs.isFinite, qa.peakDbfs < 0 else { throw VoiceLabProjectError.qaRejected }
        if segment.kind == .tts {
            guard recipe.voiceSource == .own else { throw VoiceLabProjectError.consentUnverified }
            guard let words = recipe.words, !words.isEmpty else { throw VoiceLabProjectError.alignmentUnavailable }
            var cursor = 0.0
            for word in words {
                guard !word.text.isEmpty, word.synthetic, word.start.isFinite, word.end.isFinite,
                      word.start >= cursor, word.end > word.start, word.end <= recipe.outDuration,
                      samples(word.end, rate) > samples(word.start, rate), samples(word.end, rate) <= out else { throw VoiceLabProjectError.alignmentUnavailable }
                cursor = word.end
            }
            guard let count = qa.transcriptTokens, count > 0,
                  let match = qa.transcriptMatch, match.isFinite, (0...1).contains(match),
                  (count <= 5 ? qa.transcriptExact == true : match >= 0.9) else { throw VoiceLabProjectError.qaRejected }
        } else if recipe.words != nil { throw VoiceLabProjectError.invalidWords }
        if recipe.voiceSource == .own {
            guard let id = recipe.voiceRefId, let voice = project.voiceLab.voices?.first(where: { $0.id == id }),
                  recipe.provenance.consentRecordId == voice.consentRecordId,
                  recipe.provenance.voiceId == voice.voiceId, recipe.provenance.provider == voice.provider,
                  let verified = recipe.consentVerifiedAt, verified <= recipe.provenance.createdAt else { throw VoiceLabProjectError.consentUnverified }
            if segment.kind == .tts {
                guard let score = qa.speakerScore, let threshold = qa.speakerThreshold,
                      score.isFinite, threshold.isFinite, (0...1).contains(score), (0...1).contains(threshold),
                      qa.speakerModel?.isEmpty == false, qa.speakerPassed == true, score >= threshold else { throw VoiceLabProjectError.qaRejected }
            }
        } else if recipe.voiceRefId != nil || recipe.consentVerifiedAt != nil || recipe.provenance.consentRecordId != nil { throw VoiceLabProjectError.invalidSegment }
    }
    private static func validateSeam(_ seam: VoiceLabSeam, edge: Bool, sourceAvailable: Int64, asset: VoiceLabAsset, trim: Double, stretch: Double, rate: Double, incoming: Bool) throws {
        if edge {
            guard seam.kind == .none, seam.fadeSamples == 0, seam.sourceHandleSamples == 0, seam.assetHandleFrames == 0 else { throw VoiceLabProjectError.invalidFadeHandles }
            return
        }
        guard seam.kind == .gap || seam.kind == .hard || seam.kind == .synthToSynth else { throw VoiceLabProjectError.missingRenderPolicy }
        let expected = samples(seam.kind == .hard ? 0.012 : 0.020, rate)
        guard seam.fadeSamples == expected, seam.fadeSamples >= 2 else { throw VoiceLabProjectError.invalidFadeHandles }
        let needed = incoming ? seam.fadeSamples / 2 : seam.fadeSamples - seam.fadeSamples / 2
        let rawFrames = Double(needed) * Double(asset.sampleRate) / (rate * stretch)
        let nearest = rawFrames.rounded()
        // Persisted stretch ratios can put an integral frame one ULP above its exact value.
        let neededAsset = Int64(abs(rawFrames - nearest) <= 4 * rawFrames.ulp ? nearest : ceil(rawFrames))
        let available = incoming ? samples(trim, Double(asset.sampleRate)) : samples(asset.durationSeconds - trim, Double(asset.sampleRate))
        guard seam.assetHandleFrames >= neededAsset, seam.assetHandleFrames <= available else { throw VoiceLabProjectError.invalidFadeHandles }
        if seam.kind == .synthToSynth {
            guard seam.sourceHandleSamples == 0 else { throw VoiceLabProjectError.invalidFadeHandles }
        } else {
            guard seam.sourceHandleSamples >= seam.fadeSamples - needed, seam.sourceHandleSamples <= sourceAvailable else { throw VoiceLabProjectError.invalidFadeHandles }
        }
    }
}
