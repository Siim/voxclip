import Foundation

/// "A matching voice for each video" (voice-lab §6.13, ADR-R45): a clone made from one video's own owner-verified
/// speech, used for every Rewrite take of that video, with the consent voice (the anchor) as the fallback. Pure; the
/// Media finder supplies the speech, the attested creation sends it, and `VoicePerVideoStore` remembers it.
///
/// Clips of one video share its microphone, room and noise, so the voice is per video, never per clip: a 20–45 s clip
/// is too little speech for a clone.
public enum VoicePerVideo {
    /// The cleanliness floor for a video's own speech. Creation then sets `remove_background_noise` (§6.5 step 5), and
    /// the tone match and room tone at render put the room back. Identity is unchanged: every piece is one hop at τ.
    /// Chosen from the measurement in ADR-R45.
    public static let minimumSnrDb = 8.0
    /// The video's own speech a voice needs, the anchor's clip not counted, so the clone is the video's and not the
    /// statement's. Below it the video keeps the anchor and says so once.
    public static let minimumVideoMs = VoiceTrainingSpans.TRAIN_TOTAL_MIN
    /// The setting the one-time opt-in writes.
    public static let settingKey = "voiceLab.matchEachVideo"
    /// The longest display name a voice takes (§6.7); " (VoxClip)" is added after it.
    public static let maximumNameScalars = 60

    /// The remembered answer to "Make a matching voice from this video?".
    public enum Mode: String, Sendable, Equatable {
        /// Unset: the first Rewrite, Make it postable or Claude-mode run on a video asks, inline.
        case ask
        /// Each video gets its own voice; the previous video's is removed.
        case match
        /// Every video uses the anchor.
        case anchor
        public init(setting: Bool?) { self = setting.map { $0 ? .match : .anchor } ?? .ask }
        public var setting: Bool? { switch self { case .ask: nil; case .match: true; case .anchor: false } }
    }

    /// Creation removes background noise when any of the video's pieces is under the §6.5.1 clean-speech floor.
    public static func removesBackgroundNoise(_ plan: VoiceRebuild.Plan) -> Bool {
        plan.pieces.contains { $0.snrDb < VoiceTrainingSpans.TRAIN_MIN_SNR }
    }

    /// The video's own speech in a plan, the anchor's clip not counted.
    public static func videoMs(_ plan: VoiceRebuild.Plan) -> Int { plan.totalMs - (plan.keptMs ?? 0) }

    /// "siim · DJI_0030": the anchor's display name, a middle dot and the video's title, within 60 scalars (the title is
    /// cut first, at a scalar). Control characters and line breaks in the title become spaces; an empty title keeps the
    /// anchor's name alone.
    public static func displayName(owner: String, title: String) -> String {
        let clean = String(String.UnicodeScalarView(title.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : $0 }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerScalars = Array(owner.unicodeScalars.prefix(maximumNameScalars))
        guard !clean.isEmpty, ownerScalars.count + 3 < maximumNameScalars else { return String(String.UnicodeScalarView(ownerScalars)) }
        let room = maximumNameScalars - ownerScalars.count - 3
        let cut = String(String.UnicodeScalarView(clean.unicodeScalars.prefix(room))).trimmingCharacters(in: .whitespaces)
        return String(String.UnicodeScalarView(ownerScalars)) + " · " + cut
    }

    /// A video's title: its media file's name without the extension.
    public static func title(mediaPath: String) -> String {
        URL(fileURLWithPath: mediaPath).deletingPathExtension().lastPathComponent
    }

    /// Why the previous video's voice is kept for now, or nil when it may be removed.
    public enum Keep: String, Sendable, Equatable {
        /// The consent voice: never removed by this flow.
        case anchor
        /// Its project still holds paid takes nobody used or discarded yet.
        case pendingTakes
        /// It is the voice being made or used now.
        case current
    }

    /// Whether `recordID`, the voice of a video before this one, may be removed now. Takes already rendered into a
    /// project never keep it: rendered assets stay playable after deletion (§6.10).
    public static func keep(_ recordID: String, anchorID: String, currentID: String, pendingTakes: Set<String>) -> Keep? {
        if recordID == anchorID { return .anchor }
        if recordID == currentID { return .current }
        if pendingTakes.contains(recordID) { return .pendingTakes }
        return nil
    }

    /// Seeds a new video voice's length calibration from the anchor's (§8.2.2): its measured takes start the new voice's
    /// estimate, and the new voice's own takes then replace them as they arrive (the last N per model are kept).
    public static func seededCalibration(from anchor: VoiceLabVoiceCalibration, recordId: String) -> VoiceLabVoiceCalibration {
        VoiceLabVoiceCalibration(recordId: recordId, models: anchor.models, seeded: true)
    }
}

extension VoicePerVideo {
    /// The most earlier takes the anchor's baseline reads (voice-lab §6.13), newest first.
    public static let maximumBaselineTakes = 12

    /// The anchor's earlier takes in a project, newest first: accepted (enabled) text-to-speech segments made with the
    /// voice `anchorID`, each with its asset. A recorded take, a voice-changed one, another voice's take and a take the
    /// user turned off are not the anchor's.
    public static func anchorTakes(in project: Project, anchorID: String) -> [(segment: VoiceLabSegment, asset: VoiceLabAsset)] {
        let assets = project.voiceLab.assets ?? []
        let takes = project.voiceLab.segments.compactMap { segment -> (segment: VoiceLabSegment, asset: VoiceLabAsset)? in
            guard segment.kind == .tts, segment.enabled, segment.provenance.consentRecordId == anchorID,
                  let asset = assets.first(where: { $0.id == segment.audio.assetId }) else { return nil }
            return (segment, asset)
        }
        return takes.sorted { left, right in
            left.segment.provenance.createdAt == right.segment.provenance.createdAt
                ? left.segment.id < right.segment.id : left.segment.provenance.createdAt > right.segment.provenance.createdAt
        }
    }

    /// "Match this video · free": the creation price from the catalogue's `createClone` row; nil when it has no price,
    /// which the opt-in then says instead of inventing one.
    public static func priceLabel(catalog: VoiceLabPriceCatalog?) -> String? {
        guard let catalog, let estimate = try? VoiceLabPricing.estimate(operation: .elevenLabsCreateClone, model: nil, units: 1, catalog: catalog),
              let usd = estimate.usd else { return nil }
        return usd == 0 ? "free" : VoiceLabCostPresentation.format(usd)
    }
}

/// What Voice Lab remembers about per-video voices, in app data (`<data>/VoiceLab/per-video.json`), never in a project
/// file: which voice each video's `contentKey` uses, the removals still owed, the videos already told they keep the
/// anchor, and the "did matching help" diagnostics.
public struct VoicePerVideoBook: Codable, Sendable, Equatable {
    public static let schema = "voxclip-voice-per-video/1"
    /// Diagnostics kept, newest first.
    public static let maximumMeasurements = 12

    public struct Video: Codable, Sendable, Equatable {
        public var contentKey: String
        /// The video's own voice.
        public var recordId: String
        /// The consent voice it was made from: its consent clip is the new voice's first file, so the new record's
        /// embedding is the anchor's own and the one-hop bound is unchanged.
        public var anchorId: String
        /// That consent clip's SHA-256, as sent first: the link back to the anchor's consent.
        public var anchorReferenceSha256: String
        public var title: String
        public var createdAt: String
        /// The video's own speech in the voice, the anchor's clip not counted.
        public var videoSeconds: Double
        /// Creation asked ElevenLabs to remove background noise (a piece was under 20 dB SNR).
        public var removesBackgroundNoise: Bool
        public init(contentKey: String, recordId: String, anchorId: String, anchorReferenceSha256: String, title: String, createdAt: String,
                    videoSeconds: Double, removesBackgroundNoise: Bool) {
            self.contentKey = contentKey; self.recordId = recordId; self.anchorId = anchorId; self.anchorReferenceSha256 = anchorReferenceSha256
            self.title = title; self.createdAt = createdAt; self.videoSeconds = videoSeconds; self.removesBackgroundNoise = removesBackgroundNoise
        }
    }

    /// A previous video's voice still to remove: kept for its pending takes, or a deletion that failed and retries.
    public struct Removal: Codable, Sendable, Equatable {
        public var recordId: String
        public var title: String
        public var attempts: Int
        /// The last failure's one-line reason; nil while it only waits for its takes.
        public var lastError: String?
        public var nextAttemptAt: String?
        public init(recordId: String, title: String, attempts: Int = 0, lastError: String? = nil, nextAttemptAt: String? = nil) {
            self.recordId = recordId; self.title = title; self.attempts = attempts; self.lastError = lastError; self.nextAttemptAt = nextAttemptAt
        }
    }

    /// "Did matching help": a take's speaker cosine against the original speech beside it, on this Mac.
    public struct Measurement: Codable, Sendable, Equatable {
        public var contentKey: String
        public var title: String
        /// The first take with the video's own voice.
        public var videoVoice: Double?
        /// The anchor's takes in this video, pooled.
        public var anchor: Double?
        public var measuredAt: String
        public init(contentKey: String, title: String, videoVoice: Double?, anchor: Double?, measuredAt: String) {
            self.contentKey = contentKey; self.title = title; self.videoVoice = videoVoice; self.anchor = anchor; self.measuredAt = measuredAt
        }
    }

    /// "Did matching help" before the first video's voice: the anchor's takes already accepted into the owner's projects,
    /// each scored against the original speech beside it, with the speaker model that scored them.
    public struct AnchorBaseline: Codable, Sendable, Equatable {
        public var anchorId: String
        /// The speaker model's id: a baseline from another model is dropped and measured again.
        public var model: String
        /// The mean over `takes`; nil when no earlier take could be read.
        public var score: Double?
        public var takes: Int
        public var measuredAt: String
        public init(anchorId: String, model: String, score: Double?, takes: Int, measuredAt: String) {
            self.anchorId = anchorId; self.model = model; self.score = score; self.takes = takes; self.measuredAt = measuredAt
        }
    }

    public var schema = Self.schema
    public var videos: [Video] = []
    public var removals: [Removal] = []
    /// Videos already told, once, that they keep the anchor (too little of their own speech).
    public var shortNoted: [String] = []
    public var measurements: [Measurement] = []
    public var anchorBaseline: AnchorBaseline?
    public init() {}

    /// The stored baseline when it is the anchor's and was scored by `model`; nil otherwise, so it is measured again.
    public func baseline(anchorId: String, model: String) -> AnchorBaseline? {
        anchorBaseline.flatMap { $0.anchorId == anchorId && $0.model == model ? $0 : nil }
    }

    public func video(_ contentKey: String) -> Video? { videos.first { $0.contentKey == contentKey } }
    public func isVideoVoice(_ recordId: String) -> Bool {
        videos.contains { $0.recordId == recordId } || removals.contains { $0.recordId == recordId }
    }

    /// Adds `video` as its `contentKey`'s voice. Every other video's voice becomes a removal (the previous video's), and
    /// one this video had before too.
    public func adding(_ video: Video) -> VoicePerVideoBook {
        var next = self
        for old in next.videos where old.recordId != video.recordId && !next.removals.contains(where: { $0.recordId == old.recordId }) {
            next.removals.append(Removal(recordId: old.recordId, title: old.title))
        }
        next.videos = [video]
        next.shortNoted.removeAll { $0 == video.contentKey }
        return next
    }

    public func measuring(_ measurement: Measurement) -> VoicePerVideoBook {
        var next = self
        var merged = measurement
        if let old = next.measurements.first(where: { $0.contentKey == measurement.contentKey }) {
            merged.videoVoice = measurement.videoVoice ?? old.videoVoice
            merged.anchor = measurement.anchor ?? old.anchor
        }
        next.measurements.removeAll { $0.contentKey == measurement.contentKey }
        next.measurements.insert(merged, at: 0)
        next.measurements = Array(next.measurements.prefix(Self.maximumMeasurements))
        return next
    }

    static let recordPattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    static func isKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= VoiceSpeakerReferences.maximumContentKey
            && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
    static func isRecord(_ id: String) -> Bool { (try? ProjectValidation.text(id, pattern: recordPattern)) != nil }
    static func isScore(_ value: Double?) -> Bool { value.map { $0.isFinite && (-1...1).contains($0) } ?? true }

    public func validate() throws {
        func require(_ condition: Bool) throws { if !condition { throw VoiceLabError.invalidInput } }
        try require(schema == Self.schema)
        try require(Set(videos.map(\.contentKey)).count == videos.count && Set(videos.map(\.recordId)).count == videos.count)
        for video in videos {
            try require(Self.isKey(video.contentKey) && Self.isRecord(video.recordId) && Self.isRecord(video.anchorId) && video.recordId != video.anchorId)
            try require(video.anchorReferenceSha256.count == 64 && video.anchorReferenceSha256.allSatisfy(\.isHexDigit))
            try require(video.title.unicodeScalars.count <= 200 && video.videoSeconds.isFinite && (0...240).contains(video.videoSeconds))
        }
        try require(Set(removals.map(\.recordId)).count == removals.count && removals.count <= 64)
        for removal in removals {
            try require(Self.isRecord(removal.recordId) && removal.attempts >= 0 && removal.title.unicodeScalars.count <= 200)
            try require(!videos.contains { $0.recordId == removal.recordId })
            try require((removal.lastError?.unicodeScalars.count ?? 0) <= 300)
        }
        try require(shortNoted.count <= 256 && shortNoted.allSatisfy(Self.isKey))
        try require(measurements.count <= Self.maximumMeasurements && Set(measurements.map(\.contentKey)).count == measurements.count)
        for measurement in measurements {
            try require(Self.isKey(measurement.contentKey) && Self.isScore(measurement.videoVoice) && Self.isScore(measurement.anchor))
            try require(measurement.title.unicodeScalars.count <= 200)
        }
        if let baseline = anchorBaseline {
            try require(Self.isRecord(baseline.anchorId) && !baseline.model.isEmpty && baseline.model.unicodeScalars.count <= 128)
            try require((0...VoicePerVideo.maximumBaselineTakes).contains(baseline.takes) && Self.isScore(baseline.score))
            try require((baseline.takes == 0) == (baseline.score == nil))
        }
    }
}
