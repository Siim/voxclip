import Foundation

/// A destination with its own post-text measure and limit; doc/publishing.md §2.1.
public enum ShareDestination: String, Sendable, CaseIterable { case x, linkedIn, voxConvo }

/// The rules of shared/data/share-text.json and the pure algorithms that use them; doc/publishing.md §2.1.
/// `SharePostText` (Services/Share) loads the file once and forwards to these.
struct ShareTextRules: Sendable, Equatable {
    struct Weight: Sendable, Equatable {
        let range: ClosedRange<UInt32>
        let weight: Int
    }
    let xLimit: Int
    let scale: Int
    let defaultWeight: Int
    let urlLength: Int
    let weights: [Weight]
    let linkedInLimit: Int
    let voxConvoLimit: Int
    let ellipsis: String
    let trailing: Set<UInt32>
    let tlds: Set<String>
    let emoji: [ClosedRange<UInt32>]

    private struct File: Decodable {
        struct X: Decodable {
            let maxWeightedTweetLength: Int
            let scale: Int
            let defaultWeight: Int
            let transformedURLLength: Int
            let ranges: [WeightRange]
        }
        struct WeightRange: Decodable {
            let start: UInt32
            let end: UInt32
            let weight: Int
        }
        struct Limit: Decodable { let maxLength: Int }
        struct Links: Decodable {
            let trailingPunctuation: String
            let tlds: [String]
        }
        struct Emoji: Decodable { let ranges: [[UInt32]] }
        let shareTextVersion: Int
        let x: X
        let linkedIn: Limit
        let voxConvo: Limit
        let ellipsis: String
        let url: Links
        let emoji: Emoji
    }

    init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        let emoji = try file.emoji.ranges.map { pair -> ClosedRange<UInt32> in
            guard pair.count == 2, pair[0] <= pair[1] else { throw VoxClipError.sharedResourcesMissing }
            return pair[0]...pair[1]
        }
        // Sorted, disjoint emoji ranges for the binary search.
        guard file.shareTextVersion == 1, file.x.scale > 0, file.x.ranges.allSatisfy({ $0.start <= $0.end }),
              zip(emoji, emoji.dropFirst()).allSatisfy({ $0.upperBound < $1.lowerBound })
        else { throw VoxClipError.sharedResourcesMissing }
        xLimit = file.x.maxWeightedTweetLength
        scale = file.x.scale
        defaultWeight = file.x.defaultWeight
        urlLength = file.x.transformedURLLength
        weights = file.x.ranges.map { Weight(range: $0.start...$0.end, weight: $0.weight) }
        linkedInLimit = file.linkedIn.maxLength
        voxConvoLimit = file.voxConvo.maxLength
        ellipsis = file.ellipsis
        trailing = Set(file.url.trailingPunctuation.unicodeScalars.map(\.value))
        tlds = Set(file.url.tlds.map { $0.lowercased() })
        self.emoji = emoji
        // One ellipsis scalar, itself trailing punctuation, and every trailing scalar stands alone (`lastFittingXCut`).
        guard ellipsis.unicodeScalars.count == 1, let mark = ellipsis.unicodeScalars.first, trailing.contains(mark.value),
              file.url.trailingPunctuation.unicodeScalars.allSatisfy(standsAlone)
        else { throw VoxClipError.sharedResourcesMissing }
    }

    func limit(_ destination: ShareDestination) -> Int {
        switch destination {
        case .x: xLimit
        case .linkedIn: linkedInLimit
        case .voxConvo: voxConvoLimit
        }
    }

    func measure(_ text: String, for destination: ShareDestination) -> Int {
        switch destination {
        case .x: xWeight(text)
        case .linkedIn: Self.linkedInLength(text)
        case .voxConvo: Self.voxConvoLength(text)
        }
    }

    static func linkedInLength(_ text: String) -> Int { text.unicodeScalars.count }
    static func voxConvoLength(_ text: String) -> Int { text.utf16.count }

    /// twitter-text v3 weighted length of the NFC text: each URL 23, each emoji cluster 2, other scalars by range.
    func xWeight(_ text: String) -> Int { xTotal(text) / scale }

    /// The X weight before the division by `scale`.
    private func xTotal(_ text: String) -> Int {
        let scalars = ShareDisclosure.nfc(text)
        var total = 0
        var position = 0
        for url in urlRanges(scalars) + [scalars.count..<scalars.count] {
            for character in ShareDisclosure.string(scalars[position..<url.lowerBound]) {
                let cluster = character.unicodeScalars
                total += cluster.contains(where: isEmoji) ? defaultWeight : cluster.reduce(0) { $0 + weight($1) }
            }
            if !url.isEmpty { total += urlLength * scale }
            position = url.upperBound
        }
        return total
    }

    /// URL spans in NFC scalars: a non-White_Space run from `http://` or `https://`, or from a bare host with a listed TLD,
    /// to the end of the run without its trailing punctuation.
    func urlRanges(_ s: [Unicode.Scalar]) -> [Range<Int>] {
        var urls: [Range<Int>] = []
        var start = 0
        while start < s.count {
            if ShareDisclosure.white(s[start]) { start += 1; continue }
            var next = start
            while next < s.count, !ShareDisclosure.white(s[next]) { next += 1 }
            var end = next
            while end > start, trailing.contains(s[end - 1].value) { end -= 1 }
            for index in start..<end {
                // Neither a scheme nor a bare host may follow an ASCII letter or digit.
                let before: Unicode.Scalar? = index > start ? s[index - 1] : nil
                if let before, Self.asciiAlphanumeric(before) { continue }
                if Self.scheme(s, index, end) != nil
                    || Self.asciiAlphanumeric(s[index]) && !(before.map { "@.-/".unicodeScalars.contains($0) } ?? false) && isHost(s, index, end) {
                    urls.append(index..<end)
                    break
                }
            }
            start = next
        }
        return urls
    }

    /// The text Open X or VoxConvo publish sends; doc/publishing.md §2.1 and doc/spec/voice-lab.md §11.3.
    func composerText(_ caption: String, destination: ShareDestination, disclosureLine: String?) -> String {
        guard destination != .linkedIn else { return caption }
        if measure(caption, for: destination) <= limit(destination) { return caption }
        var body = ShareDisclosure.nfc(caption)
        var line: String?
        if let disclosureLine, let span = ShareDisclosure.lastSpan(of: disclosureLine, in: body) {
            let left = ShareDisclosure.trimmingEnd(body[..<span.lowerBound]), right = ShareDisclosure.trimmingStart(body[span.upperBound...])
            body = left.isEmpty || right.isEmpty ? Array(left) + Array(right) : Array(left) + ["\n", "\n"] + Array(right)
            line = disclosureLine
        }
        return fit(Array(ShareDisclosure.trimmingEnd(body[...])), line: line, destination: destination)
    }

    /// Composer rules 3–6: the body, without trailing White_Space, and the line after a blank line; the body is cut
    /// until the text fits `destination`. A longer kept prefix never measures less, except an X first-word cut, so
    /// bisection finds the longest candidate that fits, each measured whole. `ShareDisclosure.fieldText` cuts with it too.
    func fit(_ body: [Unicode.Scalar], line: String?, destination: ShareDestination) -> String {
        let limit = limit(destination)
        let tail = line.map { "\n\n" + $0 } ?? ""
        func fits(_ text: String) -> Bool { measure(text, for: destination) <= limit }
        let whole = body.isEmpty ? line ?? "" : ShareDisclosure.string(body) + tail
        if fits(whole) { return whole }
        var boundary = [Bool](repeating: false, count: body.count + 1)
        var offset = 0
        boundary[0] = true
        for character in ShareDisclosure.string(body) {
            offset += character.unicodeScalars.count
            boundary[offset] = true
        }
        func cut(_ end: Int) -> String { ShareDisclosure.string(ShareDisclosure.trimmingEnd(body[..<end])) + ellipsis + tail }
        // The longest prefix before a White_Space run after the first word; paragraph breaks inside it are kept. A run
        // that starts inside a cluster (after a Prepend scalar such as U+0600) is no cut.
        let first = body.firstIndex { !ShareDisclosure.white($0) } ?? body.count
        let runs = body.indices.filter { $0 > first && ShareDisclosure.white(body[$0]) && !ShareDisclosure.white(body[$0 - 1]) && boundary[$0] }
        if let end = Self.last(runs, where: { fits(cut($0)) }) { return cut(end) }
        // Not even the first word fits: the last grapheme-cluster boundary inside it that fits. In an X word a URL can come
        // and go as the cut grows, so `lastFittingXCut` weighs every X cut in one pass.
        let wordEnd = body[first...].firstIndex(where: ShareDisclosure.white) ?? body.count
        let ends = (0..<wordEnd).filter { boundary[$0] }
        let end = destination == .x ? lastFittingXCut(body, first: first, wordEnd: wordEnd, ends: ends, tail: tail)
            : Self.last(ends, where: { fits(cut($0)) })
        return end.map(cut) ?? line ?? ellipsis
    }

    /// Composer rule 5 for X in one pass: the cut a scan from the longest cut down picks; doc/publishing.md §2.1 has the
    /// proof. A cut `end` after the first scalar of the word keeps `body[..<end]`, then the ellipsis and the tail. Its
    /// clusters and URLs are the body's, except that the run it ends holds the URL `urlStarts` gives for that run without
    /// its trailing punctuation. URL starts are ASCII and cuts are cluster boundaries, and the ellipsis and trailing
    /// punctuation stand alone, so no piece splits an emoji cluster: a cut weighs prefix sums of per-scalar weights, with
    /// an emoji cluster's weight on its first scalar, plus the ellipsis and the tail weighed whole.
    private func lastFittingXCut(_ body: [Unicode.Scalar], first: Int, wordEnd: Int, ends: [Int], tail: String) -> Int? {
        var prefix = [0]
        prefix.reserveCapacity(wordEnd + 1)
        for character in ShareDisclosure.string(body[..<wordEnd]) {
            let cluster = character.unicodeScalars
            let emojiCluster = cluster.contains(where: isEmoji)
            for (index, scalar) in cluster.enumerated() {
                prefix.append(prefix[prefix.count - 1] + (emojiCluster ? (index == 0 ? defaultWeight : 0) : weight(scalar)))
            }
        }
        let starts = urlStarts(body, first: first, end: wordEnd)
        // stripped[end]: the end of body[first..<end] without its trailing punctuation.
        var stripped = Array(0...wordEnd)
        for index in stride(from: first + 1, through: wordEnd, by: 1) where trailing.contains(body[index - 1].value) {
            stripped[index] = stripped[index - 1]
        }
        let tailTotal = xTotal(ellipsis + tail)
        for end in ends.reversed() {
            // Every cut up to the first scalar of the word keeps nothing but the ellipsis and the tail.
            guard end > first else { return tailTotal / scale <= xLimit ? end : nil }
            let urlEnd = stripped[end]
            let start = urlEnd > first ? starts[urlEnd] : nil
            let total = tailTotal + (start.map { prefix[$0] + urlLength * scale + prefix[end] - prefix[urlEnd] } ?? prefix[end])
            if total / scale <= xLimit { return end }
        }
        return nil
    }

    /// For every end `e` in `first + 1...end`, the start of the URL `urlRanges` finds in the run `s[first..<e]` taken as
    /// already stripped, or nil: one pass instead of one scan per end. A start holds for some ends inside its host or port
    /// and, from one end on, for every later end; the host runs of different starts never overlap. The first start that
    /// holds wins, as in `urlRanges`.
    private func urlStarts(_ s: [Unicode.Scalar], first: Int, end: Int) -> [Int?] {
        var starts = [Int?](repeating: nil, count: end + 1)
        var settled = end + 1  // every end from here on has its start
        let longestTld = tlds.map(\.unicodeScalars.count).max() ?? 0
        func mark(_ e: Int, _ start: Int) { if e < settled, starts[e] == nil { starts[e] = start } }
        for start in first..<end {
            if start > first, Self.asciiAlphanumeric(s[start - 1]) { continue }
            if start + 1 >= settled { break }
            var always = Self.scheme(s, start, end).map { start + $0 } ?? end + 1  // the start holds for every end from here on
            if Self.asciiAlphanumeric(s[start]), !(start > first && "@.-/".unicodeScalars.contains(s[start - 1])) {
                var dots = 0, labelsValid = true, label = start, index = start
                // s[start..<e] is a host: valid labels, at least two, the last a listed TLD.
                func host(_ e: Int) -> Bool {
                    dots > 0 && labelsValid && e > label && e - label <= longestTld && Self.asciiAlphanumeric(s[label])
                        && Self.asciiAlphanumeric(s[e - 1]) && tlds.contains(ShareDisclosure.string(s[label..<e].map(Self.asciiLowercased)))
                }
                while index < end, Self.asciiAlphanumeric(s[index]) || s[index] == "-" || s[index] == "." {
                    if s[index] == "." {
                        labelsValid = labelsValid && index > label && Self.asciiAlphanumeric(s[label]) && Self.asciiAlphanumeric(s[index - 1])
                        dots += 1
                        label = index + 1
                    }
                    index += 1
                    if host(index) { mark(index, start) }
                }
                if index < end, s[index] == "/", host(index) {
                    always = min(always, index + 1)
                } else if index < end, s[index] == ":", host(index) {
                    var digits = index + 1
                    while digits < end, (48...57).contains(s[digits].value) { digits += 1 }
                    for e in stride(from: index + 2, through: digits, by: 1) { mark(e, start) }
                    if digits > index + 1, digits < end, s[digits] == "/" { always = min(always, digits + 1) }
                }
            }
            for e in stride(from: always, to: settled, by: 1) { mark(e, start) }
            settled = min(settled, always)
        }
        return starts
    }

    /// The last of the ascending `candidates` that fits, by bisection: they fit up to some candidate and none after it.
    private static func last(_ candidates: [Int], where fits: (Int) -> Bool) -> Int? {
        var low = 0
        var high = candidates.count
        while low < high {
            let middle = (low + high) / 2
            if fits(candidates[middle]) { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? candidates[low - 1] : nil
    }

    /// `<title>`, blank line, first sentence of the edited, corrected words; doc/publishing.md §2.1.
    func defaultCaption(title: String?, words: [String]) -> String {
        var sentence: [String] = []
        var ended = false
        for word in words.prefix(40) {
            sentence.append(word)
            if let last = word.unicodeScalars.last, ".?!\u{2026}".unicodeScalars.contains(last) {
                ended = true
                break
            }
        }
        let first = sentence.joined(separator: " ") + (ended || sentence.isEmpty ? "" : ellipsis)
        return [title ?? "", first].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func weight(_ scalar: Unicode.Scalar) -> Int {
        weights.first { $0.range.contains(scalar.value) }?.weight ?? defaultWeight
    }

    private func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0xFE0F || value == 0x20E3 || (0x1F1E6...0x1F1FF).contains(value) { return true }
        var low = 0
        var high = emoji.count
        while low < high {
            let middle = (low + high) / 2
            if emoji[middle].upperBound < value { low = middle + 1 } else { high = middle }
        }
        return low < emoji.count && emoji[low].contains(value)
    }

    private func isHost(_ s: [Unicode.Scalar], _ start: Int, _ end: Int) -> Bool {
        // Only ASCII letters, digits, '-' and '.' can be host, so the scan stops at the first other scalar.
        var index = start
        while index < end, Self.asciiAlphanumeric(s[index]) || s[index] == "-" || s[index] == "." { index += 1 }
        guard index == end || s[index] == ":" || s[index] == "/" else { return false }
        let labels = s[start..<index].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(Self.isLabel), let last = labels.last,
              tlds.contains(ShareDisclosure.string(last.map(Self.asciiLowercased))) else { return false }
        if index < end, s[index] == ":" {
            index += 1
            let digits = index
            while index < end, (48...57).contains(s[index].value) { index += 1 }
            guard index > digits else { return false }
        }
        return index == end || s[index] == "/"
    }

    private static func isLabel(_ label: ArraySlice<Unicode.Scalar>) -> Bool {
        guard let first = label.first, let last = label.last, asciiAlphanumeric(first), asciiAlphanumeric(last) else { return false }
        return label.allSatisfy { asciiAlphanumeric($0) || $0 == "-" }
    }

    private static let schemes = ["http://", "https://"].map { Array($0.unicodeScalars) }

    /// The length of the scheme `s[start..<end]` starts with, if any.
    private static func scheme(_ s: [Unicode.Scalar], _ start: Int, _ end: Int) -> Int? {
        schemes.first { scheme in end - start >= scheme.count && scheme.indices.allSatisfy { asciiLowercased(s[start + $0]) == scheme[$0] } }?.count
    }

    /// What `lastFittingXCut` needs of the ellipsis and trailing punctuation. ASCII or General Punctuation, so NFC never
    /// composes it with the scalar before it, and BMP, as C# scans UTF-16; not White_Space or emoji; and its own grapheme
    /// cluster after a letter, an emoji ZWJ sequence and a virama, so it never joins an emoji cluster.
    private func standsAlone(_ scalar: Unicode.Scalar) -> Bool {
        let text = String(Character(scalar))
        return (scalar.value < 0x80 || (0x2000...0x206F).contains(scalar.value)) && !ShareDisclosure.white(scalar) && !isEmoji(scalar)
            && ("a" + text + "a").count == 3 && ("\u{1F642}\u{200D}" + text).count == 2 && ("\u{0915}\u{094D}" + text).count == 2
    }

    private static func asciiAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (97...122).contains(scalar.value) || (65...90).contains(scalar.value) || (48...57).contains(scalar.value)
    }

    private static func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar
    }
}
