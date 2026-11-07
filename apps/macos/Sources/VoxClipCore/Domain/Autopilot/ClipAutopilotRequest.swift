import Foundation

/// The creator's caption choices, from the project's clip style or Settings. A set field is fixed: every plan uses it as
/// it is. A nil field leaves the choice to Claude, per clip.
public struct ClipAutopilotCaptionPreference: Sendable, Equatable {
    public var styleId: String?
    public var font: ClipAutopilotPlan.Font?
    public var textCase: ClipAutopilotPlan.CaptionCase?
    public init(styleId: String? = nil, font: ClipAutopilotPlan.Font? = nil, textCase: ClipAutopilotPlan.CaptionCase? = nil) {
        self.styleId = styleId; self.font = font; self.textCase = textCase
    }
    var isEmpty: Bool { styleId == nil && font == nil && textCase == nil }
}

/// The tone the planner writes a clip's words in (ai.md §16.3; design.md §6.6 Tone row). Nil on a request sends no tone
/// line, as before prompt version 6.
public enum ClipAutopilotTone: Sendable, Equatable {
    /// Claude picks one of `offered` per clip (the catalogue tones), or none.
    case auto(offered: [RewriteTone])
    /// The creator's own tone: no tone change (As I said it, and every style that never rewords).
    case asSaid
    /// The tone the creator fixed: a catalogue tone or a saved one.
    case fixed(RewriteTone)
}

/// What to plan (ai.md §16.3): one clip span, several clip spans, or a whole video (or a range of it) as a series.
public struct ClipAutopilotRequest: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// Inclusive transcript item positions of the clip, as `ClipRange` resolves them.
        case clip(ClosedRange<Int>)
        /// Clips chosen already, such as the top suggestions: each span is planned as its own `clip` request, in parallel
        /// where the service has lanes, and the result ranks them by score.
        case clips([ClosedRange<Int>])
        /// The whole transcript when nil. Two stages: the moments, then each moment's plan.
        case series(ClosedRange<Int>?)
    }

    public var transcript: Transcript
    /// The project's current edits: cut words are left out of the request, corrections are applied, and their pauses are
    /// the ones a plan may tighten.
    public var edits: ProjectEdits
    public var mode: Mode
    public var captionPreference: ClipAutopilotCaptionPreference?
    /// BCP 47; the transcript's language when nil.
    public var language: String?
    /// An optional note from the creator, sent as data.
    public var note: String?
    /// The tone of each clip's words; nil sends no tone line. A series' moments stage never gets one.
    public var tone: ClipAutopilotTone?
    /// A `clips` request's spans as Find Clips described them, one per span in the same order (Claude mode): each clip's
    /// plan is told its rank, its title and idea, and the other clips of the series, as a series' second stage is. Empty
    /// plans each span on its own.
    public var moments: [ClipAutopilotMoment]

    public init(transcript: Transcript, edits: ProjectEdits = ProjectEdits(), mode: Mode,
                captionPreference: ClipAutopilotCaptionPreference? = nil, language: String? = nil, note: String? = nil,
                tone: ClipAutopilotTone? = nil, moments: [ClipAutopilotMoment] = []) {
        self.transcript = transcript; self.edits = edits; self.mode = mode; self.captionPreference = captionPreference
        self.language = language; self.note = note; self.tone = tone; self.moments = moments
    }

    public var isSeries: Bool { if case .series = mode { true } else { false } }

    /// The same request for one clip span.
    func clip(_ span: ClosedRange<Int>) -> ClipAutopilotRequest {
        var copy = self
        copy.mode = .clip(span)
        return copy
    }
}

extension ClipAutopilotMoment {
    /// A Find Clips suggestion as a moment of Claude mode's series (`ClipAutopilotRequest.moments`): its span, title and
    /// reason, the score it was given and no caption style, which each clip's plan picks.
    public static func found(_ span: ClosedRange<Int>, title: String, reason: String, score: Int) -> ClipAutopilotMoment {
        ClipAutopilotMoment(startWord: span.lowerBound, endWord: span.upperBound, title: title, idea: reason, score: score,
                            verdict: .implied(by: score), captionStyle: "")
    }
}

/// What the second stage of a series tells the clip plan about its moment (ai.md §16.3).
struct ClipAutopilotMomentBrief: Sendable, Equatable {
    /// 1-based rank among the picked moments.
    let rank: Int
    let count: Int
    let moment: ClipAutopilotMoment
    /// The caption styles the other moments use, in rank order.
    let otherStyles: [String]
    /// The other moments of the series, in rank order: their titles and where they start (prompt version 7).
    let others: [ClipAutopilotMoment]
}

/// Everything the validator checks a reply against (ai.md §16.5), built once per request.
public struct ClipAutopilotContext: Sendable {
    public let words: [TimedWord]
    public let corrections: [String: String]
    public let cutWordIDs: Set<String>
    public let pauses: [Pause]
    public let cutPauseIDs: Set<String>
    /// How much of a tightened pause the editor keeps (`ProjectEdits.pauseKeepSeconds`).
    public let pauseKeepSeconds: Double
    /// The request's scope: the clip span, or the series range.
    public let scope: ClosedRange<Int>
    public let styleIDs: Set<String>
    /// Bundled caption fonts, upright, with their files.
    public let fonts: [ClipAutopilotPlan.Font: String]
    public let preference: ClipAutopilotCaptionPreference?
    public let prompt: ClipAutopilotPrompt
    /// The request's tone: what the plan's `tone` may be.
    public let tone: ClipAutopilotTone?

    public init(words: [TimedWord], corrections: [String: String] = [:], cutWordIDs: Set<String> = [], pauses: [Pause] = [],
                cutPauseIDs: Set<String> = [], pauseKeepSeconds: Double = 0.15, scope: ClosedRange<Int>, styleIDs: Set<String>,
                fonts: [ClipAutopilotPlan.Font: String], preference: ClipAutopilotCaptionPreference? = nil, prompt: ClipAutopilotPrompt,
                tone: ClipAutopilotTone? = nil) {
        self.words = words; self.corrections = corrections; self.cutWordIDs = cutWordIDs; self.pauses = pauses
        self.cutPauseIDs = cutPauseIDs; self.pauseKeepSeconds = pauseKeepSeconds; self.scope = scope; self.styleIDs = styleIDs
        self.fonts = fonts; self.preference = preference; self.prompt = prompt; self.tone = tone
    }

    /// The word as shown, corrections applied.
    func text(_ index: Int) -> String { corrections[words[index].id] ?? words[index].text }
    /// A word the request listed: inside the scope and not already cut.
    func isListed(_ index: Int) -> Bool { scope.contains(index) && !cutWordIDs.contains(words[index].id) }
    /// A listed item of kind word.
    func isListedWord(_ index: Int) -> Bool { isListed(index) && words[index].kind == .word }
    /// Whether the creator's preferred font is one the plan may use.
    func allows(_ font: ClipAutopilotPlan.Font) -> Bool { fonts[font] != nil || font == prompt.defaults.font }
    /// The caption style the creator fixed, when it is a built-in style other than `off`.
    var fixedStyle: String? { preference?.styleId.flatMap { styleIDs.contains($0) && $0 != "off" ? $0 : nil } }

    /// This context with the plan's corrections applied on top of the project's, so later checks read the right words.
    func correcting(_ plan: [ClipAutopilotPlan.Correction]) -> ClipAutopilotContext {
        guard !plan.isEmpty else { return self }
        var merged = corrections
        for correction in plan { merged[words[correction.word].id] = correction.text }
        return ClipAutopilotContext(words: words, corrections: merged, cutWordIDs: cutWordIDs, pauses: pauses, cutPauseIDs: cutPauseIDs,
                                    pauseKeepSeconds: pauseKeepSeconds, scope: scope, styleIDs: styleIDs, fonts: fonts,
                                    preference: preference, prompt: prompt, tone: tone)
    }
}

/// The bundled caption fonts of `shared/fonts/fonts.json`: upright faces only, keyed by family and weight.
public enum ClipAutopilotFonts {
    public static func load(shared: SharedResources) throws -> [ClipAutopilotPlan.Font: String] {
        guard let data = try? Data(contentsOf: shared.root.appendingPathComponent("fonts/fonts.json")),
              let document = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw VoxClipError.sharedResourcesMissing }
        var fonts: [ClipAutopilotPlan.Font: String] = [:]
        for entry in document[ai: "fonts"].aiArray where entry[ai: "italic"].aiBool != true {
            guard let family = entry[ai: "family"].aiString, let weight = entry[ai: "weight"].aiInt, let file = entry[ai: "file"].aiString else { continue }
            fonts[.init(family: family, weight: weight)] = fonts[.init(family: family, weight: weight)] ?? file
        }
        guard !fonts.isEmpty else { throw VoxClipError.sharedResourcesMissing }
        return fonts
    }
}

/// Renders the request text from the prompt file (ai.md §16.4). Pure: it reads no file and sends nothing.
public enum ClipAutopilotRequestBuilder {
    /// The rendered `cachedBlock` and `instruction`, and the scope they cover.
    public struct Rendered: Sendable, Equatable {
        public let cachedBlock: String
        public let instruction: String
        public let scope: ClosedRange<Int>
        public let listedWords: Int
    }

    /// The scope of a request: a clip span as given, or the series range (the whole transcript when nil). Nil when it is
    /// empty or outside the transcript, and for `clips`, whose spans are each their own request.
    public static func scope(_ request: ClipAutopilotRequest) -> ClosedRange<Int>? {
        let count = request.transcript.words.count
        guard count > 0 else { return nil }
        let range: ClosedRange<Int>
        switch request.mode {
        case .clip(let span): range = span
        case .series(let span): range = span ?? 0...(count - 1)
        case .clips: return nil
        }
        return range.lowerBound >= 0 && range.upperBound < count ? range : nil
    }

    static func render(_ request: ClipAutopilotRequest, prompt: ClipAutopilotPrompt, styles: [CaptionStyle],
                       fonts: [ClipAutopilotPlan.Font: String], pauses: [Pause], moment: ClipAutopilotMomentBrief? = nil) throws -> Rendered {
        guard let scope = scope(request) else { throw VoiceLabError.invalidInput }
        let words = request.transcript.words
        let cut = Set(request.edits.cutWordIds)
        let listed = scope.filter { !cut.contains(words[$0].id) }
        guard listed.contains(where: { words[$0].kind == .word }), listed.count <= prompt.limits.maxTranscriptWords else { throw VoiceLabError.invalidInput }
        if let note = request.note, note.utf8.count > prompt.limits.maxNoteBytes { throw VoiceLabError.invalidInput }
        let language = request.language ?? request.transcript.language ?? "en"
        guard language.range(of: #"\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z"#, options: .regularExpression) != nil else { throw VoiceLabError.invalidInput }
        let uncutPauses = pauses.filter { !request.edits.cutPauseIds.contains($0.id) }
        let transcriptText = try transcript(words: words, listed: listed, corrections: request.edits.corrections, pauses: uncutPauses, prompt: prompt)
        let styleLines = try styles.filter { $0.id != "off" }.map {
            try prompt.request("styleLine", ["id": $0.id, "name": $0.name, "description": $0.description])
        }
        let defaultFont = prompt.defaults.font
        let fontLines = try [prompt.request("defaultFontLine", ["family": defaultFont.family, "weight": String(defaultFont.weight)])]
            + fonts.keys.filter { $0 != defaultFont }.sorted { ($0.family, $0.weight) < ($1.family, $1.weight) }.map {
                try prompt.request("fontLine", ["family": $0.family, "weight": String($0.weight)])
            }
        let first = words[listed.first!], last = words[listed.last!]
        let seconds: Double = request.isSeries ? request.transcript.durationSeconds : last.end - first.start
        let spoken = spokenTime(words: words, listed: listed, corrections: request.edits.corrections, pauses: uncutPauses,
                                keepSeconds: request.edits.pauseKeepSeconds)
        let rate = spoken.seconds > 0 ? Double(spoken.words) / spoken.seconds : 0
        let limits = prompt.limits, values = limits.templateValues
        let block = try prompt.request("contextBlock", ["language": language, "seconds": toFixed1(max(0, seconds)),
            "wordsPerMinute": String(Int((rate * 60).rounded())), "minTargetSeconds": values["minTargetSeconds"]!,
            "maxTargetSeconds": values["maxTargetSeconds"]!, "wordsMin": String(Int((rate * limits.minTargetSeconds).rounded())),
            "wordsMax": String(Int((rate * limits.maxTargetSeconds).rounded())),
            "captionPreference": try preferenceLine(request.captionPreference, prompt: prompt),
            "styles": styleLines.joined(separator: "\n"), "fonts": fontLines.joined(separator: "\n"), "transcript": transcriptText])
        var instruction: String
        switch request.mode {
        case .clip, .clips:
            let estimate = max(0, spoken.seconds)
            let excess = estimate - limits.maxTargetSeconds
            let lengthHint = excess > 0 ? try prompt.request("lengthOver", ["excess": String(Int(excess.rounded(.up)))])
                                        : try prompt.request("lengthFits", [:])
            instruction = try prompt.request("clipInstruction", ["startWord": String(listed.first!), "endWord": String(listed.last!),
                "seconds": toFixed1(max(0, last.end - first.start)), "estimate": toFixed1(estimate),
                "minTargetSeconds": values["minTargetSeconds"]!, "maxTargetSeconds": values["maxTargetSeconds"]!, "lengthHint": lengthHint])
            let elsewhere = names(words: words, outside: scope, corrections: request.edits.corrections)
            if !elsewhere.isEmpty { instruction += try prompt.request("names", ["names": elsewhere.joined(separator: ", ")]) }
            if let tone = request.tone { instruction += try toneLine(tone, prompt: prompt) }
            if let moment {
                // Find Clips' moments carry no caption style: the plan picks one, told only the other clips (Claude mode).
                let fixed = request.captionPreference?.styleId != nil || moment.moment.captionStyle.isEmpty
                let caption = fixed ? "" : try prompt.request("momentCaption", ["style": moment.moment.captionStyle,
                    "reason": moment.moment.captionReason.isEmpty ? "picked for the series" : moment.moment.captionReason,
                    "others": moment.otherStyles.isEmpty ? "none" : moment.otherStyles.joined(separator: ", ")])
                let others = moment.others.filter { words.indices.contains($0.startWord) }.map {
                    "“\($0.title)” at \(AIText.formatTime(words[$0.startWord].start))"
                }
                let series = others.isEmpty ? "" : try prompt.request("momentOthers", ["others": others.joined(separator: "; ")])
                instruction = try prompt.request("momentInstruction", ["rank": String(moment.rank), "count": String(moment.count),
                    "title": moment.moment.title, "idea": moment.moment.idea, "caption": caption]) + series + "\n\n" + instruction
            }
        case .series:
            instruction = try prompt.request("seriesInstruction", ["maxClips": String(prompt.limits.maxClips)])
        }
        if let note = request.note.map(AIText.trim), !note.isEmpty {
            instruction += "\n\n" + (try prompt.request("creatorNote", ["instruction": note]))
        }
        return Rendered(cachedBlock: block, instruction: instruction, scope: scope, listedWords: listed.count)
    }

    /// Names written elsewhere in the recording, for a clip's corrections (ai.md §16.3): each word outside `scope` that
    /// starts with a capital letter but not a sentence, of at least 3 characters once its punctuation is trimmed, other
    /// than "I" contractions, corrections applied, in transcript order without repeats, at most `maxNames`.
    static func names(words: [TimedWord], outside scope: ClosedRange<Int>, corrections: [String: String]) -> [String] {
        var names: [String] = []
        var sentenceStart = true
        for (index, word) in words.enumerated() where word.kind == .word {
            let shown = corrections[word.id] ?? word.text
            defer { sentenceStart = [".", "!", "?", "…"].contains(where: { shown.hasSuffix($0) }) }
            guard !scope.contains(index), !sentenceStart else { continue }
            let core = String(shown.drop { !$0.isLetter && !$0.isNumber }.reversed().drop { !$0.isLetter && !$0.isNumber }.reversed())
            guard let first = core.first, first.isUppercase, core.count >= 3, !core.hasPrefix("I'"), !core.hasPrefix("I’"),
                  !names.contains(core) else { continue }
            names.append(AIText.prefix(core, utf16: 40))
            if names.count == maxNames { break }
        }
        return names
    }

    static let maxNames = 20

    /// The clip instruction's tone line (prompt version 6): the creator's fixed tone with its instruction, the tones to
    /// choose from under Auto, or the creator's own tone.
    static func toneLine(_ tone: ClipAutopilotTone, prompt: ClipAutopilotPrompt) throws -> String {
        switch tone {
        case .fixed(let tone):
            return try prompt.request("toneFixed", ["title": tone.title, "id": tone.id, "instruction": tone.instruction])
        case .asSaid:
            return try prompt.request("toneAsSaid", [:])
        case .auto(let offered):
            guard !offered.isEmpty else { return try prompt.request("toneAsSaid", [:]) }
            let lines = try offered.map {
                try prompt.request("toneLine", ["id": $0.id, "title": $0.title, "descriptor": $0.detail, "instruction": $0.instruction])
            }
            return try prompt.request("toneAuto", ["tones": lines.joined(separator: "\n")])
        }
    }

    /// The caption preference line: only the fields the creator fixed, or `noCaptionPreference`.
    static func preferenceLine(_ preference: ClipAutopilotCaptionPreference?, prompt: ClipAutopilotPrompt) throws -> String {
        guard let preference, !preference.isEmpty else { return try prompt.request("noCaptionPreference", [:]) }
        var parts: [String] = []
        if let style = preference.styleId { parts.append(try prompt.request("preferenceStyle", ["style": style])) }
        if let font = preference.font { parts.append(try prompt.request("preferenceFont", ["family": font.family, "weight": String(font.weight)])) }
        if let textCase = preference.textCase { parts.append(try prompt.request("preferenceCase", ["case": textCase.rawValue])) }
        return try prompt.request("captionPreference", ["parts": parts.joined(separator: "; ")])
    }

    /// The listed words that are not fillers, and the time they take once fillers and pauses are cut (ai.md §16.3): the
    /// scope's time less every listed filler, event and unlabeled item, and less each detected pause beyond the kept length.
    static func spokenTime(words: [TimedWord], listed: [Int], corrections: [String: String], pauses: [Pause],
                           keepSeconds: Double) -> (words: Int, seconds: Double) {
        guard let firstIndex = listed.first, let lastIndex = listed.last else { return (0, 0) }
        var spoken = 0
        var seconds = words[lastIndex].end - words[firstIndex].start
        for index in listed {
            let word = words[index]
            if word.kind == .word && !EditingPrimitives.filler(corrections[word.id] ?? word.text) { spoken += 1 }
            else { seconds -= word.end - word.start }
        }
        let scope = firstIndex..<lastIndex
        for pause in pauses where scope.contains(pause.afterIndex) { seconds -= max(0, pause.end - pause.start - keepSeconds) }
        return (spoken, seconds)
    }

    /// The `voxclip-indexed-words-v1` transcript: lines of `[index]word`, a new line after a sentence end, a pause or
    /// `lineWords` items; fillers and pauses marked from the editor's own detection.
    static func transcript(words: [TimedWord], listed: [Int], corrections: [String: String], pauses: [Pause],
                           prompt: ClipAutopilotPrompt) throws -> String {
        let wordTemplate = try prompt.transcriptTemplate("word"), fillerTemplate = try prompt.transcriptTemplate("filler")
        let eventTemplate = try prompt.transcriptTemplate("event"), lineTemplate = try prompt.transcriptTemplate("line")
        let pauseTemplate = try prompt.transcriptTemplate("pause")
        let listedSet = Set(listed)
        let pauseAfter = Dictionary(pauses.filter { listedSet.contains($0.afterIndex) }.map { ($0.afterIndex, $0) }, uniquingKeysWith: { first, _ in first })
        var lines: [String] = []
        var current: [String] = []
        var lineStart: Double?
        func flush() throws {
            guard !current.isEmpty, let start = lineStart else { return }
            lines.append(try ClipAutopilotPrompt.fill(lineTemplate, ["time": AIText.formatTime(start), "words": current.joined(separator: " ")]))
            current = []; lineStart = nil
        }
        for index in listed {
            let word = words[index]
            let shown = AIText.prefix(corrections[word.id] ?? word.text, utf16: 100)
            let token: String
            switch word.kind {
            case .word:
                token = try ClipAutopilotPrompt.fill(EditingPrimitives.filler(shown) ? fillerTemplate : wordTemplate, ["index": String(index), "text": shown])
            case .event, .unlabeledSpeech:
                let label = shown.trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
                token = try ClipAutopilotPrompt.fill(eventTemplate, ["index": String(index), "text": label.isEmpty ? "…" : label])
            }
            if lineStart == nil { lineStart = word.start }
            current.append(token)
            let sentenceEnd = word.kind == .word && [".", "!", "?", "…"].contains(where: { shown.hasSuffix($0) })
            if let pause = pauseAfter[index] {
                try flush()
                lines.append(try ClipAutopilotPrompt.fill(pauseTemplate, ["seconds": toFixed1(pause.end - pause.start), "index": String(index)]))
            } else if sentenceEnd || current.count >= prompt.lineWords {
                try flush()
            }
        }
        try flush()
        return (try prompt.transcriptTemplate("prefix")) + lines.joined(separator: "\n") + (try prompt.transcriptTemplate("suffix"))
    }
}
