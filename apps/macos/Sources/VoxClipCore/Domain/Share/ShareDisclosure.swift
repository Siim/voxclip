import Foundation

/// The Voice Lab disclosure line in post text; doc/spec/voice-lab.md §11.3–11.4. The line itself comes only from
/// `VoiceLabDisclosurePlan.postText`.
public enum ShareDisclosure {
    /// Shown before sharing when the caption no longer contains the line; voice-lab.md §11.3.
    public static let removedWarning = "Your post no longer says the video contains AI-modified parts."
    /// The warning's button that shares the caption as it is.
    public static let shareAnyway = "Share anyway"
    /// The warning's button that puts the line back with `SharePostText.fieldText(_:line:)`.
    public static let restoreLine = "Restore line"
    /// The Open X checklist tip while disclosure is required; voice-lab.md §11.4.
    public static let xMadeWithAITip = "Turn on 'Made with AI' in the post's content disclosure before posting."

    /// True when the caption contains the line once both are NFC, every White_Space run is one space and the ends are
    /// trimmed. Any other edit to the line counts as removing it. An empty line counts as present.
    public static func isPresent(_ caption: String, line: String) -> Bool {
        let needle = raw(line)
        return needle.isEmpty || lastMatch(of: needle, in: raw(caption)) != nil
    }

    /// The caption field text: the line after a blank line when it is not present, the caption cut so the text stays
    /// within the 3,000 scalars of `share.captions`; voice-lab.md §11.3. `SharePostText.fieldText` passes the loaded rules.
    static func fieldText(_ savedOrDefault: String, line: String?, rules: ShareTextRules) -> String {
        guard let line, !isPresent(savedOrDefault, line: line) else { return savedOrDefault }
        return rules.fit(Array(trimmingEnd(Array(savedOrDefault.unicodeScalars)[...])), line: line, destination: .linkedIn)
    }

    /// The span of the line's last occurrence in NFC caption scalars, White_Space runs comparing equal; nil when absent.
    static func lastSpan(of line: String, in caption: [Unicode.Scalar]) -> Range<Int>? {
        let needle = raw(line)
        var collapsed: [Unicode.Scalar] = []
        var spans: [Range<Int>] = []
        var index = 0
        while index < caption.count {
            var end = index + 1
            if white(caption[index]) {
                while end < caption.count, white(caption[end]) { end += 1 }
                collapsed.append(" ")
            } else {
                collapsed.append(caption[index])
            }
            spans.append(index..<end)
            index = end
        }
        guard let start = lastMatch(of: needle, in: collapsed) else { return nil }
        return spans[start].lowerBound..<spans[start + needle.count - 1].upperBound
    }

    /// Ordinal scalar search, so both platforms compare the same units.
    static func lastMatch(of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        return stride(from: haystack.count - needle.count, through: 0, by: -1).first { haystack[$0..<$0 + needle.count].elementsEqual(needle) }
    }

    /// NFC scalars. Foundation's composition leaves a precomposed LV syllable before a trailing jamo T (U+AC00 U+11A8),
    /// so the Hangul LV + T composition of Unicode §3.12 runs after it; .NET and twitter-text compose that pair too.
    static func nfc(_ text: String) -> [Unicode.Scalar] {
        var scalars: [Unicode.Scalar] = []
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if let last = scalars.last, (0xAC00...0xD7A3).contains(last.value), (last.value - 0xAC00) % 28 == 0,
               (0x11A8...0x11C2).contains(scalar.value), let syllable = Unicode.Scalar(last.value + scalar.value - 0x11A7) {
                scalars[scalars.count - 1] = syllable
            } else {
                scalars.append(scalar)
            }
        }
        return scalars
    }

    /// `CaptionTextRules.raw` with this NFC: every White_Space run one space, the ends trimmed.
    static func raw(_ text: String) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        var pendingSpace = false
        for scalar in nfc(text) {
            if white(scalar) { pendingSpace = !result.isEmpty; continue }
            if pendingSpace { result.append(" "); pendingSpace = false }
            result.append(scalar)
        }
        return result
    }

    /// Unicode White_Space, the set of `CaptionTextRules.whitespace`, as a switch: the share search calls it per scalar.
    static func white(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    static func trimmingEnd(_ scalars: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
        var end = scalars.endIndex
        while end > scalars.startIndex, white(scalars[end - 1]) { end -= 1 }
        return scalars[..<end]
    }

    static func trimmingStart(_ scalars: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
        var start = scalars.startIndex
        while start < scalars.endIndex, white(scalars[start]) { start += 1 }
        return scalars[start...]
    }

    static func string<Scalars: Sequence<Unicode.Scalar>>(_ scalars: Scalars) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
