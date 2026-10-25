import Foundation

/// doc/spec/ai.md §11.3
public struct TranscriptLine: Codable, Sendable, Equatable {
    /// firstPos; doc/spec/ai.md §11.3
    public var firstPos: Int
    /// lastPos; doc/spec/ai.md §11.3
    public var lastPos: Int
    /// firstIndex; doc/spec/ai.md §11.3
    public var firstIndex: Int
    /// lastIndex; doc/spec/ai.md §11.3
    public var lastIndex: Int
    /// start; doc/spec/ai.md §11.3
    public var start: Double
    /// end; doc/spec/ai.md §11.3
    public var end: Double
    /// text; doc/spec/ai.md §11.3
    public var text: String
    /// pauseAfter; doc/spec/ai.md §11.3
    public var pauseAfter: String?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(firstPos: Int, lastPos: Int, firstIndex: Int, lastIndex: Int, start: Double, end: Double, text: String, pauseAfter: String? = nil) {
        self.firstPos = firstPos
        self.lastPos = lastPos
        self.firstIndex = firstIndex
        self.lastIndex = lastIndex
        self.start = start
        self.end = end
        self.text = text
        self.pauseAfter = pauseAfter
    }

    private enum CodingKeys: String, CodingKey {
        case firstPos
        case lastPos
        case firstIndex
        case lastIndex
        case start
        case end
        case text
        case pauseAfter
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.firstPos = try values.decode(Int.self, forKey: .firstPos)
        self.lastPos = try values.decode(Int.self, forKey: .lastPos)
        self.firstIndex = try values.decode(Int.self, forKey: .firstIndex)
        self.lastIndex = try values.decode(Int.self, forKey: .lastIndex)
        self.start = try values.decode(Double.self, forKey: .start)
        self.end = try values.decode(Double.self, forKey: .end)
        self.text = try values.decode(String.self, forKey: .text)
        self.pauseAfter = try values.decodeIfPresent(String.self, forKey: .pauseAfter) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(firstPos, forKey: .firstPos)
        try values.encode(lastPos, forKey: .lastPos)
        try values.encode(firstIndex, forKey: .firstIndex)
        try values.encode(lastIndex, forKey: .lastIndex)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        try values.encode(text, forKey: .text)
        try values.encode(pauseAfter, forKey: .pauseAfter)
    }

}

/// doc/spec/ai.md §11.3
public struct FormattedTranscript: Codable, Sendable, Equatable {
    /// lines; doc/spec/ai.md §11.3
    public var lines: [TranscriptLine]
    /// rendered; doc/spec/ai.md §11.3
    public var rendered: String

    /// Creates an explicit value without I/O or generated identifiers.
    public init(lines: [TranscriptLine], rendered: String) {
        self.lines = lines
        self.rendered = rendered
    }

    private enum CodingKeys: String, CodingKey {
        case lines
        case rendered
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.lines = try values.decode([TranscriptLine].self, forKey: .lines)
        self.rendered = try values.decode(String.self, forKey: .rendered)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(lines, forKey: .lines)
        try values.encode(rendered, forKey: .rendered)
    }

}
