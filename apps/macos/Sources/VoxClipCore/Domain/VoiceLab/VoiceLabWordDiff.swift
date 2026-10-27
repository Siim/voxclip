import Foundation

public enum VoiceLabDiffSide: String, Sendable { case source, newText }
public enum VoiceLabWordDiffError: Error, Equatable, Sendable {
    case tokenLimit(side: VoiceLabDiffSide, count: Int, limit: Int)
    case invalidInput
}
public enum VoiceLabDiffOpKind: String, Sendable { case equal, delete, insert }
public enum VoiceLabDiffHunkKind: String, Sendable { case cut, textOnly, voice }

public struct VoiceLabDiffOp: Sendable, Equatable {
    public let kind: VoiceLabDiffOpKind
    public let sourceWordId: String?
    public let sourceToken: String?
    public let newToken: String?
}

public struct VoiceLabDiffHunk: Sendable, Equatable {
    public let kind: VoiceLabDiffHunkKind
    public let sourceWordIds: [String]
    public let newTokens: [String]
    public let correctedTexts: [String]
    public let absorbedItemIds: [String]
    public let bridgeWordIds: [String]
    public let sourceStartIndex: Int
    public let sourceEndIndex: Int
    public let anchorSeconds: Double?
}

public struct VoiceLabWordDiffResult: Sendable, Equatable {
    public let ops: [VoiceLabDiffOp]
    public let hunks: [VoiceLabDiffHunk]
}

public enum VoiceLabWordDiff {
    public static let maximumTokens = 2_000

    private struct Token {
        let word: TimedWord
        let itemIndex: Int
        let surface: String
        let normalized: String
    }
    private struct Region {
        var start: Int
        var end: Int
        var sourceStart: Int
        var sourceEnd: Int
        var kind: VoiceLabDiffHunkKind
        var bridges: [String]
    }

    public static func diff(source: [TimedWord], newText: String) throws -> VoiceLabWordDiffResult {
        var tokens: [Token] = []
        var ids: Set<String> = []
        var previousStart: Double = 0
        for (itemIndex, word) in source.enumerated() {
            guard !word.id.isEmpty, ids.insert(word.id).inserted, word.start.isFinite, word.end.isFinite,
                  word.start >= previousStart, word.end >= word.start else { throw VoiceLabWordDiffError.invalidInput }
            previousStart = word.start
            if word.kind == .word {
                let surfaces: [String] = EditingPrimitives.splitWords(word.text)
                guard !surfaces.isEmpty else { throw VoiceLabWordDiffError.invalidInput }
                tokens += surfaces.map { (surface: String) -> Token in
                    Token(word: word, itemIndex: itemIndex, surface: surface, normalized: normalize(surface))
                }
            }
        }
        let fresh: [String] = EditingPrimitives.splitWords(newText)
        for (side, count) in [(VoiceLabDiffSide.source, tokens.count), (.newText, fresh.count)] where count > maximumTokens {
            throw VoiceLabWordDiffError.tokenLimit(side: side, count: count, limit: maximumTokens)
        }
        let normalized: [String] = fresh.map { (text: String) -> String in normalize(text) }
        let width: Int = fresh.count + 1
        let cells: Int = (tokens.count + 1) * width
        var lengths: [Int32] = Array(repeating: 0, count: cells)
        for sourceIndex in tokens.indices.reversed() {
            for newIndex in fresh.indices.reversed() {
                let cell: Int = sourceIndex * width + newIndex
                let down: Int = cell + width
                lengths[cell] = tokens[sourceIndex].normalized == normalized[newIndex]
                    ? lengths[down + 1] + 1 : max(lengths[down], lengths[cell + 1])
            }
        }
        var ops: [VoiceLabDiffOp] = []
        var sourceIndex: Int = 0
        var newIndex: Int = 0
        while sourceIndex < tokens.count || newIndex < fresh.count {
            if sourceIndex < tokens.count, newIndex < fresh.count,
               tokens[sourceIndex].normalized == normalized[newIndex] {
                let token: Token = tokens[sourceIndex]
                ops.append(VoiceLabDiffOp(kind: .equal, sourceWordId: token.word.id, sourceToken: token.surface, newToken: fresh[newIndex]))
                sourceIndex += 1
                newIndex += 1
            } else {
                let exhausted: Bool = newIndex == fresh.count
                let canDelete: Bool = sourceIndex < tokens.count
                let deleteFirst: Bool = canDelete && (exhausted || lengths[(sourceIndex + 1) * width + newIndex] >= lengths[sourceIndex * width + newIndex + 1])
                if deleteFirst {
                    let token: Token = tokens[sourceIndex]
                    ops.append(VoiceLabDiffOp(kind: .delete, sourceWordId: token.word.id, sourceToken: token.surface, newToken: nil))
                    sourceIndex += 1
                } else {
                    ops.append(VoiceLabDiffOp(kind: .insert, sourceWordId: nil, sourceToken: nil, newToken: fresh[newIndex]))
                    newIndex += 1
                }
            }
        }
        var ordered: [VoiceLabDiffOp] = []
        var cursor: Int = 0
        while cursor < ops.count {
            if ops[cursor].kind == .equal {
                ordered.append(ops[cursor])
                cursor += 1
            } else {
                let start: Int = cursor
                while cursor < ops.count && ops[cursor].kind != .equal { cursor += 1 }
                let run = ops[start..<cursor]
                ordered += run.filter { $0.kind == .delete }
                ordered += run.filter { $0.kind == .insert }
            }
        }
        return VoiceLabWordDiffResult(ops: ordered, hunks: hunks(ops: ordered, tokens: tokens, source: source))
    }

    private static func normalize(_ text: String) -> String {
        EditingPrimitives.normalizeForMatch(EditingPrimitives.nfc(text))
    }

    private static func hunks(ops: [VoiceLabDiffOp], tokens: [Token], source: [TimedWord]) -> [VoiceLabDiffHunk] {
        var regions: [Region] = []
        var cursor: Int = 0
        var sourceIndex: Int = 0
        while cursor < ops.count {
            let start: Int = cursor
            let sourceStart: Int = sourceIndex
            if ops[cursor].kind == .equal {
                if sameSurface(ops[cursor]) {
                    cursor += 1
                    sourceIndex += 1
                    continue
                }
                while cursor < ops.count && ops[cursor].kind == .equal && !sameSurface(ops[cursor]) {
                    cursor += 1
                    sourceIndex += 1
                }
                regions.append(Region(start: start, end: cursor, sourceStart: sourceStart, sourceEnd: sourceIndex, kind: .textOnly, bridges: []))
            } else {
                var inserted: Bool = false
                while cursor < ops.count && ops[cursor].kind != .equal {
                    if ops[cursor].kind == .delete { sourceIndex += 1 } else { inserted = true }
                    cursor += 1
                }
                regions.append(Region(start: start, end: cursor, sourceStart: sourceStart, sourceEnd: sourceIndex,
                                      kind: inserted ? .voice : .cut, bridges: []))
            }
        }
        var sourcePositions: [Int] = [0]
        var sourceOps: [Int] = []
        for (index, op) in ops.enumerated() {
            if op.kind != .insert { sourceOps.append(index) }
            let advance: Int = op.kind == .insert ? 0 : 1
            sourcePositions.append(sourcePositions.last! + advance)
        }
        var widened: [Region] = []
        for var region in regions {
            var first: Int = region.sourceStart
            var last: Int = region.sourceEnd
            if first == last, first > 0, first < tokens.count,
               tokens[first - 1].word.id == tokens[first].word.id {
                first -= 1
                last += 1
            }
            if first < last {
                while first > 0 && tokens[first - 1].word.id == tokens[first].word.id { first -= 1 }
                while last < tokens.count && tokens[last - 1].word.id == tokens[last].word.id { last += 1 }
                region.start = min(region.start, sourceOps[first])
                region.end = max(region.end, sourceOps[last - 1] + 1)
            }
            if let previous = widened.last, region.start <= previous.end {
                widened.removeLast()
                region.start = previous.start
                region.end = max(region.end, previous.end)
            }
            region.sourceStart = sourcePositions[region.start]
            region.sourceEnd = sourcePositions[region.end]
            widened.append(region)
        }
        for index in widened.indices {
            let run = ops[widened[index].start..<widened[index].end]
            let before: [String] = run.compactMap(\.sourceToken).map(normalize)
            let after: [String] = run.compactMap(\.newToken).map(normalize)
            widened[index].kind = after.isEmpty ? .cut : before == after ? .textOnly : .voice
        }
        var merged: [Region] = []
        for region in widened {
            if region.kind == .voice, let earlierIndex = merged.lastIndex(where: { $0.kind == .voice }) {
                let earlier: Region = merged[earlierIndex]
                let between = ops[earlier.end..<region.start]
                let equalOnly: Bool = between.allSatisfy { $0.kind == .equal }
                let gap: Double = startTime(region, tokens: tokens) - endTime(earlier, tokens: tokens)
                let equalItems: [String] = unique(between.compactMap(\.sourceWordId))
                let left: Int = earlier.sourceStart < earlier.sourceEnd
                    ? tokens[earlier.sourceEnd - 1].itemIndex : itemPosition(earlier.sourceStart, tokens: tokens)
                let right: Int = itemPosition(region.sourceStart, tokens: tokens)
                let barrier: Bool = source.indices.contains { (index: Int) -> Bool in
                    index > left && index < right && source[index].kind != .word
                }
                if equalOnly && !barrier && (equalItems.count <= 2 || gap <= 0.35) {
                    let bridges: [String] = between.compactMap(\.sourceWordId)
                    merged.removeSubrange(earlierIndex...)
                    merged.append(Region(start: earlier.start, end: region.end, sourceStart: earlier.sourceStart,
                                         sourceEnd: region.sourceEnd, kind: .voice, bridges: earlier.bridges + bridges))
                    continue
                }
            }
            merged.append(region)
        }
        return merged.map { (region: Region) -> VoiceLabDiffHunk in
            let run = ops[region.start..<region.end]
            let sourceIds: [String] = unique(run.compactMap(\.sourceWordId))
            let newTokens: [String] = run.compactMap(\.newToken)
            var absorbed: [String] = []
            if region.kind == .voice, region.sourceStart < region.sourceEnd {
                let first: Int = tokens[region.sourceStart].itemIndex
                let last: Int = tokens[region.sourceEnd - 1].itemIndex
                absorbed = source.indices.filter { (index: Int) -> Bool in
                    index > first && index < last && source[index].kind != .word
                }.map { (index: Int) -> String in source[index].id }
            }
            var corrected: [String] = []
            if region.kind == .textOnly {
                var offset: Int = 0
                for id in sourceIds {
                    let count: Int = run.filter { $0.sourceWordId == id }.count
                    corrected.append(newTokens[offset..<(offset + count)].joined(separator: " "))
                    offset += count
                }
            }
            return VoiceLabDiffHunk(kind: region.kind, sourceWordIds: sourceIds, newTokens: newTokens,
                                    correctedTexts: corrected, absorbedItemIds: absorbed,
                                    bridgeWordIds: unique(region.bridges), sourceStartIndex: region.sourceStart,
                                    sourceEndIndex: region.sourceEnd,
                                    anchorSeconds: region.sourceStart == region.sourceEnd ? anchor(region.sourceStart, tokens: tokens) : nil)
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
    private static func sameSurface(_ op: VoiceLabDiffOp) -> Bool {
        guard let source = op.sourceToken, let fresh = op.newToken else { return false }
        return source.utf8.elementsEqual(fresh.utf8)
    }
    private static func anchor(_ index: Int, tokens: [Token]) -> Double {
        index < tokens.count ? tokens[index].word.start : tokens.last?.word.end ?? 0
    }
    private static func itemPosition(_ index: Int, tokens: [Token]) -> Int {
        index < tokens.count ? tokens[index].itemIndex : tokens.last?.itemIndex ?? 0
    }
    private static func startTime(_ region: Region, tokens: [Token]) -> Double {
        region.sourceStart < region.sourceEnd ? tokens[region.sourceStart].word.start : anchor(region.sourceStart, tokens: tokens)
    }
    private static func endTime(_ region: Region, tokens: [Token]) -> Double {
        region.sourceStart < region.sourceEnd ? tokens[region.sourceEnd - 1].word.end : anchor(region.sourceStart, tokens: tokens)
    }
}
