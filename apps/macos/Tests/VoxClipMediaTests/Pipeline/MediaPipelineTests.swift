import Testing
import Foundation
import AVFoundation
import CoreGraphics
import Synchronization
@testable import VoxClipMedia
import VoxClipCore

private func fixture(_ name: String = "bars-tone.mov") async throws -> URL {
    try await NativeMediaFixtures.shared.file(name)
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-media-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func cutPlan() -> EditPlan {
    EditPlan(sampleRate: 48000, totalSamples: 96000, cuts: [MediaInterval(startSample: 24000, endSample: 36000)],
             kept: [MediaInterval(startSample: 0, endSample: 24000), MediaInterval(startSample: 36000, endSample: 96000)])
}

private func request(plan: EditPlan = cutPlan(), size: PixelSize = PixelSize(width: 320, height: 180)) async throws -> RenderRequest {
    RenderRequest(sourceURL: try await fixture(), plan: plan, output: OutputSpec(size: size, fps: 30, videoBitrate: 2_000_000))
}

extension HeavyMediaTests {
@Test func rejectsUnsupportedContainersBeforeOpening() async throws {
    for ext in ["webm", "mkv", "WEBM"] {
        await #expect(throws: VoxClipError.unsupportedContainer(ext.uppercased())) {
            try await AVMediaProbe().probe(URL(fileURLWithPath: "/missing/input.\(ext)"))
        }
    }
}

@Test func probeNativeClip() async throws {
    let probe = try await AVMediaProbe().probe(fixture())
    #expect(probe.isPlayable)
    #expect(probe.videoCodec == "h264")
    #expect(probe.audio == MediaAudio(sampleRate: 48000, channels: 2))
    #expect(probe.orientedSize == PixelSize(width: 320, height: 180))
    #expect(abs(probe.durationSeconds - 2) < 0.001)
}

@Test func exportPresetsAnd1080Cap() throws {
    let probe = MediaProbeResult(durationSeconds: 2, video: MediaVideo(width: 3840, height: 2160, frameRate: 59.94),
                                 orientedSize: PixelSize(width: 3840, height: 2160), isPlayable: true)
    let source = try OutputSpec.resolved(source: probe)
    #expect(source.size == PixelSize(width: 1920, height: 1080))
    #expect(source.fps == 60)
    #expect(source.videoBitrate == 12_000_000)
    #expect(try OutputSpec.resolved(source: probe, aspect: .portrait).size == PixelSize(width: 1080, height: 1920))
    #expect(try OutputSpec.resolved(source: probe, aspect: .square, quality: .high).videoBitrate == 13_500_000)
    let crop = FrameCompositor.centerCrop(source: CGRect(x: 0, y: 0, width: 1920, height: 1080), output: CGSize(width: 1080, height: 1920))
    #expect(crop.height == 1080)
    #expect(abs(crop.width - 607.5) < 0.001)
    #expect(crop.midX == 960)
}

@Test @MainActor func compositionAppliesCutsWithoutCaptions() async throws {
    let graph = try await CompositionBuilder().build(request())
    #expect(graph.composition.duration == CMTime(value: 84000, timescale: 48000))
    #expect(graph.videoTrack.segments.count == 2)
    #expect(graph.audioTrack?.segments.count == 2)
    #expect(graph.videoComposition.customVideoCompositorClass == FrameCompositor.self)
    #expect(graph.audioMix?.inputParameters.first?.audioTapProcessor != nil)
}

@Test func extractedPCMAndEnvelope() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try await AVAudioExtractor().extract(AudioExtractionRequest(sourceURL: fixture(), contentKey: "test", durationSeconds: 2, cacheDirectory: directory)) { _ in }
    #expect(result.audio.sampleCount == 32000)
    #expect(result.audio.audioTrackIndex == 0)
    #expect(result.envelope.levels.count == 200)
    #expect(result.envelope.levels.allSatisfy { $0 > 0.26 && $0 < 0.31 })
    let data = try Data(contentsOf: result.audio.wav16k)
    #expect(data.count == 64044)
    #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
}

@Test func editedAudioIsSampleExactAndFadesReachSilence() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("edited.wav")
    try await AVExporter().writeEditedAudio(request(), to: destination)
    let data = try Data(contentsOf: destination)
    let expectedByteCount: Int = 44 + 84_000 * 8
    #expect(data.count == expectedByteCount)
    let values = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    for frame in 23997...24003 {
        #expect(abs(values[frame * 2]) < 0.01)
        #expect(abs(values[frame * 2 + 1]) < 0.01)
    }
    for fraction in [0.1, 0.5, 0.9] {
        let frame = Int(84000 * fraction)
        let sourceFrame = frame < 24000 ? frame : frame + 12000
        let expected = Float(0.4 * sin(2 * .pi * 441 * Double(sourceFrame) / 48000))
        #expect(abs(values[frame * 2] - expected) < 0.001)
    }
}

@Test(.timeLimit(.minutes(1))) func exportsPlayableH264AndAAC() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("out.mp4")
    let result = try await AVExporter().export(ExportJob(render: request(), outputURL: destination)) { _ in }
    #expect(result.width == 320 && result.height == 180)
    #expect(result.frames >= 52 && result.frames <= 53)
    #expect(result.audioSamples == 84000)
    #expect(!FileManager.default.fileExists(atPath: destination.path + ".partial"))
    let probe = try await AVMediaProbe().probe(destination)
    #expect(probe.videoCodec == "h264")
    #expect(probe.audio?.sampleRate == 48000)
    #expect(abs(probe.durationSeconds - 1.75) < 0.034)
    let bytes = try Data(contentsOf: destination)
    let moov = try #require(bytes.range(of: Data("moov".utf8)))
    let mdat = try #require(bytes.range(of: Data("mdat".utf8)))
    #expect(moov.lowerBound < mdat.lowerBound)
}

@Test(.timeLimit(.minutes(1))) func pocketMain10UsesFirstAudioTrack() async throws {
    let source = try await fixture("pocket-main10.mov")
    let probe = try await AVMediaProbe().probe(source)
    #expect(probe.videoCodec == "hevc")
    #expect(probe.audio?.sampleRate == 48000)
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let extracted = try await AVAudioExtractor().extract(AudioExtractionRequest(sourceURL: source, contentKey: "pocket", durationSeconds: 1, cacheDirectory: directory)) { _ in }
    #expect(extracted.audio.audioTrackIndex == 0)
    let data = try Data(contentsOf: extracted.audio.wav16k)
    let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    var crossings = 0
    for index in 1601..<14400 where samples[index - 1] <= 0 && samples[index] > 0 { crossings += 1 }
    #expect(abs(Double(crossings) / 0.8 - 441) < 4)
    let plan = EditPlan(sampleRate: 48000, totalSamples: 48000, kept: [MediaInterval(startSample: 0, endSample: 48000)])
    let render = RenderRequest(sourceURL: source, plan: plan, output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let result = try await AVExporter().export(ExportJob(render: render, outputURL: directory.appendingPathComponent("pocket.mp4"))) { _ in }
    #expect(result.frames == 30)
}

@Test func everythingCutLeavesNoOutput() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let plan = EditPlan(sampleRate: 48000, totalSamples: 96000, kept: [])
    let destination = directory.appendingPathComponent("empty.mp4")
    await #expect(throws: VoxClipError.everythingCut) {
        try await AVExporter().export(ExportJob(render: request(plan: plan), outputURL: destination)) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(!FileManager.default.fileExists(atPath: destination.path + ".partial"))
}

@Test func emptyTimelinePreflightPreservesOutputsBeforeSourceAndCapacity() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let plan = EditPlan(sampleRate: 48000, totalSamples: 96000, kept: [])
    let missingSource = directory.appendingPathComponent("missing.mov")
    let video = directory.appendingPathComponent("existing.mp4")
    let wav = directory.appendingPathComponent("existing.wav")
    let srt = directory.appendingPathComponent("existing.srt")
    let oldVideo = Data("old video".utf8)
    let oldWAV = Data("old wav".utf8)
    let oldSRT = Data("old subtitles".utf8)
    try oldVideo.write(to: video)
    try oldWAV.write(to: wav)
    try oldSRT.write(to: srt)
    let render = RenderRequest(sourceURL: missingSource, plan: plan,
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let job = ExportJob(render: render, outputURL: video, writeSRT: true, srtURL: srt)
    let exporter = AVExporter(capacityProvider: { _ in .init(id: 1, freeBytes: 0) })
    await #expect(throws: VoxClipError.everythingCut) {
        try await exporter.preflightCombinedExport(job, editedAudioURL: wav)
    }
    await #expect(throws: VoxClipError.everythingCut) {
        _ = try await exporter.export(job) { _ in }
    }
    #expect(try Data(contentsOf: video) == oldVideo)
    #expect(try Data(contentsOf: wav) == oldWAV)
    #expect(try Data(contentsOf: srt) == oldSRT)
    for output in [video, wav, srt] {
        #expect(!FileManager.default.fileExists(atPath: output.path + ".partial"))
    }
}

actor TestCaptionRasterizer: CaptionRasterizer {
    private(set) var times: [Double] = []
    func rasterize(_ request: CaptionRasterRequest) async throws -> CaptionRaster {
        times.append(request.time)
        var rgba = Data(repeating: 0, count: request.width * request.height * 4)
        rgba.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for row in 0..<min(20, request.height) {
                for column in 0..<min(40, request.width) {
                    let offset = (row * request.width + column) * 4
                    bytes[offset] = 255; bytes[offset + 3] = 255
                }
            }
        }
        return CaptionRaster(width: request.width, height: request.height, bytesPerRow: request.width * 4, rgba: rgba)
    }
}

@Test func rescaledTapGainsAndClipEdges() throws {
    let plan = EditPlan(sampleRate: 44100, totalSamples: 88200, kept: [MediaInterval(startSample: 4410, endSample: 48510)])
    #expect(plan.joins == [Join(outSample: 0, fadeOutLen: 0, fadeInLen: 221), Join(outSample: 44100, fadeOutLen: 221, fadeInLen: 0)])
    let context = try FadeTap().prepare(plan: plan)
    #expect(context.gain(0) == 0)
    #expect(context.gain(22050) == 1)
    #expect(context.gain(44099) == 0)
    context.prepare(AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0))
    #expect(context.processingGain(0) == 0)
    #expect(context.processingGain(47999) == 0)
    #expect(context.processingGain(241) == 1)
    #expect(context.processingGain(24000) == 1)
}

@Test func zeroLengthFadeSidesLeaveSamplesUnchanged() throws {
    for kept in [MediaInterval(startSample: 0, endSample: 24000),
                 MediaInterval(startSample: 72000, endSample: 96000),
                 MediaInterval(startSample: 0, endSample: 96000)] {
        let plan = EditPlan(sampleRate: 48000, totalSamples: 96000, kept: [kept])
        let context = try FadeTap().prepare(plan: plan)
        let hasFadeOut = kept.endSample < plan.totalSamples
        let hasFadeIn = kept.startSample > 0
        #expect(plan.joins == (hasFadeOut ? [Join(outSample: 24000, fadeOutLen: 240, fadeInLen: 0)] :
            hasFadeIn ? [Join(outSample: 0, fadeOutLen: 0, fadeInLen: 240)] : []))
        #expect(context.processingGain(23999) == (hasFadeOut ? 0 : 1))
        #expect(context.processingGain(24000) == 1)
        #expect(context.processingGain(0) == (hasFadeIn ? 0 : 1))
        #expect(context.processingGain(239) == (hasFadeIn ? Float(239) / 240 : 1))
        #expect(context.processingGain(240) == 1)
        #expect(context.processingGain(23759) == 1)
        #expect(context.processingGain(24240) == 1)
    }
}

@Test(.timeLimit(.minutes(1))) func headAndTailCutRenderBothClipEdgeFades() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let plan = EditPlan(sampleRate: 48000, totalSamples: 96000,
        kept: [MediaInterval(startSample: 12000, endSample: 84000)])
    let destination = directory.appendingPathComponent("clip-edges.wav")
    try await AVExporter().writeEditedAudio(request(plan: plan), to: destination)
    let values = try Data(contentsOf: destination).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    #expect(values.count == 72000 * 2)
    #expect(values[0] == 0 && values[1] == 0)
    #expect(values[143998] == 0 && values[143999] == 0)
    for frame in [1, 120, 239, 240, 36000, 71759, 71760, 71879, 71998] {
        let fadeIn = frame < 240 ? Double(frame) / 240 : 1
        let fadeOut = 71999 - frame < 240 ? Double(71999 - frame) / 240 : 1
        let original = 0.4 * sin(2 * .pi * 441 * Double(frame + 12000) / 48000)
        let expected = Float(original * fadeIn * fadeOut)
        #expect(abs(values[frame * 2] - expected) < 0.00001)
        #expect(abs(values[frame * 2 + 1] - expected) < 0.00001)
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor func previewTapFadesAfterSeekingAndRateChanges() async throws {
    let graph = try await CompositionBuilder().build(request())
    let track = try #require(graph.audioTrack)
    let player = AVPlayer()
    player.volume = 0
    defer { player.pause(); player.replaceCurrentItem(with: nil) }
    for (time, rate) in [(0.13, Float(0.5)), (0.27, Float(1)), (0.39, Float(2))] {
        let capture = FadeContext(plan: cutPlan(), captureCapacity: 96000)
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = try FadeTap.make(context: capture)
        let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]
        let item = AVPlayerItem(asset: graph.composition)
        item.audioTimePitchAlgorithm = .varispeed
        item.audioMix = mix
        item.videoComposition = graph.videoComposition
        player.replaceCurrentItem(with: item)
        _ = await player.seek(to: CMTime(seconds: time, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
        player.rate = rate
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var samples: [(Int64, Float)] = []
        repeat {
            try await Task.sleep(for: .milliseconds(50))
            samples = capture.capturedSamples().filter { abs($0.0 - Int64((0.5 * capture.capturedSampleRate).rounded())) <= 3 }
        } while samples.isEmpty && ContinuousClock.now < deadline
        player.pause()
        #expect(!samples.isEmpty, "seek=\(time), rate=\(rate), processingRate=\(capture.capturedSampleRate), captured=\(capture.capturedSamples().count), nearest=\(String(describing: capture.capturedSamples().min(by: { abs($0.0 - Int64(0.5 * capture.capturedSampleRate)) < abs($1.0 - Int64(0.5 * capture.capturedSampleRate)) })))")
        #expect(samples.allSatisfy { abs($0.1) < 0.01 })
    }
}

@Test(.timeLimit(.minutes(1))) func compositorUsesRasterizerAndEditedFrameTimes() async throws {
    let shared = try FixtureLoader.sharedRoot(environment: [:])
    var style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: shared.appendingPathComponent("caption-styles/styles/vox-highlight.json")))
    style.animation = nil; style.effects = nil; style.reveal = nil
    let page = CaptionPage(index: 0, words: [CaptionWord(id: "word", text: "test", start: 0.2, end: 0.7)], start: 0.2, end: 0.7, fontPx: 20,
                           block: CaptionRect(x: 0, y: 0, width: 40, height: 20), visual: CaptionRect(x: 0, y: 0, width: 40, height: 20))
    var render = try await request()
    render.style = style; render.captions = CaptionTrack(pages: [page])
    let renderer = TestCaptionRasterizer()
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await AVExporter(rasterizer: renderer).export(ExportJob(render: render, outputURL: directory.appendingPathComponent("captioned.mp4"))) { _ in }
    let times = await renderer.times
    #expect(!times.isEmpty)
    #expect(times.allSatisfy { $0 >= 0.2 && $0 < 0.7 && abs($0 * 30 - ($0 * 30).rounded()) < 1e-6 })
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) func colorBarsSurviveAspectCrops(_ forPreview: Bool) async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for size in [PixelSize(width: 180, height: 320), PixelSize(width: 180, height: 180), PixelSize(width: 320, height: 180)] {
        let destination = directory.appendingPathComponent("\(size.width)x\(size.height).mp4")
        var render = try await request(size: size)
        render.forPreview = forPreview
        _ = try await AVExporter().export(ExportJob(render: render, outputURL: destination)) { _ in }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
        let image = try await generator.image(at: CMTime(value: 1, timescale: 5)).image
        #expect(image.width == size.width && image.height == size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: -Double(size.width / 2 - 4), y: -Double(size.height / 2))
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        #expect(pixel[1] > 140)
        #expect(pixel[0] < 40 && pixel[2] < 40)
        let points = [(0, size.height / 2), (4, size.height / 2), (size.width - 1, size.height / 2), (size.width - 5, size.height / 2),
                      (size.width / 2 - 4, 0), (size.width / 2 - 4, 4), (size.width / 2 - 4, size.height - 1), (size.width / 2 - 4, size.height - 5)]
        let frames = try await sampledFrames(destination, points: points)
        for frame in frames {
            for edge in stride(from: 0, to: points.count, by: 2) {
                for channel in 0..<3 { #expect(abs(frame.pixels[edge][channel] - frame.pixels[edge + 1][channel]) <= 4) }
            }
        }
    }
}

@Test(.timeLimit(.minutes(1))) func cancellationDeletesPartialOutput() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("cancelled.mp4")
    let render = try await request(size: PixelSize(width: 1080, height: 1920))
    let encoding = Mutex(false)
    let task = Task {
        try await AVExporter().export(ExportJob(render: render, outputURL: destination)) { progress in
            if progress.phase == .encoding { encoding.withLock { $0 = true } }
        }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !encoding.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(encoding.withLock { $0 })
    let stoppedAt = Mutex<ContinuousClock.Instant?>(.now)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await awaitStoppedExport(task, stoppedAt: { stoppedAt.withLock { $0 } }) }
    #expect(!FileManager.default.fileExists(atPath: destination.path + ".partial"))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    print("USER_CANCEL duration=\(try #require(stoppedAt.withLock { $0 }).duration(to: .now))")
}

@Test(.timeLimit(.minutes(1))) func fixtureWaitsEndWhileGenerationIsStuck() async throws {
    let stall = AsyncStream<Void>.makeStream()
    defer { stall.continuation.finish() }
    let stuck = Task<URL, any Error> {
        for await _ in stall.stream {}
        throw CancellationError()
    }
    let waiter = Task { try await NativeMediaFixtures.value(of: stuck) }
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    await #expect(throws: NativeMediaFixtures.Timeout.self) {
        try await NativeMediaFixtures.value(of: stuck, within: .milliseconds(50))
    }
}
}
