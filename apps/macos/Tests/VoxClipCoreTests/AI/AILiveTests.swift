import Foundation
import Testing
@testable import VoxClipCore

private let aiLive = ProcessInfo.processInfo.environment["VOXCLIP_LIVE_TESTS"] == "1"
private let aiLiveCLI = aiLive && ProcessInfo.processInfo.environment["VOXCLIP_LIVE_CLI"] == "1"
private let aiLiveOllama = aiLive && ProcessInfo.processInfo.environment["VOXCLIP_LIVE_OLLAMA"] == "1"

@Test("Live Claude Code structured envelope", .enabled(if: aiLiveCLI, "Requires VOXCLIP_LIVE_TESTS=1 and VOXCLIP_LIVE_CLI=1 for a paid CLI call"))
func aiLiveClaudeEnvelope() async throws { try await aiLiveCLIEnvelope(.claudeCode) }

@Test("Live standalone Codex structured envelope", .enabled(if: aiLiveCLI, "Requires VOXCLIP_LIVE_TESTS=1 and VOXCLIP_LIVE_CLI=1 for a paid CLI call"))
func aiLiveCodexEnvelope() async throws { try await aiLiveCLIEnvelope(.codex) }

private func aiLiveCLIEnvelope(_ id: ConnectorID) async throws {
    let catalog = try LLMCatalog(shared: SharedResources(root: FixtureLoader.sharedRoot()))
    let connector = CLIConnector(id: id, catalog: catalog, log: RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path))
    let status = await connector.status()
    #expect(status == .ready)
    guard status == .ready else { return }
    let model = catalog.connector(id)[ai: "defaultModel"].aiString ?? "default"
    let request = try catalog.connectionTest(for: id)
    let raw = try await connector.send(request, model: id == .claudeCode ? "haiku" : model)
    let object = try CanonicalResponseParser.parse(raw, schema: request.schema)
    #expect(object[ai: "ok"].aiBool == true)
    #expect(AIText.trim(object[ai: "echo"].aiString ?? "").lowercased() == "voxclip")
}

@Test("Live Ollama native chat", .enabled(if: aiLiveOllama, "Requires VOXCLIP_LIVE_TESTS=1, VOXCLIP_LIVE_OLLAMA=1 and an installed chat model"))
func aiLiveOllamaRoundTrip() async throws {
    let catalog = try LLMCatalog(shared: SharedResources(root: FixtureLoader.sharedRoot()))
    let log = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    let keys = LLMEnvironmentKeyProvider(catalog: catalog)
    let connector = try HTTPConnector(id: .ollama, keys: keys, catalog: catalog, log: log)
    let result = try await LLMRunner(keys: keys, catalog: catalog, log: log).test(on: connector, model: ProcessInfo.processInfo.environment["VOXCLIP_LIVE_OLLAMA_MODEL"] ?? "qwen3:0.6b")
    #expect(result.passed)
}

@Test("Live Anthropic API", .enabled(if: aiLiveKeyPresent("VOXCLIP_ANTHROPIC_API_KEY"), "Requires VOXCLIP_LIVE_TESTS=1 and VOXCLIP_ANTHROPIC_API_KEY"))
func aiLiveAnthropic() async throws { try await aiLiveAPIKey(.anthropic) }

@Test("Live OpenAI API", .enabled(if: aiLiveKeyPresent("VOXCLIP_OPENAI_API_KEY"), "Requires VOXCLIP_LIVE_TESTS=1 and VOXCLIP_OPENAI_API_KEY"))
func aiLiveOpenAI() async throws { try await aiLiveAPIKey(.openai) }

@Test("Live xAI API", .enabled(if: aiLiveKeyPresent("VOXCLIP_XAI_API_KEY"), "Requires VOXCLIP_LIVE_TESTS=1 and VOXCLIP_XAI_API_KEY"))
func aiLiveXAI() async throws { try await aiLiveAPIKey(.xai) }

@Test("Live Gemini API", .enabled(if: aiLiveKeyPresent("VOXCLIP_GEMINI_API_KEY"), "Requires VOXCLIP_LIVE_TESTS=1 and VOXCLIP_GEMINI_API_KEY"))
func aiLiveGemini() async throws { try await aiLiveAPIKey(.gemini) }

private func aiLiveKeyPresent(_ variable: String) -> Bool {
    aiLive && !(ProcessInfo.processInfo.environment[variable] ?? "").isEmpty
}

private func aiLiveAPIKey(_ id: ConnectorID) async throws {
    let catalog = try LLMCatalog(shared: SharedResources(root: FixtureLoader.sharedRoot()))
    let log = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    let keys = LLMEnvironmentKeyProvider(catalog: catalog)
    let connector = try HTTPConnector(id: id, keys: keys, catalog: catalog, log: log)
    let result = try await LLMRunner(keys: keys, catalog: catalog, log: log).test(on: connector, model: catalog.connector(id)[ai: "defaultModel"].aiString ?? "")
    #expect(result.passed)
}
