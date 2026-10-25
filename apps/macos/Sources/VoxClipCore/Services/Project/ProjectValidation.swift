import Foundation

enum ProjectValidation {
    static func fail(_ reason: String) throws -> Never { throw VoxClipError.projectUnreadable(reason) }

    static func object(_ value: JSONValue?, required: String, optional: String = "") throws -> [String: JSONValue] {
        guard case .object(let object) = value else { try fail("Expected object") }
        let requiredKeys = Set(required.split(separator: " ").map(String.init))
        let allowed = requiredKeys.union(optional.split(separator: " ").map(String.init))
        guard requiredKeys.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: allowed) else { try fail("Unknown or missing project field") }
        return object
    }

    static func array(_ value: JSONValue?) throws -> [JSONValue] {
        guard case .array(let array) = value else { try fail("Expected array") }
        return array
    }

    static func map(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard case .object(let object) = value else { try fail("Expected object") }
        return object
    }

    static func validate(_ raw: JSONValue) throws {
        let root = try object(raw, required: "format schemaVersion id createdAt modifiedAt savedBy media transcript edits captions export share ai voiceLab", optional: "title extensions")
        if let title = root["title"], case .string = title {} else if root["title"] != nil { try fail("Invalid project title") }
        _ = try object(root["savedBy"], required: "app version platform")
        let media = try object(root["media"], required: "source")
        let source = try object(media["source"], required: "absolutePath relativePath sizeBytes durationSeconds contentKey video audio")
        if source["video"] != .null { _ = try object(source["video"], required: "width height frameRate rotationDegrees") }
        if source["audio"] != .null { _ = try object(source["audio"], required: "sampleRate channels") }
        if root["transcript"] != .null {
            let transcript = try object(root["transcript"], required: "schemaVersion words language languageProbability durationSeconds engine verbatim refined pipelineVersion rawKey createdAt")
            _ = try object(transcript["engine"], required: "id modelId modelSha256 engineVersion locale")
            for word in try array(transcript["words"]) { _ = try object(word, required: "id text kind start end rawStart rawEnd conf speaker timing") }
        }
        let edits = try object(root["edits"], required: "pauseThresholdSeconds pauseKeepSeconds cutWordIds cutPauseIds corrections clips activeClipId")
        for clip in try array(edits["clips"]) { _ = try object(clip, required: "id startWordId endWordId title origin aiResultId aiClipIndex selected") }
        let captions = try object(root["captions"], required: "styleId overrides position positionByAspect")
        _ = try map(captions["overrides"])
        if captions["position"] != .null { _ = try object(captions["position"], required: "x y") }
        for (aspect, position) in try map(captions["positionByAspect"]) {
            guard ["16:9", "9:16", "1:1"].contains(aspect) else { try fail("Invalid caption aspect") }
            _ = try object(position, required: "x y")
        }
        _ = try object(root["export"], required: "aspect quality srt folder")
        _ = try object(root["share"], required: "captions")
        let ai = try object(root["ai"], required: "results")
        for rawResult in try array(ai["results"]) {
            let result = try object(rawResult, required: "id createdAt provider model preset instructions language inputSha256 clips")
            for clip in try array(result["clips"]) { _ = try object(clip, required: "title reason score startWordId endWordId") }
        }
        _ = try object(root["voiceLab"], required: "segments")
        if let extensions = root["extensions"] { _ = try map(extensions) }
        try validateDates(raw)
    }

    static func validateDates(_ raw: JSONValue) throws {
        let root = try map(raw)
        var dates = [root["createdAt"], root["modifiedAt"]]
        if case .object(let transcript) = root["transcript"] { dates.append(transcript["createdAt"]) }
        if case .object(let ai) = root["ai"] {
            for result in try array(ai["results"]) { dates.append(try map(result)["createdAt"]) }
        }
        for value in dates {
            guard case .string(let text) = value,
                  matches(text, "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]{1,9})?Z"),
                  (try? ProjectJSON.decoder().decode(Date.self, from: JSONEncoder().encode(text))) != nil else { try fail("Invalid UTC timestamp") }
        }
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }
    static func require(_ condition: Bool, _ reason: String) throws { if !condition { try fail(reason) } }
    static func text(_ text: String?, min: Int = 0, max: Int = Int.max, pattern: String? = nil) throws {
        guard let text else { return }
        try require(text.unicodeScalars.count >= min && text.unicodeScalars.count <= max && (pattern.map { matches(text, $0) } ?? true), "Invalid project text")
    }
    static func number(_ number: Double, min: Double = 0, max: Double = .greatestFiniteMagnitude) throws {
        try require(number.isFinite && number >= min && number <= max, "Invalid project number")
    }
    static let idPattern = EditingLimits.clipIDPattern
    static let hashPattern = "[0-9a-f]{64}"
    static let slugPattern = "[a-z0-9]+(?:-[a-z0-9]+)*"

    static func validateModel(_ project: Project) throws {
        try ProjectJSON.validate(project)
        try text(project.id, pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
        try text(project.title, max: 200)
        try require(project.savedBy.app == "VoxClip", "Invalid writer")
        try text(project.savedBy.version, pattern: "[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?")
        let source = project.media.source
        try text(source.absolutePath, min: 1, max: 4096)
        try text(source.relativePath, min: 1, max: 4096)
        try require(source.relativePath?.contains("\\") != true && source.sizeBytes >= 0, "Invalid source reference")
        try text(source.contentKey, pattern: hashPattern)
        try number(source.durationSeconds)
        if let video = source.video {
            try require(video.width > 0 && video.height > 0 && [0, 90, 180, 270].contains(video.rotationDegrees), "Invalid video facts")
            try number(video.frameRate, min: .leastNonzeroMagnitude)
        }
        if let audio = source.audio { try require(audio.sampleRate > 0 && audio.channels > 0, "Invalid audio facts") }
        if let transcript = project.transcript {
            try require(transcript.schemaVersion == 1 && transcript.pipelineVersion >= 1, "Invalid transcript version")
            try number(transcript.durationSeconds)
            try text(transcript.language, pattern: "[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*")
            if let probability = transcript.languageProbability { try number(probability, max: 1) }
            try text(transcript.rawKey, pattern: hashPattern)
            try text(transcript.engine.modelId, max: 128)
            try text(transcript.engine.modelSha256, pattern: hashPattern)
            try text(transcript.engine.engineVersion, min: 1, max: 128)
            try text(transcript.engine.locale, max: 35)
            for word in transcript.words {
                try text(word.id, pattern: idPattern)
                try validateWordText(word.text)
                if let start = word.rawStart { try number(start) }
                if let end = word.rawEnd { try number(end) }
                if let confidence = word.conf { try number(confidence, max: 1) }
                try text(word.speaker, max: 64)
            }
        }
        let edits = project.edits
        try number(edits.pauseThresholdSeconds, min: .leastNonzeroMagnitude, max: 10)
        try number(edits.pauseKeepSeconds, max: 1)
        try require(Set(edits.cutWordIds).count == edits.cutWordIds.count && Set(edits.cutPauseIds).count == edits.cutPauseIds.count, "Duplicate cut ids")
        for id in edits.cutWordIds { try text(id, pattern: idPattern) }
        for id in edits.cutPauseIds { try text(id, pattern: "pause-after-" + idPattern) }
        for (id, correction) in edits.corrections { try text(id, pattern: idPattern); try validateWordText(correction) }
        try text(edits.activeClipId, pattern: idPattern)
        try require(Set(edits.clips.map(\.id)).count == edits.clips.count, "Duplicate clip ids")
        for clip in edits.clips {
            try text(clip.id, pattern: idPattern); try text(clip.startWordId, pattern: idPattern); try text(clip.endWordId, pattern: idPattern)
            try text(clip.title, max: EditingLimits.maxClipTitleScalars); try text(clip.aiResultId, pattern: idPattern)
            if let index = clip.aiClipIndex { try require(index >= 0, "Invalid AI clip index") }
        }
        try text(project.captions.styleId, pattern: slugPattern)
        for position in Array(project.captions.positionByAspect.values) + [project.captions.position].compactMap({ $0 }) {
            try number(position.x, max: 1); try number(position.y, max: 1)
        }
        try text(project.export.folder, min: 1, max: 4096)
        for (id, caption) in project.share.captions { try text(id, pattern: "(?:full|" + idPattern + ")"); try text(caption, max: 3000) }
        try require(Set(project.ai.results.map(\.id)).count == project.ai.results.count, "Duplicate AI result ids")
        for result in project.ai.results {
            try text(result.id, pattern: idPattern); try text(result.provider, pattern: slugPattern)
            try text(result.model, min: 1, max: 128); try text(result.instructions, max: 500); try text(result.language, max: 35)
            try text(result.inputSha256, pattern: hashPattern)
            for clip in result.clips {
                try text(clip.title, min: 1, max: 120); try text(clip.reason, max: 300)
                try require((1...10).contains(clip.score), "Invalid clip score")
                try text(clip.startWordId, pattern: idPattern); try text(clip.endWordId, pattern: idPattern)
            }
        }
        for key in project.extensions?.keys ?? Dictionary<String, JSONValue>().keys { try text(key, pattern: "[a-z0-9]+(?:\\.[a-z0-9-]+)+") }
    }

    static func validateWordText(_ value: String) throws {
        try text(value, min: 1, max: EditingLimits.maxCorrectionScalars)
        try require(EditingPrimitives.jsTrim(value) == value && Array(value.precomposedStringWithCanonicalMapping.unicodeScalars) == Array(value.unicodeScalars), "Invalid transcript text")
    }
}
