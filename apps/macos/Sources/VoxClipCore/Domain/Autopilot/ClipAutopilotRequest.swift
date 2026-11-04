import Foundation

/// The creator's caption preference, from the project or Settings; nil fields leave the choice to Claude.
public struct ClipAutopilotCaptionPreference: Sendable, Equatable {
    public var styleId: String?
    public var font: ClipAutopilotPlan.Font?
    public var textCase: ClipAutopilotPlan.CaptionCase?
    public init(styleId: String? = nil, font: ClipAutopilotPlan.Font? = nil, textCase: ClipAutopilotPlan.CaptionCase? = nil) {
        self.styleId = styleId; self.font = font; self.textCase = textCase
    }
}

/// What to plan (ai.md §16.3): one clip span, or a whole video (or a range of it) as a series.
public struct ClipAutopilotRequest: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// Inclusive transcript item positions of the clip, as `ClipRange` resolves them.
        case clip(ClosedRange<Int>)
        /// The whole transcript when nil.
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

    public init(transcript: Transcript, edits: ProjectEdits = ProjectEdits(), mode: Mode,
                captionPreference: ClipAutopilotCaptionPreference? = nil, language: String? = nil, note: String? = nil) {
        self.transcript = transcript; self.edits = edits; self.mode = mode; self.captionPreference = captionPreference
        self.language = language; self.note = note
    }

    public var isSeries: Bool { if case .series = mode { true } else { false } }
}

/// Everything the validator checks a reply against (ai.md §16.5), built once per request.
public struct ClipAutopilotContext: Sendable {
    public let words: [TimedWord]
    public let corrections: [String: String]
    public let cutWordIDs: Set<String>
    public let pauses: [Pause]
    public let cutPauseIDs: Set<String>
    /// The request's scope: the clip span, or the series range.
    public let scope: ClosedRange<Int>
    public let styleIDs: Set<String>
    /// Bundled caption fonts, upright, with their files.
    public let fonts: [ClipAutopilotPlan.Font: String]
    public let preference: ClipAutopilotCaptionPreference?
    public let prompt: ClipAutopilotPrompt

    public init(words: [TimedWord], corrections: [String: String] = [:], cutWordIDs: Set<String> = [], pauses: [Pause] = [],
                cutPauseIDs: Set<String> = [], scope: ClosedRange<Int>, styleIDs: Set<String>, fonts: [ClipAutopilotPlan.Font: String],
                preference: ClipAutopilotCaptionPreference? = nil, prompt: ClipAutopilotPrompt) {
        self.words = words; self.corrections = corrections; self.cutWordIDs = cutWordIDs; self.pauses = pauses
        self.cutPauseIDs = cutPauseIDs; self.scope = scope; self.styleIDs = styleIDs; self.fonts = fonts
        self.preference = preference; self.prompt = prompt
    }

    /// The word as shown, corrections applied.
    func text(_ index: Int) -> String { corrections[words[index].id] ?? words[index].text }
    /// A word the request listed: inside the scope and not already cut.
    func isListed(_ index: Int) -> Bool { scope.contains(index) && !cutWordIDs.contains(words[index].id) }
    /// A listed item of kind word.
    func isListedWord(_ index: Int) -> Bool { isListed(index) && words[index].kind == .word }
    /// Whether the creator's preferred font is one the plan may use.
    func allows(_ font: ClipAutopilotPlan.Font) -> Bool { fonts[font] != nil || font == prompt.defaults.font }
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
    /// empty or outside the transcript.
    public static func scope(_ request: ClipAutopilotRequest) -> ClosedRange<Int>? {
        let count = request.transcript.words.count
        guard count > 0 else { return nil }
        let range: ClosedRange<Int>
        switch request.mode {
        case .clip(let span): range = span
        case .series(let span): range = span ?? 0...(count - 1)
        }
        return range.lowerBound >= 0 && range.upperBound < count ? range : nil
    }

    public static func render(_ request: ClipAutopilotRequest, prompt: ClipAutopilotPrompt, styles: [CaptionStyle],
                              fonts: [ClipAutopilotPlan.Font: String], pauses: [Pause]) throws -> Rendered {
        guard let scope = scope(request) else { throw VoiceLabError.invalidInput }
        let words = request.transcript.words
        let cut = Set(request.edits.cutWordIds)
        let listed = scope.filter { !cut.contains(words[$0].id) }
        guard listed.contains(where: { words[$0].kind == .word }), listed.count <= prompt.limits.maxTranscriptWords else { throw VoiceLabError.invalidInput }
        if let note = request.note, note.utf8.count > prompt.limits.maxNoteBytes { throw VoiceLabError.invalidInput }
        let language = request.language ?? request.transcript.language ?? "en"
        guard language.range(of: #"\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z"#, options: .regularExpression) != nil else { throw VoiceLabError.invalidInput }
        let transcriptText = try transcript(words: words, listed: listed, corrections: request.edits.corrections,
            pauses: pauses.filter { !request.edits.cutPauseIds.contains($0.id) }, prompt: prompt)
        let styleLines = try styles.filter { $0.id != "off" }.map {
            try prompt.request("styleLine", ["id": $0.id, "name": $0.name, "description": $0.description])
        }
        let defaultFont = prompt.defaults.font
        let fontLines = try [prompt.request("defaultFontLine", ["family": defaultFont.family, "weight": String(defaultFont.weight)])]
            + fonts.keys.filter { $0 != defaultFont }.sorted { ($0.family, $0.weight) < ($1.family, $1.weight) }.map {
                try prompt.request("fontLine", ["family": $0.family, "weight": String($0.weight)])
            }
        let preference: String
        if let wanted = request.captionPreference, wanted.styleId != nil || wanted.font != nil || wanted.textCase != nil {
            let font = wanted.font ?? defaultFont
            preference = try prompt.request("captionPreference", ["style": wanted.styleId ?? prompt.defaults.styleID, "family": font.family,
                "weight": String(font.weight), "case": (wanted.textCase ?? prompt.defaults.textCase).rawValue])
        } else {
            preference = try prompt.request("noCaptionPreference", [:])
        }
        let first = words[listed.first!], last = words[listed.last!]
        let seconds: Double = request.isSeries ? request.transcript.durationSeconds : last.end - first.start
        let rate = pace(words: words, listed: listed, corrections: request.edits.corrections,
                        pauses: pauses.filter { !request.edits.cutPauseIds.contains($0.id) }, keepSeconds: request.edits.pauseKeepSeconds)
        let block = try prompt.request("contextBlock", ["language": language, "seconds": toFixed1(max(0, seconds)),
            "wordsPerMinute": String(Int((rate * 60).rounded())), "words45": String(Int((rate * 45).rounded())),
            "captionPreference": preference, "styles": styleLines.joined(separator: "\n"), "fonts": fontLines.joined(separator: "\n"),
            "transcript": transcriptText])
        var instruction: String
        switch request.mode {
        case .clip:
            instruction = try prompt.request("clipInstruction", ["startWord": String(listed.first!), "endWord": String(listed.last!),
                "seconds": toFixed1(max(0, last.end - first.start))])
        case .series:
            instruction = try prompt.request("seriesInstruction", ["maxClips": String(prompt.limits.maxClips)])
        }
        if let note = request.note.map(AIText.trim), !note.isEmpty {
            instruction += "\n\n" + (try prompt.request("creatorNote", ["instruction": note]))
        }
        return Rendered(cachedBlock: block, instruction: instruction, scope: scope, listedWords: listed.count)
    }

    /// Words a second once fillers and pauses are cut (ai.md §16.3): the listed words that are not fillers, over the scope's
    /// time less every listed filler, event and unlabeled item, and less each detected pause beyond the kept length. Zero
    /// when nothing is left to time.
    static func pace(words: [TimedWord], listed: [Int], corrections: [String: String], pauses: [Pause], keepSeconds: Double) -> Double {
        guard let firstIndex = listed.first, let lastIndex = listed.last else { return 0 }
        var spoken = 0
        var seconds = words[lastIndex].end - words[firstIndex].start
        for index in listed {
            let word = words[index]
            if word.kind == .word && !EditingPrimitives.filler(corrections[word.id] ?? word.text) { spoken += 1 }
            else { seconds -= word.end - word.start }
        }
        let scope = firstIndex..<lastIndex
        for pause in pauses where scope.contains(pause.afterIndex) { seconds -= max(0, pause.end - pause.start - keepSeconds) }
        return seconds > 0 ? Double(spoken) / seconds : 0
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
