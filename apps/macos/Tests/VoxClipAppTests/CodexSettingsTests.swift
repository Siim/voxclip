import Foundation
import Testing
import VoxClipCore
@testable import VoxClip

@MainActor @Suite("Codex model settings", .offlineFixtures)
struct CodexSettingsTests {
    @Test func onlyAWorkingCodexModelReplacesTheSavedModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("codex")
        let flags = "--json --output-schema --output-last-message --skip-git-repo-check --ephemeral --ignore-user-config --sandbox --cd --model"
        try """
        #!/bin/sh
        case "$*" in
            '--version') printf '%s\\n' 'codex-cli 0.171.0' ;;
            'exec --help') printf '%s\\n' '\(flags)' ;;
            'features list') exit 0 ;;
            'login status') printf '%s\\n' 'Logged in using ChatGPT' ;;
            'app-server --listen stdio://')
                while IFS= read -r line; do
                    case "$line" in
                        *'"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
                        *'"model/list"'*) printf '%s\\n' '{"id":2,"result":{"data":[{"id":"gpt-6.2-sol"},{"id":"gpt-6.2-astra"}]}}'; exit 0 ;;
                    esac
                done ;;
            *'--model missing-model '*)
                printf '%s\\n' '{"type":"turn.failed","error":{"message":"model_not_found"}}'; exit 1 ;;
            *'--model gpt-6.2-astra '*)
                printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\\"ok\\":true,\\"echo\\":\\"voxclip\\"}"}}' '{"type":"turn.completed"}' ;;
            *) exit 88 ;;
        esac
        """.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let app = AppModel(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        app.loadCatalogue()
        let shared = try #require(app.shared)
        let catalog = try LLMCatalog(shared: shared)
        let cli = CLIConnector(id: .codex, catalog: catalog, log: app.log, executable: fixture,
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"], temporaryDirectory: root, loginShellPATH: "/usr/bin:/bin")
        app.connectorOverride = { _ in cli }
        let provider = try #require(app.providers.first { $0.id == "codex" })
        app.set("llm.connector", .string("codex"))
        app.set("llm.model.codex", .string("default"))
        app.set("llm.cloudConsent.codex", .bool(true))
        await app.refreshCodexModels()
        #expect(app.modelChoices(for: provider).contains { $0.id == "gpt-6.2-sol" })
        #expect(!app.modelUnavailable("gpt-6.2-sol", for: provider))
        #expect(!app.modelUnavailable("gpt-6.2-astra", for: provider))
        #expect(app.modelUnavailable("gpt-6.1-sol", for: provider))

        app.chooseModel("missing-model", for: provider)
        #expect(app.savedModel(for: provider) == "default")
        #expect(await testProvider(provider, app: app).hasPrefix("Failed:"))
        #expect(app.savedModel(for: provider) == "default")
        #expect(app.codexDraftModel == nil)

        app.chooseModel("gpt-6.2-astra", for: provider)
        #expect(app.savedModel(for: provider) == "default")
        #expect(await testProvider(provider, app: app).hasPrefix("Works · gpt-6.2-astra"))
        #expect(app.savedModel(for: provider) == "gpt-6.2-astra")
    }
}
