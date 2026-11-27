import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct TakeMatchFixtures {
    @Test func sharedOpeningUsesOpaqueWordIds() {
        let primary = [TimedWord(id: "left:opaque", text: "Opening.", start: 0, end: 1)]
        let alternate = [TimedWord(id: "r2.w14", text: "opening!", start: 2, end: 3)]
        let result = TakeMatch.build([("first", primary), ("second", alternate)])
        #expect(result.beats.map { $0.takes.map(\.startWordId) } == [["left:opaque", "r2.w14"]])
    }
}
