@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Metal
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// The clip grade at the export seam and in stills (looks spec 2026-11-28, sections 11.2 and 11.3). The clip is synthetic:
/// shared/looks/test-card.png over a gradient that moves every frame, 2 s at 30 fps, never footage. It carries Warm Print at
/// 70% with the reference task's edits, a Fix, a vignette and grain; frames are read where the exporter reads them, before
/// the encoder.
@Suite(.serialized, .offlineFixtures) struct ClipGradeExportTests {
    static let output = OutputSpec(size: PixelSize(width: 360, height: 640), fps: 30, videoBitrate: 4_000_000)
    static let width = 360, height = 640
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .cacheIntermediates: false]
        return MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()

    static func request(_ source: URL, controls: ProjectClipControls?) -> RenderRequest {
        let plan = EditPlan(sampleRate: 48000, totalSamples: 96000, kept: [MediaInterval(startSample: 0, endSample: 96000)])
        var request = RenderRequest(sourceURL: source, plan: plan, output: output)
        request.clipControls = controls
        return request
    }

    static func library() throws -> ClipLookLibrary { try ClipLookLibrary.load(shared: SharedResources(root: FixtureLoader.sharedRoot())) }

    /// Warm Print at `amount` with the reference task's Highlights and Vibrance, a Fix, a vignette and its grain.
    static func warmPrint(amount: Int = 70, vignette: Int = 35, grain: Int? = nil) throws -> ProjectClipControls {
        var controls = ProjectClipControls(clipId: "clip-main")
        controls.applyLook(try #require(try library().look("warmPrint")), amount: amount, fix: ClipColorFix(exposure: 12, temperature: -10, tint: 6))
        controls.colorGrade?.highlights = -15
        controls.colorGrade?.vibrance = 20
        controls.colorGrade?.vignette = vignette
        if let grain { controls.colorGrade?.grain = grain }
        return controls
    }

    // MARK: The synthetic clip

    private static let clipTask = Task { try await makeClip() }
    static func clip() async throws -> URL { try await clipTask.value }

    private static func makeClip() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-grade-clip-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("test-card.mov")
        let cardURL = try FixtureLoader.sharedRoot().appendingPathComponent("looks/test-card.png")
        let card = try #require(CGImageSourceCreateWithURL(cardURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let (width, height) = (640, 360)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoColorPropertiesKey: MediaSupport.colorProperties,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoMaxKeyFrameIntervalKey: 30]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(1))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            // A gradient that slides 3 px a frame: red across, green down, blue against both.
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + 4 * x, shifted = (x + 3 * frame) % 256
                    base[offset] = UInt8(255 - (shifted + y / 2) % 256); base[offset + 1] = UInt8(y * 255 / (height - 1))
                    base[offset + 2] = UInt8(shifted); base[offset + 3] = 255
                }
            }
            let graphics = try #require(CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                space: CGColorSpace(name: CGColorSpace.itur_709)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            graphics.interpolationQuality = .none
            graphics.draw(card, in: CGRect(x: 192, y: 52, width: 256, height: 256))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    // MARK: Reading frames

    /// BGRA rows, tight, top row first.
    struct Frame: Equatable {
        let width: Int, height: Int
        let bytes: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> [Int] {
            let offset = 4 * (y * width + x)
            return [Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset])]
        }
    }

    static func frame(_ buffer: CVPixelBuffer) -> Frame {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: 4 * width * height)
        for row in 0..<height { for column in 0..<(4 * width) { bytes[4 * width * row + column] = base[stride * row + column] } }
        return Frame(width: width, height: height, bytes: bytes)
    }

    static func frame(_ image: CGImage) throws -> Frame {
        let data = try #require(image.dataProvider?.data as Data?)
        #expect(image.bytesPerRow == 4 * image.width && image.bitmapInfo.contains(.byteOrder32Little))
        return Frame(width: image.width, height: image.height, bytes: [UInt8](data))
    }

    /// The compositor's frames at `indices`, read as the exporter reads them, before the encoder.
    static func exportFrames(_ graph: RenderGraph, _ indices: [Int]) throws -> [Int: Frame] {
        let reader = try AVAssetReader(asset: graph.composition)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: graph.composition.tracks(withMediaType: .video),
                                                         videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = graph.videoComposition
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        defer { reader.cancelReading() }
        var frames: [Int: Frame] = [:]
        while frames.count < indices.count, let sample = output.copyNextSampleBuffer() {
            let index = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 30).rounded())
            if indices.contains(index), let buffer = CMSampleBufferGetImageBuffer(sample) { frames[index] = frame(buffer) }
        }
        return frames
    }

    /// `image` as float RGB, top row first.
    static func floats(_ image: CIImage) -> [Float] {
        var raw = [Float](repeating: 0, count: 4 * width * height)
        context.render(image, toBitmap: &raw, rowBytes: 16 * width, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: nil)
        return raw
    }

    // MARK: 11.2 The export seam

    /// Frames 0, 15 and 45 of the export are the reference chain on the same ungraded frame, `stillBeforeGrade`: P, L, A, T,
    /// the mix, then the vignette and grain at the frame's own pixels and frame index, within 1 everywhere.
    @Test(.timeLimit(.minutes(3))) func exportFramesAreTheReferenceChainOnTheUngradedFrame() async throws {
        let controls = try Self.warmPrint()
        let recipe = ClipGradeRecipe(controls: controls)
        #expect(recipe.primary != nil && recipe.tone?.master != nil && recipe.tone?.splitTone != nil && recipe.vignette > 0 && recipe.grain > 0)
        let graph = try await CompositionBuilder().build(Self.request(try await Self.clip(), controls: controls))
        let exported = try Self.exportFrames(graph, [0, 15, 45])
        #expect(exported.keys.sorted() == [0, 15, 45])
        var previous: Frame?
        for n in [0, 15, 45] {
            let still = try await ClipStillFrame.capture(graph, renderedSeconds: Double(n) / 30)
            #expect(still.renderedTime.seconds * 30 == Double(n))
            let ungraded = Self.floats(try still.stillBeforeGrade())
            let frame = try #require(exported[n])
            let hash = ClipGrain.frameHash(UInt32(n))
            var worst = 0, off = 0
            for y in 0..<Self.height {
                for x in 0..<Self.width {
                    let offset = 4 * (y * Self.width + x)
                    let o = [Double(ungraded[offset]), Double(ungraded[offset + 1]), Double(ungraded[offset + 2])]
                    let expected = recipe.finish(recipe.apply(o), x: x, y: y, width: Self.width, height: Self.height, frameHash: hash, hole: nil)
                        .map(ClipGradeRecipe.byte)
                    let difference = zip(frame.rgb(x, y), expected).map { abs($0 - $1) }.max() ?? 0
                    worst = max(worst, difference)
                    if difference > 1 { off += 1 }
                }
            }
            #expect(worst <= 1 && off == 0, "frame \(n): worst \(worst), \(off) pixels off by more than 1")
            if let previous { #expect(previous != frame) }
            previous = frame
        }
    }

    /// Through the exporter, the MP4 decodes within codec tolerance of the compositor's frame.
    @Test(.timeLimit(.minutes(3))) func theExportedFileDecodesToTheCompositorsFrame() async throws {
        let controls = try Self.warmPrint()
        let render = Self.request(try await Self.clip(), controls: controls)
        let graph = try await CompositionBuilder().build(render)
        let expected = try #require(try Self.exportFrames(graph, [15])[15])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-grade-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("graded.mp4")
        _ = try await AVExporter(appVersion: "0.1.0").export(ExportJob(render: render, outputURL: url)) { _ in }
        let file = AVURLAsset(url: url)
        let track = try #require(try await file.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: file)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        #expect(reader.startReading())
        var decoded: Frame?
        while decoded == nil, let sample = output.copyNextSampleBuffer() {
            if Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 30).rounded()) == 15, let buffer = CMSampleBufferGetImageBuffer(sample) {
                decoded = Self.frame(buffer)
            }
        }
        reader.cancelReading()
        let frame = try #require(decoded)
        var total = 0
        for index in frame.bytes.indices where index % 4 != 3 { total += abs(Int(frame.bytes[index]) - Int(expected.bytes[index])) }
        let mean = Double(total) / Double(3 * Self.width * Self.height)
        #expect(mean < 3, "mean difference \(mean)")
    }

    /// Through the CLI, a project's grade reaches the render: the clip exported with a Fix decodes, above the captions,
    /// within codec tolerance of the Fix applied to the same clip exported as filmed.
    @Test(.timeLimit(.minutes(3))) func theCLIExportsTheClipsGrade() async throws {
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Self.clip()
        var fixed = ProjectClipControls(clipId: "a")
        fixed.colorGrade = ClipColorGrade(exposure: 40, temperature: -20)
        var decoded: [Frame] = []
        for (name, controls) in [("plain", nil), ("fixed", fixed)] as [(String, ProjectClipControls?)] {
            let project = try await Self.project(source: source, in: directory, name: name, controls: controls)
            let video = directory.appendingPathComponent("\(name).mp4")
            let result = try runCLI(["--open", project.path, "--clip", "a", "--aspect", "9:16", "--export", video.path, "--json", "--quiet"],
                                    directory: directory, timeout: 90)
            try #require(result.status == 0, "CLI exit \(result.status): \(result.stderr)")
            decoded.append(try await Self.decodedFrame(video, index: 15))
        }
        let (plain, graded) = (decoded[0], decoded[1])
        let recipe = ClipGradeRecipe(controls: fixed)
        var total = 0.0, count = 0
        for y in 0..<(plain.height / 3) {
            for x in 0..<plain.width {
                let expected = recipe.apply(plain.rgb(x, y).map { Double($0) / 255 }).map(ClipGradeRecipe.byte)
                let found = graded.rgb(x, y)
                for channel in 0..<3 { total += Double(abs(found[channel] - expected[channel])) }
                count += 3
            }
        }
        #expect(total / Double(count) < 3, "mean difference \(total / Double(count))")
        #expect(plain != graded)
    }

    static func decodedFrame(_ url: URL, index: Int) async throws -> Frame {
        let file = AVURLAsset(url: url)
        let track = try #require(try await file.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: file)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            if Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 30).rounded()) == index, let buffer = CMSampleBufferGetImageBuffer(sample) {
                return frame(buffer)
            }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    /// A saved project of the synthetic clip with one clip "a" over its eight words.
    static func project(source: URL, in directory: URL, name: String, controls: ProjectClipControls?) async throws -> URL {
        let texts = ["The", "look", "is", "the", "grade", "that", "you", "chose"]
        let words = texts.enumerated().map { index, text in
            TimedWord(id: "w\(index)", text: text, start: 0.1 + Double(index) * 0.22, end: 0.28 + Double(index) * 0.22)
        }
        let transcript = Transcript(words: words, durationSeconds: 2, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
                                    rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
        let probe = try await AVMediaProbe().probe(source)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        var project = Project(id: UUID().uuidString.lowercased(), createdAt: Date(), modifiedAt: Date(), savedBy: ProjectWriter(version: "9.8.7"),
            media: ProjectMedia(source: MediaReference(absolutePath: source.path,
                sizeBytes: try #require((attributes[.size] as? NSNumber)?.int64Value), durationSeconds: probe.durationSeconds,
                contentKey: try JSONProjectStore.contentKey(for: source), video: probe.video, audio: probe.audio)),
            transcript: transcript, edits: ProjectEdits(clips: [ClipRange(id: "a", startWordId: "w0", endWordId: "w7", title: "A")], activeClipId: "a"))
        if let controls {
            project = try ContextDemoProject.upgradeToV4(project)
            project.clipControls = [controls]
        }
        let url = directory.appendingPathComponent("\(name).voxclip")
        try await JSONProjectStore(appVersion: "9.8.7").save(project, to: url)
        return url
    }

    /// Amount 0 with no Fix is as filmed: the export takes the source-only path; a Fix alone, or a look above 0, doesn't.
    @Test func amountZeroWithoutAFixKeepsTheSourceOnlyPath() throws {
        let source = URL(fileURLWithPath: "/tmp/voxclip-grade-gate.mov")
        var controls = try Self.warmPrint()
        #expect(!AVExporter.canUseSourceOnlyVideo(Self.request(source, controls: controls)))
        controls.colorGrade?.amount = 0
        #expect(!AVExporter.canUseSourceOnlyVideo(Self.request(source, controls: controls)), "the Fix applies at amount 0")
        controls.colorGrade?.fix = .neutral
        #expect(controls.colorGrade != nil && !controls.changesPicture)
        #expect(AVExporter.canUseSourceOnlyVideo(Self.request(source, controls: controls)))
        var vignette = ProjectClipControls(clipId: "clip-main")
        vignette.colorGrade = ClipColorGrade(vignette: 30)
        #expect(vignette.changesPicture && !AVExporter.canUseSourceOnlyVideo(Self.request(source, controls: vignette)))
    }

    // MARK: 11.3 Stills equal the export

    /// Hover: a still with other controls is the export's frame with those controls, byte for byte; Compare (no colour
    /// state) is the as-filmed export's frame.
    @Test(.timeLimit(.minutes(3))) func stillsWithOtherControlsAreTheExportsFrames() async throws {
        let source = try await Self.clip()
        let controls = try Self.warmPrint()
        let graded = try await CompositionBuilder().build(Self.request(source, controls: controls))
        let plain = try await CompositionBuilder().build(Self.request(source, controls: nil))
        let still = try await ClipStillFrame.capture(plain, renderedSeconds: 15.2 / 30)
        #expect(still.renderedTime == CMTime(value: 15, timescale: 30) && still.size == CGSize(width: Self.width, height: Self.height))
        let hover = try Self.frame(try await still.still(controls: controls))
        #expect(hover == (try #require(try Self.exportFrames(graded, [15])[15])))
        let gradedStill = try await ClipStillFrame.capture(graded, renderedSeconds: 0.5)
        let compare = try Self.frame(try await gradedStill.still(controls: nil))
        #expect(compare == (try #require(try Self.exportFrames(plain, [15])[15])))
        #expect(compare != hover)
        let past = try await ClipStillFrame.capture(plain, renderedSeconds: 9)
        #expect(past.renderedTime == CMTime(value: 59, timescale: 30), "a time past the end takes the last frame")
    }

    /// A look's tile is the export's frame for that look, cropped to the face-anchor square: the same pixels before the
    /// finish, within 1, with the grain left out.
    @Test(.timeLimit(.minutes(3))) func aTileIsTheExportsFrameCroppedToTheAnchorSquare() async throws {
        let source = try await Self.clip()
        let still = try await ClipStillFrame.capture(try await CompositionBuilder().build(Self.request(source, controls: nil)), renderedSeconds: 0.5)
        let look = try Self.warmPrint(amount: 100, vignette: 0)
        var pictureOnly = look
        pictureOnly.colorGrade?.grain = 0
        let tile = try Self.frame(try still.tile(controls: look, center: (x: 0.5, y: 0.3), pixels: Self.width))
        let export = try Self.frame(try await still.still(controls: pictureOnly))
        #expect(tile.width == Self.width && tile.height == Self.width)
        // The square of side 360 centred 30% down a 640-high frame starts at row 12.
        var worst = 0
        for y in 0..<Self.width {
            for x in 0..<Self.width {
                worst = max(worst, zip(tile.rgb(x, y), export.rgb(x, y + 12)).map { abs($0 - $1) }.max() ?? 0)
            }
        }
        #expect(worst <= 1, "worst \(worst)")
        let grainy = try Self.frame(try await still.still(controls: look))
        #expect(grainy != export, "the export has the look's grain; the tile leaves it out")
    }
}
