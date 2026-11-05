@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// Replays shared/fixtures/clip-render/clip-render-cases.json (tools/fixtures/clip-render/generate_clip_render.py) on the
/// Mac, every category: the look goldens and the recipe's 8-bit arithmetic, orient corners, `mapRect` boxes, clip frames
/// and bitrates, rendered lengths, the 1.25× bleep, silence, pop and title bounds, SRT cues and × masking. Windows replays
/// the same file (ClipRenderVectorTests); a case that fails here is wrong in the generator, not in the renderer.
@Suite(.serialized, .offlineFixtures) struct ClipRenderVectorReplayTests {
    static func cases() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/clip-render/clip-render-cases.json"))
    }
    static func doubles(_ value: JSONValue) -> [Double] { value.aiArray.compactMap(\.aiDouble) }
    static func ints(_ value: JSONValue) -> [Int] { value.aiArray.compactMap(\.aiInt) }
    static func look(_ name: String) -> ClipLook? { ClipLook.allCases.first { $0.rawValue == name } }
    static func rect(_ value: JSONValue) -> ClipEffect.Rect {
        ClipEffect.Rect(x: value[ai: "x"].aiDouble ?? .nan, y: value[ai: "y"].aiDouble ?? .nan,
                        width: value[ai: "width"].aiDouble ?? .nan, height: value[ai: "height"].aiDouble ?? .nan)
    }
    static func controls(flip: Bool = false, rotation: Int = 0, shape: ClipShape? = nil, speed: Double = 1) -> ProjectClipControls {
        ProjectClipControls(clipId: "c", speed: speed, shape: shape, flipHorizontal: flip, rotationDegrees: rotation)
    }

    /// The 4 × 2 frame from the file's swatches, read top-left first.
    static func frame(_ swatches: [[Double]]) -> CIImage {
        var image = CIImage.empty()
        for (index, color) in swatches.enumerated() {
            let x = CGFloat(index % 4), y = CGFloat(1 - index / 4)
            let patch = CIImage(color: CIColor(red: color[0], green: color[1], blue: color[2])).cropped(to: CGRect(x: x, y: y, width: 1, height: 1))
            image = patch.composited(over: image)
        }
        return image
    }

    /// RGB bytes of `image`, top-left first, through the compositor's unmanaged working space.
    static func bytes(_ image: CIImage) -> (size: [Int], pixels: [[Int]]) {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var raw = [UInt8](repeating: 0, count: 4 * width * height)
        CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
            .render(image, toBitmap: &raw, rowBytes: 4 * width, bounds: image.extent, format: .RGBA8, colorSpace: nil)
        let pixels: [[Int]] = (0..<(width * height)).map { index in
            let base: Int = 4 * index
            return [Int(raw[base]), Int(raw[base + 1]), Int(raw[base + 2])]
        }
        return ([width, height], pixels)
    }

    @Test func theFileHasItsOwnSchemaAndEveryCategory() throws {
        let cases = try Self.cases()
        #expect(cases[ai: "schema"].aiString == "voxclip-clip-render-cases/1")
        let keys = Set((cases.aiObject ?? [:]).keys)
        #expect(keys == ["schema", "description", "looks", "orient", "mapRect", "frames", "bitrates", "speed", "effectsAtSpeed", "srt", "mask"])
        #expect(cases[ai: "orient"].aiArray.count == 5 && cases[ai: "mapRect"].aiArray.count == 16 && cases[ai: "frames"].aiArray.count == 6)
        #expect(cases[ai: "bitrates"].aiArray.count == 4 && cases[ai: "speed"].aiArray.count == 4 && cases[ai: "srt"].aiArray.count == 2)
        #expect(cases[ai: "mask"].aiArray.count == 5)
    }

    /// The Mac's Core Image goldens for each look, and the recipe's arithmetic on the 8-bit swatches.
    @Test func looksMatchTheGoldensAndTheRecipeArithmetic() throws {
        let looks = try Self.cases()[ai: "looks"]
        let swatches = looks[ai: "swatches"].aiArray.map(Self.doubles)
        let tolerance = try #require(looks[ai: "tolerance"].aiInt), recipeTolerance = try #require(looks[ai: "recipeTolerance"].aiInt)
        let frame = Self.frame(swatches)
        let goldens = try #require(looks[ai: "macGoldens"].aiObject)
        #expect(Set(goldens.keys) == Set(ClipLook.allCases.map(\.rawValue)))
        for (name, golden) in goldens {
            let look = try #require(Self.look(name), "\(name)")
            let rendered = Self.bytes(look == .original ? frame : ClipPicture.look(frame, look)).pixels
            let expected = golden.aiArray.map(Self.ints)
            for (index, pixel) in rendered.enumerated() {
                #expect(zip(pixel, expected[index]).allSatisfy { abs($0 - $1) <= tolerance }, "\(name)[\(index)]: \(pixel) vs golden \(expected[index])")
            }
        }
        let recipes = try #require(looks[ai: "recipe"].aiObject)
        #expect(Set(recipes.keys) == ["muted", "warm", "bw"])
        for (name, recipe) in recipes {
            let look = try #require(Self.look(name), "\(name)")
            let expected = recipe.aiArray.map(Self.ints)
            let rendered = Self.bytes(ClipPicture.look(frame, look)).pixels
            for (index, swatch) in swatches.enumerated() {
                // From the 8-bit swatch, as a decoded frame stores it; the recipe's bytes exactly.
                let stored: [Double] = swatch.map { (($0 * 255 + 0.5).rounded(.down)) / 255 }
                let arithmetic: [Int] = ClipLookRecipe(look).apply(stored).map { Int(($0 * 255 + 0.5).rounded(.down)) }
                #expect(arithmetic == expected[index], "\(name)[\(index)] recipe: \(arithmetic) vs \(expected[index])")
                #expect(zip(rendered[index], expected[index]).allSatisfy { abs($0 - $1) <= recipeTolerance },
                        "\(name)[\(index)] Core Image \(rendered[index]) vs recipe \(expected[index])")
            }
        }
    }

    /// Flips and quarter turns move the top-left corner and swap the frame.
    @Test func orientCornersAndFrames() throws {
        let cases = try Self.cases()
        let frame = Self.frame(cases[ai: "looks"][ai: "swatches"].aiArray.map(Self.doubles))
        for item in cases[ai: "orient"].aiArray {
            let flip = item[ai: "flip"] == .bool(true), rotation = item[ai: "rotation"].aiInt ?? -1
            let turned = Self.bytes(ClipPicture.orient(frame, controls: Self.controls(flip: flip, rotation: rotation)))
            #expect(turned.size == Self.ints(item[ai: "size"]), "flip \(flip) \(rotation)°: size \(turned.size)")
            #expect(turned.pixels.first == Self.ints(item[ai: "topLeft"]), "flip \(flip) \(rotation)°: corner \(turned.pixels.first ?? [])")
        }
    }

    /// Effect boxes, stored as filmed, map through the flip and quarter turns.
    @Test func mapRectBoxes() throws {
        for item in try Self.cases()[ai: "mapRect"].aiArray {
            let flip = item[ai: "flip"] == .bool(true), rotation = item[ai: "rotation"].aiInt ?? -1
            let mapped = Self.controls(flip: flip, rotation: rotation).mapRect(Self.rect(item[ai: "rect"]))
            let expected = Self.rect(item[ai: "expected"])
            let close = [(mapped.x, expected.x), (mapped.y, expected.y), (mapped.width, expected.width), (mapped.height, expected.height)]
                .allSatisfy { abs($0 - $1) < 1e-9 }
            #expect(close, "flip \(flip) \(rotation)°: \(mapped) vs \(expected)")
        }
    }

    /// A clip's frame is its shape, else the project frame turned with a quarter turn; bitrates follow the shape.
    @Test func clipFramesAndBitrates() throws {
        let cases = try Self.cases()
        for item in cases[ai: "frames"].aiArray {
            let source = Self.ints(item[ai: "source"]), size = Self.ints(item[ai: "size"])
            let aspect = try #require(item[ai: "aspect"].aiString.flatMap(AspectRatio.init(rawValue:)))
            let shape = item[ai: "shape"].aiString.flatMap(ClipShape.init(rawValue:))
            let controls = Self.controls(rotation: item[ai: "rotation"].aiInt ?? -1, shape: shape)
            let output = try OutputSizing.outputSize(source: PixelSize(width: source[0], height: source[1]), aspect: aspect, controls: controls)
            #expect([output.width, output.height] == size, "\(source) \(aspect.rawValue) \(shape?.rawValue ?? "-") \(controls.rotationDegrees)°: \(output)")
        }
        for item in cases[ai: "bitrates"].aiArray {
            let shape = try #require(item[ai: "shape"].aiString.flatMap(ClipShape.init(rawValue:)))
            let quality = try #require(item[ai: "quality"].aiString.flatMap(ExportQuality.init(rawValue:)))
            let fps = try #require(item[ai: "fps"].aiDouble)
            let bitrate = OutputSizing.videoBitrate(size: shape.size, aspect: .landscape, quality: quality, fps: fps, controls: Self.controls(shape: shape))
            #expect(bitrate == item[ai: "bitrate"].aiInt, "\(shape.rawValue) \(quality.rawValue) \(fps): \(bitrate)")
        }
    }

    /// Rendered lengths: the edited samples divided by the speed, and the frames at the rate.
    @Test func renderedLengths() throws {
        for item in try Self.cases()[ai: "speed"].aiArray {
            let speed = try #require(item[ai: "speed"].aiDouble), rate = try #require(item[ai: "rate"].aiDouble), fps = try #require(item[ai: "fps"].aiDouble)
            let edited = Int64(try #require(item[ai: "editedSamples"].aiInt))
            let rendered = ClipSpeedTiming(speed: speed).renderedSamples(edited)
            #expect(rendered == Int64(try #require(item[ai: "renderedSamples"].aiInt)), "\(speed)×: \(rendered)")
            let seconds: Double = Double(rendered) / rate
            let frames = Int((seconds * fps).rounded(.toNearestOrAwayFromZero))
            #expect(frames == item[ai: "frames"].aiInt, "\(speed)×: \(frames) frames")
        }
    }

    /// The 1.25× bleep's tone, the voice's silence and the pop on the rendered clock; the title's bounds; the edited audio.
    @Test(.timeLimit(.minutes(3))) func effectsAtSpeedSitOnTheRenderedClock() async throws {
        let vector = try Self.cases()[ai: "effectsAtSpeed"]
        let speed = try #require(vector[ai: "speed"].aiDouble), rate = try #require(vector[ai: "rate"].aiDouble)
        #expect(rate == EffectClipControlsTests.rate)
        let source = try await NativeMediaFixtures.shared.file()
        let shared = try SharedResources.locate()
        let fast = Self.controls(speed: speed)
        let bleep = ClipEffect(id: "fx-bleep-1", clipId: nil, kind: .bleep, start: try #require(vector[ai: "bleep"][ai: "start"].aiDouble),
                               end: try #require(vector[ai: "bleep"][ai: "end"].aiDouble), wordIds: ["w1"])
        let popStart = try #require(vector[ai: "pop"][ai: "start"].aiDouble), popLength = try #require(vector[ai: "pop"][ai: "durationSeconds"].aiDouble)
        let pop = ClipEffect(id: "fx-sound-1", clipId: nil, kind: .sound, start: popStart, end: popStart + popLength,
                             sound: .init(source: .bundled, id: "pop", durationSeconds: popLength, title: "Pop", license: "cc0"), gainDb: 0)
        #expect(vector[ai: "rampSeconds"].aiDouble == ClipEffect.bleepRampSeconds && vector[ai: "toneHz"].aiDouble == ClipEffect.bleepToneHz)
        #expect(vector[ai: "toneAmplitude"].aiDouble == ClipEffect.bleepToneAmplitude)
        let request = EffectClipControlsTests.request(source, effects: [bleep, pop],
            soundURLs: ["fx-sound-1": ClipEffectsRenderInput.bundledSoundURL("pop", shared: shared)], controls: fast)
        let graph = try await CompositionBuilder().build(request)
        let sourceSeconds = try #require(vector[ai: "sourceSeconds"].aiDouble)
        #expect(abs(graph.composition.duration.seconds - sourceSeconds / speed) < 0.001)
        // Tones and sounds, staged on the rendered timeline.
        let effects = EffectClipControlsTests.left(try MusicBedTests.readBed(try #require(graph.effectsLease).url))
        #expect(effects.count == vector[ai: "renderedSamples"].aiInt, "\(effects.count) samples")
        let toneFirst = try #require(effects.firstIndex { $0 != 0 })
        let toneLast = try #require(effects[..<Int(0.9 * rate)].lastIndex { $0 != 0 })
        let toneTolerance = try #require(vector[ai: "toneTolerance"].aiDouble)
        #expect(abs(Double(toneFirst) / rate - (vector[ai: "toneFirst"].aiDouble ?? .nan)) <= toneTolerance, "tone from \(Double(toneFirst) / rate) s")
        #expect(abs(Double(toneLast) / rate - (vector[ai: "toneLast"].aiDouble ?? .nan)) <= toneTolerance, "tone to \(Double(toneLast) / rate) s")
        let popFirst = try #require(effects[Int(0.85 * rate)...].firstIndex { $0 != 0 })
        #expect(abs(Double(popFirst) / rate - (vector[ai: "popFirst"].aiDouble ?? .nan)) <= (vector[ai: "popTolerance"].aiDouble ?? 0),
                "pop at \(Double(popFirst) / rate) s")
        // The staged voice is silent over the bleeped word's rendered bounds.
        let voice = EffectClipControlsTests.left(try MusicBedTests.readBed(try #require(graph.clipVoiceLease).url))
        let level = EffectRenderTests.amplitude(voice, Int(1.1 * rate)..<Int(1.5 * rate), 441)
        let silent = try #require(EffectClipControlsTests.silentSpan(voice, in: 0.2...1.2, level: level))
        let bounds = Self.doubles(vector[ai: "voiceSilent"]), silence = try #require(vector[ai: "silenceTolerance"].aiDouble)
        #expect(abs(silent.lowerBound - bounds[0]) <= silence && abs(silent.upperBound - bounds[1]) <= silence, "voice silent \(silent)")
        // The edited-audio export stays 1× long.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-clip-render-replay-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let edited = directory.appendingPathComponent("edited.wav")
        try await AVExporter().writeEditedAudio(EffectClipControlsTests.request(source, effects: [bleep], controls: fast), to: edited)
        let samples = EffectClipControlsTests.left(try await MusicBedTests.decodedAudio(edited))
        #expect(abs(samples.count - (vector[ai: "editedAudioSamples"].aiInt ?? -1)) <= 1, "\(samples.count) edited samples")
        // A title over its edited window, shown and hidden on the rendered clock, and shown at 1× where the speed hides it.
        let window = vector[ai: "title"]
        let title = ClipEffect(id: "fx-title-1", clipId: nil, kind: .title, start: try #require(window[ai: "start"].aiDouble),
                               end: try #require(window[ai: "end"].aiDouble), text: "Day 1", position: .top)
        let titled = EffectClipControlsTests.request(source, effects: [title], controls: fast)
        let plain = EffectClipControlsTests.request(source, controls: fast)
        let checks = Self.doubles(window[ai: "shown"]).map { ($0, true) } + Self.doubles(window[ai: "hidden"]).map { ($0, false) }
        for (seconds, shown) in checks {
            let differs = try await EffectClipControlsTests.frame(titled, at: seconds) != (try await EffectClipControlsTests.frame(plain, at: seconds))
            #expect(differs == shown, "\(seconds) s rendered: title \(differs ? "shown" : "hidden")")
        }
        for seconds in Self.doubles(window[ai: "shownAtOneX"]) {
            let normal = EffectClipControlsTests.request(source, effects: [title], controls: nil)
            let shown = try await EffectClipControlsTests.frame(normal, at: seconds) != (try await EffectClipControlsTests.frame(EffectClipControlsTests.request(source, controls: nil), at: seconds))
            #expect(shown, "\(seconds) s at 1×")
        }
    }

    /// SRT cues are page times on the rendered clock.
    @Test func srtCuesOnTheRenderedClock() throws {
        for item in try Self.cases()[ai: "srt"].aiArray {
            let page = Self.doubles(item[ai: "page"]), speed = try #require(item[ai: "speed"].aiDouble)
            let words = [CaptionWord(id: "w1", text: "Hello", start: page[0], end: page[1])]
            let rectangle = CaptionRect(x: 0, y: 0, width: 100, height: 20)
            let captionPage = CaptionPage(index: 0, words: words, start: page[0], end: page[1], fontPx: 20,
                                          lines: [CaptionLine(words: [0], units: 100, rect: rectangle, baseline: 10)], block: rectangle, visual: rectangle)
            let srt = AVExporter.srt(CaptionTrack(words: words, pages: [captionPage]), speed: speed)
            let cue = try #require(item[ai: "cue"].aiString)
            #expect(srt.contains(cue), "\(speed)×: \(srt)")
        }
    }

    /// Bleeped words read as × per letter or digit, punctuation kept.
    @Test func maskingKeepsPunctuation() throws {
        for item in try Self.cases()[ai: "mask"].aiArray {
            let text = try #require(item[ai: "text"].aiString)
            #expect(ClipEffects.masked(text) == item[ai: "masked"].aiString, "\(text) → \(ClipEffects.masked(text))")
        }
    }
}
