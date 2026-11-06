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
