@preconcurrency import AVFoundation
import CoreImage
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import VoxClipCore
@testable import VoxClipMedia

/// Ask Claude's rendering (ai.md §18.5): pixel goldens on synthetic frames, a freeze through a real composition, bleep and
/// mute bounds in the mixed audio, the sound-effect mix and Vision tracking. Goldens live in shared/fixtures/media/effects;
/// `VOXCLIP_RECORD_EFFECT_GOLDENS=1` rewrites them, and every run writes its frames to /tmp/voxclip-ask-claude/.
@Suite(.serialized) struct EffectRenderTests {
    static var goldens: URL { ((try? SharedResources.locate().root) ?? URL(fileURLWithPath: "shared")).appendingPathComponent("fixtures/media/effects", isDirectory: true) }
    static let captures = URL(fileURLWithPath: "/tmp/voxclip-ask-claude", isDirectory: true)
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    static let size = CGSize(width: 640, height: 360)

    /// A synthetic picture: a colour gradient under a fine checkerboard, so a blur or pixelate is unmistakable.
    static func syntheticFrame(_ size: CGSize = size) -> CIImage {
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: size.width, y: size.height),
            "inputColor0": CIColor(red: 0.1, green: 0.3, blue: 0.8), "inputColor1": CIColor(red: 0.9, green: 0.5, blue: 0.2)])!.outputImage!
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.55), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.55),
            "inputWidth": 8, "inputCenter": CIVector(x: 0, y: 0), "inputSharpness": 1])!.outputImage!
        return checker.composited(over: gradient).cropped(to: CGRect(origin: .zero, size: size))
    }

    static func effect(_ kind: ClipEffect.Kind, rect: ClipEffect.Rect? = nil, text: String? = nil, position: ClipEffect.Position? = nil) -> ClipEffect {
        ClipEffect(id: "fx-\(kind.rawValue)-1", clipId: nil, kind: kind, start: 0, end: 4, rect: rect,
                   tracking: kind.isTracked ? ClipEffect.Tracking.none : nil, track: kind.isTracked ? [] : nil,
                   text: text, position: position, scale: kind == .sticker ? 1 : nil)
    }

    static func render(_ effects: [ClipEffect], output: CGSize = size, time: Double = 1) throws -> (rgba: [UInt8], width: Int, height: Int) {
        let frames = EffectFrames(input: ClipEffectsRenderInput(effects: effects, soundURLs: [:]))
        let source = syntheticFrame()
        let crop = FrameCompositor.centerCrop(source: source.extent, output: output)
        var image = CompositionFrameGeometry.fill(source, crop: crop, output: output)
        image = frames.picture(image, source: source.extent, crop: crop, output: output, time: time)
        image = frames.frame(image, output: output, time: time, outputTime: time, mapTime: { $0 })
        let width = Int(output.width), height = Int(output.height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &rgba, rowBytes: width * 4, bounds: CGRect(origin: .zero, size: output), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (rgba, width, height)
    }

    static func png(_ frame: (rgba: [UInt8], width: Int, height: Int)) throws -> Data {
        let provider = try #require(CGDataProvider(data: Data(frame.rgba) as CFData))
        let image = try #require(CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func pixels(_ url: URL) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let graphics = try #require(CGContext(data: &rgba, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        graphics.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return rgba
    }

    /// Compares with the stored golden: the mean channel difference stays under 1.5 and 99% of channels within 24, which
    /// absorbs GPU and text antialiasing differences but not a moved, missing or different effect.
    static func expectGolden(_ name: String, _ frame: (rgba: [UInt8], width: Int, height: Int)) throws {
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let data = try png(frame)
        try data.write(to: captures.appendingPathComponent("\(name).png"))
        let golden = goldens.appendingPathComponent("\(name).png")
        if ProcessInfo.processInfo.environment["VOXCLIP_RECORD_EFFECT_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: goldens, withIntermediateDirectories: true)
            try data.write(to: golden)
        }
        let expected = try pixels(golden), actual = try pixels(captures.appendingPathComponent("\(name).png"))
        try #require(expected.count == actual.count, "\(name) size")
        let differences = zip(expected, actual).map { abs(Int($0) - Int($1)) }
        let mean = Double(differences.reduce(0, +)) / Double(differences.count)
        let far = differences.filter { $0 > 24 }.count
        #expect(mean < 1.5 && Double(far) / Double(differences.count) < 0.01, "\(name): mean \(mean), far \(far)")
    }

    static func regionVariance(_ frame: (rgba: [UInt8], width: Int, height: Int), _ rect: CGRect, channel: Int = 1) -> Double {
        var values: [Double] = []
        for row in Int(rect.minY)..<Int(rect.maxY) { for column in Int(rect.minX)..<Int(rect.maxX) { values.append(Double(frame.rgba[(row * frame.width + column) * 4 + channel])) } }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
    }

    // MARK: Pixel goldens

    @Test func blurAndPixelateGoldensCoverOnlyTheirRegion() throws {
        let rect = ClipEffect.Rect(x: 0.5, y: 0.2, width: 0.3, height: 0.4)
        let plain = try Self.render([])
        let blurred = try Self.render([Self.effect(.blur, rect: rect)])
        let pixelated = try Self.render([Self.effect(.pixelate, rect: rect)])
        // Rows count from the top in the bitmap: the region is x 320–512, y 72–216.
        let inside = CGRect(x: 340, y: 90, width: 150, height: 100), outside = CGRect(x: 40, y: 90, width: 150, height: 100)
        #expect(Self.regionVariance(blurred, inside) < Self.regionVariance(plain, inside) * 0.2)
        #expect(Self.regionVariance(pixelated, inside) < Self.regionVariance(plain, inside) * 0.9)
        #expect(Self.regionVariance(blurred, outside) == Self.regionVariance(plain, outside))
        try Self.expectGolden("blur", blurred)
        try Self.expectGolden("pixelate", pixelated)
    }

    @Test func titleEmojiAndArrowGoldens() throws {
        try Self.expectGolden("title", try Self.render([Self.effect(.title, text: "Day 1", position: .top)], output: CGSize(width: 360, height: 640)))
        try Self.expectGolden("emoji", try Self.render([Self.effect(.sticker, text: "\u{1F525}", position: .topRight)]))
        try Self.expectGolden("arrow", try Self.render([Self.effect(.arrow, rect: .init(x: 0.62, y: 0.3, width: 0.12, height: 0.12))]))
        try Self.expectGolden("lower-third", try Self.render([Self.effect(.lowerThird, text: "Synthetic speaker", position: .bottomLeft)]))
        try Self.expectGolden("circle-progress", try Self.render([Self.effect(.circle, rect: .init(x: 0.2, y: 0.3, width: 0.2, height: 0.3)),
                                                                   Self.effect(.progress, position: .bottom)], time: 2))
    }

    @Test func overlaysAreOffOutsideTheirRangeAndNoEffectsIsANoOp() throws {
        let plain = try Self.render([])
        #expect(try Self.render([Self.effect(.title, text: "Day 1", position: .top)], time: 4.5).rgba == plain.rgba)
        #expect(try Self.render([Self.effect(.blur, rect: .init(x: 0, y: 0, width: 1, height: 1))], time: 5).rgba == plain.rgba)
    }

    @Test func pictureRectsFollowTheCropToAnotherShape() throws {
        // A 9:16 export crops the middle of the 16:9 picture; a blur on the right third of the picture is off-frame.
        let output = CGSize(width: 202, height: 360)
        let plain = try Self.render([], output: output)
        let right = try Self.render([Self.effect(.blur, rect: .init(x: 0.75, y: 0, width: 0.25, height: 1))], output: output)
        #expect(right.rgba == plain.rgba)
        let middle = try Self.render([Self.effect(.blur, rect: .init(x: 0.45, y: 0.4, width: 0.1, height: 0.2))], output: output)
        #expect(Self.regionVariance(middle, CGRect(x: 90, y: 160, width: 20, height: 40)) < Self.regionVariance(plain, CGRect(x: 90, y: 160, width: 20, height: 40)) * 0.3)
    }

    // MARK: Composition

    static func request(_ source: URL, effects: [ClipEffect], soundURLs: [String: URL] = [:]) -> RenderRequest {
        let plan = EditPlan(sampleRate: 48000, totalSamples: 96000, kept: [MediaInterval(startSample: 0, endSample: 96000)])
        var request = RenderRequest(sourceURL: source, plan: plan, output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 1_000_000))
        request.effects = effects.isEmpty ? nil : ClipEffectsRenderInput(effects: effects, soundURLs: soundURLs)
        return request
    }

    static func frame(_ graph: RenderGraph, at seconds: Double) async throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: graph.composition)
        generator.videoComposition = graph.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let graphics = try #require(CGContext(data: &rgba, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        graphics.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return rgba
    }

    @Test(.timeLimit(.minutes(2))) func freezeHoldsThePictureAndTheVoicePlaysOn() async throws {
        let source = try await NativeMediaFixtures.shared.file("counter.mov")
        let freeze = ClipEffect(id: "fx-freeze-1", clipId: nil, kind: .freeze, start: 0.5, end: 1.5)
        let plain = try await CompositionBuilder().build(Self.request(source, effects: []))
        let graph = try await CompositionBuilder().build(Self.request(source, effects: [freeze]))
        let held = try await Self.frame(graph, at: 0.6), later = try await Self.frame(graph, at: 1.4)
        #expect(held == later, "the picture holds")
        #expect(try await Self.frame(plain, at: 0.6) != (try await Self.frame(plain, at: 1.4)), "the counter moves without the freeze")
        #expect(try await Self.frame(graph, at: 1.7) == (try await Self.frame(plain, at: 1.7)), "the picture resumes at the freeze's end")
        #expect(graph.composition.duration == plain.composition.duration)
        let audio = try #require(graph.audioTrack), plainAudio = try #require(plain.audioTrack)
        #expect(audio.segments.count == plainAudio.segments.count, "the voice is untouched")
        try FileManager.default.createDirectory(at: Self.captures, withIntermediateDirectories: true)
        try Self.png((held, 320, 180)).write(to: Self.captures.appendingPathComponent("freeze.png"))
    }

    @Test(.timeLimit(.minutes(2))) func blurRendersThroughTheSharedComposition() async throws {
        let source = try await NativeMediaFixtures.shared.file()
        let blur = Self.effect(.blur, rect: .init(x: 0, y: 0, width: 0.5, height: 1))
        let graph = try await CompositionBuilder().build(Self.request(source, effects: [blur]))
        let plain = try await CompositionBuilder().build(Self.request(source, effects: []))
        let blurred = try await Self.frame(graph, at: 1), unblurred = try await Self.frame(plain, at: 1)
        try FileManager.default.createDirectory(at: Self.captures, withIntermediateDirectories: true)
        try Self.png((blurred, 320, 180)).write(to: Self.captures.appendingPathComponent("composition-blur.png"))
        // The colour bars' edges on the left half are smeared (read in red: the left bars all share their green); the right
        // half is unchanged.
        let left = CGRect(x: 30, y: 60, width: 100, height: 60), right = CGRect(x: 190, y: 60, width: 100, height: 60)
        #expect(Self.regionVariance((blurred, 320, 180), left, channel: 0) < Self.regionVariance((unblurred, 320, 180), left, channel: 0) * 0.7)
        #expect(abs(Self.regionVariance((blurred, 320, 180), right, channel: 0) - Self.regionVariance((unblurred, 320, 180), right, channel: 0)) < 1)
    }

    // MARK: Audio

    /// The mixed PCM a preview or export reads: every audio track through the graph's audio mix, 48 kHz, the left channel.
    static func mixed(_ graph: RenderGraph) async throws -> [Float] {
        let reader = try AVAssetReader(asset: graph.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: graph.mixedAudioTracks, audioSettings: MediaSupport.pcm(rate: 48_000, channels: 2))
        output.audioMix = graph.audioMix
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            samples += chunk
        }
        return stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
    }

    /// The amplitude of `frequency` in `samples[range]` (Goertzel), 1 for a full-scale sine.
    static func amplitude(_ samples: [Float], _ range: Range<Int>, _ frequency: Double) -> Double {
        let omega = 2 * Double.pi * frequency / 48_000
        var real = 0.0, imaginary = 0.0
        for index in range {
            let value = Double(samples[index])
            real += value * cos(omega * Double(index)); imaginary -= value * sin(omega * Double(index))
        }
        return 2 * hypot(real, imaginary) / Double(range.count)
    }

    static func rms(_ samples: [Float], _ range: Range<Int>) -> Double {
        (range.map { Double(samples[$0] * samples[$0]) }.reduce(0, +) / Double(range.count)).squareRoot()
    }

    @Test(.timeLimit(.minutes(2))) func bleepReplacesTheVoiceWithATonAtTheExactWordBounds() async throws {
        let source = try await NativeMediaFixtures.shared.file()
        let bleep = ClipEffect(id: "fx-bleep-1", clipId: nil, kind: .bleep, start: 0.5, end: 1.0, wordIds: ["w1"])
        let samples = try await Self.mixed(try await CompositionBuilder().build(Self.request(source, effects: [bleep])))
        try #require(samples.count >= 96_000)
        let ramp = Int(ClipEffect.bleepRampSeconds * 48_000)
        // Inside the words: the voice's 441 Hz tone is gone and the 1 kHz bleep plays at −12 dBFS.
        let inside = 24_000..<48_000
        #expect(Self.amplitude(samples, inside, 441) < 0.001, "\(Self.amplitude(samples, inside, 441))")
        #expect(abs(Self.amplitude(samples, inside, 1_000) - ClipEffect.bleepToneAmplitude) < 0.01)
        // Before the ramp and after it: the voice alone, no tone.
        let before = 4_800..<(24_000 - ramp), after = (48_000 + ramp)..<90_000
        #expect(Self.amplitude(samples, before, 1_000) < 0.001 && Self.amplitude(samples, after, 1_000) < 0.001)
        #expect(Self.amplitude(samples, before, 441) > 0.3 && Self.amplitude(samples, after, 441) > 0.3)
        // The first and last silenced samples are the words' own bounds.
        let voiceAt = { (index: Int) in EffectAudio.voiceGain(at: Double(index) / 48_000, ranges: [0.5...1.0]) }
        #expect(voiceAt(24_000) == 0 && voiceAt(48_000) == 0 && voiceAt(24_000 - ramp) == 1 && voiceAt(48_000 + ramp) == 1)
        #expect(abs(voiceAt(24_000 - ramp / 2) - 0.5) < 0.01)
    }

    /// The edited-audio export reads the voice alone (`withoutMusic`): the sound effect goes, the bleep's silence stays.
    @Test(.timeLimit(.minutes(2))) func theEditedAudioExportStaysCensored() async throws {
        let source = try await NativeMediaFixtures.shared.file()
        let shared = try SharedResources.locate()
        let bleep = ClipEffect(id: "fx-bleep-1", clipId: nil, kind: .bleep, start: 0.5, end: 1.0, wordIds: ["w1"])
        let pop = ClipEffect(id: "fx-sound-1", clipId: nil, kind: .sound, start: 1.2, end: 1.32, sound: .init(source: .bundled, id: "pop", durationSeconds: 0.12, title: "Pop", license: "cc0"), gainDb: 0)
        let request = Self.request(source, effects: [bleep, pop], soundURLs: ["fx-sound-1": ClipEffectsRenderInput.bundledSoundURL("pop", shared: shared)]).withoutMusic
        #expect(request.effects?.effects.map(\.kind) == [.bleep] && request.effects?.soundURLs.isEmpty == true)
        let graph = try await CompositionBuilder().build(request)
        let voice = try #require(graph.audioTrack)
        // The edited-audio export's own read: the voice track through the graph's audio mix.
        let reader = try AVAssetReader(asset: graph.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [voice], audioSettings: MediaSupport.pcm(rate: 48_000, channels: 2))
        output.audioMix = graph.audioMix
        reader.add(output)
        #expect(reader.startReading())
        var interleaved: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            interleaved += chunk
        }
        let samples = stride(from: 0, to: interleaved.count, by: 2).map { interleaved[$0] }
        try #require(samples.count >= 96_000)
        #expect(Self.amplitude(samples, 24_000..<48_000, 441) < 0.001, "the bleeped words stay silent")
        #expect(Self.amplitude(samples, 60_000..<90_000, 441) > 0.3, "the rest of the voice plays")
    }

    @Test(.timeLimit(.minutes(2))) func muteSilencesTheWordsWithNoTone() async throws {
        let source = try await NativeMediaFixtures.shared.file()
        let mute = ClipEffect(id: "fx-mute-1", clipId: nil, kind: .mute, start: 0.5, end: 1.0, wordIds: ["w1"])
        let graph = try await CompositionBuilder().build(Self.request(source, effects: [mute]))
        #expect(graph.effectsTrack == nil, "a mute adds no track")
        let samples = try await Self.mixed(graph)
        #expect(Self.rms(samples, 24_000..<48_000) < 0.0005)
        #expect(Self.rms(samples, 4_800..<23_000) > 0.2 && Self.rms(samples, 49_000..<90_000) > 0.2)
    }

    @Test(.timeLimit(.minutes(2))) func soundEffectMixesAtItsStartWithItsGainAndNoEffectsKeepsTheVoiceOnly() async throws {
        let source = try await NativeMediaFixtures.shared.file()
        let shared = try SharedResources.locate()
        let pop = ClipEffect(id: "fx-sound-1", clipId: nil, kind: .sound, start: 1.2, end: 1.32, sound: .init(source: .bundled, id: "pop", durationSeconds: 0.12, title: "Pop", license: "cc0"), gainDb: 0)
        let url = ClipEffectsRenderInput.bundledSoundURL("pop", shared: shared)
        let plain = try await CompositionBuilder().build(Self.request(source, effects: []))
        #expect(plain.effectsTrack == nil && plain.mixedAudioTracks.count == 1)
        let graph = try await CompositionBuilder().build(Self.request(source, effects: [pop], soundURLs: ["fx-sound-1": url]))
        #expect(graph.effectsTrack != nil && graph.mixedAudioTracks.count == 2)
        let voice = try await Self.mixed(plain), mixed = try await Self.mixed(graph)
        let difference = zip(voice, mixed).map { $1 - $0 }
        #expect(Self.rms(difference, 0..<57_000) < 1e-6 && Self.rms(difference, 64_000..<90_000) < 1e-6)
        let peak = difference[57_600..<63_400].map { abs($0) }.max() ?? 0
        #expect(abs(Double(peak) - pow(10, -6.0 / 20)) < 0.05, "peak \(peak), the sound's own −6 dBFS at 0 dB gain")
        var quieter = pop; quieter.gainDb = -12
        let soft = try await Self.mixed(try await CompositionBuilder().build(Self.request(source, effects: [quieter], soundURLs: ["fx-sound-1": url])))
        let softPeak = zip(voice, soft).map { abs($1 - $0) }[57_600..<63_400].max() ?? 0
        #expect(abs(20 * log10(Double(softPeak) / Double(peak)) + 12) < 0.5)
        var probe = Self.request(source, effects: [pop], soundURLs: ["fx-sound-1": url])
        probe = probe.withoutMusic
        #expect(probe.effects == nil, "edited-audio checks read the voice alone")
    }

    @Test func bundledSoundsAreTheGeneratorsLengths() async throws {
        let shared = try SharedResources.locate()
        for (id, seconds) in AskClaudeValidator.soundSeconds {
            let duration = try await MusicBedRenderer.durationSeconds(ClipEffectsRenderInput.bundledSoundURL(id, shared: shared))
            #expect(abs(duration - seconds) < 0.001, "\(id)")
        }
    }

    // MARK: Vision

    /// A 2 s 640×360 movie: a white square moving left to right over dark grey, with "INVOICE 1042" printed top right.
    static func movingSquare() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-effects-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil)
        let text = CTLineCreateWithAttributedString(NSAttributedString(string: "INVOICE 1042", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]))
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let graphics = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 640, height: 360, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            graphics.setFillColor(CGColor(gray: 0.15, alpha: 1)); graphics.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            graphics.setFillColor(CGColor(gray: 1, alpha: 1)); graphics.fill(CGRect(x: 40 + CGFloat(frame) * 5, y: 60, width: 90, height: 90))
            graphics.textPosition = CGPoint(x: 380, y: 300); CTLineDraw(text, graphics)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    @Test(.timeLimit(.minutes(2))) func visionFindsTheTextAndTracksTheMovingSubject() async throws {
        let movie = try await Self.movingSquare()
        defer { try? FileManager.default.removeItem(at: movie) }
        let detections = try await ClipEffectVision.detect(source: movie, start: 0, end: 2)
        let invoice = try #require(detections.first { $0.kind == .text && ($0.text ?? "").uppercased().contains("INVOICE") }, "\(detections)")
        #expect(invoice.label.hasPrefix("D") && invoice.rect.x > 0.5 && invoice.rect.y < 0.3, "\(invoice.rect)")
        // The square starts at x 40–130 of 640, y 210–300 of 360 from the top, and moves 150 px a second.
        let start = ClipEffect.Rect(x: 40.0 / 640, y: 210.0 / 360, width: 90.0 / 640, height: 90.0 / 360)
        var blur = ClipEffect(id: "fx-blur-1", clipId: nil, kind: .blur, start: 0, end: 1.5, rect: start, tracking: .saliency, track: [])
        let track = try await ClipEffectVision.track(source: movie, effect: blur)
        #expect(track.map(\.t) == ClipEffects.trackTimes(start: 0, end: 1.5))
        let centres = track.map(\.rect.midX)
        #expect(zip(centres, centres.dropFirst()).allSatisfy { $1 >= $0 - 0.01 }, "\(centres)")
        let expected = (40 + 1.5 * 150 + 45) / 640
        #expect(abs((centres.last ?? 0) - expected) < 0.08, "\(centres.last ?? 0) vs \(expected)")
        blur.track = track
        #expect(throws: Never.self) { try ClipEffects.validate(blur, projectId: "p") }
        blur.tracking = ClipEffect.Tracking.none
        #expect(try await ClipEffectVision.track(source: movie, effect: blur).isEmpty)
    }
}
