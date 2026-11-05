import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/clip-controls/clip-controls-wire-cases.json (the C# twin replays the same file).
@Suite(.offlineFixtures) struct ClipControlsProjectWireTests {
    private struct Patch: Decodable {
        let path: String
        let value: JSONValue?
        let remove: Bool?
    }
    private struct WireCase: Decodable {
        let id: String
        let patches: [Patch]
        let tooNew: Bool?
    }
    private struct Cases: Decodable {
        let format: String
        let valid: [WireCase]
        let invalid: [WireCase]
    }
    static let fixture = "fixtures/clip-controls/clip-controls-project.voxclip"
    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/clip-controls/clip-controls-wire-cases.json"))
    }

    private func replacing(_ original: JSONValue, path: ArraySlice<String>, patch: Patch) throws -> JSONValue {
        guard let key = path.first else { return patch.value ?? .null }
        switch original {
        case .object(var object):
            if path.count == 1 {
                if patch.remove == true { object.removeValue(forKey: key) } else { object[key] = patch.value ?? .null }
            } else {
                object[key] = try replacing(#require(object[key]), path: path.dropFirst(), patch: patch)
            }
            return .object(object)
        case .array(var array):
            let index = try #require(Int(key))
            array[index] = path.count == 1 ? (patch.value ?? .null) : try replacing(array[index], path: path.dropFirst(), patch: patch)
            return .array(array)
        default:
            throw VoxClipError.projectUnreadable("Invalid fixture patch")
        }
    }

    private func data(_ item: WireCase) throws -> Data {
        var value = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data(Self.fixture))
        for patch in item.patches {
            value = try replacing(value, path: patch.path.split(separator: "/").map(String.init)[...], patch: patch)
        }
        return try JSONEncoder().encode(value)
    }

    @Test func formatIsItsOwnFile() throws {
        #expect(try cases().format == "voxclip-clip-controls-wire-cases/1")
    }

    @Test func validCorpusRoundTripsAtV4AndOmitsEmptyControls() throws {
        let items = try cases().valid
        #expect(items.count == 13)
        for item in items {
            let project = try ProjectJSON.decode(data(item))
            #expect(project.schemaVersion == 4, "\(item.id)")
            let encoded = try ProjectJSON.encode(project)
            #expect(try ProjectJSON.decode(encoded) == project, "\(item.id)")
            #expect(try JSONProjectStore.decode(JSONProjectStore.encode(project)) == project, "\(item.id)")
            let raw = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            if project.clipControls.isEmpty { #expect(raw["clipControls"] == nil, "\(item.id)") }
            for entry in (raw["clipControls"] as? [[String: Any]]) ?? [] {
                #expect(entry.count == 10, "\(item.id): every key is written, null included")
            }
        }
    }

    @Test func invalidCorpusIsRejected() throws {
        let items = try cases().invalid
        #expect(items.count == 38)
        for item in items {
            let input = try data(item)
            if item.tooNew == true {
                #expect(throws: VoxClipError.projectTooNew, "\(item.id)") { try ProjectJSON.decode(input) }
            } else {
                #expect(throws: (any Error).self, "\(item.id)") { try ProjectJSON.decode(input) }
                #expect(throws: (any Error).self, "\(item.id)") { try JSONProjectStore.decode(input) }
            }
        }
    }

    @Test func aLegacyProjectSavesUnchangedPromotesOnItsFirstControlAndDropsDefaults() throws {
        var original = try ProjectJSON.decode(FixtureLoader.data("fixtures/projects/interview-take.voxclip"))
        let words = try #require(original.transcript?.words)
        original.edits.clips = [ClipRange(id: "clip-a", startWordId: try #require(words.first).id, endWordId: try #require(words.last).id)]
        #expect(original.schemaVersion == 1 && original.clipControls.isEmpty)
        let saved = try #require(JSONSerialization.jsonObject(with: ProjectJSON.encode(original)) as? [String: Any])
        #expect(saved["clipControls"] == nil && saved["schemaVersion"] as? Int == 1)
        let clip = try #require(original.edits.clips.first)
        // At the defaults nothing is stored and the project keeps its version.
        #expect(try ClipControlsProject.setting(ProjectClipControls(clipId: clip.id), in: original) == original)
        var controls = ProjectClipControls(clipId: clip.id)
        controls.speed = 1.1
        var promoted = try ClipControlsProject.setting(controls, in: original)
        #expect(promoted.schemaVersion == 4 && promoted.clipControls == [controls])
        #expect(try ProjectJSON.decode(ProjectJSON.encode(promoted)) == promoted)
        controls.speed = 1
        promoted = try ClipControlsProject.setting(controls, in: promoted)
        #expect(promoted.clipControls.isEmpty)
        #expect(throws: ClipControlsProjectError.unknownClip) { try ClipControlsProject.setting(ProjectClipControls(clipId: "missing", speed: 2), in: original) }
        var legacy = original
        legacy.clipControls = [ProjectClipControls(clipId: clip.id, speed: 2)]
        #expect(throws: ClipControlsProjectError.unsupportedVersion) { try ProjectJSON.encode(legacy) }
    }

    @Test func removingAClipOrReplacingTheTranscriptDropsItsControls() throws {
        var project = try ProjectJSON.decode(FixtureLoader.data(Self.fixture))
        #expect(project.clipControls.map(\.clipId) == ["clip-main"])
        var removed = project
        try removed.applyEditing(.removeClip(id: "clip-main"))
        #expect(removed.clipControls.isEmpty)
        #expect(try ProjectJSON.decode(ProjectJSON.encode(removed)) == removed)
        project.replaceTranscript(try #require(project.transcript))
        #expect(project.clipControls.isEmpty)
    }

    @Test func thePlannersLooksAreTheRenderersLooks() {
        #expect(ClipAutopilotPlan.LookID.self == ClipLook.self)
        #expect(ClipLook.allCases.map(\.rawValue) == ["original", "muted", "warm", "bw"])
        #expect(ClipLook.allCases.map(\.label) == ["Original", "Muted", "Warm", "B&W"])
    }

    @Test func aRenderOfTheClipCarriesItsControlsAndTheFullTakeNone() throws {
        let project = try ProjectJSON.decode(FixtureLoader.data(Self.fixture))
        let controls = try #require(ClipControlsProject.controls(for: "clip-main", in: project))
        #expect(controls.speed == 1.25 && controls.look == .muted && controls.shape == .portrait)
        #expect(ClipControlsProject.controls(for: nil, in: project) == nil)
        var other = project
        other.clipControls = []
        #expect(ClipControlsProject.controls(for: "clip-main", in: other)?.isDefault == true)
    }
}

/// The clip controls' timing, level and frame rules (design.md §6.9).
@Suite struct ClipControlsTests {
    @Test func valuesAreNormalizedAndLabelled() {
        #expect(ProjectClipControls.normalizedSpeed(1.104) == 1.1 && ProjectClipControls.normalizedSpeed(3) == 2)
        #expect(ProjectClipControls.normalizedSpeed(0.1) == 0.5 && ProjectClipControls.normalizedSpeed(.nan) == 1)
        let labels = ProjectClipControls.speedPresets.map(ProjectClipControls.speedLabel)
        #expect(labels == ["0.75\u{00D7}", "1\u{00D7}", "1.1\u{00D7}", "1.25\u{00D7}", "1.5\u{00D7}", "2\u{00D7}"])
        #expect(ProjectClipControls.normalizedGain(-3.3) == -3.5 && ProjectClipControls.normalizedGain(40) == 12)
        #expect(ProjectClipControls.normalizedFade(0.46) == 0.5 && ProjectClipControls.normalizedFade(9) == 5)
        let turns = [0, 89, 90, 181, 270, 360, -90, 450].map(ProjectClipControls.normalizedRotation)
        #expect(turns == [0, 90, 90, 180, 270, 0, 270, 90])
        #expect(ProjectClipControls(clipId: "a").isDefault && !ProjectClipControls(clipId: "a", look: .bw).isDefault)
        #expect(!ProjectClipControls(clipId: "a", look: .bw).changesAudio && ProjectClipControls(clipId: "a", speed: 1.5).changesAudio)
        #expect(ProjectClipControls(clipId: "a", fadeInSeconds: 1).changesAudio && ProjectClipControls(clipId: "a", muteSource: true).changesAudio)
        #expect(ProjectClipControls(clipId: "a", flipHorizontal: true).changesPicture && !ProjectClipControls(clipId: "a", gainDb: 3).changesPicture)
    }

    /// Words, caption pages, cuts and motion keep 1× edited times; the rendered clock divides them by the speed.
    @Test func speedMapsEditedTimesOntoTheRenderedTimeline() throws {
        let timing = ClipSpeedTiming(speed: 1.25)
        #expect(timing.rendered(10) == 8 && timing.edited(8) == 10)
        #expect(timing.renderedSamples(480_000) == 384_000)
        #expect(ClipSpeedTiming(speed: 1).rendered(1.234) == 1.234 && ClipSpeedTiming(speed: 0).speed == 1)
        // A cut map: kept source ranges [0, 2) and [3, 5) play as edited [0, 2) and [2, 4); at 2× they end at 1 and 2.
        let kept = [MediaInterval(startSample: 0, endSample: 96_000), MediaInterval(startSample: 144_000, endSample: 240_000)]
        let plan = EditPlan(sampleRate: 48_000, totalSamples: 240_000, cuts: [MediaInterval(startSample: 96_000, endSample: 144_000)], kept: kept)
        let output = OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 1_000_000)
        var request = RenderRequest(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"), plan: plan, output: output)
        #expect(request.renderedSamples == 192_000 && request.renderedDuration == 4)
        request.clipControls = ProjectClipControls(clipId: "clip-main", speed: 2)
        #expect(request.renderedSamples == 96_000 && request.renderedDuration == 2)
        // A word at source 3.5 s is edited 2.5 s and plays at 1.25 s; the compositor maps 1.25 s back to the source word.
        #expect(request.timeline.mapTime(3.5) == 2.5 && request.speedTiming.rendered(2.5) == 1.25)
        #expect(request.timeline.sourceTime(request.speedTiming.edited(1.25)) == 3.5)
        // A motion cue keyed on source time fires at the same source frame at any speed.
        let cueSource = 4.0
        #expect(request.speedTiming.rendered(request.timeline.mapTime(cueSource)) == 1.5)
        #expect(request.withoutClipControls.clipControls == nil)
    }

    @Test func levelsFadeAndMuteInRenderedTime() {
        let controls = ProjectClipControls(clipId: "a", gainDb: -6, fadeInSeconds: 0.5, fadeOutSeconds: 1)
        let unity = pow(10, -6.0 / 20)
        #expect(abs(ClipAudioMix.linearGain(controls) - 0.501187) < 1e-6)
        #expect(ClipAudioMix.gain(at: 0, duration: 4, controls: controls) == 0)
        #expect(abs(ClipAudioMix.gain(at: 0.25, duration: 4, controls: controls) - unity / 2) < 1e-12)
        #expect(abs(ClipAudioMix.gain(at: 2, duration: 4, controls: controls) - unity) < 1e-12)
        #expect(abs(ClipAudioMix.gain(at: 3.5, duration: 4, controls: controls) - unity / 2) < 1e-12)
        #expect(ClipAudioMix.gain(at: 2, duration: 4, controls: ProjectClipControls(clipId: "a", gainDb: 6, muteSource: true)) == 0)
        #expect(ClipAudioMix.gain(at: 2, duration: 4, controls: ProjectClipControls(clipId: "a")) == 1)
    }

    @Test func framesFollowTheShapeAndAnOriginalFrameTurns() throws {
        let source = PixelSize(width: 1920, height: 1080)
        func size(_ aspect: AspectRatio, _ controls: ProjectClipControls?) throws -> PixelSize {
            try OutputSizing.outputSize(source: source, aspect: aspect, controls: controls)
        }
        #expect(try size(.landscape, nil) == PixelSize(width: 1920, height: 1080))
        #expect(try size(.landscape, ProjectClipControls(clipId: "a", shape: .portraitFourFive)) == PixelSize(width: 1080, height: 1350))
        #expect(try size(.source, ProjectClipControls(clipId: "a", rotationDegrees: 90)) == PixelSize(width: 1080, height: 1920))
        #expect(try size(.square, ProjectClipControls(clipId: "a", rotationDegrees: 270)) == PixelSize(width: 1080, height: 1080))
        #expect(try size(.portrait, ProjectClipControls(clipId: "a", shape: .landscape, rotationDegrees: 90)) == PixelSize(width: 1920, height: 1080))
        #expect(ClipShape.allCases.allSatisfy { $0.size.width % 2 == 0 && $0.size.height % 2 == 0 && max($0.size.width, $0.size.height) <= 1920 })
        let fourFive = OutputSizing.videoBitrate(size: source, aspect: .landscape, quality: .high, fps: 30,
                                                 controls: ProjectClipControls(clipId: "a", shape: .portraitFourFive))
        #expect(fourFive == 9_750_000)
        let looked = OutputSizing.videoBitrate(size: source, aspect: .landscape, quality: .standard, fps: 30, controls: ProjectClipControls(clipId: "a", look: .bw))
        #expect(looked == OutputSizing.videoBitrate(size: source, aspect: .landscape, quality: .standard, fps: 30))
    }

    /// Each look is a fixed recipe: Original is the identity, Muted keeps white and lifts black, B&W keeps 0, ½ and 1.
    @Test func lookRecipesAreSubtleAndFixed() {
        #expect(ClipLookRecipe(.original).isIdentity && !ClipLookRecipe(.bw).isIdentity)
        #expect(ClipLookRecipe(.original).apply([0.3, 0.6, 0.9]) == [0.3, 0.6, 0.9])
        let muted = ClipLookRecipe(.muted)
        #expect(muted.apply([1, 1, 1]).allSatisfy { abs($0 - 1) < 1e-12 } && muted.apply([0, 0, 0]).allSatisfy { abs($0 - 0.04) < 1e-12 })
        let red = muted.apply([0.9, 0.1, 0.1])
        #expect(abs((red[0] - red[1]) / 0.8 - 0.65 * 0.96) < 1e-9)
        let mono = ClipLookRecipe(.bw)
        for value in [0.0, 0.5, 1.0] { #expect(mono.apply([value, value, value]).allSatisfy { abs($0 - value) < 1e-12 }) }
        let shadow = mono.apply([0.25, 0.25, 0.25]), highlight = mono.apply([0.75, 0.75, 0.75])
        #expect(shadow[0] < 0.25 && shadow[0] > 0.2 && highlight[0] > 0.75 && highlight[0] < 0.8)
        let warm = ClipLookRecipe(.warm).apply([0.5, 0.5, 0.5])
        #expect(warm[0] > 0.5 && warm[2] < 0.5 && abs(warm[1] - 0.515) < 1e-12)
    }

    /// A framing anchor (x right, y down) follows the picture: mirrored, then turned clockwise.
    @Test func anchorsFollowTheFlipAndTheTurns() {
        func map(_ flip: Bool, _ degrees: Int) -> [Double] {
            let point = ProjectClipControls(clipId: "a", flipHorizontal: flip, rotationDegrees: degrees).mapAnchor(x: 0.2, y: 0.1)
            return [(point.x * 100).rounded() / 100, (point.y * 100).rounded() / 100]
        }
        #expect(map(false, 0) == [0.2, 0.1])
        #expect(map(true, 0) == [0.8, 0.1])
        #expect(map(false, 90) == [0.9, 0.2])
        #expect(map(false, 180) == [0.8, 0.9])
        #expect(map(false, 270) == [0.1, 0.8])
        #expect(map(true, 90) == [0.9, 0.8])
    }

    /// An Ask Claude box (top-left normalized, as filmed) flips and turns with the picture and keeps its size.
    @Test func effectBoxesFollowTheFlipAndTheTurns() {
        let box = ClipEffect.Rect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        func map(_ flip: Bool, _ degrees: Int) -> [Double] {
            let rect = ProjectClipControls(clipId: "a", flipHorizontal: flip, rotationDegrees: degrees).mapRect(box)
            return [rect.x, rect.y, rect.width, rect.height].map { ($0 * 100).rounded() / 100 }
        }
        #expect(map(false, 0) == [0.1, 0.2, 0.3, 0.4])
        #expect(map(true, 0) == [0.6, 0.2, 0.3, 0.4])
        #expect(map(false, 90) == [0.4, 0.1, 0.4, 0.3])
        #expect(map(false, 180) == [0.6, 0.4, 0.3, 0.4])
        #expect(map(false, 270) == [0.2, 0.6, 0.4, 0.3])
    }

    /// The pure steps Make it postable and Ask Claude use: a look or a speed changes only that control, normalised, and a
    /// stretch counts as the whole clip within 0.25 s of each end.
    @Test func lookAndSpeedStepsKeepTheOtherControlsAndAStretchFindsItsWholeClip() throws {
        let project = try ProjectJSON.decode(FixtureLoader.data(ClipControlsProjectWireTests.fixture))
        let before = try #require(ClipControlsProject.controls(for: "clip-main", in: project))
        let faster = try ClipControlsProject.settingSpeed(1.234, clipId: "clip-main", in: project)
        var expected = before; expected.speed = 1.23
        #expect(ClipControlsProject.controls(for: "clip-main", in: faster) == expected)
        let warm = try ClipControlsProject.settingLook(.warm, clipId: "clip-main", in: faster)
        expected.look = .warm
        #expect(ClipControlsProject.controls(for: "clip-main", in: warm) == expected)
        #expect(throws: ClipControlsProjectError.unknownClip) { try ClipControlsProject.settingSpeed(2, clipId: "missing", in: project) }
        let span = try #require(ClipControlsProject.sourceSpan(of: "clip-main", in: project))
        #expect(ClipControlsProject.wholeClip("clip-main", start: span.lowerBound + 0.25, end: span.upperBound - 0.25, in: project) == "clip-main")
        #expect(ClipControlsProject.wholeClip(nil, start: span.lowerBound - 0.1, end: span.upperBound + 0.1, in: project) == "clip-main")
        #expect(ClipControlsProject.wholeClip("clip-main", start: span.lowerBound + 0.3, end: span.upperBound, in: project) == nil)
        #expect(ClipControlsProject.wholeClip("clip-main", start: span.lowerBound, end: span.upperBound - 0.3, in: project) == nil)
    }
}
