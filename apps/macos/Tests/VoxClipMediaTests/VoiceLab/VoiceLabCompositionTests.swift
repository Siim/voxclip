import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

extension HeavyMediaTests {
@Suite("voice-lab-native-composition", .serialized)
struct VoiceLabCompositionTests {
    private func source(in root: URL) async throws -> URL {
        let original = try FixtureLoader.sharedRoot().appendingPathComponent("fixtures/media/joins-tone.mov")
        let asset = AVURLAsset(url: original)
        let session = try #require(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough))
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 7, preferredTimescale: 48_000))
        let output = root.appendingPathComponent("source.mov")
        try await session.export(to: output, as: .mov)
        return output
    }

    private func offsetSource(in root: URL) async throws -> URL {
        let original = try await source(in: root)
        let asset = AVURLAsset(url: original)
        let composition = AVMutableComposition()
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let videoTrack = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 7, preferredTimescale: 48_000)), of: video, at: .zero)
        try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 6.9, preferredTimescale: 48_000)),
                                       of: audio, at: CMTime(seconds: 0.1, preferredTimescale: 48_000))
        let output = root.appendingPathComponent("offset.mov")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: output, as: .mov)
        return output
    }

    private func shortAudioSource(in root: URL) async throws -> URL {
        let original = try await source(in: root)
        let asset = AVURLAsset(url: original)
        let composition = AVMutableComposition()
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let videoTrack = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 7, preferredTimescale: 48_000)), of: video, at: .zero)
        try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 6.9, preferredTimescale: 48_000)),
                                       of: audio, at: .zero)
        let output = root.appendingPathComponent("short-audio.mov")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: output, as: .mov)
        return output
    }

    private func wave(frames: Int, rate: Int, hz: Double, markerFrame: Int? = nil,
                      markerFrames: [Int] = [], rightOnly: Bool = false, amplitude: Double = 1) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        let channels = rightOnly ? 2 : 1
        text("RIFF"); u32(UInt32(36 + frames * 2 * channels)); text("WAVEfmt "); u32(16)
        u16(1); u16(UInt16(channels)); u32(UInt32(rate)); u32(UInt32(rate * 2 * channels)); u16(UInt16(2 * channels)); u16(16)
        text("data"); u32(UInt32(frames * 2 * channels))
        let marks = markerFrames + (markerFrame.map { [$0] } ?? [])
        for i in 0..<frames {
            let pulse = marks.contains(where: { i >= $0 && i < $0 + 240 }) ? 20_000.0 : 0
            let sample = UInt16(bitPattern: Int16(((sin(2 * .pi * hz * Double(i) / Double(rate)) * 9000 + pulse) * amplitude).rounded()))
            if rightOnly { u16(0) }
            u16(sample)
        }
        return data
    }

    private func fixture(source: URL, root: URL, fixtureName: String = "passage-render-v3",
                         nonunity: Bool = false, compressing: Bool = false,
                         minimalHandles: Bool = false, multipleMarkers: Bool = false,
                         rightOnly: Bool = false, amplitude: Double = 1,
                         customMarkers: [Int]? = nil,
                         scope: VoiceLabOutputScope = .full) throws -> (Project, VoiceLabRenderInput) {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/\(fixtureName).voxclip"))
        project.media.source.audio!.sampleRate = 48_000
        project.media.source.absolutePath = source.path
        project.media.source.relativePath = source.lastPathComponent
        project.media.source.sizeBytes = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as! NSNumber).int64Value
        project.media.source.contentKey = try JSONProjectStore.contentKey(for: source)
        project.media.source.video = MediaVideo(width: 640, height: 360, frameRate: 30, rotationDegrees: 0)
        let directory = root.appendingPathComponent(project.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = wave(frames: compressing ? 28_800 : Int(project.voiceLab.assets![0].durationSeconds * 24_000), rate: 24_000, hz: 880,
                         markerFrame: nonunity && !multipleMarkers ? 9_600 : nil,
                         markerFrames: customMarkers ?? (multipleMarkers ? [3_800, 9_600, compressing ? 19_000 : 16_600] : []),
                         rightOnly: rightOnly, amplitude: amplitude)
        let second = wave(frames: Int(project.voiceLab.assets![1].durationSeconds * 24_000), rate: 24_000, hz: 660)
        try first.write(to: directory.appendingPathComponent("asset-one.wav"))
        try second.write(to: directory.appendingPathComponent("asset-two.wav"))
        project.voiceLab.assets![0].sha256 = SpeechSHA256.hex(first)
        if compressing { project.voiceLab.assets![0].durationSeconds = 1.2 }
        project.voiceLab.assets![1].sha256 = SpeechSHA256.hex(second)
        for candidateIndex in project.voiceLab.segments[0].candidates.indices {
            var recipe = project.voiceLab.segments[0].candidates[candidateIndex].recipe!
            recipe.video.sourceStartSample *= 48
            recipe.video.sourceEndSample *= 48
            recipe.video.outputSamples *= 48
            if var room = recipe.roomTone {
                room.sourceStartSample *= 48
                room.sourceEndSample *= 48
                room.gainDb = -30
                recipe.roomTone = room
            }
            recipe.seams.in.fadeSamples *= 48
            recipe.seams.in.sourceHandleSamples *= 48
            recipe.seams.out.fadeSamples *= 48
            recipe.seams.out.sourceHandleSamples *= 48
            for index in recipe.chunks.indices {
                recipe.chunks[index].sourceStartSample *= 48
                recipe.chunks[index].sourceEndSample *= 48
                recipe.chunks[index].assetSha256 = project.voiceLab.assets![candidateIndex].sha256
            }
            project.voiceLab.segments[0].candidates[candidateIndex].recipe = recipe
        }
        if nonunity {
            var selected = project.voiceLab.segments[0].candidates[0].recipe!
            selected.audio.trimEnd = compressing ? 0.85 : 0.75
            selected.audio.stretch = compressing ? 0.7 / 0.75 : 0.7 / 0.65
            selected.chunks[selected.chunks.count - 1].assembledEndFrame = compressing ? 20_400 : 18_000
            let minimum = Int64(ceil(480 * 24_000 / (48_000 * selected.audio.stretch)))
            selected.seams.in.assetHandleFrames = minimalHandles ? minimum : 2_400
            selected.seams.out.assetHandleFrames = minimalHandles ? minimum : 2_400
            project.voiceLab.segments[0].candidates[0].recipe = selected
            project.voiceLab.segments[0].audio = selected.audio
        }
        let prepared = try VoiceLabRenderContract.prepare(project, scope: scope, labelPosition: .topRight)
        let input = try VoiceLabRenderInput(project: project, scope: scope, labelPosition: .topRight,
                                            paidRoot: root, prepared: prepared)
        return (project, input)
    }

    private func markerOnset(_ audio: [Float], center: Int, threshold: Double = 0.35) -> Int {
        let start = max(0, center - 1_000), end = min(audio.count - 96, center + 1_000)
        for index in start..<end {
            let average = (0..<96).reduce(0.0) { $0 + Double(audio[index + $1]) } / 96
            if average > threshold { return index }
        }
        return -1
    }

    private func samples(_ file: URL, at start: Int64, count: Int, channel: Int = 0) throws -> [Float] {
        let reader = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        reader.framePosition = start
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(count)))
        try reader.read(into: buffer, frameCount: AVAudioFrameCount(count))
        #expect(buffer.frameLength == count)
        return Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[channel]), count: count))
    }

    private func magnitude(_ audio: [Float], hz: Double, rate: Double) -> Double {
        let cosine = zip(audio.indices, audio).reduce(0.0) { $0 + Double($1.1) * cos(2 * .pi * hz * Double($1.0) / rate) }
        let sine = zip(audio.indices, audio).reduce(0.0) { $0 + Double($1.1) * sin(2 * .pi * hz * Double($1.0) / rate) }
        return hypot(cosine, sine) / Double(audio.count)
    }

    private func decodedMP4Mono(_ url: URL, frames: Int) async throws -> (pcm: [Float], count: Int64, firstPTS: Double?, end: Double) {
        let video = AVURLAsset(url: url)
        let track = try #require(try await MediaSupport.audioTrack(in: video))
        let reader = try AVAssetReader(asset: video)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: Int64(frames), timescale: 48_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: 48_000, channels: 2))
        let provider = reader.outputProvider(for: output)
        #expect(reader.startReading())
        var pcm = [Float](repeating: .nan, count: frames)
        var count: Int64 = 0
        var firstPTS: Double?
        var end = 0.0
        while let ready = try await MediaSupport.nextSample(provider) {
            let sampleCount = Int(ready.sampleCount)
            let pts = ready.presentationTimeStamp.seconds
            firstPTS = firstPTS ?? pts
            count += Int64(sampleCount)
            end = pts + Double(sampleCount) / 48_000
            let start = Int((pts * 48_000).rounded())
            try ready.withUnsafeSampleBuffer { sample in
                guard let block = CMSampleBufferGetDataBuffer(sample),
                      CMBlockBufferGetDataLength(block) == sampleCount * 8 else {
                    throw VoxClipError.decodeFailed("Unexpected decoded AAC layout")
                }
                var bytes = Data(count: sampleCount * 8)
                let status = bytes.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                guard status == noErr else { throw VoxClipError.decodeFailed("Cannot copy decoded AAC") }
                bytes.withUnsafeBytes { raw in
                    for frame in 0..<sampleCount where (0..<frames).contains(start + frame) {
                        pcm[start + frame] = raw.loadUnaligned(fromByteOffset: frame * 8, as: Float.self)
                    }
                }
            }
        }
        #expect(reader.status == .completed)
        return (pcm, count, firstPTS, end)
    }

    private func compareDecodedMP4(_ mp4: URL, wav: URL, windows: [(frame: Int, hz: Double)],
                                   markerCenters: [Int]) async throws -> (count: Int64, firstPTS: Double?, end: Double) {
        let frames = Int(try AVAudioFile(forReading: wav).length)
        let decoded = try await decodedMP4Mono(mp4, frames: frames)
        // PTS maps decoded AAC into the source grid; the ±1024 search allows one
        // priming packet without treating an unrelated source tone as a match.
        for window in windows {
            let reference = try samples(wav, at: Int64(window.frame), count: 4096)
            let candidate = Array(decoded.pcm[window.frame..<(window.frame + 4096)])
            #expect(candidate.allSatisfy { $0.isFinite })
            let wanted = magnitude(reference, hz: window.hz, rate: 48_000)
            let other = magnitude(candidate, hz: window.hz == 880 ? 440 : 880, rate: 48_000)
            let actual = magnitude(candidate, hz: window.hz, rate: 48_000)
            #expect(wanted > 0.02)
            #expect(actual > other * 3, "AAC must carry the selected source or synthetic route")
            #expect(actual > wanted * 0.6 && actual < wanted * 1.4)
            var best = 0.0
            for lag in -1024...1024 where window.frame + lag >= 0 && window.frame + lag + 4096 <= frames {
                var dot = 0.0, referencePower = 0.0, decodedPower = 0.0
                for index in stride(from: 0, to: 4096, by: 8) {
                    let left = Double(reference[index])
                    let right = Double(decoded.pcm[window.frame + lag + index])
                    dot += left * right
                    referencePower += left * left
                    decodedPower += right * right
                }
                if decodedPower > 0 { best = max(best, dot / sqrt(referencePower * decodedPower)) }
            }
            #expect(best > 0.65, "Decoded AAC waveform must track the production edited WAV")
        }
        let referenceAll = try samples(wav, at: 0, count: frames)
        for center in markerCenters {
            let referenceMarker = markerOnset(referenceAll, center: center)
            let decodedMarker = markerOnset(decoded.pcm, center: center, threshold: 0.2)
            #expect(referenceMarker >= 0)
            #expect(decodedMarker >= 0)
            #expect(abs(decodedMarker - referenceMarker) <= 1024, "AAC marker drift exceeds one priming packet")
        }
        return (decoded.count, decoded.firstPTS, decoded.end)
    }

    private func legacyPlan(_ project: Project, scope: VoiceLabOutputScope = .full) throws -> EditPlan {
        let transcript = try #require(project.transcript)
        let edits = project.edits
        let state = EditState(transcript: transcript,
                              pauses: try detectPauses(transcript.words, thresholdSeconds: edits.pauseThresholdSeconds),
                              pauseThresholdSeconds: edits.pauseThresholdSeconds, pauseKeepSeconds: edits.pauseKeepSeconds,
                              cutWordIds: Set(edits.cutWordIds), cutPauseIds: Set(edits.cutPauseIds),
                              corrections: edits.corrections, clips: edits.clips)
        let clip: ClipRange?
        switch scope {
        case .full: clip = nil
        case .clip(let id): clip = edits.clips.first(where: { $0.id == id })
        }
        return try EditPlan.build(transcript: transcript, editState: state, activeClip: clip,
                                  duration: project.media.source.durationSeconds,
                                  sampleRate: Double(project.media.source.audio!.sampleRate))
    }

    @Test(.timeLimit(.minutes(4))) func fittedAssetTest19UsesUnityRecipeInWAVAndDecodedMP4() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-fitted-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        var (project, _) = try fixture(source: media, root: root)
        let vector = try #require(FittedAssetVector.load().first { $0.name == "balanced-edits" })
        let fitted = try vector.prepare(root: root, projectId: project.id)
        let original = try #require(project.voiceLab.segments[0].candidates[0].recipe)
        let published = try fitted.publish(projectId: project.id, assetId: "fitted-test19", paidRoot: root,
            createdAt: Date(), requestId: try #require(original.provenance.requestId), seed: original.seed, gainDb: 0)
        let recipe = published.applying(to: original)
        project.voiceLab.assets!.append(contentsOf: published.assets)
        project.voiceLab.segments[0].candidates[0].assetId = published.audio.assetId
        project.voiceLab.segments[0].candidates[0].recipe = recipe
        project.voiceLab.segments[0].audio = published.audio
        project.voiceLab.segments[0].words = published.words
        project.voiceLab.segments[0].outDuration = published.outDuration
        try VoiceLabProject.validate(project)
        let prepared = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
        let input = try VoiceLabRenderInput(project: project, scope: .full, labelPosition: .topRight, paidRoot: root, prepared: prepared)
        let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
            output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30, videoBitrate: 2_000_000), voiceLab: input)
        let wav = root.appendingPathComponent("fitted.wav"), mp4 = root.appendingPathComponent("fitted.mp4")
        try await AVExporter().writeEditedAudio(request, to: wav)
        _ = try await AVExporter(appVersion: "0.1.0").export(ExportJob(render: request, outputURL: mp4)) { _ in }
        let piece = try #require(prepared.outputPlan.pieces.first { $0.kind == .synth })
        let markers = [Int(piece.outputStartSample), Int(piece.outputStartSample) + 4800,
                       Int(piece.outputStartSample) + 24_000, Int(piece.outputEndSample)]
        let all = try samples(wav, at: 0, count: Int(prepared.outputPlan.outputSamples))
        for center in markers { #expect(abs(markerOnset(all, center: center) - center) <= 500) }
        _ = try await compareDecodedMP4(mp4, wav: wav, windows: [(48_000, 440), (5 * 48_000, 440)], markerCenters: markers)
        #expect(recipe.audio.stretch == 1 && recipe.outDuration == vector.windowEnd - vector.windowStart)
        #expect(recipe.chunks[0].assetId == fitted.paidAsset.id && recipe.chunks[0].assetSha256 == fitted.paidAsset.sha256)
        let partialVector = try #require(FittedAssetVector.load().first { $0.name == "partial-insertion" })
        let partialFit = try partialVector.prepare(root: root, projectId: project.id)
        let partial = try partialFit.publish(projectId: project.id, assetId: "partial-test19", paidRoot: root,
            createdAt: Date(), requestId: try #require(original.provenance.requestId), seed: original.seed, gainDb: 0)
        var partialRecipe = partial.applying(to: original)
        partialRecipe.video.mode = .retimed
        partialRecipe.video.outputSamples = Int64(EditingPrimitives.jsRound(partial.outDuration * 48_000))
        partialRecipe.video.retimeFactor = Double(partialRecipe.video.sourceEndSample - partialRecipe.video.sourceStartSample) / Double(partialRecipe.video.outputSamples)
        project.voiceLab.assets!.append(contentsOf: partial.assets)
        project.voiceLab.segments[0].candidates[0].assetId = partial.audio.assetId
        project.voiceLab.segments[0].candidates[0].recipe = partialRecipe
        project.voiceLab.segments[0].audio = partial.audio
        project.voiceLab.segments[0].words = partial.words
        project.voiceLab.segments[0].outDuration = partial.outDuration
        try VoiceLabProject.validate(project)
        #expect(partial.outDuration == (partialVector.windowEnd - partialVector.windowStart) + partialVector.residualSeconds)
    }

    @Test(.timeLimit(.minutes(3))) func builderAndEditedWaveUseMixedSourceGrid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-composition-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        let (project, input) = try fixture(source: media, root: root)
        let legacy = try legacyPlan(project)
        let request = RenderRequest(sourceURL: media, plan: legacy, output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                    videoBitrate: 2_000_000), voiceLab: input)
        let graph = try await CompositionBuilder().build(request)
        let mixed = try #require(graph.voiceLabLease?.mixedAudioURL)
        let file = try AVAudioFile(forReading: mixed)
        #expect(file.length == input.prepared.outputPlan.outputSamples)
        let before = try samples(mixed, at: 48_000, count: 4096)
        let inside = try samples(mixed, at: 2 * 48_000 + 29_000, count: 4096)
        #expect(magnitude(before, hz: 440, rate: 48_000) > magnitude(before, hz: 880, rate: 48_000) * 4)
        #expect(magnitude(inside, hz: 880, rate: 48_000) > magnitude(inside, hz: 440, rate: 48_000) * 4)
        let piece = try #require(input.prepared.outputPlan.pieces.first(where: { $0.kind == .synth }))
        let recipe = try #require(input.prepared.selectedSegmentRecipes.first?.recipe)
        let incoming = recipe.seams.in.fadeSamples
        let after = incoming - incoming / 2
        let fit = mixed.deletingLastPathComponent().appendingPathComponent("fit-\(piece.segmentId!).caf")
        let stagedSource = mixed.deletingLastPathComponent().appendingPathComponent("source.caf")
        let seamEnd = try samples(mixed, at: piece.outputStartSample + after - 1, count: 1)[0]
        let fitEnd = try samples(fit, at: incoming - 1, count: 1)[0]
        let room = try #require(recipe.roomTone)
        let toneEnd = try samples(stagedSource, at: room.sourceStartSample + after - 1, count: 1)[0]
        let toneGain = Float(pow(10, room.gainDb / 20))
        #expect(abs(toneEnd * toneGain) > 0.0001)
        #expect(abs(seamEnd - (fitEnd + toneEnd * toneGain)) < 0.002,
                "The synth-weight-one endpoint must retain room tone")
        let following = try samples(mixed, at: piece.outputStartSample + after, count: 1)[0]
        let fittedFollowing = try samples(fit, at: incoming, count: 1)[0]
        let toneFollowing = try samples(stagedSource, at: room.sourceStartSample + after, count: 1)[0]
        #expect(abs(following - (fittedFollowing + toneFollowing * toneGain)) < 0.002)
        let output = root.appendingPathComponent("edited.wav")
        try await AVExporter().writeEditedAudio(request, to: output)
        let wave = try AVAudioFile(forReading: output)
        #expect(wave.length == input.prepared.outputPlan.outputSamples)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(input.project.id).appendingPathComponent("asset-one.wav").path))
    }

    @Test func ordinarySourceFadeMatchesLegacyAtScopeEdgesAndShortRuns() {
        let rate = 48_000.0
        for length: Int64 in [1, 3, 21, 240, 1_000] {
            let legacy = EditPlan(sampleRate: rate, totalSamples: 2_000,
                                  kept: [MediaInterval(startSample: 100, endSample: 100 + length)])
            for local in 0..<length {
                let expected = Float(legacy.joinGain(at: local))
                let actual = VoiceLabAudioRenderer.ordinarySourceGain(local: local, length: length, rate: rate,
                                                                      fadeIn: true, fadeOut: true)
                #expect(abs(actual - expected) < 0.0000002)
            }
        }
        #expect(VoiceLabAudioRenderer.ordinarySourceGain(local: 0, length: 21, rate: rate,
                                                          fadeIn: false, fadeOut: true) == 1)
        #expect(VoiceLabAudioRenderer.ordinarySourceGain(local: 20, length: 21, rate: rate,
                                                          fadeIn: true, fadeOut: false) == 1)
    }

    @Test func requestPreflightRejectsStaleSourcePlanAndCaptionsButAllowsRelink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-preflight-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        let (project, input) = try fixture(source: media, root: root)
        var request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                       videoBitrate: 2_000_000), voiceLab: input)
        try VoiceLabRenderPreflight.validate(request)
        let moved = root.appendingPathComponent("relinked.mov")
        try FileManager.default.copyItem(at: media, to: moved)
        request.sourceURL = moved
        try VoiceLabRenderPreflight.validate(request)
        request.plan = EditPlan(sampleRate: 48_000, totalSamples: 336_000,
                                kept: [MediaInterval(startSample: 0, endSample: 335_999)])
        #expect(throws: VoiceLabAssetError.invalidSelection("legacy source plan")) {
            try VoiceLabRenderPreflight.validate(request)
        }
        request.plan = try legacyPlan(project)
        request.captions = CaptionTrack(words: [CaptionWord(id: "stale", text: "stale", start: 0, end: 1)])
        #expect(throws: VoiceLabAssetError.invalidSelection("caption layout")) {
            try VoiceLabRenderPreflight.validate(request)
        }
        request.captions = CaptionTrack()
        try Data("wrong source".utf8).write(to: moved)
        #expect(throws: VoiceLabAssetError.invalidSelection("source identity")) {
            try VoiceLabRenderPreflight.validate(request)
        }
    }

    @Test(.timeLimit(.minutes(3))) func sourcePresentationOffsetIsPreservedOrTypedRefused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-offset-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await offsetSource(in: root)
        let (project, input) = try fixture(source: media, root: root)
        let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                       videoBitrate: 2_000_000), voiceLab: input)
        do {
            let graph = try await CompositionBuilder().build(request)
            let mixed = try #require(graph.voiceLabLease?.mixedAudioURL)
            let leading = try samples(mixed, at: 0, count: 4_000)
            #expect(leading.allSatisfy { abs($0) < 0.00001 }, "A supported offset must retain the silent source lead")
        } catch VoxClipError.decodeFailed(let detail) {
            #expect(detail.contains("unsupported presentation offset"))
        }
    }

    @Test(.timeLimit(.minutes(3))) func nonunityFitRefusesBeforeSnapshotAndPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-fit-gate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for compressing in [false, true] {
            let caseRoot = root.appendingPathComponent(compressing ? "short" : "long")
            try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: false)
            let media = try await source(in: caseRoot)
            let (project, input) = try fixture(source: media, root: caseRoot, nonunity: true, compressing: compressing)
            let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                   videoBitrate: 2_000_000), voiceLab: input)
            let paid = caseRoot.appendingPathComponent(project.id).appendingPathComponent("asset-one.wav")
            let paidBytes = try Data(contentsOf: paid)
            // The case's own scratch folder: no other test's render can land in it.
            let scratch = caseRoot.appendingPathComponent("scratch")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            await #expect(throws: VoiceLabRenderCapabilityError.nonunityFitUnsupported) {
                _ = try await CompositionBuilder(scratchRoot: scratch).build(request)
            }
            let wav = caseRoot.appendingPathComponent("edited.wav")
            await #expect(throws: VoiceLabRenderCapabilityError.nonunityFitUnsupported) {
                _ = try await AVExporter(capacityProvider: DiskCapacity.systemVolume, scratchRoot: scratch).stageEditedAudio(request, to: wav)
            }
            let video = caseRoot.appendingPathComponent("marked.mp4")
            let sidecar = caseRoot.appendingPathComponent("marked.mp4.provenance.json")
            let oldVideo = Data("old video".utf8), oldSidecar = Data("old sidecar".utf8)
            try oldVideo.write(to: video); try oldSidecar.write(to: sidecar)
            await #expect(throws: VoiceLabRenderCapabilityError.nonunityFitUnsupported) {
                _ = try await AVExporter(capacityProvider: DiskCapacity.systemVolume, scratchRoot: scratch, appVersion: "0.1.0")
                    .export(ExportJob(render: request, outputURL: video)) { _ in }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
            #expect(try Data(contentsOf: paid) == paidBytes)
            #expect(try Data(contentsOf: video) == oldVideo)
            #expect(try Data(contentsOf: sidecar) == oldSidecar)
            #expect(!FileManager.default.fileExists(atPath: wav.path))
            #expect(!FileManager.default.fileExists(atPath: wav.path + ".partial"))
            #expect(!FileManager.default.fileExists(atPath: video.path + ".partial"))
        }
    }

    /// Exercises the native unit directly. These measurements do not authorize a render.
    @Test(.timeLimit(.minutes(4))) func timePitchAmplitudeAndChannelDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-fit-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var results: [[String: Any]] = []
        for vector in ["full-long", "full-short", "extra-short"] {
            for variant in ["normal", "right-only", "quiet"] {
                let caseRoot = root.appendingPathComponent("\(vector)-\(variant)")
                try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: false)
                let media = try await source(in: caseRoot)
                let rightOnly = variant == "right-only"
                let amplitude = variant == "quiet" ? 0.02 : 1.0
                let project: Project
                let input: VoiceLabRenderInput
                let markers: [Int]
                if vector == "extra-short" {
                    (project, input) = try fixture(source: media, root: caseRoot, nonunity: true,
                        compressing: true, multipleMarkers: true, rightOnly: rightOnly, amplitude: amplitude)
                    markers = [3_800, 9_600, 19_000]
                } else {
                    var (take, _) = try fixture(source: media, root: caseRoot, fixtureName: "full-take-render-v3")
                    let compressing = vector == "full-short"
                    let middle: Int64 = compressing ? 92_400 : 81_600
                    let last: Int64 = compressing ? 182_400 : 160_800
                    markers = [3_400, Int(middle), Int(last) - 1_000]
                    let payload = wave(frames: compressing ? 192_000 : 172_800, rate: 24_000, hz: 880,
                                       markerFrames: markers, rightOnly: rightOnly, amplitude: amplitude)
                    try payload.write(to: caseRoot.appendingPathComponent(take.id).appendingPathComponent("asset-one.wav"))
                    take.voiceLab.assets![0].sha256 = SpeechSHA256.hex(payload)
                    take.voiceLab.assets![0].durationSeconds = compressing ? 8.0 : 7.2
                    var recipe = take.voiceLab.segments[0].candidates[0].recipe!
                    recipe.audio.trimEnd = compressing ? 7.6 : 6.7
                    recipe.audio.stretch = 7 / (recipe.audio.trimEnd - 0.1)
                    recipe.chunks[0].assembledEndFrame = middle
                    recipe.chunks[1].assembledStartFrame = middle
                    recipe.chunks[1].assembledEndFrame = last
                    for index in recipe.chunks.indices { recipe.chunks[index].assetSha256 = take.voiceLab.assets![0].sha256 }
                    take.voiceLab.segments[0].candidates[0].recipe = recipe
                    take.voiceLab.segments[0].audio = recipe.audio
                    let prepared = try VoiceLabRenderContract.prepare(take, scope: .full, labelPosition: .topRight)
                    project = take
                    input = try VoiceLabRenderInput(project: take, scope: .full, labelPosition: .topRight,
                                                    paidRoot: caseRoot, prepared: prepared)
                }
                let item = try #require(input.prepared.selectedSegmentRecipes.first)
                let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                       videoBitrate: 2_000_000), voiceLab: input)
                #expect(throws: VoiceLabRenderCapabilityError.nonunityFitUnsupported) {
                    try VoiceLabRenderPreflight.validate(request)
                }
                let asset = try #require(VoiceLabAssets.prepare(project: project, plan: input.prepared.outputPlan,
                                                                 paidRoot: caseRoot)[item.segmentId])
                let output = caseRoot.appendingPathComponent("diagnostic-fit.caf")
                let length = item.piece.outputEndSample - item.piece.outputStartSample
                var result: [String: Any] = ["vector": vector, "variant": variant,
                    "inputChannels": rightOnly ? 2 : 1, "amplitudeScale": amplitude,
                    "plannedFrames": length + item.recipe.seams.in.fadeSamples / 2 +
                        item.recipe.seams.out.fadeSamples - item.recipe.seams.out.fadeSamples / 2]
                do {
                    try VoiceLabAudioRenderer.stageFit(asset, recipe: item.recipe, outputFrames: length,
                                                        rate: input.prepared.outputPlan.sampleRate, to: output, scratch: caseRoot)
                    result["nativeRender"] = "returned planned frames"
                } catch {
                    result["nativeRender"] = "failed: \(error)"
                }
                if FileManager.default.fileExists(atPath: output.path) {
                    let count = Int(try AVAudioFile(forReading: output).length)
                    result["renderedFrames"] = count
                    let channel = rightOnly ? 1 : 0
                    let fitted = try samples(output, at: 0, count: count, channel: channel)
                    let expected = markers.map { marker in
                        let trimStart = Int((item.recipe.audio.trimStart * 24_000).rounded())
                        return Int((Double(marker - trimStart) * 2 * item.recipe.audio.stretch).rounded()) +
                            Int(item.recipe.seams.in.fadeSamples / 2)
                    }
                    result["markers"] = expected.map { marker in
                        ["expected": marker, "observed": markerOnset(fitted, center: marker,
                            threshold: 0.35 * amplitude)]
                    }
                    let tail = fitted.suffix(256)
                    result["tailRMS"] = sqrt(tail.reduce(0.0) { $0 + Double($1 * $1) } / Double(tail.count))
                }
                results.append(result)
                print("Voice Lab TimePitch diagnostic: \(result)")
            }
        }
        #expect(results.count == 9)
        if let folder = ProcessInfo.processInfo.environment["VOXCLIP_FIT_EVIDENCE"] {
            let destination = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent("mac-timepitch-channel-amplitude.json"))
        }
    }

    @Test(.timeLimit(.minutes(3))) func fullTakeTwoChunksAndVoiceConversionUseNativeMix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-native-modes-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        for name in ["full-take-render-v3", "voice-changer-half-render-v3"] {
            let (project, input) = try fixture(source: media, root: root, fixtureName: name, multipleMarkers: true,
                customMarkers: name == "full-take-render-v3" ? [3_800, 86_300] : nil)
            let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                                        output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                           videoBitrate: 2_000_000), voiceLab: input)
            let graph = try await CompositionBuilder().build(request)
            let mixed = try #require(graph.voiceLabLease?.mixedAudioURL)
            #expect(try AVAudioFile(forReading: mixed).length == 336_000)
            let generated = try samples(mixed, at: 48_000, count: 4096)
            #expect(magnitude(generated, hz: 880, rate: 48_000) > magnitude(generated, hz: 440, rate: 48_000) * 4)
            if name == "full-take-render-v3" {
                #expect(input.prepared.selectedSegmentRecipes[0].recipe.chunks.count == 2)
                let secondChunk = try samples(mixed, at: 4 * 48_000, count: 4096)
                #expect(magnitude(secondChunk, hz: 880, rate: 48_000) > 0.05)
            } else {
                let sourcePart = try samples(mixed, at: 5 * 48_000, count: 4096)
                #expect(magnitude(sourcePart, hz: 440, rate: 48_000) > magnitude(sourcePart, hz: 880, rate: 48_000) * 4)
            }
            let wav = root.appendingPathComponent("\(name).wav")
            let mp4 = root.appendingPathComponent("\(name).mp4")
            try await AVExporter().writeEditedAudio(request, to: wav)
            _ = try await AVExporter(appVersion: "0.1.0").export(ExportJob(render: request, outputURL: mp4)) { _ in }
            let piece = try #require(input.prepared.outputPlan.pieces.first(where: { $0.kind == .synth }))
            let windows: [(frame: Int, hz: Double)] = name == "full-take-render-v3"
                ? [(48_000, 880), (4 * 48_000, 880), (6 * 48_000, 880)]
                : [(48_000, 880), (5 * 48_000, 440)]
            let trimStart = try #require(input.prepared.selectedSegmentRecipes.first?.recipe.audio.trimStart)
            _ = try await compareDecodedMP4(mp4, wav: wav, windows: windows,
                                             markerCenters: name == "full-take-render-v3"
                                                ? [Int(piece.outputStartSample) + Int((3_800 - trimStart * 24_000) * 2), 168_000]
                                                : [Int(piece.outputStartSample) + Int((3_800 - trimStart * 24_000) * 2)])
        }
    }

    @Test(.timeLimit(.minutes(3))) func touchingSyntheticPiecesShareOneSeam() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-touching-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        var (project, _) = try fixture(source: media, root: root, fixtureName: "full-take-render-v3",
                                        customMarkers: [3_800, 86_300])
        let original = project.voiceLab.segments[0]
        let combined = try #require(original.candidates[original.selectedCandidateIndex].recipe)
        var first = original, second = original
        first.id = "vl-first"; second.id = "vl-second"
        first.replace.end = 3.5; first.replace.lastWordId = "w6"
        second.replace.start = 3.5; second.replace.firstWordId = "w7"
        first.outDuration = 3.5; second.outDuration = 3.5
        first.words = [VoiceLabWord(text: "whole", start: 0, end: 3.4, synthetic: true)]
        second.words = [VoiceLabWord(text: "take", start: 0, end: 3.5, synthetic: true)]
        var firstRecipe = combined, secondRecipe = combined
        firstRecipe.outDuration = 3.5; secondRecipe.outDuration = 3.5
        firstRecipe.audio.trimEnd = 3.6
        secondRecipe.audio.trimStart = 3.6
        firstRecipe.words = first.words; secondRecipe.words = second.words
        firstRecipe.chunks = [combined.chunks[0]]
        secondRecipe.chunks = [combined.chunks[1]]
        firstRecipe.video.sourceEndSample = 3 * 48_000 + 24_000
        secondRecipe.video.sourceStartSample = 3 * 48_000 + 24_000
        firstRecipe.video.outputSamples = 3 * 48_000 + 24_000
        secondRecipe.video.outputSamples = 3 * 48_000 + 24_000
        firstRecipe.seams.out = VoiceLabSeam(kind: .synthToSynth, fadeSamples: 960,
                                            sourceHandleSamples: 0, assetHandleFrames: 240)
        secondRecipe.seams.in = VoiceLabSeam(kind: .synthToSynth, fadeSamples: 960,
                                            sourceHandleSamples: 0, assetHandleFrames: 240)
        first.audio = firstRecipe.audio; second.audio = secondRecipe.audio
        first.candidates = [original.candidates[original.selectedCandidateIndex]]
        second.candidates = first.candidates
        first.selectedCandidateIndex = 0; second.selectedCandidateIndex = 0
        first.candidates[0].recipe = firstRecipe; second.candidates[0].recipe = secondRecipe
        project.voiceLab.segments = [first, second]
        let prepared = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
        let input = try VoiceLabRenderInput(project: project, scope: .full, labelPosition: .topRight,
                                            paidRoot: root, prepared: prepared)
        let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                       videoBitrate: 2_000_000), voiceLab: input)
        let graph = try await CompositionBuilder().build(request)
        let mixed = try #require(graph.voiceLabLease?.mixedAudioURL)
        #expect(try AVAudioFile(forReading: mixed).length == 336_000)
        let seam = try samples(mixed, at: 168_000 - 480, count: 960)
        let firstFit = mixed.deletingLastPathComponent().appendingPathComponent("fit-vl-first.caf")
        let secondFit = mixed.deletingLastPathComponent().appendingPathComponent("fit-vl-second.caf")
        let leftStart = try samples(firstFit, at: 167_520, count: 1)[0]
        let rightStart = try samples(secondFit, at: 0, count: 1)[0]
        let rightEnd = try samples(secondFit, at: 959, count: 1)[0]
        let leftMiddle = try samples(firstFit, at: 168_000, count: 1)[0]
        let rightMiddle = try samples(secondFit, at: 480, count: 1)[0]
        let u = Double(480) / 959
        let equalPower = leftMiddle * Float(cos(.pi * u / 2)) + rightMiddle * Float(sin(.pi * u / 2))
        #expect(abs(seam[0] - leftStart) < 0.002)
        #expect(abs(seam[959] - rightEnd) < 0.002)
        #expect(abs(seam[480] - equalPower) < 0.002)
        #expect(abs(rightStart) <= 1)
        let wav = root.appendingPathComponent("touching.wav")
        let mp4 = root.appendingPathComponent("touching.mp4")
        try await AVExporter().writeEditedAudio(request, to: wav)
        _ = try await AVExporter(appVersion: "0.1.0").export(ExportJob(render: request, outputURL: mp4)) { _ in }
        _ = try await compareDecodedMP4(mp4, wav: wav,
            windows: [(48_000, 880), (168_000 - 2_048, 880), (168_000 + 1_024, 880), (6 * 48_000, 880)],
            markerCenters: [2_800, 168_000])
    }

    @Test(.timeLimit(.minutes(4))) func nativeMP4CarriesActualCompositionLabelXMPAndSidecar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-marked-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        let (project, input) = try fixture(source: media, root: root, multipleMarkers: true)
        let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                       videoBitrate: 2_000_000), voiceLab: input)
        let destination = root.appendingPathComponent("marked.mp4")
        let prior = Data("previous video".utf8)
        try prior.write(to: destination)
        let result = try await AVExporter(appVersion: "0.1.0").export(ExportJob(render: request, outputURL: destination)) { _ in }
        #expect(result.frames == 210)
        #expect(result.audioSamples == 336_000)
        let sidecarURL = root.appendingPathComponent("marked.mp4.provenance.json")
        let sidecar = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any])
        let app = try #require(sidecar["app"] as? [String: Any])
        #expect(app["version"] as? String == "0.1.0")
        let export = try #require(sidecar["export"] as? [String: Any])
        let digest = SHA256.hash(data: try Data(contentsOf: destination)).map { String(format: "%02x", $0) }.joined()
        #expect(export["sha256"] as? String == digest)
        #expect(export["file"] as? String == "marked.mp4")
        let video = AVURLAsset(url: destination)
        #expect(abs((try await video.load(.duration)).seconds - 7) < 1.0 / 30)
        let wav = root.appendingPathComponent("marked.wav")
        try await AVExporter().writeEditedAudio(request, to: wav)
        let piece = try #require(input.prepared.outputPlan.pieces.first(where: { $0.kind == .synth }))
        let decoded = try await compareDecodedMP4(destination, wav: wav,
            windows: [(48_000, 440), (2 * 48_000 + 29_000, 880), (5 * 48_000, 440)],
            markerCenters: [Int(piece.outputStartSample) + 2_800])
        // AAC priming/padding may move a decoder boundary by one 1024-frame packet.
        #expect(abs(decoded.count - 336_000) <= 1024)
        #expect(abs((decoded.firstPTS ?? -1)) <= 1024.0 / 48_000)
        #expect(abs(decoded.end - 7) <= 1024.0 / 48_000)
        let generator = AVAssetImageGenerator(asset: video)
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 48_000)).image
        let image = CIImage(cgImage: frame)
        let bounds = image.extent
        #expect(bounds.width == 640 && bounds.height == 360)
        if let evidence = ProcessInfo.processInfo.environment["VOXCLIP_DISCLOSURE_EVIDENCE"] {
            let folder = URL(fileURLWithPath: evidence, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let mp4 = folder.appendingPathComponent("mac-actual-synthetic-marked.mp4")
            try? FileManager.default.removeItem(at: mp4)
            try FileManager.default.copyItem(at: destination, to: mp4)
            let provenance = folder.appendingPathComponent("mac-actual-synthetic-marked.mp4.provenance.json")
            try? FileManager.default.removeItem(at: provenance)
            try FileManager.default.copyItem(at: sidecarURL, to: provenance)
            try CIContext().writePNGRepresentation(of: image,
                to: folder.appendingPathComponent("mac-actual-synthetic-frame.png"), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
    }

    @MainActor @Test(.timeLimit(.minutes(3))) func playerItemRetainsAndReleasesScratchAfterReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-player-lease-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        let (project, input) = try fixture(source: media, root: root)
        let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                       videoBitrate: 2_000_000), forPreview: true, voiceLab: input)
        let controller = PreviewPlayerController()
        try await controller.load(request)
        var held: LeasedPlayerItem? = try #require(controller.player.currentItem as? LeasedPlayerItem)
        let scratch = try #require(held?.renderGraph.voiceLabLease?.mixedAudioURL.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: scratch.path))
        controller.close()
        #expect(FileManager.default.fileExists(atPath: scratch.path), "Outstanding item readers retain their lease")
        held = nil
        for _ in 0..<30 where FileManager.default.fileExists(atPath: scratch.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(project.id).appendingPathComponent("asset-one.wav").path))
    }

    @Test(.timeLimit(.minutes(4))) func markedPublicationRollbackKeepsPreviousDestinationSet() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-marked-rollback-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        let (project, input) = try fixture(source: media, root: root)
        let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                       videoBitrate: 2_000_000), voiceLab: input)
        let video = root.appendingPathComponent("marked.mp4")
        let sidecar = root.appendingPathComponent("marked.mp4.provenance.json")
        let priorVideo = Data("prior video".utf8), priorSidecar = Data("prior sidecar".utf8)
        try priorVideo.write(to: video)
        try priorSidecar.write(to: sidecar)
        let missing = root.appendingPathComponent("missing-extra.partial")
        let extra = root.appendingPathComponent("extra.wav")
        await #expect(throws: (any Error).self) {
            _ = try await AVExporter(appVersion: "0.1.0").export(ExportJob(render: request, outputURL: video),
                additionalOutputs: [(partial: missing, destination: extra)]) { _ in }
        }
        #expect(try Data(contentsOf: video) == priorVideo)
        #expect(try Data(contentsOf: sidecar) == priorSidecar)
        #expect(!FileManager.default.fileExists(atPath: extra.path))
        #expect(!FileManager.default.fileExists(atPath: video.path + ".partial"))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path + ".partial"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(project.id).appendingPathComponent("asset-one.wav").path))
    }

    @Test(.timeLimit(.minutes(3))) func cancelledMarkedExportKeepsPriorVideoAndSidecar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-marked-cancel-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        let (project, input) = try fixture(source: media, root: root)
        let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                       videoBitrate: 2_000_000), voiceLab: input)
        let video = root.appendingPathComponent("marked.mp4")
        let sidecar = root.appendingPathComponent("marked.mp4.provenance.json")
        let priorVideo = Data("prior video".utf8), priorSidecar = Data("prior sidecar".utf8)
        try priorVideo.write(to: video)
        try priorSidecar.write(to: sidecar)
        let unownedPartial = URL(fileURLWithPath: sidecar.path + ".partial")
        let priorPartial = Data("another run owns this partial".utf8)
        try priorPartial.write(to: unownedPartial)
        let exporter = AVExporter(appendCheck: { pump, frame in
            if pump == 0 && frame == 5 { throw CancellationError() }
        }, appVersion: "0.1.0")
        await #expect(throws: CancellationError.self) {
            _ = try await exporter.export(ExportJob(render: request, outputURL: video)) { _ in }
        }
        #expect(try Data(contentsOf: video) == priorVideo)
        #expect(try Data(contentsOf: sidecar) == priorSidecar)
        #expect(!FileManager.default.fileExists(atPath: video.path + ".partial"))
        #expect(try Data(contentsOf: unownedPartial) == priorPartial)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(project.id).appendingPathComponent("asset-one.wav").path))
    }

    @Test(.timeLimit(.minutes(4))) func existingProvenancePartialSurvivesExclusiveCreateFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-provenance-owner-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        let (project, input) = try fixture(source: media, root: root)
        let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                       videoBitrate: 2_000_000), voiceLab: input)
        let video = root.appendingPathComponent("marked.mp4")
        let sidecar = root.appendingPathComponent("marked.mp4.provenance.json")
        let partial = URL(fileURLWithPath: sidecar.path + ".partial")
        let originalVideo = Data("old video".utf8), originalSidecar = Data("old sidecar".utf8)
        let unowned = Data("unowned partial".utf8)
        try originalVideo.write(to: video)
        try originalSidecar.write(to: sidecar)
        try unowned.write(to: partial)
        await #expect(throws: (any Error).self) {
            _ = try await AVExporter(appVersion: "0.1.0").export(ExportJob(render: request, outputURL: video)) { _ in }
        }
        #expect(try Data(contentsOf: video) == originalVideo)
        #expect(try Data(contentsOf: sidecar) == originalSidecar)
        #expect(try Data(contentsOf: partial) == unowned)
    }

    @Test func provenancePathsRejectAdditionalOutputCollisionBeforeBuild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-provenance-path-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        let (project, input) = try fixture(source: media, root: root)
        let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                       videoBitrate: 2_000_000), voiceLab: input)
        let video = root.appendingPathComponent("marked.mp4")
        let provenance = URL(fileURLWithPath: video.path + ".provenance.json")
        let original = Data("preserve".utf8)
        try original.write(to: provenance)
        await #expect(throws: (any Error).self) {
            _ = try await AVExporter(appVersion: "0.1.0").export(ExportJob(render: request, outputURL: video),
                additionalOutputs: [(partial: root.appendingPathComponent("extra.partial"), destination: provenance)]) { _ in }
        }
        #expect(try Data(contentsOf: provenance) == original)
        #expect(!FileManager.default.fileExists(atPath: video.path))
    }

    @Test func exportCannotOverwritePaidAssetBeforeSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-paid-output-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        let (project, input) = try fixture(source: media, root: root)
        let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                       videoBitrate: 2_000_000), voiceLab: input)
        let paid = root.appendingPathComponent(project.id).appendingPathComponent("asset-one.wav")
        let original = try Data(contentsOf: paid)
        await #expect(throws: (any Error).self) {
            _ = try await AVExporter(appVersion: "0.1.0").export(ExportJob(render: request, outputURL: paid)) { _ in }
        }
        #expect(try Data(contentsOf: paid) == original)
        #expect(!FileManager.default.fileExists(atPath: paid.path + ".partial"))
    }

    @Test(.timeLimit(.minutes(4))) func productionCapacityPreflightRejectsEarlyAndAcceptsBelowFifteenGiB() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-capacity-boundary-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        let (project, input) = try fixture(source: media, root: root)
        let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                       videoBitrate: 2_000_000), voiceLab: input)
        let paid = root.appendingPathComponent(project.id).appendingPathComponent("asset-one.wav")
        let original = try Data(contentsOf: paid)
        let output = root.appendingPathComponent("capacity.mp4")
        await #expect(throws: VoxClipError.self) {
            _ = try await AVExporter(capacityProvider: { _ in .init(id: 1, freeBytes: 0) },
                                     appVersion: "0.1.0").export(ExportJob(render: request, outputURL: output)) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: output.path + ".partial"))
        #expect(try Data(contentsOf: paid) == original)
        _ = try await AVExporter(capacityProvider: { _ in .init(id: 1, freeBytes: 2_000_000_000) },
                                 appVersion: "0.1.0").export(ExportJob(render: request, outputURL: output)) { _ in }
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: paid) == original)
    }

    @Test(.timeLimit(.minutes(4))) func combinedOutputPreflightCountsWAVBeforeAnyStageAndSeparatesVolumes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-combined-capacity-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        let (project, input) = try fixture(source: media, root: root)
        let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
            output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                               videoBitrate: 2_000_000), voiceLab: input)
        let video = root.appendingPathComponent("combined.mp4")
        let wav = root.appendingPathComponent("combined.wav")
        let srt = root.appendingPathComponent("combined.srt")
        let sidecar = root.appendingPathComponent("combined.mp4.provenance.json")
        let oldVideo = Data("old video".utf8), oldWAV = Data("old wav".utf8)
        try oldVideo.write(to: video); try oldWAV.write(to: wav)
        let job = ExportJob(render: request, outputURL: video, writeSRT: true, srtURL: srt)
        let wavBytes = try PCMFile.plannedBytes(frames: request.timeline.outputSamples, channels: 2, bits: 32)
        let scratch = try VoiceLabAudioRenderer.scratchBytes(input: input)
        let stageOnlyFree = scratch + wavBytes + Int64(oldWAV.count) + 1_000_000
        // The test's own scratch folder: no other test's render can land in it.
        let scratchRoot = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: false)
        do {
            try await AVExporter(capacityProvider: { _ in .init(id: 1, freeBytes: stageOnlyFree) }, scratchRoot: scratchRoot,
                                 appVersion: "0.1.0").preflightCombinedExport(job, editedAudioURL: wav)
            Issue.record("Whole transaction must exceed WAV plus scratch capacity")
        } catch VoxClipError.diskFull { /* expected before staging */ }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratchRoot.path).isEmpty)
        #expect(try Data(contentsOf: video) == oldVideo)
        #expect(try Data(contentsOf: wav) == oldWAV)
        #expect(!FileManager.default.fileExists(atPath: video.path + ".partial"))
        #expect(!FileManager.default.fileExists(atPath: wav.path + ".partial"))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        // The fake provider places scratch on another volume. WAV alone fits the
        // output volume; marked MP4, SRT, sidecar and rollback still must fit there.
        let tempPath = FileManager.default.temporaryDirectory.path
        do {
            try await AVExporter(capacityProvider: { directory in
                directory.path == tempPath ? .init(id: 2, freeBytes: scratch + 1_000_000)
                                           : .init(id: 1, freeBytes: wavBytes + 1_000_000)
            }, appVersion: "0.1.0").preflightCombinedExport(job, editedAudioURL: wav)
            Issue.record("Output volume must hold the complete publication")
        } catch VoxClipError.diskFull { /* expected */ }
        let exporter = AVExporter(capacityProvider: { directory in
            directory.path == tempPath ? .init(id: 2, freeBytes: scratch + 1_000_000)
                                       : .init(id: 1, freeBytes: 2_000_000_000)
        }, appVersion: "0.1.0")
        try await exporter.preflightCombinedExport(job, editedAudioURL: wav)
        let staged = try await exporter.stageEditedAudio(request, to: wav)
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try await exporter.export(job, additionalOutputs: [(partial: staged, destination: wav)]) { _ in }
        #expect(FileManager.default.fileExists(atPath: video.path))
        #expect(FileManager.default.fileExists(atPath: wav.path))
        #expect(FileManager.default.fileExists(atPath: srt.path))
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test func plannedRiffOverflowRefusesBeforeReaderOrOutput() async throws {
        let maximum = (Int64(UInt32.max) - 36) / 8
        #expect(try PCMFile.plannedBytes(frames: maximum, channels: 2, bits: 32) == maximum * 8 + 44)
        #expect(throws: VoxClipError.self) {
            _ = try PCMFile.plannedBytes(frames: maximum + 1, channels: 2, bits: 32)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-riff-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.mov")
        let plan = EditPlan(sampleRate: 48_000, totalSamples: maximum + 1,
                            kept: [MediaInterval(startSample: 0, endSample: maximum + 1)])
        let request = RenderRequest(sourceURL: missing, plan: plan,
            output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30, videoBitrate: 2_000_000))
        let wav = root.appendingPathComponent("oversized.wav")
        do {
            _ = try await AVExporter().stageEditedAudio(request, to: wav)
            Issue.record("RIFF overflow must fail before source opening")
        } catch VoxClipError.exportFailed(let detail) {
            #expect(detail.contains("RIFF size limit"))
        }
        #expect(!FileManager.default.fileExists(atPath: wav.path))
        #expect(!FileManager.default.fileExists(atPath: wav.path + ".partial"))
        do {
            try await AVExporter().preflightCombinedExport(ExportJob(render: request, outputURL: root.appendingPathComponent("large.mp4")),
                                                            editedAudioURL: wav)
            Issue.record("Combined transaction must reject known RIFF overflow")
        } catch VoxClipError.exportFailed(let detail) {
            #expect(detail.contains("RIFF size limit"))
        }
    }

    @Test func missingSelectedAssetCannotBuildGraph() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-missing-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        let (project, input) = try fixture(source: media, root: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(project.id).appendingPathComponent("asset-one.wav"))
        let legacy = try legacyPlan(project)
        let request = RenderRequest(sourceURL: media, plan: legacy,
                                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                       videoBitrate: 2_000_000), voiceLab: input)
        do {
            _ = try await CompositionBuilder().build(request)
            Issue.record("Missing paid audio must stop composition")
        } catch VoiceLabAssetError.missing { /* expected */ }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("output.mp4").path))
    }

    @Test(.timeLimit(.minutes(2))) func disabledSyntheticSelectionUsesLegacyComposition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-disabled-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await source(in: root)
        let (initial, _) = try fixture(source: media, root: root)
        let project = try VoiceLabProject.setEnabled(false, id: "vl-passage", in: initial)
        let prepared = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
        #expect(!prepared.outputPlan.requiresSyntheticRendering)
        let input = try VoiceLabRenderInput(project: project, scope: .full, labelPosition: .topRight,
                                            paidRoot: root, prepared: prepared)
        let request = RenderRequest(sourceURL: media, plan: try legacyPlan(project),
                                    output: OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30,
                                                       videoBitrate: 2_000_000), voiceLab: input)
        #expect(request.timeline == .legacy(request.plan))
        let graph = try await CompositionBuilder().build(request)
        #expect(graph.voiceLabLease == nil)
        #expect(graph.audioMix != nil)
        var excluded = initial
        excluded.edits.clips = [ClipRange(id: "late", startWordId: "w9", endWordId: "w9")]
        let scoped = try VoiceLabRenderContract.prepare(excluded, scope: .clip("late"), labelPosition: .topRight)
        #expect(!scoped.outputPlan.requiresSyntheticRendering)
        let excludedInput = try VoiceLabRenderInput(project: excluded, scope: .clip("late"),
                                                   labelPosition: .topRight, paidRoot: root, prepared: scoped)
        let excludedRequest = RenderRequest(sourceURL: media, plan: try legacyPlan(excluded, scope: .clip("late")),
                                            output: request.output, voiceLab: excludedInput)
        #expect(excludedRequest.timeline == .legacy(excludedRequest.plan))
        let excludedGraph = try await CompositionBuilder().build(excludedRequest)
        #expect(excludedGraph.voiceLabLease == nil)
        #expect(excludedGraph.audioMix != nil)
    }

    @Test(.timeLimit(.minutes(3))) func taggedDisabledAndExcludedWAVMatchNilLegacyTailRoute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-disabled-tail-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try await shortAudioSource(in: root)
        let (initial, _) = try fixture(source: media, root: root)
        let disabled = try VoiceLabProject.setEnabled(false, id: "vl-passage", in: initial)
        let output = OutputSpec(size: PixelSize(width: 640, height: 360), fps: 30, videoBitrate: 2_000_000)
        for (project, scope) in [(disabled, VoiceLabOutputScope.full), (initial, .clip("late"))] {
            var selected = project
            if scope == .clip("late") {
                selected.edits.clips = [ClipRange(id: "late", startWordId: "w9", endWordId: "w9")]
            }
            let prepared = try VoiceLabRenderContract.prepare(selected, scope: scope, labelPosition: .topRight)
            #expect(!prepared.outputPlan.requiresSyntheticRendering)
            let input = try VoiceLabRenderInput(project: selected, scope: scope, labelPosition: .topRight,
                                                paidRoot: root, prepared: prepared)
            let plan = try legacyPlan(selected, scope: scope)
            let tagged = RenderRequest(sourceURL: media, plan: plan, output: output, voiceLab: input)
            let nilRoute = RenderRequest(sourceURL: media, plan: plan, output: output)
            let name = scope == .full ? "disabled" : "excluded"
            let taggedWAV = root.appendingPathComponent("\(name)-tagged.wav")
            let nilWAV = root.appendingPathComponent("\(name)-nil.wav")
            try await AVExporter().writeEditedAudio(tagged, to: taggedWAV)
            try await AVExporter().writeEditedAudio(nilRoute, to: nilWAV)
            #expect(try Data(contentsOf: taggedWAV) == Data(contentsOf: nilWAV))
            #expect(try AVAudioFile(forReading: taggedWAV).length == plan.outputSamples)
        }
    }
}
}
