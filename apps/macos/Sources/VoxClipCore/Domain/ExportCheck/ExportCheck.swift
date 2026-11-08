import Foundation

/// The four checks of an export (ADR-R49, doc/agent-clipping-benchmark.md item 6).
public enum ExportCheckKind: String, Codable, Sendable, CaseIterable { case words, sync, loudness, captions }

/// `ok`: measured and within its rule. `warning`: measured and outside it. `skipped`: not measured, with the reason.
public enum ExportCheckStatus: String, Codable, Sendable { case ok, warning, skipped }

/// One finding, at a time in the export (output seconds from its first frame).
public struct ExportCheckItem: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// An expected word heard as another word, or not heard.
        case mismatch
        /// A word next to a cut or a clip edge not heard, or heard as a shorter different word.
        case cutOff
        /// The audio track starts or ends more than a frame from the video track.
        case trackStart, trackEnd
        /// A revoiced or rewritten phrase's heard words sit further from where the edit placed them than the tolerance.
        case phraseOffset
        /// None of a phrase's words were heard, so its placement can't be measured.
        case phraseNotHeard
        /// Phrase placement wasn't measured (the words check was skipped).
        case phrasesSkipped
        /// The integrated loudness is outside the target's range, the true peak above the ceiling, or nothing is audible.
        case integratedLoudness, truePeak, silent
        /// A caption card or the title reaches into a safe-zone band.
        case captionBand, titleBand
    }

    public var kind: Kind
    /// Output seconds.
    public var time: Double
    public var expected: String?
    public var heard: String?
    /// What was measured: seconds for sync, LUFS or dBTP for loudness, the band overlap (fraction of the frame's height)
    /// for captions.
    public var value: Double?
    /// The rule's limit for `value`.
    public var limit: Double?
    /// The band's edge, for captions.
    public var band: CaptionSafeZones.Edge?
    /// The phrase (Voice Lab segment) id, for words in a phrase and for sync.
    public var phrase: String?
    public var reason: String?

    public init(kind: Kind, time: Double, expected: String? = nil, heard: String? = nil, value: Double? = nil, limit: Double? = nil,
                band: CaptionSafeZones.Edge? = nil, phrase: String? = nil, reason: String? = nil) {
        self.kind = kind; self.time = time; self.expected = expected; self.heard = heard; self.value = value; self.limit = limit
        self.band = band; self.phrase = phrase; self.reason = reason
    }
}

/// One check's outcome. `matched` and `total` are the words check's; `integratedLufs` and `truePeakDbtp` the loudness
/// check's; `startOffset` and `endOffset` the sync check's (audio minus video, seconds).
public struct ExportCheckResult: Codable, Sendable, Equatable {
    public var check: ExportCheckKind
    public var status: ExportCheckStatus
    /// Why the check was skipped.
    public var reason: String?
    public var items: [ExportCheckItem]
    public var matched: Int?
    public var total: Int?
    public var integratedLufs: Double?
    public var truePeakDbtp: Double?
    public var startOffset: Double?
    public var endOffset: Double?

    public init(check: ExportCheckKind, status: ExportCheckStatus, reason: String? = nil, items: [ExportCheckItem] = []) {
        self.check = check; self.status = status; self.reason = reason; self.items = items
    }

    static func skipped(_ check: ExportCheckKind, _ reason: String) -> ExportCheckResult {
        ExportCheckResult(check: check, status: .skipped, reason: reason)
    }
}

/// The four results, in `ExportCheckKind` order.
public struct ExportCheckReport: Codable, Sendable, Equatable {
    public var results: [ExportCheckResult]
    public init(results: [ExportCheckResult]) { self.results = results }
    /// No check warned: every result is `ok` or `skipped`.
    public var passed: Bool { results.allSatisfy { $0.status != .warning } }
    public subscript(_ check: ExportCheckKind) -> ExportCheckResult? { results.first { $0.check == check } }
}

/// What the check compares, all in output seconds. Built from the render the export ran (`ExportCheckExpectation`) and
/// from what was measured in the exported file.
public struct ExportCheckInput: Sendable, Equatable {
    /// A word the edit puts in the export: a kept source word, or a Rewrite's or revoiced phrase's word at its placed time.
    public struct Word: Sendable, Equatable {
        public var text: String
        public var start: Double
        public var end: Double
        /// A filler the edit keeps: never a mismatch when it isn't heard (Whisper drops "um" and "uh").
        public var optional: Bool
        /// The Voice Lab segment whose audio speaks it, for a revoiced or rewritten phrase.
        public var phrase: String?
        public init(text: String, start: Double, end: Double, optional: Bool = false, phrase: String? = nil) {
            self.text = text; self.start = start; self.end = end; self.optional = optional; self.phrase = phrase
        }
    }

    /// A word the local engine heard in the export.
    public struct Heard: Sendable, Equatable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
    }

    /// A revoiced or rewritten phrase where the edit placed it.
    public struct Phrase: Sendable, Equatable {
        public var id: String
        public var start: Double
        public var end: Double
        public init(id: String, start: Double, end: Double) { self.id = id; self.start = start; self.end = end }
    }

    /// A track's time range in the file.
    public struct Track: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    /// The export's measured loudness and its loudness setting.
    public struct Loudness: Sendable, Equatable {
        public var setting: ExportLoudness
        /// nil when nothing is above the gate.
        public var integratedLufs: Double?
        public var truePeakDbtp: Double?
        public init(setting: ExportLoudness, integratedLufs: Double?, truePeakDbtp: Double?) {
            self.setting = setting; self.integratedLufs = integratedLufs; self.truePeakDbtp = truePeakDbtp
        }
    }

    /// A caption card's or the title's laid-out box, top-left origin, in fractions of the frame.
    public struct Box: Sendable, Equatable {
        public enum Kind: String, Sendable { case caption, title }
        public var kind: Kind
        /// When it first shows, output seconds.
        public var time: Double
        public var rect: CaptionRect
        public init(kind: Kind, time: Double, rect: CaptionRect) { self.kind = kind; self.time = time; self.rect = rect }
    }

    public var expected: [Word]
    /// nil when no local engine heard the export: `words` and phrase sync are skipped with `hearingSkipped`.
    public var heard: [Heard]?
    public var hearingSkipped: String
    /// Where the edit joins two pieces that were not next to each other (cuts, a phrase's seams), output seconds.
    public var cuts: [Double]
    public var phrases: [Phrase]
    public var video: Track?
    public var audio: Track?
    /// One video frame, seconds.
    public var frameSeconds: Double
    /// nil when the export has no audio track.
    public var loudness: Loudness?
    public var boxes: [Box]
    /// The export frame's pixel size, which picks the safe-zone bands.
    public var frame: PixelSize

    public init(expected: [Word], heard: [Heard]?, hearingSkipped: String = ExportCheck.noLocalEngine, cuts: [Double] = [],
                phrases: [Phrase] = [], video: Track?, audio: Track?, frameSeconds: Double, loudness: Loudness?, boxes: [Box] = [],
                frame: PixelSize) {
        self.expected = expected; self.heard = heard; self.hearingSkipped = hearingSkipped; self.cuts = cuts; self.phrases = phrases
        self.video = video; self.audio = audio; self.frameSeconds = frameSeconds; self.loudness = loudness; self.boxes = boxes
        self.frame = frame
    }
}

/// The export self-check (ADR-R49): the export transcribed again and compared word for word with the edit, picture and
/// sound measured for sync, loudness measured against ADR-R47's target, and every caption card and the title checked
/// against the frame's safe-zone bands. It reports what it measured and nothing it can't: sync never claims the lips match.
public enum ExportCheck {
    public static let noLocalEngine = "No local transcription model"
    /// The words check warns below this share of matched words: the take QA's transcript threshold (voice-lab §8.11).
    public static let matchFloor = 0.9
    /// How far a phrase's heard words may sit from where the edit placed them, seconds: the median of the phrase's
    /// matched words' start offsets (ADR-R49 records the Whisper measurement it comes from).
    public static let phraseToleranceSeconds = 0.30
    /// ADR-R47's target and its tolerance.
    public static let targetLufs = SocialLoudness.targetLufs
    public static let loudnessToleranceLu = 1.0
    public static let ceilingDbtp = SocialLoudness.ceilingDbtp
    /// AAC rings a few hundredths of a dB past the PCM's ceiling on a limited transient (ADR-R47's amendment).
    public static let truePeakToleranceDb = 0.1

    public static func run(_ input: ExportCheckInput) -> ExportCheckReport {
        let alignment = input.heard.map { WordAlignment(expected: input.expected, heard: $0) }
        return ExportCheckReport(results: [words(input, alignment: alignment), sync(input, alignment: alignment), loudness(input),
                                           captions(input)])
    }

    // MARK: Words

    /// The expected words matched against the heard words, word by word.
    struct WordAlignment {
        /// For each expected word, the heard word it matched, if any.
        var matched: [Int?]
        /// For each unmatched expected word, the heard words in its place (between the matches around it), joined.
        var heardInstead: [String?]
        /// For each unmatched expected word, whether what was heard in its place is one shorter, different word.
        var heardShorter: [Bool]
        let heard: [ExportCheckInput.Heard]

        init(expected: [ExportCheckInput.Word], heard: [ExportCheckInput.Heard]) {
            self.heard = heard
            var expectedTokens: [String] = [], expectedOwner: [Int] = []
            for (index, word) in expected.enumerated() {
                for token in VoiceLabTakeQuality.tokens(word.text) { expectedTokens.append(token); expectedOwner.append(index) }
            }
            var heardTokens: [String] = [], heardOwner: [Int] = []
            for (index, word) in heard.enumerated() {
                for token in VoiceLabTakeQuality.tokens(word.text) { heardTokens.append(token); heardOwner.append(index) }
            }
            // A recognizer spells a name it does not know as the common word it sounds like ("Claude" as "cloud").
            let recognized = VoiceLabTakeQuality.normalizingHomophones(heardTokens, expected: expectedTokens,
                                                                       replacementWords: Set(expectedTokens))
            let pairs = VoiceLabTakeQuality.alignment(expected: expectedTokens, recognized: recognized)
            var tokenMatch = [Int?](repeating: nil, count: expectedTokens.count)
            for pair in pairs { tokenMatch[pair.expected] = pair.recognized }
            // A word matches when every token of it matched; it is matched to its first token's heard word.
            var matched = [Int?](repeating: nil, count: expected.count)
            var complete = [Bool](repeating: true, count: expected.count)
            for (token, owner) in expectedOwner.enumerated() {
                if let heardToken = tokenMatch[token] {
                    if matched[owner] == nil { matched[owner] = heardOwner[heardToken] }
                } else { complete[owner] = false }
            }
            for index in expected.indices where !complete[index] { matched[index] = nil }
            self.matched = matched
            // The heard tokens in each gap between matches go to that gap's unmatched expected tokens in order; the last
            // one takes what remains.
            var instead = [[String]](repeating: [], count: expected.count)
            var shorter = [Bool](repeating: false, count: expected.count)
            let anchors = [(expected: -1, recognized: -1)] + pairs + [(expected: expectedTokens.count, recognized: recognized.count)]
            for (left, right) in zip(anchors, anchors.dropFirst()) {
                let missing = Array((left.expected + 1)..<right.expected)
                let extra = Array((left.recognized + 1)..<right.recognized)
                for (offset, token) in missing.enumerated() {
                    let owner = expectedOwner[token]
                    let taken: [Int]
                    if offset >= extra.count { taken = [] }
                    else if offset < missing.count - 1 { taken = [extra[offset]] }
                    else { taken = Array(extra[offset...]) }
                    let words = taken.map { heardTokens[$0] }
                    instead[owner] += words
                    let wanted = expectedTokens[token]
                    if words.count == 1, let only = words.first, only.count < wanted.count, only != wanted { shorter[owner] = true }
                }
            }
            heardInstead = instead.map { $0.isEmpty ? nil : $0.joined(separator: " ") }
            heardShorter = shorter
        }
    }

    /// Whether each expected word sits next to a cut or a clip edge: the first and the last word, and any word with a cut
    /// between it and the word before or after it.
    static func atEdges(_ words: [ExportCheckInput.Word], cuts: [Double]) -> [Bool] {
        guard !words.isEmpty else { return [] }
        let sorted = cuts.sorted()
        func cut(between lower: Double, _ upper: Double) -> Bool { sorted.contains { $0 > lower && $0 < upper } }
        let last = words.count - 1
        return words.indices.map { index in
            if index == 0 || index == last { return true }
            let word = words[index]
            return cut(between: words[index - 1].end, word.end) || cut(between: word.start, words[index + 1].start)
        }
    }

    static func words(_ input: ExportCheckInput, alignment: WordAlignment?) -> ExportCheckResult {
        guard let alignment else { return .skipped(.words, input.hearingSkipped) }
        let expected = input.expected
        let scored = expected.indices.filter { !expected[$0].optional }
        guard !scored.isEmpty else { return .skipped(.words, "No words to check") }
        let edges = atEdges(expected, cuts: input.cuts)
        var items: [ExportCheckItem] = []
        var warn = false
        for index in scored where alignment.matched[index] == nil {
            let word = expected[index]
            let heard = alignment.heardInstead[index]
            let cutOff = edges[index] && (heard == nil || alignment.heardShorter[index])
            items.append(ExportCheckItem(kind: cutOff ? .cutOff : .mismatch, time: word.start, expected: word.text, heard: heard,
                                         phrase: word.phrase))
            if cutOff || word.phrase != nil { warn = true }
        }
        let matched = scored.count - items.count
        if Double(matched) < matchFloor * Double(scored.count) { warn = true }
        var result = ExportCheckResult(check: .words, status: warn ? .warning : .ok, items: items)
        result.matched = matched; result.total = scored.count
        return result
    }

    // MARK: Sync

    static func sync(_ input: ExportCheckInput, alignment: WordAlignment?) -> ExportCheckResult {
        var result = ExportCheckResult(check: .sync, status: .ok)
        let frame = input.frameSeconds
        if let video = input.video, let audio = input.audio {
            let start = audio.start - video.start, end = audio.end - video.end
            result.startOffset = start; result.endOffset = end
            // The microsecond keeps a track that ends exactly one frame from the other within the rule.
            if abs(start) > frame + 1e-6 {
                result.items.append(ExportCheckItem(kind: .trackStart, time: min(audio.start, video.start), value: start, limit: frame))
            }
            if abs(end) > frame + 1e-6 {
                result.items.append(ExportCheckItem(kind: .trackEnd, time: min(audio.end, video.end), value: end, limit: frame))
            }
        } else if input.phrases.isEmpty {
            return .skipped(.sync, input.video == nil ? "No video track" : "No audio track")
        }
        if !input.phrases.isEmpty, let alignment {
            for phrase in input.phrases { if let item = placement(of: phrase, input: input, alignment: alignment) { result.items.append(item) } }
        } else if !input.phrases.isEmpty {
            result.items.append(ExportCheckItem(kind: .phrasesSkipped, time: input.phrases.map(\.start).min() ?? 0, reason: input.hearingSkipped))
        }
        result.status = result.items.contains { $0.kind != .phrasesSkipped } ? .warning : .ok
        return result
    }

    /// The phrase's finding, nil when its heard words sit within the tolerance of where the edit placed them: the median
    /// of its matched words' start offsets, heard minus placed.
    static func placement(of phrase: ExportCheckInput.Phrase, input: ExportCheckInput, alignment: WordAlignment) -> ExportCheckItem? {
        let offsets = input.expected.indices.compactMap { index -> Double? in
            guard input.expected[index].phrase == phrase.id, let heard = alignment.matched[index] else { return nil }
            return alignment.heard[heard].start - input.expected[index].start
        }.sorted()
        guard !offsets.isEmpty else { return ExportCheckItem(kind: .phraseNotHeard, time: phrase.start, phrase: phrase.id) }
        let middle = offsets.count / 2
        let median = offsets.count % 2 == 1 ? offsets[middle] : (offsets[middle - 1] + offsets[middle]) / 2
        guard abs(median) > phraseToleranceSeconds else { return nil }
        return ExportCheckItem(kind: .phraseOffset, time: phrase.start, value: median, limit: phraseToleranceSeconds, phrase: phrase.id)
    }

    // MARK: Loudness

    static func loudness(_ input: ExportCheckInput) -> ExportCheckResult {
        guard let measured = input.loudness else { return .skipped(.loudness, "No audio track") }
        guard measured.setting == .social else { return .skipped(.loudness, "Loudness is off for this export") }
        var result = ExportCheckResult(check: .loudness, status: .ok)
        result.integratedLufs = measured.integratedLufs; result.truePeakDbtp = measured.truePeakDbtp
        guard let lufs = measured.integratedLufs, lufs.isFinite else {
            result.items = [ExportCheckItem(kind: .silent, time: 0)]
            result.status = .warning
            return result
        }
        if abs(lufs - targetLufs) > loudnessToleranceLu {
            result.items.append(ExportCheckItem(kind: .integratedLoudness, time: 0, value: lufs, limit: targetLufs))
        }
        if let peak = measured.truePeakDbtp, peak > ceilingDbtp + truePeakToleranceDb {
            result.items.append(ExportCheckItem(kind: .truePeak, time: 0, value: peak, limit: ceilingDbtp))
        }
        result.status = result.items.isEmpty ? .ok : .warning
        return result
    }

    // MARK: Captions

    static func captions(_ input: ExportCheckInput) -> ExportCheckResult {
        guard !input.boxes.isEmpty else { return .skipped(.captions, "No captions or title in this export") }
        let bands = CaptionSafeZones.bands(width: input.frame.width, height: input.frame.height)
        var items: [ExportCheckItem] = []
        for box in input.boxes {
            for band in bands {
                let overlap = CaptionSafeZones.overlap(box.rect, band: band)
                // A millionth of the frame's height is rounding, not a box in the band.
                guard overlap > 1e-6 else { continue }
                items.append(ExportCheckItem(kind: box.kind == .title ? .titleBand : .captionBand, time: box.time, value: overlap,
                                             limit: band.fraction, band: band.edge))
            }
        }
        return ExportCheckResult(check: .captions, status: items.isEmpty ? .ok : .warning, items: items)
    }
}
