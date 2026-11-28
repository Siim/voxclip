import Foundation
import Testing
@testable import VoxClipCore

/// The project-level cut edge calls the editors use (editing §5.10): the inline offer and Fix Cut Edges, a recording
/// whose waveform is not loaded, the freeze inputs, and an edge in a later recording. The algorithm itself is pinned
/// by the shared `cut-edges/*` and `session/cut-edge-*` vectors in EditingFixtures.
@Suite(.offlineFixtures) struct CutEdgesTests {
    /// V1 of the spec table: touching w1, w2, w3 with w2 cut, a quiet w1|w2 edge and a dip after w2 at frames 119–121.
    static func v1Envelope() -> AudioEnvelope {
        var levels = [Float](repeating: 0x1p-9, count: 300)
        for frame in 30...189 { levels[frame] = 0.5 }
        for frame in Array(79...81) + Array(119...121) { levels[frame] = 0.0625 }
        return AudioEnvelope(sampleRate: 16_000, frameSeconds: 0.01, levels: levels)
    }

    static func words() -> [TimedWord] {
        [("w1", 0.30, 0.80), ("w2", 0.80, 1.30), ("w3", 1.30, 1.90)].map {
            TimedWord(id: $0.0, text: $0.0, kind: .word, start: $0.1, end: $0.2)
        }
    }

    static func project(cut: [String] = ["w2"]) throws -> Project {
        var project = try ContextDemoProject.upgradeToV4(JSONProjectStore.decode(FixtureLoader.data("fixtures/projects/interview-take.voxclip")))
        project.transcript?.words = words()
        project.transcript?.durationSeconds = 3
        project.media.source.durationSeconds = 3
        project.edits = ProjectEdits(pauseThresholdSeconds: 0.8, cutWordIds: cut)
        return project
    }

    @Test func theOfferCountsOldCutsAndFixMovesThemInOneStep() throws {
        let project = try Self.project()
        let key = project.media.source.contentKey
        #expect(CutEdges.offer(project, envelopes: [key: Self.v1Envelope()]) == CutEdges.Offer(count: 1, frozen: 0, unloaded: []))
        let (fixed, offer) = try CutEdges.fix(project, envelopes: [key: Self.v1Envelope()])
        #expect(offer.count == 1)
        #expect(fixed.edits.cutEdges == ["w3": 1.205])
        #expect(fixed.schemaVersion == 8)
        #expect(CutEdges.offer(fixed, envelopes: [key: Self.v1Envelope()]).count == 0)
        let plan = try EditPlan.build(transcript: try #require(fixed.transcript), editState: try #require(try EditState(project: fixed)),
                                      activeClip: nil, duration: 3, sampleRate: 48_000)
        #expect(plan.cuts == [MediaInterval(startSample: 38_400, endSample: 57_840)])
    }

    @Test func aWaveformThatIsNotLoadedLeavesTodaysPadding() throws {
        let before = try Self.project(cut: [])
        var after = before
        try after.applyEditing(.toggle(id: "w2"))
        let committed = try CutEdges.finalize(before: before, after: after, envelopes: [:])
        #expect(committed.edits.cutEdges.isEmpty && committed.schemaVersion == before.schemaVersion)
        #expect(CutEdges.offer(committed, envelopes: [:]).unloaded == [before.media.source.contentKey])
    }

    @Test func voicePatchesAndPaidScopesKeepTheirEdgesAndAreCounted() throws {
        let project = try Self.project()
        let key = project.media.source.contentKey
        let voice = [key: CutEdges.Freeze(voiceRanges: [TimeRange(start: 1.30, end: 1.90)])]
        #expect(CutEdges.offer(project, envelopes: [key: Self.v1Envelope()], freeze: voice) == CutEdges.Offer(count: 0, frozen: 1, unloaded: []))
        let paid = [key: CutEdges.Freeze(paidScopes: [ClipWordRange(startWordId: "w3", endWordId: "w3")])]
        #expect(try CutEdges.fix(project, envelopes: [key: Self.v1Envelope()], freeze: paid).project.edits.cutEdges.isEmpty)
        let inside = [key: CutEdges.Freeze(paidScopes: [ClipWordRange(startWordId: "w2", endWordId: "w3")])]
        #expect(try CutEdges.fix(project, envelopes: [key: Self.v1Envelope()], freeze: inside).project.edits.cutEdges == ["w3": 1.205])
    }

    @Test func anEdgeInALaterRecordingIsStoredInItsLocalSecondsAndPlannedOnTheClock() throws {
        var project = try ProjectJSON.decode(FixtureLoader.data("fixtures/recordings/two-recordings.voxclip"))
        var sources = try #require(project.media.spokenSources)
        sources[0].transcript.words = Self.words()
        project.media.spokenSources = sources
        let companion = try #require(project.media.additionalSources.firstIndex { $0.contentKey == sources[0].sourceKey })
        project.media.additionalSources[companion].durationSeconds = 3
        project.edits.cutWordIds = []
        project.edits.cutPauseIds = []
        project.edits.clips = []
        project.edits.activeClipId = nil
        project.edits.corrections = [:]
        var after = project
        try after.applyEditing(.toggle(id: "r2.w2"))
        let key = sources[0].sourceKey
        // The companion's own envelope and seconds: the key stores 1.205, not its clock time.
        let committed = try CutEdges.finalize(before: project, after: after, envelopes: [key: Self.v1Envelope()])
        #expect(committed.edits.cutEdges == ["r2.w3": 1.205])
        #expect(committed.schemaVersion == 8)
        let reloaded = try ProjectJSON.decode(ProjectJSON.encode(committed))
        #expect(reloaded.edits.cutEdges == ["r2.w3": 1.205])
        let state = try #require(try EditState(project: reloaded))
        let plan = try EditPlan.build(transcript: state.transcript, editState: state, activeClip: nil, duration: 0, sampleRate: 48_000)
        let offset = Int64(sources[0].offsetSeconds * 48_000)
        #expect(plan.cuts.contains { $0.startSample == offset + 38_400 && $0.endSample == offset + 57_840 })
        let restored = try CutEdges.finalize(before: committed, after: project, envelopes: [key: Self.v1Envelope()])
        #expect(restored.edits.cutEdges.isEmpty && restored.schemaVersion == 7)
    }
}
