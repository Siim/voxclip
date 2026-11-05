import AVFoundation
import CoreImage
import ImageIO
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// Clip controls in the shared render path (design.md §6.8), measured on decoded output. The source is the synthetic
/// bars-tone fixture: 2 s of 320 × 180 video and a 441 Hz tone at 48 kHz.
@Suite(.serialized, .offlineFixtures) struct ClipControlsRenderTests {
    private static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-clip-controls-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func request(_ source: URL, controls: ProjectClipControls?) -> RenderRequest {
        let plan = EditPlan(sampleRate: 48000, totalSamples: 96000, kept: [MediaInterval(startSample: 0, endSample: 96000)])
        var request = RenderRequest(sourceURL: source, plan: plan, output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 1_000_000))
        request.clipControls = controls
        return request
    }

    /// The dominant frequency of the left channel over a window, scanned 1 Hz apart with Goertzel.
    static func dominantFrequency(_ interleaved: [Float], from: Int, count: Int, range: ClosedRange<Int> = 200...900) -> Int {
        var best = (frequency: 0, power: -1.0)
        for frequency in range {
            let coefficient = 2 * cos(2 * Double.pi * Double(frequency) / 48_000)
            var previous = 0.0, older = 0.0
            for index in from..<(from + count) {
                let value = Double(interleaved[2 * index]) + coefficient * previous - older
                older = previous; previous = value
            }
            let power = previous * previous + older * older - coefficient * previous * older
            if power > best.power { best = (frequency, power) }
        }
        return best.frequency
    }

    static func rms(_ interleaved: [Float], _ from: Double, _ to: Double) -> Double {
        let start = Int(from * 48_000), end = Int(to * 48_000)
        var sum = 0.0
        for frame in start..<end { sum += Double(interleaved[2 * frame]) * Double(interleaved[2 * frame]) }
        return (sum / Double(max(1, end - start))).squareRoot()
    }

    static func staged(_ graph: RenderGraph) throws -> [Float] {
        try MusicBedTests.readBed(try #require(graph.clipVoiceLease).url)
    }

    @Test(.timeLimit(.minutes(2))) func speedShortensTheExportAndKeepsTheVoicesPitch() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await NativeMediaFixtures.shared.file("bars-tone.mov")
        let plain = try await AVExporter().export(ExportJob(render: Self.request(source, controls: nil), outputURL: directory.appendingPathComponent("plain.mp4"))) { _ in }
        let fastURL = directory.appendingPathComponent("fast.mp4")
        let fast = try await AVExporter().export(ExportJob(render: Self.request(source, controls: ProjectClipControls(clipId: "c", speed: 1.25)),
                                                         outputURL: fastURL)) { _ in }
        #expect(abs(plain.durationSeconds - 2) < 0.001)
        // The source divided by 1.25: 1.6 s of video and 76,800 audio samples.
        #expect(abs(fast.durationSeconds - 1.6) < 0.001, "\(fast.durationSeconds)")
        #expect(fast.audioSamples == 76_800 && fast.frames == 48, "\(fast.audioSamples) \(fast.frames)")
        let asset = AVURLAsset(url: fastURL)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1.6) < 0.05, "\(duration)")
        let audio = try await MusicBedTests.decodedAudio(fastURL)
        try #require(audio.count / 2 >= 70_000)
        // The tone stays at 441 Hz; a plain resample would have raised it to 551 Hz.
        let frequency = Self.dominantFrequency(audio, from: 24_000, count: 24_000)
        #expect(abs(frequency - 441) <= 3, "\(frequency) Hz")
        let plainAudio = try await MusicBedTests.decodedAudio(directory.appendingPathComponent("plain.mp4"))
        #expect(abs(Self.dominantFrequency(plainAudio, from: 24_000, count: 24_000) - 441) <= 3)
        // And slowed down, too.
        let slow = try await CompositionBuilder().build(Self.request(source, controls: ProjectClipControls(clipId: "c", speed: 0.75)))
        let slowVoice = try Self.staged(slow)
        #expect(slowVoice.count == 2 * 128_000, "\(slowVoice.count)")
        #expect(abs(Self.dominantFrequency(slowVoice, from: 48_000, count: 24_000) - 441) <= 3)
        #expect(abs(slow.composition.duration.seconds - 8.0 / 3) < 0.01, "\(slow.composition.duration.seconds)")
    }

    @Test(.timeLimit(.minutes(1))) func volumeFadesAndMuteActOnTheSourceAudio() async throws {
        let source = try await NativeMediaFixtures.shared.file("bars-tone.mov")
        let tone = 0.4 / 2.0.squareRoot()
        let quieter = try Self.staged(try await CompositionBuilder().build(Self.request(source, controls: ProjectClipControls(clipId: "c", gainDb: -6))))
        #expect(quieter.count == 2 * 96_000)
        #expect(abs(20 * log10(Self.rms(quieter, 0.5, 1.5) / tone) + 6) < 0.3)
        let faded = try Self.staged(try await CompositionBuilder().build(Self.request(source,
            controls: ProjectClipControls(clipId: "c", fadeInSeconds: 0.5, fadeOutSeconds: 0.5))))
        #expect(Self.rms(faded, 0, 0.02) < tone * 0.05 && Self.rms(faded, 1.98, 2) < tone * 0.05)
        #expect(abs(Self.rms(faded, 0.2, 0.3) / tone - 0.5) < 0.06, "\(Self.rms(faded, 0.2, 0.3) / tone)")
        #expect(abs(Self.rms(faded, 0.8, 1.2) / tone - 1) < 0.02)
        let muted = try await CompositionBuilder().build(Self.request(source, controls: ProjectClipControls(clipId: "c", gainDb: 6, muteSource: true)))
        #expect(try Self.staged(muted).allSatisfy { $0 == 0 })
        #expect(muted.audioMix == nil && muted.mixedAudioTracks.count == 1)
    }

    /// Defaults and picture-only controls leave the audio graph exactly as before; the speed's graph is scaled.
    @Test func defaultsAreANoOpAndThePictureOnlyKeepsTheVoiceTrack() async throws {
        let source = try await NativeMediaFixtures.shared.file("bars-tone.mov")
        let plain = try await CompositionBuilder().build(Self.request(source, controls: nil))
        let looked = try await CompositionBuilder().build(Self.request(source, controls: ProjectClipControls(clipId: "c", look: .warm, flipHorizontal: true)))
        for graph in [plain, looked] {
            #expect(graph.clipVoiceLease == nil && graph.audioMix != nil)
            #expect(graph.composition.duration == CMTime(value: 96_000, timescale: 48_000))
            #expect(graph.videoComposition.instructions.last?.timeRange.end == CMTime(value: 96_000, timescale: 48_000))
        }
        #expect(plain.videoComposition.instructions.map(\.timeRange) == looked.videoComposition.instructions.map(\.timeRange))
        let fast = try await CompositionBuilder().build(Self.request(source, controls: ProjectClipControls(clipId: "c", speed: 2)))
        #expect(fast.videoComposition.instructions.last?.timeRange.end == CMTime(value: 48_000, timescale: 48_000))
        #expect(abs(fast.composition.tracks(withMediaType: .video)[0].timeRange.duration.seconds - 1) < 0.001)
        // Preview builds the same compositor path, so the look and speed render identically there.
        var preview = Self.request(source, controls: ProjectClipControls(clipId: "c", speed: 2, look: .bw)); preview.forPreview = true
        let previewGraph = try await CompositionBuilder().build(preview)
        #expect(previewGraph.videoComposition.customVideoCompositorClass == FrameCompositor.self)
        #expect((previewGraph.videoComposition.instructions.first as? RenderInstruction)?.request.clipControls?.look == .bw)
        #expect(previewGraph.videoComposition.instructions.map(\.timeRange) == fast.videoComposition.instructions.map(\.timeRange))
    }

    @Test func subtitlesPlayOnTheRenderedTimeline() throws {
        let words = [CaptionWord(id: "w1", text: "Hello", start: 1, end: 1.5), CaptionWord(id: "w2", text: "there", start: 1.5, end: 2)]
        let rectangle = CaptionRect(x: 0, y: 0, width: 100, height: 20)
        let page = CaptionPage(index: 0, words: words, start: 1, end: 2, fontPx: 20,
                               lines: [CaptionLine(words: [0, 1], units: 100, rect: rectangle, baseline: 10)], block: rectangle, visual: rectangle)
        let track = CaptionTrack(words: words, pages: [page])
        #expect(AVExporter.srt(track) == AVExporter.srt(track, speed: 1))
        #expect(AVExporter.srt(track).contains("00:00:01,000 --> 00:00:02,000"))
        #expect(AVExporter.srt(track, speed: 1.25).contains("00:00:00,800 --> 00:00:01,600"))
    }

    // MARK: Picture

    /// A 4 × 2 synthetic frame: mid-grey, a saturated red, a skin tone, near-black; then white, blue, green, light grey.
    static let swatches: [[Double]] = [[0.5, 0.5, 0.5], [0.9, 0.1, 0.1], [0.85, 0.62, 0.5], [0.05, 0.05, 0.05],
                                       [1, 1, 1], [0.1, 0.2, 0.9], [0.2, 0.7, 0.3], [0.8, 0.8, 0.8]]

    static func frame() -> CIImage {
        var image = CIImage.empty()
        for (index, color) in swatches.enumerated() {
            let x = CGFloat(index % 4), y = CGFloat(1 - index / 4)
            let patch = CIImage(color: CIColor(red: color[0], green: color[1], blue: color[2])).cropped(to: CGRect(x: x, y: y, width: 1, height: 1))
            image = patch.composited(over: image)
        }
        return image
    }

    /// RGB bytes of each swatch, read top-left first, through the compositor's unmanaged working space.
    static func pixels(_ image: CIImage) -> [[Int]] {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
        var bytes = [UInt8](repeating: 0, count: 4 * 8)
        context.render(image, toBitmap: &bytes, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 4, height: 2), format: .RGBA8, colorSpace: nil)
        var result: [[Int]] = []
        for index in 0..<8 {
            let base: Int = 4 * index
            let pixel: [Int] = [Int(bytes[base]), Int(bytes[base + 1]), Int(bytes[base + 2])]
            result.append(pixel)
        }
        return result
    }

    /// Pixel goldens for each look on the synthetic frame (±1 for GPU rounding). Generated once from ClipPicture and
    /// checked by hand: Muted drops saturation about a third and lifts black; Warm raises red and lowers blue a little;
    /// B&W is equal-channel with darker shadows and brighter highlights. Original is the frame untouched.
    static let goldens: [ClipLook: [[Int]]] = [
        .original: [[128, 128, 128], [229, 26, 26], [217, 158, 128], [13, 13, 13], [255, 255, 255], [26, 51, 229], [51, 178, 77], [204, 204, 204]],
        .muted: [[133, 133, 133], [177, 49, 49], [202, 165, 146], [22, 22, 22], [255, 255, 255], [46, 62, 173], [90, 170, 106], [206, 206, 206]],
        .warm: [[138, 131, 117], [246, 28, 25], [232, 162, 117], [16, 15, 14], [255, 255, 232], [30, 54, 209], [57, 183, 71], [219, 209, 186]],
        .bw: [[128, 128, 128], [62, 62, 62], [174, 174, 174], [9, 9, 9], [255, 255, 255], [51, 51, 51], [146, 146, 146], [211, 211, 211]],
    ]

    @Test func looksAreSubtleFixedColourTransforms() throws {
        let original = Self.pixels(Self.frame())
        #expect(Self.near(original, try #require(Self.goldens[.original])), "\(original)")
        #expect(ClipPicture.look(Self.frame(), .original).extent == Self.frame().extent)
        let muted = Self.pixels(ClipPicture.look(Self.frame(), .muted))
        let warm = Self.pixels(ClipPicture.look(Self.frame(), .warm))
        let mono = Self.pixels(ClipPicture.look(Self.frame(), .bw))
        Self.record(["muted": muted, "warm": warm, "bw": mono, "original": original])
        // Muted: the red patch's spread shrinks by about a third or more, and black is lifted.
        let spread = { (pixel: [Int]) -> Double in Double((pixel.max() ?? 0) - (pixel.min() ?? 0)) }
        let mutedSpread: Double = spread(muted[1]), originalSpread: Double = spread(original[1])
        #expect(mutedSpread < 0.72 * originalSpread && mutedSpread > 0.5 * originalSpread, "\(muted[1])")
        let lifted: Int = muted[3][0] - original[3][0]
        #expect(lifted > 5 && muted[4][0] >= 250, "\(muted[3]) \(muted[4])")
        // Warm: red up, blue down, by small amounts.
        let redUp: Int = warm[0][0] - original[0][0], blueDown: Int = original[0][2] - warm[0][2], greenMove: Int = warm[0][1] - original[0][1]
        #expect((4...12).contains(redUp) && (8...18).contains(blueDown), "\(warm[0])")
        #expect(abs(greenMove) <= 5)
        // B&W: grey everywhere; grey stays mid, shadows deepen, highlights brighten.
        #expect(mono.allSatisfy { abs($0[0] - $0[1]) <= 1 && abs($0[1] - $0[2]) <= 1 }, "\(mono)")
        #expect(abs(mono[0][0] - 128) <= 1 && mono[7][0] >= original[7][0] && mono[3][0] <= original[3][0], "\(mono[0]) \(mono[7])")
        // The compositor's frames are the Core recipe's numbers, within 8-bit rounding.
        for (look, pixels) in [(ClipLook.muted, muted), (.warm, warm), (.bw, mono)] {
            let expected = Self.swatches.map { ClipLookRecipe(look).apply($0).map { Int(($0 * 255).rounded()) } }
            #expect(Self.near(pixels, expected, tolerance: 2), "\(look): \(pixels) vs \(expected)")
            #expect(Self.near(pixels, try #require(Self.goldens[look])), "\(look): \(pixels)")
        }
        for (look, pixels) in [(ClipLook.muted, muted), (.warm, warm), (.bw, mono)] {
            // Subtle: no channel moves more than a quarter of the range from the original on the grey patch.
            #expect(abs(pixels[0][0] - original[0][0]) < 64, "\(look) \(pixels[0])")
        }
        // Deterministic: the same chain gives the same bytes again.
        #expect(Self.pixels(ClipPicture.look(Self.frame(), .bw)) == mono && Self.pixels(ClipPicture.look(Self.frame(), .muted)) == muted)
    }

    @Test func flipAndQuarterTurnsMoveTheTopLeftCornerAndSwapTheFrame() throws {
        let frame = Self.frame()
        func corner(_ flip: Bool, _ degrees: Int) -> (CGRect, [Int]) {
            let turned = ClipPicture.orient(frame, controls: ProjectClipControls(clipId: "c", flipHorizontal: flip, rotationDegrees: degrees))
            let context = CIContext(options: [.workingColorSpace: NSNull()])
            let width = Int(turned.extent.width), height = Int(turned.extent.height)
            var bytes = [UInt8](repeating: 0, count: 4 * width * height)
            context.render(turned, toBitmap: &bytes, rowBytes: 4 * width, bounds: turned.extent, format: .RGBA8, colorSpace: nil)
            return (turned.extent, [Int(bytes[0]), Int(bytes[1]), Int(bytes[2])])
        }
        // Bitmap rows start at the top: the grey patch is the top-left as filmed.
        #expect(corner(false, 0).1 == [128, 128, 128] && corner(false, 0).0 == CGRect(x: 0, y: 0, width: 4, height: 2))
        // Flipped, the near-black patch (top-right as filmed) comes to the top-left.
        #expect(corner(true, 0).1 == [13, 13, 13])
        // A clockwise quarter turn brings the bottom-left (white) to the top-left and swaps the frame.
        let quarter = corner(false, 90)
        #expect(quarter.0 == CGRect(x: 0, y: 0, width: 2, height: 4) && quarter.1 == [255, 255, 255], "\(quarter)")
        #expect(corner(false, 180).1 == [204, 204, 204] && corner(false, 270).1 == [13, 13, 13])
        #expect(ClipPicture.orient(frame, controls: nil).extent == frame.extent)
    }

    private static func near(_ lhs: [[Int]], _ rhs: [[Int]], tolerance: Int = 1) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in zip(pair.0, pair.1).allSatisfy { abs($0 - $1) <= tolerance } }
    }

    /// Writes the looks' swatches as PNGs when VOXCLIP_CLIP_CONTROLS_CAPTURES names a folder.
    private static func record(_ looks: [String: [[Int]]]) {
        guard let folder = ProcessInfo.processInfo.environment["VOXCLIP_CLIP_CONTROLS_CAPTURES"] else { return }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        for look in ClipLook.allCases {
            let image = ClipPicture.look(frame(), look).transformed(by: CGAffineTransform(scaleX: 60, y: 60))
            guard let cg = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: 240, height: 120), format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
                  let destination = CGImageDestinationCreateWithURL(url.appendingPathComponent("look-\(look.rawValue).png") as CFURL,
                                                                    "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, cg, nil)
            CGImageDestinationFinalize(destination)
        }
        if let data = try? JSONSerialization.data(withJSONObject: looks, options: [.sortedKeys]) {
            try? data.write(to: url.appendingPathComponent("look-pixels.json"))
        }
    }
}
