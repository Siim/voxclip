import Foundation
import Testing
@testable import VoxClipCore

extension HTTPConnectorTests {
    @Test(arguments: [ConnectorID.ollama, .lmstudio])
    func localStatus400UsesCatalogLabelWithoutProviderDetail(_ id: ConnectorID) async throws {
        let label = "Fixture local server"
        let catalog = try aiSecurityCatalog(id, changes: ["label": .string(label)])
        let harness = try HTTPHarness(id, replies: [.json(#"{"error":{"message":"private provider detail"}}"#, status: 400)], catalog: catalog)
        defer { harness.finish() }
        let reason = "\(label) rejected the request (400)."
        #expect(await harness.connector.status() == .unavailable(reason: reason))
        #expect(LLMError.unavailable(reason: reason).userMessage(label: label) == reason + " Your edits are saved.")
        #expect(HTTPStubProtocol.requests.count == 1)
    }

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini], [false, true])
    func crossOriginRedirectNeverResendsStoredKeys(_ id: ConnectorID, sending: Bool) async throws {
        let catalog = try HTTPFixtures.catalog()
        let baseURL = try #require(URL(string: catalog.connector(id)[ai: "baseUrl"].aiString ?? ""))
        let host = try #require(baseURL.host)
        for address in ["https://example.invalid/steal", "http://\(host)/steal", "https://\(host):444/steal"] {
            let target = try #require(URL(string: address))
            let harness = try HTTPHarness(id, replies: [.redirect(to: target)])
            defer { harness.finish() }
            let failure = LLMError.badRequest(status: 307, message: "The provider rejected the request.")
            await #expect(throws: failure) {
                if sending {
                    _ = try await harness.connector.send(harness.catalog.connectionTest(for: id), model: harness.model)
                } else {
                    _ = try await harness.connector.fetch(path: "/fixture", timeout: 3)
                }
            }
            let requests = HTTPStubProtocol.requests
            #expect(requests.count == 1)
            let initial = try #require(requests.first?.request)
            #expect(initial.url?.host == host)
            let header = try #require(catalog.connector(id)[ai: "auth"][ai: "header"].aiString)
            #expect(initial.value(forHTTPHeaderField: header) != nil)
            for captured in requests where captured.request.url == target {
                for sensitive in ["x-api-key", "x-goog-api-key", "Authorization"] {
                    #expect(captured.request.value(forHTTPHeaderField: sensitive) == nil)
                }
            }
        }
    }

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini], [false, true])
    func sameOriginRedirectNeverResendsStoredKeys(_ id: ConnectorID, sending: Bool) async throws {
        let catalog = try HTTPFixtures.catalog()
        let baseURL = try #require(URL(string: catalog.connector(id)[ai: "baseUrl"].aiString ?? ""))
        let target = baseURL.appendingPathComponent("redirected")
        let harness = try HTTPHarness(id, replies: [.redirect(to: target)])
        defer { harness.finish() }
        await #expect(throws: LLMError.badRequest(status: 307, message: "The provider rejected the request.")) {
            if sending {
                _ = try await harness.connector.send(harness.catalog.connectionTest(for: id), model: harness.model)
            } else {
                _ = try await harness.connector.fetch(path: "/fixture", timeout: 3)
            }
        }
        let requests = HTTPStubProtocol.requests
        #expect(requests.count == 1)
        let initial = try #require(requests.first?.request)
        #expect(initial.url != target)
        let header = try #require(catalog.connector(id)[ai: "auth"][ai: "header"].aiString)
        #expect(initial.value(forHTTPHeaderField: header) != nil)
    }

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini])
    func sharedCatalogOverrideCannotRedirectStoredKeys(_ id: ConnectorID) async throws {
        let catalog = try aiSecurityCatalog(id, changes: ["baseUrl": .string("https://example.invalid/\(id.rawValue)")])
        let harness = try HTTPHarness(id, replies: [], catalog: catalog)
        defer { harness.finish() }
        let reason = "VoxClip is missing its AI configuration. Reinstall VoxClip."
        let failure = LLMError.unavailable(reason: reason)
        #expect(await harness.connector.status() == .unavailable(reason: reason))
        _ = try await harness.connector.models(refresh: true)
        #expect(await harness.connector.refreshWarning?.contains(reason) == true)
        await #expect(throws: failure) {
            try await harness.runner().test(on: harness.connector, model: harness.model)
        }
        await #expect(throws: failure) {
            try await harness.connector.send(HTTPFixtures.f1(), model: harness.model)
        }
        #expect(HTTPStubProtocol.requests.isEmpty)
    }

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini], ["keyAccount", "header", "valueTemplate", "debugEnvVar"])
    func craftedCatalogAuthCannotSelectCredentials(_ id: ConnectorID, field: String) async throws {
        var auth = try #require(HTTPFixtures.catalog().connector(id)[ai: "auth"].aiObject)
        let replacements = [
            "keyAccount": id == .anthropic ? "llm-api-key-openai" : "llm-api-key-anthropic",
            "header": "User-Agent",
            "valueTemplate": "forwarded {key}",
            "debugEnvVar": id == .anthropic ? "VOXCLIP_OPENAI_API_KEY" : "VOXCLIP_ANTHROPIC_API_KEY"
        ]
        auth[field] = .string(try #require(replacements[field]))
        let catalog = try aiSecurityCatalog(id, changes: ["auth": .object(auth)])
        let keys = AISecurityKeys()
        let harness = try HTTPHarness(id, replies: [], catalog: catalog, keys: keys)
        defer { harness.finish() }
        let reason = "VoxClip is missing its AI configuration. Reinstall VoxClip."
        let failure = LLMError.unavailable(reason: reason)
        #expect(await harness.connector.status() == .unavailable(reason: reason))
        _ = try await harness.connector.models(refresh: true)
        #expect(await harness.connector.refreshWarning?.contains(reason) == true)
        await #expect(throws: failure) {
            try await harness.runner().test(on: harness.connector, model: harness.model)
        }
        await #expect(throws: failure) {
            try await harness.connector.send(catalog.connectionTest(for: id), model: harness.model)
        }
        #expect(failure.userMessage(label: id.rawValue) == reason + " Your edits are saved.")
        #expect(await keys.accounts.isEmpty)
        #expect(await harness.log.registered.isEmpty)
        #expect(HTTPStubProtocol.requests.isEmpty)
    }

    @Test(arguments: [ConnectorID.ollama, .lmstudio])
    func localCatalogAuthIsUnavailableWithoutReadingOrSendingAKey(_ id: ConnectorID) async throws {
        let auth = try HTTPFixtures.catalog().connector(.openai)[ai: "auth"]
        let catalog = try aiSecurityCatalog(id, changes: ["auth": auth])
        let keys = AISecurityKeys()
        let harness = try HTTPHarness(id, replies: [], catalog: catalog, keys: keys)
        defer { harness.finish() }
        let reason = "VoxClip is missing its AI configuration. Reinstall VoxClip."
        let failure = LLMError.unavailable(reason: reason)
        #expect(await harness.connector.status() == .unavailable(reason: reason))
        await #expect(throws: failure) { try await harness.connector.apiKey() }
        await #expect(throws: failure) {
            try await harness.connector.send(catalog.connectionTest(for: id), model: harness.model)
        }
        await #expect(throws: failure) {
            try await harness.runner().test(on: harness.connector, model: harness.model)
        }
        _ = try await harness.connector.models(refresh: true)
        #expect(await harness.connector.refreshWarning?.contains(reason) == true)
        #expect(HTTPStubProtocol.requests.isEmpty)
        #expect(await keys.accounts.isEmpty)
        #expect(await harness.log.registered.isEmpty)
    }

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini])
    func authorizedRequestsUseTheirPinnedAccountAndHeader(_ id: ConnectorID) async throws {
        let accounts: [ConnectorID: String] = [
            .anthropic: "llm-api-key-anthropic", .openai: "llm-api-key-openai",
            .xai: "llm-api-key-xai", .gemini: "llm-api-key-gemini"
        ]
        let keys = AISecurityKeys()
        let harness = try HTTPHarness(id, replies: [HTTPFixtures.success(id)], keys: keys)
        defer { harness.finish() }
        _ = try await harness.connector.send(harness.catalog.connectionTest(for: id), model: harness.model)
        let account = try #require(accounts[id])
        #expect(await keys.accounts == [account])
        let request = try #require(HTTPStubProtocol.requests.first?.request)
        let header = id == .anthropic ? "x-api-key" : id == .gemini ? "x-goog-api-key" : "Authorization"
        let value = (id == .openai || id == .xai ? "Bearer " : "") + "fixture-\(account)"
        #expect(request.value(forHTTPHeaderField: header) == value)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "VoxClip/9.8.7 (macOS)")
    }

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini])
    func storedKeysRequireOnlyTheirPinnedHTTPSHost(_ id: ConnectorID) async throws {
        let pinnedHosts: [ConnectorID: String] = [
            .anthropic: "api.anthropic.com",
            .openai: "api.openai.com",
            .xai: "api.x.ai",
            .gemini: "generativelanguage.googleapis.com"
        ]
        let harness = try HTTPHarness(id, replies: [])
        defer { harness.finish() }
        let header = try #require(harness.catalog.connector(id)[ai: "auth"][ai: "header"].aiString)
        let value = try #require(harness.catalog.connector(id)[ai: "auth"][ai: "valueTemplate"].aiString)
            .replacingOccurrences(of: "{key}", with: "test")
        let pinnedHost = try #require(pinnedHosts[id])
        let failure = LLMError.unavailable(reason: "VoxClip is missing its AI configuration. Reinstall VoxClip.")
        for (provider, host) in pinnedHosts {
            for address in ["https://\(host)/fixture", "HTTPS://\(host.uppercased())/fixture"] {
                let url = try #require(URL(string: address))
                if provider == id {
                    let request = try await harness.connector.authorizedRequest(url: url, timeout: 3)
                    #expect(request.value(forHTTPHeaderField: header) == value)
                } else {
                    await #expect(throws: failure) {
                        try await harness.connector.authorizedRequest(url: url, timeout: 3)
                    }
                }
            }
        }
        for address in [
            "http://\(pinnedHost)/fixture",
            "https://\(pinnedHost).example.invalid/fixture",
            "https://other.\(pinnedHost)/fixture",
            "https://\(pinnedHost)./fixture",
            "https://user@\(pinnedHost)/fixture",
            "https://user:password@\(pinnedHost)/fixture",
            "https://\(pinnedHost)@example.invalid/fixture"
        ] {
            let url = try #require(URL(string: address))
            await #expect(throws: failure) {
                try await harness.connector.authorizedRequest(url: url, timeout: 3)
            }
        }
        #expect(HTTPStubProtocol.requests.isEmpty)
    }
}

private actor AISecurityKeys: KeyProvider {
    private(set) var accounts: [String] = []

    func key(for provider: String) async throws -> String? {
        accounts.append(provider)
        return "fixture-\(provider)"
    }
}

func aiSecurityCatalog(_ id: ConnectorID, changes: [String: JSONValue]) throws -> LLMCatalog {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: root.appendingPathComponent("catalog"), withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    try manager.createDirectory(at: root.appendingPathComponent("caption-styles"), withIntermediateDirectories: true)
    var document = try #require(HTTPFixtures.catalog().document.aiObject)
    document["connectors"] = .array(document["connectors"]!.aiArray.map { entry in
        guard entry[ai: "id"].aiString == id.rawValue, var fields = entry.aiObject else { return entry }
        fields.merge(changes) { _, replacement in replacement }
        return .object(fields)
    })
    try JSONValue.object(document).aiEncoded().write(to: root.appendingPathComponent("catalog/llm-providers.json"))
    let shared = try SharedResources.locate(environment: ["VOXCLIP_SHARED_DIR": root.path])
    #expect(shared.root == root)
    return try LLMCatalog.load(shared: shared)
}
