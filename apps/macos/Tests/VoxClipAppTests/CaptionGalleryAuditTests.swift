#if DEBUG
import Foundation
import CoreFoundation
import Synchronization
import Testing
@testable import VoxClip

@Suite("Headless gallery audit", .serialized)
@MainActor struct CaptionGalleryAuditTests {
    @Test func settlementWaitsForAnAppKitLayoutTurn() async throws {
        let observed = Mutex(false)
        let observer = try #require(CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max - 1) { _, _ in
            observed.withLock { $0 = true }
        })
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        await DebugCaptionGallery.layoutTurn()
        #expect(observed.withLock { $0 })
    }
    @Test func failureNamesRetainExpectedActualAndSnapshotDiagnostics() {
        let receipt = DebugCaptionGallery.Measurement(name: "undo-360", width: 360, height: 4096, style: "expected", snapshot: nil, elapsed: 2, settled: false, passes: 2)
        let result = DebugCaptionGallery.selectionResult(name: "undo reveals tile", receipt: receipt, actualStyle: "actual")
        #expect(!result.passed)
        #expect(result.name.contains("expected style expected, actual style actual"))
        #expect(result.name.contains("\"settled\":false") && result.name.contains("\"passes\":2"))
        let unsettled = DebugCaptionGallery.selectionResult(name: "undo reveals tile", receipt: receipt, actualStyle: "expected")
        #expect(!unsettled.passed)
    }
}
#endif
