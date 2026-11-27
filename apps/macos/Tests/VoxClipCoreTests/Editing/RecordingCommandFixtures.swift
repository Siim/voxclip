import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct RecordingCommandFixtures {
    @Test func startsFromTheWholeRecordingExceptRestarts() throws {
        let original = try JSONProjectStore.decode(FixtureLoader.data("fixtures/recordings/reference-recordings.voxclip"))
        let started = try RecordingEdits.apply(.startFromRecording(key: original.media.source.contentKey), project: original).get()
        let clip = try #require(started.project.edits.clips.last)
        #expect(started.undoName == "Start from recording")
        #expect(clip.id == started.project.edits.activeClipId)
        #expect(clip.title == "I started Superscribe as a dictation tool.")
        #expect(clip.playParts.map(\.startWordId) == ["w1", "w18"])
        #expect(clip.playParts.map(\.endWordId) == ["w13", "w27"])
        #expect(started.details?.leftOut.map(\.startWordId) == ["w14"])
    }
}
