import Foundation

/// Explicit schema-v3 choices. Optional properties on older records are never inferred at render time.
public enum VoiceLabSegmentScope: String, Codable, Sendable { case passage, fullTake }
public enum VoiceLabCleanAudioMode: String, Codable, Sendable { case off, on }
public struct VoiceLabCleanAudio: Codable, Sendable, Equatable {
    public var mode: VoiceLabCleanAudioMode
    public var assetId: String?
    public var mix: Double?
    public init(mode: VoiceLabCleanAudioMode, assetId: String? = nil, mix: Double? = nil) {
        self.mode = mode; self.assetId = assetId; self.mix = mix
    }
    private enum CodingKeys: String, CodingKey { case mode, assetId, mix }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode)
        try values.encode(assetId, forKey: .assetId)
        try values.encode(mix, forKey: .mix)
    }
}
public enum VoiceLabVoiceStatus: String, Codable, Sendable { case active, deleted }
public struct VoiceLabVoiceReference: Codable, Sendable, Equatable {
    public var id: String
    public var provider: String
    public var voiceId: String
    public var consentRecordId: String
    public var displayName: String
    public var status: VoiceLabVoiceStatus
    public init(id: String, provider: String, voiceId: String, consentRecordId: String, displayName: String, status: VoiceLabVoiceStatus) {
        self.id = id; self.provider = provider; self.voiceId = voiceId; self.consentRecordId = consentRecordId
        self.displayName = displayName; self.status = status
    }
}
public struct VoiceLabRoomTone: Codable, Sendable, Equatable {
    public var sourceStartSample: Int64
    public var sourceEndSample: Int64
    public var gainDb: Double
    public init(sourceStartSample: Int64, sourceEndSample: Int64, gainDb: Double) {
        self.sourceStartSample = sourceStartSample; self.sourceEndSample = sourceEndSample; self.gainDb = gainDb
    }
}
public struct VoiceLabVideoAsset: Codable, Sendable, Equatable {
    public var id: String
    public var file: String
    public var sha256: String
    public var durationSeconds: Double
    public var frameRate: Double
    public var width: Int
    public var height: Int
    public init(id: String, file: String, sha256: String, durationSeconds: Double, frameRate: Double, width: Int, height: Int) {
        self.id = id; self.file = file; self.sha256 = sha256; self.durationSeconds = durationSeconds
        self.frameRate = frameRate; self.width = width; self.height = height
    }
}
public enum VoiceLabSeamKind: String, Codable, Sendable { case none, gap, hard, synthToSynth }
public struct VoiceLabSeam: Codable, Sendable, Equatable {
    public var kind: VoiceLabSeamKind
    public var fadeSamples: Int64
    public var sourceHandleSamples: Int64
    public var assetHandleFrames: Int64
    public init(kind: VoiceLabSeamKind, fadeSamples: Int64, sourceHandleSamples: Int64, assetHandleFrames: Int64) {
        self.kind = kind; self.fadeSamples = fadeSamples
        self.sourceHandleSamples = sourceHandleSamples; self.assetHandleFrames = assetHandleFrames
    }
}
public struct VoiceLabSeams: Codable, Sendable, Equatable {
    public var `in`: VoiceLabSeam
    public var out: VoiceLabSeam
    public init(in incoming: VoiceLabSeam, out: VoiceLabSeam) {
        self.in = incoming; self.out = out
    }
}
public struct VoiceLabChunk: Codable, Sendable, Equatable {
    public var sourceStartSample: Int64
    public var sourceEndSample: Int64
    public var requestId: String
    public var seed: UInt32
    public var assetId: String
    public var assetSha256: String
    public var assembledStartFrame: Int64
    public var assembledEndFrame: Int64
    public init(sourceStartSample: Int64, sourceEndSample: Int64, requestId: String, seed: UInt32, assetId: String,
                assetSha256: String, assembledStartFrame: Int64, assembledEndFrame: Int64) {
        self.sourceStartSample = sourceStartSample; self.sourceEndSample = sourceEndSample
        self.requestId = requestId; self.seed = seed; self.assetId = assetId; self.assetSha256 = assetSha256
        self.assembledStartFrame = assembledStartFrame; self.assembledEndFrame = assembledEndFrame
    }
}
public enum VoiceLabVideoMode: String, Codable, Sendable { case source, retimed, zoomCover, lipsync }
public struct VoiceLabVideoRecipe: Codable, Sendable, Equatable {
    public var mode: VoiceLabVideoMode
    public var sourceStartSample: Int64
    public var sourceEndSample: Int64
    public var outputSamples: Int64
    public var retimeFactor: Double?
    public var zoom: Double?
    public var faceX: Double?
    public var faceY: Double?
    public var assetId: String?
    public var provider: String?
    public var model: String?
    public var requestId: String?
    public var windowStartSample: Int64?
    public var windowEndSample: Int64?
    public var syncMode: String?
    public init(mode: VoiceLabVideoMode, sourceStartSample: Int64, sourceEndSample: Int64, outputSamples: Int64,
                retimeFactor: Double?, zoom: Double?, faceX: Double?, faceY: Double?, assetId: String?,
                provider: String?, model: String?, requestId: String?, windowStartSample: Int64?,
                windowEndSample: Int64?, syncMode: String?) {
        self.mode = mode; self.sourceStartSample = sourceStartSample; self.sourceEndSample = sourceEndSample
        self.outputSamples = outputSamples; self.retimeFactor = retimeFactor; self.zoom = zoom
        self.faceX = faceX; self.faceY = faceY; self.assetId = assetId; self.provider = provider
        self.model = model; self.requestId = requestId; self.windowStartSample = windowStartSample
        self.windowEndSample = windowEndSample; self.syncMode = syncMode
    }
    private enum CodingKeys: String, CodingKey {
        case mode, sourceStartSample, sourceEndSample, outputSamples, retimeFactor, zoom, faceX, faceY, assetId, provider, model, requestId
        case windowStartSample, windowEndSample, syncMode
    }
    /// Writes every key, with null for the fields a mode does not use, as Windows and the schema require.
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode); try values.encode(sourceStartSample, forKey: .sourceStartSample)
        try values.encode(sourceEndSample, forKey: .sourceEndSample); try values.encode(outputSamples, forKey: .outputSamples)
        try values.encode(retimeFactor, forKey: .retimeFactor); try values.encode(zoom, forKey: .zoom)
        try values.encode(faceX, forKey: .faceX); try values.encode(faceY, forKey: .faceY)
        try values.encode(assetId, forKey: .assetId); try values.encode(provider, forKey: .provider)
        try values.encode(model, forKey: .model); try values.encode(requestId, forKey: .requestId)
        try values.encode(windowStartSample, forKey: .windowStartSample); try values.encode(windowEndSample, forKey: .windowEndSample)
        try values.encode(syncMode, forKey: .syncMode)
    }
}
public enum VoiceLabVoiceSource: String, Codable, Sendable { case own, stock }
public struct VoiceLabRenderQA: Codable, Sendable, Equatable {
    public var transcriptTokens: Int?
    public var transcriptExact: Bool?
    public var transcriptMatch: Double?
    public var lufsJumpLu: Double
    public var peakDbfs: Double
    public var speakerScore: Double?
    public var speakerThreshold: Double?
    public var speakerModel: String?
    public var speakerPassed: Bool?
    public init(transcriptTokens: Int?, transcriptExact: Bool?, transcriptMatch: Double?, lufsJumpLu: Double,
                peakDbfs: Double, speakerScore: Double?, speakerThreshold: Double?, speakerModel: String?, speakerPassed: Bool?) {
        self.transcriptTokens = transcriptTokens; self.transcriptExact = transcriptExact; self.transcriptMatch = transcriptMatch
        self.lufsJumpLu = lufsJumpLu; self.peakDbfs = peakDbfs; self.speakerScore = speakerScore
        self.speakerThreshold = speakerThreshold; self.speakerModel = speakerModel; self.speakerPassed = speakerPassed
    }
    private enum CodingKeys: String, CodingKey { case transcriptTokens, transcriptExact, transcriptMatch, lufsJumpLu, peakDbfs, speakerScore, speakerThreshold, speakerModel, speakerPassed }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(transcriptTokens, forKey: .transcriptTokens)
        try values.encode(transcriptExact, forKey: .transcriptExact)
        try values.encode(transcriptMatch, forKey: .transcriptMatch)
        try values.encode(lufsJumpLu, forKey: .lufsJumpLu)
        try values.encode(peakDbfs, forKey: .peakDbfs)
        try values.encode(speakerScore, forKey: .speakerScore)
        try values.encode(speakerThreshold, forKey: .speakerThreshold)
        try values.encode(speakerModel, forKey: .speakerModel)
        try values.encode(speakerPassed, forKey: .speakerPassed)
    }
}
public struct VoiceLabCost: Codable, Sendable, Equatable {
    public var quoteId: String
    public var usd: Double?
    public init(quoteId: String, usd: Double?) {
        self.quoteId = quoteId; self.usd = usd
    }
    private enum CodingKeys: String, CodingKey { case quoteId, usd }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(quoteId, forKey: .quoteId)
        try values.encode(usd, forKey: .usd)
    }
}
public struct VoiceLabRenderRecipe: Codable, Sendable, Equatable {
    public var audio: VoiceLabAudio
    public var words: [VoiceLabWord]?
    public var outDuration: Double
    public var seed: UInt32
    public var chunks: [VoiceLabChunk]
    public var roomTone: VoiceLabRoomTone?
    public var seams: VoiceLabSeams
    public var video: VoiceLabVideoRecipe
    public var qa: VoiceLabRenderQA
    public var provenance: VoiceLabProvenance
    public var cost: VoiceLabCost
    public var voiceSource: VoiceLabVoiceSource
    public var voiceRefId: String?
    public var consentVerifiedAt: Date?
    public init(audio: VoiceLabAudio, words: [VoiceLabWord]?, outDuration: Double, seed: UInt32,
                chunks: [VoiceLabChunk], roomTone: VoiceLabRoomTone?, seams: VoiceLabSeams, video: VoiceLabVideoRecipe,
                qa: VoiceLabRenderQA, provenance: VoiceLabProvenance, cost: VoiceLabCost,
                voiceSource: VoiceLabVoiceSource, voiceRefId: String?, consentVerifiedAt: Date?) {
        self.audio = audio; self.words = words; self.outDuration = outDuration; self.seed = seed
        self.chunks = chunks; self.roomTone = roomTone; self.seams = seams; self.video = video
        self.qa = qa; self.provenance = provenance; self.cost = cost; self.voiceSource = voiceSource
        self.voiceRefId = voiceRefId; self.consentVerifiedAt = consentVerifiedAt
    }
    private enum CodingKeys: String, CodingKey { case audio, words, outDuration, seed, chunks, roomTone, seams, video, qa, provenance, cost, voiceSource, voiceRefId, consentVerifiedAt }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(audio, forKey: .audio); try values.encode(words, forKey: .words); try values.encode(outDuration, forKey: .outDuration)
        try values.encode(seed, forKey: .seed); try values.encode(chunks, forKey: .chunks)
        try values.encode(roomTone, forKey: .roomTone); try values.encode(seams, forKey: .seams)
        try values.encode(video, forKey: .video); try values.encode(qa, forKey: .qa)
        try values.encode(provenance, forKey: .provenance); try values.encode(cost, forKey: .cost)
        try values.encode(voiceSource, forKey: .voiceSource); try values.encode(voiceRefId, forKey: .voiceRefId)
        try values.encode(consentVerifiedAt, forKey: .consentVerifiedAt)
    }
}
