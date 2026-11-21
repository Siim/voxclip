#if DEBUG
import Foundation
import Testing
import VoxClipCore
import VoxClipMedia
@testable import VoxClip

@Suite("Local editorial illustration suggestions")
struct EditorialIllustrationSuggestionsTests {
    private let clipID = "clip-editorial"

    private func project(_ text: String, wordSeconds: Double = 0.24) throws -> Project {
        let fixture = try SharedResources.locate().root.appendingPathComponent("fixtures/projects/interview-take.voxclip")
        var project = try JSONProjectStore.decode(Data(contentsOf: fixture))
        let words = text.split(separator: " ").enumerated().map { index, text in
            let start = 0.3 + Double(index) * wordSeconds
            return TimedWord(id: "word-\(index)", text: String(text), start: start, end: start + wordSeconds * 0.8)
        }
        let duration = (words.last?.end ?? 0) + 0.5
        project.transcript?.words = words
        project.transcript?.durationSeconds = duration
        project.media.source.durationSeconds = duration
        project.edits.cutWordIds = []
        project.edits.cutPauseIds = []
        project.edits.corrections = [:]
        project.edits.clips = [ClipRange(id: clipID, startWordId: try #require(words.first?.id),
            endWordId: try #require(words.last?.id), origin: .manual)]
        project.edits.activeClipId = nil
        return project
    }

    @Test func comparisonsWinWithoutInventingWordingOrSuggestingEveryBeat() throws {
        var project = try project("The waves crashed against the rocks. It felt like a snow ball rolling downhill. It moved like a kite in the wind. A volcano erupted behind the village.")
        project.edits.corrections["word-10"] = "snowball"
        project.edits.cutWordIds = ["word-11"]
        var suggestions = EditorialIllustrationSuggestions.find(in: project, clipID: clipID)
        #expect(suggestions.map(\.quote) == ["The waves crashed against the rocks.", "It moved like a kite in the wind."])

        project.transcript?.words.remove(at: 11)
        project.edits.cutWordIds = []
        suggestions = EditorialIllustrationSuggestions.find(in: project, clipID: clipID)
        #expect(suggestions.map(\.quote) == ["It felt like a snowball rolling downhill.", "It moved like a kite in the wind."])
        #expect(suggestions.first?.wordIDs == ["word-6", "word-7", "word-8", "word-9", "word-10", "word-12", "word-13"])
        #expect(suggestions.first?.reason.contains("comparison") == true)
    }

    @Test func sparseAndWeakClipsCanReturnZeroOrOne() throws {
        for text in ["We needed a rock solid strategic direction.", "I would like a rocket for my birthday.",
                     "Did it look like a rocket?", "The volcano never erupted here.",
                     "It felt like a story about a rocket.", "The wave of criticism broke the founder's confidence.",
                     "It looked like a rocket landed behind the hill and someone said that maybe it happened to be a satellite that had been drifting up there for years."] {
            let project = try project(text)
            #expect(EditorialIllustrationSuggestions.find(in: project, clipID: clipID).isEmpty)
        }
        let short = try project("It felt like a rocket.", wordSeconds: 0.09)
        #expect(EditorialIllustrationSuggestions.find(in: short, clipID: clipID).isEmpty)

        var repeated = try project("It looked like a rocket. It moved like a rocket.")
        #expect(EditorialIllustrationSuggestions.find(in: repeated, clipID: clipID).count == 1)
        repeated.transcript?.language = "de"
        #expect(EditorialIllustrationSuggestions.find(in: repeated, clipID: clipID).isEmpty)
    }

    @Test func rechecksScopeEveryWordAndTimingBeforeUse() throws {
        let original = try project("It looked like a spinning compass.")
        let suggestions = EditorialIllustrationSuggestions.find(in: original, clipID: clipID)
        #expect(suggestions.count == 1)
        #expect(EditorialIllustrationSuggestions.current(suggestions, in: original, clipID: clipID) == suggestions)

        var changed = original
        changed.title = "Harmless project rename"
        #expect(EditorialIllustrationSuggestions.current(suggestions, in: changed, clipID: clipID) == suggestions)
        changed.edits.corrections["word-4"] = "broken"
        #expect(EditorialIllustrationSuggestions.current(suggestions, in: changed, clipID: clipID).isEmpty)

        changed = original
        changed.transcript?.words[2].start += 0.01
        #expect(EditorialIllustrationSuggestions.current(suggestions, in: changed, clipID: clipID).isEmpty)
        changed = original
        changed.edits.clips[0].startWordId = "word-1"
        #expect(EditorialIllustrationSuggestions.current(suggestions, in: changed, clipID: clipID).isEmpty)
        changed = original
        changed.edits.clips[0].id = "different-clip"
        #expect(EditorialIllustrationSuggestions.current(suggestions, in: changed, clipID: "different-clip").isEmpty)
        changed = original
        changed.id = UUID().uuidString.lowercased()
        #expect(EditorialIllustrationSuggestions.current(suggestions, in: changed, clipID: clipID).isEmpty)
        changed = original
        changed.media.source.contentKey = String(repeating: "a", count: 64)
        #expect(EditorialIllustrationSuggestions.current(suggestions, in: changed, clipID: clipID).isEmpty)
    }

    @Test func rejectsOccupiedOrStaleNarrationAndNeverBackfillsReview() throws {
        var project = try project("The volcano erupted behind the village. A bridge collapsed over the ravine.")
        let initial = EditorialIllustrationSuggestions.find(in: project, clipID: clipID)
        #expect(initial.count == 2)
        let first = try #require(initial.first)
        let timeline = try RenderCallerInputs.timeline(project: project)
        let document = try ContextDemoDocument(project: project, planId: "test", timeline: timeline)
        let selection = try IllustrativeCutawaySelection.matching(project: project, clipID: clipID, selected: first.wordIDs,
            timeline: timeline, document: document)
        let asset = ContextDemoAsset(id: "other", requestId: "other", target: IllustrativeCutawayAssets.target,
            relativePath: try ContextDemoAsset.relativePath(projectId: project.id, assetId: "other"),
            sha256: String(repeating: "a", count: 64), durationSeconds: 2, pixelWidth: 128, pixelHeight: 128,
            byteSize: 100, createdAt: Date())
        project.contextDemo = try document.placing(asset: asset, placement: ContextDemoPlacement(id: "other", assetId: "other",
            source: TimeRange(start: 0, end: selection.duration), editedStartSeconds: selection.start), expectedRevision: 0)

        #expect(EditorialIllustrationSuggestions.current([first], in: project, clipID: clipID).isEmpty)
        #expect(EditorialIllustrationSuggestions.current(initial, in: project, clipID: clipID) == Array(initial.dropFirst()))
        #expect(EditorialIllustrationSuggestions.find(in: project, clipID: clipID) == Array(initial.dropFirst()))

        project.edits.cutWordIds = ["word-0"]
        #expect(EditorialIllustrationSuggestions.find(in: project, clipID: clipID).isEmpty)
    }

    @Test func skipsMotionAndCensorOverlapsButNotAnUnrelatedClip() throws {
        var project = try project("The river overflowed into the village.")
        project.motionCues = [MotionCue(id: "motion", clipID: "different-clip", sourceStart: 0.5, sourceEnd: 0.9)]
        #expect(EditorialIllustrationSuggestions.find(in: project, clipID: clipID).count == 1)
        project.motionCues = [MotionCue(id: "motion", clipID: clipID, sourceStart: 0.5, sourceEnd: 0.9)]
        #expect(EditorialIllustrationSuggestions.find(in: project, clipID: clipID).isEmpty)
        project.motionCues = []
        project.clipEffects = [ClipEffect(id: "censor", clipId: nil, kind: .mute, start: 0.5, end: 0.9, wordIds: ["word-1"])]
        #expect(EditorialIllustrationSuggestions.find(in: project, clipID: clipID).isEmpty)
    }
}
#endif
