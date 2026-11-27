import ArgumentParser
import Foundation
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
        if tool == .proposeTimeline, case .object(let fields) = arguments, fields["revises"] != nil {
            throw HarnessError.invalid("Revising is only for the in-app chat.")
        }
        _ = try HarnessTimeline.requireObject(arguments, keys: tool.keys)
        let project = try Self.read(url)
        guard project.id == id else { throw HarnessError.invalid("The selected project changed. Restart the connection.") }
        let result = try await HarnessTools.call(tool, arguments: arguments, project: project, shared: nil, projectURL: url,
                                               decodeFrames: HarnessFrameDecoder.decode, chat: false)
        if let proposal = result.proposal { try HarnessInbox.stage(proposal, for: url) }
        return result
    }
}

extension HarnessResult {
    func writeCLI() throws {
        var result = fields
        if !images.isEmpty { result["frames"] = try HarnessTools.json(images) }
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
    @Option var recordingKey: String?
    func run() async throws {
        var fields: [String: JSONValue] = ["offset": .number(Double(offset)), "limit": .number(Double(limit))]
        fields["recordingKey"] = recordingKey.map(JSONValue.string)
        try await HarnessProject(path: scope.project).call(.readTranscript, arguments: .object(fields)).writeCLI()
    }
}

struct HarnessClips: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clips", abstract: "List a project's clips as JSON.")
    @OptionGroup var scope: HarnessProjectOptions
    func run() async throws {
        try await HarnessProject(path: scope.project).call(.readClips, arguments: .object([:])).writeCLI()
    }
}

struct HarnessTakes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "takes", abstract: "Read matched takes across recordings as JSON.")
    @OptionGroup var scope: HarnessProjectOptions
    func run() async throws {
        try await HarnessProject(path: scope.project).call(.readTakes, arguments: .object([:])).writeCLI()
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
