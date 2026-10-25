import Foundation
import Testing
@testable import VoxClipCore

@Suite struct VoiceLabProjectTests {
    private func fixture(_ name: String = "passage-project") throws -> Project {
        try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/\(name).voxclip"))
    }
    private func expected() throws -> FixtureValue {
        FixtureValue(try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/voice-lab/plan-cases.json")))
    }
    private func pairs(_ value: FixtureValue) -> [[Double]] { value.array.map { $0.array.map(\.number) } }

    @Test func versionedRoundTripAndFutureRejection() throws {
        let v1 = try JSONProjectStore.decode(FixtureLoader.data("fixtures/projects/interview-take.voxclip"))
        #expect(v1.schemaVersion == 1 && v1.voiceLab.assets == nil)
        let v1Data = try JSONProjectStore.encode(v1)
        #expect(try JSONProjectStore.decode(v1Data) == v1)
        let v2 = try fixture()
        #expect(v2.schemaVersion == 2 && v2.voiceLab.segments.count == 1)
        #expect(try JSONProjectStore.decode(JSONProjectStore.encode(v2)) == v2)
        var future = v2; future.schemaVersion = 3
        #expect(throws: VoxClipError.projectTooNew) { try JSONProjectStore.decode(ProjectJSON.encoder().encode(future)) }
        var unknown = v2; unknown.extensions = ["example.keep": .object(["nested": .array([.number(7)])])]
        #expect(try JSONProjectStore.decode(JSONProjectStore.encode(unknown)).extensions == unknown.extensions)
    }

    @Test func invalidReferencesAndRangesAreTyped() throws {
        let good = try fixture()
        let raw = try #require(String(data: FixtureLoader.data("fixtures/voice-lab/passage-project.voxclip"), encoding: .utf8))
        let unsafe = raw.replacingOccurrences(of: good.id + "/asset-one.wav", with: good.id + "/asset-one:stream.wav")
        #expect(throws: VoiceLabProjectError.unsafePath) { try JSONProjectStore.decode(Data(unsafe.utf8)) }
        var badId = good; badId.id = "../outside"
        #expect(throws: VoiceLabProjectError.unsafePath) { try VoiceLabProject.validate(badId) }
        var changed = good; changed.voiceLab.assets![0].file = "../outside.wav"
        #expect(throws: VoiceLabProjectError.unsafePath) { try ProjectJSON.encode(changed) }
        for filename in ["asset-one:stream.wav", "asset-one..wav", "asset-one .wav", "con.wav"] {
            changed = good; changed.voiceLab.assets![0].file = good.id + "/" + filename
            #expect(throws: VoiceLabProjectError.unsafePath) { try ProjectJSON.encode(changed) }
        }
        changed = good; changed.voiceLab.assets![0].id = "con"; changed.voiceLab.assets![0].file = good.id + "/con.wav"
        #expect(throws: VoiceLabProjectError.unsafePath) { try ProjectJSON.encode(changed) }
        changed = good; changed.voiceLab.segments[0].audio.assetId = "missing"
        #expect(throws: VoiceLabProjectError.danglingAsset) { try ProjectJSON.encode(changed) }
        changed = good; changed.voiceLab.segments[0].replace.end = .infinity
        #expect(throws: VoiceLabProjectError.invalidRange) { try VoiceLabProject.validate(changed) }
        changed = good; changed.voiceLab.segments[0].replace.end = 2.5
        #expect(throws: VoiceLabProjectError.invalidRange) { try VoiceLabProject.validate(changed) }
        changed = good; changed.voiceLab.segments[0].words![1].start = 0.1
        #expect(throws: VoiceLabProjectError.invalidWords) { try VoiceLabProject.validate(changed) }
        changed = good; changed.voiceLab.segments[0].words![0].end = 0.0001
        #expect(throws: VoiceLabProjectError.invalidWords) { try VoiceLabProject.validate(changed) }
        changed = good; changed.voiceLab.segments[0].selectedCandidateIndex = 99
        #expect(throws: VoiceLabProjectError.invalidCandidate) { try VoiceLabProject.validate(changed) }
        changed = good; var duplicateWords = try #require(good.transcript)
        duplicateWords.words[1].id = duplicateWords.words[0].id
        changed.transcript = duplicateWords
        #expect(throws: VoiceLabProjectError.invalidRange) { try VoiceLabProject.validate(changed) }
        changed = good; var invalidWords = try #require(good.transcript)
        invalidWords.words[1].id = "../word"
        changed.transcript = invalidWords
        #expect(throws: VoiceLabProjectError.invalidRange) { try VoiceLabProject.validate(changed) }
        changed = good; var overlap = changed.voiceLab.segments[0]; overlap.id = "vl-overlap"; changed.voiceLab.segments.append(overlap)
        #expect(throws: VoiceLabProjectError.overlappingReplacement) { try VoiceLabProject.validate(changed) }
    }

    @Test func passageAndFullTakeUseCanonicalPieces() throws {
        let expected = try expected()
        let passage = try fixture()
        let plan = try VoiceLabOutputPlanner.build(passage, scope: .full)
        #expect(plan.outputSamples == expected["passage"]["outputSamples"].int)
        let pieceRows = plan.pieces.map { [$0.kind == .synth ? "synth" : "source", String($0.sourceStartSample), String($0.sourceEndSample), String($0.outputStartSample), String($0.outputEndSample)] }
        let expectedRows = expected["passage"]["pieces"].array.map { row in [row.array[0].string] + row.array.dropFirst().map { String($0.int) } }
        #expect(pieceRows == expectedRows)
        for row in pairs(expected["passage"]["mapping"]) {
            #expect(abs(plan.mapTime(row[0]) - row[1]) < 0.000001)
            #expect(abs(plan.sourceTime(row[1]) - row[0]) < 0.000001)
        }
        for row in expected["passage"]["captions"].array {
            let fields = row.array
            let caption = try #require(plan.captions.first { $0.id == fields[0].string })
            #expect(abs(caption.start - fields[1].number) < 0.000001)
            #expect(abs(caption.end - fields[2].number) < 0.000001)
        }
        #expect(throws: VoiceLabProjectError.unsupportedRendering) { try plan.requireLegacyRendering() }
        let full = try VoiceLabOutputPlanner.build(fixture("full-take-project"), scope: .full)
        #expect(full.outputSamples == expected["full"]["outputSamples"].int)
        #expect(full.pieces.count == 1 && full.pieces[0].kind == .synth)
        for row in pairs(expected["full"]["mapping"]) { #expect(abs(full.mapTime(row[0]) - row[1]) < 0.000001) }
    }

    @Test func clipScopeAndReversibleTransitions() throws {
        let original = try fixture()
        let full = try VoiceLabOutputPlanner.build(original, scope: .full)
        let clip = try VoiceLabOutputPlanner.build(original, scope: .clip("clip-main"))
        let fixtureExpected = try expected()
        #expect(full.outputSamples == 7300)
        #expect(clip.outputSamples == fixtureExpected["clip"]["outputSamples"].int)
        #expect(abs(clip.sourceTime(0) - 1.05) < 0.000001)
        #expect(abs(clip.sourceTime(clip.duration) - 7) < 0.000001)
        let disabled = try VoiceLabProject.setEnabled(false, id: "vl-passage", in: original)
        #expect(try VoiceLabOutputPlanner.build(disabled, scope: .full).outputSamples == 7000)
        #expect(try VoiceLabOutputPlanner.build(disabled, scope: .full).requiresSyntheticRendering == false)
        try VoiceLabProject.requireLegacyRendering(disabled)
        let restored = try VoiceLabProject.setEnabled(true, id: "vl-passage", in: disabled)
        #expect(restored == original)
        let selected = try VoiceLabProject.selectCandidate(1, id: "vl-passage", in: original)
        #expect(selected.voiceLab.segments[0].audio.assetId == "asset-two")
        #expect(original.voiceLab.segments[0].audio.assetId == "asset-one")
        let deleted = try VoiceLabProject.delete(id: "vl-passage", in: original)
        #expect(deleted.voiceLab.assets?.count == 2)
        #expect(try VoiceLabOutputPlanner.build(deleted, scope: .full).outputSamples == 7000)
        #expect(deleted.transcript == original.transcript && deleted.edits == original.edits)
        let v1 = try JSONProjectStore.decode(FixtureLoader.data("fixtures/projects/interview-take.voxclip"))
        let accepted = try VoiceLabProject.accept(original.voiceLab.segments[0], assets: original.voiceLab.assets!, into: v1)
        #expect(accepted.schemaVersion == 2 && v1.schemaVersion == 1)
    }

    @Test func seamCutsAndVoiceChangerCaptions() throws {
        let original = try fixture()
        var edited = original
        edited.edits.cutWordIds = ["w4", "w6"] // w4 is covered; w6 reach enters the seam.
        let plan = try VoiceLabOutputPlanner.build(edited, scope: .full)
        #expect(plan.outputSamples == 7050)
        #expect(plan.pieces.contains { $0.kind == .synth && $0.sourceStartSample == 2500 && $0.sourceEndSample == 3200 })
        let disabled = try VoiceLabProject.setEnabled(false, id: "vl-passage", in: edited)
        #expect(try VoiceLabOutputPlanner.build(disabled, scope: .full).outputSamples < 7000)
        var changer = original
        changer.voiceLab.segments[0].kind = .voiceChanger
        changer.voiceLab.segments[0].text = nil
        changer.voiceLab.segments[0].words = nil
        let converted = try VoiceLabOutputPlanner.build(changer, scope: .full)
        let sourceWord = try #require(converted.captions.first { $0.id == "w4" })
        #expect(sourceWord.text == "we")
        #expect(abs(sourceWord.start - (2.5 + 0.1 / 0.7)) < 0.000001)
        var badClip = original
        badClip.edits.clips[0].endWordId = "w5"
        #expect(throws: VoiceLabProjectError.invalidScope) { try VoiceLabOutputPlanner.build(badClip, scope: .clip("clip-main")) }
    }

    @Test func storeSaveAndReopenRetainsEnabledReplacement() async throws {
        let project = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("take.voxclip")
        let store = JSONProjectStore()
        try await store.save(project, to: path)
        let reopened = try await store.load(from: path)
        #expect(reopened.schemaVersion == 2 && reopened.voiceLab == project.voiceLab)
        #expect(try VoiceLabOutputPlanner.build(reopened, scope: .full).outputSamples == 7300)
    }
}
