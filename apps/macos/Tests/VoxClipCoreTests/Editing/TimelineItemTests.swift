import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct TimelineItemTests {
    @Test func cutAnchorPlaysAtTheSeamAndRestoringMovesItBack() throws {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/story-clips/story-project.voxclip"))
        project.clipEffects = [ClipEffect(id: "sound", clipId: nil, kind: .sound, start: 1, end: 1.5)]
        let cut = EditPlan(sampleRate: 48_000, totalSamples: 144_000, kept: [
            .init(startSample: 0, endSample: 24_000), .init(startSample: 72_000, endSample: 144_000)
        ])
        let restored = EditPlan(sampleRate: 48_000, totalSamples: 144_000, kept: [.init(startSample: 0, endSample: 144_000)])
        let cutItem = try #require(TimelineItems.layout(project: project, plan: cut, scope: nil, axis: .edited).items.first { $0.id == .effect("sound") })
        let restoredItem = try #require(TimelineItems.layout(project: project, plan: restored, scope: nil, axis: .edited).items.first { $0.id == .effect("sound") })
        #expect(cutItem.editedIntervals == [TimeRange(start: 0.5, end: 1)])
        #expect(restoredItem.editedIntervals == [TimeRange(start: 1, end: 1.5)])
    }
}
