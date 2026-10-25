import CryptoKit
import Foundation
import FoundationModels
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

enum FoundationModelsFixtures {
    static let available = ProcessInfo.processInfo.environment["VOXCLIP_SHARED_DIR"] != nil || root() != nil
    static let skipReason: Comment = "No shared/ directory was selected or found by walking from the test source."
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Envelope: Decodable {
        let schema: String
        let id: String
        let origin: String
        let sources: [String: String]
        let cases: [Case]
    }

    struct Case: Decodable, Sendable {
        struct Input: Decodable, Sendable {
            let request: Request?
            let connector: String?
            let options: Options?
            let connectorOptions: [String: Options]?
        }

        struct Expected: Decodable, Sendable {
            let canonical: Request?
            let request: Request?
            let connectors: [String: JSONValue]?
        }

        let id: String
        let kind: String
        let input: Input
        let expected: JSONValue
    }

    struct Request: Decodable, Sendable {
        let feature: LLMFeature
        let system: String
        let cachedBlock: String?
        let instruction: String
        let schemaName: String
        let schema: JSONValue
        let maxOutputTokens: Int
        let effort: Effort?
        let language: String?

        func value(timeout: Int, tag: String) -> LLMRequest {
            LLMRequest(feature: feature, system: system, cachedBlock: cachedBlock,
                       instruction: instruction, schemaName: schemaName, schema: schema,
                       maxOutputTokens: maxOutputTokens, effort: effort,
                       timeout: .seconds(timeout), language: language, tag: tag)
        }
    }

    struct Options: Decodable, Sendable {
        let macOSMajor: Int?
        let clipBudget: Int?
    }

    struct Rendering: Decodable, Sendable {
        struct Session: Decodable, Sendable {
            let fresh: Bool
            let instructions: String
        }

        struct Schema: Decodable, Sendable {
            let root: JSONValue
            let dependencies: [JSONValue]
        }

        let kind: String
        let model: String
        let timeoutSeconds: Int
        let session: Session
        let prompt: String
        let schema: Schema
        let options: [String: JSONValue]
        let language: String?
    }

    struct Argument: Sendable, CustomTestStringConvertible {
        let file: String
        let root: URL?
        let fixture: Case?
        let failure: String?

        var testDescription: String { "\(file)/\(fixture?.id ?? "corpus")" }
    }

    struct Catalog: Decodable {
        struct Policy: Decodable {
            struct Timeouts: Decodable {
                let test: Int
                let appleFoundation: Int
            }
            let timeoutsSeconds: Timeouts
        }
        let policy: Policy
    }

    static func root(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sourcePath: String = #filePath,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        if let override = environment["VOXCLIP_SHARED_DIR"] {
            guard !override.isEmpty else { return nil }
            let shared = URL(fileURLWithPath: override, isDirectory: true)
            return exists(shared) ? shared : nil
        }
        var directory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
        while true {
            let shared = directory.appendingPathComponent("shared", isDirectory: true)
            if exists(shared), exists(directory.appendingPathComponent("apps")) { return shared }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { return nil }
            directory = parent
        }
    }

    static func arguments(_ file: String) -> [Argument] {
        do {
            guard let root = root() else {
                throw Failure(description: "Missing shared/fixtures/llm; set VOXCLIP_SHARED_DIR to shared/.")
            }
            let data = try Data(contentsOf: root.appendingPathComponent("fixtures/llm/\(file).json"))
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schema == "voxclip-llm-fixtures/1", envelope.id == file,
                  envelope.origin == "voxclip", !envelope.cases.isEmpty,
                  Set(envelope.cases.map(\.id)).count == envelope.cases.count else {
                throw Failure(description: "Invalid fixture envelope or duplicate case IDs in \(file).")
            }
            for (path, expected) in envelope.sources {
                let text = try String(contentsOf: root.deletingLastPathComponent().appendingPathComponent(path), encoding: .utf8)
                let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                let actual = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
                guard actual == expected else {
                    throw Failure(description: "\(file): source hash mismatch for \(path).")
                }
            }
            let kind = file == "connector-requests" ? "connector-request" : "render-request"
            var selected: [Argument] = []
            for fixture in envelope.cases {
                guard fixture.kind == kind else {
                    throw Failure(description: "\(file)/\(fixture.id): unknown case kind \(fixture.kind).")
                }
                if kind == "connector-request" {
                    if fixture.input.connector == ConnectorID.appleFoundation.rawValue {
                        selected.append(Argument(file: file, root: root, fixture: fixture, failure: nil))
                    }
                } else {
                    let expected = try decode(Case.Expected.self, fixture.expected)
                    if expected.connectors?[ConnectorID.appleFoundation.rawValue] != nil {
                        selected.append(Argument(file: file, root: root, fixture: fixture, failure: nil))
                    }
                }
            }
            guard !selected.isEmpty else { throw Failure(description: "No Apple renderings in \(file).") }
            return selected
        } catch {
            return [Argument(file: file, root: nil, fixture: nil, failure: String(describing: error))]
        }
    }

    static func decode<Value: Decodable>(_ type: Value.Type, _ value: JSONValue) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    static func mapped(_ schema: GenerationSchema, name: String) throws -> JSONValue {
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(schema))
        return try mappedNode(encoded, root: encoded, name: name, depth: 0)
    }

    private static func mappedNode(_ value: JSONValue, root: JSONValue, name: String, depth: Int) throws -> JSONValue {
        guard depth < 64, case .object(let node) = value else {
            throw Failure(description: "Invalid or recursive SDK schema at \(name).")
        }
        if case .string(let reference) = node["$ref"] {
            let target: JSONValue
            if reference == "#" {
                target = root
            } else if reference.hasPrefix("#/$defs/"), case .object(let fields) = root,
                      case .object(let definitions) = fields["$defs"] {
                let key = String(reference.dropFirst("#/$defs/".count))
                    .replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                guard let definition = definitions[key] else { throw Failure(description: "Missing SDK schema reference \(reference).") }
                target = definition
            } else {
                throw Failure(description: "Unsupported SDK schema reference \(reference).")
            }
            return try mappedNode(target, root: root, name: name, depth: depth + 1)
        }
        guard case .string(let type) = node["type"] else { throw Failure(description: "Missing SDK schema type at \(name).") }
        switch type {
        case "object":
            guard case .string(let title) = node["title"], case .object(let properties) = node["properties"],
                  case .array(let required) = node["required"],
                  case .array(let order) = node["x-order"] ?? node["required"],
                  node["additionalProperties"] == .bool(false) else {
                throw Failure(description: "Invalid SDK object schema at \(name).")
            }
            let names = try order.map { value -> String in
                guard case .string(let property) = value else { throw Failure(description: "Invalid SDK property order.") }
                return property
            }
            let requiredNames = try required.map { value -> String in
                guard case .string(let property) = value else { throw Failure(description: "Invalid SDK required property.") }
                return property
            }
            guard names.count == properties.count, Set(names) == Set(properties.keys),
                  Set(requiredNames).count == requiredNames.count,
                  Set(requiredNames).isSubset(of: Set(names)) else {
                throw Failure(description: "SDK properties and required names disagree at \(name).")
            }
            let mapped = try names.map { property -> JSONValue in
                guard let schema = properties[property] else {
                    throw Failure(description: "Missing SDK property \(property).")
                }
                return try .object([
                    "name": .string(property),
                    "schema": mappedNode(schema, root: root, name: title + "_" + property, depth: depth + 1),
                    "isOptional": .bool(!required.contains(.string(property)))
                ])
            }
            return .object(["name": .string(title), "properties": .array(mapped)])
        case "array":
            guard let item = node["items"] else { throw Failure(description: "Missing SDK array item at \(name).") }
            return try .object([
                "arrayOf": mappedNode(item, root: root, name: name + "_item", depth: depth + 1),
                "maximumElements": node["maxItems"] ?? .null
            ])
        case "string":
            if let choices = node["enum"] {
                return .object(["name": .string(name), "anyOf": choices])
            }
            return .object(["type": .string("String")])
        case "integer": return .object(["type": .string("Int")])
        case "number": return .object(["type": .string("Double")])
        case "boolean": return .object(["type": .string("Bool")])
        default: throw Failure(description: "Unsupported SDK schema type \(type).")
        }
    }

    static func differences(_ actual: JSONValue, _ expected: JSONValue, path: String = "schema.root") -> [String] {
        switch (actual, expected) {
        case (.object(let actual), .object(let expected)):
            return Set(actual.keys).union(expected.keys).sorted().flatMap { key -> [String] in
                guard let actual = actual[key], let expected = expected[key] else { return ["\(path).\(key): field presence differs"] }
                return differences(actual, expected, path: "\(path).\(key)")
            }
        case (.array(let actual), .array(let expected)):
            guard actual.count == expected.count else { return ["\(path): array counts differ"] }
            return actual.indices.flatMap { differences(actual[$0], expected[$0], path: "\(path)[\($0)]") }
        default:
            return actual == expected ? [] : ["\(path): actual \(actual), expected \(expected)"]
        }
    }
}

actor FoundationModelsFixtureProbe {
    struct Configuration: Sendable {
        let instructions: String
        let prompt: String
        let schema: JSONValue
        let options: GenerationOptions
        let maxOutput: Int
        let request: LLMRequest
    }

    private(set) var configurations: [Configuration] = []

    func generate(_ request: LLMRequest, schema: GenerationSchema, maxOutput: Int) throws -> String {
        configurations.append(try Configuration(
            instructions: request.system, prompt: FoundationModelsRuntime.prompt(for: request),
            schema: FoundationModelsFixtures.mapped(schema, name: request.schemaName),
            options: FoundationModelsRuntime.options(maxOutput: maxOutput), maxOutput: maxOutput, request: request
        ))
        return "{}"
    }
}

@Suite struct FoundationModelsFixtureTests {
    @Test(.enabled(if: FoundationModelsFixtures.available, FoundationModelsFixtures.skipReason),
          arguments: FoundationModelsFixtures.arguments("clip-finder-requests"))
    func clipFinderLogicalRequests(_ argument: FoundationModelsFixtures.Argument) async throws {
        try await compare(argument)
    }

    @Test(.enabled(if: FoundationModelsFixtures.available, FoundationModelsFixtures.skipReason),
          arguments: FoundationModelsFixtures.arguments("ai-tighten-requests"))
    func tightenLogicalRequests(_ argument: FoundationModelsFixtures.Argument) async throws {
        try await compare(argument)
    }

    @Test(.enabled(if: FoundationModelsFixtures.available, FoundationModelsFixtures.skipReason),
          arguments: FoundationModelsFixtures.arguments("connector-requests"))
    func connectorLogicalRequests(_ argument: FoundationModelsFixtures.Argument) async throws {
        try await compare(argument)
    }

    @Test func sharedDirectoryOverrideWins() {
        let override = "/fixture-override/shared"
        let actual = FoundationModelsFixtures.root(
            environment: ["VOXCLIP_SHARED_DIR": override], sourcePath: "/worktree/apps/macos/Tests/fixture.swift",
            exists: { [override, "/worktree/shared", "/worktree/apps"].contains($0.path) }
        )
        #expect(actual?.path == override)
    }

    @Test func missingOverrideDoesNotSilentlyUseWorktree() {
        let actual = FoundationModelsFixtures.root(
            environment: ["VOXCLIP_SHARED_DIR": "/missing/shared"], sourcePath: "/worktree/apps/macos/Tests/fixture.swift",
            exists: { ["/worktree/shared", "/worktree/apps"].contains($0.path) }
        )
        #expect(actual == nil)
    }

    @Test func worktreeFallbackWalksFromTestSource() {
        let actual = FoundationModelsFixtures.root(
            environment: [:], sourcePath: "/worktree/apps/macos/Tests/fixture.swift",
            exists: { ["/worktree/shared", "/worktree/apps"].contains($0.path) }
        )
        #expect(actual?.path == "/worktree/shared")
    }

    @Test func emptyOverrideDoesNotSilentlyUseWorktree() {
        let actual = FoundationModelsFixtures.root(
            environment: ["VOXCLIP_SHARED_DIR": ""], sourcePath: "/worktree/apps/macos/Tests/fixture.swift",
            exists: { ["/worktree/shared", "/worktree/apps"].contains($0.path) }
        )
        #expect(actual == nil)
    }

    @Test func missingSharedDirectoryCannotBeDiscovered() {
        #expect(FoundationModelsFixtures.root(environment: [:], sourcePath: "/missing/fixture.swift", exists: { _ in false }) == nil)
    }

    private func compare(_ argument: FoundationModelsFixtures.Argument) async throws {
        let label = argument.testDescription
        let fixture = try #require(argument.fixture, "\(label): \(argument.failure ?? "Missing fixture.")")
        let root = try #require(argument.root, "\(label): Missing fixture root.")
        let canonical: FoundationModelsFixtures.Request
        let rendering: FoundationModelsFixtures.Rendering
        let options: FoundationModelsFixtures.Options
        if fixture.kind == "connector-request" {
            canonical = try #require(fixture.input.request, "\(label): Missing input.request.")
            rendering = try FoundationModelsFixtures.decode(FoundationModelsFixtures.Rendering.self, fixture.expected)
            options = try #require(fixture.input.options, "\(label): Missing input.options.")
        } else {
            let expected = try FoundationModelsFixtures.decode(FoundationModelsFixtures.Case.Expected.self, fixture.expected)
            canonical = try #require(expected.canonical ?? expected.request, "\(label): Missing canonical request.")
            let apple = try #require(expected.connectors?[ConnectorID.appleFoundation.rawValue], "\(label): Missing Apple rendering.")
            rendering = try FoundationModelsFixtures.decode(FoundationModelsFixtures.Rendering.self, apple)
            options = try #require(fixture.input.connectorOptions?[ConnectorID.appleFoundation.rawValue], "\(label): Missing Apple options.")
        }
        let catalog = try LLMCatalog(shared: SharedResources(root: root))
        let request = canonical.value(timeout: Int(catalog.timeout(for: .appleFoundation, feature: canonical.feature).components.seconds), tag: label)
        let probe = FoundationModelsFixtureProbe()
        let runtime = FoundationModelsRuntime(
            status: { .ready }, contextSize: { 8_192 }, supportsLocale: { _ in true },
            tokenCount: { _ in throw FoundationModelsFixtures.Failure(description: "Unexpected tokenizer call.") },
            generate: { request, schema, maxOutput in
                try await probe.generate(request, schema: schema, maxOutput: maxOutput)
            },
            sleep: { _ in throw FoundationModelsFixtures.Failure(description: "Unexpected retry.") }
        )
        let connector = FoundationModelsConnector(runtime: runtime, shared: SharedResources(root: root))
        let result = try await connector.send(request, model: rendering.model, clipBudget: options.clipBudget)
        let configurations = await probe.configurations
        #expect(configurations.count == 1, "\(label): A window must generate exactly once in a fresh session.")
        let configuration = try #require(configurations.first, "\(label): Missing generation configuration.")
        #expect(rendering.kind == "logical", "\(label): Expected a logical Apple request.")
        #expect(rendering.session.fresh, "\(label): Apple windows must use fresh sessions.")
        #expect(Array(configuration.instructions.utf8) == Array(rendering.session.instructions.utf8), "\(label): Session instructions differ.")
        #expect(Array(configuration.prompt.utf8) == Array(rendering.prompt.utf8), "\(label): Prompt bytes differ.")
        let schemaDifferences = FoundationModelsFixtures.differences(configuration.schema, rendering.schema.root)
        #expect(schemaDifferences.isEmpty, "\(label): Mapped schema differs: \(schemaDifferences.joined(separator: "; "))")
        #expect(rendering.schema.dependencies.isEmpty, "\(label): Canonical schemas must not require dependencies.")
        #expect(configuration.request == request, "\(label): Connector changed the canonical request.")
        #expect(configuration.request.timeout == .seconds(rendering.timeoutSeconds), "\(label): Timeout differs.")
        #expect(configuration.request.language == rendering.language, "\(label): Language differs.")
        #expect(result.model == rendering.model, "\(label): Model differs.")
        #expect(result.stop == .complete, "\(label): Stub completion was not complete.")
        let samplingKey = options.macOSMajor == 26 ? "sampling" : "samplingMode"
        #expect(Set(rendering.options.keys) == [samplingKey, "maximumResponseTokens"], "\(label): Generation option fields differ.")
        #expect(rendering.options[samplingKey] == .string("greedy"), "\(label): Sampling must be greedy.")
        let cap = try #require(rendering.options["maximumResponseTokens"], "\(label): Missing output cap.")
        #expect(cap == .number(Double(configuration.maxOutput)), "\(label): Connector output cap differs.")
        #expect(configuration.options == GenerationOptions(samplingMode: .greedy, maximumResponseTokens: configuration.maxOutput),
                "\(label): Actual GenerationOptions differ.")
    }
}
