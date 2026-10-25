import Foundation

public enum SpeechText {
    public static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }
    public static func trim(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.drop(while: isWhitespace).reversed().drop(while: isWhitespace).reversed()))
    }
    public static func isPunctuation(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            [.connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation].contains($0.properties.generalCategory)
        }
    }
    public static func primaryLanguage(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map { $0.lowercased() } ?? code.lowercased()
    }
}
