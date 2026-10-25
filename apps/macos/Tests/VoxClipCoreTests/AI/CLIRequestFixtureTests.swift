import Foundation
import Testing
@testable import VoxClipCore

@Suite("CLI shared request goldens", .enabled(if: aiSharedFixturesAvailable, aiSharedFixturesSkipReason))
struct CLIRequestFixtureTests {
    @Test(arguments: ["clip-finder-requests", "ai-tighten-requests", "connector-requests"])
    func everyCLIRenderingMatchesGolden(_ file: String) async throws {
        let shared = try #require(CLIGoldenFixtures.sharedRoot())
        let document = try JSONDecoder().decode(CLIGoldenDocument.self,
            from: Data(contentsOf: shared.appendingPathComponent("fixtures/llm/\(file).json")))
        try #require(!document.cases.isEmpty, "\(file): empty required fixture cases")
        #expect(document.schema == "voxclip-llm-fixtures/1", "\(file): envelope schema")
        #expect(document.id == file, "\(file): envelope id")
        #expect(Set(document.cases.map(\.id)).count == document.cases.count, "\(file): duplicate case ids")
        for (source, hash) in document.sources {
            let relative = try #require(source.hasPrefix("shared/") ? String(source.dropFirst(7)) : nil)
            let text = try String(contentsOf: shared.appendingPathComponent(relative), encoding: .utf8)
                .replacingOccurrences(of: "\r\n", with: "\n")
            #expect(AIHash.sha256(text) == hash, "\(file): stale source \(source)")
        }
        let catalog = try LLMCatalog(shared: SharedResources(root: shared))
        var count = 0
        for fixture in document.cases {
            let input = try #require(fixture.input.goldenObject, "\(file):\(fixture.id): input")
            let expected = try #require(fixture.expected.goldenObject, "\(file):\(fixture.id): expected")
            switch fixture.kind {
            case "render-request":
                if expected["error"] != nil {
                    #expect(expected["connectors"] == nil, "\(file):\(fixture.id): gated request cannot spawn")
                    continue
                }
                let canonical = try #require(expected["canonical"] ?? expected["request"], "\(file):\(fixture.id): request")
                let connectors = try #require(expected["connectors"]?.goldenObject, "\(file):\(fixture.id): connectors")
                for id in [ConnectorID.claudeCode, .codex] {
                    guard let rendering = connectors[id.rawValue] else { continue }
                    try await verify(canonical, id: id, options: input["connectorOptions"]?.goldenObject?[id.rawValue],
                                     expected: rendering, catalog: catalog, label: "\(file):\(fixture.id):\(id.rawValue)")
                    count += 1
                }
            case "connector-request":
                guard let name = input["connector"]?.goldenString,
                      let id = ConnectorID(rawValue: name), id == .claudeCode || id == .codex else { continue }
                try await verify(try #require(input["request"]), id: id, options: input["options"],
                                 expected: fixture.expected, catalog: catalog, label: "\(file):\(fixture.id):\(name)")
                count += 1
            default: Issue.record("\(file):\(fixture.id): unknown kind \(fixture.kind)")
            }
        }
        #expect(count > 0, "\(file): no CLI renderings verified")
        print("CLI shared fixtures: \(file): \(count) CLI renderings.")
    }

    private func verify(_ canonical: JSONValue, id: ConnectorID, options: JSONValue?, expected: JSONValue,
                        catalog: LLMCatalog, label: String) async throws {
        let rendering = try #require(expected.goldenObject, "\(label): rendering")
        #expect(rendering["kind"] == .string("cli"), "\(label): kind")
        let model = try #require(rendering["model"]?.goldenString, "\(label): model")
        let seconds = try #require(rendering["timeoutSeconds"]?.goldenInt, "\(label): timeout")
        let request = try JSONDecoder().decode(CLIGoldenCanonical.self, from: JSONEncoder().encode(canonical))
        let directory = try CLITestDirectory()
        let executable = directory.url.appendingPathComponent(try #require(rendering["executable"]?.goldenString))
        try Data("#!/bin/sh\nexit 97\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let processRunner = CLIGoldenRunner(id: id, catalog: catalog, options: options?.goldenObject ?? [:], model: model)
        let connector = CLIConnector(id: id, runner: processRunner, catalog: catalog,
            log: RedactingLogger(homeDirectory: "/synthetic/home"), executable: executable, environment: [:],
            temporaryDirectory: directory.url, loginShellPATH: "/synthetic/path")
        if id == .codex, model != "default" { _ = try await connector.models(refresh: true) }
        do {
            _ = try await connector.send(LLMRequest(feature: request.feature, system: request.system,
                cachedBlock: request.cachedBlock, instruction: request.instruction, schemaName: request.schemaName,
                schema: request.schema, maxOutputTokens: request.maxOutputTokens, effort: request.effort,
                timeout: .seconds(seconds), language: request.language, tag: label), model: model)
        } catch {
            Issue.record("\(label): real CLI connector failed: \(error)")
            throw error
        }
        let generations = await processRunner.generations
        #expect(generations.count == 1, "\(label): generation count")
        let observed = try #require(generations.first, "\(label): missing generation")
        let cwd = observed.request.workingDirectory
        let io = cwd.deletingLastPathComponent().appendingPathComponent("io")
        func substituted(_ text: String) -> String {
            text.replacingOccurrences(of: "<cwd>", with: cwd.path).replacingOccurrences(of: "<io>", with: io.path)
        }
        let argumentValues = try #require(rendering["argv"]?.goldenArray, "\(label): argv")
        let arguments = try argumentValues.map { value in
            try #require(value.goldenString, "\(label): argv string")
        }.map(substituted)
        #expect(observed.request.arguments.map { Data($0.utf8) } == arguments.map { Data($0.utf8) }, "\(label): argv")
        #expect(observed.request.executable == executable, "\(label): executable")
        #expect(cwd.path == substituted(try #require(rendering["cwd"]?.goldenString)), "\(label): cwd")
        #expect(observed.request.stdin == Data(try #require(rendering["stdin"]?.goldenString).utf8), "\(label): stdin UTF-8")
        #expect(observed.request.timeout == .seconds(seconds), "\(label): timeout")
        let files = try #require(rendering["files"]?.goldenObject, "\(label): files")
        var expectedFiles: [String: Data] = [:]
        for (path, content) in files {
            expectedFiles[substituted(path)] = Data(try #require(content.goldenString).utf8)
        }
        #expect(observed.files == expectedFiles, "\(label): compact schema files without trailing newline")
        #expect(!FileManager.default.fileExists(atPath: cwd.deletingLastPathComponent().path), "\(label): workspace cleanup")
    }
}

private enum CLIGoldenFixtures {
    static func sharedRoot() -> URL? { try? aiGoldenSharedRoot() }
}

private struct CLIGoldenDocument: Decodable {
    let schema: String
    let id: String
    let sources: [String: String]
    let cases: [CLIGoldenCase]
}

private struct CLIGoldenCase: Decodable {
    let id: String
    let kind: String
    let input: JSONValue
    let expected: JSONValue
}

private struct CLIGoldenCanonical: Decodable {
    let feature: LLMFeature
    let system: String
    let cachedBlock: String?
    let instruction: String
    let schemaName: String
    let schema: JSONValue
    let maxOutputTokens: Int
    let effort: Effort?
    let language: String?
}

private struct CLIGoldenObserved: Sendable {
    let request: ProcessRequest
    let files: [String: Data]
}

private actor CLIGoldenRunner: ProcessRunner {
    let id: ConnectorID
    let flags: [String]
    let features: [JSONValue]
    let model: String
    let efforts: [JSONValue]
    var generations: [CLIGoldenObserved] = []

    init(id: ConnectorID, catalog: LLMCatalog, options: [String: JSONValue], model: String) {
        self.id = id
        self.model = model
        let provider = catalog.document.goldenObject?["connectors"]?.goldenArray?.compactMap(\.goldenObject)
            .first { $0["id"] == .string(id.rawValue) }
        let cli = provider?["cli"]?.goldenObject ?? [:]
        let help = cli["detect"]?.goldenObject?["help"]?.goldenObject ?? [:]
        flags = (options["supportedFlags"]?.goldenArray ??
            ((help["requiredFlags"]?.goldenArray ?? []) + (help["optionalFlags"]?.goldenArray ?? []))).compactMap(\.goldenString)
        features = options["features"]?.goldenArray ?? cli["disableFeatures"]?.goldenArray ?? []
        efforts = options["supportedEfforts"]?.goldenArray ?? []
    }

    func run(_ request: ProcessRequest) throws -> ProcessResult {
        func result(_ text: String) -> ProcessResult { ProcessResult(exitCode: 0, stdout: Data(text.utf8), stderr: Data()) }
        if request.arguments == ["--version"] { return result(id == .claudeCode ? "2.1.309" : "codex-cli 0.163.0") }
        if request.arguments.contains("--help") { return result(flags.joined(separator: "\n")) }
        if request.arguments == ["features", "list"] {
            return result(features.compactMap { value in
                if let name = value.goldenString { return "\(name) stable true" }
                guard let feature = value.goldenObject, let name = feature["name"]?.goldenString else { return nil }
                return "\(name) \(feature["stage"]?.goldenString ?? "stable") true"
            }.joined(separator: "\n"))
        }
        if request.arguments == ["auth", "status", "--json"] { return result(#"{"loggedIn":true,"authMethod":"oauth"}"#) }
        if request.arguments == ["login", "status"] { return result("Logged in using ChatGPT") }
        if request.arguments.first == "app-server" {
            let response: JSONValue = .object(["id": .number(2), "result": .object(["data": .array([
                .object(["id": .string(model), "displayName": .string(model), "supportedReasoningEfforts": .array(
                    efforts.map { .object(["reasoningEffort": $0]) })])])])])
            return ProcessResult(exitCode: 0, stdout: try JSONEncoder().encode(response), stderr: Data())
        }
        guard request.arguments.first == "-p" || request.arguments.first == "exec" else {
            throw LLMError.cliFailed("Unexpected fake CLI invocation.")
        }
        let io = request.workingDirectory.deletingLastPathComponent().appendingPathComponent("io")
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: io.path) {
            let file = io.appendingPathComponent(name)
            files[file.path] = try Data(contentsOf: file)
        }
        generations.append(CLIGoldenObserved(request: request, files: files))
        return result(id == .claudeCode ? #"{"type":"result","is_error":false,"structured_output":{"ok":true}}"# :
            #"{"type":"item.completed","item":{"type":"agent_message","text":"{\"ok\":true}"}}"# + "\n" + #"{"type":"turn.completed"}"#)
    }
}

private extension JSONValue {
    var goldenObject: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var goldenArray: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var goldenString: String? { if case .string(let value) = self { value } else { nil } }
    var goldenInt: Int? { if case .number(let value) = self { Int(exactly: value) } else { nil } }
}
