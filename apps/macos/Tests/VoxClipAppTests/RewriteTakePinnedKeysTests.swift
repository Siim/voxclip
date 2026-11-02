#if DEBUG
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@testable import VoxClip

private final class RewriteTakeKeySource: KeyProvider, Sendable {
    let rotated = Mutex(false)
    func key(for provider: String) async throws -> String? {
        guard provider == "elevenlabs" else { return nil }
        return rotated.withLock { $0 ? "synthetic-rewrite-account-b" : "synthetic-rewrite-account-a" }
    }
}

@Suite("Rewrite take production key pin", .offlineFixtures)
struct RewriteTakePinnedKeysTests {
    @Test func sharedProductionProviderRejectsRotationInsteadOfRebinding() async throws {
        let source = RewriteTakeKeySource()
        let keys = VoiceChangePinnedKeys(source: source)
        #expect(try await keys.key(for: "elevenlabs") == "synthetic-rewrite-account-a")
        #expect(try await keys.key(for: "elevenlabs") == "synthetic-rewrite-account-a")
        source.rotated.withLock { $0 = true }
        await #expect(throws: VoiceConsentError.creatorMismatch) { try await keys.key(for: "elevenlabs") }
    }
}
#endif
