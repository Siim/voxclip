@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// Ask Claude's effects (ai.md §18.5) on a clip with clip controls (design.md §6.9), through the one render path preview
/// and export share. The source is the synthetic bars-tone fixture: 2 s of 320 × 180 bars and a 441 Hz tone at 48 kHz;
/// with nothing cut, source time is edited time, and a 1.25× clip renders it in 1.6 s.
@Suite(.serialized, .offlineFixtures) struct EffectClipControlsTests {
    static let rate = 48_000.0

    static func request(_ source: URL, effects: [ClipEffect] = [], soundURLs: [String: URL] = [:], controls: ProjectClipControls?) -> RenderRequest {
        var request = EffectRenderTests.request(source, effects: effects, soundURLs: soundURLs)
        request.clipControls = controls
        return request
    }

    static let bleep = ClipEffect(id: "fx-bleep-1", clipId: nil, kind: .bleep, start: 0.5, end: 1.0, wordIds: ["w1"])
    static let pop = ClipEffect(id: "fx-sound-1", clipId: nil, kind: .sound, start: 1.2, end: 1.32,
                                sound: .init(source: .bundled, id: "pop", durationSeconds: 0.12, title: "Pop", license: "cc0"), gainDb: 0)
    static let fast = ProjectClipControls(clipId: "c", speed: 1.25)

    /// The left channel of interleaved stereo.
    static func left(_ interleaved: [Float]) -> [Float] { stride(from: 0, to: interleaved.count, by: 2).map { interleaved[$0] } }

    /// Seconds where the 441 Hz voice is under a tenth of its level, scanned in 5 ms windows over `range`.
    static func silentSpan(_ samples: [Float], in range: ClosedRange<Double>, level: Double) -> ClosedRange<Double>? {
        let window = Int(0.005 * rate)
        var first: Double?, last: Double?
        var index = Int(range.lowerBound * rate)
        while index + window <= Int(range.upperBound * rate) {
            if EffectRenderTests.amplitude(samples, index..<(index + window), 441) < level * 0.1 {
                if first == nil { first = Double(index) / rate }
                last = Double(index + window) / rate
            }
            index += window
        }
        guard let first, let last else { return nil }
        return first...last
    }

    /// (a) and (b): at 1.25× the bleep's tone and the voice's silence sit on the bleeped word's rendered bounds (edited
    /// ÷ 1.25), the tone stays 1 kHz, and a sound effect starts at its rendered time.
    @Test(.timeLimit(.minutes(2))) func atASpeedTheBleepAndTheSoundSitOnTheRenderedClock() async throws {
        let source = try await NativeMediaFixtures.shared.file()
        let shared = try SharedResources.locate()
        let request = Self.request(source, effects: [Self.bleep, Self.pop],
                                   soundURLs: ["fx-sound-1": ClipEffectsRenderInput.bundledSoundURL("pop", shared: shared)], controls: Self.fast)
        let graph = try await CompositionBuilder().build(request)
        #expect(abs(graph.composition.duration.seconds - 1.6) < 0.001)
        // The tones and sounds track, as staged on the rendered timeline.
        let effects = Self.left(try MusicBedTests.readBed(try #require(graph.effectsLease).url))
        #expect(effects.count == 76_800, "\(effects.count)")
        let ramp = ClipEffect.bleepRampSeconds
        let toneFirst = try #require(effects.firstIndex { $0 != 0 })
        let toneLast = try #require(effects[..<Int(0.9 * Self.rate)].lastIndex { $0 != 0 })
        // The tone ramps in over the 10 ms before the word's rendered start (0.4 s) and out over the 10 ms after its end (0.8 s).
        #expect(abs(Double(toneFirst) / Self.rate - (0.4 - ramp)) <= 0.001, "tone from \(Double(toneFirst) / Self.rate) s")
        #expect(abs(Double(toneLast) / Self.rate - (0.8 + ramp)) <= 0.001, "tone to \(Double(toneLast) / Self.rate) s")
        let held = Int(0.41 * Self.rate)..<Int(0.79 * Self.rate)
        #expect(abs(EffectRenderTests.amplitude(effects, held, ClipEffect.bleepToneHz) - ClipEffect.bleepToneAmplitude) < 0.005)
        let interleaved = effects.flatMap { [$0, $0] }
        let tone = ClipControlsRenderTests.dominantFrequency(interleaved, from: held.lowerBound, count: held.count, range: 900...1100)
        #expect(tone == 1_000, "\(tone) Hz: the tone is placed, never resampled")
        // The pop starts at 1.2 / 1.25 = 0.96 s.
        let popFirst = try #require(effects[Int(0.85 * Self.rate)...].firstIndex { $0 != 0 })
        #expect(abs(Double(popFirst) / Self.rate - 0.96) <= 0.002, "pop at \(Double(popFirst) / Self.rate) s")
        // The staged voice is silent over the word's rendered bounds, within 10 ms.
        let voice = Self.left(try MusicBedTests.readBed(try #require(graph.clipVoiceLease).url))
        let level = EffectRenderTests.amplitude(voice, Int(1.1 * Self.rate)..<Int(1.5 * Self.rate), 441)
        #expect(level > 0.2, "\(level)")
        let silent = try #require(Self.silentSpan(voice, in: 0.2...1.2, level: level))
        #expect(abs(silent.lowerBound - 0.4) <= 0.010 && abs(silent.upperBound - 0.8) <= 0.010, "voice silent \(silent)")
        // And in the mix a preview or export reads: the tone, no voice, inside the word.
        let mixed = try await EffectRenderTests.mixed(graph)
        let inside = Int(0.42 * Self.rate)..<Int(0.78 * Self.rate)
        #expect(EffectRenderTests.amplitude(mixed, inside, 441) < 0.005, "\(EffectRenderTests.amplitude(mixed, inside, 441))")
        #expect(abs(EffectRenderTests.amplitude(mixed, inside, ClipEffect.bleepToneHz) - ClipEffect.bleepToneAmplitude) < 0.01)
    }

    /// (f) The edited-audio export (`withoutMusic`, the CLI's `--audio-out`) is the clip's voice at 1×: a 1.25× clip's
    /// still carries the bleep's silence, at the word's edited bounds.
    @Test(.timeLimit(.minutes(2))) func theEditedAudioOfAFasterClipStaysCensored() async throws {
        let source = try await NativeMediaFixtures.shared.file()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-effects-speed-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("edited.wav")
        try await AVExporter().writeEditedAudio(Self.request(source, effects: [Self.bleep], controls: Self.fast), to: destination)
        let samples = Self.left(try await MusicBedTests.decodedAudio(destination))
        #expect(abs(samples.count - 96_000) <= 1, "\(samples.count): edited audio stays 1×")
        #expect(EffectRenderTests.amplitude(samples, 24_000..<48_000, 441) < 0.001, "the bleeped word stays silent")
        #expect(EffectRenderTests.amplitude(samples, 60_000..<90_000, 441) > 0.3, "the rest of the voice plays")
        #expect(EffectRenderTests.amplitude(samples, 24_000..<48_000, ClipEffect.bleepToneHz) < 0.001, "no tone in the voice alone")
    }

    // MARK: Picture

    static func frame(_ request: RenderRequest, at seconds: Double) async throws -> [UInt8] {
        try await EffectRenderTests.frame(try await CompositionBuilder().build(request), at: seconds)
    }

    /// (c) A title shows over its edited-time window mapped to the rendered clock: 0.5–1.0 s edited is 0.4–0.8 s at 1.25×.
    @Test(.timeLimit(.minutes(2))) func aTitleShowsOverItsWindowOnTheRenderedClock() async throws {
        let source = try await NativeMediaFixtures.shared.file()
        let title = ClipEffect(id: "fx-title-1", clipId: nil, kind: .title, start: 0.5, end: 1.0, text: "Day 1", position: .top)
        let titled = Self.request(source, effects: [title], controls: Self.fast), plain = Self.request(source, controls: Self.fast)
        for (seconds, shown) in [(0.38, false), (0.46, true), (0.7, true), (0.82, false), (1.2, false)] {
            let differs = try await Self.frame(titled, at: seconds) != (try await Self.frame(plain, at: seconds))
            #expect(differs == shown, "\(seconds) s rendered (\(seconds * 1.25) s edited): title \(differs ? "shown" : "hidden")")
        }
        // At 1× the same rendered second, 0.82, is inside the window: the speed is what hides it there.
        let normal = Self.request(source, effects: [title], controls: nil)
        #expect(try await Self.frame(normal, at: 0.82) != (try await Self.frame(Self.request(source, controls: nil), at: 0.82)))
    }

    /// Pixels in VoxClip's accent yellow (pointers and the progress bar).
    static func accentPixels(_ rgba: [UInt8]) -> Int {
        stride(from: 0, to: rgba.count, by: 4).filter { rgba[$0] > 200 && rgba[$0 + 1] > 150 && rgba[$0 + 2] < 90 }.count
    }

    /// (d) With the B&W look, Ask Claude's overlays keep their colours: the look grades the picture before any effect
    /// draws, the pointers included, and the bars themselves turn grey.
    @Test(.timeLimit(.minutes(2))) func theBlackAndWhiteLookLeavesOverlaysInTheirColours() async throws {
        let source = try await NativeMediaFixtures.shared.file()
        let mono = ProjectClipControls(clipId: "c", look: .bw)
        let arrow = ClipEffect(id: "fx-arrow-1", clipId: nil, kind: .arrow, start: 0, end: 2, rect: .init(x: 0.6, y: 0.3, width: 0.15, height: 0.2))
        let progress = ClipEffect(id: "fx-progress-1", clipId: nil, kind: .progress, start: 0, end: 2, position: .bottom)
        let plain = try await Self.frame(Self.request(source, controls: mono), at: 1)
        #expect(Self.accentPixels(plain) == 0, "the graded bars have no colour left")
        #expect(Self.accentPixels(try await Self.frame(Self.request(source, controls: nil), at: 1)) > 0, "the bars as filmed include yellow")
        for effect in [arrow, progress] {
            let graded = try await Self.frame(Self.request(source, effects: [effect], controls: mono), at: 1)
            #expect(Self.accentPixels(graded) > 40, "\(effect.kind): \(Self.accentPixels(graded)) accent pixels under B&W")
        }
    }

    /// (e) Flipped, a blur stays on the content it covers: the flipped render with the blur is the mirror of the plain
    /// render with the blur.
    @Test(.timeLimit(.minutes(2))) func aBlurFollowsTheFlippedPicture() async throws {
        let source = try await NativeMediaFixtures.shared.file()
        let blur = EffectRenderTests.effect(.blur, rect: .init(x: 0.05, y: 0.1, width: 0.3, height: 0.8))
        let upright = try await Self.frame(Self.request(source, effects: [blur], controls: nil), at: 1)
        let flipped = try await Self.frame(Self.request(source, effects: [blur], controls: ProjectClipControls(clipId: "c", flipHorizontal: true)), at: 1)
        let width = 320, height = 180
        var mirrored = [UInt8](repeating: 0, count: upright.count)
        for row in 0..<height {
            for column in 0..<width {
                for channel in 0..<4 { mirrored[(row * width + column) * 4 + channel] = upright[(row * width + width - 1 - column) * 4 + channel] }
            }
        }
        let difference = Double(zip(mirrored, flipped).map { abs(Int($0) - Int($1)) }.reduce(0, +)) / Double(flipped.count)
        #expect(difference < 1.5, "mean difference \(difference) from the mirrored upright render")
        try FileManager.default.createDirectory(at: EffectRenderTests.captures, withIntermediateDirectories: true)
        try EffectRenderTests.png((flipped, width, height)).write(to: EffectRenderTests.captures.appendingPathComponent("blur-flipped.png"))
    }

    /// (e) Turned a quarter, and flipped and turned, a blur's region turns with the picture: censoring the oriented frame
    /// gives the same pixels as orienting the censored frame.
    @Test func aBlurTurnsWithTheQuarterTurnedPicture() throws {
        let blur = EffectRenderTests.effect(.blur, rect: .init(x: 0.1, y: 0.15, width: 0.25, height: 0.4))
        let frames = EffectFrames(input: ClipEffectsRenderInput(effects: [blur], soundURLs: [:]))
        let source = EffectRenderTests.syntheticFrame()
        func censored(_ image: CIImage, controls: ProjectClipControls?) -> CIImage {
            let output = image.extent.size
            let crop = FrameCompositor.centerCrop(source: image.extent, output: output)
            let filled = CompositionFrameGeometry.fill(image, crop: crop, output: output)
            return frames.picture(filled, source: image.extent, crop: crop, output: output, time: 1, controls: controls)
        }
        func bytes(_ image: CIImage) -> [UInt8] {
            let width = Int(image.extent.width), height = Int(image.extent.height)
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            EffectRenderTests.context.render(image, toBitmap: &rgba, rowBytes: width * 4, bounds: image.extent, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return rgba
        }
        let upright = censored(source, controls: nil)
        for controls in [ProjectClipControls(clipId: "c", rotationDegrees: 90), ProjectClipControls(clipId: "c", rotationDegrees: 270),
                         ProjectClipControls(clipId: "c", flipHorizontal: true, rotationDegrees: 90)] {
            let turnedFirst = censored(ClipPicture.orient(source, controls: controls), controls: controls)
            let censoredFirst = ClipPicture.orient(upright, controls: controls)
            #expect(turnedFirst.extent == censoredFirst.extent)
            let lhs = bytes(turnedFirst), rhs = bytes(censoredFirst)
            let difference = Double(zip(lhs, rhs).map { abs(Int($0) - Int($1)) }.reduce(0, +)) / Double(lhs.count)
            #expect(difference < 1, "\(controls.rotationDegrees)° flip \(controls.flipHorizontal): mean difference \(difference)")
        }
        // The region itself: a quarter turn clockwise brings the filmed top-left region to the top-right.
        let turned = ProjectClipControls(clipId: "c", rotationDegrees: 90).mapRect(.init(x: 0.1, y: 0.15, width: 0.25, height: 0.4))
        #expect(abs(turned.x - 0.45) < 1e-9 && abs(turned.y - 0.1) < 1e-9 && abs(turned.width - 0.4) < 1e-9 && abs(turned.height - 0.25) < 1e-9)
    }
}
