import Foundation
import Testing
@testable import VoxClipCore

@Suite struct VoiceLabRenderContractTests {
    @Test func allSharedPostTextCombinationsReplayInBothLanguages() throws {
        struct Share: Decodable { let lines: [String: [String: String]] }
        let share = try JSONDecoder().decode(Share.self, from: FixtureLoader.data("fixtures/share/cases.json"))
        #expect(share.lines.count == 8)
        for (key, languages) in share.lines {
            let kinds = key.split(separator: "+").map { $0.hasPrefix("voiceChanger") ? "voiceChanger" : String($0) }
            for language in ["en", "et"] {
                #expect(VoiceLabRenderContract.disclosurePostText(kinds: kinds, ownVoice: key.contains("voiceChangerOwn"), language: language) == languages[language])
            }
        }
    }
    @Test func sharedDisclosureIntervalsUseTheExportedClipTimeline() throws {
        struct Vectors: Decodable {
            struct Case: Decodable { let id: String; let duration: Double; let segments: [[Double]]; let expected: [[Double]] }
            let cases: [Case]
        }
        let vectors = try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data("fixtures/voice-lab/disclosure-intervals.json"))
        for vector in vectors.cases {
            let ranges = [VoiceLabLabelInterval(start: 0, end: min(3, vector.duration))] + vector.segments.map {
                VoiceLabLabelInterval(start: max(0, $0[0] - 0.5), end: min(vector.duration, $0[1] + 0.5))
            }
            #expect(VoiceLabRenderContract.mergeDisclosureIntervals(ranges) == vector.expected.map { VoiceLabLabelInterval(start: $0[0], end: $0[1]) }, Comment(rawValue: vector.id))
        }
    }
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
    @Test func disclosureLineLanguageUsesThePrimarySubtag() throws {
        struct Share: Decodable {
            struct Language: Decodable { let code: String?; let estonian: Bool }
            let lines: [String: [String: String]]
            let languages: [Language]
        }
        let share = try JSONDecoder().decode(Share.self, from: FixtureLoader.data("fixtures/share/cases.json"))
        #expect(share.languages.count == 10)
        for language in share.languages {
            for (name, kinds) in [("passage-render-v3", "tts"), ("voice-changer-half-render-v3", "voiceChangerStock")] {
                var project = try fixture(name)
                project.transcript?.language = language.code
                let line = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight).disclosure.postText
                let expected = share.lines[kinds]?[language.estonian ? "et" : "en"]
                #expect(line.map { Array($0.utf8) } == expected.map { Array($0.utf8) }, "\(name) \(language.code ?? "nil")")
            }
        }
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
    @Test func candidateDurationBaselines() throws {
        let cases = try JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/render-cases.json")) as! [String: [String: Any]]
        for name in ["unity-binary64-residual-eight", "unity-binary64-residual-nine", "unity-legacy-source-grid-only", "unity-inconsistent-alternate",
                     "nonunity-inconsistent-alternate", "nonunity-consistent-alternate"] {
            let vector = try #require(cases[name])
            let range = vector["replace"] as! [Double]
            let rate = (vector["sourceRate"] as! NSNumber).doubleValue
            let assetRate = (vector["assetRate"] as! NSNumber).intValue
            let frames = (vector["outputFrames"] as! NSNumber).int64Value
            let duration = vector["outDuration"] as! Double
            var project = try fixture()
            project.media.source.audio?.sampleRate = Int(rate)
            let minimumSourceDuration: Double = range[1] + 1.5
            project.media.source.durationSeconds = max(project.media.source.durationSeconds, minimumSourceDuration)
            project.transcript?.words = [TimedWord(id: "w4", text: "source", kind: .word, start: 2, end: 2.4)]
            project.edits.clips = []; project.edits.activeClipId = nil
            var segment = project.voiceLab.segments[0]
            segment.replace = VoiceLabReplacement(start: range[0], end: range[1], firstWordId: "w4", lastWordId: "w4")
            var recipe = try #require(segment.candidates[0].recipe)
            let halfAssetRate: Int = assetRate / 2
            let trimStartFrame: Int64 = Int64(halfAssetRate)
            let trimEndFrame = trimStartFrame + frames
            let trimEnd = Double(trimEndFrame) / Double(assetRate)
            recipe.audio = VoiceLabAudio(assetId: recipe.audio.assetId, trimStart: 0.5, trimEnd: trimEnd)
            recipe.outDuration = duration
            recipe.words = [VoiceLabWord(text: "Patch", start: 0.1, end: 0.7, synthetic: true)]
            recipe.qa.transcriptTokens = 1
            recipe.roomTone = VoiceLabRoomTone(sourceStartSample: 0, sourceEndSample: VoiceLabGeometry.samples(0.5, rate), gainDb: 0)
            let start = VoiceLabGeometry.samples(range[0], rate), end = VoiceLabGeometry.samples(range[1], rate)
            let windowSamples: Int64 = end - start
            let windowSampleCount: Double = Double(windowSamples)
            let assetFrameRate: Double = Double(assetRate)
            let windowFrameCount: Double = windowSampleCount * assetFrameRate / rate
            let windowFrames: Double = EditingPrimitives.jsRound(windowFrameCount)
            let baseline: Double = range[1] - range[0]
            let residualFrameCount: Double = (duration - baseline) * assetFrameRate
            let residual: Double = EditingPrimitives.jsRound(residualFrameCount)
            let binaryDuration: Double = baseline + residual / assetFrameRate
            let tolerance: Double = 4 * max(duration.ulp, baseline.ulp)
            let binaryFits = windowFrames + residual == Double(frames) && abs(duration - binaryDuration) <= tolerance
            #expect(binaryFits == ((vector["baseline"] as! String) == "binary64"), "\(name)")
            recipe.chunks = [VoiceLabChunk(sourceStartSample: start, sourceEndSample: end, requestId: "request-baseline", seed: recipe.seed,
                                           assetId: recipe.audio.assetId, assetSha256: project.voiceLab.assets![0].sha256,
                                           assembledStartFrame: trimStartFrame, assembledEndFrame: trimEndFrame)]
            let fade = VoiceLabGeometry.samples(VoiceLabPatchConstants.HARD_SEAM_FADE, rate)
            recipe.seams = VoiceLabSeams(
                in: try VoiceLabHandles.seam(kind: .hard, fadeSamples: fade, incoming: true, assetSampleRate: assetRate, sourceSampleRate: rate, stretch: 1),
                out: try VoiceLabHandles.seam(kind: .hard, fadeSamples: fade, incoming: false, assetSampleRate: assetRate, sourceSampleRate: rate, stretch: 1))
            recipe.video.sourceStartSample = start; recipe.video.sourceEndSample = end
            recipe.video.outputSamples = VoiceLabGeometry.samples(duration, rate)
            let defaultAssetDuration: Double = trimEnd + 0.5
            project.voiceLab.assets![0].sampleRate = assetRate
            project.voiceLab.assets![0].durationSeconds = vector["assetDuration"] as? Double ?? defaultAssetDuration
            segment.audio = recipe.audio; segment.outDuration = duration; segment.words = recipe.words
            segment.candidates = [VoiceLabCandidate(assetId: recipe.audio.assetId, score: 0.9)]
            segment.candidates[0].recipe = recipe
            project.voiceLab.segments = [segment]
            try VoiceLabProject.validate(project)
            try VoiceLabRenderValidation.validate(project)
            if let alternateFrames = vector["alternateOutputFrames"] as? NSNumber {
                let alternateEndFrame: Int64 = trimStartFrame + alternateFrames.int64Value
                let alternateEnd: Double = Double(alternateEndFrame) / Double(assetRate)
                var alternate = recipe
                alternate.audio.trimEnd = alternateEnd
                alternate.audio.stretch = vector["alternateStretch"] as? Double ?? 1
                alternate.chunks[0].assembledEndFrame = alternateEndFrame
                var candidate = segment.candidates[0]
                candidate.recipe = alternate
                project.voiceLab.segments[0].candidates.append(candidate)
                if vector["alternateStretch"] != nil {
                    let contentDuration: Double = alternateEnd - alternate.audio.trimStart
                    let expectedStretch: Double = duration / contentDuration
                    #expect(abs(alternate.audio.stretch - expectedStretch) <= 1e-6)
                    #expect((0.92...1.08).contains(contentDuration / duration))
                }
                if vector["validationError"] != nil {
                    #expect(vector["validationError"] as? String == "invalidSegment")
                    #expect(throws: VoiceLabProjectError.invalidSegment) { try VoiceLabProject.validate(project) }
                    #expect(throws: VoiceLabProjectError.invalidSegment) { try VoiceLabRenderValidation.validate(project) }
                    #expect(throws: VoiceLabProjectError.invalidSegment) {
                        try VoiceLabProject.selectCandidate(1, id: segment.id, in: project)
                    }
                } else {
                    try VoiceLabProject.validate(project)
                    try VoiceLabRenderValidation.validate(project)
                    let selected = try VoiceLabProject.selectCandidate(1, id: segment.id, in: project)
                    try VoiceLabProject.validate(selected)
                    try VoiceLabRenderValidation.validate(selected)
                    #expect(try VoiceLabRenderContract.prepare(selected, scope: .full, labelPosition: .topRight)
                        .selectedSegmentRecipes[0].recipe.audio.stretch == alternate.audio.stretch)
                    candidateSelectionParity(project, recipe: alternate)
                }
                project.voiceLab.segments[0].candidates[1].rejected = "fixture"
                try VoiceLabProject.validate(project)
                try VoiceLabRenderValidation.validate(project)
            }
            if name != "unity-binary64-residual-nine" {
                #expect(duration == Double(VoiceLabGeometry.samples(duration, rate)) / rate)
            }
        }
    }

    private func candidateSelectionParity(_ project: Project, recipe: VoiceLabRenderRecipe) {
        func accepts(_ operation: () throws -> Void) -> Bool {
            do { try operation(); return true }
            catch is VoiceLabProjectError { return false }
            catch { Issue.record(error); return false }
        }
        var accepted: Int = 0
        var refused: Int = 0
        func check(_ alternate: VoiceLabRenderRecipe) {
            var probe = project
            probe.voiceLab.segments[0].candidates[1].recipe = alternate
            let renderAccepts: Bool = accepts { try VoiceLabRenderValidation.validate(probe) }
            let projectAccepts: Bool = accepts { try VoiceLabProject.validate(probe) }
            let selectionAccepts: Bool = accepts {
                _ = try VoiceLabProject.selectCandidate(1, id: probe.voiceLab.segments[0].id, in: probe)
            }
            #expect(renderAccepts == projectAccepts)
            #expect(selectionAccepts == renderAccepts,
                    "trim=\(alternate.audio.trimEnd), duration=\(alternate.outDuration), stretch=\(alternate.audio.stretch)")
            if renderAccepts { accepted += 1 } else { refused += 1 }
        }
        let assetRate: Double = 96_000
        let sourceRate: Double = 8_000
        let stretches: [Double] = [0.9999991, 0.9999996, 1, 1.0000004, 1.0000009, 1.0000011, 1.05, 1 / 1.08, 1 / 0.92]
        for trimOffset: Int64 in -2...2 {
            for durationOffset: Int64 in -2...2 {
                for stretch: Double in stretches {
                    var alternate = recipe
                    let trimDelta: Double = Double(trimOffset) / assetRate
                    let durationDelta: Double = Double(durationOffset) / assetRate
                    alternate.audio.trimEnd += trimDelta
                    alternate.audio.stretch = stretch
                    alternate.outDuration += durationDelta
                    alternate.chunks[0].assembledEndFrame += trimOffset
                    alternate.video.outputSamples = VoiceLabGeometry.samples(alternate.outDuration, sourceRate)
                    check(alternate)
                }
            }
        }
        var alternate = recipe
        alternate.chunks = []; check(alternate)
        alternate = recipe; alternate.seams.in.assetHandleFrames = 0; check(alternate)
        alternate = recipe; alternate.qa.peakDbfs = 0; check(alternate)
        alternate = recipe; alternate.words![0].synthetic = false; check(alternate)
        alternate = recipe; alternate.provenance.endpoint = "https://example.invalid"; check(alternate)
        alternate = recipe; alternate.consentVerifiedAt = nil; check(alternate)
        alternate = recipe; alternate.video.outputSamples += 1; check(alternate)
        #expect(accepted > 0 && refused > 0 && accepted + refused == 232)
        print("Candidate selection parity: \(accepted) accepted, \(refused) refused; no reverse gap")
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
