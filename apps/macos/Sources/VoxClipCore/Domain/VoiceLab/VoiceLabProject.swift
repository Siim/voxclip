import Foundation

/// Schema-v2 synthetic media is a separate, source-preserving layer (ADR-R24).
public struct VoiceLabAsset: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var file: String
    public var sha256: String
    public var durationSeconds: Double
    public var sampleRate: Int
    public var createdAt: Date
    public init(id: String, kind: String = "audio", file: String, sha256: String, durationSeconds: Double, sampleRate: Int, createdAt: Date) {
        self.id = id; self.kind = kind; self.file = file; self.sha256 = sha256
        self.durationSeconds = durationSeconds; self.sampleRate = sampleRate; self.createdAt = createdAt
    }
}

public enum VoiceLabSegmentKind: String, Codable, Sendable { case tts, voiceChanger }
public struct VoiceLabReplacement: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var firstWordId: String
    public var lastWordId: String
    public init(start: Double, end: Double, firstWordId: String, lastWordId: String) {
        self.start = start; self.end = end; self.firstWordId = firstWordId; self.lastWordId = lastWordId
    }
}
public struct VoiceLabAudio: Codable, Sendable, Equatable {
    public var assetId: String
    public var trimStart: Double
    public var trimEnd: Double
    public var stretch: Double
    public var gainDb: Double
    public init(assetId: String, trimStart: Double, trimEnd: Double, stretch: Double = 1, gainDb: Double = 0) {
        self.assetId = assetId; self.trimStart = trimStart; self.trimEnd = trimEnd; self.stretch = stretch; self.gainDb = gainDb
    }
}
public struct VoiceLabText: Codable, Sendable, Equatable {
    public var original: String
    public var new: String
    public init(original: String, new: String) { self.original = original; self.new = new }
}
public struct VoiceLabWord: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var synthetic: Bool
    public init(text: String, start: Double, end: Double, synthetic: Bool) {
        self.text = text; self.start = start; self.end = end; self.synthetic = synthetic
    }
}
public struct VoiceLabCandidate: Codable, Sendable, Equatable {
    public var assetId: String?
    public var score: Double?
    public var rejected: String?
    public var recipe: VoiceLabRenderRecipe?
    public init(assetId: String?, score: Double?, rejected: String? = nil) {
        self.assetId = assetId; self.score = score; self.rejected = rejected; self.recipe = nil
    }
    private enum CodingKeys: String, CodingKey { case assetId, score, rejected, recipe }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(assetId, forKey: .assetId)
        try values.encode(score, forKey: .score)
        try values.encode(rejected, forKey: .rejected)
        try values.encodeIfPresent(recipe, forKey: .recipe)
    }
}
public struct VoiceLabProvenance: Codable, Sendable, Equatable {
    public var provider: String
    public var endpoint: String
    public var model: String
    public var voiceId: String
    public var consentRecordId: String?
    public var requestId: String?
    public var seed: UInt32?
    public var createdAt: Date
    public var region: String?
    public init(provider: String, endpoint: String, model: String, voiceId: String, consentRecordId: String?, requestId: String?, seed: UInt32?, createdAt: Date) {
        self.provider = provider; self.endpoint = endpoint; self.model = model; self.voiceId = voiceId
        self.consentRecordId = consentRecordId; self.requestId = requestId; self.seed = seed; self.createdAt = createdAt
        self.region = nil
    }
    private enum CodingKeys: String, CodingKey { case provider, endpoint, model, voiceId, consentRecordId, requestId, seed, createdAt, region }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(provider, forKey: .provider); try values.encode(endpoint, forKey: .endpoint)
        try values.encode(model, forKey: .model); try values.encode(voiceId, forKey: .voiceId)
        try values.encode(consentRecordId, forKey: .consentRecordId)
        try values.encode(requestId, forKey: .requestId); try values.encode(seed, forKey: .seed)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(region, forKey: .region)
    }
}
public struct VoiceLabQA: Codable, Sendable, Equatable {
    public var transcriptMatch: Double?
    public var lufsJumpLu: Double?
    public var peakDbfs: Double?
    public var speakerScore: Double?
    public init(transcriptMatch: Double? = nil, lufsJumpLu: Double? = nil, peakDbfs: Double? = nil, speakerScore: Double? = nil) {
        self.transcriptMatch = transcriptMatch; self.lufsJumpLu = lufsJumpLu; self.peakDbfs = peakDbfs; self.speakerScore = speakerScore
    }
    private enum CodingKeys: String, CodingKey { case transcriptMatch, lufsJumpLu, peakDbfs, speakerScore }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(transcriptMatch, forKey: .transcriptMatch)
        try values.encode(lufsJumpLu, forKey: .lufsJumpLu); try values.encode(peakDbfs, forKey: .peakDbfs)
        try values.encode(speakerScore, forKey: .speakerScore)
    }
}
public struct VoiceLabSegment: Codable, Sendable, Equatable {
    public var id: String
    public var kind: VoiceLabSegmentKind
    public var enabled: Bool
    public var replace: VoiceLabReplacement
    public var outDuration: Double
    public var audio: VoiceLabAudio
    public var text: VoiceLabText?
    public var words: [VoiceLabWord]?
    public var provenance: VoiceLabProvenance
    public var qa: VoiceLabQA
    public var candidates: [VoiceLabCandidate]
    public var selectedCandidateIndex: Int
    public var scope: VoiceLabSegmentScope?
    public var groupId: String?
    public init(id: String, kind: VoiceLabSegmentKind, enabled: Bool, replace: VoiceLabReplacement, outDuration: Double, audio: VoiceLabAudio, text: VoiceLabText?, words: [VoiceLabWord]?, provenance: VoiceLabProvenance, qa: VoiceLabQA, candidates: [VoiceLabCandidate], selectedCandidateIndex: Int) {
        self.id = id; self.kind = kind; self.enabled = enabled; self.replace = replace; self.outDuration = outDuration
        self.audio = audio; self.text = text; self.words = words; self.provenance = provenance; self.qa = qa
        self.candidates = candidates; self.selectedCandidateIndex = selectedCandidateIndex
        self.scope = nil; self.groupId = nil
    }
    private enum CodingKeys: String, CodingKey { case id, kind, enabled, replace, outDuration, audio, text, words, provenance, qa, candidates, selectedCandidateIndex, scope, groupId }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(kind, forKey: .kind)
        try values.encode(enabled, forKey: .enabled); try values.encode(replace, forKey: .replace)
        try values.encode(outDuration, forKey: .outDuration); try values.encode(audio, forKey: .audio)
        try values.encode(text, forKey: .text); try values.encode(words, forKey: .words)
        try values.encode(provenance, forKey: .provenance); try values.encode(qa, forKey: .qa)
        try values.encode(candidates, forKey: .candidates)
        try values.encode(selectedCandidateIndex, forKey: .selectedCandidateIndex)
        try values.encodeIfPresent(scope, forKey: .scope)
        try values.encodeIfPresent(groupId, forKey: .groupId)
    }
}

public enum VoiceLabProjectError: Error, Equatable, Sendable {
    case invalidAsset, unsafePath, invalidSegment, invalidRange, invalidWords, danglingAsset, overlappingReplacement
    case missingSegment, invalidCandidate, unsupportedRendering, invalidScope
    case missingRenderPolicy, needsVoiceLabUpgrade, videoModeUnsupported, alignmentUnavailable, consentUnverified
    case qaRejected, invalidFadeHandles, overlappingFades, unsupportedAssetFormat, cleanAudioUnsupported, staleRenderContract, endpointUnsupported
    case legacySegmentsNeedReview, requiresVersion3, invalidVoice, missingVoice
}

/// The §10.1 paid-asset file rule, shared by Core validation (also for §10.5 video assets) and the Media writers that name new assets.
public enum VoiceLabAssetNaming {
    /// Returns the relative `<projectId>/<assetId>.wav` or `.flac` name under the caller's paid Voice Lab store.
    public static func file(projectId: String, assetId: String, extension fileExtension: String) throws -> String {
        guard let file = safeFile(projectId: projectId, assetId: assetId, extension: fileExtension) else { throw VoiceLabProjectError.invalidAsset }
        return file
    }
    static func isSafeProjectID(_ projectId: String) -> Bool {
        VoiceLabProject.matches(projectId, "[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
    }
    static func safeFile(projectId: String, assetId: String, extension fileExtension: String) -> String? {
        fileExtension == "wav" || fileExtension == "flac" ? safeName(projectId, assetId, fileExtension) : nil
    }
    /// A §10.5 video asset follows the same rule, always with the `mp4` extension.
    static func safeVideoFile(projectId: String, assetId: String) -> String? { safeName(projectId, assetId, "mp4") }
    private static func safeName(_ projectId: String, _ assetId: String, _ fileExtension: String) -> String? {
        guard isSafeProjectID(projectId), VoiceLabProject.matches(assetId, "[a-z0-9][a-z0-9_-]{0,63}"),
              !VoiceLabProject.matches(assetId, "con|prn|aux|nul|com[1-9]|lpt[1-9]") else { return nil }
        return projectId + "/" + assetId + "." + fileExtension
    }
}

public enum VoiceLabProject {
    private static let id = "[A-Za-z0-9][A-Za-z0-9._:-]{0,63}"
    /// The ElevenLabs client's path-safe ID rule, anchored so a trailing newline is refused.
    private static let providerVoiceID = "[A-Za-z0-9_-]{1,128}"
    fileprivate static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }
    public static func validate(_ project: Project) throws {
        if project.schemaVersion == 1 {
            guard project.voiceLab.segments.isEmpty, project.voiceLab.assets == nil,
                  project.voiceLab.cleanAudio == nil, project.voiceLab.voices == nil, project.voiceLab.videoAssets == nil else { throw VoiceLabProjectError.invalidSegment }
            return
        }
        guard (project.schemaVersion == 2 || project.schemaVersion == 3), let assets = project.voiceLab.assets else { throw VoiceLabProjectError.invalidSegment }
        if project.schemaVersion == 2 && (project.voiceLab.cleanAudio != nil || project.voiceLab.voices != nil || project.voiceLab.videoAssets != nil || project.voiceLab.segments.contains(where: { $0.scope != nil || $0.groupId != nil || $0.provenance.region != nil || $0.candidates.contains(where: { $0.recipe != nil }) })) { throw VoiceLabProjectError.invalidSegment }
        guard VoiceLabAssetNaming.isSafeProjectID(project.id) else {
            throw VoiceLabProjectError.unsafePath
        }
        let assetIDs = Set(assets.map(\.id))
        guard assetIDs.count == assets.count else { throw VoiceLabProjectError.invalidAsset }
        for asset in assets {
            guard matches(asset.id, id), asset.kind == "audio", matches(asset.sha256, "[0-9a-f]{64}"),
                  asset.durationSeconds.isFinite, asset.durationSeconds > 0, asset.sampleRate > 0 else { throw VoiceLabProjectError.invalidAsset }
            // A stored file must be exactly the §10.1 name for its own asset ID.
            let fileExtension = asset.file.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            guard VoiceLabAssetNaming.safeFile(projectId: project.id, assetId: asset.id, extension: fileExtension) == asset.file else {
                throw VoiceLabProjectError.unsafePath
            }
        }
        let words = project.transcript?.words ?? []
        let sourceRate = Double(project.media.source.audio?.sampleRate ?? 48_000)
        guard sourceRate > 0, project.media.source.durationSeconds.isFinite,
              project.media.source.durationSeconds * sourceRate < Double(Int64.max) else { throw VoiceLabProjectError.invalidRange }
        var sourceWordIDs = Set<String>()
        guard words.allSatisfy({ matches($0.id, id) && sourceWordIDs.insert($0.id).inserted }) else {
            throw VoiceLabProjectError.invalidRange
        }
        let wordIndex = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($0.element.id, $0.offset) })
        var segmentIDs = Set<String>()
        var enabled: [(Double, Double)] = []
        for segment in project.voiceLab.segments {
            guard matches(segment.id, id), segmentIDs.insert(segment.id).inserted,
                  segment.outDuration.isFinite, segment.outDuration > 0,
                  (segment.outDuration * sourceRate).isFinite, segment.outDuration * sourceRate < Double(Int64.max) else { throw VoiceLabProjectError.invalidSegment }
            let range = segment.replace
            guard range.start.isFinite, range.end.isFinite, range.start >= 0, range.end > range.start,
                  range.end <= project.media.source.durationSeconds,
                  let first = wordIndex[range.firstWordId], let last = wordIndex[range.lastWordId], first <= last,
                  words[first].start >= range.start, words[last].end <= range.end,
                  words.first(where: { $0.start >= range.start && $0.end <= range.end })?.id == range.firstWordId,
                  words.last(where: { $0.start >= range.start && $0.end <= range.end })?.id == range.lastWordId,
                  !words.contains(where: { $0.start < range.start && $0.end > range.start || $0.start < range.end && $0.end > range.end }) else { throw VoiceLabProjectError.invalidRange }
            guard let asset = assets.first(where: { $0.id == segment.audio.assetId }) else { throw VoiceLabProjectError.danglingAsset }
            let audio = segment.audio
            guard audio.trimStart.isFinite, audio.trimEnd.isFinite, audio.stretch.isFinite, audio.gainDb.isFinite,
                  audio.trimStart >= 0, audio.trimEnd > audio.trimStart, audio.trimEnd <= asset.durationSeconds,
                  audio.stretch > 0, VoiceLabRenderValidation.contentMatchesDuration(audio, outDuration: segment.outDuration,
                                                                                  assetSampleRate: asset.sampleRate) else { throw VoiceLabProjectError.invalidSegment }
            guard !segment.candidates.isEmpty, segment.candidates.indices.contains(segment.selectedCandidateIndex),
                  segment.candidates[segment.selectedCandidateIndex].assetId == audio.assetId,
                  segment.candidates[segment.selectedCandidateIndex].rejected == nil else { throw VoiceLabProjectError.invalidCandidate }
            for candidate in segment.candidates {
                if let candidateID = candidate.assetId, !assetIDs.contains(candidateID) { throw VoiceLabProjectError.danglingAsset }
                if let score = candidate.score, (!score.isFinite || score < 0 || score > 1) { throw VoiceLabProjectError.invalidCandidate }
                if candidate.rejected == nil && (candidate.assetId == nil || candidate.score == nil) { throw VoiceLabProjectError.invalidCandidate }
            }
            let provenance = segment.provenance
            guard matches(provenance.provider, "[a-z0-9-]+"), !provenance.endpoint.isEmpty, !provenance.endpoint.contains("://"),
                  !provenance.model.isEmpty, !provenance.voiceId.isEmpty,
                  provenance.consentRecordId.map({ matches($0, id) }) ?? true,
                  provenance.requestId.map({ matches($0, id) }) ?? true else { throw VoiceLabProjectError.invalidSegment }
            let qa = segment.qa
            for value in [qa.transcriptMatch, qa.lufsJumpLu, qa.peakDbfs, qa.speakerScore].compactMap({ $0 }) {
                guard value.isFinite else { throw VoiceLabProjectError.invalidSegment }
            }
            if let match = qa.transcriptMatch, !(0...1).contains(match) { throw VoiceLabProjectError.invalidSegment }
            if let score = qa.speakerScore, !(0...1).contains(score) { throw VoiceLabProjectError.invalidSegment }
            switch segment.kind {
            case .tts:
                guard let text = segment.text, !text.new.isEmpty, let captionWords = segment.words, !captionWords.isEmpty else { throw VoiceLabProjectError.invalidWords }
                var previous = 0.0
                for word in captionWords {
                    guard !word.text.isEmpty, word.start.isFinite, word.end.isFinite, word.start >= previous,
                          word.end > word.start, word.end <= segment.outDuration,
                          EditingPrimitives.jsRound(word.end * sourceRate) > EditingPrimitives.jsRound(word.start * sourceRate) else {
                        throw VoiceLabProjectError.invalidWords
                    }
                    previous = word.end
                }
            case .voiceChanger:
                guard segment.text == nil, segment.words == nil else { throw VoiceLabProjectError.invalidWords }
            }
            if segment.enabled { enabled.append((range.start, range.end)) }
        }
        enabled.sort { $0.0 < $1.0 }
        if enabled.count > 1 {
            for index in 1..<enabled.count where enabled[index].0 < enabled[index - 1].1 { throw VoiceLabProjectError.overlappingReplacement }
        }
        if project.schemaVersion == 3 { try VoiceLabRenderValidation.validate(project) }
    }

    /// The only v1/v2 to v3 promotion (§10.1, §10.5); loading and saving never call it. A v2 segment needs explicit review.
    public static func upgradeToV3(_ project: Project) throws -> Project {
        try validate(project)
        if project.schemaVersion == 3 { return project }
        guard project.voiceLab.segments.isEmpty else { throw VoiceLabProjectError.legacySegmentsNeedReview }
        var result = project
        result.schemaVersion = 3
        result.voiceLab = ProjectVoiceLab(segments: [], assets: project.voiceLab.assets ?? [], cleanAudio: VoiceLabCleanAudio(mode: .off),
                                          voices: [], videoAssets: [])
        try validate(result)
        return result
    }

    /// Appends a reviewed v3 segment; v1 and segment-free v2 projects are upgraded first, so accept never writes v2.
    public static func accept(_ segment: VoiceLabSegment, assets: [VoiceLabAsset], into project: Project) throws -> Project {
        var result = try project.schemaVersion == 3 ? project : upgradeToV3(project)
        guard segment.candidates.indices.contains(segment.selectedCandidateIndex) else { throw VoiceLabProjectError.invalidCandidate }
        guard Set(assets.map(\.id)).count == assets.count,
              assets.allSatisfy({ asset in result.voiceLab.assets?.contains(where: { $0.id == asset.id }) == false }) else { throw VoiceLabProjectError.invalidAsset }
        result.voiceLab.assets?.append(contentsOf: assets)
        guard !result.voiceLab.segments.contains(where: { $0.id == segment.id }) else { throw VoiceLabProjectError.invalidSegment }
        result.voiceLab.segments.append(segment)
        // Every unrejected own-voice candidate is a new take, selected or not, so each needs an active consent reference (§6.10, §10.5).
        for candidate in segment.candidates where candidate.rejected == nil {
            guard let recipe = candidate.recipe, recipe.voiceSource == .own else { continue }
            guard result.voiceLab.voices?.first(where: { $0.id == recipe.voiceRefId })?.status == .active else { throw VoiceLabProjectError.consentUnverified }
        }
        try validate(result)
        return result
    }
    /// Adds an own-voice consent reference (§6.8, §10.5). The project stores only IDs and the trimmed display name.
    public static func addVoiceReference(_ reference: VoiceLabVoiceReference, to project: Project) throws -> Project {
        guard project.schemaVersion == 3 else { throw VoiceLabProjectError.requiresVersion3 }
        var voice = reference
        // §6.1: the name counts 1–60 Unicode scalars after trimming whitespace, and the trimmed name is stored.
        voice.displayName = reference.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let voices = project.voiceLab.voices ?? []
        guard matches(voice.id, id), !voices.contains(where: { $0.id == voice.id }), matches(voice.consentRecordId, id),
              voice.provider == "elevenlabs", matches(voice.voiceId, providerVoiceID), voice.status == .active,
              (1...60).contains(voice.displayName.unicodeScalars.count),
              !voices.contains(where: { $0.status == .active && $0.provider == voice.provider && $0.voiceId == voice.voiceId }) else {
            throw VoiceLabProjectError.invalidVoice
        }
        var result = project
        result.voiceLab.voices = voices + [voice]
        try validate(result)
        return result
    }
    /// Records provider deletion (§6.10). The reference, segments and paid assets stay; new own-voice accepts are refused.
    public static func markVoiceDeleted(id voiceID: String, in project: Project) throws -> Project {
        // §10.5: only version 3 holds voice references, so versions 1 and 2 report requiresVersion3.
        guard project.schemaVersion == 3 else { throw VoiceLabProjectError.requiresVersion3 }
        guard let index = project.voiceLab.voices?.firstIndex(where: { $0.id == voiceID }) else { throw VoiceLabProjectError.missingVoice }
        var result = project
        result.voiceLab.voices?[index].status = .deleted
        try validate(result)
        return result
    }
    public static func setEnabled(_ enabled: Bool, id: String, in project: Project) throws -> Project {
        var result = project
        guard let index = result.voiceLab.segments.firstIndex(where: { $0.id == id }) else { throw VoiceLabProjectError.missingSegment }
        result.voiceLab.segments[index].enabled = enabled
        try validate(result); return result
    }
    public static func delete(id: String, in project: Project) throws -> Project {
        var result = project
        guard result.voiceLab.segments.contains(where: { $0.id == id }) else { throw VoiceLabProjectError.missingSegment }
        result.voiceLab.segments.removeAll { $0.id == id }
        try validate(result); return result
    }
    /// Voice status is not checked: accept verified consent for every unrejected candidate, and its stored evidence keeps the take renderable (§10.5).
    public static func selectCandidate(_ index: Int, id: String, in project: Project) throws -> Project {
        var result = project
        guard let position = result.voiceLab.segments.firstIndex(where: { $0.id == id }) else { throw VoiceLabProjectError.missingSegment }
        let candidates = result.voiceLab.segments[position].candidates
        guard candidates.indices.contains(index), let assetID = candidates[index].assetId, candidates[index].rejected == nil,
              let asset = result.voiceLab.assets?.first(where: { $0.id == assetID }) else { throw VoiceLabProjectError.invalidCandidate }
        result.voiceLab.segments[position].selectedCandidateIndex = index
        if result.schemaVersion == 3 {
            guard let recipe = candidates[index].recipe else { throw VoiceLabProjectError.missingRenderPolicy }
            result.voiceLab.segments[position].outDuration = recipe.outDuration
            result.voiceLab.segments[position].audio = recipe.audio
            result.voiceLab.segments[position].words = recipe.words
            result.voiceLab.segments[position].provenance = recipe.provenance
            result.voiceLab.segments[position].qa = VoiceLabQA(transcriptMatch: recipe.qa.transcriptMatch, lufsJumpLu: recipe.qa.lufsJumpLu, peakDbfs: recipe.qa.peakDbfs, speakerScore: recipe.qa.speakerScore)
            try validate(result); return result
        }
        result.voiceLab.segments[position].audio.assetId = assetID
        result.voiceLab.segments[position].audio.trimStart = 0
        result.voiceLab.segments[position].audio.trimEnd = asset.durationSeconds
        result.voiceLab.segments[position].audio.stretch = result.voiceLab.segments[position].outDuration / asset.durationSeconds
        try validate(result); return result
    }
    /// Existing EditPlan-only Media consumers must call this before rendering a project.
    public static func requireLegacyRendering(_ project: Project) throws {
        if project.voiceLab.segments.contains(where: \.enabled) { throw VoiceLabProjectError.unsupportedRendering }
    }
    public static func requireLegacyRendering(_ project: Project, scope: VoiceLabOutputScope) throws {
        guard project.voiceLab.segments.contains(where: \.enabled) else { return }
        try VoiceLabOutputPlanner.build(project, scope: scope).requireLegacyRendering()
    }
}
