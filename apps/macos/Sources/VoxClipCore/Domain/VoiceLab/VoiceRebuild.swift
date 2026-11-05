import Foundation

/// "Rebuild from my videos" (voice-lab §6.12, ADR-R42): the owner-verified speech across the user's projects that a
/// rebuilt clone is made from. Pure; the Media finder supplies the candidates and the enrollment sends the result.
///
/// The limits are the existing ones, not new ones: the attested project route (§6.7) sends 1–24 training WAVs of 5–30 s,
/// 30–120 s in total, each at most 16 MiB, inside the client's 1–25 files and 10–240 s. ElevenLabs recommends 1–2
/// minutes for an instant clone (§6.5 step 3), so the rebuild aims at the full 120 s.
public enum VoiceRebuild {
    public static let maximumFiles = 24
    public static let minimumTotalMs = VoiceTrainingSpans.TRAIN_TOTAL_MIN
    public static let maximumTotalMs = VoiceTrainingSpans.TRAIN_TOTAL_MAX
    public static let minimumPieceMs = VoiceTrainingSpans.TRAIN_SPAN_MIN
    public static let maximumPieceMs = VoiceTrainingSpans.TRAIN_SPAN_MAX
    public static let maximumBytes = 16 * 1_024 * 1_024
    /// Clean speech only: the §6.5.1 SNR floor.
    public static let minimumSnrDb = VoiceTrainingSpans.TRAIN_MIN_SNR
    /// The candidates the finder embeds per video: its cleanest qualifying spans.
    public static let candidatesPerVideo = 6

    /// One stretch of a project's own speech, scored against the voice's own consent embedding.
    public struct Candidate: Sendable, Equatable {
        /// The project's media `contentKey`: one video.
        public let video: String
        public let startMs: Int
        public let endMs: Int
        public let snrDb: Double
        /// The lowest of the piece's part scores and its whole score against the record's own embedding (§6.6 project
        /// span parts), so another voice inside it can't pass on the mean.
        public let score: Double
        /// The piece's whole embedding, L2-normalised; used for diversity only.
        public let embedding: [Float]
        public init(video: String, startMs: Int, endMs: Int, snrDb: Double, score: Double, embedding: [Float]) {
            self.video = video; self.startMs = startMs; self.endMs = endMs; self.snrDb = snrDb; self.score = score; self.embedding = embedding
        }
        public var durationMs: Int { endMs - startMs }
    }

    /// Why a candidate was left out.
    public enum Rejection: String, Sendable, Equatable {
        /// It doesn't pass against the voice's own consent embedding at τ (one hop, never through a reference).
        case notTheOwner
        /// Below the clean-speech floor, or no SNR.
        case noisy
        /// Not 5–30 s.
        case length
        /// Fine, but the set was already full (files or seconds).
        case full
    }

    public struct Plan: Sendable, Equatable {
        /// The pieces in the order they are sent: `kept` first when there is one, then the pick order.
        public let pieces: [Candidate]
        /// The voice's existing reference sample, sent first so the consent embedding stays the same (`keptMs` long).
        public let keptMs: Int?
        public let rejected: [Rejection: Int]
        public var totalMs: Int { pieces.reduce(keptMs ?? 0) { $0 + $1.durationMs } }
        public var videoCount: Int { Set(pieces.map(\.video)).count }
        public var fileCount: Int { pieces.count + (keptMs == nil ? 0 : 1) }
        public var enough: Bool { totalMs >= VoiceRebuild.minimumTotalMs }
    }

    /// Picks the rebuild's pieces.
    /// 1. **One hop.** Only candidates scoring ≥ `threshold` against the voice's own embedding; never via a reference.
    /// 2. **Clean.** SNR ≥ `minimumSnrDb`; 5–30 s.
    /// 3. **Each video once first.** The cleanest piece of each video (SNR, then score, then the earlier start), the
    ///    videos in order of that piece's score, so every room and microphone is represented before any repeats.
    /// 4. **Then the most different.** Each further piece is the one whose highest cosine to any piece already chosen is
    ///    lowest (ties: SNR, score, video, start), until 24 files or 120 s; a piece that would pass 120 s is skipped and
    ///    a later, shorter one may still fit.
    /// `keptMs` (the existing reference sample, already verified as the statement itself) counts toward both limits.
    public static func pick(_ candidates: [Candidate], threshold: Double, keptMs: Int? = nil) -> Plan {
        var rejected: [Rejection: Int] = [:]
        var pool: [Candidate] = []
        for candidate in candidates {
            let rejection: Rejection?
            if !(candidate.score.isFinite && candidate.score >= threshold) { rejection = .notTheOwner }
            else if !(candidate.snrDb.isFinite && candidate.snrDb >= minimumSnrDb) { rejection = .noisy }
            else if !(minimumPieceMs...maximumPieceMs).contains(candidate.durationMs) { rejection = .length }
            else { rejection = nil }
            if let rejection { rejected[rejection, default: 0] += 1 } else { pool.append(candidate) }
        }
        func cleaner(_ a: Candidate, _ b: Candidate) -> Bool {
            a.snrDb != b.snrDb ? a.snrDb > b.snrDb : a.score != b.score ? a.score > b.score : a.video != b.video ? a.video < b.video : a.startMs < b.startMs
        }
        var chosen: [Candidate] = []
        var total = keptMs ?? 0
        var files = keptMs == nil ? 0 : 1
        func fits(_ candidate: Candidate) -> Bool { files < maximumFiles && total + candidate.durationMs <= maximumTotalMs }
        func take(_ candidate: Candidate) { chosen.append(candidate); total += candidate.durationMs; files += 1 }
        // Round 1: the cleanest piece of every video.
        let firsts = Dictionary(grouping: pool, by: \.video).compactMap { $0.value.sorted(by: cleaner).first }
            .sorted { $0.score != $1.score ? $0.score > $1.score : cleaner($0, $1) }
        for candidate in firsts where fits(candidate) { take(candidate) }
        // Round 2: the most different remaining piece, again and again.
        var remaining = pool.filter { candidate in !chosen.contains(candidate) }
        while !remaining.isEmpty {
            var best: (index: Int, closeness: Double)?
            for (index, candidate) in remaining.enumerated() where fits(candidate) {
                let closeness = chosen.map { (try? SpeakerAudio.cosine($0.embedding, candidate.embedding)) ?? 1 }.max() ?? -1
                if let current = best {
                    let other = remaining[current.index]
                    if closeness < current.closeness || closeness == current.closeness && cleaner(candidate, other) { best = (index, closeness) }
                } else { best = (index, closeness) }
            }
            guard let best else { break }
            take(remaining.remove(at: best.index))
        }
        rejected[.full, default: 0] += remaining.count
        if rejected[.full] == 0 { rejected[.full] = nil }
        return Plan(pieces: chosen, keptMs: keptMs, rejected: rejected)
    }

    /// "2 min from 9 videos": whole seconds, as minutes and seconds.
    public static func amount(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1_000
        let minutes = seconds / 60, rest = seconds % 60
        if minutes == 0 { return "\(rest) s" }
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

    /// The line shown before any click: how much speech, from how many videos.
    public static func summary(_ plan: Plan) -> String {
        let videos = plan.videoCount == 1 ? "1 video" : "\(plan.videoCount) videos"
        let kept = plan.keptMs == nil ? "" : " and your consent clip"
        return "\(amount(plan.totalMs)) from \(videos)\(kept)"
    }
}
