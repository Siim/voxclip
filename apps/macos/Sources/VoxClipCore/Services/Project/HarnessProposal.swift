import Foundation

public enum HarnessError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

public struct HarnessTimeline: Codable, Sendable, Equatable {
    package static let legacyKeys: Set<String> = ["clipId", "reason", "cuts", "captionStyle", "title", "musicTrackId", "generateMusic", "effects"]
    package static let keys = legacyKeys.union(["newClip", "parts", "pauseCuts", "corrections", "font", "case", "wordsPerCaption",
                                                "look", "speed", "hook", "postText", "coverTitle", "music", "rewrites", "edits"])
    private let wire: JSONValue
    public let proposal: ClipProposal
    let edits: [TimelineEditRequest]
    public let recordingKey: String?
    package let recordingRevision: String?
    public var timelineEditCount: Int { edits.count + (recordingKey == nil ? 0 : 1) }
    public var clipId: String { proposal.target.clipId ?? "" }
    public var reason: String { proposal.reason }
    public var cuts: [ClipAutopilotPlan.Cut]? { proposal.cuts }
    public var captionStyle: String? { proposal.captionStyle }
    public var title: String? { proposal.title ?? proposal.target.new?.title }
    public var musicTrackId: String? { proposal.music?.trackId }
    public var generateMusic: String? { proposal.music?.brief }
    public var effects: [ClipPlanEffect]? { proposal.effects }

    public static func read(_ value: JSONValue) throws -> Self { try read(value, legacy: false) }

    package static func readSeries(_ value: JSONValue) throws -> [Self] {
        if case .object(let fields) = value, fields["timelines"] != nil {
            _ = try requireObject(value, keys: ["timelines"])
            guard case .array(let timelines) = fields["timelines"], (1...6).contains(timelines.count) else {
                throw HarnessError.invalid("Propose one to six timelines.")
            }
            return try timelines.map { try read($0) }
        }
        return [try read(value)]
    }

    private static func read(_ value: JSONValue, legacy: Bool) throws -> Self {
        var fields = try requireObject(value, keys: legacy ? legacyKeys : keys)
        let invalid = HarnessError.invalid("Invalid timeline. Give a clip or new clip, a reason and at least one supported change.")
        let clip = fields.removeValue(forKey: "clipId")
        let new = fields.removeValue(forKey: "newClip")
        guard (clip == nil) != (new == nil), (fields.keys.count > 1) else { throw invalid }
        var recordingKey: String?
        var recordingRevision: String?
        var edits: [TimelineEditRequest] = []
        if let value = fields.removeValue(forKey: "edits") {
            guard case .array(let items) = value, (1...30).contains(items.count) else { throw invalid }
            let other = try items.filter { item in
                guard case .object(let object) = item, object["op"] == .string("useRecording") else { return true }
                let entry = try requireObject(item, keys: ["op", "key", "transcriptRevision"])
                guard recordingKey == nil, case .string(let key) = entry["key"], RecordingTranscriptCache.validKey(key) else { throw invalid }
                if let value = entry["transcriptRevision"] {
                    guard case .string(let digest) = value, RecordingTranscriptCache.validKey(digest) else { throw invalid }
                    recordingRevision = digest
                }
                recordingKey = key
                return false
            }
            if !other.isEmpty { edits = try TimelineEditRequest.read(.array(other)) }
        }
        guard new == nil || edits.isEmpty else { throw invalid }
        if let clip {
            guard case .string(let id) = clip, !id.isEmpty else { throw invalid }
            fields["target"] = .object(["clipId": clip])
        }
        if let new {
            _ = try requireObject(new, keys: ["kind", "title"])
            fields["target"] = .object(["new": new])
        }
        let track = fields.removeValue(forKey: "musicTrackId")
        let brief = fields.removeValue(forKey: "generateMusic")
        guard [track, brief, fields["music"]].compactMap({ $0 }).count <= 1 else { throw invalid }
        if let track { fields["music"] = .object(["trackId": track]) }
        if let brief { fields["music"] = .object(["brief": brief]) }
        if let music = fields["music"] {
            _ = try requireObject(music, keys: ClipPlanMusicShape.keys.union(["trackId", "brief"]))
            _ = try ClipPlanMusicShape.read(music)
        }
        if let font = fields["font"] { _ = try requireObject(font, keys: ["family", "weight"]) }
        for (key, allowed) in [("look", Set(["id", "reason"])), ("speed", Set(["rate", "reason"]))] {
            if let item = fields[key] {
                var object = try requireObject(item, keys: allowed)
                if object["reason"] == nil { object["reason"] = .string("") }
                else if object["reason"]?.aiString.map({ line($0, max: 240) }) != true { throw invalid }
                fields[key] = .object(object)
            }
        }
        let arrays: [(String, Set<String>, Int)] = [
            ("parts", ["startWord", "endWord"], 12), ("cuts", ["startWord", "endWord", "kind", "reason"], 30),
            ("pauseCuts", ["afterWord", "reason"], 30), ("corrections", ["word", "heard", "text", "reason"], 30),
            ("rewrites", ["startWord", "endWord", "text", "reason"], 12), ("effects", [], ClipPlanEffect.maximumEntries),
        ]
        for (key, allowed, maximum) in arrays where fields[key] != nil {
            guard case .array(let items) = fields[key], (1...maximum).contains(items.count) else { throw invalid }
            for item in items where !allowed.isEmpty {
                let entry = try requireObject(item, keys: allowed)
                guard Set(entry.keys) == allowed else { throw invalid }
                if allowed.contains("reason"), entry["reason"]?.aiString.map({ line($0, max: 240) }) != true { throw invalid }
                for field in ["startWord", "endWord", "afterWord", "word"] where allowed.contains(field) {
                    guard let index = entry[field]?.aiInt, index >= 0 else { throw invalid }
                }
                if allowed.contains("text"), entry["text"]?.aiString.map({ line($0, max: key == "rewrites" ? 2000 : 120) }) != true { throw invalid }
                if allowed.contains("heard"), entry["heard"]?.aiString.map({ line($0, max: 120) }) != true { throw invalid }
            }
        }
        guard let proposal = try? JSONDecoder().decode(ClipProposal.self, from: JSONEncoder().encode(JSONValue.object(fields))),
              line(proposal.reason, max: 240), proposal.title.map({ line($0, max: 120) }) != false,
              proposal.hook.map({ line($0, max: 80) }) != false, proposal.postText.map({ line($0, max: 500) }) != false,
              proposal.coverTitle.map({ line($0, max: 80) }) != false, proposal.captionStyle.map({ !$0.isEmpty }) != false,
              proposal.font.map({ line($0.family, max: 80) && (100...900).contains($0.weight) }) != false,
              proposal.wordsPerCaption.map({ (1...12).contains($0) }) != false,
              proposal.speed.map({ ProjectClipControls.speedRange.contains($0.rate) }) != false,
              proposal.music.map({ ($0.trackId == nil) != ($0.brief == nil) && $0.trackId?.isEmpty != true && $0.brief.map { line($0, max: 500) } != false }) != false,
              proposal.target.new.map({ entry in
                  line(entry.title, max: 120) && (entry.kind == .stretch ? proposal.parts?.count == 1 : (proposal.parts?.count ?? 0) >= 2)
              }) != false else { throw invalid }
        return .init(wire: value, proposal: proposal, edits: edits, recordingKey: recordingKey, recordingRevision: recordingRevision)
    }

    private init(wire: JSONValue, proposal: ClipProposal, edits: [TimelineEditRequest], recordingKey: String?, recordingRevision: String?) {
        self.wire = wire; self.proposal = proposal; self.edits = edits; self.recordingKey = recordingKey; self.recordingRevision = recordingRevision
    }

    package func pinningRecordingTranscript(_ transcript: Transcript) throws -> Self {
        guard recordingKey != nil, recordingRevision == nil, case .object(var fields) = wire,
              case .array(let items) = fields["edits"] else { return self }
        let digest = try Self.transcriptRevision(transcript)
        fields["edits"] = .array(items.map { item in
            guard case .object(var operation) = item, operation["op"] == .string("useRecording") else { return item }
            operation["transcriptRevision"] = .string(digest)
            return .object(operation)
        })
        return try Self.read(.object(fields))
    }

    static func transcriptRevision(_ transcript: Transcript) throws -> String {
        SourceContentKey.sha256(try ProjectJSON.encoder().encode(transcript))
    }

    public init(from decoder: any Decoder) throws { self = try Self.read(JSONValue(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try wire.encode(to: encoder) }

    package static func requireObject(_ value: JSONValue, keys: Set<String>) throws -> [String: JSONValue] {
        guard case .object(let fields) = value, Set(fields.keys).isSubset(of: keys), !fields.values.contains(.null) else {
            throw HarnessError.invalid("Unexpected or null argument.")
        }
        return fields
    }

    private static func line(_ text: String, max: Int) -> Bool {
        !text.isEmpty && text.unicodeScalars.count <= max && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
            && !text.unicodeScalars.contains { [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }
    }
}

public struct HarnessProposal: Codable, Sendable, Equatable, Identifiable {
    public let version: Int
    public let id: UUID
    public let projectId: String
    public let baseRevision: String
    public let timelines: [HarnessTimeline]
    public var timeline: HarnessTimeline { timelines[0] }

    public init(timeline: HarnessTimeline, project: Project) throws { try self.init(timelines: [timeline], project: project) }

    public init(timelines: [HarnessTimeline], project: Project) throws {
        try self.init(id: UUID(), timelines: timelines, project: project)
    }

    private init(id: UUID, timelines: [HarnessTimeline], project: Project) throws {
        guard (1...6).contains(timelines.count) else { throw HarnessError.invalid("Propose one to six timelines.") }
        version = 2
        self.id = id
        projectId = project.id
        baseRevision = try Self.revision(of: project, timelines: timelines, version: 2)
        self.timelines = timelines
    }

    public init(from decoder: any Decoder) throws {
        let wire = try JSONValue(from: decoder)
        let fields = try HarnessTimeline.requireObject(wire, keys: ["version", "id", "projectId", "baseRevision", "timeline", "timelines"])
        guard let version = fields["version"]?.aiInt, let id = fields["id"]?.aiString.flatMap(UUID.init(uuidString:)),
              let projectId = fields["projectId"]?.aiString, !projectId.isEmpty,
              let baseRevision = fields["baseRevision"]?.aiString, baseRevision.range(of: "\\A[0-9a-f]{64}\\z", options: .regularExpression) != nil else {
            throw HarnessError.invalid("This timeline proposal can't be read.")
        }
        switch version {
        case 1 where fields["timelines"] == nil:
            guard let change = fields["timeline"] else { throw HarnessError.invalid("Missing timeline.") }
            _ = try HarnessTimeline.requireObject(change, keys: HarnessTimeline.legacyKeys)
            timelines = [try HarnessTimeline.read(change)]
        case 2 where fields["timeline"] == nil:
            guard case .array(let changes) = fields["timelines"], (1...6).contains(changes.count) else {
                throw HarnessError.invalid("Propose one to six timelines.")
            }
            timelines = try changes.map { try HarnessTimeline.read($0) }
        default: throw HarnessError.invalid("This timeline proposal version can't be read.")
        }
        self.version = version; self.id = id; self.projectId = projectId; self.baseRevision = baseRevision
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(version, forKey: .version)
        try fields.encode(id, forKey: .id)
        try fields.encode(projectId, forKey: .projectId)
        try fields.encode(baseRevision, forKey: .baseRevision)
        if version == 1 { try fields.encode(timeline, forKey: .timeline) }
        else { try fields.encode(timelines, forKey: .timelines) }
    }

    private enum CodingKeys: String, CodingKey { case version, id, projectId, baseRevision, timeline, timelines }

    public func clipID(at index: Int) throws -> String {
        let timeline = timelines[index]
        if let existing = timeline.proposal.target.clipId { return existing }
        let digest = SourceContentKey.sha256(try ProjectJSON.encoder().encode(timeline))
        return "harness-\(id.uuidString.lowercased())-\(digest.prefix(12))"
    }

    public func validateRevision(of project: Project) throws {
        guard projectId == project.id, baseRevision == (try Self.revision(of: project, timelines: timelines, version: version)) else {
            throw HarnessError.invalid("The project changed. Ask for a new timeline proposal.")
        }
    }

    public func remaining(after index: Int, project: Project) throws -> Self? {
        var remaining = timelines
        remaining.remove(at: index)
        return remaining.isEmpty ? nil : try Self(id: id, timelines: remaining, project: project)
    }

    public func discarding(at index: Int) -> Self? {
        var remaining = timelines
        remaining.remove(at: index)
        return remaining.isEmpty ? nil : Self(version: version, id: id, projectId: projectId, baseRevision: baseRevision, timelines: remaining)
    }

    private init(version: Int, id: UUID, projectId: String, baseRevision: String, timelines: [HarnessTimeline]) {
        self.version = version; self.id = id; self.projectId = projectId; self.baseRevision = baseRevision; self.timelines = timelines
    }

    public func applying(to project: Project, shared: SharedResources) throws -> Project { try evaluate(project, shared: shared).project }

    public func evaluate(_ project: Project, shared: SharedResources, at index: Int = 0) throws -> (project: Project, assets: [ClipPlanAsset]) {
        let review = try review(project, shared: shared, at: index)
        return (review.project, review.pending.compactMap { if case .asset(let asset) = $0.action { asset } else { nil } })
    }

    public func review(_ project: Project, shared: SharedResources, at index: Int = 0, recordingTranscript: Transcript? = nil,
                       preview: Bool = false) throws
        -> (project: Project, operations: [ClipAutopilotOperation], pending: [ClipAutopilotOperation]) {
        try validateRevision(of: project)
        guard let key = timelines[index].recordingKey else { return try mapping(project, shared: shared, at: index) }
        let source = try HarnessRecording.source(key, in: project)
        if let expected = timelines[index].recordingRevision,
           try recordingTranscript.map(HarnessTimeline.transcriptRevision) != expected {
            throw HarnessError.invalid("The recording transcript changed. Ask for a new timeline proposal.")
        }
        if let recordingTranscript {
            let candidate = try HarnessRecording.add(key, transcript: recordingTranscript, to: project)
            return try mapping(candidate, shared: shared, at: index)
        }
        guard preview else { throw HarnessRecording.refusal(source) }
        if timelines[index].proposal.parts?.contains(where: { $0.endWord >= ProjectClock.build(project).words.count }) == true {
            throw HarnessRecording.refusal(source)
        }
        return try mapping(project, shared: shared, at: index)
    }

    package func mapping(_ project: Project, shared: SharedResources, at index: Int) throws
        -> (project: Project, operations: [ClipAutopilotOperation], pending: [ClipAutopilotOperation]) {
        let proposal = timelines[index].proposal
        let clipID = try clipID(at: index)
        if let style = proposal.captionStyle, try style != "off" && CaptionStyleLibrary(shared: shared).style(id: style) == nil {
            throw HarnessError.invalid("Choose a bundled caption style or off.")
        }
        let fonts = proposal.font == nil ? [:] : try ClipAutopilotFonts.load(shared: shared)
        if let font = proposal.font, fonts[font] == nil { throw HarnessError.invalid("Choose a bundled caption font.") }
        let stickers = proposal.effects == nil ? [] : try AskClaudePrompt.load(shared: shared).stickers
        let operations = try ClipAutopilotMapping.operations(for: proposal, clipID: clipID, project: project, fonts: fonts, stickers: stickers)
        let clipStyle = operations.contains(where: { $0.decision == .captions })
            ? try (project.clipStyle ?? ClipStyleCatalog.load(shared: shared).initial(saved: nil)) : nil
        let result = try ClipAutopilotMapping.apply(operations, to: project, clipCaptions: clipStyle.map { (clipID, $0) })
        guard result.project.edits.clips.contains(where: { $0.id == clipID }) else {
            throw HarnessError.invalid("The proposed clip duplicates an existing clip or doesn't have valid parts.")
        }
        for operation in result.pending {
            switch operation.action {
            case .asset, .music, .rewrite: break
            default: throw HarnessError.invalid("A proposed change overlaps a cut or an existing effect, or doesn't fit the clip.")
            }
        }
        var candidate = result.project
        for edit in timelines[index].edits { candidate = try edit.applying(to: candidate, scope: clipID).project }
        _ = try JSONProjectStore.encode(candidate)
        return (candidate, operations, result.pending)
    }

    public func estimatedMusicPrice(in project: Project, shared: SharedResources, at index: Int = 0) throws -> String? {
        guard timelines[index].generateMusic != nil, project.transcript != nil else { return nil }
        return try Self.musicPrice(in: project, shared: shared, clipID: clipID(at: index))
    }

    static func musicPrice(in project: Project, shared: SharedResources, clipID: String) throws -> String? {
        let seconds = MusicPricing.lengthSeconds(forClip: try renderedSeconds(in: project, clipID: clipID))
        let price = try MusicPricing.estimate(seconds: seconds, catalog: VoiceLabPriceCatalog.load(shared: shared))
        return MusicPricing.label(price)
    }

    static func renderedSeconds(in project: Project, clipID: String) throws -> Double {
        let edit = try RenderCallerInputs.timeline(project: project, clipID: clipID)
        let speed = ClipControlsProject.controls(for: clipID, in: project)?.speed ?? 1
        let timing = ClipSpeedTiming(speed: speed, timeline: edit, effects: ClipEffects.rendered(in: project, clipID: clipID))
        return timing.rendered(edit.duration)
    }

    private static func revision(of project: Project, timelines: [HarnessTimeline], version: Int) throws -> String {
        struct Inputs: Encodable {
            let sourceKey: String
            let transcript: Transcript?
            let edits: ProjectEdits
            let captions: CaptionSettings
            let clipStyle: ClipStyle?
            let controls: [ProjectClipControls]
            let motion: [MotionCue]
            let effects: [ClipEffect]
            let reuseMusic: [ProjectMusic]?
            let footageSources: [MediaReference]?
            let footage: [ClipFootage]?
            let postText: [String: String]?
            let voiceLab: ProjectVoiceLab?
            let spokenSources: [SpokenSource]?
        }
        var edits = project.edits
        edits.activeClipId = nil
        edits.cutWordIds.sort()
        edits.cutPauseIds.sort()
        let usesFootage = version == 2 || timelines.contains { $0.effects?.contains { [.bRoll, .screenshot, .videoStack].contains($0.kind) } == true }
        let input = Inputs(sourceKey: project.media.source.contentKey, transcript: project.transcript, edits: edits,
                           captions: project.captions, clipStyle: project.clipStyle, controls: project.clipControls,
                           motion: project.motionCues, effects: project.clipEffects, reuseMusic: version == 2 || timelines.contains { $0.musicTrackId != nil } ? project.music : nil,
                           footageSources: usesFootage ? project.media.additionalSources : nil, footage: usesFootage ? project.media.footage : nil,
                           postText: version == 2 ? project.share.captions : nil, voiceLab: version == 2 ? project.voiceLab : nil,
                           spokenSources: project.media.spokenSources?.isEmpty == false ? project.media.spokenSources : nil)
        return SourceContentKey.sha256(try ProjectJSON.encoder().encode(input))
    }
}

public enum HarnessInbox {
    public static let maximumBytes = 128 * 1024

    public static func url(for projectURL: URL) -> URL {
        projectURL.standardizedFileURL.resolvingSymlinksInPath().appendingPathExtension("proposal.json")
    }

    public static func read(for projectURL: URL) throws -> HarnessProposal? {
        let path = url(for: projectURL)
        let info: URLResourceValues
        do { info = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= maximumBytes else {
            throw HarnessError.invalid("This timeline proposal can't be read.")
        }
        let data = try Data(contentsOf: path)
        guard data.count <= maximumBytes else { throw HarnessError.invalid("This timeline proposal is too large.") }
        return try JSONDecoder().decode(HarnessProposal.self, from: data)
    }

    public static func stage(_ proposal: HarnessProposal, for projectURL: URL) throws {
        let path = url(for: projectURL)
        let temporary = path.deletingLastPathComponent().appendingPathComponent(".voxclip-proposal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bytes = try AtomicJSON.encoded(proposal)
        guard bytes.count <= maximumBytes else { throw HarnessError.invalid("This timeline proposal is too large.") }
        guard FileManager.default.createFile(atPath: temporary.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
            throw HarnessError.invalid("Can't write a proposal next to the project.")
        }
        do { try FileManager.default.linkItem(at: temporary, to: path) }
        catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw HarnessError.invalid("Review the pending timeline in VoxClip before sending another.")
        }
    }

    public static func resolve(_ proposal: HarnessProposal, remaining: HarnessProposal?, for projectURL: URL) throws {
        guard try read(for: projectURL) == proposal else { throw HarnessError.invalid("The pending timeline changed. Review it again.") }
        let path = url(for: projectURL)
        if let remaining {
            try AtomicJSON.encoded(remaining).write(to: path, options: .atomic)
        } else { try FileManager.default.removeItem(at: path) }
    }

    public static func dismiss(_ proposal: HarnessProposal, for projectURL: URL) throws {
        try resolve(proposal, remaining: nil, for: projectURL)
    }
}
