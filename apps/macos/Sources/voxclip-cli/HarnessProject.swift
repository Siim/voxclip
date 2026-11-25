import AVFoundation
import ArgumentParser
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VoxClipCore
import VoxClipMedia

struct HarnessProject {
    let url: URL
    let id: String

    init(path: String) throws {
        url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        id = try Self.read(url).id
    }

    private static func read(_ url: URL) throws -> Project {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard url.pathExtension.lowercased() == "voxclip", info.isRegularFile == true, info.isSymbolicLink != true,
              url.resolvingSymlinksInPath() == url else {
            throw HarnessError.invalid("Choose a saved .voxclip project file.")
        }
        return try JSONProjectStore.decode(Data(contentsOf: url))
    }

    func call(_ tool: HarnessTool, arguments: JSONValue) async throws -> HarnessResult {
        let fields = try HarnessTimeline.requireObject(arguments, keys: tool.keys)
        let project = try Self.read(url)
        guard project.id == id else { throw HarnessError.invalid("The selected project changed. Restart the connection.") }
        switch tool {
        case .readTranscript:
            let transcript = project.transcript
            let words = transcript?.words ?? []
            let offset = try Self.integer(fields["offset"], default: 0, range: 0...Int.max)
            let limit = try Self.integer(fields["limit"], default: 200, range: 1...500)
            let first = min(offset, words.count)
            let end = first + min(words.count - first, limit)
            let cut = Set(project.edits.cutWordIds)
            let items: [JSONValue] = (first..<end).map { index in
                let word = words[index]
                return .object(["index": .number(Double(index)), "id": .string(word.id), "kind": .string(word.kind.rawValue),
                                "start": .number(word.start), "end": .number(word.end), "text": .string(project.edits.corrections[word.id] ?? word.text),
                                "cut": .bool(cut.contains(word.id))])
            }
            return .init(["words": .array(items), "total": .number(Double(words.count)), "nextOffset": end < words.count ? .number(Double(end)) : .null,
                          "language": transcript?.language.map(JSONValue.string) ?? .null])
        case .readClips:
            let indices = Dictionary(uniqueKeysWithValues: (project.transcript?.words ?? []).enumerated().map { ($0.element.id, $0.offset) })
            let clips: [JSONValue] = try project.edits.clips.map { clip in
                let parts = clip.playParts.compactMap { part -> ClipProposal.Part? in
                    guard let start = indices[part.startWordId], let end = indices[part.endWordId] else { return nil }
                    return .init(startWord: start, endWord: end)
                }
                return .object(["id": .string(clip.id), "title": clip.title.map(JSONValue.string) ?? .null, "selected": .bool(clip.selected),
                         "kind": .string(clip.kind?.rawValue ?? (clip.parts == nil ? "stretch" : "story")), "parts": try Self.json(parts),
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
            return .init(["projectId": .string(id), "clips": .array(clips), "footageSources": .array(sources)])
        case .readDecisions:
            guard case .string(let clipId) = fields["clipId"], let clip = project.edits.clips.first(where: { $0.id == clipId }) else {
                throw HarnessError.invalid("Choose a clip id from read_clips.")
            }
            let result = project.ai.results.first { $0.id == clip.aiResultId }
            let found = clip.aiClipIndex.flatMap { index in result.flatMap { $0.clips.indices.contains(index) ? $0.clips[index] : nil } }
            let tracks = project.music.map { JSONValue.object(["id": .string($0.id), "title": .string($0.title), "clipId": $0.clipId.map(JSONValue.string) ?? .null]) }
            return .init(["clipId": .string(clipId), "title": clip.title.map(JSONValue.string) ?? .null,
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
            return try await frames(times, project: project)
        case .proposeTimeline:
            let timelines = try HarnessTimeline.readSeries(arguments)
            let shared = try SharedResources.locate()
            let proposal = try HarnessProposal(timelines: timelines, project: project)
            var actions: [JSONValue] = []
            var free: [JSONValue] = []
            for index in timelines.indices {
                let review = try proposal.review(project, shared: shared, at: index)
                guard review.project != project || !review.pending.isEmpty else { throw HarnessError.invalid("The timeline doesn't change the project.") }
                let approval: JSONValue = .string("In VoxClip only; the app confirms the price for the open clip.")
                let position: JSONValue = .number(Double(index))
                for operation in review.pending {
                    switch operation.action {
                    case .music(let cue):
                        let price = try proposal.estimatedMusicPrice(in: review.project, shared: shared, at: index)
                        actions.append(.object(["kind": .string("generateMusic"), "prompt": .string(cue.picked.prompt),
                                                "price": price.map(JSONValue.string) ?? .null, "approval": approval, "timelineIndex": position]))
                    case .asset(let asset) where asset.kind == .illustration:
                        let quote = try ClipIllustrationQuote.load(shared: shared)
                        let amount = NSDecimalNumber(decimal: quote.usdPerImage).stringValue
                        actions.append(.object(["kind": .string("generateIllustration"), "prompt": .string(asset.text),
                                                "price": .string("$\(amount)"), "approval": approval, "timelineIndex": position]))
                    case .asset(let asset):
                        free.append(.object(["kind": .string("findSound"), "query": .string(asset.text), "timelineIndex": position]))
                    case .rewrite(_, let text):
                        actions.append(.object(["kind": .string("rewrite"), "text": .string(text), "price": .null,
                                                "approval": approval, "timelineIndex": position]))
                    default: break
                    }
                }
            }
            try HarnessInbox.stage(proposal, for: url)
            return .init(["proposal": try Self.json(proposal), "pricedActions": .array(actions), "freeActions": .array(free)])
        }
    }

    private func frames(_ times: [Double], project: Project) async throws -> HarnessResult {
        let media = project.media.source
        var candidates = [URL(fileURLWithPath: media.absolutePath)]
        if let relative = media.relativePath { candidates.append(url.deletingLastPathComponent().appendingPathComponent(relative).standardizedFileURL) }
        guard let source = candidates.first(where: { candidate in
            guard ["mp4", "mov", "m4v"].contains(candidate.pathExtension.lowercased()),
                  let info = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size == media.sizeBytes else { return false }
            return (try? JSONProjectStore.contentKey(for: candidate)) == media.contentKey
        }) else {
            throw HarnessError.invalid("The project's source video is missing. Relink it in VoxClip.")
        }
        let asset = AVURLAsset(url: source, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var images: [HarnessResult.Frame] = []
        for time in times {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000))
            let bytes = NSMutableData()
            guard let jpeg = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw HarnessError.invalid("Can't encode a preview frame.")
            }
            CGImageDestinationAddImage(jpeg, frame.image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
            guard CGImageDestinationFinalize(jpeg) else { throw HarnessError.invalid("Can't encode a preview frame.") }
            images.append(.init(requested: time, actual: frame.actualTime.seconds, jpeg: bytes.base64EncodedString()))
        }
        return .init(["frames": try Self.json(images.map { ["requested": $0.requested, "actual": $0.actual] })], images: images)
    }

    static func json(_ value: some Encodable) throws -> JSONValue {
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

struct HarnessResult {
    struct Frame: Encodable {
        let requested: Double
        let actual: Double
        let jpeg: String
    }

    let fields: [String: JSONValue]
    let images: [Frame]

    init(_ fields: [String: JSONValue], images: [Frame] = []) {
        self.fields = fields
        self.images = images
    }

    func writeCLI() throws {
        var result = fields
        if !images.isEmpty { result["frames"] = try HarnessProject.json(images) }
        try HarnessMCP.write(.object(result))
    }
}

struct HarnessProjectOptions: ParsableArguments {
    @Option(help: "Path to one saved .voxclip project.") var project: String
}

struct HarnessTranscript: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "transcript", abstract: "Read a page of a project's timed transcript as JSON.")
    @OptionGroup var scope: HarnessProjectOptions
    @Option var offset = 0
    @Option var limit = 200
    func run() async throws {
        try await HarnessProject(path: scope.project).call(.readTranscript, arguments: .object(["offset": .number(Double(offset)), "limit": .number(Double(limit))])).writeCLI()
    }
}

struct HarnessClips: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clips", abstract: "List a project's clips as JSON.")
    @OptionGroup var scope: HarnessProjectOptions
    func run() async throws {
        try await HarnessProject(path: scope.project).call(.readClips, arguments: .object([:])).writeCLI()
    }
}

struct HarnessDecisions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "decisions", abstract: "Read a clip's saved decisions as JSON.")
    @OptionGroup var scope: HarnessProjectOptions
    @Option(name: .customLong("clip")) var clipID: String
    func run() async throws {
        try await HarnessProject(path: scope.project).call(.readDecisions, arguments: .object(["clipId": .string(clipID)])).writeCLI()
    }
}

struct HarnessFrames: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "frames", abstract: "Read local JPEG thumbnails at source times as JSON.")
    @OptionGroup var scope: HarnessProjectOptions
    @Option(name: .customLong("time"), help: "Source seconds. Repeat up to four times.") var times: [Double]
    func run() async throws {
        try await HarnessProject(path: scope.project).call(.readFrames, arguments: .object(["times": .array(times.map(JSONValue.number))])).writeCLI()
    }
}

struct HarnessPropose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "propose-timeline", abstract: "Read a JSON timeline on stdin and stage it for review in VoxClip.")
    @OptionGroup var scope: HarnessProjectOptions
    func run() async throws {
        var bytes = Data()
        while let block = try FileHandle.standardInput.read(upToCount: 8192), !block.isEmpty {
            guard bytes.count + block.count <= HarnessInbox.maximumBytes else { throw HarnessError.invalid("This timeline proposal is too large.") }
            bytes.append(block)
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: bytes)
        try await HarnessProject(path: scope.project).call(.proposeTimeline, arguments: value).writeCLI()
    }
}
