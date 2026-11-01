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

    @Test func everySharedAcceptanceReviewVector() throws {
        struct ReviewVectors: Decodable {
            struct Row: Decodable {
                let `case`: String
                let input: String
                let segments: [VoiceLabSegment]
                let expected: Expected
            }
            let schema: String
            let cases: [Row]
        }
        let review = try ProjectJSON.decoder().decode(ReviewVectors.self,
            from: FixtureLoader.data("fixtures/voice-lab/accept-all-review-cases.json"))
        #expect(review.schema == "voxclip.accept-all-review.v1" && review.cases.count == 1)
        let inputs = try vectors().inputs
        for row in review.cases {
            let input = try #require(inputs[row.input])
            do {
                _ = try VoiceLabEditCommand.acceptAll(segments: row.segments, assets: [], voice: input.voice)
                    .applying(to: input.project)
                Issue.record("\(row.case): expected \(row.expected.error ?? "success")")
            } catch { #expect(String(describing: error) == row.expected.error, "\(row.case)") }
            let voiced = try VoiceLabProject.addVoiceReference(input.voice, to: input.project)
            #expect(throws: VoiceLabProjectError.invalidSegment, "\(row.case): direct transition") {
                _ = try VoiceLabProject.acceptAll(row.segments, assets: [], into: voiced)
            }
        }
    }

    private func window(_ segment: VoiceLabSegment) throws -> VoiceLabWindow {
        let recipe = try #require(segment.candidates[segment.selectedCandidateIndex].recipe)
        let start = recipe.video.sourceStartSample, end = recipe.video.sourceEndSample
        return VoiceLabWindow(firstWordId: segment.replace.firstWordId, lastWordId: segment.replace.lastWordId,
            leftBridgeWordIds: [], rightBridgeWordIds: [], start: segment.replace.start, end: segment.replace.end,
            startSample: start, endSample: end,
            leftSeam: .init(kind: recipe.seams.in.kind, time: segment.replace.start, sample: start, fadeSamples: recipe.seams.in.fadeSamples),
            rightSeam: .init(kind: recipe.seams.out.kind, time: segment.replace.end, sample: end, fadeSamples: recipe.seams.out.fadeSamples))
    }

    @Test func prePaymentProjectionUsesTheAcceptanceOutputRules() throws {
        let vectors = try vectors()
        // An accepted full-take group cannot lose one member and remain a structurally valid input.
        for row in vectors.cases where row.expected.error == nil && row.input != "group" {
            let input = try #require(vectors.inputs[row.input])
            let scope: VoiceLabOutputScope = row.scope == "full" ? .full : .clip(row.scope)
            let accepted = try VoiceLabEditCommand.acceptAll(segments: input.segments, assets: input.assets, voice: input.voice)
                .applying(to: input.project, outputScope: scope)
            for segment in input.segments {
                var without = accepted
                without.voiceLab.segments.removeAll { $0.id == segment.id }
                // Includes disjoint source, touching synth neighbors and a clip.
                do { try VoiceLabRenderContract.validatePlacement(without, scope: scope, window: window(segment)) }
                catch { Issue.record("\(row.case)/\(segment.id): \(error)") }
            }
        }
        let full = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/full-take-render-v3.voxclip"))
        let fullSegment = try #require(full.voiceLab.segments.first)
        var unvoiced = full; unvoiced.voiceLab.segments = []
        try VoiceLabRenderContract.validatePlacement(unvoiced, scope: .full, window: window(fullSegment))
        for name in ["outside-clip", "crosses-clip", "cut-invalidates-seam"] {
            let input = try #require(vectors.inputs[name])
            let row = try #require(vectors.cases.first(where: { $0.case == name }))
            let scope: VoiceLabOutputScope = row.scope == "full" ? .full : .clip(row.scope)
            do {
                try VoiceLabRenderContract.validatePlacement(input.project, scope: scope, window: window(input.segments[0]))
                Issue.record("\(name): expected \(row.expected.error ?? "success")")
            } catch { #expect(String(describing: error) == row.expected.error, "\(name)") }
        }
    }

    @Test func alternateScopeVectorPassesStructuralValidation() throws {
        let input = try #require(vectors().inputs["bad-alternate-scope-seam"])
        let voiced = try VoiceLabProject.addVoiceReference(input.voice, to: input.project)
        let structural = try VoiceLabProject.acceptAll(input.segments, assets: input.assets, into: voiced)
        try VoiceLabProject.validate(structural)
        // The selected recipe renders; only checking the unused candidate catches this refusal.
        _ = try VoiceLabRenderContract.prepare(structural, scope: .full, labelPosition: .topRight)
        #expect(throws: VoiceLabProjectError.invalidFadeHandles) {
            try VoiceLabProject.validate(structural, scope: .full, accepting: input.segments)
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
