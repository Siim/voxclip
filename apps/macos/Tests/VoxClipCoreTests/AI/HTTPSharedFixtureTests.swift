import Foundation
import Testing
@testable import VoxClipCore

private enum HTTPSharedFixtures {
    static let requestFiles = ["clip-finder-requests", "ai-tighten-requests"]

    static var root: URL? { try? aiGoldenSharedRoot() }

    static func cases(_ file: String) throws -> [JSONValue] {
        let shared = try #require(root)
        let data = try Data(contentsOf: shared.appendingPathComponent("fixtures/llm/\(file).json"))
        let document = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(document[ai: "schema"].aiString == "voxclip-llm-fixtures/1")
        #expect(document[ai: "id"].aiString == file)
        let cases = try #require(document[ai: "cases"].aiArray.isEmpty ? nil : document[ai: "cases"].aiArray)
        let identifiers = try cases.map { try #require($0[ai: "id"].aiString) }
        #expect(Set(identifiers).count == cases.count)
        return cases
    }

    static func request(_ value: JSONValue, catalog: LLMCatalog, connector: ConnectorID, label: String) throws -> LLMRequest {
        let featureName = try #require(value[ai: "feature"].aiString)
        let feature = try #require(LLMFeature(rawValue: featureName))
        let effort = try value[ai: "effort"].aiString.map { try #require(Effort(rawValue: $0)) }
        return LLMRequest(
            feature: feature,
            system: try #require(value[ai: "system"].aiString),
            cachedBlock: value[ai: "cachedBlock"].aiString,
            instruction: try #require(value[ai: "instruction"].aiString),
            schemaName: try #require(value[ai: "schemaName"].aiString),
            schema: value[ai: "schema"],
            maxOutputTokens: try #require(value[ai: "maxOutputTokens"].aiInt),
            effort: effort,
            timeout: catalog.timeout(for: connector, feature: feature),
            language: value[ai: "language"].aiString,
            tag: label
        )
    }

    static func differences(_ actual: JSONValue, _ expected: JSONValue, path: String = "body") -> [String] {
        switch (actual, expected) {
        case (.object(let actualObject), .object(let expectedObject)):
            let missing = Set(expectedObject.keys).subtracting(actualObject.keys).sorted().map { "\(path).\($0): missing" }
            let extra = Set(actualObject.keys).subtracting(expectedObject.keys).sorted().map { "\(path).\($0): unexpected" }
            return missing + extra + Set(actualObject.keys).intersection(expectedObject.keys).sorted().flatMap {
                differences(actualObject[$0]!, expectedObject[$0]!, path: "\(path).\($0)")
            }
        case (.array(let actualArray), .array(let expectedArray)):
            let lengths = actualArray.count == expectedArray.count ? [] : ["\(path): array length \(actualArray.count), expected \(expectedArray.count)"]
            return lengths + zip(actualArray, expectedArray).enumerated().flatMap {
                differences($0.element.0, $0.element.1, path: "\(path)[\($0.offset)]")
            }
        case (.string(let actualString), .string(let expectedString)):
            let actualBytes = Array(actualString.utf8)
            let expectedBytes = Array(expectedString.utf8)
            guard actualBytes != expectedBytes else { return [] }
            let first = zip(actualBytes, expectedBytes).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(actualBytes.count, expectedBytes.count)
            return ["\(path): UTF-8 mismatch at byte \(first), lengths \(actualBytes.count)/\(expectedBytes.count)"]
        default:
            return actual == expected ? [] : ["\(path): value \(actual), expected \(expected)"]
        }
    }

    static func render(_ canonical: JSONValue, connector id: ConnectorID, options: JSONValue, expected: JSONValue, label: String) async throws {
        #expect(expected[ai: "kind"].aiString == "http", "\(label): expected HTTP rendering")
        let allowedOptions: Set<String> = ["model", "baseUrl", "modelContext", "capabilities", "thinkingValues", "serverSideFallback", "structuredOutputsSupported", "effortSupported"]
        let unknownOptions = Set(options.aiObject?.keys.map { $0 } ?? []).subtracting(allowedOptions)
        #expect(unknownOptions.isEmpty, "\(label): unhandled connector options \(unknownOptions)")
        let catalog = try HTTPFixtures.catalog()
        let model = try #require(options[ai: "model"].aiString ?? catalog.connector(id)[ai: "defaultModel"].aiString)
        var replies: [HTTPReply] = []
        let refreshCapabilities = id == .anthropic && (options[ai: "structuredOutputsSupported"] != .null || options[ai: "effortSupported"] != .null)
        if refreshCapabilities {
            var capabilities: [String: JSONValue] = [:]
            if options[ai: "structuredOutputsSupported"] != .null {
                capabilities["structured_outputs"] = .object(["supported": options[ai: "structuredOutputsSupported"]])
            }
            if options[ai: "effortSupported"] != .null {
                capabilities["effort"] = .object(["supported": options[ai: "effortSupported"]])
            }
            let list = JSONValue.object(["data": .array([.object(["id": .string(model), "capabilities": .object(capabilities)])]), "has_more": .bool(false)])
            replies.append(.json(try list.aiCompact()))
        }
        if id == .ollama {
            var details: [String: JSONValue] = ["model_info": .object(["fixture.context_length": options[ai: "modelContext"] == .null ? .number(32768) : options[ai: "modelContext"]])]
            if options[ai: "capabilities"] != .null { details["capabilities"] = options[ai: "capabilities"] }
            if options[ai: "thinkingValues"] != .null { details["thinking"] = .object(["values": options[ai: "thinkingValues"]]) }
            replies.append(.json(try JSONValue.object(details).aiCompact()))
        } else if id == .lmstudio {
            replies += try HTTPFixtures.localDetails(id)
        }
        let rejectBeta = id == .anthropic && options[ai: "serverSideFallback"].aiBool == false
        if rejectBeta {
            replies.append(.json(#"{"error":{"type":"invalid_request_error","message":"Unexpected anthropic-beta value"}}"#, status: 400))
            replies.append(try HTTPFixtures.success(id))
        }
        replies.append(try HTTPFixtures.success(id))
        let baseURL = try options[ai: "baseUrl"].aiString.map { try #require(URL(string: $0)) }
        let harness = try HTTPHarness(id, replies: replies, key: "<key>", baseURL: baseURL)
        defer { harness.finish() }
        let request = try request(canonical, catalog: catalog, connector: id, label: label)
        if refreshCapabilities { _ = try await harness.connector.models(refresh: true) }
        if rejectBeta { _ = try await harness.connector.send(request, model: model) }
        let completion = try await harness.connector.send(request, model: model)
        let captured = try #require(HTTPStubProtocol.requests.last)
        #expect(completion.model == expected[ai: "model"].aiString, "\(label): answering model")
        #expect(captured.request.httpMethod == expected[ai: "method"].aiString, "\(label): method")
        #expect(captured.request.url?.absoluteString == expected[ai: "url"].aiString, "\(label): URL")
        #expect(captured.request.timeoutInterval == expected[ai: "timeoutSeconds"].aiDouble, "\(label): timeout")
        #expect(captured.request.value(forHTTPHeaderField: "User-Agent") == "VoxClip/9.8.7 (macOS)", "\(label): platform User-Agent")
        if let contentLength = captured.request.value(forHTTPHeaderField: "Content-Length") {
            #expect(Int(contentLength) == captured.body.count, "\(label): URLSession transport Content-Length")
        }
        let actualHeaders = Dictionary(uniqueKeysWithValues: (captured.request.allHTTPHeaderFields ?? [:]).filter { !["user-agent", "content-length"].contains($0.key.lowercased()) }.map { ($0.key.lowercased(), JSONValue.string($0.value)) })
        let expectedHeaders = Dictionary(uniqueKeysWithValues: (try #require(expected[ai: "headers"].aiObject)).map { ($0.key.lowercased(), $0.value) })
        let headerDifferences = differences(.object(actualHeaders), .object(expectedHeaders), path: "headers")
        #expect(headerDifferences.isEmpty, "\(label): \(headerDifferences.joined(separator: "; "))")
        let bodyDifferences = try differences(captured.json(), expected[ai: "body"])
        #expect(bodyDifferences.isEmpty, "\(label): \(bodyDifferences.joined(separator: "; "))")
        #expect(harness.sleeps.durations.isEmpty, "\(label): no real waits or transport retries")
        #expect(HTTPStubProtocol.requests.count == replies.count, "\(label): every request remains intercepted")
    }
}

extension HTTPConnectorTests {
    @Test(.enabled(if: aiSharedFixturesAvailable, aiSharedFixturesSkipReason), arguments: HTTPSharedFixtures.requestFiles)
    func sharedFeatureFixturesMatchEveryHTTPRendering(_ file: String) async throws {
        let cases = try HTTPSharedFixtures.cases(file)
        var renderings = 0
        var gates = 0
        for fixture in cases {
            let caseID = try #require(fixture[ai: "id"].aiString)
            #expect(fixture[ai: "kind"].aiString == "render-request", "\(file)/\(caseID): unknown fixture kind")
            let expected = fixture[ai: "expected"]
            if expected[ai: "error"] != .null {
                #expect(expected[ai: "connectors"] == .null, "\(file)/\(caseID): gated requests have no HTTP rendering")
                gates += 1
                continue
            }
            let connectors = try #require(expected[ai: "connectors"].aiObject)
            let http = connectors.filter { $0.value[ai: "kind"].aiString == "http" }
            #expect(Set(http.keys) == Set(HTTPFixtures.connectors.map(\.rawValue)), "\(file)/\(caseID): every HTTP connector must be covered")
            for name in http.keys.sorted() {
                let label = "\(file)/\(caseID)/\(name)"
                let connector = try #require(ConnectorID(rawValue: name))
                do {
                    try await HTTPSharedFixtures.render(expected[ai: "request"], connector: connector, options: fixture[ai: "input"][ai: "connectorOptions"][ai: name], expected: try #require(http[name]), label: label)
                } catch {
                    Issue.record(error, "\(label): HTTP rendering threw")
                }
                renderings += 1
            }
        }
        #expect(renderings > 0)
        print("HTTP shared fixtures: \(file): \(renderings) HTTP renderings; \(gates) gated cases owned by Domain tests.")
    }

    @Test(.enabled(if: aiSharedFixturesAvailable, aiSharedFixturesSkipReason))
    func sharedConnectorFixturesMatchEveryHTTPRendering() async throws {
        let cases = try HTTPSharedFixtures.cases("connector-requests")
        var renderings = 0
        for fixture in cases {
            let caseID = try #require(fixture[ai: "id"].aiString)
            #expect(fixture[ai: "kind"].aiString == "connector-request", "connector-requests/\(caseID): unknown fixture kind")
            let input = fixture[ai: "input"]
            let connectorName = try #require(input[ai: "connector"].aiString)
            let connector = try #require(ConnectorID(rawValue: connectorName))
            guard HTTPFixtures.connectors.contains(connector) else { continue }
            let label = "connector-requests/\(caseID)/\(connector.rawValue)"
            do {
                try await HTTPSharedFixtures.render(input[ai: "request"], connector: connector, options: input[ai: "options"], expected: fixture[ai: "expected"], label: label)
            } catch {
                Issue.record(error, "\(label): HTTP rendering threw")
            }
            renderings += 1
        }
        #expect(renderings > 0)
        print("HTTP shared fixtures: connector-requests: \(renderings) HTTP renderings.")
    }
}
