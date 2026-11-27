import Foundation

enum ProjectValidation {
    static func fail(_ reason: String, at path: String = "/") throws -> Never { throw VoxClipError.projectUnreadable("\(path): \(reason)") }

    static func object(_ value: JSONValue?, required: String, optional: String = "", at path: String? = nil) throws -> [String: JSONValue] {
        guard case .object(let object) = value else { try fail("expected object", at: path ?? "/") }
        let requiredKeys = required.split(separator: " ").map(String.init)
        for key in requiredKeys where object[key] == nil {
            let location = path.map { $0 == "/" ? key : "\($0)/\(key)" } ?? "/"
            try fail(path == nil ? "missing required field \(key)" : "missing required field", at: location)
        }
        let allowed = Set(requiredKeys).union(optional.split(separator: " ").map(String.init))
        guard Set(object.keys).isSubset(of: allowed) else { try fail("unknown field", at: path ?? "/") }
        return object
    }

    static func array(_ value: JSONValue?, at path: String = "/") throws -> [JSONValue] {
        guard case .array(let array) = value else { try fail("expected array", at: path) }
        return array
    }

    static func map(_ value: JSONValue?, at path: String) throws -> [String: JSONValue] {
        guard case .object(let object) = value else { try fail("expected object", at: path) }
        return object
    }

    static func validate(_ raw: JSONValue) throws {
        try ProjectMigrations.checkVersion(raw)
        let wireVersion = try map(raw, at: "/")["schemaVersion"]
        let isV6 = wireVersion == .number(6)
        let isV5 = isV6 || wireVersion == .number(5)
        let isV4 = isV5 || wireVersion == .number(4)
        let root = try object(raw, required: "format schemaVersion id createdAt modifiedAt savedBy media transcript edits captions export share ai voiceLab", optional: "title extensions clipStyle" + (isV4 ? " contextDemo motionCues music clipEffects clipControls captionTranslations" : ""), at: "/")
        if let clipStyle = root["clipStyle"] {
            let style = try object(clipStyle, required: "preset captions music maxLengthSec shapes rewording captionPicks", optional: "tone", at: "clipStyle")
            for (key, pick) in try map(style["captionPicks"], at: "clipStyle/captionPicks") {
                // Optional: the clip's caption overrides and "by": "user" for the creator's own choice (design.md §6.6).
                let path = "clipStyle/captionPicks/\(key)"
                let fields = try object(pick, required: "styleId reason", optional: "overrides by", at: path)
                if let overrides = fields["overrides"] { _ = try map(overrides, at: "\(path)/overrides") }
                if let by = fields["by"], by != .string("user") { try fail("invalid value", at: "\(path)/by") }
            }
        }
        if let title = root["title"], case .string = title {} else if root["title"] != nil { try fail("Invalid project title") }
        _ = try object(root["savedBy"], required: "app version platform", at: "savedBy")
        let media = try object(root["media"], required: "source", optional: isV4 ? "additionalSources footage" : "", at: "media")
        let additional = try media["additionalSources"].map { try array($0, at: "media/additionalSources") } ?? []
        try require(media["additionalSources"] == nil || !additional.isEmpty, "Empty companion source list")
        var sourceKeys = Set<String>()
        for (index, raw) in ([media["source"] ?? .null] + additional).enumerated() {
            let path = index == 0 ? "media/source" : "media/additionalSources/\(index - 1)"
            let source = try object(raw, required: "absolutePath relativePath sizeBytes durationSeconds contentKey video audio", optional: isV4 ? "recordingHash" : "", at: path)
            if let hash = source["recordingHash"] { try require(hash.aiString.map { matches($0, hashPattern) } == true, "Invalid recording hash") }
            if let key = (source["recordingHash"] ?? source["contentKey"])?.aiString {
                try require(sourceKeys.insert(key).inserted, "Duplicate source recording")
            }
            if source["video"] != .null { _ = try object(source["video"], required: "width height frameRate rotationDegrees", at: "\(path)/video") }
            if source["audio"] != .null { _ = try object(source["audio"], required: "sampleRate channels", at: "\(path)/audio") }
        }
        if let footage = media["footage"] {
            let entries = try array(footage, at: "media/footage")
            guard !entries.isEmpty else { try fail("empty companion placement list", at: "media/footage") }
            for (index, raw) in entries.enumerated() {
                let path = "media/footage/\(index)"
                let fields = try object(raw, required: "id clipID kind start end footage", optional: isV6 ? "fadeInSeconds fadeOutSeconds" : "", at: path)
                _ = try object(fields["footage"], required: "sourceKey start", at: "\(path)/footage")
                for key in ["fadeInSeconds", "fadeOutSeconds"] where fields[key] != nil {
                    guard case .number(let fade) = fields[key], (0...2).contains(fade) else { try fail("invalid value", at: "\(path)/\(key)") }
                }
            }
        }
        if root["transcript"] != .null {
            let transcript = try object(root["transcript"], required: "schemaVersion words language languageProbability durationSeconds engine verbatim refined pipelineVersion rawKey createdAt", at: "transcript")
            _ = try object(transcript["engine"], required: "id modelId modelSha256 engineVersion locale", at: "transcript/engine")
            for (index, word) in try array(transcript["words"], at: "transcript/words").enumerated() {
                _ = try object(word, required: "id text kind start end rawStart rawEnd conf speaker timing", at: "transcript/words/\(index)")
            }
        }
        let edits = try object(root["edits"], required: "pauseThresholdSeconds pauseKeepSeconds cutWordIds cutPauseIds corrections clips activeClipId", at: "edits")
        for (index, clip) in try array(edits["clips"], at: "edits/clips").enumerated() {
            let path = "edits/clips/\(index)"
            if !isV5, case .object(let fields) = clip, fields["parts"] != nil || fields["kind"] != nil {
                try fail("story clip needs schemaVersion 5", at: path)
            }
            let fields = try object(clip, required: "id startWordId endWordId title origin aiResultId aiClipIndex selected", optional: "leadInSeconds" + (isV5 ? " parts kind" : ""), at: path)
            if let kind = fields["kind"] {
                guard fields["parts"] != nil && (kind == .string("story") || kind == .string("showreel")) else { try fail("invalid clip kind", at: "\(path)/kind") }
            }
            if let parts = fields["parts"] {
                for (partIndex, part) in try array(parts, at: "\(path)/parts").enumerated() {
                    let partPath = "\(path)/parts/\(partIndex)"
                    let fields = try object(part, required: "id startWordId endWordId", optional: "reframe", at: partPath)
                    if let reframe = fields["reframe"] { _ = try object(reframe, required: "mode zoom centerX centerY", at: "\(partPath)/reframe") }
                }
            }
            // An opening lead-in (ADR-R48) is schema v4 only: 0 < s ≤ 0.6.
            if let lead = fields["leadInSeconds"] {
                guard isV4, case .number(let seconds) = lead, seconds.isFinite, seconds > 0, seconds <= FrameSampling.openingSpan + 1e-9 else {
                    try fail("invalid clip lead-in", at: "\(path)/leadInSeconds")
                }
            }
        }
        let captions = try object(root["captions"], required: "styleId overrides position positionByAspect", at: "captions")
        _ = try map(captions["overrides"], at: "captions/overrides")
        if captions["position"] != .null { _ = try object(captions["position"], required: "x y", at: "captions/position") }
        for (aspect, position) in try map(captions["positionByAspect"], at: "captions/positionByAspect") {
            guard ["16:9", "9:16", "1:1"].contains(aspect) else { try fail("unknown field", at: "captions/positionByAspect") }
            _ = try object(position, required: "x y", at: "captions/positionByAspect/\(aspect)")
        }
        let export = try object(root["export"], required: "aspect quality srt folder", at: "export")
        guard export["aspect"]?.aiString.flatMap(AspectRatio.init(rawValue:)) != nil else { try fail("invalid value", at: "export/aspect") }
        _ = try object(root["share"], required: "captions", at: "share")
        let ai = try object(root["ai"], required: "results", at: "ai")
        for (index, rawResult) in try array(ai["results"], at: "ai/results").enumerated() {
            let path = "ai/results/\(index)"
            let result = try object(rawResult, required: "id createdAt provider model preset instructions language inputSha256 clips", at: path)
            for (clipIndex, clip) in try array(result["clips"], at: "\(path)/clips").enumerated() {
                let clipPath = "\(path)/clips/\(clipIndex)"
                let fields = try object(clip, required: "title reason score startWordId endWordId", optional: isV5 ? "parts notInTake" : "", at: clipPath)
                if let parts = fields["parts"] {
                    for (partIndex, part) in try array(parts, at: "\(clipPath)/parts").enumerated() {
                        _ = try object(part, required: "startWordId endWordId", at: "\(clipPath)/parts/\(partIndex)")
                    }
                }
                if let note = fields["notInTake"] {
                    guard case .string = note else { try fail("invalid value", at: "\(clipPath)/notInTake") }
                }
            }
        }
        let version = isV4 ? 4 : root["schemaVersion"] == .number(3) ? 3 : root["schemaVersion"] == .number(2) ? 2 : 1
        let voice = try object(root["voiceLab"], required: version >= 3 ? "segments assets cleanAudio voices videoAssets" : version == 2 ? "segments assets" : "segments",
                               optional: version >= 3 ? "speakingRateSamples wholeClipRevoices" : "speakingRateSamples", at: "voiceLab")
        if let rates = voice["speakingRateSamples"] {
            for (key, samples) in try map(rates, at: "voiceLab/speakingRateSamples") {
                let path = "voiceLab/speakingRateSamples/\(key)"
                for (index, sample) in try array(samples, at: path).enumerated() { _ = try object(sample, required: "id ratio", at: "\(path)/\(index)") }
            }
        }
        // A whole-clip revoice (ADR-R46): every key present, `usd` and `match` may be null.
        if let revoices = voice["wholeClipRevoices"] {
            for (index, revoice) in try array(revoices, at: "voiceLab/wholeClipRevoices").enumerated() {
                let path = "voiceLab/wholeClipRevoices/\(index)"
                let item = try object(revoice, required: "id clipId segmentIds script consentRecordId videoRetime lipsyncModel usd match createdAt", at: path)
                if item["match"] != .null { _ = try object(item["match"], required: "take anchorBaseline realSpeech", at: "\(path)/match") }
            }
        }
        if version == 1, try !array(voice["segments"], at: "voiceLab/segments").isEmpty {
            try fail("Version 1 Voice Lab must be empty", at: "voiceLab/segments")
        }
        if version >= 2 {
            for (index, asset) in try array(voice["assets"], at: "voiceLab/assets").enumerated() {
                _ = try object(asset, required: "id kind file sha256 durationSeconds sampleRate createdAt", at: "voiceLab/assets/\(index)")
            }
            for (index, segment) in try array(voice["segments"], at: "voiceLab/segments").enumerated() {
                let path = "voiceLab/segments/\(index)"
                let item = try object(segment, required: "id kind enabled replace outDuration audio text words provenance qa candidates selectedCandidateIndex" + (version >= 3 ? " scope" : ""), optional: version >= 3 ? "groupId" : "", at: path)
                _ = try object(item["replace"], required: "start end firstWordId lastWordId", at: "\(path)/replace")
                _ = try object(item["audio"], required: "assetId trimStart trimEnd stretch gainDb", optional: "tiltDbPerOctave", at: "\(path)/audio")
                if item["text"] != .null {
                    let text = try object(item["text"], required: "original new", optional: "audioTags", at: "\(path)/text")
                    if let annotations = text["audioTags"] {
                        let tagsPath = "\(path)/text/audioTags"
                        for (tagIndex, annotation) in try array(annotations, at: tagsPath).enumerated() {
                            _ = try object(annotation, required: "beforeToken tag", at: "\(tagsPath)/\(tagIndex)")
                        }
                    }
                }
                if item["words"] != .null {
                    for (wordIndex, word) in try array(item["words"], at: "\(path)/words").enumerated() {
                        _ = try object(word, required: "text start end synthetic", at: "\(path)/words/\(wordIndex)")
                    }
                }
                let provenance = try object(item["provenance"], required: "provider endpoint model voiceId consentRecordId requestId seed createdAt" + (version >= 3 ? " region" : ""), optional: "pace", at: "\(path)/provenance")
                if let pace = provenance["pace"] {
                    guard case .number(let value) = pace, VoiceLabPace.isValid(value) else { try fail("invalid value", at: "\(path)/provenance/pace") }
                }
                _ = try object(item["qa"], required: "transcriptMatch lufsJumpLu peakDbfs speakerScore", at: "\(path)/qa")
                for (candidateIndex, candidate) in try array(item["candidates"], at: "\(path)/candidates").enumerated() {
                    let candidatePath = "\(path)/candidates/\(candidateIndex)"
                    let record = try object(candidate, required: "assetId score rejected", optional: version >= 3 ? "recipe" : "", at: candidatePath)
                    let recipePath = "\(candidatePath)/recipe"
                    if let recipe = record["recipe"] { try validateRenderRecipe(recipe, at: recipePath) }
                    else if version >= 3, record["rejected"] == .null { try fail("missing required field", at: recipePath) }
                }
            }
        }
        if version >= 3 {
            let clean = try object(voice["cleanAudio"], required: "mode assetId mix", at: "voiceLab/cleanAudio")
            try require(clean["mode"] == .string("off") || clean["mode"] == .string("on"), "Invalid clean-audio mode")
            for (index, value) in try array(voice["voices"], at: "voiceLab/voices").enumerated() {
                _ = try object(value, required: "id provider voiceId consentRecordId displayName status", at: "voiceLab/voices/\(index)")
            }
            for (index, value) in try array(voice["videoAssets"], at: "voiceLab/videoAssets").enumerated() {
                _ = try object(value, required: "id file sha256 durationSeconds frameRate width height", at: "voiceLab/videoAssets/\(index)")
            }
        }
        if let extensions = root["extensions"] { _ = try map(extensions, at: "extensions") }
        if let demo = root["contextDemo"] {
            let document = try ContextDemoCodec.decode(ProjectJSON.encoder().encode(demo))
            try require(root["id"] == .string(document.projectId) && media["source"]?[ai: "contentKey"] == .string(document.sourceContentKey), "Context demo source binding mismatch")
        }
        if let cues = root["motionCues"] { try validateMotionCues(cues) }
        if let music = root["music"] { try MusicProject.validateWire(music, timelineEdits: isV6) }
        if let effects = root["clipEffects"] { try ClipEffects.validateWire(effects, timelineEdits: isV6) }
        if let controls = root["clipControls"] { try ClipControlsProject.validateWire(controls) }
        if let translations = root["captionTranslations"] { try CaptionTranslations.validateWire(translations) }
        try validateDates(raw)
    }

    static func validateMotionCues(_ value: JSONValue) throws {
        func scalar(_ value: JSONValue?) throws -> Double {
            guard case .number(let number) = value, number.isFinite else { try fail("Invalid motion number") }
            return number
        }
        for (cueIndex, value) in try array(value, at: "motionCues").enumerated() {
            let path = "motionCues/\(cueIndex)"
            let cue = try object(value, required: "id clipID sourceStart sourceEnd keyframes", at: path)
            guard case .string(let id) = cue["id"], !id.isEmpty,
                  case .string(let clipID) = cue["clipID"], !clipID.isEmpty else { try fail("Invalid motion identity") }
            let start = try scalar(cue["sourceStart"])
            let end = try scalar(cue["sourceEnd"])
            try require(start >= 0 && end - start + 1e-9 >= 0.1 && end - start <= 120 + 1e-9, "Invalid motion duration")
            let frames = try array(cue["keyframes"], at: "\(path)/keyframes")
            try require((2...8).contains(frames.count), "Invalid motion keyframe count")
            var previous = -Double.infinity
            for (index, value) in frames.enumerated() {
                let frame = try object(value, required: "progress scale anchorX anchorY", at: "\(path)/keyframes/\(index)")
                let progress = try scalar(frame["progress"])
                try number(progress, max: 1)
                try number(scalar(frame["scale"]), min: 1, max: 1.35)
                try number(scalar(frame["anchorX"]), max: 1)
                try number(scalar(frame["anchorY"]), max: 1)
                try require(progress > previous && (index != 0 || progress == 0) && (index != frames.count - 1 || progress == 1), "Noncanonical motion keyframes")
                previous = progress
            }
        }
    }

    static func validateRenderRecipe(_ value: JSONValue, at path: String) throws {
        let recipe = try object(value, required: "audio words outDuration seed chunks roomTone seams video qa provenance cost voiceSource voiceRefId consentVerifiedAt", optional: "edgeGain", at: path)
        _ = try object(recipe["audio"], required: "assetId trimStart trimEnd stretch gainDb", optional: "tiltDbPerOctave", at: "\(path)/audio")
        if recipe["words"] != .null {
            for (index, word) in try array(recipe["words"], at: "\(path)/words").enumerated() {
                _ = try object(word, required: "text start end synthetic", at: "\(path)/words/\(index)")
            }
        }
        for (index, value) in try array(recipe["chunks"], at: "\(path)/chunks").enumerated() {
            _ = try object(value, required: "sourceStartSample sourceEndSample requestId seed assetId assetSha256 assembledStartFrame assembledEndFrame", at: "\(path)/chunks/\(index)")
        }
        if recipe["roomTone"] != .null { _ = try object(recipe["roomTone"], required: "sourceStartSample sourceEndSample gainDb", optional: "endGainDb", at: "\(path)/roomTone") }
        let seams = try object(recipe["seams"], required: "in out", at: "\(path)/seams")
        for side in ["in", "out"] {
            let seamPath = "\(path)/seams/\(side)"
            let seam = try object(seams[side], required: "kind fadeSamples sourceHandleSamples assetHandleFrames", optional: "microPause", at: seamPath)
            if let pause = seam["microPause"] { _ = try object(pause, required: "wordStartSeconds wordEndSeconds", at: "\(seamPath)/microPause") }
        }
        if let value = recipe["edgeGain"] {
            let gains = try object(value, required: "", optional: "in out", at: "\(path)/edgeGain")
            for side in ["in", "out"] {
                if let value = gains[side] {
                    let gainPath = "\(path)/edgeGain/\(side)"
                    let gain = try object(value, required: "gainDb wordSeconds", at: gainPath)
                    _ = try object(gain["wordSeconds"], required: "wordStartSeconds wordEndSeconds", at: "\(gainPath)/wordSeconds")
                }
            }
        }
        let video = try object(recipe["video"], required: "mode sourceStartSample sourceEndSample outputSamples retimeFactor zoom faceX faceY assetId provider model requestId windowStartSample windowEndSample syncMode", optional: "cuts", at: "\(path)/video")
        if let cuts = video["cuts"] {
            for (index, cut) in try array(cuts, at: "\(path)/video/cuts").enumerated() {
                _ = try object(cut, required: "startSample endSample", at: "\(path)/video/cuts/\(index)")
            }
        }
        let qa = try object(recipe["qa"], required: "transcriptTokens transcriptExact transcriptMatch lufsJumpLu peakDbfs speakerScore speakerThreshold speakerModel speakerPassed", optional: "shortSpeech joinAdvisory outputSpeakerCheckSkipped", at: "\(path)/qa")
        if let skipped = qa["outputSpeakerCheckSkipped"], skipped != .bool(true) { try fail("invalid value", at: "\(path)/qa/outputSpeakerCheckSkipped") }
        if let value = qa["joinAdvisory"] {
            let advisoryPath = "\(path)/qa/joinAdvisory"
            let advisory = try object(value, required: "seams acceptedAt", at: advisoryPath)
            for (index, seam) in try array(advisory["seams"], at: "\(advisoryPath)/seams").enumerated() {
                _ = try object(seam, required: "side excessLu", at: "\(advisoryPath)/seams/\(index)")
            }
        }
        if let evidence = qa["shortSpeech"] {
            _ = try object(evidence, required: "mode recordId consentMethod voicedFrames takeCount", at: "\(path)/qa/shortSpeech")
        }
        let provenance = try object(recipe["provenance"], required: "provider endpoint model voiceId consentRecordId requestId seed createdAt region", optional: "pace", at: "\(path)/provenance")
        if let pace = provenance["pace"] {
            guard case .number(let value) = pace, VoiceLabPace.isValid(value) else { try fail("invalid value", at: "\(path)/provenance/pace") }
        }
        _ = try object(recipe["cost"], required: "quoteId usd", at: "\(path)/cost")
    }

    static func validateDates(_ raw: JSONValue) throws {
        let root = try map(raw, at: "/")
        var dates = [(root["createdAt"], "createdAt"), (root["modifiedAt"], "modifiedAt")]
        if case .object(let transcript) = root["transcript"] { dates.append((transcript["createdAt"], "transcript/createdAt")) }
        if case .object(let ai) = root["ai"] {
            for (index, result) in try array(ai["results"], at: "ai/results").enumerated() {
                let path = "ai/results/\(index)"
                dates.append((try map(result, at: path)["createdAt"], "\(path)/createdAt"))
            }
        }
        for (value, path) in dates {
            guard case .string(let text) = value, UTCTimestamp.date(from: text) != nil else { try fail("invalid UTC timestamp", at: path) }
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
        for source in [project.media.source] + project.media.additionalSources {
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
        }
        var media = ProjectMedia(source: project.media.source, additionalSources: project.media.additionalSources)
        var placementIDs = Set<String>()
        for entry in project.media.footage {
            try text(entry.id, pattern: idPattern)
            try text(entry.clipID, pattern: idPattern)
            try text(entry.footage.sourceKey, pattern: hashPattern)
            try require(placementIDs.insert(entry.id).inserted && media.storeFootage(entry, allowShortSource: project.schemaVersion == 6), "Invalid companion footage placement")
        }
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
            if let lead = clip.leadInSeconds {
                try require(project.schemaVersion >= 4 && lead.isFinite && lead > 0 && lead <= FrameSampling.openingSpan + 1e-9, "Invalid clip lead-in")
            }
        }
        try text(project.captions.styleId, pattern: slugPattern)
        if let clipStyle = project.clipStyle {
            try clipStyle.validate()
            for id in clipStyle.captionPicks.keys { try text(id, pattern: idPattern) }
        }
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
        try require(EditingPrimitives.jsTrim(value) == value && Array(EditingPrimitives.nfc(value).unicodeScalars) == Array(value.unicodeScalars), "Invalid transcript text")
    }
}
