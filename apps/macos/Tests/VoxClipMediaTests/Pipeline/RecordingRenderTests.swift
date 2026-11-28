@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

extension HeavyMediaTests {
    @MainActor @Test func recordingsKeepTheirPictureAndVoiceThroughPreviewAndExport() async throws {
        let project = try await Self.recordingStoryProject()
        let render = try Self.recordingRender(project)
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = AVExporter(cleanupRegistry: directory.appendingPathComponent("Scratch"))
        let output = directory.appendingPathComponent("story.mp4")
        _ = try await exporter.export(.init(render: render, outputURL: output, loudness: .off)) { _ in }

        let rate: Int32 = 48_000
        let decodedFrames = Self.generator(AVURLAsset(url: output))

        let ranges = try CompositionVideoSpan.build(render)
        let routed = try [1, 0, 0, 1, 0].map { index in try #require(render.recordings.indices.contains(index) ? render.recordings[index] : nil) }
        #expect(ranges.map(\.recordingKey) == routed.map { Optional($0.key) })
        var sourcePCM: [String: [Float]] = [:]
        for recording in render.recordings {
            let count = Int64(recording.region.durationSamples)
            sourcePCM[recording.key] = try await Self.sourceAudio(recording.url, count: Int(count))
        }
        let decoded = try AVAudioFile(forReading: output, commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(decoded.processingFormat.sampleRate == Double(rate))
        for (index, pair) in zip(ranges, routed).enumerated() {
            let (span, recording) = pair
            let sampleStart = CMTimeConvertScale(span.output.start, timescale: rate, method: .roundHalfAwayFromZero).value + 24_000
            let localStart = CMTimeConvertScale(span.localSource.start, timescale: rate, method: .roundHalfAwayFromZero).value + 24_000
            let audioCount: Int64 = 9_600
            let sampleWindow = Int(localStart - 48)..<Int(localStart + audioCount + 48)
            let referencePCM = try #require(sourcePCM[recording.key])
            let wrongPCM = try #require(sourcePCM.first(where: { $0.key != recording.key })?.value)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: AVAudioFrameCount(audioCount)))
            decoded.framePosition = sampleStart
            try decoded.read(into: buffer)
            let channel = try #require(buffer.floatChannelData?[0])
            let actual = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let correctCorrelation = Self.correlation(actual, Array(referencePCM[sampleWindow]))
            let wrongCorrelation = Self.correlation(actual, Array(wrongPCM[sampleWindow]))
            #expect(correctCorrelation > 0.95, "part \(index + 1), reference correlation \(correctCorrelation)")
            #expect(wrongCorrelation < 0.35, "part \(index + 1), wrong-file correlation \(wrongCorrelation)")

            let referenceFrames = Self.generator(AVURLAsset(url: recording.url))
            referenceFrames.appliesPreferredTrackTransform = true
            let outputTime = CMTimeConvertScale(span.output.start, timescale: 30, method: .roundHalfAwayFromZero) + CMTime(value: 12, timescale: 30)
            let localTime = span.localSource.start + (outputTime - span.output.start)
            let expectedImage = try await referenceFrames.image(at: localTime).image
            let observedImage = try await decodedFrames.image(at: outputTime).image
            #expect(observedImage.width == 320 && observedImage.height == 180)
            let rotated = recording.region.label == "0010"
            #expect(expectedImage.width == (rotated ? 256 : 320) && expectedImage.height == (rotated ? 144 : 180))
            let expectedCounter = Self.counter(try Self.luma(expectedImage), rotated: rotated)
            let actualCounter = Self.counter(try Self.luma(observedImage), rotated: rotated)
            #expect(expectedCounter > 0 && abs(actualCounter - expectedCounter) <= 1, "part \(index + 1): expected counter \(expectedCounter), got \(actualCounter)")
        }

        let preview = PreviewPlayerController()
        defer { preview.close() }
        try await preview.load(render)
        let previewGraph = try #require((preview.player.currentItem as? LeasedPlayerItem)?.renderGraph)
        let exportGraph = try await CompositionBuilder().build(render)
        let previewFrames = Self.generator(previewGraph.composition, composition: previewGraph.videoComposition)
        let exportFrames = Self.generator(exportGraph.composition, composition: exportGraph.videoComposition)
        let previewPCM = try await Self.interleavedPCM(previewGraph, count: render.timeline.outputSamples)
        let staged = try await exporter.stageEditedAudio(render, to: directory.appendingPathComponent("voice.wav"))
        let exportPCM = try await Self.sourceAudio(staged, count: Int(render.timeline.outputSamples), stereo: true)
        for (left, right) in zip(ranges, ranges.dropFirst()) where left.recordingKey != right.recordingKey {
            let seam = CMTimeConvertScale(right.output.start, timescale: rate, method: .roundHalfAwayFromZero)
            let window = Int(seam.value - 480) * 2..<Int(seam.value + 480) * 2
            let previewHash = Array(previewPCM[window]).withUnsafeBytes { SHA256.hash(data: Data($0)) }
            let exportHash = Array(exportPCM[window]).withUnsafeBytes { SHA256.hash(data: Data($0)) }
            #expect(previewHash == exportHash)
            let after = CMTimeConvertScale(seam, timescale: 30, method: .roundTowardPositiveInfinity)
            for time in [after - CMTime(value: 1, timescale: 30), after] {
                let previewImage = try await previewFrames.image(at: time).image
                let exportImage = try await exportFrames.image(at: time).image
                let previewFrame = try #require(previewImage.dataProvider?.data as Data?)
                let exportFrame = try #require(exportImage.dataProvider?.data as Data?)
                #expect(SHA256.hash(data: previewFrame) == SHA256.hash(data: exportFrame))
            }
        }
    }

    /// "Don't match level" changes a recording's gain, not the timeline: the preview rebuilds its mix instead of
    /// keeping the old one under a caption-only update.
    @MainActor @Test func recordingGainChangeRebuildsThePreviewMix() async throws {
        var project = try await Self.recordingStoryProject()
        let render = try Self.recordingRender(project)
        let preview = PreviewPlayerController()
        defer { preview.close() }
        try await preview.load(render)
        let first = try #require(preview.player.currentItem)
        let gain = try #require(project.media.spokenSources?.first?.gainDb)
        project.media.spokenSources?[0].gainDb = gain - 6
        let quieter = try Self.recordingRender(project)
        #expect(quieter.timeline == render.timeline && quieter.recordings != render.recordings)
        try await preview.update(quieter)
        let item = try #require(preview.player.currentItem as? LeasedPlayerItem)
        #expect(item !== first)
        let count = quieter.timeline.outputSamples
        let previewPCM = try await Self.interleavedPCM(item.renderGraph, count: count)
        let exportPCM = try await Self.interleavedPCM(try await CompositionBuilder().build(quieter), count: count)
        let matches = previewPCM == exportPCM
        #expect(matches, "the preview plays the old gain")
    }

    @MainActor @Test func recordingSelfCheckFindsWrongPictureAndQuietSpeech() async throws {
        var project = try await Self.recordingStoryProject()
        project.edits.corrections["r2.w1"] = "Companion"
        let render = try Self.recordingRender(project)
        let clip = try #require(project.edits.clips.first)
        var state = try #require(try EditState(project: project))
        state.activeClipId = clip.id
        let edit = try ExportCheckExpectation.edit(render: render, state: state)
        #expect(edit.words.first?.text == "Companion")
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = AVExporter(cleanupRegistry: directory.appendingPathComponent("Scratch"))
        let checker = ExportChecker(hearing: nil, scratch: directory)

        func check(_ request: RenderRequest, name: String) async throws -> (ExportCheckReport, URL) {
            let output = directory.appendingPathComponent("\(name).mp4")
            _ = try await exporter.export(.init(render: request, outputURL: output, loudness: .off)) { _ in }
            return (try await checker.check(export: output, render: render, edit: edit, loudness: .off).report, output)
        }
        let (good, output) = try await check(render, name: "matched")
        #expect(good.passed, "warnings: \(good.results.filter { $0.status == .warning }.flatMap(\.items).map(\.kind.rawValue))")
        let seams = good.results.flatMap(\.items).compactMap(\.recordingSeam)
        #expect(seams.count == 3)
        let levels = try await RecordingExportCheck.measure(export: output, render: render, edit: edit)
        #expect(levels.count == 3)
        for level in levels { #expect(abs(try #require(level.levelDelta)) <= 0.5) }

        var wrong = render
        wrong.recordings[1] = .init(region: wrong.recordings[1].region, url: wrong.recordings[0].url)
        let (wrongFile, _) = try await check(wrong, name: "wrong")
        #expect(wrongFile.results.flatMap(\.items).contains { $0.kind == .pictureSource })

        let gain = try #require(project.media.spokenSources?.first?.gainDb)
        project.media.spokenSources?[0].gainDb = gain - 6
        let (quiet, _) = try await check(Self.recordingRender(project), name: "quiet")
        #expect(quiet.results.flatMap(\.items).contains { $0.kind == .recordingLevel && $0.reason?.contains("0010 is quieter than 0007") == true })
    }

    @Test(arguments: [false, true]) func missingRecordingStopsRenderWithItsLabel(_ replaced: Bool) async throws {
        var project = try await Self.recordingStoryProject()
        project.media.additionalSources[0].absolutePath = replaced ? project.media.source.absolutePath : "/nonexistent/0010.mp4"
        project.media.additionalSources[0].relativePath = nil
        #expect(throws: VoxClipError.recordingMissing("0010")) { try Self.recordingRender(project) }
        #expect(VoxClipError.recordingMissing("0010").localizedDescription == "0010 is missing. Locate it to use its words.")
    }

    private static func recordingRender(_ project: Project) throws -> RenderRequest {
        let plan = try RenderCallerInputs.editPlan(project: project, clipID: "story")
        let request = RenderRequest(sourceURL: URL(fileURLWithPath: project.media.source.absolutePath), plan: plan,
            output: .init(size: .init(width: 320, height: 180), fps: 30, videoBitrate: 550_000))
        return try RenderCallerInputs.prepare(request, project: project, clipID: "story", dataRoot: FileManager.default.temporaryDirectory)
    }

    @MainActor private static func generator(_ asset: AVAsset, composition: AVVideoComposition? = nil) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    @MainActor private static func interleavedPCM(_ graph: RenderGraph, count: Int64) async throws -> [Float] {
        let range = CMTimeRange(start: .zero, duration: CMTime(value: count, timescale: 48_000))
        var samples: [Float] = []
        try await AVExporter.readMix(graph: graph, timeRange: range, sampleLimit: count) { buffer in
            samples.append(contentsOf: buffer)
        }
        return samples
    }

    @MainActor private static func sourceAudio(_ url: URL, count: Int, stereo: Bool = false) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: stereo)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let rate = file.processingFormat.sampleRate / 48_000
        if stereo {
            try #require(rate == 1 && buffer.format.channelCount == 2)
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength) * 2))
        }
        if rate == 1 { return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))) }
        return (0..<count).map { frame in
            let position = Double(frame) * rate
            let lower = min(Int(position), Int(buffer.frameLength) - 1)
            let upper = min(lower + 1, Int(buffer.frameLength) - 1)
            let fraction = Float(position - Double(lower))
            return channel[lower] + (channel[upper] - channel[lower]) * fraction
        }
    }

    private static func correlation(_ actual: [Float], _ reference: [Float]) -> Double {
        guard !actual.isEmpty, reference.count >= actual.count else { return 0 }
        return (0...(reference.count - actual.count)).map { lag in
            var cross = 0.0, actualPower = 0.0, referencePower = 0.0
            for index in actual.indices {
                let lhs = Double(actual[index]), rhs = Double(reference[lag + index])
                cross += lhs * rhs; actualPower += lhs * lhs; referencePower += rhs * rhs
            }
            return cross / max(1e-12, sqrt(actualPower * referencePower))
        }.max() ?? 0
    }

    private static func luma(_ image: CGImage) throws -> [UInt8] {
        let width = 160, height = 90
        var bytes = [UInt8](repeating: 0, count: width * height)
        try bytes.withUnsafeMutableBytes { pixels in
            let context = try #require(CGContext(data: pixels.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    private static func counter(_ luma: [UInt8], rotated: Bool) -> Int {
        (0..<8).reduce(0) { value, bit in
            let sourceX = Double(37 + 9 * bit), sourceY = 61.5
            let column = Int(rotated ? (256 - sourceY) * 0.625 : sourceX * 0.5)
            let row = Int(rotated ? sourceX * 0.625 : sourceY * 0.5)
            return value | (luma[row * 160 + column] > 145 ? 1 << bit : 0)
        }
    }
}
