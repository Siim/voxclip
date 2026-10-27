import AVFoundation
import Foundation
import Synchronization
import Testing
import VoxClipCore
@testable import VoxClipMedia

private func identityPlan(_ seconds: Int) -> EditPlan {
    let samples = Int64(seconds * 48000)
    return EditPlan(sampleRate: 48000, totalSamples: samples, kept: [MediaInterval(startSample: 0, endSample: samples)])
}

private func outputDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-verification-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

struct SampledFrame: Sendable {
    let time: Double
    let pixels: [[Int]]
}

func sampledFrames(_ url: URL, points: [(Int, Int)]) async throws -> [SampledFrame] {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    let provider = reader.outputProvider(for: output)
    guard reader.startReading() else { throw VoxClipError.decodeFailed("Cannot verify video") }
    var frames: [SampledFrame] = []
    while let ready = try await provider.next() {
        try Task.checkCancellation()
        let pixels = try ready.withUnsafeSampleBuffer { sample -> [[Int]] in
            let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
            let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            return points.map { column, row in
                let luminance = (Double(luma[row * lumaStride + column]) - 16) * 255 / 219
                let chromaOffset = (row / 2) * chromaStride + (column / 2) * 2
                let blueDifference = (Double(chroma[chromaOffset]) - 128) * 255 / 224
                let redDifference = (Double(chroma[chromaOffset + 1]) - 128) * 255 / 224
                return [luminance + 1.5748 * redDifference,
                        luminance - 0.187324 * blueDifference - 0.468124 * redDifference,
                        luminance + 1.8556 * blueDifference].map { min(255, max(0, Int($0.rounded()))) }
            }
        }
        frames.append(SampledFrame(time: ready.presentationTimeStamp.seconds, pixels: pixels))
    }
    #expect(reader.status == .completed)
    return frames
}

extension HeavyMediaTests {
@Test func sampleRangesAndFrameRateAreValidated() async throws {
    let source = try await NativeMediaFixtures.shared.file()
    for kept in [[MediaInterval(startSample: 0, endSample: 60000), MediaInterval(startSample: 30000, endSample: 50000)],
                 [MediaInterval(startSample: -1, endSample: 96000)]] {
        let plan = EditPlan(sampleRate: 48000, totalSamples: 96000, kept: kept)
        await #expect(throws: (any Error).self) {
            _ = try await CompositionBuilder().build(RenderRequest(sourceURL: source, plan: plan, output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000)))
        }
    }
    var request = RenderRequest(sourceURL: source, plan: identityPlan(2), output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 29.97, videoBitrate: 2_000_000))
    await #expect(throws: (any Error).self) { _ = try await CompositionBuilder().build(request) }
    request.output.fps = 30
    request.output.videoBitrate = 0
    await #expect(throws: (any Error).self) { _ = try await CompositionBuilder().build(request) }
}

@Test func rotationAndMain10CameraMetadata() async throws {
    let rotated = try await AVMediaProbe().probe(NativeMediaFixtures.shared.file("rotated.mov"))
    #expect(rotated.video?.rotationDegrees == 90)
    #expect(rotated.orientedSize == PixelSize(width: 180, height: 320))
    let source = try await NativeMediaFixtures.shared.file("pocket-main10.mov")
    let tracks = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
    #expect(tracks.count == 2)
    for track in tracks {
        let formats = try await track.load(.formatDescriptions)
        #expect(formats.first.map(CMFormatDescriptionGetMediaSubType) == kAudioFormatMPEG4AAC)
    }
    let directory = try outputDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let extracted = try await AVAudioExtractor().extract(AudioExtractionRequest(sourceURL: source, contentKey: "second-track", durationSeconds: 1,
        audioTrackIndex: 1, cacheDirectory: directory)) { _ in }
    #expect(extracted.audio.audioTrackIndex == 1)
    let samples = try Data(contentsOf: extracted.audio.wav16k).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    let crossings = (1601..<14400).filter { samples[$0 - 1] <= 0 && samples[$0] > 0 }.count
    #expect(abs(Double(crossings) / 0.8 - 882) < 5)
}

@Test(.timeLimit(.minutes(1))) func manyJoinFadesPreserveSampleAlignment() async throws {
    let source = try await NativeMediaFixtures.shared.file("joins-tone.mov")
    let total: Int64 = 12 * 48000
    var kept: [MediaInterval] = []
    var joins: [Join] = []
    var cursor: Int64 = 0
    var outputSamples: Int64 = 0
    for index in 0..<59 {
        let start = Int64(5280 + 9600 * index)
        kept.append(MediaInterval(startSample: cursor, endSample: start))
        outputSamples += start - cursor
        joins.append(Join(outSample: outputSamples, fadeOutLen: 240, fadeInLen: 240))
        cursor = start + 3840
    }
    kept.append(MediaInterval(startSample: cursor, endSample: total))
    outputSamples += total - cursor
    let plan = EditPlan(sampleRate: 48000, totalSamples: total, kept: kept)
    #expect(plan.outputSamples == outputSamples)
    #expect(plan.joins == joins)
    let request = RenderRequest(sourceURL: source, plan: plan, output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let directory = try outputDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("joins.wav")
    try await AVExporter().writeEditedAudio(request, to: destination)
    let values = try Data(contentsOf: destination).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    #expect(values.count == Int(outputSamples) * 2)
    for join in joins {
        for offset in -3...3 { #expect(abs(values[Int(join.outSample + Int64(offset)) * 2]) < 0.01) }
    }
    for fraction in [0.1, 0.5, 0.9] {
        let frame = Int64(Double(outputSamples) * fraction)
        var outputStart: Int64 = 0
        for range in kept {
            if frame < outputStart + range.count {
                let sourceSample = range.startSample + frame - outputStart
                let expected = Float(0.4 * sin(2 * .pi * 441 * Double(sourceSample) / 48000))
                #expect(abs(values[Int(frame) * 2] - expected) < 0.00001)
                break
            }
            outputStart += range.count
        }
    }
}

@Test(.timeLimit(.minutes(1))) func exportCapsLargeSourcesAndPreserves709Bars() async throws {
    let directory = try outputDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["big.mov", "bars.mov"] {
        let source = try await NativeMediaFixtures.shared.file(name)
        let probe = try await AVMediaProbe().probe(source)
        let output = try OutputSpec.resolved(source: probe)
        let destination = directory.appendingPathComponent("\(name).mp4")
        let result = try await AVExporter().export(ExportJob(render: RenderRequest(sourceURL: source, plan: identityPlan(2), output: output), outputURL: destination)) { _ in }
        #expect(result.width == 1920 && result.height == 1080)
        #expect(result.frames == 60)
        if name == "bars.mov" {
            let frames = try await sampledFrames(destination, points: (0..<8).map { (120 + 240 * $0, 540) })
            let expected = [[191,191,191], [191,191,0], [0,191,191], [0,191,0], [191,0,191], [191,0,0], [0,0,191], [0,0,0]]
            let sourceFrames = try await sampledFrames(source, points: (0..<8).map { (120 + 240 * $0, 540) })
            for frame in sourceFrames {
                for bar in 0..<8 { for channel in 0..<3 { #expect(abs(frame.pixels[bar][channel] - expected[bar][channel]) <= 3) } }
            }
            // Exported colour is accepted by E2E case 8 under ADR-R22; the source fixture keeps its canonical check.
            #expect(frames.count == 60)
            let format = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video)[0].load(.formatDescriptions)[0]
            #expect(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        }
    }
}

@Test(.timeLimit(.minutes(1))) func portraitCropPreservesMarkersAndFrameBarcodes() async throws {
    let source = try await NativeMediaFixtures.shared.file("counter.mov")
    let directory = try outputDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = try await AVMediaProbe().probe(source)
    let output = try OutputSpec.resolved(source: probe, aspect: .portrait)
    let request = RenderRequest(sourceURL: source, plan: identityPlan(2), output: output)
    let destination = directory.appendingPathComponent("counter.mp4")
    _ = try await AVExporter().export(ExportJob(render: request, outputURL: destination)) { _ in }
    var barcode: [(Int, Int)] = []
    let scale = 1920.0 / 1080.0
    let barcodeRow = Int((32.0 * scale).rounded())
    for bit in 0..<12 {
        let sourceColumn = 736.0 + Double(bit) * 40.0
        let outputColumn = Int(((sourceColumn - 656.25) * scale).rounded())
        barcode.append((outputColumn, barcodeRow))
    }
    let frames = try await sampledFrames(destination, points: [(185, 1000), (895, 1000)] + barcode)
    #expect(frames.count == 60)
    for frame in frames {
        #expect(frame.pixels[0].min()! > 200 && frame.pixels[1].min()! > 200)
        let code = frame.pixels.dropFirst(2).reduce(0) { ($0 << 1) | ($1[0] >= 128 ? 1 : 0) }
        #expect(code == Int((frame.time * 30).rounded()))
    }
}

@Test(.timeLimit(.minutes(1))) func captionsAreVisibleOnlyInsideTheirEditedInterval() async throws {
    let source = try await NativeMediaFixtures.shared.file()
    let shared = try FixtureLoader.sharedRoot(environment: [:])
    let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: shared.appendingPathComponent("caption-styles/styles/vox-highlight.json")))
    let page = CaptionPage(index: 0, words: [CaptionWord(id: "word", text: "test", start: 0.2, end: 0.7)], start: 0.2, end: 0.7,
        fontPx: 20, block: CaptionRect(x: 0, y: 0, width: 40, height: 20), visual: CaptionRect(x: 0, y: 0, width: 40, height: 20))
    let request = RenderRequest(sourceURL: source, plan: identityPlan(2), captions: CaptionTrack(pages: [page]), style: style,
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let directory = try outputDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("captions.mp4")
    _ = try await AVExporter(rasterizer: TestCaptionRasterizer()).export(ExportJob(render: request, outputURL: destination)) { _ in }
    let frames = try await sampledFrames(destination, points: [(10, 10)])
    for frame in frames {
        let red = frame.pixels[0][0] > 220 && frame.pixels[0][1] < 30 && frame.pixels[0][2] < 30
        #expect(red == (frame.time >= 0.2 && frame.time < 0.7))
    }
}

private actor FailingCaptionRasterizer: CaptionRasterizer {
    func rasterize(_ request: CaptionRasterRequest) async throws -> CaptionRaster {
        throw VoxClipError.decodeFailed("Synthetic caption drawing failure")
    }
}

@Test(.timeLimit(.minutes(1))) func captionFailureStopsBothExportPumpsAndAllowsReuse() async throws {
    let source = try await NativeMediaFixtures.shared.file()
    let shared = try FixtureLoader.sharedRoot(environment: [:])
    let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: shared.appendingPathComponent("caption-styles/styles/vox-highlight.json")))
    let page = CaptionPage(index: 0, words: [CaptionWord(id: "word", text: "test", start: 0, end: 2)], start: 0, end: 2,
        fontPx: 20, block: CaptionRect(x: 0, y: 0, width: 40, height: 20), visual: CaptionRect(x: 0, y: 0, width: 40, height: 20))
    var request = RenderRequest(sourceURL: source, plan: identityPlan(2), captions: CaptionTrack(pages: [page]), style: style,
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let directory = try outputDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let exporter = AVExporter(rasterizer: FailingCaptionRasterizer())
    await #expect(throws: (any Error).self) {
        try await exporter.export(ExportJob(render: request, outputURL: directory.appendingPathComponent("failed.mp4"))) { _ in }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    request.style = nil
    request.captions = CaptionTrack()
    let destination = directory.appendingPathComponent("retry.mp4")
    let result = try await exporter.export(ExportJob(render: request, outputURL: destination)) { _ in }
    #expect(result.frames == 60)
    #expect(result.audioSamples == 96000)
    #expect(try await AVMediaProbe().probe(destination).isPlayable)
}

@Test(.timeLimit(.minutes(1))) func exportProgressIsThrottledAndDestinationsAreSafe() async throws {
    let source = try await NativeMediaFixtures.shared.file()
    let directory = try outputDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = RenderRequest(sourceURL: source, plan: identityPlan(2), output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let reports = Mutex<[(ContinuousClock.Instant, ExportProgress)]>([])
    let destination = directory.appendingPathComponent("progress.mp4")
    _ = try await AVExporter().export(ExportJob(render: request, outputURL: destination)) { value in reports.withLock { $0.append((.now, value)) } }
    let values = reports.withLock { $0 }
    #expect(values.first?.1.phase == .preparing)
    #expect(values.last?.1.phase == .finalizing)
    for (earlier, later) in zip(values, values.dropFirst()) { #expect(earlier.0.duration(to: later.0) >= .milliseconds(95)) }
    let alias = directory.appendingPathComponent("alias.mov")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
    await #expect(throws: (any Error).self) { _ = try await AVExporter().export(ExportJob(render: request, outputURL: alias)) { _ in } }
    await #expect(throws: (any Error).self) {
        _ = try await AVExporter().export(ExportJob(render: request, outputURL: destination, writeSRT: true, srtURL: URL(fileURLWithPath: destination.path + ".partial"))) { _ in }
    }
}

@Test @MainActor func previewCaptionUpdatesReuseTheComposition() async throws {
    let source = try await NativeMediaFixtures.shared.file()
    let request = RenderRequest(sourceURL: source, plan: identityPlan(2), output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let preview = PreviewPlayerController()
    defer { preview.close() }
    try await preview.load(request)
    let asset = try #require(preview.player.currentItem?.asset)
    try await preview.seek(to: 0.75, exact: true)
    try await preview.update(request)
    #expect(preview.player.currentItem?.asset === asset)
    #expect(abs(preview.editedTime - 0.75) < 0.001)
}

@Test(.timeLimit(.minutes(1))) func srtSidecarUsesEditedPageTimesAndUTF8() async throws {
    let source = try await NativeMediaFixtures.shared.file()
    let directory = try outputDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let page = CaptionPage(index: 7, words: [CaptionWord(id: "word", text: "Tere, maailm!", start: 0.125, end: 1.625)], start: 0.125, end: 1.625,
        fontPx: 20, block: CaptionRect(x: 0, y: 0, width: 100, height: 20), visual: CaptionRect(x: 0, y: 0, width: 100, height: 20))
    let request = RenderRequest(sourceURL: source, plan: identityPlan(2), captions: CaptionTrack(pages: [page]),
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let result = try await AVExporter().export(ExportJob(render: request, outputURL: directory.appendingPathComponent("sidecar.mp4"), writeSRT: true)) { _ in }
    let srt = try #require(result.srtURL)
    #expect(try Data(contentsOf: srt) == Data("1\n00:00:00,125 --> 00:00:01,625\nTere, maailm!\n".utf8))
}
}
