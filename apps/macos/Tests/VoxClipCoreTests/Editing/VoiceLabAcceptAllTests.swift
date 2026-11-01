import Foundation
import Testing
@testable import VoxClipCore

@Suite struct VoiceLabAcceptAllTests {
    struct Vectors: Decodable {
        let inputs: [String: Input]
        let cases: [Case]
    }
    struct Input: Decodable {
        var project: Project
        var segments: [VoiceLabSegment]
        var assets: [VoiceLabAsset]
        var voice: VoiceLabVoiceReference
    }
    struct Case: Decodable {
        let `case`: String
        let input: String
        let scope: String
        let expected: Expected
    }
    struct Expected: Decodable {
        let error: String?
        let segmentIDs: [String]?
    }
    private func vectors() throws -> Vectors {
        try ProjectJSON.decoder().decode(Vectors.self, from: FixtureLoader.data("fixtures/voice-lab/accept-all-cases.json"))
    }

    @Test func everySharedAcceptanceVector() throws {
        let vectors = try vectors()
        for row in vectors.cases {
            let input = try #require(vectors.inputs[row.input])
            let before = input.project
            let scope: VoiceLabOutputScope = row.scope == "full" ? .full : .clip(row.scope)
            let command = VoiceLabEditCommand.acceptAll(segments: input.segments, assets: input.assets, voice: input.voice)
            do {
                let result = try command.applying(to: input.project, outputScope: scope)
                #expect(row.expected.error == nil, "\(row.case): expected \(row.expected.error ?? "success")")
                #expect(result.voiceLab.segments.map(\.id) == row.expected.segmentIDs, "\(row.case)")
                #expect(result.voiceLab.assets?.count == input.assets.count, "\(row.case)")
                #expect(result.transcript == before.transcript && result.edits == before.edits, "\(row.case)")
                #expect(try JSONProjectStore.decode(JSONProjectStore.encode(result)) == result, "\(row.case)")
            } catch {
                #expect(String(describing: error) == row.expected.error, "\(row.case): \(error)")
            }
            #expect(input.project == before, "\(row.case): input must never change")
        }
    }

    @Test func mixedSetWithCutsAndCorrectionsSurvivesSaveAndLoad() async throws {
        var input = try #require(vectors().inputs["mixed"])
        input.project.edits.cutWordIds = ["w1"]
        input.project.edits.cutPauseIds = ["pause-after-w3"]
        input.project.edits.corrections["w2"] = "Corrected"
        let accepted = try VoiceLabEditCommand.acceptAll(segments: input.segments, assets: input.assets, voice: input.voice)
            .applying(to: input.project)
        #expect(accepted.voiceLab.segments.map(\.kind) == [.tts, .voiceChanger])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-c4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("mixed.voxclip")
        let store = JSONProjectStore(appVersion: "9.8.7")
        try await store.save(accepted, to: path)
        let loaded = try await store.load(from: path)
        #expect(loaded.voiceLab == accepted.voiceLab && loaded.edits == accepted.edits)
        #expect(loaded.transcript == accepted.transcript)
        var normalized = loaded
        // Save updates writer/time and a project-relative media path by the established store contract.
        normalized.modifiedAt = accepted.modifiedAt
        normalized.savedBy = accepted.savedBy
        normalized.media.source.relativePath = accepted.media.source.relativePath
        #expect(normalized == accepted)
        #expect(loaded.edits.cutWordIds.contains("w1") && loaded.edits.corrections["w2"] == "Corrected")
        #expect(loaded.edits.cutPauseIds == ["pause-after-w3"])
        try VoiceLabProject.validate(loaded, scope: .full, accepting: input.segments)
    }

    @Test func wholeSetUpgradesV1AndSegmentFreeV2() throws {
        let input = try #require(vectors().inputs["group"])
        let command = VoiceLabEditCommand.acceptAll(segments: input.segments, assets: input.assets, voice: input.voice)
        for version in [1, 2] {
            var original = input.project
            original.schemaVersion = version
            original.voiceLab = version == 1 ? ProjectVoiceLab() : ProjectVoiceLab(segments: [], assets: [])
            let accepted = try command.applying(to: original)
            #expect(accepted.schemaVersion == 3 && accepted.voiceLab.segments == input.segments)
            #expect(accepted.transcript == original.transcript && accepted.edits == original.edits)
        }
    }

    @Test func singleAcceptIsTheSameTransitionAsOneElementSet() throws {
        let input = try #require(vectors().inputs["single"])
        let segment = try #require(input.segments.first)
        let single = try VoiceLabEditCommand.accept(segment, assets: input.assets, voice: input.voice).applying(to: input.project)
        let batch = try VoiceLabEditCommand.acceptAll(segments: [segment], assets: input.assets, voice: input.voice).applying(to: input.project)
        #expect(single == batch)
        let voiced = try VoiceLabProject.addVoiceReference(input.voice, to: input.project)
        #expect(try VoiceLabProject.accept(segment, assets: input.assets, into: voiced) ==
            VoiceLabProject.acceptAll([segment], assets: input.assets, into: voiced))
    }
}
