import AVFoundation
import CoreVideo
import Foundation
import QuartzCore
import Synchronization
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// The preview draws real frames (design.md §5.4.4 g): at the clip's speed, with cuts and with captions, read through the
/// player's own video output; a caption that can't be drawn leaves the picture and says why, while an export still fails.
@Suite(.serialized, .offlineFixtures) struct PreviewFramesTests {
    static func request(_ source: URL, speed: Double?, cuts: Bool) -> RenderRequest {
        let kept = cuts ? [MediaInterval(startSample: 0, endSample: 30_000), MediaInterval(startSample: 40_000, endSample: 70_000),
                           MediaInterval(startSample: 80_000, endSample: 96_000)]
                        : [MediaInterval(startSample: 0, endSample: 96_000)]
        let plan = EditPlan(sampleRate: 48000, totalSamples: 96000, kept: kept)
        var request = RenderRequest(sourceURL: source, plan: plan, output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 1_000_000))
        if let speed { request.clipControls = ProjectClipControls(clipId: "c", speed: speed) }
        return request
    }

    /// A caption layout over the whole edited take, in vox-bold at the output's size.
    static func captioned(_ request: RenderRequest) async throws -> RenderRequest {
        let shared = try CaptionMediaFixtures.shared()
        let pipeline = try CaptionPipeline(shared: shared)
        let words = [CaptionWord(id: "w1", text: "First", start: 0, end: 0.6), CaptionWord(id: "w2", text: "sale", start: 0.6, end: 1.2),
                     CaptionWord(id: "w3", text: "scammer", start: 1.2, end: 1.9)]
        let layout = try await pipeline.layout(words: words, language: "en", style: CaptionMediaFixtures.style("vox-bold", shared: shared),
            position: .init(x: 0.5, y: 0.8), frame: request.output.size, duration: request.timeline.duration)
        var result = request
        result.captionLayout = layout
        result.captions = layout.track
        return result
    }

    /// The mean of the frame's colour channels (0–255) at `seconds` of edited time, while playing; -1 with no frame.
    @MainActor static func meanLuma(_ controller: PreviewPlayerController, at seconds: Double) async throws -> Double {
        let item = try #require(controller.player.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        defer { item.remove(output) }
        for _ in 0..<100 where item.status != .readyToPlay && item.status != .failed { try await Task.sleep(for: .milliseconds(50)) }
        try await controller.seek(to: seconds, exact: true)
        controller.play()
        var buffer: CVPixelBuffer?
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(50))
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time), let copied = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                buffer = copied; break
            }
        }
        controller.pause()
        guard let buffer else { return -1 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let pixel = base + y * row + x * 4
                sum += Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])
            }
        }
        let samples = Double((height / 4) * (width / 4) * 3)
        return sum / samples
    }

    /// The controller's failure events, collected as they arrive.
    @MainActor final class Failures {
        private(set) var events: [(VoxClipError, PreviewFailureReason?)] = []
        private var task: Task<Void, Never>?
        init(_ controller: PreviewPlayerController) {
            task = Task { @MainActor [weak self] in
                for await event in controller.events {
                    if case .failed(let error, let reason) = event { self?.events.append((error, reason)) }
                }
            }
        }
        func stop() { task?.cancel() }
    }

    /// Forces the caption layout's draw to fail in every frame.
    static let failingDraw: CaptionLayoutDraw = { _, _, _, _, _ in throw CaptionFailure.invalid("Synthetic caption failure") }

    private actor FailingRasterizer: CaptionRasterizer {
        func rasterize(_ request: CaptionRasterRequest) async throws -> CaptionRaster {
            throw VoxClipError.decodeFailed("Synthetic caption raster failure")
        }
    }

    @MainActor @Test(.timeLimit(.minutes(2)), arguments: [(nil as Double?, false), (nil, true), (1.1, false), (1.1, true), (1.25, true)])
    func previewShowsFrames(speed: Double?, cuts: Bool) async throws {
        let source = try await NativeMediaFixtures.shared.file("bars-tone.mov")
        let controller = PreviewPlayerController()
        defer { controller.close() }
        try await controller.load(Self.request(source, speed: speed, cuts: cuts))
        let luma = try await Self.meanLuma(controller, at: 0.5)
        #expect(luma > 20, "speed=\(String(describing: speed)) cuts=\(cuts) luma=\(luma)")
    }

    @MainActor @Test(.timeLimit(.minutes(2)))
    func captionedPreviewAtClipSpeedShowsFrames() async throws {
        let source = try await NativeMediaFixtures.shared.file("bars-tone.mov")
        let controller = PreviewPlayerController()
        let failures = Failures(controller)
        defer { controller.close(); failures.stop() }
        let request = try await Self.captioned(Self.request(source, speed: 1.1, cuts: true))
        try await controller.load(request)
        for time in [0.3, 0.9, 1.5] {
            let luma = try await Self.meanLuma(controller, at: time)
            #expect(luma > 20, "t=\(time) luma=\(luma)")
        }
        #expect(failures.events.isEmpty)
    }

    @MainActor @Test(.timeLimit(.minutes(2)))
    func captionLayoutFailureInPreviewKeepsThePictureAndSaysWhy() async throws {
        let source = try await NativeMediaFixtures.shared.file("bars-tone.mov")
        let controller = PreviewPlayerController(builder: CompositionBuilder(captionDrawHook: Self.failingDraw))
        let failures = Failures(controller)
        defer { controller.close(); failures.stop() }
        try await controller.load(Self.captioned(Self.request(source, speed: 1.1, cuts: false)))
        let first = try await Self.meanLuma(controller, at: 0.4)
        let second = try await Self.meanLuma(controller, at: 1.2)
        #expect(first > 20 && second > 20, "luma \(first), \(second)")
        for _ in 0..<40 where failures.events.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        // Once per loaded item, however many frames failed.
        #expect(failures.events.count == 1)
        #expect(failures.events.first?.1 == .captionLayout)
    }

    @MainActor @Test(.timeLimit(.minutes(2)))
    func captionRasterFailureInPreviewKeepsThePictureAndSaysWhy() async throws {
        let source = try await NativeMediaFixtures.shared.file("bars-tone.mov")
        let shared = try FixtureLoader.sharedRoot(environment: [:])
        let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: shared.appendingPathComponent("caption-styles/styles/vox-highlight.json")))
        let page = CaptionPage(index: 0, words: [CaptionWord(id: "word", text: "test", start: 0, end: 2)], start: 0, end: 2,
            fontPx: 20, block: CaptionRect(x: 0, y: 0, width: 40, height: 20), visual: CaptionRect(x: 0, y: 0, width: 40, height: 20))
        var request = Self.request(source, speed: nil, cuts: false)
        request.captions = CaptionTrack(pages: [page]); request.style = style
        let controller = PreviewPlayerController(builder: CompositionBuilder(rasterizer: FailingRasterizer()))
        let failures = Failures(controller)
        defer { controller.close(); failures.stop() }
        try await controller.load(request)
        let luma = try await Self.meanLuma(controller, at: 0.6)
        #expect(luma > 20, "luma \(luma)")
        for _ in 0..<40 where failures.events.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(failures.events.count == 1)
        #expect(failures.events.first?.1 == .captionRaster)
    }

    @Test(.timeLimit(.minutes(2)))
    func captionLayoutFailureStillFailsTheExport() async throws {
        let source = try await NativeMediaFixtures.shared.file("bars-tone.mov")
        let request = try await Self.captioned(Self.request(source, speed: 1.1, cuts: false))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-preview-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = AVExporter(builder: CompositionBuilder(captionDrawHook: Self.failingDraw))
        await #expect(throws: (any Error).self) {
            try await exporter.export(ExportJob(render: request, outputURL: directory.appendingPathComponent("failed.mp4"))) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
