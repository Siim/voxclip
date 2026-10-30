import AVFoundation
import Foundation
import Synchronization
import Testing
import VoxClipCore
@testable import VoxClipMedia

private struct SRTFixture: Decodable {
    struct Page: Decodable { var start: Double; var end: Double; var lines: [[Int]] }
    var schema: String
    var derivation: String
    var words: [CaptionInputWord]
    var pages: [Page]
    var expected: String
}

@Test func srtBytesFollowSharedFixture() async throws {
    let fixture = try FixtureLoader.decode(SRTFixture.self, at: "fixtures/captions/srt.json")
    #expect(fixture.schema == "voxclip-srt-fixture/1")
    #expect(!fixture.derivation.isEmpty)
    let words = fixture.words.map { CaptionWord(id: $0.id, text: $0.text, start: $0.start, end: $0.end) }
    let rectangle = CaptionRect(x: 0, y: 0, width: 100, height: 20)
    let pages = fixture.pages.enumerated().map { index, page in
        CaptionPage(index: index, words: page.lines.flatMap { $0 }.map { words[$0] }, start: page.start, end: page.end,
            fontPx: 20, lines: page.lines.map { CaptionLine(words: $0, units: 100, rect: rectangle, baseline: 10) }, block: rectangle, visual: rectangle)
    }
    let expected = Data(fixture.expected.utf8)
    #expect(Data(AVExporter.srt(CaptionTrack(words: words, pages: pages)).utf8) == expected)
    #expect(AVExporter.srt(CaptionTrack()).isEmpty)
    let harness = try CaptionRenderHarness(shared: CaptionMediaFixtures.shared())
    var layout = try await harness.layout(CaptionLayoutInput(style: "vox-bold", frame: .init(width: 640, height: 360),
        language: "en", duration: 2, words: fixture.words))
    #expect(layout.words.map(\.input.text) == fixture.words.map(\.text))
    let template = try #require(layout.pages.first)
    layout.pages = pages.map { page in var copy = template; copy.page = page; return copy }
    #expect(Data(CaptionSubtitles.srt(layout).utf8) == expected)
    layout.pages = []
    #expect(CaptionSubtitles.srt(layout).isEmpty)
}

private struct ExportPresetFixture: Decodable {
    struct Case: Decodable {
        struct Expected: Decodable {
            var size: [Int]
            var crop: [Double]
            var fps: Double
            var videoBitrate: Int
        }
        var source: [Int]
        var sourceFps: Double
        var aspect: AspectRatio
        var quality: ExportQuality
        var expected: Expected
    }
    var schema: String
    var cases: [Case]
}

extension HeavyMediaTests {
@Test func allSharedExportPresetsMatchSizingAndCrop() throws {
    let fixture = try FixtureLoader.decode(ExportPresetFixture.self, at: "fixtures/export/presets.json")
    #expect(fixture.schema == "voxclip-export-fixture/1")
    #expect(fixture.cases.count == 15)
    for entry in fixture.cases {
        let size = PixelSize(width: entry.source[0], height: entry.source[1])
        let probe = MediaProbeResult(durationSeconds: 2, video: MediaVideo(width: size.width, height: size.height, frameRate: entry.sourceFps),
            orientedSize: size, isPlayable: true)
        let output = try OutputSpec.resolved(source: probe, aspect: entry.aspect, quality: entry.quality)
        #expect([output.size.width, output.size.height] == entry.expected.size)
        #expect(output.fps == entry.expected.fps)
        #expect(output.videoBitrate == entry.expected.videoBitrate)
        let coreCrop = OutputSizing.centerCrop(source: size, output: output.size)
        let crop = FrameCompositor.centerCrop(source: CGRect(x: 0, y: 0, width: size.width, height: size.height),
            output: CGSize(width: output.size.width, height: output.size.height))
        for (actual, expected) in zip([crop.minX, crop.minY, crop.width, crop.height], entry.expected.crop) {
            #expect(abs(actual - expected) < 1e-9)
        }
        for (core, media) in zip([coreCrop.x, coreCrop.y, coreCrop.width, coreCrop.height],
                                 [Double(crop.minX), Double(crop.minY), Double(crop.width), Double(crop.height)]) {
            #expect(abs(core - media) < 1e-9)
        }
    }
}

@Test func cropBoundaryPreservesOrientedImageOriginAndRoundedSourceAspect() throws {
    let source = PixelSize(width: 853, height: 480)
    let output = try OutputSizing.outputSize(source: source, aspect: .source)
    #expect(OutputSizing.centerCrop(source: source, output: output) == CaptionRect(x: 0, y: 0, width: 853, height: 480))
    let extent = CGRect(x: -17, y: 23, width: 1920, height: 1080)
    let crop = FrameCompositor.centerCrop(source: extent, output: CGSize(width: 1080, height: 1920))
    let core = OutputSizing.centerCrop(source: PixelSize(width: 1920, height: 1080), output: PixelSize(width: 1080, height: 1920))
    #expect(crop == CGRect(x: extent.minX + core.x, y: extent.minY + core.y, width: core.width, height: core.height))
    #expect(crop.midX == extent.midX && crop.midY == extent.midY)
}

private func reviewDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "/tmp/voxclip-media-review-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

@Test func srtPreservesPageLinesRawTextAndVisibleCueNumbering() {
    let words = [CaptionWord(id: "first", text: "Tere,", start: 0.0005, end: 0.5),
                 CaptionWord(id: "second", text: "maailm!", start: 0.5, end: 1),
                 CaptionWord(id: "third", text: "Straße…", start: 1, end: 1.25),
                 CaptionWord(id: "fourth", text: "Next", start: 1.3, end: 1.5),
                 CaptionWord(id: "fifth", text: "page!", start: 1.5, end: 1.8)]
    let rectangle = CaptionRect(x: 0, y: 0, width: 100, height: 20)
    let lines = [CaptionLine(words: [0, 1], units: 100, rect: rectangle, baseline: 10),
                 CaptionLine(words: [2], units: 100, rect: rectangle, baseline: 10)]
    let page = CaptionPage(index: 12, words: Array(words.prefix(3)), start: 0.0005, end: 1.25, fontPx: 20,
        lines: lines, block: rectangle, visual: rectangle)
    var hidden = page
    hidden.start = hidden.end
    var backwards = page
    backwards.end = -1
    let next = CaptionPage(index: 15, words: Array(words.suffix(2)), start: 1.3, end: 1.8, fontPx: 20,
        lines: [CaptionLine(words: [3], units: 100, rect: rectangle, baseline: 10),
                CaptionLine(words: [4], units: 100, rect: rectangle, baseline: 10)], block: rectangle, visual: rectangle)
    #expect(AVExporter.srt(CaptionTrack(words: words, pages: [hidden, page, backwards, next])) ==
        "1\n00:00:00,001 --> 00:00:01,250\nTere, maailm!\nStraße…\n\n2\n00:00:01,300 --> 00:00:01,800\nNext\npage!\n\n")
    var invalid = next
    invalid.lines[0].words = [-1, 99]
    #expect(AVExporter.srt(CaptionTrack(words: words, pages: [invalid])) ==
        "1\n00:00:01,300 --> 00:00:01,800\nNext page!\n\n")
    #expect(AVExporter.srt(CaptionTrack(pages: [next])) ==
        "1\n00:00:01,300 --> 00:00:01,800\nNext page!\n\n")
    #expect(AVExporter.srt(CaptionTrack(pages: [hidden, backwards])).isEmpty)
}

@Test(.timeLimit(.minutes(1)), arguments: [Int64(48001), 48321, 95999])
func exportedAudioPreservesSubMovieTickSampleDurations(_ count: Int64) async throws {
    let source = try await NativeMediaFixtures.shared.file()
    let directory = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let plan = EditPlan(sampleRate: 48000, totalSamples: 96000,
                        kept: [MediaInterval(startSample: 0, endSample: count)])
    let request = RenderRequest(sourceURL: source, plan: plan,
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let output = directory.appendingPathComponent("sample-exact.mp4")
    let result = try await AVExporter().export(ExportJob(render: request, outputURL: output)) { _ in }
    #expect(result.audioSamples == count)
    let audio = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).first)
    let range = try await audio.load(.timeRange)
    #expect(CMTimeCompare(range.duration, CMTime(value: result.audioSamples, timescale: 48000)) == 0)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func roundedContainerAudioTailsMatchEditedWAVAndMP4(_ clipped: Bool) async throws {
    let source = try await NativeMediaFixtures.shared.file("rounded-tail.mov")
    let directory = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = try await AVMediaProbe().probe(source)
    let total = Int64((probe.durationSeconds * 48000).rounded())
    let plan = EditPlan(sampleRate: 48000, totalSamples: total,
                        kept: [MediaInterval(startSample: clipped ? 12000 : 0, endSample: total)])
    let asset = AVURLAsset(url: source)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: 48000, channels: 2)))
    try #require(reader.startReading())
    var decoded: Int64 = 0
    while let sample = try await MediaSupport.nextSample(provider) { decoded += Int64(sample.sampleCount) }
    try #require(reader.status == .completed)
    try #require(total > decoded, "Rounded source must expose its undecodable tail: total=\(total), decoded=\(decoded)")
    let render = RenderRequest(sourceURL: source, plan: plan,
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let audio = directory.appendingPathComponent("tail.wav")
    let exporter = AVExporter()
    try await exporter.writeEditedAudio(render, to: audio)
    let samples = try Data(contentsOf: audio).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    #expect(samples.count == Int(plan.outputSamples) * 2)
    #expect(samples.suffix(Int(total - decoded) * 2).allSatisfy { $0 == 0 })
    let result = try await exporter.export(ExportJob(render: render, outputURL: directory.appendingPathComponent("tail.mp4"))) { _ in }
    #expect(result.audioSamples == plan.outputSamples)
    print("ROUNDED_AUDIO_TAIL total=\(total) decoded=\(decoded) padded=\(total - decoded) clipped=\(clipped)")
}

@Test func editedWAVResolvesExistingSymlinkDestinations() async throws {
    let directory = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target.wav")
    try Data("original".utf8).write(to: target)
    let symlink = directory.appendingPathComponent("audio.wav")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    let plan = EditPlan(sampleRate: 48000, totalSamples: 96000,
                        kept: [MediaInterval(startSample: 0, endSample: 96000)])
    let request = RenderRequest(sourceURL: try await NativeMediaFixtures.shared.file(), plan: plan,
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    try await AVExporter().writeEditedAudio(request, to: symlink)
    #expect(try symlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(try Data(contentsOf: target).count == 44 + 96000 * 8)
    #expect(!FileManager.default.fileExists(atPath: target.path + ".partial"))
}

@Test @MainActor func productionPreviewSharesOneConcreteCaptionRasterizer() async throws {
    let source = try await NativeMediaFixtures.shared.file()
    let style = try JSONDecoder().decode(CaptionStyle.self, from: FixtureLoader.data("caption-styles/styles/vox-highlight.json"))
    let plan = EditPlan(sampleRate: 48000, totalSamples: 96000,
        kept: [MediaInterval(startSample: 0, endSample: 96000)])
    var request = RenderRequest(sourceURL: source, plan: plan, style: style,
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let builder = CompositionBuilder()
    let first = try builder.makeVideoComposition(request, trackID: 1, duration: CMTime(seconds: 2, preferredTimescale: 48000), orientation: .up)
    let second = try builder.makeVideoComposition(request, trackID: 1, duration: CMTime(seconds: 2, preferredTimescale: 48000), orientation: .up)
    let firstInstruction = try #require(first.instructions.first as? RenderInstruction)
    let secondInstruction = try #require(second.instructions.first as? RenderInstruction)
    #expect(firstInstruction.rasterizer != nil)
    #expect(firstInstruction.rasterizer === secondInstruction.rasterizer)
    #expect(firstInstruction.legacyRasterizer == nil)
    let preview = PreviewPlayerController()
    defer { preview.close() }
    try await preview.load(request)
    let original = try #require(preview.player.currentItem?.videoComposition?.instructions.first as? RenderInstruction)
    request.placement = CaptionPosition(x: 0.5, y: 0.4)
    try await preview.update(request)
    let updated = try #require(preview.player.currentItem?.videoComposition?.instructions.first as? RenderInstruction)
    #expect(original.rasterizer != nil)
    #expect(original.rasterizer === updated.rasterizer)
    #expect(updated.legacyRasterizer == nil)
}

@Test(.timeLimit(.minutes(1)), arguments: [ExportPhase.preparing, .finalizing])
func cancellationAtExportPhaseBoundariesLeavesNoStaging(_ phase: ExportPhase) async throws {
    let directory = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file()
    let plan = EditPlan(sampleRate: 48000, totalSamples: 96000,
        kept: [MediaInterval(startSample: 0, endSample: 96000)])
    let render = RenderRequest(sourceURL: source, plan: plan,
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let output = directory.appendingPathComponent("cancelled.mp4")
    let observed = Mutex(false)
    let task = Task {
        try await AVExporter().export(ExportJob(render: render, outputURL: output)) { progress in
            if progress.phase == phase {
                observed.withLock { $0 = true }
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(observed.withLock { $0 })
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor func supersededPreviewBuildsKeepTheLatestSourcePlayhead() async throws {
    let source = try await NativeMediaFixtures.shared.file()
    let original = EditPlan(sampleRate: 48000, totalSamples: 96000,
        kept: [MediaInterval(startSample: 0, endSample: 96000)])
    let firstPlan = EditPlan(sampleRate: 48000, totalSamples: 96000,
        cuts: [MediaInterval(startSample: 24000, endSample: 36000)],
        kept: [MediaInterval(startSample: 0, endSample: 24000), MediaInterval(startSample: 36000, endSample: 96000)])
    let lastPlan = EditPlan(sampleRate: 48000, totalSamples: 96000,
        cuts: [MediaInterval(startSample: 0, endSample: 12000)],
        kept: [MediaInterval(startSample: 12000, endSample: 96000)])
    let output = OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000)
    let preview = PreviewPlayerController()
    defer { preview.close() }
    try await preview.load(RenderRequest(sourceURL: source, plan: original, output: output))
    try await preview.seek(to: 1.2, exact: true)
    let first = Task { try await preview.update(RenderRequest(sourceURL: source, plan: firstPlan, output: output)) }
    try await Task.sleep(for: .milliseconds(151))
    let last = Task { try await preview.update(RenderRequest(sourceURL: source, plan: lastPlan, output: output)) }
    try await first.value
    try await last.value
    let instruction = try #require(preview.player.currentItem?.videoComposition?.instructions.first as? RenderInstruction)
    #expect(instruction.request.plan == lastPlan)
    #expect(abs(lastPlan.sourceTime(fromEdited: preview.editedTime) - 1.2) < 1 / 48000)
    #expect(!preview.isPlaying)
}

@Test(arguments: ["right-only.mov", "six-channel.mov"])
func extractionDownmixesEveryChannelWithoutShiftingSampleZero(_ name: String) async throws {
    let directory = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file(name)
    let result = try await AVAudioExtractor().extract(AudioExtractionRequest(sourceURL: source, contentKey: "review", durationSeconds: 2,
        cacheDirectory: directory)) { _ in }
    let data = try Data(contentsOf: result.audio.wav16k)
    let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    #expect(samples.count == 32000)
    let expected = name == "six-channel.mov" ? 3277 : 9830
    #expect(abs(Int(samples[16000]) - expected) <= 1)
    let crossing = try #require(samples.firstIndex { Int($0) >= expected / 2 })
    #expect(crossing == 8000)
    #expect(samples[0] == 0)
    #expect(result.envelope.levels.max() ?? 0 > 0.1)
}

@Test(.timeLimit(.minutes(1)), arguments: ["audio-overhang.mov", "audio-overhang-short.mov"])
@MainActor func audioOverhangHoldsTheLastFrameForExportAndDirectPreviewSeek(_ name: String) async throws {
    let directory = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file(name)
    let probe = try await AVMediaProbe().probe(source)
    let total = Int64((probe.durationSeconds * 48000).rounded())
    let plan = EditPlan(sampleRate: 48000, totalSamples: total, kept: [MediaInterval(startSample: 0, endSample: total)])
    let request = RenderRequest(sourceURL: source, plan: plan, output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let output = directory.appendingPathComponent("tail.mp4")
    let result = try await AVExporter().export(ExportJob(render: request, outputURL: output)) { _ in }
    #expect(result.frames == Int64((probe.durationSeconds * 30).rounded()))
    #expect(result.audioSamples == total)
    let barcode = (0..<12).map { (24 + 24 * $0, 32) }
    let frames = try await sampledFrames(output, points: [(160, 90), (0, 90), (319, 90)] + barcode)
    let reference = try #require(frames.last { $0.time < 2 })
    let tail = frames.filter { $0.time >= 2 }
    try #require(!tail.isEmpty)
    for frame in tail {
        for (actual, expected) in zip(frame.pixels.prefix(3), reference.pixels.prefix(3)) {
            for (channel, referenceChannel) in zip(actual, expected) { #expect(abs(channel - referenceChannel) <= 3) }
        }
        let frameNumber = frame.pixels.dropFirst(3).reduce(0) { ($0 << 1) | ($1[0] >= 128 ? 1 : 0) }
        #expect(frameNumber == 59)
    }
    let preview = PreviewPlayerController()
    defer { preview.close() }
    try await preview.load(request)
    try await preview.seek(to: probe.durationSeconds - 0.01, exact: true)
    #expect(preview.player.currentItem?.status != .failed)
    #expect(preview.editedTime > 2)
}

@Test(.timeLimit(.minutes(1)), arguments: ["rate-44100.mov", "rate-32000.mov"])
func non48kAudioKeepsTheVideoFrameGridAndExactAudioDuration(_ name: String) async throws {
    let directory = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file(name)
    let probe = try await AVMediaProbe().probe(source)
    let rate = Double(try #require(probe.audio).sampleRate)
    let fps = name == "rate-44100.mov" ? 24.0 : 30
    let total = Int64((probe.durationSeconds * rate).rounded())
    let plan = EditPlan(sampleRate: rate, totalSamples: total, kept: [MediaInterval(startSample: 0, endSample: total)])
    let request = RenderRequest(sourceURL: source, plan: plan, output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: fps, videoBitrate: 2_000_000))
    let output = directory.appendingPathComponent("grid.mp4")
    let result = try await AVExporter().export(ExportJob(render: request, outputURL: output)) { _ in }
    let frames = try await sampledFrames(output, points: [])
    #expect(frames.count == Int((probe.durationSeconds * fps).rounded()))
    for (index, frame) in frames.enumerated() { #expect(abs(frame.time - Double(index) / fps) < 1e-9) }
    #expect(result.audioSamples == Int64((probe.durationSeconds * 48000).rounded()))
    let audio = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)[0]
    #expect(abs(try await audio.load(.timeRange).duration.seconds - probe.durationSeconds) < 1 / 48000)
    try await AVExporter().writeEditedAudio(request, to: directory.appendingPathComponent("unedited.wav"))
}

@Test(arguments: [1.01, 1.03]) func fractionalDurationsRoundFrameCounts(_ duration: Double) async throws {
    let directory = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await NativeMediaFixtures.shared.file()
    let total = Int64((duration * 48000).rounded())
    let plan = EditPlan(sampleRate: 48000, totalSamples: total, kept: [MediaInterval(startSample: 0, endSample: total)])
    let request = RenderRequest(sourceURL: source, plan: plan, output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let output = directory.appendingPathComponent("fractional.mp4")
    let result = try await AVExporter().export(ExportJob(render: request, outputURL: output)) { _ in }
    #expect(result.frames == Int64((duration * 30).rounded()))
    #expect(result.audioSamples == total)
    #expect(try await sampledFrames(output, points: []).count == Int((duration * 30).rounded()))
}
}
