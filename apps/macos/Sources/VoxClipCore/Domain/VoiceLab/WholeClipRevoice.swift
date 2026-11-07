import Foundation

/// Revoice the whole clip (ADR-R46, voice-lab §8.14): one AI voice for every word of a clip, fitted to the clip's length,
/// then lip synced, so a heavily rewritten clip has no seams between the real voice and patched phrases. This file holds
/// the free, deterministic parts both apps share: when to switch from patching, the script, its parts, the fit, the price
/// and the project's record of a used revoice.
public enum WholeClipRevoice {
    /// (a) Revoice when the changed phrases re-voice at least this share of the clip's spoken words.
    public static let wordSharePercent = 40
    /// (b) Revoice when at least this many phrases can't fit their slot (they would keep the original audio).
    public static let noFitPhrases = 2
    /// The Fit step matches the picture with one uniform retime while the voice is within this share of the video.
    public static let fitTolerance = 0.08
    /// Measured-wording rounds the Fit step may ask for before it says the voice can't fit.
    public static let maximumRewordRounds = 2
    /// A part of the script is whole sentences spanning at most this much source time (a single longer sentence stays one
    /// part). The mockup's 31 s clip comes to three parts.
    public static let maximumPartSeconds = 12.0
    /// A script part never exceeds the text-to-speech route's limit.
    public static let maximumPartCharacters = 1_000
    /// Lip sync takes at most 300 s in one job (voice-lab §9.3).
    public static let maximumClipSeconds = 300.0
    /// The burned-in chip and the post text line of an export holding a whole-clip revoice (voice-lab §11).
    public static let disclosureChip = "Voice and lip movement generated with AI"
    public static let disclosureLine = "Voice and lip movement generated with AI."
    /// The disclosure kind a revoiced segment adds to an export's label plan.
    public static let disclosureKind = "revoice"
}

// MARK: - The switch rule

extension WholeClipRevoice {
    /// What the rule reads from a Rewrite of one clip.
    public struct RuleInputs: Equatable, Sendable {
        /// The clip's spoken words (transcript `word` items in its span, after its cuts).
        public var spokenWords: Int
        /// The words the patch re-voices: every new word of the included voice changes (the voice budget's count).
        public var revoicedWords: Int
        /// Phrases no video duration can carry (`ClipTakePlan.fitsNoDuration`), or, before takes, phrases the free fit
        /// keeps as recorded because their wording is too long for the video.
        public var noFitPhrases: Int
        public init(spokenWords: Int, revoicedWords: Int, noFitPhrases: Int) {
            self.spokenWords = spokenWords; self.revoicedWords = revoicedWords; self.noFitPhrases = noFitPhrases
        }
    }

    /// Why patching would sound stitched.
    public enum Reason: Equatable, Sendable {
        case manyWords(revoiced: Int, spoken: Int)
        case phrasesCantFit(Int)
    }

    /// The rule (ADR-R46): (a) the changes re-voice at least 40% of the clip's spoken words, or (b) at least two phrases
    /// can't fit their slot. Integer arithmetic, so the edges are exact. Nil keeps patching.
    public static func reason(_ inputs: RuleInputs) -> Reason? {
        if inputs.spokenWords > 0, inputs.revoicedWords > 0, inputs.revoicedWords * 100 >= inputs.spokenWords * wordSharePercent {
            return .manyWords(revoiced: inputs.revoicedWords, spoken: inputs.spokenWords)
        }
        if inputs.noFitPhrases >= noFitPhrases { return .phrasesCantFit(inputs.noFitPhrases) }
        return nil
    }

    /// ✦ Claude does it all's choice for a clip whose patch would sound stitched.
    public enum AutoChoice: Equatable, Sendable {
        /// Patch as before: the rule doesn't apply, or no price is known (nothing unpriced is ever spent or offered).
        case patch
        /// Revoice the whole clip: its price fits what is left of the run's cap.
        case revoice(price: Decimal)
        /// Patch, and offer "Revoice the Whole Clip · ≈ $X" inline; nothing is spent until it is clicked.
        case patchAndOffer(price: Decimal)
    }

    /// `remaining` is what the run may still spend (nil: no paid step may run).
    public static func autoChoice(_ reason: Reason?, price: Decimal?, remaining: Decimal?) -> AutoChoice {
        guard reason != nil, let price, price > 0 else { return .patch }
        guard let remaining, price <= remaining else { return .patchAndOffer(price: price) }
        return .revoice(price: price)
    }

    /// The callout over a large change, as the mockup's: "These changes re-voice 58 words, a lot for a 74-word clip. Long
    /// stretches in your voice can sound stitched."
    public static func callout(_ reason: Reason) -> String {
        switch reason {
        case .manyWords(let revoiced, let spoken):
            return "These changes re-voice \(revoiced) words, a lot for a \(spoken)-word clip. Long stretches in your voice can sound stitched."
        case .phrasesCantFit(let count):
            return "\(count) phrases can't fit their places in the video, so they would keep your original audio. Revoicing the whole clip fits the picture to the voice."
        }
    }
}

// MARK: - Script and parts

/// The clip's words with every edit and rewrite applied, in transcript order (the Script step; free).
public struct WholeClipScript: Equatable, Sendable {
    /// One sentence of the script, with the source words it is said over.
    public struct Sentence: Equatable, Sendable {
        public let tokens: [String]
        /// The clip's spoken source words this sentence replaces, in transcript order.
        public let sourceWordIds: [String]
        public let start: Double
        public let end: Double
        public var text: String { tokens.joined(separator: " ") }
    }
    public let sentences: [Sentence]
    public var text: String { sentences.map(\.text).joined(separator: " ") }
    public var words: Int { sentences.reduce(0) { $0 + $1.tokens.count } }
    public var characters: Int { text.unicodeScalars.count }

    /// `words` are the clip's transcript items in order (their text already corrected); `cutWordIds` the project's cuts;
    /// `voiceHunks` the Rewrite's included voice changes. A change replaces its source words where its first one stood; a
    /// change with no source words (an insertion, which the prompts forbid, ADR-R42) is left out. Nil when nothing is said.
    public static func assemble(words: [TimedWord], cutWordIds: Set<String>, voiceHunks: [VoiceLabDiffHunk]) -> WholeClipScript? {
        let spoken = words.filter { $0.kind == .word }
        let byID = Dictionary(spoken.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var owner: [String: Int] = [:]
        for (index, hunk) in voiceHunks.enumerated() where hunk.kind == .voice {
            for id in hunk.sourceWordIds where byID[id] != nil && owner[id] == nil { owner[id] = index }
        }
        struct Unit { let tokens: [String]; let sources: [String] }
        var units: [Unit] = []
        var emitted = Set<Int>()
        for word in spoken {
            if let index = owner[word.id] {
                guard emitted.insert(index).inserted else { continue }
                let sources = voiceHunks[index].sourceWordIds.filter { byID[$0] != nil }
                units.append(Unit(tokens: voiceHunks[index].newTokens.filter { !$0.isEmpty }, sources: sources))
            } else if !cutWordIds.contains(word.id) {
                units.append(Unit(tokens: EditingPrimitives.splitWords(word.text), sources: [word.id]))
            }
        }
        var sentences: [Sentence] = []
        var tokens: [String] = [], sources: [String] = []
        func close() {
            guard !tokens.isEmpty else { tokens = []; sources = []; return }
            let times = sources.compactMap { byID[$0] }
            guard let start = times.map(\.start).min(), let end = times.map(\.end).max() else {
                // A sentence made only of new words with no source left (every source word re-owned): join the previous.
                if let last = sentences.popLast() {
                    sentences.append(Sentence(tokens: last.tokens + tokens, sourceWordIds: last.sourceWordIds, start: last.start, end: last.end))
                }
                tokens = []; sources = []; return
            }
            sentences.append(Sentence(tokens: tokens, sourceWordIds: sources, start: start, end: end))
            tokens = []; sources = []
        }
        for unit in units {
            sources += unit.sources.filter { !sources.contains($0) }
            for token in unit.tokens {
                tokens.append(token)
                if let last = token.last, ".!?…".contains(last) { close() }
            }
        }
        close()
        guard !sentences.isEmpty else { return nil }
        return WholeClipScript(sentences: sentences)
    }

    /// One part of the voice: whole sentences said in one request, over the source words they replace.
    public struct Part: Equatable, Sendable {
        public let text: String
        public let words: Int
        public let sourceWordIds: [String]
        public let start: Double
        public let end: Double
    }

    /// The script split at sentence boundaries into parts of at most `maximumPartSeconds` of source time and
    /// `maximumPartCharacters`; one voice says every part (the mockup's "3 parts, one take").
    public var parts: [Part] {
        var parts: [Part] = []
        var group: [Sentence] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let tokens = group.flatMap(\.tokens)
            parts.append(Part(text: tokens.joined(separator: " "), words: tokens.count, sourceWordIds: group.flatMap(\.sourceWordIds),
                              start: first.start, end: last.end))
            group = []
        }
        for sentence in sentences {
            if let first = group.first {
                let seconds = sentence.end - first.start
                let characters = (group.map(\.text) + [sentence.text]).joined(separator: " ").unicodeScalars.count
                if seconds > WholeClipRevoice.maximumPartSeconds || characters > WholeClipRevoice.maximumPartCharacters { flush() }
            }
            group.append(sentence)
        }
        flush()
        return parts
    }

    /// The parts as Rewrite voice changes, so each goes through the existing take path (window placement, the R40 guard,
    /// R43 calibration, the take checks and the lip-sync window). `words` are the clip's transcript items.
    public func hunks(words: [TimedWord]) -> [VoiceLabDiffHunk] {
        let spoken = words.filter { $0.kind == .word }
        let index = Dictionary(spoken.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let items = Dictionary(words.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return parts.compactMap { part in
            let positions = part.sourceWordIds.compactMap { index[$0] }
            guard let lower = positions.min(), let upper = positions.max() else { return nil }
            var absorbed: [String] = []
            let itemPositions = part.sourceWordIds.compactMap { items[$0] }
            if let first = itemPositions.min(), let last = itemPositions.max(), last > first {
                absorbed = words[(first + 1)..<last].filter { $0.kind != .word }.map(\.id)
            }
            return VoiceLabDiffHunk(kind: .voice, sourceWordIds: part.sourceWordIds, newTokens: EditingPrimitives.splitWords(part.text),
                                    correctedTexts: [], absorbedItemIds: absorbed, bridgeWordIds: [],
                                    sourceStartIndex: lower, sourceEndIndex: upper + 1, anchorSeconds: nil)
        }
    }
}

// MARK: - Fit

extension WholeClipRevoice {
    /// The Fit step's verdict on the voice against the clip's rendered video (which already includes any clip speed).
    public enum Fit: Equatable, Sendable {
        /// Within ±8%: the picture is retimed uniformly by `factor` (voice ÷ video).
        case matched(factor: Double)
        /// Outside it: ask for a wording of about `targetWords` through the measured-wording round.
        case reword(shorter: Bool, targetWords: Int)
        /// No round is left: say so inline and offer a forward action.
        case cannotFit(voiceSeconds: Double, videoSeconds: Double)
    }

    /// `round` counts the reword rounds already asked for.
    public static func fit(voiceSeconds: Double, videoSeconds: Double, words: Int, round: Int) -> Fit {
        guard voiceSeconds.isFinite, videoSeconds.isFinite, voiceSeconds > 0, videoSeconds > 0 else {
            return .cannotFit(voiceSeconds: voiceSeconds, videoSeconds: videoSeconds)
        }
        let factor = voiceSeconds / videoSeconds
        if abs(factor - 1) <= fitTolerance + 1e-9 { return .matched(factor: factor) }
        guard round < maximumRewordRounds, words > 0 else { return .cannotFit(voiceSeconds: voiceSeconds, videoSeconds: videoSeconds) }
        let target = max(1, Int((Double(words) / factor).rounded()))
        return .reword(shorter: factor > 1, targetWords: target)
    }

    /// "video matched (−1.3%)": the voice's length against the video's, signed.
    public static func matchedCopy(factor: Double) -> String {
        let percent = (factor - 1) * 100
        let rounded = (percent * 10).rounded() / 10
        let magnitude = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), abs(rounded))
        let sign = rounded < 0 ? "−" : rounded > 0 ? "+" : "±"
        return "video matched (\(sign)\(magnitude)%)"
    }
}

// MARK: - Lip-sync model and price

extension WholeClipRevoice {
    /// The lip-sync models a whole clip may use (the user's decision, 2026-11-07): lipsync-2 by default, sync-3 as the
    /// priced upgrade on Review that re-runs only the lip sync.
    public enum Lipsync: String, Codable, Sendable, CaseIterable {
        case lipsync2 = "fal-ai/sync-lipsync/v2:lipsync-2"
        case sync3 = "fal-ai/sync-lipsync/v3"
        public static let standard = Lipsync.lipsync2
        public var endpoint: String { String(rawValue.split(separator: ":", maxSplits: 1)[0]) }
        public var model: String? { rawValue.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) }
        /// "lipsync-2", "sync-3".
        public var name: String { self == .lipsync2 ? "lipsync-2" : "sync-3" }
        public var lipsyncModel: LipsyncModel { LipsyncModel(provider: "fal", id: rawValue, tier: self == .sync3 ? .best : .quality, supportsRemap: true) }
    }

    /// The whole clip's price before anything is sent: the voice for every script character, and the lip sync for the
    /// clip's video seconds. Both come from the pricing tables; nil `usd` when either row is missing.
    public struct Price: Equatable, Sendable {
        public let voice: CostEstimate
        public let lipsync: CostEstimate
        public var usd: Decimal? {
            guard let voice = voice.usd, let lipsync = lipsync.usd else { return nil }
            return voice + lipsync
        }
    }

    public static func price(characters: Int, ttsModel: String, videoSeconds: Double, lipsync: Lipsync,
                             catalog: VoiceLabPriceCatalog) throws -> Price {
        let voice = try VoiceLabPricing.estimate(operation: .elevenLabsTextToSpeech, model: ttsModel, units: Double(characters), catalog: catalog)
        let sync = try lipsyncPrice(videoSeconds: videoSeconds, lipsync: lipsync, catalog: catalog)
        return Price(voice: voice, lipsync: sync)
    }

    public static func lipsyncPrice(videoSeconds: Double, lipsync: Lipsync, catalog: VoiceLabPriceCatalog) throws -> CostEstimate {
        try VoiceLabPricing.estimate(operation: .falLipsync(endpoint: lipsync.endpoint), model: lipsync.model, units: videoSeconds, catalog: catalog)
    }
}

// MARK: - The project's record

/// A used whole-clip revoice, saved in the project (`voiceLab.wholeClipRevoices`, schema v3 and v4). Its segments are
/// ordinary Voice Lab segments, one per part, whose recipes carry the matched video and the lip sync; this record ties
/// them together for the disclosure, the stage's tag, the review's match line and Undo.
public struct WholeClipRevoiceRecord: Codable, Sendable, Equatable {
    public struct Match: Codable, Sendable, Equatable {
        /// The whole-clip voice's take-match score against the speech beside it.
        public var take: Double
        /// The anchor's earlier takes (voice-lab §6.13 item 9), when measured.
        public var anchorBaseline: Double?
        /// The real speech against the consent recording, when measured.
        public var realSpeech: Double?
        public init(take: Double, anchorBaseline: Double?, realSpeech: Double?) {
            self.take = take; self.anchorBaseline = anchorBaseline; self.realSpeech = realSpeech
        }
        private enum CodingKeys: String, CodingKey { case take, anchorBaseline, realSpeech }
        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(take, forKey: .take)
            try values.encode(anchorBaseline, forKey: .anchorBaseline)
            try values.encode(realSpeech, forKey: .realSpeech)
        }
    }
    public var id: String
    public var clipId: String
    public var segmentIds: [String]
    public var script: String
    public var consentRecordId: String
    /// The voice's length ÷ the clip's video length; the picture's uniform retime, within ±`fitTolerance`.
    public var videoRetime: Double
    /// `WholeClipRevoice.Lipsync` raw value.
    public var lipsyncModel: String
    public var usd: Double?
    public var match: Match?
    public var createdAt: Date

    public init(id: String, clipId: String, segmentIds: [String], script: String, consentRecordId: String, videoRetime: Double,
                lipsyncModel: String, usd: Double?, match: Match?, createdAt: Date) {
        self.id = id; self.clipId = clipId; self.segmentIds = segmentIds; self.script = script
        self.consentRecordId = consentRecordId; self.videoRetime = videoRetime; self.lipsyncModel = lipsyncModel
        self.usd = usd; self.match = match; self.createdAt = createdAt
    }
    private enum CodingKeys: String, CodingKey { case id, clipId, segmentIds, script, consentRecordId, videoRetime, lipsyncModel, usd, match, createdAt }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(clipId, forKey: .clipId)
        try values.encode(segmentIds, forKey: .segmentIds); try values.encode(script, forKey: .script)
        try values.encode(consentRecordId, forKey: .consentRecordId); try values.encode(videoRetime, forKey: .videoRetime)
        try values.encode(lipsyncModel, forKey: .lipsyncModel); try values.encode(usd, forKey: .usd)
        try values.encode(match, forKey: .match); try values.encode(createdAt, forKey: .createdAt)
    }
}

extension WholeClipRevoice {
    /// The record's rules, checked with the rest of the Voice Lab data (`VoiceLabProject.validate`): schema 3 or later;
    /// an `id` and `clipId` of the project's ID shape, the clip existing; at least one segment, each an existing,
    /// distinct text-to-speech segment in no other record; a lip-sync model this feature uses; the retime within the fit
    /// tolerance; scores within −1…1 and a finite, non-negative price.
    public static func validate(_ project: Project) throws {
        guard let records = project.voiceLab.wholeClipRevoices else { return }
        guard project.schemaVersion >= 3, !records.isEmpty else { throw VoiceLabProjectError.invalidSegment }
        let segments = Dictionary(project.voiceLab.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids = Set<String>(), used = Set<String>()
        for record in records {
            guard idShape(record.id), ids.insert(record.id).inserted, idShape(record.clipId),
                  project.edits.clips.contains(where: { $0.id == record.clipId }),
                  !record.segmentIds.isEmpty, !record.script.isEmpty, record.script.unicodeScalars.count <= 20_000,
                  !record.consentRecordId.isEmpty,
                  Lipsync(rawValue: record.lipsyncModel) != nil,
                  record.videoRetime.isFinite, abs(record.videoRetime - 1) <= fitTolerance + 1e-9,
                  record.usd.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  record.createdAt.timeIntervalSince1970.isFinite else { throw VoiceLabProjectError.invalidSegment }
            if let match = record.match {
                let scores = [match.take] + [match.anchorBaseline, match.realSpeech].compactMap { $0 }
                guard scores.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else { throw VoiceLabProjectError.invalidSegment }
            }
            for id in record.segmentIds {
                guard used.insert(id).inserted, let segment = segments[id], segment.kind == .tts else { throw VoiceLabProjectError.missingSegment }
            }
        }
    }

    /// Whether `clipId` plays a whole-clip revoice: a record for it with an enabled segment. The stage then shows its AI
    /// voice tag over the whole clip, the pauses between parts included.
    public static func isRevoiced(clipId: String, in project: Project) -> Bool {
        guard let records = project.voiceLab.wholeClipRevoices else { return false }
        let enabled = Set(project.voiceLab.segments.filter(\.enabled).map(\.id))
        return records.contains { $0.clipId == clipId && $0.segmentIds.contains(where: enabled.contains) }
    }

    /// The record holding `segmentId`, if a whole-clip revoice made it.
    public static func record(holding segmentId: String, in project: Project) -> WholeClipRevoiceRecord? {
        project.voiceLab.wholeClipRevoices?.first { $0.segmentIds.contains(segmentId) }
    }

    private static func idShape(_ value: String) -> Bool {
        value.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\\z", options: .regularExpression) != nil
    }
}

// MARK: - Paid steps (never paid twice)

/// What a whole-clip run has paid for, keyed by what it was paid for. A step whose key matches is reused instead of paid
/// again: Try Again after a failed or cancelled lip sync keeps the voice, and the sync-3 upgrade re-runs only the lip sync.
public struct WholeClipRevoiceLedger: Codable, Sendable, Equatable {
    /// The voice: the script, the voice record and the text-to-speech model it was said in.
    public struct VoiceKey: Codable, Sendable, Hashable {
        public let script: String
        public let recordId: String
        public let model: String
        public init(script: String, recordId: String, model: String) { self.script = script; self.recordId = recordId; self.model = model }
    }
    /// A lip sync: the voice it was made over, the picture's retime and the model.
    public struct LipsyncKey: Codable, Sendable, Hashable {
        public let voice: VoiceKey
        public let retime: Double
        public let model: Lipsync
        public init(voice: VoiceKey, retime: Double, model: Lipsync) { self.voice = voice; self.retime = retime; self.model = model }
    }
    public typealias Lipsync = WholeClipRevoice.Lipsync
    public private(set) var voices: [VoiceKey: Decimal] = [:]
    public private(set) var lipsyncs: [LipsyncKey: Decimal] = [:]
    public init() {}

    public func paid(_ key: VoiceKey) -> Bool { voices[key] != nil }
    public func paid(_ key: LipsyncKey) -> Bool { lipsyncs[key] != nil }
    public mutating func record(_ key: VoiceKey, usd: Decimal) { voices[key] = usd }
    public mutating func record(_ key: LipsyncKey, usd: Decimal) { lipsyncs[key] = usd }
    /// Everything paid so far.
    public var total: Decimal { voices.values.reduce(0, +) + lipsyncs.values.reduce(0, +) }
    /// What is still to pay for these steps: a step already paid costs nothing again.
    public func remaining(voice: VoiceKey, voiceUSD: Decimal, lipsync: LipsyncKey?, lipsyncUSD: Decimal) -> Decimal {
        let voiceDue: Decimal = paid(voice) ? 0 : voiceUSD
        let lipsyncPaid: Bool = lipsync.map { paid($0) } ?? false
        return voiceDue + (lipsyncPaid ? 0 : lipsyncUSD)
    }
}
