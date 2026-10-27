import Foundation

/// Portable document encoding; editing §10.1. Dates use `UTCTimestamp`, never a default Date strategy.
public enum ProjectJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .utcTimestamp
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .utcTimestamp
        return decoder
    }

    public static func decode(_ data: Data) throws -> Project {
        let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let version = document?["schemaVersion"] as? Int, version > 3 { throw VoxClipError.projectTooNew }
        if document?["schemaVersion"] as? Int == 3 { try validateV3Wire(document) }
        let project = try decoder().decode(Project.self, from: data)
        try validate(project)
        return project
    }

    private static func validateV3Wire(_ document: [String: Any]?) throws {
        func contains(_ object: [String: Any], _ keys: [String]) -> Bool { keys.allSatisfy { object.keys.contains($0) } }
        guard let voice = document?["voiceLab"] as? [String: Any],
              let clean = voice["cleanAudio"] as? [String: Any],
              contains(clean, ["mode", "assetId", "mix"]),
              let segments = voice["segments"] as? [[String: Any]] else { throw VoxClipError.projectUnreadable("Incomplete Voice Lab render policy") }
        let recipeKeys = ["audio", "words", "outDuration", "seed", "chunks", "roomTone", "seams", "video", "qa", "provenance", "cost", "voiceSource", "voiceRefId", "consentVerifiedAt"]
        let qaKeys = ["transcriptTokens", "transcriptExact", "transcriptMatch", "lufsJumpLu", "peakDbfs", "speakerScore", "speakerThreshold", "speakerModel", "speakerPassed"]
        let videoKeys = ["mode", "sourceStartSample", "sourceEndSample", "outputSamples", "retimeFactor", "zoom", "faceX", "faceY",
                         "assetId", "provider", "model", "requestId", "windowStartSample", "windowEndSample", "syncMode"]
        for segment in segments {
            guard let candidates = segment["candidates"] as? [[String: Any]] else { throw VoxClipError.projectUnreadable("Incomplete Voice Lab candidates") }
            for candidate in candidates {
                if let rejected = candidate["rejected"], !(rejected is NSNull), candidate["recipe"] == nil { continue }
                guard let recipe = candidate["recipe"] as? [String: Any], contains(recipe, recipeKeys),
                      let qa = recipe["qa"] as? [String: Any], contains(qa, qaKeys),
                      let video = recipe["video"] as? [String: Any], contains(video, videoKeys) else { throw VoxClipError.projectUnreadable("Incomplete Voice Lab render recipe") }
            }
        }
    }

    public static func encode(_ project: Project) throws -> Data {
        try validate(project)
        return try encoder().encode(project)
    }

    public static func validate(_ project: Project) throws {
        guard project.format == "voxclip-project", (1...3).contains(project.schemaVersion) else {
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
