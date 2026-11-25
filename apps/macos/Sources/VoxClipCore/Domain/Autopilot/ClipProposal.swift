import Foundation

public struct ClipProposal: Codable, Sendable, Equatable {
    public struct Part: Codable, Sendable, Equatable {
        public var startWord: Int
        public var endWord: Int
        public init(startWord: Int, endWord: Int) { self.startWord = startWord; self.endWord = endWord }
    }

    public struct NewClip: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case stretch, story, showreel }
        public var kind: Kind
        public var title: String
        public init(kind: Kind, title: String) { self.kind = kind; self.title = title }
    }

    public struct Target: Codable, Sendable, Equatable {
        public let clipId: String?
        public let new: NewClip?
        public init(clipId: String) { self.clipId = clipId; new = nil }
        public init(new: NewClip) { clipId = nil; self.new = new }
    }

    public struct Music: Codable, Sendable, Equatable {
        public let trackId: String?
        public let brief: String?
        public init(trackId: String) { self.trackId = trackId; brief = nil }
        public init(brief: String) { trackId = nil; self.brief = brief }
    }

    public var target: Target
    public var reason: String
    public var parts: [Part]?
    public var cuts: [ClipAutopilotPlan.Cut]?
    public var pauseCuts: [ClipAutopilotPlan.PauseCut]?
    public var corrections: [ClipAutopilotPlan.Correction]?
    public var captionStyle: String?
    public var font: ClipAutopilotPlan.Font?
    public var textCase: ClipAutopilotPlan.CaptionCase?
    public var wordsPerCaption: Int?
    public var look: ClipAutopilotPlan.Look?
    public var speed: ClipAutopilotPlan.Speed?
    public var hook: String?
    public var title: String?
    public var postText: String?
    public var coverTitle: String?
    public var music: Music?
    public var effects: [ClipPlanEffect]?
    public var rewrites: [ClipAutopilotPlan.Rewrite]?

    public init(target: Target, reason: String) { self.target = target; self.reason = reason }

    private enum CodingKeys: String, CodingKey {
        case target, reason, parts, cuts, pauseCuts, corrections, captionStyle, font, textCase = "case", wordsPerCaption
        case look, speed, hook, title, postText, coverTitle, music, effects, rewrites
    }
}

extension ClipAutopilotPlan {
    public func canonicalProposal(clipID: String, in project: Project) -> ClipProposal {
        let existing = project.edits.clips.first { $0.id == clipID }
        let target: ClipProposal.Target = existing != nil ? .init(clipId: clipID) : .init(new: .init(kind: .stretch, title: title))
        var proposal = ClipProposal(target: target, reason: "")
        if existing?.parts == nil { proposal.parts = [.init(startWord: startWord, endWord: endWord)] }
        proposal.cuts = cuts; proposal.pauseCuts = pauseCuts; proposal.corrections = corrections; proposal.rewrites = rewrites
        proposal.captionStyle = captions.styleId; proposal.font = captions.font
        proposal.textCase = captions.textCase; proposal.wordsPerCaption = captions.wordsPerCaption
        proposal.look = look; proposal.speed = speed; proposal.effects = effects
        proposal.hook = hook; proposal.title = title; proposal.postText = postText; proposal.coverTitle = frames?.cover?.title
        proposal.music = pickedMusic.map { .init(brief: $0.prompt) }
        return proposal
    }
}
