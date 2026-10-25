import Foundation
import Testing
@testable import VoxClipCore

private actor FactoryKeys: KeyProvider {
    var accounts: [String] = []
    func key(for provider: String) async throws -> String? {
        accounts.append(provider)
        return nil
    }
}

private actor FactoryProcesses: ProcessRunner {
    var requests: [ProcessRequest] = []
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        if request.arguments == ["-lc", "printf %s \"$PATH\""] {
            return ProcessResult(exitCode: 0, stdout: Data("/fixture/bin".utf8), stderr: Data())
        }
        throw LLMError.cliFailed("fixture process")
    }
}

@Suite("M8 catalog and connector factory")
struct LLMFactoryTests {
    @Test func loadWrapsCatalogInitializer() throws {
        let shared = try SharedResources(root: FixtureLoader.sharedRoot())
        #expect(try LLMCatalog.load(shared: shared) == LLMCatalog(shared: shared))
    }

    @Test(arguments: ConnectorID.allCases)
    func factorySelectsConnectorWithoutCallingProviders(_ id: ConnectorID) async throws {
        let catalog = try LLMCatalog.load(shared: SharedResources(root: FixtureLoader.sharedRoot()))
        let keys = FactoryKeys()
        let processes = FactoryProcesses()
        let connector = LLMConnectors.make(id, catalog: catalog, keys: keys, processes: processes, settings: SettingsDocument())
        #expect(connector.id == id)
        switch id {
        case .appleFoundation: #expect(connector is StubLLMConnector)
        case .claudeCode, .codex: #expect(connector is CLIConnector)
        default: #expect(connector is HTTPConnector)
        }
        #expect(await keys.accounts.isEmpty)
        #expect(await processes.requests.isEmpty)
        if let account = catalog.connector(id)[ai: "auth"][ai: "keyAccount"].aiString {
            #expect(await connector.status() == .needsKey)
            #expect(await keys.accounts == [account])
        }
    }

    @Test(arguments: ConnectorID.allCases)
    func disabledConnectorsStayUnavailable(_ id: ConnectorID) async throws {
        var catalog = try LLMCatalog.load(shared: SharedResources(root: FixtureLoader.sharedRoot()))
        var document = try #require(catalog.document.aiObject)
        document["connectors"] = .array(document["connectors"]!.aiArray.map { entry in
            guard entry[ai: "id"].aiString == id.rawValue, var fields = entry.aiObject else { return entry }
            fields["enabled"] = .bool(false)
            return .object(fields)
        })
        catalog.document = .object(document)
        let keys = FactoryKeys()
        let processes = FactoryProcesses()
        let connector = LLMConnectors.make(id, catalog: catalog, keys: keys, processes: processes, settings: SettingsDocument())
        let reason = "\(catalog.connector(id)[ai: "label"].aiString ?? id.rawValue) is not enabled."
        #expect(await connector.status() == .unavailable(reason: reason))
        do {
            _ = try await connector.models(refresh: true)
            Issue.record("Disabled connector returned models")
        } catch let failure as VoxClipError {
            #expect(id == .appleFoundation && failure == .sharedResourcesMissing)
        } catch {
            #expect(error is LLMError)
        }
        #expect(await keys.accounts.isEmpty)
        #expect(await processes.requests.isEmpty)
    }

    @Test(arguments: [ConnectorID.ollama, .lmstudio, .appleFoundation, .claudeCode, .codex])
    func keylessAuthBlocksMakeConnectorsUnavailable(_ id: ConnectorID) async throws {
        let auth = try HTTPFixtures.catalog().connector(.openai)[ai: "auth"]
        let catalog = try aiSecurityCatalog(id, changes: ["auth": auth])
        let keys = FactoryKeys()
        let processes = FactoryProcesses()
        let reason = "VoxClip is missing its AI configuration. Reinstall VoxClip."
        let connector = LLMConnectors.make(id, catalog: catalog, keys: keys, processes: processes, settings: SettingsDocument())
        #expect(await connector.status() == .unavailable(reason: reason))
        await #expect(throws: LLMError.unavailable(reason: reason)) { try await connector.models(refresh: true) }
        await #expect(throws: LLMError.unavailable(reason: reason)) {
            try await connector.send(catalog.connectionTest(for: id), model: "default")
        }
        if id == .claudeCode || id == .codex {
            let direct = CLIConnector(id: id, runner: processes, catalog: catalog, log: RedactingLogger(homeDirectory: "/test"),
                                      executable: URL(fileURLWithPath: "/bin/sh"), environment: [:], loginShellPATH: "/test")
            #expect(await direct.status() == .unavailable(reason: reason))
            await #expect(throws: LLMError.unavailable(reason: reason)) { try await direct.detection() }
        }
        #expect(await keys.accounts.isEmpty)
        #expect(await processes.requests.isEmpty)
    }

    @Test(arguments: [ConnectorID.anthropic, .openai, .xai, .gemini])
    func cloudURLSettingsCannotOverrideCatalog(_ id: ConnectorID) async throws {
        let catalog = try LLMCatalog.load(shared: SharedResources(root: FixtureLoader.sharedRoot()))
        let keys = FactoryKeys()
        let processes = FactoryProcesses()
        let settings = SettingsDocument(values: ["llm.baseUrl.\(id.rawValue)": .string("https://example.invalid")])
        let connector = try #require(LLMConnectors.make(id, catalog: catalog, keys: keys, processes: processes, settings: settings) as? HTTPConnector)
        #expect(await connector.baseURL.absoluteString == catalog.connector(id)[ai: "baseUrl"].aiString)
        #expect(await keys.accounts.isEmpty)
        #expect(await processes.requests.isEmpty)
    }

    @Test(arguments: [ConnectorID.ollama, .lmstudio])
    func localURLSettingsAreAppliedWithoutRequests(_ id: ConnectorID) async throws {
        let catalog = try LLMCatalog.load(shared: SharedResources(root: FixtureLoader.sharedRoot()))
        let settings = SettingsDocument(values: ["llm.baseUrl.\(id.rawValue)": .string("http://127.0.0.1:9876/custom")])
        let connector = try #require(LLMConnectors.make(id, catalog: catalog, keys: FactoryKeys(), processes: FactoryProcesses(), settings: settings) as? HTTPConnector)
        #expect(await connector.baseURL.absoluteString == "http://127.0.0.1:9876/custom")
    }

    @Test(arguments: [ConnectorID.ollama, .lmstudio], ["file:///invalid", "http://user:password@localhost", "http://localhost/?query=1", "http://localhost/#fragment", "http://", "http://["])
    func invalidLocalURLSettingsUseSettingsCopy(_ id: ConnectorID, address: String) async throws {
        let catalog = try LLMCatalog.load(shared: SharedResources(root: FixtureLoader.sharedRoot()))
        let label = try #require(catalog.connector(id)[ai: "label"].aiString)
        let reason = "\(label)'s server address in Settings isn't valid."
        let invalid = SettingsDocument(values: ["llm.baseUrl.\(id.rawValue)": .string(address)])
        let keys = FactoryKeys()
        let processes = FactoryProcesses()
        let unavailable = LLMConnectors.make(id, catalog: catalog, keys: keys, processes: processes, settings: invalid)
        #expect(await unavailable.status() == .unavailable(reason: reason))
        do {
            _ = try await unavailable.send(catalog.connectionTest(for: id), model: "local")
            Issue.record("Invalid local URL was accepted")
        } catch let failure as LLMError {
            #expect(failure == .unavailable(reason: reason))
            #expect(failure.userMessage(label: label) == reason + " Your edits are saved.")
        }
        if let url = URL(string: address) {
            #expect(throws: LLMError.unavailable(reason: reason)) {
                try HTTPConnector(id: id, keys: keys, catalog: catalog, log: HTTPLog(), baseURL: url)
            }
        }
        #expect(await keys.accounts.isEmpty)
        #expect(await processes.requests.isEmpty)
    }

    @Test(arguments: [ConnectorID.claudeCode, .codex])
    func CLISettingsUseTheInjectedProcesses(_ id: ConnectorID) async throws {
        let catalog = try LLMCatalog.load(shared: SharedResources(root: FixtureLoader.sharedRoot()))
        let processes = FactoryProcesses()
        let settings = SettingsDocument(values: ["llm.cliPath.\(id.rawValue)": .string("/bin/sh")])
        let connector = LLMConnectors.make(id, catalog: catalog, keys: FactoryKeys(), processes: processes, settings: settings)
        _ = await connector.status()
        let requests = await processes.requests
        #expect(requests.filter { $0.executable.path == "/bin/sh" }.count == 1)
        #expect(requests.last?.executable.path == "/bin/sh")
        #expect(requests.last?.arguments == ["--version"])
    }
}
