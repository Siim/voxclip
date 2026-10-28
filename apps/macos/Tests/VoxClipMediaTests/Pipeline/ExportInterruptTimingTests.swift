import Testing
@testable import VoxClipMedia

@Suite struct ExportInterruptTimingTests {
    @Test func mediaTimingRecordsNothingWithoutExplicitOptIn() {
        #expect(ExportInterruptTiming.testOnly == nil)
        ExportInterruptTiming.testOnly?.mark(.handler)
        ExportInterruptTiming.testOnly?.mark(.exportStart)
        ExportInterruptTiming.testOnly?.mark(.partialDeleted)
        #expect(ExportInterruptTiming.testOnly == nil)
    }
}
