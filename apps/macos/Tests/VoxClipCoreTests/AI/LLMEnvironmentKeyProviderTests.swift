import Foundation
import Testing
@testable import VoxClipCore

@Suite("Pinned AI environment keys")
struct LLMEnvironmentKeyProviderTests {
    private let variables: [ConnectorID: String] = [
        .anthropic: "VOXCLIP_ANTHROPIC_API_KEY", .openai: "VOXCLIP_OPENAI_API_KEY",
        .xai: "VOXCLIP_XAI_API_KEY", .gemini: "VOXCLIP_GEMINI_API_KEY"
    ]

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini])
    func environmentKeysUseOnlyTheirOwnPinnedDestination(_ id: ConnectorID) async throws {
        let catalog = try HTTPFixtures.catalog()
        let variable = try #require(variables[id])
        let keys = LLMEnvironmentKeyProvider(catalog: catalog, environment: [variable: " fixture-environment "])
        let account = "llm-api-key-\(id.rawValue)"
        for provider in variables.keys {
            #expect(try await keys.key(for: "llm-api-key-\(provider.rawValue)") == (provider == id ? "fixture-environment" : nil))
        }
        let connector = try HTTPConnector(id: id, keys: keys, catalog: catalog, log: HTTPLog())
        let url = try #require(URL(string: catalog.connector(id)[ai: "baseUrl"].aiString ?? ""))
        let request = try await connector.authorizedRequest(url: url, timeout: 3)
        let header = id == .anthropic ? "x-api-key" : id == .gemini ? "x-goog-api-key" : "Authorization"
        #expect(request.value(forHTTPHeaderField: header) == (id == .openai || id == .xai ? "Bearer " : "") + "fixture-environment")
        #expect(try await keys.key(for: account) == "fixture-environment")
    }

    @Test(arguments: ["keyAccount", "header", "valueTemplate", "debugEnvVar"])
    func craftedCatalogCannotSelectAnotherEnvironmentKey(_ field: String) async throws {
        var auth = try #require(HTTPFixtures.catalog().connector(.openai)[ai: "auth"].aiObject)
        let replacements = [
            "keyAccount": "llm-api-key-anthropic", "header": "User-Agent",
            "valueTemplate": "forwarded {key}", "debugEnvVar": "VOXCLIP_ANTHROPIC_API_KEY"
        ]
        auth[field] = .string(try #require(replacements[field]))
        let catalog = try aiSecurityCatalog(.openai, changes: ["auth": .object(auth)])
        let keys = LLMEnvironmentKeyProvider(catalog: catalog, environment: [
            "VOXCLIP_OPENAI_API_KEY": "fixture-openai", "VOXCLIP_ANTHROPIC_API_KEY": "fixture-anthropic"
        ])
        #expect(try await keys.key(for: "llm-api-key-openai") == nil)
        #expect(try await keys.key(for: "llm-api-key-anthropic") == "fixture-anthropic")
        let connector = try HTTPConnector(id: .openai, keys: keys, catalog: catalog, log: HTTPLog())
        let reason = "VoxClip is missing its AI configuration. Reinstall VoxClip."
        #expect(await connector.status() == .unavailable(reason: reason))
        let url = try #require(URL(string: "https://api.openai.com/v1/responses"))
        await #expect(throws: LLMError.unavailable(reason: reason)) {
            try await connector.authorizedRequest(url: url, timeout: 3)
        }
    }

    @Test(arguments: [ConnectorID.ollama, .lmstudio, .appleFoundation])
    func nonKeyedCatalogAuthCannotOverrideAnEnvironmentAccount(_ id: ConnectorID) async throws {
        let auth = try HTTPFixtures.catalog().connector(.openai)[ai: "auth"]
        let catalog = try aiSecurityCatalog(id, changes: ["auth": auth])
        let keys = LLMEnvironmentKeyProvider(catalog: catalog, environment: ["VOXCLIP_OPENAI_API_KEY": "fixture-openai"])
        #expect(try await keys.key(for: "llm-api-key-openai") == "fixture-openai")
        #expect(try await keys.key(for: "llm-api-key-\(id.rawValue)") == nil)
        #expect(LLMKeyDestination.pinned[id] == nil)
    }
}
