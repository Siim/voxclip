import Foundation
import Testing
@testable import VoxClipCore

/// ai.md §19.3: images reach the API-key connectors as their native blocks, each after its label, between the cached
/// block and the instruction; local servers take none, and a request without images is built exactly as before.
@Suite("HTTP image requests", .serialized, .httpStubs, .timeLimit(.minutes(1)), .offlineFixtures)
struct HTTPImageRequestTests {
    static let images = [
        LLMImage(label: "Frame 1 at 3.20 s", mediaType: "image/jpeg", data: Data([0xFF, 0xD8, 0x01]), width: 320, height: 180),
        LLMImage(label: "Frame 2 at 7.45 s", mediaType: "image/jpeg", data: Data([0xFF, 0xD8, 0x02]), width: 320, height: 180),
    ]

    @Test(arguments: HTTPFixtures.connectors)
    func catalogueDeclaresImageSupport(_ id: ConnectorID) async throws {
        let harness = try HTTPHarness(id, replies: [])
        defer { harness.finish() }
        let expected = [ConnectorID.anthropic, .openai, .xai, .gemini].contains(id)
        #expect(await harness.connector.supportsImages() == expected)
        #expect(harness.catalog.maximumImages(for: id) == (expected ? 24 : 0))
    }

    @Test(arguments: HTTPFixtures.connectors)
    func imagesAreInsertedAndNothingElseChanges(_ id: ConnectorID) async throws {
        let harness = try HTTPHarness(id, replies: [])
        defer { harness.finish() }
        var plain = try HTTPFixtures.f1()
        plain.maxOutputTokens = 1000  // fits a local server's default 4,096-token context
        var pictured = plain
        pictured.images = Self.images
        let without = try await body(harness, plain)
        let with = try await body(harness, pictured)
        #expect(without == (try await body(harness, plain)))
        let expected: JSONValue
        switch id {
        case .anthropic:
            expected = try inserting(Self.images.flatMap { image -> [JSONValue] in
                [.object(["type": .string("text"), "text": .string(image.label)]),
                 .object(["type": .string("image"), "source": .object(["type": .string("base64"), "media_type": .string("image/jpeg"),
                                                                     "data": .string(image.data.base64EncodedString())])])]
            }, into: without, path: ["messages", 0, "content"], at: 1)
        case .openai:
            expected = try inserting(Self.images.flatMap { image -> [JSONValue] in
                [.object(["type": .string("input_text"), "text": .string(image.label)]),
                 .object(["type": .string("input_image"), "image_url": .string("data:image/jpeg;base64," + image.data.base64EncodedString()), "detail": .string("low")])]
            }, into: without, path: ["input", 0, "content"], at: 1)
        case .gemini:
            expected = try inserting(Self.images.flatMap { image -> [JSONValue] in
                [.object(["text": .string(image.label)]),
                 .object(["inlineData": .object(["mimeType": .string("image/jpeg"), "data": .string(image.data.base64EncodedString())])])]
            }, into: without, path: ["contents", 0, "parts"], at: 1)
        case .xai:
            let user = try #require(without[ai: "messages"].aiArray.last?[ai: "content"])
            let parts: [JSONValue] = Self.images.flatMap { image -> [JSONValue] in
                [.object(["type": .string("text"), "text": .string(image.label)]),
                 .object(["type": .string("image_url"), "image_url": .object(["url": .string("data:image/jpeg;base64," + image.data.base64EncodedString()), "detail": .string("low")])])]
            } + [.object(["type": .string("text"), "text": user])]
            expected = try replacing(without, path: ["messages", 1, "content"], with: .array(parts))
        default:
            expected = without
        }
        #expect(with == expected)
    }

    @Test func imagesBeyondTheCataloguesLimitAreDropped() async throws {
        let harness = try HTTPHarness(.anthropic, replies: [])
        defer { harness.finish() }
        var request = try HTTPFixtures.f1()
        request.images = Array(repeating: Self.images[0], count: 30)
        let content = try await body(harness, request)[ai: "messages"].aiArray.first?[ai: "content"].aiArray ?? []
        #expect(content.filter { $0[ai: "type"].aiString == "image" }.count == 24)
    }

    private func body(_ harness: HTTPHarness, _ request: LLMRequest) async throws -> JSONValue {
        let url = try await harness.connector.makeRequest(request, model: harness.model)
        return try JSONDecoder().decode(JSONValue.self, from: try #require(url.httpBody))
    }

    private func inserting(_ items: [JSONValue], into value: JSONValue, path: [Any], at index: Int) throws -> JSONValue {
        let current = try #require(lookup(value, path).aiArray)
        var array = current
        array.insert(contentsOf: items, at: index)
        return try replacing(value, path: path, with: .array(array))
    }

    private func lookup(_ value: JSONValue, _ path: [Any]) -> JSONValue {
        path.reduce(value) { current, key in
            if let name = key as? String { return current[ai: name] }
            if let position = key as? Int { return current.aiArray.indices.contains(position) ? current.aiArray[position] : .null }
            return .null
        }
    }

    private func replacing(_ value: JSONValue, path: [Any], with replacement: JSONValue) throws -> JSONValue {
        guard let key = path.first else { return replacement }
        let rest = Array(path.dropFirst())
        if let name = key as? String, case .object(var object) = value {
            object[name] = try replacing(object[name] ?? .null, path: rest, with: replacement)
            return .object(object)
        }
        if let position = key as? Int, case .array(var array) = value, array.indices.contains(position) {
            array[position] = try replacing(array[position], path: rest, with: replacement)
            return .array(array)
        }
        Issue.record("Path \(path) does not exist")
        return value
    }
}
