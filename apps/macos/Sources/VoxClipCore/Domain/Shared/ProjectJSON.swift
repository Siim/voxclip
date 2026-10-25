import Foundation

/// Portable document encoding; editing §10.1. No default Date strategy is used.
public enum ProjectJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let fractional = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) != 0
            try container.encode(date.formatted(.iso8601.year().month().day().dateSeparator(.dash).timeSeparator(.colon).timeZone(separator: .omitted).time(includingFractionalSeconds: fractional)))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected UTC RFC 3339 timestamp")
        }
        return decoder
    }

    public static func decode(_ data: Data) throws -> Project {
        let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let version = document?["schemaVersion"] as? Int, version > 2 { throw VoxClipError.projectTooNew }
        let project = try decoder().decode(Project.self, from: data)
        try validate(project)
        return project
    }

    public static func encode(_ project: Project) throws -> Data {
        try validate(project)
        return try encoder().encode(project)
    }

    public static func validate(_ project: Project) throws {
        guard project.format == "voxclip-project", (1...2).contains(project.schemaVersion) else {
            throw VoxClipError.projectUnreadable("Unsupported document format or Voice Lab schema")
        }
        if let transcript = project.transcript {
            var identifiers = Set<String>()
            var previousStart = -Double.infinity
            for word in transcript.words {
                guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end > word.start,
                      word.start >= previousStart, identifiers.insert(word.id).inserted else {
                    throw VoxClipError.projectUnreadable("Invalid transcript item or timing")
                }
                previousStart = word.start
            }
        }
        try VoiceLabProject.validate(project)
    }
}
