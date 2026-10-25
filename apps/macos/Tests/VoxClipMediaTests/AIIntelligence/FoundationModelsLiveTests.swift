import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite struct FoundationModelsLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_LIVE_TESTS"] == "1" && ProcessInfo.processInfo.environment["VOXCLIP_LIVE_FM"] == "1",
        "Requires VOXCLIP_LIVE_TESTS=1 and VOXCLIP_LIVE_FM=1"))
    func catalogTestRoundtrip() async throws {
        let connector = try FoundationModelsTestResources.connector(runtime: .system)
        let status = await connector.status()
        guard status == .ready else {
            Issue.record("VOXCLIP_LIVE_FM was enabled, but Apple Intelligence is not ready: \(status)")
            return
        }
        let request = try FoundationModelsTestResources.request()
        let response = try await connector.send(request, model: "system")
        #expect(response.object == (try FoundationModelsTestResources.catalog().testRequest.expect))
        #expect(response.stop == .complete)
        #expect(await connector.contextTokens(model: "system") != nil)
    }
}
