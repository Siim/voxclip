import Foundation

/// The limits of `shared/prompts/clip-autopilot.json` (ai.md §16.4). The same numbers fill the system prompt and bound the
/// validator, so the two cannot drift.
public struct ClipAutopilotLimits: Sendable, Equatable {
    public let maxTranscriptWords, maxClips, maxCuts, maxPauseCuts, maxRewrites, maxRewriteWords, maxRewriteTextWords: Int
    public let maxZooms, minWordsPerCaption, maxWordsPerCaption, maxMusic, maxQuestions, maxOptions: Int
    public let maxTitleScalars, maxHookScalars, maxPostScalars, maxReasonScalars, maxMusicPromptScalars, maxNoteBytes: Int
    public let minClipSeconds, maxClipSeconds, maxZoomSeconds, minZoomScale, maxZoomScale, minUnderVoiceDb, maxUnderVoiceDb: Double

    init(_ value: JSONValue) throws {
        func int(_ key: String) throws -> Int {
            guard let number = value[ai: key].aiDouble, number == number.rounded(), number >= 0, number <= 1_000_000 else {
                throw VoxClipError.sharedResourcesMissing
            }
            return Int(number)
        }
        func double(_ key: String) throws -> Double {
            guard let number = value[ai: key].aiDouble, number.isFinite, number >= 0 else { throw VoxClipError.sharedResourcesMissing }
            return number
        }
        maxTranscriptWords = try int("maxTranscriptWords"); maxClips = try int("maxClips"); maxCuts = try int("maxCuts")
        maxPauseCuts = try int("maxPauseCuts"); maxRewrites = try int("maxRewrites"); maxRewriteWords = try int("maxRewriteWords")
        maxRewriteTextWords = try int("maxRewriteTextWords"); maxZooms = try int("maxZooms")
        minWordsPerCaption = try int("minWordsPerCaption"); maxWordsPerCaption = try int("maxWordsPerCaption")
        maxMusic = try int("maxMusic"); maxQuestions = try int("maxQuestions"); maxOptions = try int("maxOptions")
        maxTitleScalars = try int("maxTitleScalars"); maxHookScalars = try int("maxHookScalars"); maxPostScalars = try int("maxPostScalars")
        maxReasonScalars = try int("maxReasonScalars"); maxMusicPromptScalars = try int("maxMusicPromptScalars")
        maxNoteBytes = try int("maxNoteBytes")
        minClipSeconds = try double("minClipSeconds"); maxClipSeconds = try double("maxClipSeconds")
        maxZoomSeconds = try double("maxZoomSeconds"); minZoomScale = try double("minZoomScale"); maxZoomScale = try double("maxZoomScale")
        minUnderVoiceDb = try double("minUnderVoiceDb"); maxUnderVoiceDb = try double("maxUnderVoiceDb")
        guard maxClips >= 1, maxRewriteWords >= 2, minWordsPerCaption >= 1, maxWordsPerCaption >= minWordsPerCaption,
              minClipSeconds < maxClipSeconds, minZoomScale >= 1, maxZoomScale >= minZoomScale, maxZoomScale <= MotionCue.maximumScale,
              maxUnderVoiceDb >= minUnderVoiceDb, maxMusic >= 1 else { throw VoxClipError.sharedResourcesMissing }
    }

    /// The `{name}` values the system prompt names.
    var templateValues: [String: String] {
        func text(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
        return ["maxClipSeconds": text(maxClipSeconds), "maxRewrites": String(maxRewrites), "maxRewriteWords": String(maxRewriteWords),
                "minWordsPerCaption": String(minWordsPerCaption), "maxWordsPerCaption": String(maxWordsPerCaption),
                "minUnderVoiceDb": text(minUnderVoiceDb), "maxUnderVoiceDb": text(maxUnderVoiceDb), "maxZoomSeconds": text(maxZoomSeconds),
                "minZoomScale": text(minZoomScale), "maxZoomScale": text(maxZoomScale), "maxOptions": String(maxOptions)]
    }
}

/// The fallbacks the validator uses for a value the reply leaves unreadable (ai.md §16.5).
public struct ClipAutopilotDefaults: Sendable, Equatable {
    public let styleID: String
    public let font: ClipAutopilotPlan.Font
    public let textCase: ClipAutopilotPlan.CaptionCase
    public let wordsPerCaption: Int
    public let underVoiceDb: Double
    public let zoomScale: Double
    public let score: Int
}

/// `shared/prompts/clip-autopilot.json`, read whole: every string the planner sends comes from it (ai.md §16.4).
public struct ClipAutopilotPrompt: Sendable {
    public let promptVersion: Int
    /// SHA-256 of the file's bytes with CRLF read as LF, as the Voice Lab prompts are hashed.
    public let sha256: String
    /// The system prompt with the limits filled in.
    public let system: String
    public let limits: ClipAutopilotLimits
    public let defaults: ClipAutopilotDefaults
    public let schemaName: String
    public let schema: JSONValue
    public let seriesSchemaName: String
    public let seriesSchema: JSONValue
    public let clipOutputTokens: Int
    public let seriesOutputTokens: Int
    public let minimumTimeout: Duration
    public let instrumentalSuffix: String
    let transcript: JSONValue
    let request: JSONValue

    public static let path = "prompts/clip-autopilot.json"

    public init(shared: SharedResources) throws {
        let read = try VoiceLabLLMChecks.readPrompt(shared, Self.path)
        try self.init(document: read.document, sha256: read.sha256)
    }

    init(document: JSONValue, sha256: String) throws {
        guard document[ai: "schemaVersion"].aiInt == 1, let version = document[ai: "promptVersion"].aiInt, version >= 1,
              let system = document[ai: "system"].aiString, let name = document[ai: "schemaName"].aiString,
              let seriesName = document[ai: "seriesSchemaName"].aiString,
              CanonicalResponseParser.validateSchemaSubset(document[ai: "schema"]),
              CanonicalResponseParser.validateSchemaSubset(document[ai: "seriesSchema"]),
              document[ai: "seriesSchema"][ai: "properties"][ai: "clips"][ai: "items"] == document[ai: "schema"],
              let clipTokens = document[ai: "maxOutputTokens"][ai: "clip"].aiInt, clipTokens > 0,
              let seriesTokens = document[ai: "maxOutputTokens"][ai: "series"].aiInt, seriesTokens > 0,
              let timeout = document[ai: "minimumTimeoutSeconds"].aiInt, timeout > 0,
              let suffix = document[ai: "music"][ai: "instrumentalSuffix"].aiString else { throw VoxClipError.sharedResourcesMissing }
        let limits = try ClipAutopilotLimits(document[ai: "limits"])
        let values = document[ai: "defaults"]
        guard let style = values[ai: "styleId"].aiString, let family = values[ai: "fontFamily"].aiString,
              let weight = values[ai: "fontWeight"].aiInt, let textCase = values[ai: "case"].aiString.flatMap(ClipAutopilotPlan.CaptionCase.init),
              let words = values[ai: "wordsPerCaption"].aiInt, (limits.minWordsPerCaption...limits.maxWordsPerCaption).contains(words),
              let under = values[ai: "underVoiceDb"].aiDouble, (limits.minUnderVoiceDb...limits.maxUnderVoiceDb).contains(under),
              let scale = values[ai: "zoomScale"].aiDouble, (limits.minZoomScale...limits.maxZoomScale).contains(scale),
              let score = values[ai: "score"].aiInt, (1...10).contains(score) else { throw VoxClipError.sharedResourcesMissing }
        self.promptVersion = version
        self.sha256 = sha256
        self.system = try Self.fill(system, limits.templateValues)
        self.limits = limits
        self.defaults = ClipAutopilotDefaults(styleID: style, font: .init(family: family, weight: weight), textCase: textCase,
                                              wordsPerCaption: words, underVoiceDb: under, zoomScale: scale, score: score)
        self.schemaName = name
        self.schema = document[ai: "schema"]
        self.seriesSchemaName = seriesName
        self.seriesSchema = document[ai: "seriesSchema"]
        self.clipOutputTokens = clipTokens
        self.seriesOutputTokens = seriesTokens
        self.minimumTimeout = .seconds(timeout)
        self.instrumentalSuffix = suffix
        self.transcript = document[ai: "transcriptBlock"]
        self.request = document[ai: "request"]
    }

    /// One `request` template with its `{name}` values filled in one pass, so a value is never read as a template.
    func request(_ key: String, _ values: [String: String]) throws -> String {
        guard let template = request[ai: key].aiString else { throw VoxClipError.sharedResourcesMissing }
        return try Self.fill(template, values)
    }

    func transcriptTemplate(_ key: String) throws -> String {
        guard let template = transcript[ai: key].aiString else { throw VoxClipError.sharedResourcesMissing }
        return template
    }

    var lineWords: Int { max(1, transcript[ai: "lineWords"].aiInt ?? 16) }

    /// Fills `{name}` placeholders; a placeholder without a value is a defect of the shared file.
    static func fill(_ template: String, _ values: [String: String]) throws -> String {
        var missing = false
        let result = template.replacing(#/\{([A-Za-z][A-Za-z0-9]*)\}/#) { match in
            guard let value = values[String(match.1)] else { missing = true; return String(match.0) }
            return value
        }
        guard !missing else { throw VoxClipError.sharedResourcesMissing }
        return result
    }
}
