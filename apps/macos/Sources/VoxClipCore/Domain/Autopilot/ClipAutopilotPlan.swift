import Foundation

/// One clip's complete "Make it postable" plan (ai.md §16): every decision Claude made, already checked against the
/// transcript, the caption styles and the bundled fonts (`ClipAutopilotValidator`). Word indices are transcript item
/// positions, as the clip finder's are (ai.md §11.2); every range is inclusive. Building, mapping and pricing a plan sends
/// nothing and changes no project.
public struct ClipAutopilotPlan: Codable, Sendable, Equatable {
    /// `version` of this contract. A reader refuses any other value.
    public static let currentVersion = 1

    public enum CutKind: String, Codable, Sendable, CaseIterable { case filler, stumble, `repeat`, falseStart, tangent, other }

    /// Words to remove, `startWord...endWord`.
    public struct Cut: Codable, Sendable, Equatable {
        public var startWord: Int
        public var endWord: Int
        public var kind: CutKind
        public var reason: String
        public init(startWord: Int, endWord: Int, kind: CutKind, reason: String) {
            self.startWord = startWord; self.endWord = endWord; self.kind = kind; self.reason = reason
        }
    }

    /// A detected pause to tighten to the project's kept length: the editor's pause after `afterWord`.
    public struct PauseCut: Codable, Sendable, Equatable {
        public var afterWord: Int
        public var reason: String
        public init(afterWord: Int, reason: String) { self.afterWord = afterWord; self.reason = reason }
    }

    /// New words for `startWord...endWord`, re-voiced with the creator's voice. `text` is the whole phrase as spoken: it
    /// begins with the range's first word and ends with its last, the bridge words (voice-lab.md §8.4).
    public struct Rewrite: Codable, Sendable, Equatable {
        public var startWord: Int
        public var endWord: Int
        public var text: String
        public var reason: String
        public init(startWord: Int, endWord: Int, text: String, reason: String) {
            self.startWord = startWord; self.endWord = endWord; self.text = text; self.reason = reason
        }
    }

    public enum CaptionCase: String, Codable, Sendable, CaseIterable {
        case upper, lower, asSaid
        /// The caption style's `text.transform` (captions.md §2.4).
        public var transform: String {
            switch self { case .upper: "uppercase"; case .lower: "lowercase"; case .asSaid: "none" }
        }
    }

    public struct Font: Codable, Sendable, Hashable {
        public var family: String
        public var weight: Int
        public init(family: String, weight: Int) { self.family = family; self.weight = weight }
    }

    public struct Captions: Codable, Sendable, Equatable {
        /// A built-in style id from shared/caption-styles, never `off`.
        public var styleId: String
        public var font: Font
        public var textCase: CaptionCase
        public var wordsPerCaption: Int
        public init(styleId: String, font: Font, textCase: CaptionCase, wordsPerCaption: Int) {
            self.styleId = styleId; self.font = font; self.textCase = textCase; self.wordsPerCaption = wordsPerCaption
        }
        private enum CodingKeys: String, CodingKey { case styleId, font, textCase = "case", wordsPerCaption }
    }

    /// One background track to generate with Eleven Music; `underVoiceDb` is how far the music sits under the voice.
    public struct Music: Codable, Sendable, Equatable {
        public var title: String
        public var mood: String
        /// Instrumental only: the validator appends the prompt file's suffix when the prompt does not say so.
        public var prompt: String
        public var reason: String
        public var underVoiceDb: Double
        public init(title: String, mood: String, prompt: String, reason: String, underVoiceDb: Double) {
            self.title = title; self.mood = mood; self.prompt = prompt; self.reason = reason; self.underVoiceDb = underVoiceDb
        }
    }

    /// A punch-in from the start of `word` to the end of `untilWord`, at `scale` (at most `MotionCue.maximumScale`).
    public struct Zoom: Codable, Sendable, Equatable {
        public var word: Int
        public var untilWord: Int
        public var scale: Double
        public var reason: String
        public init(word: Int, untilWord: Int, scale: Double, reason: String) {
            self.word = word; self.untilWord = untilWord; self.scale = scale; self.reason = reason
        }
    }

    public enum Verdict: String, Codable, Sendable, CaseIterable {
        case postFirst, post, casualPost, holdBack
        /// The verdict a score implies, used when the reply's verdict is unreadable.
        public static func implied(by score: Int) -> Verdict {
            score >= 9 ? .postFirst : score >= 7 ? .post : score >= 5 ? .casualPost : .holdBack
        }
    }

    /// Something Claude was unsure of, with the answer the plan already follows.
    public struct Question: Codable, Sendable, Equatable {
        public var question: String
        public var answer: String
        public var options: [String]
        public init(question: String, answer: String, options: [String]) { self.question = question; self.answer = answer; self.options = options }
    }

    /// What the validator changed or left out of the reply, so a review can say so and tests can pin it.
    public struct Repair: Codable, Sendable, Equatable {
        public enum Action: String, Codable, Sendable { case dropped, repaired }
        /// The reply field, with its item index where it has one, such as `rewrites[1]`.
        public var field: String
        public var action: Action
        public var detail: String
        public init(field: String, action: Action, detail: String) { self.field = field; self.action = action; self.detail = detail }
    }

    public var version: Int
    public var startWord: Int
    public var endWord: Int
    public var title: String
    /// On-screen text for the first 2 s.
    public var hook: String
    public var cuts: [Cut]
    public var pauseCuts: [PauseCut]
    public var rewrites: [Rewrite]
    public var captions: Captions
    /// Up to three suggestions; `musicPick` indexes the one to use, nil when there is none.
    public var music: [Music]
    public var musicPick: Int?
    public var zooms: [Zoom]
    /// Short X/LinkedIn post text.
    public var postText: String
    /// 1...10.
    public var score: Int
    public var verdict: Verdict
    public var scoreReason: String
    public var questions: [Question]
    public var repairs: [Repair]

    public init(version: Int = ClipAutopilotPlan.currentVersion, startWord: Int, endWord: Int, title: String, hook: String,
                cuts: [Cut] = [], pauseCuts: [PauseCut] = [], rewrites: [Rewrite] = [], captions: Captions, music: [Music] = [],
                musicPick: Int? = nil, zooms: [Zoom] = [], postText: String, score: Int, verdict: Verdict, scoreReason: String = "",
                questions: [Question] = [], repairs: [Repair] = []) {
        self.version = version; self.startWord = startWord; self.endWord = endWord; self.title = title; self.hook = hook
        self.cuts = cuts; self.pauseCuts = pauseCuts; self.rewrites = rewrites; self.captions = captions; self.music = music
        self.musicPick = musicPick; self.zooms = zooms; self.postText = postText; self.score = score; self.verdict = verdict
        self.scoreReason = scoreReason; self.questions = questions; self.repairs = repairs
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unknown plan version")
        }
        self.init(version: version, startWord: try values.decode(Int.self, forKey: .startWord), endWord: try values.decode(Int.self, forKey: .endWord),
                  title: try values.decode(String.self, forKey: .title), hook: try values.decode(String.self, forKey: .hook),
                  cuts: try values.decode([Cut].self, forKey: .cuts), pauseCuts: try values.decode([PauseCut].self, forKey: .pauseCuts),
                  rewrites: try values.decode([Rewrite].self, forKey: .rewrites), captions: try values.decode(Captions.self, forKey: .captions),
                  music: try values.decode([Music].self, forKey: .music), musicPick: try values.decodeIfPresent(Int.self, forKey: .musicPick),
                  zooms: try values.decode([Zoom].self, forKey: .zooms), postText: try values.decode(String.self, forKey: .postText),
                  score: try values.decode(Int.self, forKey: .score), verdict: try values.decode(Verdict.self, forKey: .verdict),
                  scoreReason: try values.decode(String.self, forKey: .scoreReason), questions: try values.decode([Question].self, forKey: .questions),
                  repairs: try values.decodeIfPresent([Repair].self, forKey: .repairs) ?? [])
    }

    private enum CodingKeys: String, CodingKey {
        case version, startWord, endWord, title, hook, cuts, pauseCuts, rewrites, captions, music, musicPick, zooms, postText, score,
             verdict, scoreReason, questions, repairs
    }

    /// The picked music, when there is one.
    public var pickedMusic: Music? { musicPick.flatMap { music.indices.contains($0) ? music[$0] : nil } }
}

/// A whole video made into a series: its clips ranked best first, each with its own plan, never overlapping.
public struct ClipAutopilotSeries: Codable, Sendable, Equatable {
    public var version: Int
    public var plans: [ClipAutopilotPlan]
    /// Clips the validator left out (overlap, length, an unreadable span).
    public var repairs: [ClipAutopilotPlan.Repair]
    public init(version: Int = ClipAutopilotPlan.currentVersion, plans: [ClipAutopilotPlan], repairs: [ClipAutopilotPlan.Repair] = []) {
        self.version = version; self.plans = plans; self.repairs = repairs
    }
}
