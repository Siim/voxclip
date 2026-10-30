import Foundation
import Testing
@testable import VoxClipCore

extension HTTPConnectorTests {
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
