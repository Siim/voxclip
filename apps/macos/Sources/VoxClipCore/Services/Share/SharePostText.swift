import Foundation

/// Post text for Copy caption, Open X, Open LinkedIn and VoxConvo publish; doc/publishing.md §2.1 and
/// doc/spec/voice-lab.md §11.3. Reads shared/data/share-text.json once through `SharedResources` (architecture §2.4).
/// A missing or invalid file throws `VoxClipError.sharedResourcesMissing`; the App and voxclip-cli call `preflight()`
/// at launch, and after it succeeds no function here throws.
public enum SharePostText {
    /// Loaded once per process. A failure is kept too, so a process that failed the preflight never loads mid-session.
    private static let loaded = Result { try ShareTextRules.load(shared: SharedResources.locate()) }

    static func rules() throws -> ShareTextRules { try loaded.get() }

    /// The launch check next to `SharedResources.locate()`: loads the rules or throws `.sharedResourcesMissing`.
    public static func preflight() throws { _ = try rules() }

    /// X 280 (weighted), LinkedIn 3,000 (Unicode scalars), VoxConvo 2,048 (UTF-16 code units).
    public static func limit(_ destination: ShareDestination) throws -> Int { try rules().limit(destination) }

    /// The X counter: twitter-text v3 weighted length of the NFC text.
    public static func xWeight(_ text: String) throws -> Int { try rules().xWeight(text) }

    /// The LinkedIn counter: Unicode scalar count.
    public static func linkedInLength(_ text: String) -> Int { ShareTextRules.linkedInLength(text) }

    /// UTF-16 code units, a deliberately conservative bound on vox-api's `@Length(0, 2048)` for `NewPostInput.text`:
    /// validator.js `isLength` subtracts surrogate pairs and U+FE0E/U+FE0F, so any text within 2,048 units is accepted.
    public static func voxConvoLength(_ text: String) -> Int { ShareTextRules.voxConvoLength(text) }

    /// The caption as `share.captions` holds it: its first 3,000 Unicode scalars (voice-lab.md §11.3). Both Apps cap their
    /// caption field with it, so the field, Copy caption, the composers and the saved caption see the same text.
    public static func capCaption(_ caption: String) -> String { String(String.UnicodeScalarView(caption.unicodeScalars.prefix(3000))) }

    /// The text Open X (`.x`) or VoxConvo publish (`.voxConvo`) sends. A caption that fits is returned unchanged.
    /// Otherwise the last occurrence of `disclosureLine` is removed, the rest is cut at a word boundary with "…", and the
    /// line follows after a blank line, never cut. `.linkedIn` returns the caption unchanged; Copy caption never uses this.
    public static func composerText(_ caption: String, destination: ShareDestination, disclosureLine: String?) throws -> String {
        try rules().composerText(caption, destination: destination, disclosureLine: disclosureLine)
    }

    /// The default caption: `title` (nil for the full take), blank line, and the first sentence of `words`, the target's
    /// edited, corrected word texts in transcript order. At most 40 words, followed by "…" when no word ends a sentence.
    public static func defaultCaption(title: String?, words: [String]) throws -> String {
        try rules().defaultCaption(title: title, words: words)
    }

    /// The caption field text: the saved or default caption, with the line appended after a blank line when a line
    /// exists and is not present, the caption cut (never the line) to keep the text within 3,000 Unicode scalars.
    /// Otherwise the input unchanged.
    public static func fieldText(_ savedOrDefault: String, line: String?) throws -> String {
        try ShareDisclosure.fieldText(savedOrDefault, line: line, rules: rules())
    }
}

extension ShareTextRules {
    static func load(shared: SharedResources) throws -> ShareTextRules {
        do { return try ShareTextRules(data: Data(contentsOf: shared.root.appendingPathComponent("data/share-text.json"))) }
        catch { throw VoxClipError.sharedResourcesMissing }
    }
}
