import Foundation

/// The length of new wording for the length budget and its checks (voice-lab §8.9.1). Spaces, punctuation, symbols,
/// combining marks and number forms other than decimal digits do not count. Vectors: `shared/fixtures/voice-lab/text-length-cases.json`.
public enum VoiceLabTextLength {
    /// The number of Unicode scalars of general category L* or Nd in the NFC form of `text`.
    public static func length(_ text: String) -> Int {
        EditingPrimitives.nfc(text).unicodeScalars.reduce(0) { count, scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: count + 1
            default: count
            }
        }
    }
}
