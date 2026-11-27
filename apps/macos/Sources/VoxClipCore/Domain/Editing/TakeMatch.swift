public enum TakeMatch {
    public struct Result: Codable, Equatable, Sendable {
        public let beats: [Beat]
    }

    public struct Beat: Codable, Equatable, Sendable {
        public let id: String
        public let takes: [Take]
    }

    public struct Take: Codable, Equatable, Sendable {
        public let key: String
        public let startWordId: String
        public let endWordId: String
    }

    private struct Token {
        let text: String
        let position: Int
    }

    private struct Sentence {
        let recording: Int
        let words: [TimedWord]
        let tokens: [Token]
        let previous: Int?
    }

    static let minimumSimilarity = 0.6
    static let minimumWordRatio = 0.5
    static let maximumWordRatio = 2.0

    public static func build(_ recordings: [(key: String, words: [TimedWord])]) -> Result {
        var sentences: [Sentence] = []
        var ranges: [Range<Int>] = []
        for (recording, input) in recordings.enumerated() {
            let firstSentence = sentences.count
            var firstWord = 0
            for position in input.words.indices {
                let word = input.words[position]
                let next = position + 1
                let gap = next < input.words.count ? input.words[next].start - word.end : 0
                guard next == input.words.count ||
                    TranscriptLineBoundary.endsLine(word.text, gap: gap, wordCount: next - firstWord) else { continue }
                let words = Array(input.words[firstWord...position])
                let tokens = words.enumerated().compactMap { offset, word -> Token? in
                    guard word.kind == .word, !EditingPrimitives.filler(word.text) else { return nil }
                    let text = EditingPrimitives.normalizeForMatch(EditingPrimitives.nfc(word.text))
                    return text.isEmpty ? nil : Token(text: text, position: offset)
                }
                let previous = sentences.count > firstSentence ? sentences.count - 1 : nil
                sentences.append(Sentence(recording: recording, words: words, tokens: tokens, previous: previous))
                firstWord = next
            }
            ranges.append(firstSentence..<sentences.count)
        }

        var groups = Groups(sentences: sentences)
        for first in ranges.indices {
            for second in ranges.indices.dropFirst(first + 1) {
                var next = ranges[second].lowerBound
                for left in ranges[first] {
                    for right in next..<ranges[second].upperBound where matches(sentences[left], sentences[right]) {
                        guard groups.join(left, right) else { continue }
                        next = right + 1
                        break
                    }
                }
            }
        }
        let beats = groups.inOrder().enumerated().map { index, members in
            Beat(id: "beat\(index + 1)", takes: members.map { member in
                let sentence = sentences[member]
                return Take(key: recordings[sentence.recording].key,
                            startWordId: sentence.words[0].id, endWordId: sentence.words[sentence.words.count - 1].id)
            })
        }
        return Result(beats: beats)
    }

    private static func matches(_ left: Sentence, _ right: Sentence) -> Bool {
        let shorter = min(left.tokens.count, right.tokens.count)
        guard shorter > 0 else { return false }
        let ratio = Double(left.tokens.count) / Double(right.tokens.count)
        guard ratio >= minimumWordRatio, ratio <= maximumWordRatio else { return false }
        if left.tokens.map(\.text) == right.tokens.map(\.text) { return true }
        let common = Set(left.tokens.map(\.text)).intersection(right.tokens.map(\.text))
        guard Double(left.tokens.count(where: { common.contains($0.text) })) >= minimumSimilarity * Double(shorter),
              Double(right.tokens.count(where: { common.contains($0.text) })) >= minimumSimilarity * Double(shorter) else { return false }
        return Double(lcs(left.tokens, right.tokens)[0]) / Double(shorter) >= minimumSimilarity
    }

    private static func lcs(_ left: [Token], _ right: [Token]) -> [Int] {
        let width = right.count + 1
        var lengths = [Int](repeating: 0, count: (left.count + 1) * width)
        for row in left.indices.reversed() {
            for column in right.indices.reversed() {
                let index = row * width + column
                lengths[index] = left[row].text == right[column].text
                    ? 1 + lengths[index + width + 1] : max(lengths[index + width], lengths[index + 1])
            }
        }
        return lengths
    }

    private struct Groups {
        let sentences: [Sentence]
        var owner: [Int]
        var members: [[Int]]

        init(sentences: [Sentence]) {
            self.sentences = sentences
            owner = Array(sentences.indices)
            members = sentences.indices.map { [$0] }
        }

        func predecessors(_ group: Int) -> [Int] {
            members[group].compactMap { member in sentences[member].previous.map { owner[$0] } }
        }

        func precedes(_ target: Int, _ group: Int) -> Bool {
            var pending = predecessors(group)
            var seen: Set<Int> = []
            while let previous = pending.popLast() {
                if previous == target { return true }
                if seen.insert(previous).inserted { pending.append(contentsOf: predecessors(previous)) }
            }
            return false
        }

        mutating func join(_ left: Int, _ right: Int) -> Bool {
            let first = min(owner[left], owner[right])
            let second = max(owner[left], owner[right])
            if first == second { return true }
            let recordings = Set(members[first].map { sentences[$0].recording })
            guard members[second].allSatisfy({ !recordings.contains(sentences[$0].recording) }),
                  !precedes(first, second), !precedes(second, first) else { return false }
            let moved = members[second]
            for sentence in moved { owner[sentence] = first }
            members[first] = (members[first] + moved).sorted()
            members[second] = []
            return true
        }

        func inOrder() -> [[Int]] {
            var emitted: Set<Int> = []
            var order: [[Int]] = []
            for group in members.indices where !members[group].isEmpty {
                var pending = [(group, false)]
                while let (current, ready) = pending.popLast() {
                    if emitted.contains(current) { continue }
                    if ready {
                        emitted.insert(current)
                        order.append(members[current])
                    } else {
                        pending.append((current, true))
                        pending.append(contentsOf: predecessors(current).reversed().map { ($0, false) })
                    }
                }
            }
            return order
        }
    }
}
