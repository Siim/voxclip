import Foundation

public enum HarnessTool: String, CaseIterable, Sendable {
    case readTranscript = "read_transcript"
    case readClips = "read_clips"
    case readTakes = "read_takes"
    case readDecisions = "read_decisions"
    case readFrames = "read_frames"
    case proposeTimeline = "propose_timeline"
    case check
    case findMusic = "find_music"
    case offer
    case pointTo = "point_to"

    package var keys: Set<String> {
        switch self {
        case .readTranscript: ["offset", "limit", "recordingKey"]
        case .readClips, .readTakes: []
        case .readDecisions: ["clipId"]
        case .readFrames: ["times"]
        case .proposeTimeline: HarnessTimeline.keys.union(["timelines"])
        case .check: ["clipId", "targets"]
        case .findMusic: ["mood", "lengthSeconds"]
        case .offer: ["kind", "target", "brief", "words"]
        case .pointTo: ["panel", "target"]
        }
    }

}

public enum HarnessTools {
    public static func call(_ tool: HarnessTool, arguments: JSONValue, project: Project, shared: SharedResources?,
                            projectURL: URL? = nil, cache: URL? = nil,
                            decodeFrames: (@Sendable (URL, [Double]) async throws -> [HarnessResult.Frame])? = nil,
                            music: HarnessMusicLibrary? = nil,
                            check: (@Sendable (Project, String, [String]) throws -> JSONValue)? = nil,
                            postableCap: Decimal? = nil, chat: Bool = true) async throws -> HarnessResult {
        let input = chat && tool == .proposeTimeline ? try HarnessChatTools.timeline(arguments) : (arguments, nil, [])
        let (arguments, revises, labels) = input
        let fields = try HarnessTimeline.requireObject(arguments, keys: tool.keys)
        switch tool {
        case .readTranscript:
            var project = project
            if let requested = fields["recordingKey"] {
                guard case .string(let key) = requested else { throw HarnessError.invalid("Choose a recording key from read_clips.") }
                let source = try HarnessRecording.source(key, in: project)
                guard let transcript = HarnessRecording.cachedTranscript(key, cache: cache ?? DataLocations().cache) else { throw HarnessRecording.refusal(source) }
                project = try HarnessRecording.add(key, transcript: transcript, to: project)
            }
            let clock = ProjectClock.build(project)
            let words = clock.words
            let offset = try Self.integer(fields["offset"], default: 0, range: 0...Int.max)
            let limit = try Self.integer(fields["limit"], default: 200, range: 1...500)
            let first = min(offset, words.count)
            let end = first + min(words.count - first, limit)
            let cut = Set(project.edits.cutWordIds)
            let items: [JSONValue] = (first..<end).map { index in
                let word = words[index]
                return .object(["index": .number(Double(index)), "id": .string(word.id), "kind": .string(word.kind.rawValue),
                                "start": .number(word.start), "end": .number(word.end), "text": .string(project.edits.corrections[word.id] ?? word.text),
                                "cut": .bool(cut.contains(word.id))].merging(Self.recording(clock.region(of: word.id))) { current, _ in current })
            }
            return .init(["words": .array(items), "total": .number(Double(words.count)), "nextOffset": end < words.count ? .number(Double(end)) : .null,
                          "language": clock.transcript?.language.map(JSONValue.string) ?? .null,
                          "recordings": Self.recordings(project, clock: clock)])
        case .readClips:
            let clock = ProjectClock.build(project)
            let indices = Dictionary(uniqueKeysWithValues: clock.words.enumerated().map { ($0.element.id, $0.offset) })
            let clips: [JSONValue] = try project.edits.clips.map { clip in
                let parts = clip.playParts.compactMap { part -> JSONValue? in
                    guard let start = indices[part.startWordId], let end = indices[part.endWordId] else { return nil }
                    var fields = Self.recording(clock.region(of: part.startWordId))
                    fields["startWord"] = .number(Double(start)); fields["endWord"] = .number(Double(end))
                    return .object(fields)
                }
                return .object(["id": .string(clip.id), "title": clip.title.map(JSONValue.string) ?? .null, "selected": .bool(clip.selected),
                         "kind": .string(clip.kind?.rawValue ?? (clip.parts == nil ? "stretch" : "story")), "parts": .array(parts),
                         "startWord": indices[clip.startWordId].map { .number(Double($0)) } ?? .null,
                         "endWord": indices[clip.endWordId].map { .number(Double($0)) } ?? .null,
                         "sourceSpan": try Self.json(ClipControlsProject.sourceSpan(of: clip.id, in: project).map {
                            TimeRange(start: $0.lowerBound, end: $0.upperBound)
                         })])
            }
            let sources: [JSONValue] = project.media.additionalSources.filter { $0.video != nil }.map {
                .object(["sourceKey": .string($0.footageKey), "duration": .number($0.durationSeconds),
                         "name": .string(URL(fileURLWithPath: $0.absolutePath).lastPathComponent)])
            }
            return .init(["projectId": .string(project.id), "clips": .array(clips), "footageSources": .array(sources),
                          "recordings": Self.recordings(project, clock: clock)])
        case .readTakes:
            let clock = ProjectClock.build(project)
            let matches = TakeMatch.build(clock: clock)
            return .init(["beats": try Self.json(matches.beats), "solo": try Self.json(matches.solo),
                          "recordings": Self.recordings(project, clock: clock)])
        case .readDecisions:
            guard case .string(let clipId) = fields["clipId"], let clip = project.edits.clips.first(where: { $0.id == clipId }) else {
                throw HarnessError.invalid("Choose a clip id from read_clips.")
            }
            let result = project.ai.results.first { $0.id == clip.aiResultId }
            let found = clip.aiClipIndex.flatMap { index in result.flatMap { $0.clips.indices.contains(index) ? $0.clips[index] : nil } }
            let tracks = project.music.map { JSONValue.object(["id": .string($0.id), "title": .string($0.title), "clipId": $0.clipId.map(JSONValue.string) ?? .null]) }
            return .init(["clipId": .string(clipId), "title": clip.title.map(JSONValue.string) ?? .null,
                          "timeline": try TimelineDecisions.read(project: project, scope: clipId),
                          "findReason": (found?.reason).map(JSONValue.string) ?? .null,
                          "openingLeadInSeconds": clip.leadInSeconds.map(JSONValue.number) ?? .null,
                          "controls": try Self.json(ClipControlsProject.controls(for: clipId, in: project)),
                          "captionStyle": .string(project.captionSettings(forClip: clipId).styleId), "musicTracks": .array(tracks),
                          "effects": .array(try project.clipEffects.filter { $0.clipId == clipId }.map { effect in
                              .object(["id": .string(effect.id), "kind": .string(effect.kind.rawValue),
                                       "start": .number(effect.start), "end": .number(effect.end),
                                       "text": effect.text.map(JSONValue.string) ?? .null, "rect": try Self.json(effect.rect)])
                          }), "zooms": try Self.json(project.motionCues.filter { $0.clipID == clipId })])
        case .readFrames:
            guard case .array(let requested) = fields["times"], (1...4).contains(requested.count),
                  requested.allSatisfy({ if case .number(let time) = $0 { return time >= 0 && time < project.media.source.durationSeconds }; return false }) else {
                throw HarnessError.invalid("Give one to four source times inside the video.")
            }
            let times = requested.compactMap { if case .number(let time) = $0 { return time }; return nil }
            let source = try sourceURL(project: project, projectURL: projectURL)
            guard let decodeFrames else { throw HarnessError.invalid("Preview frames aren’t available in this host.") }
            let images = try await decodeFrames(source, times)
            return .init(["frames": try Self.json(images.map { ["requested": $0.requested, "actual": $0.actual] })], images: images)
        case .proposeTimeline:
            let timelines = try HarnessTimeline.readSeries(arguments).map { timeline in
                guard let key = timeline.recordingKey,
                      let transcript = HarnessRecording.cachedTranscript(key, cache: cache ?? DataLocations().cache) else { return timeline }
                return try timeline.pinningRecordingTranscript(transcript)
            }
            let shared = try shared ?? SharedResources.locate()
            var project = project
            let requestedTracks = Set(timelines.compactMap(\.musicTrackId)).subtracting(project.music.map(\.id))
            let imported = try await music?.prepare(requestedTracks.sorted(), projectID: project.id) ?? []
            project.music.append(contentsOf: imported)
            let proposal = try HarnessProposal(timelines: timelines, project: project)
            var actions: [JSONValue] = []
            var free: [JSONValue] = []
            var refusals: [JSONValue] = []
            for index in timelines.indices {
                let review: (project: Project, operations: [ClipAutopilotOperation], pending: [ClipAutopilotOperation])
                let recording = timelines[index].recordingKey
                let transcript = recording.flatMap { HarnessRecording.cachedTranscript($0, cache: cache ?? DataLocations().cache) }
                do { review = try proposal.review(project, shared: shared, at: index, recordingTranscript: transcript, preview: true) }
                catch let refusal as TimelineEditRefusal {
                    refusals.append(.object(["timelineIndex": .number(Double(index)), "reason": .string(refusal.copy)]))
                    continue
                }
                guard recording != nil || review.project != project || !review.pending.isEmpty else {
                    throw HarnessError.invalid("The timeline doesn't change the project.")
                }
                let approval: JSONValue = .string("In VoxClip only; the app confirms the price for the open clip.")
                let position: JSONValue = .number(Double(index))
                if let recording { free.append(.object(["kind": .string("useRecording"), "key": .string(recording), "timelineIndex": position])) }
                let music = review.pending.filter { $0.decision == .music }
                for operation in music + review.pending.filter({ $0.decision != .music }) {
                    switch operation.action {
                    case .music(let cue):
                        let price = try proposal.estimatedMusicPrice(in: review.project, shared: shared, at: index)
                        actions.append(.object(["kind": .string("generateMusic"), "prompt": .string(cue.picked.prompt),
                                                "price": price.map(JSONValue.string) ?? .null, "approval": approval, "timelineIndex": position]))
                    case .asset(let asset) where asset.kind == .illustration:
                        actions.append(.object(["kind": .string("generateIllustration"), "prompt": .string(asset.text),
                                                "price": .string(try ClipIllustrationQuote.load(shared: shared).price),
                                                "approval": approval, "timelineIndex": position]))
                    case .asset(let asset):
                        free.append(.object(["kind": .string("findSound"), "query": .string(asset.text), "timelineIndex": position]))
                    case .rewrite(_, let text):
                        let estimate = try VoiceLabPricing.estimate(operation: .elevenLabsTextToSpeech, model: "eleven_multilingual_v2",
                            units: Double(VoiceLabTextLength.length(text)), catalog: VoiceLabPriceCatalog.load(shared: shared))
                        let price = estimate.usd.map(VoiceLabCostPresentation.format)
                        actions.append(.object(["kind": .string("rewrite"), "text": .string(text), "price": price.map(JSONValue.string) ?? .null,
                                                "approval": approval, "timelineIndex": position]))
                    default: break
                    }
                }
            }

            var response: [String: JSONValue] = ["proposal": try Self.json(proposal), "pricedActions": .array(actions), "freeActions": .array(free)]
            if !refusals.isEmpty { response["refusals"] = .array(refusals) }
            if let revises { response["revises"] = .string(revises) }
            if labels.contains(where: { $0 != .null }) { response["labels"] = .array(labels) }
            return .init(response, proposal: proposal, preparedMusic: imported)
        case .check:
            let clipID = try HarnessChatTools.text(fields["clipId"], max: 200)
            let targets = try HarnessChatTools.strings(fields["targets"], maxCount: 8, maxLength: 32)
            guard let check else { throw HarnessError.invalid("Timeline checks aren’t available in this host.") }
            return .init(["checks": try check(project, clipID, targets)])
        case .findMusic:
            let mood = try HarnessChatTools.text(fields["mood"], max: 200)
            guard case .number(let seconds) = fields["lengthSeconds"], seconds.isFinite, seconds > 0 else {
                throw HarnessError.invalid("Give a positive music length in seconds.")
            }
            let tracks = try await music?.search(mood: mood, seconds: seconds) ?? []
            return .init(["tracks": .array(tracks)])
        case .offer:
            return try HarnessChatTools.offer(fields, project: project, shared: shared ?? SharedResources.locate(), postableCap: postableCap)
        case .pointTo:
            return try HarnessChatTools.pointTo(fields)
        }
    }

    private static func recording(_ region: ProjectClock.Region?) -> [String: JSONValue] {
        ["recording": region.map { .string($0.label) } ?? .null, "recordingKey": region.map { .string($0.key) } ?? .null]
    }

    private static func recordings(_ project: Project, clock: ProjectClock) -> JSONValue {
        var next = 0
        func entry(_ key: String, _ label: String, _ duration: Double, _ count: Int?, _ gain: Double) -> JSONValue {
            let first = next
            next += count ?? 0
            return .object(["key": .string(key), "label": .string(label), "durationSeconds": .number(duration),
                            "firstWord": next > first ? .number(Double(first)) : .null,
                            "lastWord": next > first ? .number(Double(next - 1)) : .null,
                            "transcribed": .bool(count != nil), "gainDb": .number(gain)])
        }
        let spoken = project.media.spokenSources ?? []
        let regions = clock.regions.map { region in
            let count = region.prefix.isEmpty ? project.transcript?.words.count : spoken.first { $0.sourceKey == region.key }?.transcript.words.count
            let duration = region.prefix.isEmpty ? project.media.source.durationSeconds :
                project.media.additionalSources.first { $0.contentKey == region.key }?.durationSeconds ?? 0
            return entry(region.key, region.label, duration, count, region.gainDb)
        }
        let keys = Set(clock.regions.map(\.key))
        return .array(regions + project.media.additionalSources.filter { !keys.contains($0.contentKey) }.map {
            entry($0.contentKey, ProjectClock.label($0), $0.durationSeconds, nil, 0)
        })
    }

    private static func sourceURL(project: Project, projectURL: URL?) throws -> URL {
        let media = project.media.source
        var candidates = [URL(fileURLWithPath: media.absolutePath)]
        if let relative = media.relativePath, let projectURL { candidates.append(projectURL.deletingLastPathComponent().appendingPathComponent(relative).standardizedFileURL) }
        guard let source = candidates.first(where: { candidate in
            guard ["mp4", "mov", "m4v"].contains(candidate.pathExtension.lowercased()),
                  let info = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size == media.sizeBytes else { return false }
            return (try? JSONProjectStore.contentKey(for: candidate)) == media.contentKey
        }) else {
            throw HarnessError.invalid("The project's source video is missing. Relink it in VoxClip.")
        }
        return source
    }

    package static func json(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: ProjectJSON.encoder().encode(value))
    }

    static func integer(_ value: JSONValue?, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value else { return fallback }
        guard case .number(let number) = value, let int = Int(exactly: number), range.contains(int) else {
            throw HarnessError.invalid("The page offset or size is out of range.")
        }
        return int
    }
}

public struct HarnessResult: Sendable {
    public struct Frame: Encodable, Sendable {
        public let requested: Double
        public let actual: Double
        public let jpeg: String

        public init(requested: Double, actual: Double, jpeg: String) {
            self.requested = requested
            self.actual = actual
            self.jpeg = jpeg
        }
    }

    public let fields: [String: JSONValue]
    public let images: [Frame]
    public let proposal: HarnessProposal?
    public let preparedMusic: [ProjectMusic]

    init(_ fields: [String: JSONValue], images: [Frame] = [], proposal: HarnessProposal? = nil, preparedMusic: [ProjectMusic] = []) {
        self.fields = fields
        self.images = images
        self.proposal = proposal
        self.preparedMusic = preparedMusic
    }

}
