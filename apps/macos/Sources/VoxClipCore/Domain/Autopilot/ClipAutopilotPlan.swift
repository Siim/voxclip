import Foundation

/// One clip's complete "Make it postable" plan (ai.md §16): every decision Claude made, already checked against the
/// transcript, the caption styles and the bundled fonts (`ClipAutopilotValidator`). Word indices are transcript item
/// positions, as the clip finder's are (ai.md §11.2); every range is inclusive. Building, mapping and pricing a plan sends
/// nothing and changes no project.
public struct ClipAutopilotPlan: Codable, Sendable, Equatable {
    /// `version` of this contract. A reader accepts `readableVersions` and upgrades a version 1 plan to this one: no
    /// corrections, the original look, no speed change, no stated reasons, no length and no flags.
    public static let currentVersion = 2
    public static let readableVersions: ClosedRange<Int> = 1...2

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

    /// A misheard word spelled right in the transcript and captions (`EditCommand.correct`); the audio is unchanged.
    /// `heard` is the word as the transcript showed it, `text` its replacement.
    public struct Correction: Codable, Sendable, Equatable {
        public var word: Int
        public var heard: String
        public var text: String
        public var reason: String
        public init(word: Int, heard: String, text: String, reason: String) {
            self.word = word; self.heard = heard; self.text = text; self.reason = reason
        }
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
        /// Why this style suits the clip; empty in a version 1 plan.
        public var reason: String
        public init(styleId: String, font: Font, textCase: CaptionCase, wordsPerCaption: Int, reason: String = "") {
            self.styleId = styleId; self.font = font; self.textCase = textCase; self.wordsPerCaption = wordsPerCaption; self.reason = reason
        }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(styleId: try values.decode(String.self, forKey: .styleId), font: try values.decode(Font.self, forKey: .font),
                      textCase: try values.decode(CaptionCase.self, forKey: .textCase), wordsPerCaption: try values.decode(Int.self, forKey: .wordsPerCaption),
                      reason: try values.decodeIfPresent(String.self, forKey: .reason) ?? "")
        }
        private enum CodingKeys: String, CodingKey { case styleId, font, textCase = "case", wordsPerCaption, reason }
    }

    /// The colour look of the clip (ai.md §16.2): the renderer's `ClipLook` (design.md §6.8).
    public typealias LookID = ClipLook

    public struct Look: Codable, Sendable, Equatable {
        public var id: LookID
        public var reason: String
        public init(id: LookID, reason: String = "") { self.id = id; self.reason = reason }
        public static let original = Look(id: .original)
    }

    /// The whole clip played at `rate` (between the prompt file's `minSpeed` and `maxSpeed`, never 1); applied with
    /// `ClipControlsProject` (design.md §6.8).
    public struct Speed: Codable, Sendable, Equatable {
        public var rate: Double
        public var reason: String
        public init(rate: Double, reason: String) { self.rate = rate; self.reason = reason }
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

    /// Something the review should show next to the plan; the plan itself is kept as it is (ai.md §16.5).
    public struct Flag: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable, CaseIterable {
            /// Longer than the target (`maxTargetSeconds`, 45 s) with no `lengthReason`.
            case longWithoutReason
            /// Longer than `maxReasonedSeconds` (60 s), with or without a reason.
            case overLength
        }
        public var kind: Kind
        public var detail: String
        public init(kind: Kind, detail: String) { self.kind = kind; self.detail = detail }
    }

    public var version: Int
    public var startWord: Int
    public var endWord: Int
    public var title: String
    /// On-screen text for the first 2 s.
    public var hook: String
    public var cuts: [Cut]
    public var pauseCuts: [PauseCut]
    /// Applied before every other edit, so rewrites and captions read the corrected words.
    public var corrections: [Correction]
    public var rewrites: [Rewrite]
    public var captions: Captions
    public var look: Look
    /// Nil plays the clip at its own speed.
    public var speed: Speed?
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
    /// Why the clip runs past the target length; empty when it does not.
    public var lengthReason: String
    /// The clip's length once the plan's cuts, pause cuts and speed apply, measured when the plan was checked
    /// (`ClipAutopilotMapping.finalSeconds`). Zero in a version 1 plan.
    public var seconds: Double
    public var questions: [Question]
    public var repairs: [Repair]
    public var flags: [Flag]

    public init(version: Int = ClipAutopilotPlan.currentVersion, startWord: Int, endWord: Int, title: String, hook: String,
                cuts: [Cut] = [], pauseCuts: [PauseCut] = [], corrections: [Correction] = [], rewrites: [Rewrite] = [], captions: Captions,
                look: Look = .original, speed: Speed? = nil, music: [Music] = [], musicPick: Int? = nil, zooms: [Zoom] = [], postText: String,
                score: Int, verdict: Verdict, scoreReason: String = "", lengthReason: String = "", seconds: Double = 0,
                questions: [Question] = [], repairs: [Repair] = [], flags: [Flag] = []) {
        self.version = version; self.startWord = startWord; self.endWord = endWord; self.title = title; self.hook = hook
        self.cuts = cuts; self.pauseCuts = pauseCuts; self.corrections = corrections; self.rewrites = rewrites; self.captions = captions
        self.look = look; self.speed = speed; self.music = music; self.musicPick = musicPick; self.zooms = zooms; self.postText = postText
        self.score = score; self.verdict = verdict; self.scoreReason = scoreReason; self.lengthReason = lengthReason; self.seconds = seconds
        self.questions = questions; self.repairs = repairs; self.flags = flags
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard Self.readableVersions.contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unknown plan version")
        }
        self.init(startWord: try values.decode(Int.self, forKey: .startWord), endWord: try values.decode(Int.self, forKey: .endWord),
                  title: try values.decode(String.self, forKey: .title), hook: try values.decode(String.self, forKey: .hook),
                  cuts: try values.decode([Cut].self, forKey: .cuts), pauseCuts: try values.decode([PauseCut].self, forKey: .pauseCuts),
                  corrections: try values.decodeIfPresent([Correction].self, forKey: .corrections) ?? [],
                  rewrites: try values.decode([Rewrite].self, forKey: .rewrites), captions: try values.decode(Captions.self, forKey: .captions),
                  look: try values.decodeIfPresent(Look.self, forKey: .look) ?? .original,
                  speed: try values.decodeIfPresent(Speed.self, forKey: .speed),
                  music: try values.decode([Music].self, forKey: .music), musicPick: try values.decodeIfPresent(Int.self, forKey: .musicPick),
                  zooms: try values.decode([Zoom].self, forKey: .zooms), postText: try values.decode(String.self, forKey: .postText),
                  score: try values.decode(Int.self, forKey: .score), verdict: try values.decode(Verdict.self, forKey: .verdict),
                  scoreReason: try values.decode(String.self, forKey: .scoreReason),
                  lengthReason: try values.decodeIfPresent(String.self, forKey: .lengthReason) ?? "",
                  seconds: try values.decodeIfPresent(Double.self, forKey: .seconds) ?? 0,
                  questions: try values.decode([Question].self, forKey: .questions),
                  repairs: try values.decodeIfPresent([Repair].self, forKey: .repairs) ?? [],
                  flags: try values.decodeIfPresent([Flag].self, forKey: .flags) ?? [])
    }

    private enum CodingKeys: String, CodingKey {
        case version, startWord, endWord, title, hook, cuts, pauseCuts, corrections, rewrites, captions, look, speed, music, musicPick, zooms,
             postText, score, verdict, scoreReason, lengthReason, seconds, questions, repairs, flags
    }

    /// The picked music, when there is one.
    public var pickedMusic: Music? { musicPick.flatMap { music.indices.contains($0) ? music[$0] : nil } }
}

/// A moment the first stage of a series picked (ai.md §16.3): a span worth a clip, with its score and the caption style
/// chosen for it across the series. The second stage plans each one at extra high effort.
public struct ClipAutopilotMoment: Codable, Sendable, Equatable {
    public var startWord: Int
    public var endWord: Int
    public var title: String
    /// The one idea and why it hooks, in a sentence; it briefs the second stage.
    public var idea: String
    public var score: Int
    public var verdict: ClipAutopilotPlan.Verdict
    public var scoreReason: String
    /// A built-in style id, never `off`; the creator's fixed style when there is one.
    public var captionStyle: String
    public var captionReason: String
    public init(startWord: Int, endWord: Int, title: String, idea: String, score: Int, verdict: ClipAutopilotPlan.Verdict,
                scoreReason: String = "", captionStyle: String, captionReason: String = "") {
        self.startWord = startWord; self.endWord = endWord; self.title = title; self.idea = idea; self.score = score
        self.verdict = verdict; self.scoreReason = scoreReason; self.captionStyle = captionStyle; self.captionReason = captionReason
    }
}

/// A whole video made into a series: its clips ranked best first, each with its own plan, never overlapping.
public struct ClipAutopilotSeries: Codable, Sendable, Equatable {
    public var version: Int
    public var plans: [ClipAutopilotPlan]
    /// The first stage's picks in its rank order; empty for a clip request.
    public var moments: [ClipAutopilotMoment]
    /// Moments and clips left out (overlap, length, an unreadable span, a plan that failed).
    public var repairs: [ClipAutopilotPlan.Repair]
    public init(version: Int = ClipAutopilotPlan.currentVersion, plans: [ClipAutopilotPlan], moments: [ClipAutopilotMoment] = [],
                repairs: [ClipAutopilotPlan.Repair] = []) {
        self.version = version; self.plans = plans; self.moments = moments; self.repairs = repairs
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard ClipAutopilotPlan.readableVersions.contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unknown series version")
        }
        self.init(plans: try values.decode([ClipAutopilotPlan].self, forKey: .plans),
                  moments: try values.decodeIfPresent([ClipAutopilotMoment].self, forKey: .moments) ?? [],
                  repairs: try values.decodeIfPresent([ClipAutopilotPlan.Repair].self, forKey: .repairs) ?? [])
    }
    private enum CodingKeys: String, CodingKey { case version, plans, moments, repairs }
}
