import Foundation

public enum HarnessError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

public struct HarnessTimeline: Codable, Sendable, Equatable {
    package static let keys: Set<String> = ["clipId", "reason", "cuts", "captionStyle", "title", "musicTrackId", "generateMusic", "effects"]
    private static let supportedEffects: Set<ClipPlanEffect.Kind> = [.zoom, .punchIn, .motionTitle, .lowerThird, .emojiPop, .motionTemplate]
    public let clipId: String
    public let reason: String
    public let cuts: [ClipAutopilotPlan.Cut]?
    public let captionStyle: String?
    public let title: String?
    public let musicTrackId: String?
    public let generateMusic: String?
    public let effects: [ClipPlanEffect]?

    public static func read(_ value: JSONValue) throws -> Self {
        let fields = try requireObject(value, keys: keys)
        if case .array(let cuts) = fields["cuts"] {
            for cut in cuts { _ = try requireObject(cut, keys: ["startWord", "endWord", "kind", "reason"]) }
        }
        guard let timeline = try? JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)),
              line(timeline.reason, max: 240), timeline.title.map({ line($0, max: EditingLimits.maxClipTitleScalars) }) != false,
              timeline.generateMusic.map({ line($0, max: 500) }) != false,
              timeline.generateMusic == nil || timeline.musicTrackId == nil,
              timeline.effects.map({ (1...ClipPlanEffect.maximumEntries).contains($0.count)
                  && $0.allSatisfy { supportedEffects.contains($0.kind) } }) != false,
              timeline.cuts.map({ (1...30).contains($0.count) }) != false,
              (timeline.cuts ?? []).allSatisfy({ line($0.reason, max: 240) }),
              timeline.title != nil || timeline.captionStyle != nil || timeline.musicTrackId != nil || timeline.generateMusic != nil
                || timeline.effects?.isEmpty == false || timeline.cuts?.isEmpty == false else {
            throw HarnessError.invalid("Invalid timeline. Give a clip, a reason and at least one supported change.")
        }
        return timeline
    }

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
    public let timeline: HarnessTimeline

    public init(timeline: HarnessTimeline, project: Project) throws {
        version = 1
        id = UUID()
        projectId = project.id
        baseRevision = try Self.revision(of: project, timeline: timeline)
        self.timeline = timeline
    }

    public func applying(to project: Project, shared: SharedResources) throws -> Project {
        guard version == 1, projectId == project.id, baseRevision == (try Self.revision(of: project, timeline: timeline)) else {
            throw HarnessError.invalid("The project changed. Ask for a new timeline proposal.")
        }
        guard let transcript = project.transcript, let clip = project.edits.clips.first(where: { $0.id == timeline.clipId }),
              let start = transcript.words.firstIndex(where: { $0.id == clip.startWordId }),
              let end = transcript.words.firstIndex(where: { $0.id == clip.endWordId }), start <= end else {
            throw HarnessError.invalid("Choose an existing clip with a transcript.")
        }
        let words = transcript.words
        let scope = start...end
        var next = project
        var cutIDs = Set<String>()
        for cut in timeline.cuts ?? [] {
            guard scope.contains(cut.startWord), scope.contains(cut.endWord), cut.startWord <= cut.endWord else {
                throw HarnessError.invalid("A cut is outside the clip.")
            }
            let ids = words[cut.startWord...cut.endWord].filter { $0.kind == .word }.map(\.id)
            guard !ids.isEmpty, cutIDs.isDisjoint(with: ids) else { throw HarnessError.invalid("Cuts must name distinct spoken words.") }
            cutIDs.formUnion(ids)
        }
        let uncut = cutIDs.subtracting(project.edits.cutWordIds)
        if !uncut.isEmpty { try next.applyEditing(.cutSelection(ids: uncut.sorted())) }
        let allCuts = Set(next.edits.cutWordIds)
        guard cutIDs.isSubset(of: allCuts), words[scope].contains(where: { $0.kind == .word && !allCuts.contains($0.id) }) else {
            throw HarnessError.invalid("Keep at least one spoken word in the clip.")
        }
        if let title = timeline.title { try next.applyEditing(.renameClip(id: clip.id, title: title)) }
        if let style = timeline.captionStyle {
            guard try style == "off" || CaptionStyleLibrary(shared: shared).style(id: style) != nil else {
                throw HarnessError.invalid("Choose a bundled caption style or off.")
            }
            let catalog = try ClipStyleCatalog.load(shared: shared)
            guard let settings = next.clipStyle ?? catalog.presets.first(where: { $0.id == catalog.defaultPreset })?.style else {
                throw HarnessError.invalid("No clip style is available.")
            }
            next.clipStyle = settings.choosingCaptionStyle(style, forClip: clip.id, current: next.captionSettings(forClip: clip.id))
        }
        if let trackID = timeline.musicTrackId {
            guard var track = project.music.first(where: { $0.id == trackID }) else {
                throw HarnessError.invalid("Choose a saved music track from this project.")
            }
            track.clipId = clip.id
            next = try MusicProject.setting(MusicProject.unique(track, in: next), clipId: clip.id, in: next)
        }
        if let effects = timeline.effects, !effects.isEmpty {
            let stickers = try AskClaudePrompt.load(shared: shared).stickers
            let cutPauses = Set(next.edits.cutPauseIds)
            let tightened = Set(scope.filter { cutPauses.contains("pause-after-" + words[$0].id) })
            for (index, effect) in effects.enumerated() {
                let effectID = "harness-\(id.uuidString.lowercased())-\(index)"
                guard let operation = effect.operation(id: effectID, clipID: clip.id, scope: scope, words: words,
                                                       cut: allCuts, tightenedAfter: tightened, stickers: stickers) else {
                    throw HarnessError.invalid("Effect \(index + 1) is not supported on those words. Use a kept span of 0.1–5 seconds.")
                }
                switch operation.action {
                case .motion(let cue):
                    guard let changed = ClipAutopilotMapping.addingMotionCue(cue, to: next) else {
                        throw HarnessError.invalid("Effect \(index + 1) overlaps a cut or another zoom.")
                    }
                    next = changed
                case .effect(let overlay): next = try ClipEffects.adding([overlay], to: next)
                default: throw HarnessError.invalid("Unsupported effect.")
                }
            }
        }
        _ = try JSONProjectStore.encode(next)
        return next
    }

    public func estimatedMusicPrice(in project: Project, shared: SharedResources) throws -> String? {
        guard timeline.generateMusic != nil, let transcript = project.transcript,
              let clip = project.edits.clips.first(where: { $0.id == timeline.clipId }) else { return nil }
        let state = try EditState(transcript: transcript, edits: project.edits)
        let segments = try buildSegments(state, activeClip: clip)
        let rate = Double(project.media.source.audio?.sampleRate ?? 48_000)
        let edit = try buildEditPlan(segments, duration: project.media.source.durationSeconds, sampleRate: rate, pauseKeepSeconds: state.pauseKeepSeconds)
        let speed = ClipControlsProject.controls(for: clip.id, in: project)?.speed ?? 1
        let seconds = MusicPricing.lengthSeconds(forClip: Double(edit.outputSamples) / rate / speed)
        let price = try MusicPricing.estimate(seconds: seconds, catalog: VoiceLabPriceCatalog.load(shared: shared))
        return MusicPricing.label(price)
    }

    private static func revision(of project: Project, timeline: HarnessTimeline) throws -> String {
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
        }
        var edits = project.edits
        edits.activeClipId = nil
        edits.cutWordIds.sort()
        edits.cutPauseIds.sort()
        let input = Inputs(sourceKey: project.media.source.contentKey, transcript: project.transcript, edits: edits,
                           captions: project.captions, clipStyle: project.clipStyle, controls: project.clipControls,
                           motion: project.motionCues, effects: project.clipEffects, reuseMusic: timeline.musicTrackId == nil ? nil : project.music)
        let bytes = try ProjectJSON.encoder().encode(input)
        return SourceContentKey.sha256(bytes)
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
        let raw = try JSONDecoder().decode(JSONValue.self, from: data)
        let fields = try HarnessTimeline.requireObject(raw, keys: ["version", "id", "projectId", "baseRevision", "timeline"])
        _ = try HarnessTimeline.read(fields["timeline"] ?? .null)
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

    public static func dismiss(_ proposal: HarnessProposal, for projectURL: URL) throws {
        guard try read(for: projectURL) == proposal else { throw HarnessError.invalid("The pending timeline changed. Review it again.") }
        try FileManager.default.removeItem(at: url(for: projectURL))
    }
}
