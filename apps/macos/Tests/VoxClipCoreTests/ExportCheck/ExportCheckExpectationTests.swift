import Foundation
import Testing
@testable import VoxClipCore

/// What the export check expects to hear (ADR-R49), from the same timeline the renderer plays.
@Suite(.offlineFixtures) struct ExportCheckExpectationTests {
    /// "So um, today we ship uh the clipper. Thanks" with a Rewrite of "we ship" as "new words" (segment vl-passage).
    private func passage() throws -> Project {
        try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
    }

    private func state(_ project: Project, clipID: String) throws -> EditState {
        let transcript = try #require(project.transcript)
        let edits = project.edits
        return EditState(transcript: transcript, pauses: try detectPauses(transcript.words, thresholdSeconds: edits.pauseThresholdSeconds),
                         pauseThresholdSeconds: edits.pauseThresholdSeconds, pauseKeepSeconds: edits.pauseKeepSeconds,
                         cutWordIds: Set(edits.cutWordIds), cutPauseIds: Set(edits.cutPauseIds), corrections: edits.corrections,
                         clips: edits.clips, activeClipId: clipID)
    }

    @Test func aRewrittenPhraseIsExpectedWithItsNewWordsWhereTheEditPlacedThem() throws {
        let project = try passage()
        let timeline = try RenderCallerInputs.timeline(project: project, clipID: "clip-main")
        guard case .voiceLab(let plan) = timeline else { Issue.record("the Rewrite renders on the Voice Lab path"); return }
        let edit = try ExportCheckExpectation.edit(timeline: timeline, speed: ClipSpeedTiming(speed: 1), effects: [], state: nil,
                                                   duration: plan.duration)
        #expect(edit.words.map(\.text) == ["today", "new", "words", "uh", "the", "clipper."])
        // The source words it replaced are not expected; the new ones are, in the phrase, at the plan's placed times.
        let phrase = try #require(edit.phrases.first)
        #expect(edit.phrases.count == 1 && phrase.id == "vl-passage")
        let placed = edit.words.filter { $0.phrase == "vl-passage" }
        #expect(placed.map(\.text) == ["new", "words"])
        let piece = try #require(plan.pieces.first { $0.segmentId == "vl-passage" })
        let pieceStart = Double(piece.outputStartSample) / plan.sampleRate
        #expect(abs((placed.first?.start ?? 0) - (pieceStart + 0.1)) < 1e-4, "the TTS word time inside the piece")
        #expect(phrase.start == pieceStart)
        // The kept filler is optional; the seams before and after the phrase are cuts.
        #expect(edit.words.first { $0.text == "uh" }?.optional == true && edit.words.filter(\.optional).count == 1)
        #expect(edit.cuts.contains { abs($0 - pieceStart) < 1e-9 })
        #expect(edit.cuts.contains { abs($0 - Double(piece.outputEndSample) / plan.sampleRate) < 1e-9 })
    }

    @Test func sourceWordsAreExpectedThroughThePlanAtTheClipSpeed() throws {
        var project = try passage()
        project.schemaVersion = 4
        project.voiceLab = ProjectVoiceLab(assets: [], cleanAudio: .init(mode: .off), voices: [], videoAssets: [])
        project.edits.cutWordIds = ["w5"]
        project.edits.clips = [ClipRange(id: "scope", startWordId: "w1", endWordId: "w8")]
        let timeline = try RenderCallerInputs.timeline(project: project, clipID: "scope")
        guard case .legacy(let plan) = timeline else { Issue.record("no Voice Lab, the legacy plan"); return }
        let state = try state(project, clipID: "scope")
        let plain = try ExportCheckExpectation.edit(timeline: timeline, speed: ClipSpeedTiming(speed: 1), effects: [], state: state,
                                                    duration: plan.duration)
        #expect(plain.words.map(\.text) == ["So", "um,", "today", "we", "uh", "the", "clipper."])
        #expect(plain.words.filter(\.optional).map(\.text) == ["um,", "uh"], "kept fillers are optional")
        #expect(plain.phrases.isEmpty)
        // One join, where "ship" was cut: between "we" and "uh".
        #expect(plain.cuts.count == plan.kept.count - 1 && plain.cuts.count == 1)
        let we = try #require(plain.words.first { $0.text == "we" }), uh = try #require(plain.words.first { $0.text == "uh" })
        #expect(plain.cuts.allSatisfy { $0 > we.end && $0 < uh.start }, "\(plain.cuts) between \(we.end) and \(uh.start)")
        // At 2× every output time halves.
        let fast = try ExportCheckExpectation.edit(timeline: timeline, speed: ClipSpeedTiming(speed: 2), effects: [], state: state,
                                                   duration: plan.duration / 2)
        #expect(zip(plain.words, fast.words).allSatisfy { abs($0.start / 2 - $1.start) < 1e-12 && abs($0.end / 2 - $1.end) < 1e-12 })
        #expect(zip(plain.cuts, fast.cuts).allSatisfy { abs($0 / 2 - $1) < 1e-12 })
        // A bleeped word is not heard, so it is not expected.
        let bleep = ClipEffect(id: "fx-bleep-1", clipId: "scope", kind: .bleep, start: 2.6, end: 2.75, wordIds: ["w4"])
        let bleeped = try ExportCheckExpectation.edit(timeline: timeline, speed: ClipSpeedTiming(speed: 1), effects: [bleep], state: state,
                                                      duration: plan.duration)
        #expect(bleeped.words.map(\.text) == ["So", "um,", "today", "uh", "the", "clipper."])
    }

    @Test func theTakeQAAndTheCheckShareOneAlignment() throws {
        let pairs = VoiceLabTakeQuality.alignment(expected: ["we", "close", "deals", "today"], recognized: ["we", "close", "details", "today"])
        #expect(pairs.map(\.expected) == [0, 1, 3] && pairs.map(\.recognized) == [0, 1, 3])
        #expect(VoiceLabTakeQuality.alignment(expected: [], recognized: ["a"]).isEmpty)
        // The ratio is twice the shared tokens over both counts, as before.
        #expect(try VoiceLabTakeQuality.transcriptRatio(expected: ["we", "close", "deals", "today"], recognized: ["we", "close", "details", "today"]) == 0.75)
    }
}
