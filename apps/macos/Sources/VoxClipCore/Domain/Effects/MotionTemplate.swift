import Foundation

public enum MotionTemplate: Codable, Equatable, Sendable {
    case titleCard(String)
    case kineticCaption(String)
    case logoSting(String)
    case counter(from: Int, to: Int)

    public var label: String {
        switch self {
        case .titleCard: "Title card"
        case .kineticCaption: "Kinetic caption"
        case .logoSting: "Logo sting"
        case .counter: "Counter"
        }
    }

    private enum Name: String, Codable { case titleCard, kineticCaption, logoSting, counter }
    private enum Keys: String, CodingKey { case name, text, from, to }

    var isValid: Bool {
        switch self {
        case .titleCard(let text), .kineticCaption(let text): Self.isLine(text, limit: 80)
        case .logoSting(let text): Self.isLine(text, limit: 24)
        case .counter(let from, let to): (-999_999...999_999).contains(from) && (-999_999...999_999).contains(to)
        }
    }

    private static func isLine(_ text: String, limit: Int) -> Bool {
        !text.isEmpty && text.unicodeScalars.count <= limit && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
            && !text.unicodeScalars.contains { [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }
    }

    static func read(_ raw: JSONValue) -> Self? {
        guard let fields = raw.aiObject, let name = raw[ai: "name"].aiString.flatMap(Name.init(rawValue:)) else { return nil }
        let template: Self
        if name == .counter {
            guard Set(fields.keys) == ["name", "from", "to"], let from = raw[ai: "from"].aiDouble,
                  let to = raw[ai: "to"].aiDouble, let start = Int(exactly: from), let end = Int(exactly: to) else { return nil }
            template = .counter(from: start, to: end)
        } else {
            guard Set(fields.keys) == ["name", "text"], let text = raw[ai: "text"].aiString else { return nil }
            switch name {
            case .titleCard: template = .titleCard(text)
            case .kineticCaption: template = .kineticCaption(text)
            case .logoSting: template = .logoSting(text)
            case .counter: return nil
            }
        }
        return template.isValid ? template : nil
    }

    package func presentation(progress: Double) -> (text: String, scale: Double, down: Double) {
        let progress = min(1, max(0, progress))
        switch self {
        case .titleCard(let text):
            let remaining = 1 - min(1, progress / 0.55)
            return (text, 1, 0.06 * remaining * remaining)
        case .kineticCaption(let text):
            let words = text.split(whereSeparator: \.isWhitespace)
            let reveal = min(1, progress / 0.75)
            let count = max(1, 1 + Int(reveal * Double(words.count)))
            return (words.prefix(count).joined(separator: " "), 1, 0)
        case .logoSting(let text):
            let entrance = min(1, progress / 0.65)
            let scale = entrance < 0.6 ? 0.64 + 0.46 * entrance / 0.6 : 1.10 - 0.10 * (entrance - 0.6) / 0.4
            return (text, scale, 0)
        case .counter(let from, let to):
            let fraction = min(1, progress / 0.68)
            let start: Double = Double(from)
            let delta: Double = Double(to) - start
            let interpolated: Double = start + delta * fraction
            let value = Int(interpolated.rounded())
            return (String(value), 1, 0)
        }
    }

    public init(from decoder: any Decoder) throws {
        guard let template = Self.read(try JSONValue(from: decoder)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid motion template"))
        }
        self = template
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        switch self {
        case .titleCard(let text):
            try values.encode(Name.titleCard, forKey: .name); try values.encode(text, forKey: .text)
        case .kineticCaption(let text):
            try values.encode(Name.kineticCaption, forKey: .name); try values.encode(text, forKey: .text)
        case .logoSting(let text):
            try values.encode(Name.logoSting, forKey: .name); try values.encode(text, forKey: .text)
        case .counter(let from, let to):
            try values.encode(Name.counter, forKey: .name); try values.encode(from, forKey: .from); try values.encode(to, forKey: .to)
        }
    }
}
