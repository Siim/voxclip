import Foundation

/// Editing rules that keep the name of their VoxClip.Core counterpart, `EditingAlgorithms`, so both Cores share one
/// vector per rule.
public enum EditingAlgorithms {
    /// Words a manual clip's title takes from its selection, design §6.2.
    public static let clipTitleWords = 7

    /// A manual clip's title, design §6.2: the first `clipTitleWords` words of the selection as shown (corrections
    /// applied), joined by one space, trimmed, cut to `EditingLimits.maxClipTitleScalars` Unicode scalars and trimmed
    /// again; nil when nothing is left. Both Cores check it against shared/fixtures/clips/manual-titles.json: this one and
    /// VoxClip.Core's `EditingAlgorithms.ClipTitle`.
    public static func clipTitle(_ words: some Sequence<String>) -> String? {
        let joined = EditingPrimitives.jsTrim(words.prefix(clipTitleWords).joined(separator: " "))
        let capped = String(String.UnicodeScalarView(joined.unicodeScalars.prefix(EditingLimits.maxClipTitleScalars)))
        let title = EditingPrimitives.jsTrim(capped)
        return title.isEmpty ? nil : title
    }
}
