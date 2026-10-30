import Foundation
import Testing
@testable import VoxClipCore

extension HTTPConnectorTests {
    @Test
    func anthropicContextExhaustionDoesNotCorrectPartialJSON() async throws {
        let harness = try HTTPHarness(.anthropic, replies: [.json(#"{"stop_reason":"model_context_window_exceeded","content":[{"type":"text","text":"{"}]}"#)])
        defer { harness.finish() }
        await #expect(throws: LLMError.truncated) {
            try await harness.runner().test(on: harness.connector, model: harness.model)
        }
        #expect(HTTPStubProtocol.requests.count == 1)
    }

    @Test(arguments: ["not-loaded", "loading", "", "loaded"])
    func lmStudioRequiresLoadedStateForWorkingContext(_ state: String) async throws {
        let harness = try HTTPHarness(.lmstudio, replies: [.json("{\"state\":\"\(state)\",\"max_context_length\":131072}")])
        defer { harness.finish() }
        #expect(await harness.connector.contextTokens(model: "local") == (state == "loaded" ? 131072 : 4096))
        #expect(await harness.connector.assumedContextModels.contains("local") == (state != "loaded"))
    }

    @Test(arguments: [8192, 0, -1])
    func lmStudioPrefersOnlyPositiveLoadedContext(_ loaded: Int) async throws {
        let harness = try HTTPHarness(.lmstudio, replies: [.json("{\"state\":\"loaded\",\"loaded_context_length\":\(loaded),\"max_context_length\":131072}")])
        defer { harness.finish() }
        #expect(await harness.connector.contextTokens(model: "local") == (loaded > 0 ? loaded : 131072))
    }
}
