import Foundation

public struct ClipPlanEffect: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case zoom, punchIn, motionTitle, lowerThird, emojiPop, motionTemplate, soundEffect, illustration, colourLook, speedForPart
        case bRoll, screenshot, videoStack

        var payloadKey: String {
            switch self {
            case .zoom, .punchIn: "scale"
            case .motionTitle, .lowerThird, .emojiPop: "text"
            case .motionTemplate: "template"
            case .soundEffect: "query"
            case .illustration: "prompt"
            case .colourLook: "look"
            case .speedForPart: "rate"
            case .bRoll, .screenshot, .videoStack: "footage"
            }
        }
    }

    public static let maximumEntries = 12
    public let kind: Kind
    public let startWord: Int
    public let endWord: Int
    public let reason: String
    public let scale: Double?
    public let text: String?
    public let query: String?
    public let prompt: String?
    public let look: ClipLook?
    public let rate: Double?
    public let template: MotionTemplate?
    public let footage: ClipFootage.Selection?

    private init(kind: Kind, startWord: Int, endWord: Int, reason: String, value: JSONValue, template: MotionTemplate?) {
        self.kind = kind; self.startWord = startWord; self.endWord = endWord; self.reason = reason
        scale = value[ai: "scale"].aiDouble; text = value[ai: "text"].aiString
        query = value[ai: "query"].aiString; prompt = value[ai: "prompt"].aiString
        look = value[ai: "look"].aiString.flatMap(ClipLook.init(rawValue:)); rate = value[ai: "rate"].aiDouble
        self.template = template
        footage = ClipFootage.Selection.read(value[ai: "footage"])
    }

    public init(from decoder: any Decoder) throws {
        let raw = try JSONValue(from: decoder)
        guard let entry = Self.read(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid clip-plan effect"))
        }
        self = entry
    }

    public static func read(_ value: JSONValue) -> Self? {
        guard let fields = value.aiObject, let kind = value[ai: "kind"].aiString.flatMap(Kind.init(rawValue:)),
              Set(fields.keys) == ["kind", "startWord", "endWord", "reason", kind.payloadKey],
              let start = value[ai: "startWord"].aiInt, let end = value[ai: "endWord"].aiInt, start >= 0, end >= start,
              let reason = line(value[ai: "reason"], limit: 240) else { return nil }
        let payload = value[ai: kind.payloadKey]
        let template = kind == .motionTemplate ? MotionTemplate.read(payload) : nil
        let valid = switch kind {
        case .zoom, .punchIn: payload.aiDouble.map { (1.05...MotionCue.maximumScale).contains($0) } == true
        case .motionTitle, .lowerThird: line(payload, limit: ClipEffect.maximumTitleScalars) != nil
        case .emojiPop: line(payload, limit: ClipEffect.maximumStickerScalars) != nil
        case .motionTemplate: template != nil
        case .soundEffect: line(payload, limit: 120) != nil
        case .illustration: line(payload, limit: 500) != nil
        case .colourLook: payload.aiString.flatMap(ClipLook.init(rawValue:)) != nil
        case .speedForPart: payload.aiDouble.map { (0.5...2).contains($0) } == true
        case .bRoll, .screenshot, .videoStack: ClipFootage.Selection.read(payload) != nil
        }
        return valid ? Self(kind: kind, startWord: start, endWord: end, reason: reason, value: value, template: template) : nil
    }

    static func providerEntry(_ value: JSONValue) -> Self? {
        guard let kind = value[ai: "kind"].aiString.flatMap(Kind.init(rawValue:)) else { return nil }
        let keys = ["kind", "startWord", "endWord", "reason", kind.payloadKey]
        var fields = Dictionary(uniqueKeysWithValues: keys.map { ($0, value[ai: $0]) })
        if kind == .motionTemplate, let template = fields["template"]?.aiObject {
            let used = template["name"]?.aiString == "counter" ? ["name", "from", "to"] : ["name", "text"]
            fields["template"] = .object(template.filter { used.contains($0.key) })
        }
        return read(.object(fields))
    }

    private static func line(_ value: JSONValue, limit: Int) -> String? {
        guard let text = value.aiString, !text.isEmpty, text.unicodeScalars.count <= limit,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.unicodeScalars.contains(where: { [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }) else { return nil }
        return text
    }

    public func operation(id: String, clipID: String, scope: ClosedRange<Int>, anchor: (Int) -> Range<Double>?,
                          isCut: (Int) -> Bool = { _ in false }, stickers: Set<String>,
                          sources: [String: Double] = [:]) -> ClipAutopilotOperation? {
        guard scope.contains(startWord), scope.contains(endWord),
              let first = anchor(startWord), let last = anchor(endWord),
              !(startWord...endWord).contains(where: isCut) else { return nil }
        let duration = last.upperBound - first.lowerBound
        guard first.lowerBound.isFinite, last.upperBound.isFinite, first.lowerBound >= 0,
              (0.1...(footage == nil ? 5 : 60)).contains(duration) else { return nil }
        switch kind {
        case .zoom, .punchIn:
            guard let scale else { return nil }
            let frames: [MotionKeyframe] = kind == .zoom
                ? [.init(progress: 0), .init(progress: 0.28, scale: scale), .init(progress: 0.7, scale: scale), .init(progress: 1)]
                : [.init(progress: 0, scale: scale), .init(progress: 1, scale: scale)]
            let cue = MotionCue(id: id, clipID: clipID, sourceStart: first.lowerBound, sourceEnd: last.upperBound, keyframes: frames)
            return .init(id: id, decision: .zoom, action: .motion(cue), reason: reason)
        case .motionTitle, .lowerThird, .emojiPop:
            guard let text, kind != .emojiPop || stickers.contains(text) else { return nil }
            let overlay: ClipEffect.Kind = kind == .motionTitle ? .title : kind == .lowerThird ? .lowerThird : .sticker
            let position: ClipEffect.Position = kind == .motionTitle ? .top : kind == .lowerThird ? .bottom : .topRight
            let effect = ClipEffect(id: id, clipId: clipID, kind: overlay, start: first.lowerBound, end: last.upperBound,
                                    text: text, position: position, scale: kind == .emojiPop ? 1 : nil,
                                    animation: kind == .emojiPop ? .pop : .rise)
            return .init(id: id, decision: .overlay, action: .effect(effect), reason: reason)
        case .motionTemplate:
            guard let template else { return nil }
            let effect = ClipEffect(id: id, clipId: clipID, kind: .motionTemplate, start: first.lowerBound, end: last.upperBound,
                                    template: template)
            return .init(id: id, decision: .overlay, action: .effect(effect), reason: reason)
        case .bRoll, .screenshot, .videoStack:
            guard let footage, let kind = ClipFootage.Kind(rawValue: kind.rawValue), let length = sources[footage.sourceKey] else { return nil }
            let entry = ClipFootage(id: id, clipID: clipID, kind: kind, start: first.lowerBound, end: last.upperBound, footage: footage)
            guard entry.fits(duration: length) else { return nil }
            return .init(id: id, decision: .overlay, action: .footage(entry), reason: reason)
        case .colourLook, .speedForPart:
            let effect = ClipEffect(id: id, clipId: clipID, kind: kind == .colourLook ? .colourLook : .speedForPart,
                                    start: first.lowerBound, end: last.upperBound, look: look, rate: rate)
            return .init(id: id, decision: kind == .colourLook ? .look : .stretch, action: .effect(effect), reason: reason)
        case .soundEffect, .illustration:
            guard let text = query ?? prompt else { return nil }
            let asset = ClipPlanAsset(id: id, kind: kind == .soundEffect ? .sound : .illustration, clipID: clipID,
                                     start: first.lowerBound, end: last.upperBound, text: text)
            return .init(id: id, decision: kind == .soundEffect ? .sound : .overlay, action: .asset(asset), reason: reason)
        }
    }

    func operation(id: String, clipID: String, scope: ClosedRange<Int>, words: [TimedWord], cut: Set<String>,
                   tightenedAfter: Set<Int>, stickers: Set<String>, sources: [String: Double] = [:]) -> ClipAutopilotOperation? {
        guard startWord <= endWord, startWord >= 0, endWord < words.count,
              !tightenedAfter.contains(where: { startWord <= $0 && $0 < endWord }) else { return nil }
        return operation(id: id, clipID: clipID, scope: scope, anchor: { index in
            let word = words[index]
            guard word.kind == .word, word.start.isFinite, word.end.isFinite, word.end > word.start else { return nil }
            return word.start..<word.end
        }, isCut: { cut.contains(words[$0].id) }, stickers: stickers, sources: sources)
    }
}

public struct ClipPlanAsset: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case sound, illustration }
    public let id: String
    public let kind: Kind
    public let clipID: String
    public let start: Double
    public let end: Double
    public let text: String
}
