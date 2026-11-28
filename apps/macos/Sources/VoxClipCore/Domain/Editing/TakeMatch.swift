public enum TakeMatch {
    public struct Result: Codable, Equatable, Sendable {
        public let beats: [Beat]
        public let solo: [SoloRun]
    }

    public struct Beat: Codable, Equatable, Sendable {
        public let id: String
        public let takes: [Take]
        public let spans: [AlignedSpan]
    }

    public struct Take: Codable, Equatable, Sendable {
        public let key: String
        public let startWordId: String
        public let endWordId: String
        public let flags: [String]
        public let signals: DeliverySignals
    }

    public struct AlignedSpan: Codable, Equatable, Sendable {
        public let fromKey: String
        public let toKey: String
        public let startWordId: String
        public let endWordId: String
        public let changedWordIds: [String]
    }

    public struct SoloRun: Codable, Equatable, Sendable {
        public let key: String
        public let startWordId: String
        public let endWordId: String
        public let sentenceCount: Int
        public let afterBeatId: String?
        public let beforeBeatId: String?
    }

    public struct DeliverySignals: Codable, Equatable, Sendable {
        public let fillers: Int
        public let longestPause: Double
        public let restarts: Int
        public let wordsPerMinute: Double
        public let meanConfidence: Double?
        public let cutOff: Bool
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
        let cutOff: Bool
    }

    static let minimumSimilarity = 0.6
    static let minimumWordRatio = 0.5
    static let maximumWordRatio = 2.0
    static let clauseBreaks = ",，、-–—.。"
    static let maxRestartWords = 8
    static let restartMajority = 0.5
    static let falseStartSeconds = 10.0
    static let restartRunSeconds = 3.0
    static let minRestartRunWords = 2
    static let isolatedTailGapWords = 2
    static let restartPhrases = [
        "en": ["sorry where was i", "let me start again", "one more time"],
        "et": ["vabandust kus ma olin", "alustan uuesti", "üks kord veel"],
        "de": ["sorry wo war ich", "ich fange noch mal an", "noch einmal"],
    ]
    private static let restartTokens: [[String]] = restartPhrases.values.joined().map { phrase in
        phrase.split(separator: " ").map { String($0) }
    }

    public static func build(clock: ProjectClock) -> Result {
        guard clock.regions.count > 1 else { return build([(clock.regions[0].key, clock.words)]) }
        let byRegion = Dictionary(grouping: clock.words) { clock.region(of: $0.id)?.key }
        return build(clock.regions.map { region in
            let words = (byRegion[region.key] ?? []).map { word in
                guard region.offsetSamples != 0 else { return word }
                let rate = Double(clock.sampleRate)
                var local = word
                local.start = (EditingPrimitives.jsRound(word.start * rate) - Double(region.offsetSamples)) / rate
                local.end = (EditingPrimitives.jsRound(word.end * rate) - Double(region.offsetSamples)) / rate
                return local
            }
            return (region.key, words)
        })
    }

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
                    guard word.kind == .word, !isFiller(word) else { return nil }
                    let text = EditingPrimitives.normalizeForMatch(EditingPrimitives.nfc(word.text))
                    return text.isEmpty ? nil : Token(text: text, position: offset)
                }
                let previous = sentences.count > firstSentence ? sentences.count - 1 : nil
                sentences.append(Sentence(recording: recording, words: words, tokens: tokens, previous: previous,
                                          cutOff: firstWord == 0 || next == input.words.count))
                firstWord = next
            }
            ranges.append(firstSentence..<sentences.count)
        }

        var groups = Groups(sentences: sentences)
        for first in ranges.indices {
            for second in ranges.indices.dropFirst(first + 1) {
                var next = ranges[second].lowerBound
                for left in ranges[first] {
                    for right in next..<ranges[second].upperBound {
                        guard groups.join(left, right) else { continue }
                        next = right + 1
                        break
                    }
                }
            }
        }
        let takes = sentences.enumerated().map { index, sentence in
            let next = index + 1 < sentences.count && sentences[index + 1].recording == sentence.recording ? sentences[index + 1] : nil
            return makeTake(key: recordings[sentence.recording].key, sentence: sentence, next: next)
        }
        var matchedIds = [String?](repeating: nil, count: sentences.count)
        let beats = groups.inOrder().enumerated().map { index, members in
            let id = "beat\(index + 1)"
            if members.count > 1 {
                for member in members { matchedIds[member] = id }
            }
            var spans: [AlignedSpan] = []
            for source in members {
                for target in members where source != target {
                    spans.append(align(fromKey: takes[source].key, source: sentences[source],
                                       toKey: takes[target].key, target: sentences[target]))
                }
            }
            return Beat(id: id, takes: members.map { takes[$0] }, spans: spans)
        }
        return Result(beats: beats, solo: soloRuns(ranges, takes: takes, matchedIds: matchedIds))
    }

    private static func isFiller(_ word: TimedWord) -> Bool {
        word.kind == .unlabeledSpeech || (word.kind == .word && EditingPrimitives.filler(word.text))
    }

    private static func makeTake(key: String, sentence: Sentence, next: Sentence?) -> Take {
        let words = sentence.words
        let last = words[words.count - 1]
        let spoken = words.filter { $0.kind != .event }
        let fillers = spoken.count(where: isFiller)
        let tokens = sentence.tokens
        let lexical = tokens.map(\.text)
        var flags: [String] = []
        if !spoken.isEmpty, spoken.count <= maxRestartWords,
           Double(fillers + lexical.count - Set(lexical).count) > Double(spoken.count) * restartMajority || hasRestartPhrase(lexical) {
            flags.append("restart")
        }
        if let next, !lexical.isEmpty, next.words[0].start - last.end <= falseStartSeconds,
           Double(lcs(tokens, Array(next.tokens.prefix(lexical.count)))[0]) / Double(lexical.count) >= minimumSimilarity {
            flags.append("falseStart")
        }
        if sentence.cutOff { flags.append("cutOff") }

        let pause = zip(spoken, spoken.dropFirst()).reduce(0.0) { max($0, $1.1.start - $1.0.end) }
        var restarts = 0
        var runLength = 1
        for (previous, current) in zip(tokens, tokens.dropFirst()) {
            runLength = current.text == previous.text && words[current.position].end - words[previous.position].start <= restartRunSeconds
                ? runLength + 1 : 1
            if runLength == minRestartRunWords { restarts += 1 }
        }
        let duration = last.end - words[0].start
        let transcribed = spoken.filter { $0.kind == .word }
        let rate = duration > 0 ? 60 * Double(transcribed.count) / duration : 0
        let confidence = transcribed.compactMap(\.conf)
        let mean = confidence.isEmpty ? nil : confidence.reduce(0, +) / Double(confidence.count)
        return Take(key: key, startWordId: words[0].id, endWordId: last.id, flags: flags,
                    signals: DeliverySignals(fillers: fillers, longestPause: pause, restarts: restarts, wordsPerMinute: rate,
                                             meanConfidence: mean, cutOff: sentence.cutOff))
    }

    private static func hasRestartPhrase(_ lexical: [String]) -> Bool {
        restartTokens.contains { phrase in
            lexical.count >= phrase.count && (0...(lexical.count - phrase.count)).contains { start in
                lexical[start..<(start + phrase.count)].elementsEqual(phrase)
            }
        }
    }

    private static func soloRuns(_ ranges: [Range<Int>], takes: [Take], matchedIds: [String?]) -> [SoloRun] {
        var result: [SoloRun] = []
        for range in ranges {
            var upcoming = matchedIds[range].compactMap { $0 }[...]
            var after: String?
            var runStart: Int?
            for index in range.lowerBound...range.upperBound {
                if index < range.upperBound, matchedIds[index] == nil,
                   !takes[index].flags.contains("restart"), !takes[index].flags.contains("falseStart") {
                    runStart = runStart ?? index
                    continue
                }
                if let start = runStart {
                    result.append(SoloRun(key: takes[start].key, startWordId: takes[start].startWordId,
                                          endWordId: takes[index - 1].endWordId, sentenceCount: index - start,
                                          afterBeatId: after, beforeBeatId: upcoming.first))
                    runStart = nil
                }
                if index < range.upperBound, matchedIds[index] != nil { after = upcoming.popFirst() }
            }
        }
        return result
    }

    private static func align(fromKey: String, source: Sentence, toKey: String, target: Sentence) -> AlignedSpan {
        var pairs = alignment(source.tokens, target.tokens)
        let first = target.tokens[pairs[0].target].position
        let last = target.tokens[pairs[pairs.count - 1].target].position
        let start = (target.words[..<first].lastIndex { TranscriptLineBoundary.endsWithPunctuation($0.text, in: clauseBreaks) } ?? -1) + 1
        let end = clauseEnd(target, anchor: last)
        if isIsolatedTail(source, target, pairs: pairs) { pairs.removeLast() }
        let aligned = Set(pairs.map { target.tokens[$0.target].position })
        let changed = (start...end).filter { !aligned.contains($0) }.map { target.words[$0].id }
        return AlignedSpan(fromKey: fromKey, toKey: toKey, startWordId: target.words[start].id,
                           endWordId: target.words[end].id, changedWordIds: changed)
    }

    private static func clauseEnd(_ sentence: Sentence, anchor: Int) -> Int {
        sentence.words[anchor...].firstIndex { TranscriptLineBoundary.endsWithPunctuation($0.text, in: clauseBreaks) }
            ?? sentence.words.count - 1
    }

    private static func isIsolatedTail(_ source: Sentence, _ target: Sentence, pairs: [(source: Int, target: Int)]) -> Bool {
        guard pairs.count >= 2 else { return false }
        let last = pairs[pairs.count - 1], previous = pairs[pairs.count - 2]
        guard last.source - previous.source - 1 >= isolatedTailGapWords,
              last.target - previous.target - 1 >= isolatedTailGapWords else { return false }
        return (last.source == source.tokens.count - 1 && continuesClause(target, token: last.target)) ||
               (last.target == target.tokens.count - 1 && continuesClause(source, token: last.source))
    }

    private static func continuesClause(_ sentence: Sentence, token: Int) -> Bool {
        token + 1 < sentence.tokens.count && sentence.tokens[token + 1].position <= clauseEnd(sentence, anchor: sentence.tokens[token].position)
    }

    private static func alignment(_ source: [Token], _ target: [Token]) -> [(source: Int, target: Int)] {
        let lengths = lcs(source, target)
        let width = target.count + 1
        var pairs: [(source: Int, target: Int)] = []
        var left = 0, right = 0
        while left < source.count, right < target.count {
            if source[left].text == target[right].text {
                pairs.append((left, right))
                left += 1
                right += 1
            } else if lengths[(left + 1) * width + right] > lengths[left * width + right + 1] {
                left += 1
            } else {
                right += 1
            }
        }
        return pairs
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
                  members[first].allSatisfy({ source in members[second].allSatisfy { matches(sentences[source], sentences[$0]) } }),
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
