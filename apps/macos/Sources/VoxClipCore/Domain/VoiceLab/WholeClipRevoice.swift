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
    /// The Fit step lays the voice out on the clip as edited while it is within this share of its length.
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
    /// R43 calibration, the take checks and the lip-sync window). `words` are the clip's transcript items; `cutWordIds` and
    /// `cutPauseIds` the project's cuts.
    ///
    /// Every spoken word of the clip is replaced, so the parts tile the clip (voice-lab §8.14 item 3): the first starts at
    /// the clip's first item, the last ends at its last, and each runs from just after the one before it. Between two parts,
    /// from the last kept word of one to the first kept word of the next, the items (cut words, a rewrite's cut source words,
    /// events) go to the side of the widest gap, the earliest on a tie, so both windows seam in that gap, on kept audio, and
    /// never in the reach of a cut. A cut pause counts as no gap: it keeps its breath only beside kept words, and both of its
    /// neighbours are replaced. When the widest gap is narrower than `SEAM_MIN_GAP`, no seam can sit there, so the two parts
    /// become one change (placement joins touching windows anyway). Two parts whose kept words touch keep their split. A
    /// hunk's `sourceWordIds` are its parts' source words in its span, with the items it takes at its edges;
    /// `absorbedItemIds` are the non-word items in its span; its spoken indices tile the clip's spoken words.
    public func hunks(words: [TimedWord], cutWordIds: Set<String>, cutPauseIds: Set<String>) -> [VoiceLabDiffHunk] {
        let items = Dictionary(words.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        /// `first`/`last` bound a part's source items, `keptFirst`/`keptLast` its kept ones (its source items when it has
        /// none), and `lower`/`upper` its span.
        struct Tile { var sources: [String]; var tokens: [String]; var first, last, keptFirst, keptLast, lower, upper: Int }
        var tiles: [Tile] = []
        for part in parts {
            let positions = part.sourceWordIds.compactMap { items[$0] }
            guard let first = positions.min(), let last = positions.max() else { continue }
            let kept = positions.filter { words[$0].kind == .word && !cutWordIds.contains(words[$0].id) }
            tiles.append(Tile(sources: part.sourceWordIds, tokens: EditingPrimitives.splitWords(part.text), first: first, last: last,
                              keptFirst: kept.min() ?? first, keptLast: kept.max() ?? last, lower: first, upper: last))
        }
        guard !tiles.isEmpty else { return [] }
        // Where the silence after item `j` begins: the latest end of the items up to it.
        var reached: [Double] = []
        for word in words { reached.append(max(reached.last ?? word.end, word.end)) }
        var joined: [Tile] = [tiles[0]]
        for next in tiles.dropFirst() {
            var current = joined.removeLast()
            let left = current.keptLast, right = next.keptFirst
            if current.last < next.first, right > left {
                var split = left, widest = Double.infinity
                if right > left + 1 {
                    // Split at the widest gap, the earliest on a tie.
                    widest = -Double.infinity
                    for j in left..<right {
                        let gap: Double = cutPauseIds.contains("pause-after-" + words[j].id) ? 0 : words[j + 1].start - reached[j]
                        if gap > widest { widest = gap; split = j }
                    }
                }
                if widest >= VoiceLabPatchConstants.SEAM_MIN_GAP {
                    current.upper = split
                    var following = next
                    following.lower = split + 1
                    joined.append(current); joined.append(following)
                    continue
                }
            }
            // No seam fits between them, or their sources interleave: one change.
            current.sources += next.sources.filter { !current.sources.contains($0) }
            current.tokens += next.tokens
            current.first = min(current.first, next.first); current.last = max(current.last, next.last)
            current.keptFirst = min(current.keptFirst, next.keptFirst); current.keptLast = max(current.keptLast, next.keptLast)
            current.upper = max(current.upper, next.upper)
            joined.append(current)
        }
        joined[0].lower = 0
        joined[joined.count - 1].upper = words.count - 1
        var spokenBefore: [Int] = [0]
        for word in words { spokenBefore.append((spokenBefore.last ?? 0) + (word.kind == .word ? 1 : 0)) }
        return joined.map { tile in
            let span = tile.lower...tile.upper
            let sources = tile.sources.filter { items[$0].map(span.contains) ?? false }
            let positions = sources.compactMap { items[$0] }
            let first = positions.min() ?? tile.lower, last = positions.max() ?? tile.upper
            let leading = words[tile.lower..<first].map(\.id), trailing = words[(last + 1)..<(tile.upper + 1)].map(\.id)
            return VoiceLabDiffHunk(kind: .voice, sourceWordIds: leading + sources + trailing, newTokens: tile.tokens,
                                    correctedTexts: [], absorbedItemIds: words[span].filter { $0.kind != .word }.map(\.id), bridgeWordIds: [],
                                    sourceStartIndex: spokenBefore[tile.lower], sourceEndIndex: spokenBefore[tile.upper + 1], anchorSeconds: nil)
        }
    }
}

// MARK: - Fit (on the clip as edited)

extension WholeClipRevoice {
    /// The Fit step's verdict on the voice against the clip **as edited**: its cuts and tightened pauses applied, the length
    /// the user sees and the video the lip sync gets (ADR-R46, "One timeline"). Clip speed scales both alike.
    public enum Fit: Equatable, Sendable {
        /// Within ±8%: the voice is laid out on the clip as edited (`factor` = voice ÷ video).
        case matched(factor: Double)
        /// Shorter than that: the voice is still laid out on the clip as edited. Its sentence-end pauses grow within the
        /// pause bound (`layoutPauseProfile`), it ends on the clip's own last pause, and the picture after that is trimmed.
        /// A shorter voice never asks for a longer wording, which would pad the script with words nobody said.
        case laidOut(factor: Double)
        /// Longer than the clip as edited can hold: ask for a **shorter** wording of about `targetWords`.
        case reword(targetWords: Int)
        /// No round is left: say so inline and offer a forward action.
        case cannotFit(voiceSeconds: Double, videoSeconds: Double)
    }

    /// `voiceSeconds` is the voice as said, `videoSeconds` the clip as edited, `round` the reword rounds already asked for.
    public static func fit(voiceSeconds: Double, videoSeconds: Double, words: Int, round: Int) -> Fit {
        guard voiceSeconds.isFinite, videoSeconds.isFinite, voiceSeconds > 0, videoSeconds > 0 else {
            return .cannotFit(voiceSeconds: voiceSeconds, videoSeconds: videoSeconds)
        }
        let factor = voiceSeconds / videoSeconds
        if abs(factor - 1) <= fitTolerance + 1e-9 { return .matched(factor: factor) }
        if factor < 1 { return .laidOut(factor: factor) }
        guard round < maximumRewordRounds, words > 0 else { return .cannotFit(voiceSeconds: voiceSeconds, videoSeconds: videoSeconds) }
        return .reword(targetWords: max(1, Int((Double(words) / factor).rounded())))
    }

    /// Check before paying (ADR-R46): a reworded script is voiced only when the speaking-rate estimate says it now fits.
    /// The estimate is scaled by the measured voice (`voiceSeconds` for a wording estimated at `estimateSeconds`), so the
    /// rate's own error cancels; the new wording must come in at or under the clip as edited plus `fitTolerance`.
    public static func rewordFits(voiceSeconds: Double, estimateSeconds: Double, newEstimateSeconds: Double, videoSeconds: Double) -> Bool {
        guard let predicted = predictedSeconds(voiceSeconds: voiceSeconds, estimateSeconds: estimateSeconds, newEstimateSeconds: newEstimateSeconds),
              videoSeconds.isFinite, videoSeconds > 0 else { return false }
        return predicted <= videoSeconds * (1 + fitTolerance) + 1e-9
    }

    /// The new wording's predicted voice: the measured voice scaled by the estimates' ratio. Nil without a usable estimate.
    public static func predictedSeconds(voiceSeconds: Double, estimateSeconds: Double, newEstimateSeconds: Double) -> Double? {
        guard voiceSeconds.isFinite, voiceSeconds > 0, estimateSeconds.isFinite, estimateSeconds > 0,
              newEstimateSeconds.isFinite, newEstimateSeconds > 0 else { return nil }
        return voiceSeconds * newEstimateSeconds / estimateSeconds
    }

    /// "video matched (−1.3%)": the voice's length against the video's, signed.
    public static func matchedCopy(factor: Double) -> String { "video matched (" + signedPercent(factor) + ")" }

    /// "laid out on the clip's pauses (−14.0%)": a shorter voice, laid out on the clip as edited.
    public static func laidOutCopy(factor: Double) -> String { "laid out on the clip's pauses (" + signedPercent(factor) + ")" }

    private static func signedPercent(_ factor: Double) -> String {
        let percent = (factor - 1) * 100
        let rounded = (percent * 10).rounded() / 10
        let magnitude = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), abs(rounded))
        let sign = rounded < 0 ? "−" : rounded > 0 ? "+" : "±"
        return sign + magnitude + "%"
    }
}

// MARK: - Layout (the voice on the clip as edited)

extension WholeClipRevoice {
    /// The pause bound (ADR-R46, "Keep the recording's rhythm"). A sentence-end pause of the laid-out voice grows to at most
    /// `pauseThresholdSeconds`, the project's own pause threshold: a longer pause is one the clip's Tighten would cut. It
    /// shrinks to no less than the punctuated floor (150 ms). Pauses inside a sentence keep their length (the phrase floor,
    /// 60 ms, as their only bound). The silence after the voice's last word, the clip's own last pause, holds at most the
    /// same bound; the picture after it is trimmed.
    public static func layoutPauseProfile(pauseThresholdSeconds: Double) -> VoiceLabPauseProfile {
        let bound = layoutPauseBound(pauseThresholdSeconds)
        return VoiceLabPauseProfile(withinSentence: [VoiceLabPatchConstants.PAUSE_FLOOR_PHRASE],
                                    betweenSentences: [VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT, bound, bound, bound])
    }

    /// The bound itself: the threshold, never under the punctuated floor (a project's threshold is at least 0.3 s).
    public static func layoutPauseBound(_ pauseThresholdSeconds: Double) -> Double {
        guard pauseThresholdSeconds.isFinite else { return VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT }
        return max(VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT, pauseThresholdSeconds)
    }

    /// The clip's own cuts inside a source window: the stretches its edit removes (cut words, a filler's reach, the trimmed
    /// part of each tightened pause), read off the clip's output plan with no voice in it. Every stretch of the window the
    /// plan doesn't play is one cut.
    public static func editedCuts(_ plan: VoiceLabOutputPlan, startSample: Int64, endSample: Int64) -> [VoiceLabVideoCut] {
        guard endSample > startSample else { return [] }
        var cuts: [VoiceLabVideoCut] = []
        var cursor = startSample
        for piece in plan.pieces.sorted(by: { $0.sourceStartSample < $1.sourceStartSample })
        where piece.sourceEndSample > startSample && piece.sourceStartSample < endSample {
            let lower = max(piece.sourceStartSample, startSample)
            if lower > cursor { cuts.append(VoiceLabVideoCut(startSample: cursor, endSample: lower)) }
            cursor = max(cursor, min(piece.sourceEndSample, endSample))
        }
        if cursor < endSample { cuts.append(VoiceLabVideoCut(startSample: cursor, endSample: endSample)) }
        return cuts
    }

    /// The clip as edited inside a source window, in seconds at `sampleRate`: the window without its edited cuts.
    public static func editedSeconds(_ cuts: [VoiceLabVideoCut], startSample: Int64, endSample: Int64, sampleRate: Double) -> Double {
        let removed = cuts.reduce(Int64(0)) { $0 + max(0, $1.endSample - $1.startSample) }
        return Double(max(0, endSample - startSample - removed)) / sampleRate
    }

    /// The picture under a laid-out voice: the clip's own `cuts` changed so they remove exactly `removedSamples` of the
    /// window. Removing more trims the picture's end: the voice ended on the clip's last pause, so the frames after it go,
    /// latest first. Removing less gives cut picture back, from the latest cut, each from its start (the frames right after
    /// the speech before it). Nil when the window can't do that: nothing would be left, or more than the window is asked for.
    public static func layoutCuts(_ cuts: [VoiceLabVideoCut], startSample: Int64, endSample: Int64, removedSamples: Int64) -> [VoiceLabVideoCut]? {
        let span = endSample - startSample
        guard span > 0, removedSamples >= 0, removedSamples < span,
              cuts.allSatisfy({ $0.startSample >= startSample && $0.endSample <= endSample && $0.endSample > $0.startSample }) else { return nil }
        let ordered = cuts.sorted { $0.startSample < $1.startSample }
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.endSample <= $1.startSample }) else { return nil }
        let removed = ordered.reduce(Int64(0)) { $0 + $1.endSample - $1.startSample }
        if removedSamples <= removed {
            var giveBack = removed - removedSamples
            var result = ordered
            for index in result.indices.reversed() where giveBack > 0 {
                let take = min(giveBack, result[index].endSample - result[index].startSample)
                result[index] = VoiceLabVideoCut(startSample: result[index].startSample + take, endSample: result[index].endSample)
                giveBack -= take
            }
            return result.filter { $0.endSample > $0.startSample }
        }
        // Trim: the kept stretches, latest first, lose their ends until the extra is removed.
        var kept: [(Int64, Int64)] = []
        var cursor = startSample
        for cut in ordered {
            if cut.startSample > cursor { kept.append((cursor, cut.startSample)) }
            cursor = cut.endSample
        }
        if cursor < endSample { kept.append((cursor, endSample)) }
        var extra = removedSamples - removed
        for index in kept.indices.reversed() where extra > 0 {
            let take = min(extra, kept[index].1 - kept[index].0)
            kept[index].1 -= take
            extra -= take
        }
        kept.removeAll { $0.1 <= $0.0 }
        guard extra == 0, !kept.isEmpty else { return nil }
        var result: [VoiceLabVideoCut] = []
        cursor = startSample
        for stretch in kept {
            if stretch.0 > cursor { result.append(VoiceLabVideoCut(startSample: cursor, endSample: stretch.0)) }
            cursor = stretch.1
        }
        if cursor < endSample { result.append(VoiceLabVideoCut(startSample: cursor, endSample: endSample)) }
        return result
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
    /// The picture's uniform retime, within ±`fitTolerance`: 1 for a voice laid out on the clip as edited (ADR-R46 update
    /// 2026-11-08); an earlier record keeps the retime it ran.
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

    /// Drops every record whose clip is gone or whose segments are no longer the project's own text-to-speech segments.
    /// Edits that remove a clip or a segment call it in the same step, so the project never stops validating, saving or
    /// rendering because of a record that names what was removed (ADR-R46). The segments themselves stay as voiced
    /// patches; only the record that bound them to one clip goes. A file that arrives with such a record is still refused.
    public static func pruneDangling(_ project: inout Project) {
        guard var records = project.voiceLab.wholeClipRevoices else { return }
        let clips = Set(project.edits.clips.map(\.id))
        let tts = Set(project.voiceLab.segments.filter { $0.kind == .tts }.map(\.id))
        records.removeAll { !clips.contains($0.clipId) || $0.segmentIds.isEmpty || !$0.segmentIds.allSatisfy(tts.contains) }
        project.voiceLab.wholeClipRevoices = records.isEmpty ? nil : records
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
