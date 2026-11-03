import Foundation

public struct VoiceLabAudioTag: Codable, Sendable, Equatable {
    public var beforeToken: Int
    public var tag: String
    public init(beforeToken: Int, tag: String) {
        self.beforeToken = beforeToken
        self.tag = tag
    }
}

public enum VoiceLabAudioTags {
    public struct Definition: Decodable, Sendable {
        public let tag: String
        public let seconds: Double
    }
    private struct Catalog: Decodable, Sendable {
        let models: [String]
        let tags: [Definition]
        let scribeEvents: [String]
    }
    private static let catalog: Catalog? = {
        guard let shared = try? SharedResources.locate(),
              let data = try? Data(contentsOf: shared.root.appendingPathComponent("data/voice-audio-tags.json")) else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }()
    public static var definitions: [Definition] { catalog?.tags ?? [] }
    public static func supports(_ modelID: String) -> Bool { catalog?.models.contains(modelID) == true }
    public static func validated(_ tags: [VoiceLabAudioTag], text: String) -> [VoiceLabAudioTag] {
        let count = EditingPrimitives.splitWords(text).count
        return tags.prefix(64).filter { annotation in
            (0...count).contains(annotation.beforeToken) && definitions.contains { $0.tag == annotation.tag }
        }.enumerated().sorted { left, right in
            left.element.beforeToken == right.element.beforeToken ? left.offset < right.offset : left.element.beforeToken < right.element.beforeToken
        }.map(\.element)
    }
    public static func parse(_ value: JSONValue, text: String) -> [VoiceLabAudioTag] {
        let tags = value.aiArray.compactMap { item -> VoiceLabAudioTag? in
            guard let boundary = item[ai: "beforeToken"].aiInt, item[ai: "beforeToken"].aiDouble == Double(boundary),
                  let tag = item[ai: "tag"].aiString else { return nil }
            return VoiceLabAudioTag(beforeToken: boundary, tag: tag)
        }
        return Array(validated(tags, text: text).prefix(max(1, (EditingPrimitives.splitWords(text).count + 7) / 8)))
    }
    public static func requestText(words: String, tags: [VoiceLabAudioTag], modelID: String) -> String {
        guard supports(modelID), !tags.isEmpty else { return strippingTags(words) }
        let tokens = EditingPrimitives.splitWords(strippingTags(words))
        let annotations = validated(tags, text: words)
        var result: [String] = []
        for boundary in 0...tokens.count {
            result += annotations.filter { $0.beforeToken == boundary }.map { "[\($0.tag)]" }
            if boundary < tokens.count { result.append(tokens[boundary]) }
        }
        return result.joined(separator: " ")
    }
    public static func allowance(_ tags: [VoiceLabAudioTag], text: String, modelID: String) -> Double {
        guard supports(modelID) else { return 0 }
        return validated(tags, text: text).reduce(0) { total, annotation in
            total + (definitions.first { $0.tag == annotation.tag }?.seconds ?? 0)
        }
    }
    public static func tagRanges(_ text: String) -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(pattern: #"\[[^\[\]\r\n]*\]"#) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let tag = String(text[range].dropFirst().dropLast())
            return definitions.contains { $0.tag == tag } ? range : nil
        }
    }
    public static func sanitizedRequest(_ text: String, modelID: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"\[[^\[\]\r\n]*\]"#) else { return text }
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let tag = String(text[range].dropFirst().dropLast())
            if !supports(modelID) || !definitions.contains(where: { $0.tag == tag }) { result.replaceSubrange(range, with: "") }
        }
        return result
    }
    public static func strippingTags(_ text: String) -> String {
        var result = text
        for range in tagRanges(text).reversed() { result.replaceSubrange(range, with: "") }
        return result
    }
    public static func isScribeEvent(_ text: String) -> Bool {
        catalog?.scribeEvents.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == true
    }
    public static func shifted(_ tags: [VoiceLabAudioTag], by offset: Int) -> [VoiceLabAudioTag] {
        tags.map { VoiceLabAudioTag(beforeToken: $0.beforeToken + offset, tag: $0.tag) }
    }
    public static func reanchored(_ tags: [VoiceLabAudioTag], from original: String, to edited: String) -> [VoiceLabAudioTag] {
        guard !tags.isEmpty else { return [] }
        if original == edited { return validated(tags, text: edited) }
        let tokens = EditingPrimitives.splitWords(original)
        let source = tokens.enumerated().map { index, text in
            TimedWord(id: String(index), text: text, start: Double(index), end: Double(index + 1))
        }
        guard let operations = try? VoiceLabWordDiff.diff(source: source, newText: edited).ops else { return [] }
        var boundaries = [Int](repeating: 0, count: tokens.count + 1)
        var oldIndex = 0, newIndex = 0
        for operation in operations {
            switch operation.kind {
            case .equal:
                boundaries[oldIndex] = newIndex
                oldIndex += 1; newIndex += 1
            case .delete:
                boundaries[oldIndex] = newIndex
                oldIndex += 1
            case .insert: newIndex += 1
            }
        }
        boundaries[tokens.count] = newIndex
        return validated(tags, text: original).map {
            VoiceLabAudioTag(beforeToken: boundaries[$0.beforeToken], tag: $0.tag)
        }
    }
}
