import Foundation
import Testing
@testable import VoxClipCore

/// "Claude sees the picture", part 2 (ADR-R48, ai.md §19.6): the project fields (a clip's opening lead-in, its face-follow
/// crop and its cover), the clip's frames out of the whole video's, the candidates a plan request lists, the reply's frame
/// choices and the image price. Shared vectors: shared/fixtures/clip-frames/ and shared/fixtures/autopilot/plan-frames-cases.json.
@Suite(.offlineFixtures) struct ClipFramesProjectWireTests {
    private struct Patch: Decodable { let path: String; let value: JSONValue?; let remove: Bool? }
    private struct WireCase: Decodable { let id: String; let patches: [Patch] }
    private struct Cases: Decodable { let format: String; let valid: [WireCase]; let invalid: [WireCase] }
    static let fixture = "fixtures/clip-frames/clip-frames-project.voxclip"

    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: FixtureLoader.data("fixtures/clip-frames/clip-frames-wire-cases.json"))
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

    private func value(_ item: WireCase) throws -> JSONValue {
        var value = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data(Self.fixture))
        for patch in item.patches { value = try replacing(value, path: patch.path.split(separator: "/").map(String.init)[...], patch: patch) }
        return value
    }

    @Test func formatIsItsOwnFile() throws {
        #expect(try cases().format == "voxclip-clip-frames-wire-cases/1")
    }

    @Test func validCorpusSavesLosslessly() throws {
        let items = try cases().valid
        #expect(items.count == 8)
        for item in items {
            let input = try value(item)
            let project = try ProjectJSON.decode(JSONEncoder().encode(input))
            let saved = try JSONDecoder().decode(JSONValue.self, from: ProjectJSON.encode(project))
            // Every field the case carries comes back as it was, and an absent one stays absent.
            #expect(saved[ai: "edits"][ai: "clips"] == input[ai: "edits"][ai: "clips"], "\(item.id)")
            #expect(saved[ai: "clipControls"] == input[ai: "clipControls"], "\(item.id)")
            #expect(try JSONProjectStore.decode(JSONProjectStore.encode(project)) == project, "\(item.id)")
        }
    }

    @Test func invalidCorpusIsRejected() throws {
        let items = try cases().invalid
        #expect(items.count == 14)
        for item in items {
            let input = try JSONEncoder().encode(value(item))
            #expect(throws: (any Error).self, "\(item.id)") { try ProjectJSON.decode(input) }
        }
    }

    @Test func theFixtureCarriesEachField() throws {
        let project = try ProjectJSON.decode(FixtureLoader.data(Self.fixture))
        let controls = try #require(ClipControlsProject.controls(for: "clip-main", in: project))
        #expect(project.edits.clips[0].leadInSeconds == 0.25)
        #expect(controls.reframe == .face(x: 0.42, y: 0.38) && controls.coverSeconds == 1.3)
        #expect(controls.cropCenter(outputAspect: 9.0 / 16.0)?.x == 0.42 && controls.cropCenter(outputAspect: 1)?.y == 0.38)
        #expect(controls.cropCenter(outputAspect: 16.0 / 9.0) == nil, "16:9 crops nothing it could move")
    }
}

@Suite struct ClipLeadInTests {
    static func words() -> [TimedWord] {
        [TimedWord(id: "a", text: "So.", kind: .word, start: 0.2, end: 0.5),
         TimedWord(id: "b", text: "Here", kind: .word, start: 1.5, end: 1.8),
         TimedWord(id: "c", text: "it", kind: .word, start: 1.9, end: 2.1),
         TimedWord(id: "d", text: "is.", kind: .word, start: 2.2, end: 2.5)]
    }

    @Test func aLeadInOpensEarlierButNeverReachesTheWordBefore() throws {
        let words = Self.words()
        #expect(try clipTimes(words, startIndex: 1, endIndex: 3).start == 1.5 - 0.12)
        #expect(abs(try clipTimes(words, startIndex: 1, endIndex: 3, leadIn: 0.4).start - 1.1) < 1e-9)
        // The floor is the word before plus its own cut margin (0.1 s): never a sound of "So.".
        #expect(try clipTimes(words, startIndex: 1, endIndex: 3, leadIn: 5).start == 0.6)
        #expect(clipLeadInFloor(words, startIndex: 1) == 0.6)
        #expect(try clipTimes(words, startIndex: 0, endIndex: 3, leadIn: 0.6).start == 0)
    }

    @Test func theRenderedClipKeepsTheWordBeforeCut() throws {
        var project = try ProjectJSON.decode(FixtureLoader.data(ClipFramesProjectWireTests.fixture))
        let words = try #require(project.transcript?.words)
        // "we" starts 1.1 s after "today" ends: room for the whole 0.6 s.
        project.edits.clips[0].startWordId = words[3].id
        project.edits.clips[0].leadInSeconds = 0.6
        let timeline = try RenderCallerInputs.timeline(project: project, clipID: "clip-main")
        #expect(abs(timeline.sourceTime(0) - (words[3].start - 0.6)) < 1e-3)
        project.edits.clips[0].leadInSeconds = 0.6
        project.edits.clips[0].startWordId = words[1].id
        let tight = try RenderCallerInputs.timeline(project: project, clipID: "clip-main")
        #expect(abs(tight.sourceTime(0) - clipLeadInFloor(words, startIndex: 1)) < 1e-3, "opens at the floor, after the word before")
        #expect(tight.sourceTime(0) > words[0].end)
        project.edits.clips[0].startWordId = words[3].id
        project.edits.clips[0].leadInSeconds = nil
        let plain = try RenderCallerInputs.timeline(project: project, clipID: "clip-main")
        #expect(plain.duration < timeline.duration)
    }

    @Test func aNewFirstWordDropsTheLeadIn() throws {
        let project = try ProjectJSON.decode(FixtureLoader.data(ClipFramesProjectWireTests.fixture))
        var moved = project, kept = project
        try moved.applyEditing(.updateClip(id: "clip-main", startIndex: 1, endIndex: 8))
        #expect(moved.edits.clips[0].leadInSeconds == nil)
        try kept.applyEditing(.updateClip(id: "clip-main", startIndex: 0, endIndex: 7))
        #expect(kept.edits.clips[0].leadInSeconds == 0.25)
    }
}

@Suite struct ClipFrameSamplingTests {
    static func words(_ count: Int) -> [TimedWord] {
        (0..<count).map { index in
            let text = index % 4 == 3 ? "word\(index)." : "word\(index)"
            return TimedWord(id: "w\(index)", text: text, kind: .word, start: Double(index), end: Double(index) + 0.8)
        }
    }

    @Test func theVideoPassHasOneFramePerSentenceAndAClipTakesItsOwnAtMost24() throws {
        let words = Self.words(400)
        let video = FrameSampling.videoSamples(words)
        #expect(video.count == 100)
        let clip = try #require(FrameClip(words: words, first: 40, last: 199, cutWordIds: []))
        let samples = FrameSampling.clipSamples(video, clip: clip)
        #expect(samples.count == 24)
        #expect(samples.allSatisfy { $0.time >= clip.start && $0.time <= clip.end })
        #expect(samples.first == video.first { $0.time >= clip.start } && samples.last == video.last { $0.time <= clip.end })
        #expect(Set(samples.map(\.time)).isSubset(of: Set(video.map(\.time))), "every frame comes from the pass, so from its cache")
    }

    @Test func cutWordsAreSkippedAndAClipInsideOneSentenceGetsItsOwn() throws {
        let words = Self.words(40)
        let video = FrameSampling.videoSamples(words)
        let cut = Set(video.prefix(3).compactMap { sample in words.first { $0.start <= sample.time && sample.time <= $0.end }?.id })
        let clip = try #require(FrameClip(words: words, first: 0, last: 39, cutWordIds: cut))
        #expect(FrameSampling.clipSamples(video, clip: clip).count == video.count - 3)
        let short = try #require(FrameClip(words: words, first: 0, last: 1, cutWordIds: []))
        #expect(FrameSampling.clipSamples(video, clip: short) == FrameSampling.sentenceSamples(short))
    }
}

@Suite(.offlineFixtures) struct ClipAutopilotFramesTests {
    static func fixture() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/autopilot/plan-frames-cases.json"))
    }

    static func image(_ index: Int) -> LLMImage {
        LLMImage(label: "Frame \(index)", mediaType: "image/jpeg", data: Data(repeating: UInt8(index), count: 8), width: 320, height: 180)
    }

    /// The fixture's frames as a request would carry them.
    static func frames(images: Bool) throws -> ClipAutopilotFrames {
        let value = try fixture()[ai: "frames"]
        let blur = value[ai: "blur"].aiArray.map { item in
            let box = item[ai: "rect"].aiArray.compactMap(\.aiDouble)
            return ClipAutopilotFrames.BlurCandidate(id: item[ai: "id"].aiString ?? "", start: item[ai: "start"].aiDouble ?? 0,
                end: item[ai: "end"].aiDouble ?? 0, rect: ClipEffect.Rect(x: box[0], y: box[1], width: box[2], height: box[3]),
                frames: item[ai: "frames"].aiInt ?? 0)
        }
        let cover = value[ai: "cover"].aiArray.map { item in
            ClipAutopilotFrames.CoverCandidate(id: item[ai: "id"].aiString ?? "", frame: item[ai: "frame"].aiInt ?? 0,
                                               time: item[ai: "time"].aiDouble ?? 0, score: 0.5)
        }
        return ClipAutopilotFrames(summary: value[ai: "summary"].aiString ?? "", images: images ? (1...5).map(image) : [], blur: blur,
                                   cover: cover, frames: [], estimatedImageTokens: images ? 385 : 0)
    }

    @Test func vectorsPinTheCurrentPrompt() throws {
        let prompt = try ClipAutopilotPrompt(shared: ClipAutopilotTests.shared())
        #expect(prompt.promptVersion == 8)
        #expect(try Self.fixture()[ai: "sources"][ai: "shared/prompts/clip-autopilot.json"].aiString == prompt.sha256)
        #expect(prompt.system.contains("frames.blur") && prompt.schema[ai: "required"].aiArray.contains(.string("frames")))
    }

    @Test func theBlockCarriesTheSummaryAlwaysAndNamesTheImagesOnlyWhenTheyGo() throws {
        let prompt = try ClipAutopilotPrompt(shared: ClipAutopilotTests.shared())
        #expect(try ClipAutopilotRequestBuilder.framesBlock(Self.frames(images: false), prompt: prompt) == Self.fixture()[ai: "block"].aiString)
        #expect(try ClipAutopilotRequestBuilder.framesBlock(Self.frames(images: true), prompt: prompt) == Self.fixture()[ai: "blockWithImages"].aiString)
    }

    @Test func theRequestCarriesTheSummaryForEveryConnectorAndImagesOnlyWhenGiven() async throws {
        let shared = try ClipAutopilotTests.shared()
        let service = ClipAutopilotService(runner: try ClipAutopilotTests.runner(), shared: shared)
        let input = ClipAutopilotRequest(transcript: try ClipAutopilotV2Tests.transcript(), mode: .clip(0...29))
        let plain = try await service.request(input, connector: .anthropic)
        let text = try await service.request(input, connector: .ollama, frames: Self.frames(images: false))
        let images = try await service.request(input, connector: .anthropic, frames: Self.frames(images: true))
        #expect(!plain.instruction.contains("Frames measured") && plain.images.isEmpty, "no frames: the request is as before")
        #expect(text.instruction.contains(try #require(Self.fixture()[ai: "block"].aiString)) && text.images.isEmpty)
        #expect(images.instruction.contains("The images are those frames") && images.images.count == 5)
        #expect(text.instruction.hasPrefix(plain.instruction), "the frames follow the clip instruction")
        // The moments stage of a series never carries frames.
        let series = try await service.request(ClipAutopilotRequest(transcript: input.transcript, mode: .series(nil)), connector: .anthropic,
                                               frames: Self.frames(images: true))
        #expect(series.images.isEmpty && !series.instruction.contains("Frames measured"))
    }

    @Test(arguments: ["blur-one-keep-one", "ids-read-ignoring-case-and-space", "unknown-and-repeated-blur-ids-are-ignored",
                      "unknown-cover-falls-back-to-the-local-best", "empty-cover-falls-back", "old-reply-without-frames"])
    func replyFramesAreCheckedAgainstTheCandidates(_ id: String) throws {
        let vector = try #require(try Self.fixture()[ai: "cases"].aiArray.first { $0[ai: "id"].aiString == id })
        guard case .object(var reply) = try ClipAutopilotV2Tests.vector("corrections")[ai: "reply"] else { Issue.record("no reply"); return }
        if vector[ai: "reply"] != .null { reply["frames"] = vector[ai: "reply"] }
        let context = try ClipAutopilotV2Tests.context(scope: 0...29).showing(Self.frames(images: true))
        let plan = try #require(ClipAutopilotValidator.plan(.object(reply), context: context))
        let expect = vector[ai: "expect"]
        let frames = try #require(plan.frames)
        #expect(frames.blur.map { [JSONValue.string($0.id), .bool($0.blur)] } == expect[ai: "blur"].aiArray.map(\.aiArray))
        #expect([JSONValue.string(frames.cover?.id ?? ""), .bool(frames.cover?.fallback ?? false)] == expect[ai: "cover"].aiArray)
        let repairs = plan.repairs.filter { $0.field.hasPrefix("frames") }.map { [$0.field, $0.action.rawValue] }
        #expect(repairs == expect[ai: "repairs"].aiArray.map { $0.aiArray.compactMap(\.aiString) })
    }

    @Test func withoutFramesInTheRequestThePlanHasNone() throws {
        var reply = try ClipAutopilotV2Tests.vector("corrections")[ai: "reply"]
        if case .object(var object) = reply { object["frames"] = .object(["blur": .array([]), "cover": .object(["id": .string("C1"), "reason": .string("")])]); reply = .object(object) }
        let plan = try #require(ClipAutopilotValidator.plan(reply, context: try ClipAutopilotV2Tests.context(scope: 0...29)))
        #expect(plan.frames == nil && plan.version == 4)
    }

    @Test func planVersionFourIsReadAndFiveRefused() throws {
        let plan = ClipAutopilotPlan(startWord: 0, endWord: 3, title: "T", hook: "H",
            captions: .init(styleId: "vox-bold", font: .init(family: "Roboto", weight: 900), textCase: .upper, wordsPerCaption: 3),
            postText: "P", score: 7, verdict: .post, frames: .init(blur: [.init(id: "B1", blur: true, reason: "names")], cover: .init(id: "C2", reason: "smile")))
        let data = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(ClipAutopilotPlan.self, from: data) == plan)
        var raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        raw["version"] = 5
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ClipAutopilotPlan.self, from: JSONSerialization.data(withJSONObject: raw)) }
        raw["version"] = 3; raw["frames"] = nil
        #expect(try JSONDecoder().decode(ClipAutopilotPlan.self, from: JSONSerialization.data(withJSONObject: raw)).frames == nil)
    }
}

@Suite struct ClipFrameCandidateTests {
    static func face(_ x: Double, eyes: Double = 0.3, quality: Double = 0.5) -> FrameFace {
        FrameFace(rect: .init(x: x, y: 0.2, width: 0.2, height: 0.36), captureQuality: quality, leftEyeAspect: eyes, rightEyeAspect: eyes, yaw: 0, pitch: 0)
    }

    static func frame(_ index: Int, time: Double, face: FrameFace?, screen: ClipEffect.Rect? = nil) -> FrameSheetFrame {
        let screens = screen.map { [FrameScreen(rect: $0, textBoxes: 5, textCoverage: 0.2, framed: true)] } ?? []
        return FrameSheetFrame(index: index, observation: FrameObservation(time: time, faceCount: face == nil ? 0 : 1, face: face, screens: screens),
                               jpeg: Data([1]), width: 320, height: 180)
    }

    @Test func blurCandidatesMergeAScreenAcrossSentenceFramesAndStayInsideTheClip() {
        let phone = ClipEffect.Rect(x: 0.6, y: 0.3, width: 0.2, height: 0.4)
        let frames = [Self.frame(1, time: 2, face: Self.face(0.4)), Self.frame(2, time: 6, face: Self.face(0.4), screen: phone),
                      Self.frame(3, time: 11, face: Self.face(0.4), screen: phone), Self.frame(4, time: 29.5, face: nil, screen: phone)]
        let candidates = ClipFrameCandidates.blur(frames.map(\.observation), clipStart: 1, clipEnd: 30)
        #expect(candidates.map(\.id) == ["B1", "B2"])
        #expect(candidates[0].start == 5 && candidates[0].end == 12 && candidates[0].frames == 2)
        #expect(candidates[1].end == 30, "kept inside the clip")
    }

    @Test func coverCandidatesAreTheBestThreeAndSkipABlink() {
        let frames = [Self.frame(1, time: 1, face: Self.face(0.4, quality: 0.45)), Self.frame(2, time: 1.2, face: Self.face(0.4, eyes: 0.1)),
                      Self.frame(3, time: 5, face: Self.face(0.4, quality: 0.7)), Self.frame(4, time: 9, face: Self.face(0.1, quality: 0.6)),
                      Self.frame(5, time: 13, face: Self.face(0.4, quality: 0.55)), Self.frame(6, time: 17, face: nil)]
        let covers = ClipFrameCandidates.cover(frames, pitchBaseline: nil)
        #expect(covers.map(\.id) == ["C1", "C2", "C3"])
        #expect(covers.map(\.frame) == [3, 5, 4], "frame 1 sits beside a blink; frame 4 is off centre")
    }

    @Test func aTextOnlySendKeepsTheSummaryAndCandidates() {
        let frames = [Self.frame(1, time: 1, face: Self.face(0.4))]
        let sheet = FrameSheet(frames: frames)
        let shown = ClipAutopilotFrames(sheet: sheet, clipStart: 0, clipEnd: 10, images: true, pitchBaseline: nil)
        #expect(shown.images.count == 1 && shown.estimatedImageTokens == 77)
        #expect(shown.textOnly.images.isEmpty && shown.textOnly.summary == shown.summary && shown.textOnly.cover == shown.cover)
    }
}

@Suite(.offlineFixtures) struct ClipAutopilotImagePriceTests {
    @Test func imageTokensArePricedFromTheListAndAnUnlistedModelTakesTheCeiling() throws {
        let prices = try ClipAutopilotImagePrices(shared: ClipAutopilotTests.shared())
        #expect(prices.usd(tokens: 1_000_000, connector: .anthropic, model: "claude-opus-5-5") == 4)
        #expect(prices.usd(tokens: 1_850, connector: .anthropic, model: "claude-sonnet-5-5") == Decimal(string: "0.0037"))
        #expect(prices.usd(tokens: 1_000_000, connector: .anthropic, model: "claude-new") == 5, "the connector's highest listed price")
        #expect(prices.usd(tokens: 1_000, connector: .claudeCode, model: "opus") == nil, "a CLI is never priced here")
        #expect(prices.usd(tokens: 1_000, connector: .ollama, model: "llava") == nil)
        #expect(throws: VoxClipError.sharedResourcesMissing) { try ClipAutopilotImagePrices(data: Data(#"{"schema":"other"}"#.utf8)) }
    }
}
