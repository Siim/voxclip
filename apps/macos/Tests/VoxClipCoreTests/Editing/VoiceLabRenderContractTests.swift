import Foundation
import Testing
@testable import VoxClipCore

@Suite struct VoiceLabRenderContractTests {
    private func fixture(_ name: String = "passage-render-v3") throws -> Project {
        try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/\(name).voxclip"))
    }
    @Test func passageAndFullTakePrepareAndRoundTrip() throws {
        let passage = try fixture()
        #expect(passage.schemaVersion == 3)
        #expect(try ProjectJSON.decode(ProjectJSON.encode(passage)) == passage)
        let prepared = try VoiceLabRenderContract.prepare(passage, scope: .full, labelPosition: .topRight)
        #expect(prepared.outputPlan.outputSamples == 7000)
        #expect(prepared.selectedSegmentRecipes.count == 1)
        #expect(prepared.disclosure.required && !prepared.disclosure.persistent)
        #expect(prepared.disclosure.outputAISeconds == 0.7)
        #expect(prepared.disclosure.intervals == [VoiceLabLabelInterval(start: 0, end: 3.7)])
        #expect(prepared.disclosure.fadeSeconds == 0.15)
        try prepared.verify(project: passage, scope: .full, labelPosition: .topRight)
        var stale = passage
        stale.captions.styleId = "vox-highlight"
        #expect(throws: VoiceLabProjectError.staleRenderContract) { try prepared.verify(project: stale, scope: .full, labelPosition: .topRight) }
        let full = try VoiceLabRenderContract.prepare(fixture("full-take-render-v3"), scope: .full, labelPosition: .bottomLeft)
        #expect(full.selectedSegmentRecipes[0].recipe.chunks.count == 2)
        #expect(full.disclosure.persistent && full.disclosure.intervals == [VoiceLabLabelInterval(start: 0, end: 7)])
    }
    @Test func selectionAndSourceRestore() throws {
        let original = try fixture()
        let chosen = try VoiceLabProject.selectCandidate(1, id: "vl-passage", in: original)
        #expect(chosen.voiceLab.segments[0].audio.trimStart == 0.2)
        #expect(chosen.voiceLab.segments[0].audio.gainDb == -1)
        #expect(chosen.voiceLab.segments[0].provenance.seed == 8)
        #expect(chosen.voiceLab.segments[0].words?.first?.start == 0.12)
        #expect(try VoiceLabRenderContract.prepare(chosen, scope: .full, labelPosition: .topLeft).selectedSegmentRecipes[0].recipe.seed == 8)
        #expect(try VoiceLabProject.selectCandidate(0, id: "vl-passage", in: chosen) == original)
        let disabled = try VoiceLabProject.setEnabled(false, id: "vl-passage", in: original)
        #expect(try VoiceLabRenderContract.prepare(disabled, scope: .full, labelPosition: .topRight).selectedSegmentRecipes.isEmpty)
        #expect(try VoiceLabProject.setEnabled(true, id: "vl-passage", in: disabled) == original)
        let deleted = try VoiceLabProject.delete(id: "vl-passage", in: original)
        #expect(deleted.voiceLab.assets?.count == 2)
        #expect(try VoiceLabRenderContract.prepare(deleted, scope: .full, labelPosition: .topRight).disclosure.required == false)
        #expect(throws: VoiceLabProjectError.needsVoiceLabUpgrade) { try VoiceLabRenderContract.prepare(fixture("passage-project"), scope: .full, labelPosition: .topRight) }
    }
    @Test func invalidPolicyAndVideoCapability() throws {
        let good = try fixture()
        var bad = good
        bad.voiceLab.segments[0].candidates[0].recipe = nil
        #expect(throws: VoiceLabProjectError.missingRenderPolicy) { try VoiceLabProject.validate(bad) }
        bad = good
        bad.voiceLab.segments[0].candidates[0].recipe!.roomTone = nil
        #expect(throws: VoiceLabProjectError.missingRenderPolicy) { try VoiceLabProject.validate(bad) }
        bad = good
        bad.voiceLab.segments[0].candidates[0].recipe!.seams.in.assetHandleFrames = 1
        #expect(throws: VoiceLabProjectError.invalidFadeHandles) { try VoiceLabProject.validate(bad) }
        bad = good
        bad.voiceLab.segments[0].candidates[0].recipe!.qa.peakDbfs = .nan
        #expect(throws: VoiceLabProjectError.qaRejected) { try VoiceLabProject.validate(bad) }
        bad = good
        bad.voiceLab.segments[0].candidates[0].recipe!.video.mode = .retimed
        bad.voiceLab.segments[0].candidates[0].recipe!.video.retimeFactor = 1
        try VoiceLabProject.validate(bad)
        #expect(throws: VoiceLabProjectError.videoModeUnsupported) { try VoiceLabRenderContract.prepare(bad, scope: .full, labelPosition: .topRight) }
        let raw = try #require(String(data: FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"), encoding: .utf8))
        #expect(throws: DecodingError.self) { try ProjectJSON.decode(Data(raw.replacingOccurrences(of: "\"mode\": \"source\"", with: "\"mode\": \"unrecognised\"").utf8)) }
    }
    @Test func disclosureThresholdsAndStockConversion() throws {
        let at = try VoiceLabRenderContract.prepare(fixture("disclosure-at-30-render-v3"), scope: .full, labelPosition: .topRight)
        let above = try VoiceLabRenderContract.prepare(fixture("disclosure-above-30-render-v3"), scope: .full, labelPosition: .topRight)
        #expect(at.disclosure.outputAISeconds == 2.1 && !at.disclosure.persistent)
        #expect(above.disclosure.outputAISeconds == 2.101 && above.disclosure.persistent)
        let stock = try VoiceLabRenderContract.prepare(fixture("voice-changer-half-render-v3"), scope: .full, labelPosition: .topRight)
        #expect(stock.disclosure.outputAISeconds == 3.5 && stock.disclosure.persistent)
        #expect(stock.disclosure.kinds == ["voiceChanger"])
        #expect(stock.disclosure.postText == "The voice in this video was changed with AI.")
    }
    @Test func chunksAndChangedDurationSourceCapability() throws {
        let good = try fixture("full-take-render-v3")
        var bad = good
        bad.voiceLab.segments[0].candidates[0].recipe!.chunks.removeLast()
        #expect(throws: VoiceLabProjectError.invalidRange) { try VoiceLabProject.validate(bad) }
        var passage = try fixture()
        var recipe = try #require(passage.voiceLab.segments[0].candidates[0].recipe)
        recipe.outDuration = 0.75
        recipe.audio.trimEnd = 0.85
        recipe.audio.stretch = 1
        recipe.chunks[0].assembledEndFrame = 20400
        recipe.video.outputSamples = 750
        passage.voiceLab.segments[0].candidates[0].recipe = recipe
        passage.voiceLab.segments[0].outDuration = 0.75
        passage.voiceLab.segments[0].audio = recipe.audio
        try VoiceLabProject.validate(passage)
        #expect(throws: VoiceLabProjectError.videoModeUnsupported) {
            try VoiceLabRenderContract.prepare(passage, scope: .full, labelPosition: .topRight)
        }
    }
    @Test func acceptRejectsMalformedCandidateIndices() throws {
        let project = try fixture()
        var segment = project.voiceLab.segments[0]
        segment.candidates = []
        #expect(throws: VoiceLabProjectError.invalidCandidate) { try VoiceLabProject.accept(segment, assets: [], into: project) }
        segment = project.voiceLab.segments[0]
        segment.selectedCandidateIndex = 99
        #expect(throws: VoiceLabProjectError.invalidCandidate) { try VoiceLabProject.accept(segment, assets: [], into: project) }
    }
    @Test func selectedScopeSeamWindows() throws {
        let touching = try fixture("touching-render-v3")
        let prepared = try VoiceLabRenderContract.prepare(touching, scope: .full, labelPosition: .topRight)
        #expect(prepared.selectedSegmentRecipes.count == 2)
        #expect(prepared.outputPlan.pieces.filter { $0.kind == .synth }.count == 2)
        let gap = try fixture("one-sample-gap-render-v3")
        let gapPlan = try VoiceLabOutputPlanner.build(gap, scope: .full)
        #expect(gapPlan.pieces.contains { $0.kind == .source && $0.sourceEndSample - $0.sourceStartSample == 1 })
        #expect(throws: VoiceLabProjectError.overlappingFades) { try VoiceLabRenderContract.prepare(gap, scope: .full, labelPosition: .topRight) }
        let clipped = try fixture("clipped-seam-render-v3")
        #expect(throws: VoiceLabProjectError.invalidFadeHandles) { try VoiceLabRenderContract.prepare(clipped, scope: .clip("clip-edge"), labelPosition: .topRight) }
        #expect(try VoiceLabRenderContract.prepare(clipped, scope: .full, labelPosition: .topRight).selectedSegmentRecipes.count == 2)
    }
    @Test func stretchedAssetHandlesUseRawFramesAtTheAssetRate() throws {
        let original = try fixture()
        func withHandles(_ incoming: Int64, _ outgoing: Int64) -> Project {
            var project = original
            var segment = project.voiceLab.segments[0]
            var recipe = segment.candidates[0].recipe!
            recipe.audio.trimEnd = 0.856
            recipe.audio.stretch = 0.7 / (0.856 - 0.1)
            recipe.chunks[0].assembledEndFrame = 20_544
            recipe.seams.in.assetHandleFrames = incoming
            recipe.seams.out.assetHandleFrames = outgoing
            segment.audio = recipe.audio
            segment.candidates[0].recipe = recipe
            project.voiceLab.segments[0] = segment
            return project
        }
        // 10 output samples at 1 kHz require ceil(10 * 24 kHz / (1 kHz * (0.7 / 0.756))) = 260 raw frames.
        let sufficient = withHandles(260, 260)
        try VoiceLabProject.validate(sufficient)
        #expect(try VoiceLabRenderContract.prepare(sufficient, scope: .full, labelPosition: .topRight).selectedSegmentRecipes.count == 1)
        #expect(throws: VoiceLabProjectError.invalidFadeHandles) { try VoiceLabProject.validate(withHandles(259, 260)) }
        #expect(throws: VoiceLabProjectError.invalidFadeHandles) { try VoiceLabProject.validate(withHandles(260, 259)) }
    }
    @Test func touchingSynthSeamUsesOneHalfHandleFromEachAsset() throws {
        let original = try fixture("touching-render-v3")
        func withHandles(_ outgoing: Int64, _ incoming: Int64) -> Project {
            var project = original
            project.voiceLab.segments[0].candidates[0].recipe!.seams.out.assetHandleFrames = outgoing
            project.voiceLab.segments[1].candidates[0].recipe!.seams.in.assetHandleFrames = incoming
            return project
        }
        // Each side of the one 20-sample seam supplies 10 output samples: 240 frames at 24 kHz.
        let sufficient = withHandles(240, 240)
        try VoiceLabProject.validate(sufficient)
        let prepared = try VoiceLabRenderContract.prepare(sufficient, scope: .full, labelPosition: .topRight)
        #expect(prepared.selectedSegmentRecipes.count == 2)
        #expect(prepared.selectedSegmentRecipes[0].recipe.seams.out.fadeSamples == 20)
        #expect(prepared.selectedSegmentRecipes[1].recipe.seams.in.fadeSamples == 20)
        #expect(throws: VoiceLabProjectError.invalidFadeHandles) { try VoiceLabProject.validate(withHandles(239, 240)) }
        #expect(throws: VoiceLabProjectError.invalidFadeHandles) { try VoiceLabProject.validate(withHandles(240, 239)) }
    }
    @Test func halfUpAndRequestBinding() throws {
        let cases = try JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/render-cases.json")) as! [String: [String: Any]]
        let vector = cases["sample-grid-half-up"]!
        #expect(EditingPrimitives.jsRound((vector["seconds"] as! Double) * (vector["rate"] as! Double)) == Double(vector["samples"] as! Int))
        let project = try fixture()
        let prepared = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
        #expect(throws: VoiceLabProjectError.staleRenderContract) { try prepared.verify(project: project, scope: .clip("clip-main"), labelPosition: .topRight) }
        let changed = try VoiceLabProject.selectCandidate(1, id: "vl-passage", in: project)
        #expect(throws: VoiceLabProjectError.staleRenderContract) { try prepared.verify(project: changed, scope: .full, labelPosition: .topRight) }
    }
    @Test func excludedScopeAndInvalidV3References() throws {
        var project = try fixture()
        project.edits.clips[0].startWordId = "w1"
        project.edits.clips[0].endWordId = "w2"
        let sourceOnly = try VoiceLabRenderContract.prepare(project, scope: .clip("clip-main"), labelPosition: .topRight)
        #expect(sourceOnly.selectedSegmentRecipes.isEmpty && !sourceOnly.disclosure.required)
        project = try fixture()
        project.voiceLab.assets![0].file = "../outside.wav"
        #expect(throws: VoiceLabProjectError.unsafePath) { try VoiceLabProject.validate(project) }
        project = try fixture()
        project.voiceLab.segments[0].audio.assetId = "missing"
        #expect(throws: VoiceLabProjectError.danglingAsset) { try VoiceLabProject.validate(project) }
        var future = try fixture(); future.schemaVersion = 4
        #expect(throws: VoxClipError.projectTooNew) { try ProjectJSON.decode(ProjectJSON.encoder().encode(future)) }
        var extended = try fixture(); extended.extensions = ["example.keep": .object(["value": .number(7)])]
        #expect(try ProjectJSON.decode(ProjectJSON.encode(extended)).extensions == extended.extensions)
        let raw = try #require(String(data: FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"), encoding: .utf8))
        let omitted = raw.replacingOccurrences(of: "      \"assetId\": null,\n", with: "")
        #expect(throws: VoxClipError.self) { try ProjectJSON.decode(Data(omitted.utf8)) }
        for missing in ["seams", "video", "qa", "consentVerifiedAt"] {
            var document = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            var voice = document["voiceLab"] as! [String: Any]
            var segments = voice["segments"] as! [[String: Any]]
            var candidates = segments[0]["candidates"] as! [[String: Any]]
            var recipe = candidates[0]["recipe"] as! [String: Any]
            recipe.removeValue(forKey: missing)
            candidates[0]["recipe"] = recipe; segments[0]["candidates"] = candidates
            voice["segments"] = segments; document["voiceLab"] = voice
            let incomplete = try JSONSerialization.data(withJSONObject: document)
            #expect(throws: VoxClipError.self) { try ProjectJSON.decode(incomplete) }
        }
    }
    @Test func malformedV3ContainerShapesReject() throws {
        let raw = try FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip")
        func reject(_ name: String, _ change: (inout [String: Any]) -> Void) throws {
            var document = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            change(&document)
            let malformed = try JSONSerialization.data(withJSONObject: document)
            var rejected = false
            do { _ = try ProjectJSON.decode(malformed) }
            catch is VoxClipError { rejected = true }
            catch is DecodingError { rejected = true }
            #expect(rejected, "\(name) must reject malformed project data")
        }
        try reject("voiceLab") { $0["voiceLab"] = 42 }
        for field in ["cleanAudio", "voices", "segments"] {
            try reject(field) { document in
                var voice = document["voiceLab"] as! [String: Any]
                voice[field] = 42
                document["voiceLab"] = voice
            }
        }
        try reject("seams") { document in
            var voice = document["voiceLab"] as! [String: Any]
            var segments = voice["segments"] as! [[String: Any]]
            var candidates = segments[0]["candidates"] as! [[String: Any]]
            var recipe = candidates[0]["recipe"] as! [String: Any]
            recipe["seams"] = 42
            candidates[0]["recipe"] = recipe
            segments[0]["candidates"] = candidates
            voice["segments"] = segments
            document["voiceLab"] = voice
        }
    }
}
