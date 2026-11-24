import Foundation

public struct PostingClip: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let words: String
    public let duration: Double

    public init(id: String, title: String, words: String, duration: Double) {
        self.id = id
        self.title = AIText.prefix(title, utf16: 200)
        self.words = AIText.prefix(words, utf16: 2_500)
        self.duration = duration.isFinite && duration > 0 ? min(duration.rounded(), 1_000_000) : 0
    }
}

public struct PostingPlan: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let clip: Int
        public let when: String
        public let posts: Posts
        public var id: Int { clip }
    }

    public struct Posts: Codable, Equatable, Sendable {
        public let x: Post
        public let linkedin: Post
        public let voxconvo: Post

        public subscript(_ destination: ShareDestination) -> Post {
            switch destination {
            case .x: x
            case .linkedIn: linkedin
            case .voxConvo: voxconvo
            }
        }
    }

    public struct Post: Codable, Equatable, Sendable {
        public let text: String
        public let hashtags: [String]
        public var copyText: String { hashtags.isEmpty ? text : text + "\n\n" + hashtags.joined(separator: " ") }
    }

    public let entries: [Entry]
}

public struct PostingHelpService: Sendable {
    public static let maxClips = 12
    private let system: String
    private let schemaName: String
    private let schema: JSONValue
    private let catalog: LLMCatalog
    private let runner: LLMRunner
    private let archive: PostingHelpArchive

    public init(shared: SharedResources, catalog: LLMCatalog, runner: LLMRunner, archive: PostingHelpArchive) throws {
        let data = try Data(contentsOf: shared.root.appendingPathComponent("prompts/posting-help.json"))
        let prompt = try JSONDecoder().decode(JSONValue.self, from: data)
        let schema = prompt[ai: "output"][ai: "schema"]
        guard prompt[ai: "schemaVersion"].aiInt == 1, let system = prompt[ai: "system"].aiString,
              let name = prompt[ai: "output"][ai: "schemaName"].aiString,
              CanonicalResponseParser.validateSchemaSubset(schema) else { throw VoxClipError.sharedResourcesMissing }
        self.system = system; self.schemaName = name; self.schema = schema
        self.catalog = catalog; self.runner = runner; self.archive = archive
    }

    public func restore(projectID: String, clips: [PostingClip]) async throws -> PostingPlan? {
        let key = try batchKey(projectID: projectID, clips: clips)
        for completion in try await archive.replies(for: key) {
            guard let value = try? CanonicalResponseParser.validate(completion, schema: schema), value.droppedItems == 0,
                  let plan = try? checked(value.object, clipCount: clips.count) else { continue }
            return plan
        }
        return nil
    }

    public func ask(projectID: String, clips: [PostingClip], connector: any LLMConnector, model: String) async throws -> PostingPlan {
        guard [.anthropic, .claudeCode].contains(connector.id) else { throw LLMError.unavailable(reason: "Choose Claude in AI settings.") }
        if let existing = try await restore(projectID: projectID, clips: clips) { return existing }
        let key = try batchKey(projectID: projectID, clips: clips)
        let items: [JSONValue] = clips.enumerated().map { index, clip in
            .object(["clip": .number(Double(index + 1)), "title": .string(clip.title), "words": .string(clip.words), "durationSeconds": .number(clip.duration)])
        }
        let payload = JSONValue.object(["clips": .array(items), "localTimeZone": .string(TimeZone.current.identifier)])
        let request = LLMRequest(feature: .postingHelp, system: system,
            instruction: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self),
            schemaName: schemaName, schema: schema, maxOutputTokens: 8_192, effort: .decision,
            timeout: catalog.timeout(for: connector.id, feature: .postingHelp), tag: "posting-help")
        let result = try await runner.run(request, on: connector, model: model) { reply in
            try await archive.keep(reply, for: key)
        }
        guard result.droppedItems == 0 else { throw LLMError.invalidOutput(reason: "Some posting drafts didn't come back.") }
        return try checked(result.object, clipCount: clips.count)
    }

    private func batchKey(projectID: String, clips: [PostingClip]) throws -> String {
        guard (1...Self.maxClips).contains(clips.count), Set(clips.map(\.id)).count == clips.count else {
            throw LLMError.unavailable(reason: "Export 1 to \(Self.maxClips) finished clips first.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = Data(projectID.utf8); bytes.append(0); bytes.append(try encoder.encode(clips))
        return SpeechSHA256.hex(bytes)
    }

    private func checked(_ object: JSONValue, clipCount: Int) throws -> PostingPlan {
        let invalid = LLMError.invalidOutput(reason: "Claude didn't return a complete posting plan.")
        guard let plan = try? JSONDecoder().decode(PostingPlan.self, from: JSONEncoder().encode(object)),
              plan.entries.count == clipCount, Set(plan.entries.map(\.clip)) == Set(1...clipCount) else { throw invalid }
        for entry in plan.entries {
            guard !AIText.trim(entry.when).isEmpty, entry.when.utf16.count <= 200 else { throw invalid }
            for destination in ShareDestination.allCases {
                let post = entry.posts[destination]
                guard !AIText.trim(post.text).isEmpty, post.hashtags.count <= 4, post.hashtags.allSatisfy(validHashtag) else { throw invalid }
                let length = switch destination {
                case .x: try SharePostText.xWeight(post.copyText)
                case .linkedIn: SharePostText.linkedInLength(post.copyText)
                case .voxConvo: SharePostText.voxConvoLength(post.copyText)
                }
                guard length <= (try SharePostText.limit(destination)) else { throw invalid }
            }
        }
        return plan
    }

    private func validHashtag(_ text: String) -> Bool {
        guard text.first == "#", (2...80).contains(text.utf16.count) else { return false }
        return text.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

public actor PostingHelpArchive {
    private struct Reply: Codable, Sendable {
        let id: UUID
        let date: Date
        let text: String?
        let object: JSONValue?
        let model: String
        let usage: LLMUsage?
        let complete: Bool

        init(_ completion: RawCompletion) {
            id = UUID(); date = Date(); text = completion.text; object = completion.object
            model = completion.model; usage = completion.usage; complete = completion.stop == .complete
        }

        var completion: RawCompletion {
            RawCompletion(text: text, object: object, model: model, stop: complete ? .complete : .truncated, usage: usage)
        }
    }

    private let root: URL
    private var unsaved: [String: [Reply]] = [:]

    public init(root: URL) { self.root = root }

    fileprivate func keep(_ completion: RawCompletion, for key: String) throws {
        unsaved[key, default: []].append(Reply(completion))
        try flush(key)
    }

    fileprivate func replies(for key: String) throws -> [RawCompletion] {
        try flush(key)
        let folder = root.appendingPathComponent(key, isDirectory: true)
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return [] }
        return try files.filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(Reply.self, from: Data(contentsOf: $0))
        }.sorted { $0.date > $1.date }.map(\.completion)
    }

    private func flush(_ key: String) throws {
        guard let replies = unsaved[key], !replies.isEmpty else { return }
        let folder = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for reply in replies {
            let file = folder.appendingPathComponent(reply.id.uuidString).appendingPathExtension("json")
            try JSONEncoder().encode(reply).write(to: file, options: .atomic)
        }
        unsaved[key] = nil
    }
}
