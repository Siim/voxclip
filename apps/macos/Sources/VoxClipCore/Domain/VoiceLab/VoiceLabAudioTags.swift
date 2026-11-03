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
    private static let scribeEvents = Set((catalog?.scribeEvents ?? []).map { EditingPrimitives.normalizeForMatch(EditingPrimitives.nfc($0)) })
    public static var definitions: [Definition] { catalog?.tags ?? [] }
    public static func supports(_ modelID: String) -> Bool { catalog?.models.contains(modelID) == true }
    /// The tags an accepted segment records: only those its model spoke, so a Multilingual v2 take saves none.
    public static func recorded(_ tags: [VoiceLabAudioTag], modelID: String) -> [VoiceLabAudioTag]? {
        tags.isEmpty || !supports(modelID) ? nil : tags
    }
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
        let normalized = EditingPrimitives.normalizeForMatch(EditingPrimitives.nfc(text))
        return scribeEvents.contains(normalized)
    }
    public static func filterScribeEvents(recognized: [String], expected: [String], hasTags: Bool) -> [String] {
        let tokens = recognized.flatMap { $0.split(whereSeparator: \.isWhitespace) }
            .map { EditingPrimitives.normalizeForMatch(EditingPrimitives.nfc(String($0))) }.filter { !$0.isEmpty }
        guard hasTags else { return tokens }
        let expectedCounts = Dictionary(expected.map { ($0, 1) }, uniquingKeysWith: +)
        var extras = Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +)
        for (token, count) in expectedCounts { extras[token, default: 0] -= count }
        var matched: Set<Int> = []
        if tokens.count <= 5_000, expected.count <= 5_000,
           extras.contains(where: { $0.value > 0 && expectedCounts[$0.key, default: 0] > 0 && isScribeEvent($0.key) }) {
            let width = tokens.count + 1
            var lengths = [UInt16](repeating: 0, count: (expected.count + 1) * width)
            for expectedIndex in expected.indices.reversed() {
                for recognizedIndex in tokens.indices.reversed() {
                    let cell = expectedIndex * width + recognizedIndex
                    lengths[cell] = expected[expectedIndex] == tokens[recognizedIndex]
                        ? lengths[cell + width + 1] + 1 : max(lengths[cell + width], lengths[cell + 1])
                }
            }
            var expectedIndex = 0, recognizedIndex = 0
            while expectedIndex < expected.count && recognizedIndex < tokens.count {
                if expected[expectedIndex] == tokens[recognizedIndex] {
                    matched.insert(recognizedIndex)
                    expectedIndex += 1; recognizedIndex += 1
                } else if lengths[(expectedIndex + 1) * width + recognizedIndex] >= lengths[expectedIndex * width + recognizedIndex + 1] {
                    expectedIndex += 1
                } else { recognizedIndex += 1 }
            }
        }
        return tokens.enumerated().filter { index, token in
            guard !matched.contains(index), isScribeEvent(token), extras[token, default: 0] > 0 else { return true }
            extras[token, default: 0] -= 1
            return false
        }.map(\.element)
    }
    public static func edgeExtent(words: [VoiceLabWord], samples: [Float], sampleRate: Int,
                                  tags: [VoiceLabAudioTag], tokenCount: Int, modelID: String,
                                  characters: [VoiceLabCharacterTiming]) -> [VoiceLabWord] {
        guard supports(modelID), !words.isEmpty, sampleRate > 0, !samples.isEmpty else { return words }
        let assetEnd = VoiceLabTakeProcessing.lastAlignedTime(frames: samples.count, rate: sampleRate)
        let text = characters.map(\.character).joined()
        let ranges = tagRanges(text)
        var result = words
        for incoming in [true, false] {
            let edgeTags = tags.filter { annotation in
                annotation.beforeToken == (incoming ? 0 : tokenCount) && definitions.contains { $0.tag == annotation.tag }
            }
            guard !edgeTags.isEmpty else { continue }
            let index = incoming ? 0 : words.count - 1
            var missing: [VoiceLabAudioTag] = []
            var used: Set<Int> = []
            for annotation in edgeTags {
                let match = ranges.indices.first { rangeIndex in
                    let range = ranges[rangeIndex]
                    return !used.contains(rangeIndex) && String(text[range].dropFirst().dropLast()) == annotation.tag &&
                        EditingPrimitives.splitWords(strippingTags(String(text[..<range.lowerBound]))).count == annotation.beforeToken
                }
                guard let match else { missing.append(annotation); continue }
                used.insert(match)
                let range = ranges[match]
                let lower = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.lowerBound)
                let upper = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.upperBound)
                var offset = 0
                for timing in characters {
                    let count = timing.character.unicodeScalars.count
                    let start = max(lower, offset), end = min(upper, offset + count)
                    if end > start, count > 0 {
                        let step = (timing.end - timing.start) / Double(count)
                        if incoming {
                            result[index].start = max(0, min(result[index].start, timing.start + step * Double(start - offset)))
                        } else {
                            result[index].end = min(assetEnd, max(result[index].end, timing.start + step * Double(end - offset)))
                        }
                    }
                    offset += count
                }
            }
            if !missing.isEmpty {
                let allowance = edgeTags.reduce(0.0) { total, annotation in total + (definitions.first { $0.tag == annotation.tag }?.seconds ?? 0) }
                let refined = VoiceLabHardJoin.refine(words: words, samples: samples, sampleRate: sampleRate,
                    incoming: incoming, outgoing: !incoming, searchSeconds: VoiceLabHardJoin.acousticSearchSeconds + allowance)
                if incoming { result[index].start = max(0, min(result[index].start, refined[index].start)) }
                else { result[index].end = min(assetEnd, max(result[index].end, refined[index].end)) }
            }
        }
        return result
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
