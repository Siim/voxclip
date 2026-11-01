import Foundation

/// Punctuation as the folded transcript shows it (ux/v2 notes.md §5). Display only: the
/// transcript, corrections, captions and exports keep every comma.
///
/// A comma that only exists because a filler follows it folds with the filler, so
/// "include, uh, um, source" reads "include • source". A fold of pauses alone keeps the comma
/// before it ("speaking, • it"), and so does a fold with no word after it in its paragraph.
/// Under Show cuts the comma shows again, in the removed words' grey.
public enum DisplayPunctuation {
    /// The trailing commas that can fold: ASCII, full-width and ideographic.
    public static let commas: Set<Character> = [",", "，", "、"]

    /// Whether the word before a fold reads without its trailing comma: it ends in a comma,
    /// the fold removes at least one filler word, and a word follows the fold in the paragraph.
    public static func foldsComma(_ text: String, foldRemovesFiller: Bool, wordFollows: Bool) -> Bool {
        guard foldRemovesFiller, wordFollows, let last = text.last, commas.contains(last) else { return false }
        return text.count > 1
    }

    /// The word without the trailing comma that folds; the text itself when it has none.
    public static func withoutComma(_ text: String) -> String {
        guard let last = text.last, commas.contains(last), text.count > 1 else { return text }
        return String(text.dropLast())
    }
}
