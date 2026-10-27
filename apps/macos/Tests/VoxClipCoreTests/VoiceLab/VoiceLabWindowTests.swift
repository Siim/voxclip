import Foundation
import Testing
@testable import VoxClipCore

/// Vector accessors over VoxClipCore's JSONValue. JSONDecoder keeps binary64 numbers and U+FEFF exactly; JSONSerialization does neither.
private extension JSONValue {
    subscript(key: String) -> JSONValue { if case .object(let fields) = self { fields[key] ?? .null } else { .null } }
    var vectorFields: [String: JSONValue] { if case .object(let fields) = self { fields } else { [:] } }
    var vectorItems: [JSONValue]? { if case .array(let items) = self { items } else { nil } }
    var vectorNumber: Double { if case .number(let number) = self { number } else { .nan } }
    var vectorInteger: Int64 { Int64(exactly: vectorNumber) ?? .min }
    var vectorString: String? { if case .string(let text) = self { text } else { nil } }
    var vectorBool: Bool? { if case .bool(let flag) = self { flag } else { nil } }
    var vectorStrings: [String]? { vectorItems?.compactMap(\.vectorString) }
    var isVectorNull: Bool { if case .null = self { true } else { false } }
}

/// Shared `window-cases.json` vectors (tools/fixtures/voice-lab/generate_window.py) and a v3 round trip.
@Suite("Voice Lab window geometry")
struct VoiceLabWindowTests {
    private static let categories = ["window", "handles", "trimHandles", "alignment", "trim", "relativeWords", "roomTone", "lendableSilence",
                                     "propertyCases", "multiSegmentCases"]
    /// The passage fixture. Its replacement is the template every recipe here starts from.
    private static let passage = try? JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))

    private func document() throws -> JSONValue {
        let document = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/voice-lab/window-cases.json"))
        #expect(document["schema"].vectorString == "voxclip-voice-lab-window-cases/4")
        return document
    }
    private func cases(_ key: String) throws -> [JSONValue] { try #require(document()[key].vectorItems) }
    private func items(_ value: JSONValue) -> [TimedWord] {
        (value.vectorItems ?? []).map {
            TimedWord(id: $0["id"].vectorString ?? "", text: $0["text"].vectorString ?? "", kind: WordKind(rawValue: $0["kind"].vectorString ?? "") ?? .word,
                      start: $0["start"].vectorNumber, end: $0["end"].vectorNumber)
        }
    }
    private func voiceWords(_ value: JSONValue) -> [VoiceLabWord] {
        (value.vectorItems ?? []).map { VoiceLabWord(text: $0["text"].vectorString ?? "", start: $0["start"].vectorNumber, end: $0["end"].vectorNumber, synthetic: $0["synthetic"].vectorBool ?? false) }
    }
    private func envelope(_ value: JSONValue) -> AudioEnvelope {
        let levels = (value["runs"].vectorItems ?? []).flatMap { run in
            Array(repeating: Float(run.vectorItems?.first?.vectorNumber ?? .nan), count: Int(run.vectorItems?.last?.vectorInteger ?? 0))
        }
        return AudioEnvelope(sampleRate: value["sampleRate"].vectorNumber, levels: levels)
    }
    private func seam(_ value: JSONValue) -> VoiceLabSeam {
        VoiceLabSeam(kind: VoiceLabSeamKind(rawValue: value["kind"].vectorString ?? "") ?? .none, fadeSamples: value["fadeSamples"].vectorInteger,
                     sourceHandleSamples: value["sourceHandleSamples"].vectorInteger, assetHandleFrames: value["assetHandleFrames"].vectorInteger)
    }
    private func described(_ error: VoiceLabGeometryError) -> [String: AnyHashable] {
        switch error {
        case .invalidInput(let id): id.map { ["error": "invalidInput", "segmentId": $0] } ?? ["error": "invalidInput"]
        case .unknownWord(let id): ["error": "unknownWord", "wordId": id]
        case .reversedWords: ["error": "reversedWords"]
        case .insertionUnsupported: ["error": "insertionUnsupported"]
        case .windowCrossesWord(let id): ["error": "windowCrossesWord", "wordId": id]
        case .seamFadeOutsideTake: ["error": "seamFadeOutsideTake"]
        case let .seamFadeCrossesCut(incoming, needed, available):
            ["error": "seamFadeCrossesCut", "incoming": incoming, "needed": needed, "available": available]
        case let .windowTooShort(needed, available): ["error": "windowTooShort", "needed": needed, "available": available]
        case .overlapsReplacement(let id): ["error": "overlapsReplacement", "segmentId": id]
        case .adjacentReplacement(let id): ["error": "adjacentReplacement", "segmentId": id]
        case let .insufficientHandle(incoming, needed, available):
            ["error": "insufficientHandle", "incoming": incoming, "needed": needed, "available": available]
        case .alignmentUnavailable: ["error": "alignmentUnavailable"]
        case .alignmentMismatch: ["error": "alignmentMismatch"]
        case .invalidWordTiming: ["error": "invalidWordTiming"]
        case .noVoicedAudio: ["error": "noVoicedAudio"]
        case .roomToneUnavailable: ["error": "roomToneUnavailable"]
        case .fitTouchesVoice: ["error": "fitTouchesVoice"]
        }
    }
    private func expectedError(_ value: JSONValue) -> [String: AnyHashable]? {
        guard let code = value["error"].vectorString else { return nil }
        var error: [String: AnyHashable] = ["error": code]
        if let id = value["wordId"].vectorString { error["wordId"] = id }
        if let id = value["segmentId"].vectorString { error["segmentId"] = id }
        if let incoming = value["incoming"].vectorBool { error["incoming"] = incoming }
        if !value["needed"].isVectorNull { error["needed"] = value["needed"].vectorInteger }
        if !value["available"].isVectorNull { error["available"] = value["available"].vectorInteger }
        return error
    }
    /// Runs one vector: either the typed error it names or a value checked by `compare`.
    private func run<Value>(_ test: JSONValue, _ body: () throws -> Value, compare: (Value, String) -> Void) {
        let name = test["name"].vectorString ?? "?"
        if let error = expectedError(test["expected"]) {
            do {
                _ = try body()
                Issue.record("\(name): expected \(error)")
            } catch let failure as VoiceLabGeometryError {
                #expect(described(failure) == error, "\(name)")
            } catch { Issue.record("\(name): \(error)") }
        } else {
            do { compare(try body(), name) } catch { Issue.record("\(name): \(error)") }
        }
    }
    /// The passage fixture's take without its replacement and assets.
    private func fixture() throws -> Project {
        var project = try #require(Self.passage)
        project.voiceLab.segments = []
        project.voiceLab.assets = []
        return project
    }
    private func seamPlacement(_ value: JSONValue) -> VoiceLabSeamPlacement {
        VoiceLabSeamPlacement(kind: VoiceLabSeamKind(rawValue: value["kind"].vectorString ?? "") ?? .none, time: value["time"].vectorNumber,
                              sample: value["sample"].vectorInteger, fadeSamples: value["fadeSamples"].vectorInteger)
    }
    private func window(_ value: JSONValue) -> VoiceLabWindow {
        VoiceLabWindow(firstWordId: value["firstWordId"].vectorString ?? "", lastWordId: value["lastWordId"].vectorString ?? "",
                       leftBridgeWordIds: value["leftBridgeWordIds"].vectorStrings ?? [], rightBridgeWordIds: value["rightBridgeWordIds"].vectorStrings ?? [],
                       start: value["start"].vectorNumber, end: value["end"].vectorNumber, startSample: value["startSample"].vectorInteger,
                       endSample: value["endSample"].vectorInteger, leftSeam: seamPlacement(value["leftSeam"]), rightSeam: seamPlacement(value["rightSeam"]))
    }
    private func roomTone(_ value: JSONValue) -> VoiceLabRoomTone {
        VoiceLabRoomTone(sourceStartSample: value["sourceStartSample"].vectorInteger, sourceEndSample: value["sourceEndSample"].vectorInteger,
                         gainDb: value["gainDb"].vectorNumber)
    }
    /// A vector's take: the passage fixture with the vector's items, duration, sample rate, edits and replacements. Each
    /// replacement is a one-word passage recipe built from its window with the vector's room tone.
    private func take(_ input: JSONValue, tone: JSONValue = .null) throws -> Project {
        var project = try fixture()
        let edits = input["edits"]
        project.media.source.audio?.sampleRate = Int(input["sampleRate"].vectorInteger)
        project.media.source.durationSeconds = input["durationSeconds"].vectorNumber
        project.transcript?.words = items(input["words"])
        project.edits.cutWordIds = edits["cutWordIds"].vectorStrings ?? []
        project.edits.cutPauseIds = edits["cutPauseIds"].vectorStrings ?? []
        project.edits.pauseThresholdSeconds = edits["pauseThresholdSeconds"].vectorNumber
        project.edits.pauseKeepSeconds = edits["pauseKeepSeconds"].vectorNumber
        project.edits.clips = (edits["clips"].vectorItems ?? []).map {
            ClipRange(id: $0["id"].vectorString ?? "", startWordId: $0["startWordId"].vectorString ?? "", endWordId: $0["endWordId"].vectorString ?? "")
        }
        project.edits.activeClipId = nil
        for raw in input["segments"].vectorItems ?? [] {
            let placed = window(raw["window"])
            let outDuration = Double(placed.endSample - placed.startSample) / input["sampleRate"].vectorNumber
            var (segment, asset) = try passageSegment(project, id: raw["id"].vectorString ?? "", window: placed, tone: roomTone(tone),
                                                      words: [VoiceLabWord(text: "patch", start: 0, end: outDuration, synthetic: true)],
                                                      trimStart: 0.5, patch: "patch")
            segment.enabled = try #require(raw["enabled"].vectorBool as Bool?)
            project.voiceLab.segments.append(segment)
            project.voiceLab.assets?.append(asset)
        }
        return project
    }
    /// The render scope a vector names: its `clipId`, or the full take.
    private func scope(_ input: JSONValue) -> VoiceLabOutputScope { input["clipId"].vectorString.map { .clip($0) } ?? .full }
    private func expectWords(_ words: [VoiceLabWord], _ value: JSONValue, _ name: String) {
        let expected = value.vectorItems ?? []
        #expect(words.count == expected.count, "\(name)")
        for (word, raw) in zip(words, expected) {
            #expect(word.text.unicodeScalars.elementsEqual((raw["text"].vectorString ?? "").unicodeScalars), "\(name)")
            #expect(word.start == raw["start"].vectorNumber && word.end == raw["end"].vectorNumber && word.synthetic, "\(name) \(word.text)")
        }
    }

    @Test func everyVectorIsConsumed() throws {
        let document = try document()
        #expect(Set(document.vectorFields.keys) == Set(Self.categories + ["schema", "constants", "caseCount", "lendableSilenceFuzz", "propertyFuzz", "multiSegmentFuzz"]))
        #expect(try Self.categories.reduce(0) { try $0 + cases($1).count } == Int(document["caseCount"].vectorInteger))
        let constants = document["constants"]
        #expect(constants["SEAM_MIN_GAP"].vectorNumber == VoiceLabPatchConstants.SEAM_MIN_GAP)
        #expect(constants["SEAM_SEARCH_WORDS"].vectorInteger == Int64(VoiceLabPatchConstants.SEAM_SEARCH_WORDS))
        #expect(constants["SEAM_FADE"].vectorNumber == VoiceLabPatchConstants.SEAM_FADE)
        #expect(constants["HARD_SEAM_FADE"].vectorNumber == VoiceLabPatchConstants.HARD_SEAM_FADE)
        #expect(constants["TTS_TRIM_LEAD"].vectorNumber == VoiceLabPatchConstants.TTS_TRIM_LEAD)
        #expect(constants["TTS_TRIM_TAIL"].vectorNumber == VoiceLabPatchConstants.TTS_TRIM_TAIL)
        #expect(constants["PAUSE_SLACK_KEEP"].vectorNumber == VoiceLabPatchConstants.PAUSE_SLACK_KEEP)
        #expect(constants["VOICED_FRAME"].vectorNumber == VoiceLabPatchConstants.VOICED_FRAME)
        #expect(constants["VOICED_FRAME_LEVEL"].vectorNumber == VoiceLabPatchConstants.VOICED_FRAME_LEVEL)
        #expect(constants["ROOM_TONE_MIN_RUN"].vectorNumber == VoiceLabPatchConstants.ROOM_TONE_MIN_RUN)
        #expect(constants["RMS_FRAME"].vectorNumber == VoiceLabPatchConstants.RMS_FRAME)
    }

    /// Replays window-shaped cases through `place`. Every accepted window must validate and prepare in the case's scope,
    /// beside the take's replacements. A case that carries `roomTone` selects that room tone and builds a one-word passage
    /// recipe; one without room tone builds a voice-changer recipe, the minimal recipe that needs none.
    private func replayWindows(_ tests: [JSONValue], requireLend: Bool = false) throws -> (accepted: Int, passages: Int, rendered: Int) {
        var accepted = 0, passages = 0, rendered = 0
        for test in tests {
            let input = test["input"], expected = test["expected"], tone = test["roomTone"]
            let project = try take(input, tone: tone), scope = scope(input), source = envelope(input["envelope"]), rate = input["sampleRate"].vectorNumber
            run(test, {
                if let after = input["afterWordId"].vectorString {
                    return try VoiceLabWindowPlanner.place(project: project, scope: scope, envelope: source, afterWordId: after)
                }
                return try VoiceLabWindowPlanner.place(project: project, scope: scope, envelope: source,
                                                       firstWordId: input["firstWordId"].vectorString ?? "", lastWordId: input["lastWordId"].vectorString ?? "")
            }) { placed, name in
                #expect(placed == window(expected), "\(name)")
                for placement in [placed.leftSeam, placed.rightSeam] {
                    #expect(EditingPrimitives.jsRound(placement.time * rate) == Double(placement.sample), "\(name)")
                }
                accepted += 1
                do {
                    let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: scope, window: placed)
                    if requireLend { try #require(!test["lendableSilence"].isVectorNull, "\(name)") }
                    if !test["lendableSilence"].isVectorNull {
                        func seconds(_ value: JSONValue) -> Double? { value.isVectorNull ? nil : value.vectorNumber }
                        #expect(silence.incoming == seconds(test["lendableSilence"]["incoming"]), "\(name)")
                        #expect(silence.outgoing == seconds(test["lendableSilence"]["outgoing"]), "\(name)")
                    }
                    if tone.isVectorNull {
                        _ = try assemble(project, window: placed, tone: nil, words: nil, trimStart: 0.5, patch: nil, scope: scope)
                    } else {
                        let selected = try VoiceLabRoomToneSelection.select(items: project.transcript?.words ?? [], envelope: source, sourceSampleRate: rate,
                                                                            totalSamples: VoiceLabGeometry.samples(input["durationSeconds"].vectorNumber, rate))
                        #expect(selected == roomTone(tone), "\(name)")
                        let outDuration = Double(placed.endSample - placed.startSample) / rate
                        _ = try assemble(project, window: placed, tone: selected, words: [VoiceLabWord(text: "patch", start: 0, end: outDuration, synthetic: true)],
                                         trimStart: 0.5, patch: "patch", scope: scope)
                        passages += 1
                    }
                    rendered += 1
                } catch { Issue.record("\(name) does not render: \(error)") }
            }
        }
        return (accepted, passages, rendered)
    }

    @Test func windowVectors() throws {
        let (accepted, passages, rendered) = try replayWindows(try cases("window"))
        #expect(passages > 0 && passages < accepted && rendered == accepted)
    }

    /// The committed sample of the property fuzz: every case replays, and every accepted window validates and prepares.
    @Test func propertyCases() throws {
        let document = try document(), fuzz = document["propertyFuzz"], tests = try #require(document["propertyCases"].vectorItems)
        #expect(fuzz["cases"].vectorInteger >= 20_000 && fuzz["renderFailures"].vectorInteger == 0)
        let (accepted, passages, rendered) = try replayWindows(tests, requireLend: true)
        #expect(tests.count == 300 && accepted > 0 && passages == accepted && rendered == accepted)
    }

    /// The committed sample of the multi-segment fuzz: each take already holds one or two replacements that `place` put there,
    /// and every accepted window validates and prepares beside them.
    @Test func multiSegmentCases() throws {
        let document = try document(), fuzz = document["multiSegmentFuzz"], tests = try #require(document["multiSegmentCases"].vectorItems)
        #expect(fuzz["cases"].vectorInteger >= 20_000 && fuzz["renderFailures"].vectorInteger == 0)
        let (accepted, passages, rendered) = try replayWindows(tests, requireLend: true)
        #expect(tests.count == 150 && accepted > 0 && passages == accepted && rendered == accepted)
        #expect(tests.contains { ($0["input"]["segments"].vectorItems ?? []).contains { $0["enabled"].vectorBool == true } })
    }

    /// §8.9.2 lendable silence: each case's window places, validates and prepares, and each gap seam lends the kept source
    /// beside it up to the stop the case names. The fuzz widened every accepted window by what its gap seams lend, less
    /// `PAUSE_SLACK_KEEP`, and every widened window still rendered.
    @Test func lendableSilenceVectors() throws {
        let document = try document(), fuzz = document["lendableSilenceFuzz"], tests = try #require(document["lendableSilence"].vectorItems)
        #expect(fuzz["windows"].vectorInteger >= 20_000 && fuzz["lendingSeams"].vectorInteger > 0)
        let (accepted, _, rendered) = try replayWindows(tests)
        #expect(accepted == tests.count && rendered == accepted)
        func seconds(_ value: JSONValue) -> Double? { value.isVectorNull ? nil : value.vectorNumber }
        for test in tests {
            let input = test["input"], expected = test["lendableSilence"], name = test["name"].vectorString ?? "?"
            let lent = try VoiceLabWindowPlanner.lendableSilence(project: try take(input, tone: test["roomTone"]), scope: scope(input),
                                                                 window: window(test["expected"]))
            #expect(lent.incoming == seconds(expected["incoming"]) && lent.outgoing == seconds(expected["outgoing"]), "\(name)")
        }
    }

    @Test func placedWindowsFeedFitPlannerAndRenderValidator() throws {
        var kinds = Set<VoiceLabSeamKind>()
        for test in try cases("lendableSilence") {
            let input = test["input"], tone = test["roomTone"]
            let project = try take(input, tone: tone), scope = scope(input), rate = input["sampleRate"].vectorNumber
            let placed = try VoiceLabWindowPlanner.place(project: project, scope: scope, envelope: envelope(input["envelope"]),
                                                         firstWordId: input["firstWordId"].vectorString ?? "", lastWordId: input["lastWordId"].vectorString ?? "")
            kinds.formUnion([placed.leftSeam.kind, placed.rightSeam.kind])
            let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: scope, window: placed)
            let take = VoiceLabFitTake(assetFrames: 12_000, assetSampleRate: 24_000, trimStart: 0.02, trimEnd: 0.41,
                                       words: [VoiceLabWord(text: "patch", start: 0.05, end: 0.35, synthetic: true)],
                                       envelope: AudioEnvelope(sampleRate: 24_000, levels: Array(repeating: 0.1, count: 50)))
            let result = try VoiceLabFitPlanner.plan(window: placed, incomingSilence: silence.incoming, outgoingSilence: silence.outgoing,
                                                     take: take, tokens: ["patch"], sourceSampleRate: rate)
            let plan: VoiceLabFitPlan, duration: Double
            switch result {
            case let .exact(value): plan = value; duration = value.windowEnd - value.windowStart
            case let .changedDuration(value, _, residual): plan = value; duration = value.windowEnd - value.windowStart + residual
            }
            var window = placed
            window.start = plan.windowStart; window.end = plan.windowEnd
            window.startSample = plan.windowStartSample; window.endSample = plan.windowEndSample
            let words = tone.isVectorNull ? nil : plan.words
            let (segment, asset) = try passageSegment(project, id: "segment-fitted", window: window, tone: tone.isVectorNull ? nil : roomTone(tone), words: words,
                                                      trimStart: 0.5, patch: words == nil ? nil : "patch", fit: plan, duration: duration)
            var built = project
            built.voiceLab.segments.append(segment); built.voiceLab.assets?.append(asset)
            try VoiceLabProject.validate(built)
            var broken = built
            broken.voiceLab.segments[broken.voiceLab.segments.count - 1].candidates[0].recipe?.audio.trimEnd += 1 / 24_000
            #expect(throws: VoiceLabProjectError.invalidRange) { try VoiceLabRenderValidation.validate(broken) }
        }
        #expect(kinds == Set([.none, .gap, .hard]))
    }

    @Test func millisecondWindowsFitThroughRenderPreparation() throws {
        for variant in ["hard-hard-exact", "take-end-exact", "hard-hard-changed"] {
            let atEnd = variant == "take-end-exact", changed = variant == "hard-hard-changed"
            let rate: Double = 44_100
            var project = try fixture()
            project.media.source.audio?.sampleRate = Int(rate)
            project.media.source.durationSeconds = atEnd ? 3.143 : 4.6
            project.transcript?.words = [
                TimedWord(id: "w0", text: "zero", kind: .word, start: 0.7, end: 1),
                TimedWord(id: "w1", text: "one", kind: .word, start: 1.1, end: 1.4),
                TimedWord(id: "w2", text: "two", kind: .word, start: 1.5, end: 2.1),
                TimedWord(id: "w3", text: "before", kind: .word, start: 2.2, end: 2.5),
                TimedWord(id: "w4", text: "old", kind: .word, start: 2.586, end: 2.75),
                TimedWord(id: "w5", text: "words", kind: .word, start: 2.8, end: 3.113)
            ]
            if !atEnd {
                project.transcript?.words.append(contentsOf: [
                    TimedWord(id: "w6", text: "after", kind: .word, start: 3.2, end: 3.5),
                    TimedWord(id: "w7", text: "seven", kind: .word, start: 3.6, end: 3.8),
                    TimedWord(id: "w8", text: "eight", kind: .word, start: 3.9, end: 4.1),
                    TimedWord(id: "w9", text: "nine", kind: .word, start: 4.2, end: 4.5)
                ])
            }
            project.edits.cutWordIds = []; project.edits.cutPauseIds = []; project.edits.clips = []; project.edits.activeClipId = nil
            project.voiceLab.cleanAudio = VoiceLabCleanAudio(mode: .off)
            let voicedFrames: Int = atEnd ? 255 : 400
            let levels = Array(repeating: Float(0.001), count: 60) + Array(repeating: Float(0.1), count: voicedFrames)
            let sourceEnvelope = AudioEnvelope(sampleRate: rate, levels: levels)
            let placed = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: sourceEnvelope, firstWordId: "w4", lastWordId: "w5")
            #expect(placed.start == 2.556 && placed.end == 3.143, "\(variant)")
            #expect(placed.leftSeam.kind == .hard && placed.rightSeam.kind == (atEnd ? .none : .hard), "\(variant)")
            let silence = try VoiceLabWindowPlanner.lendableSilence(project: project, scope: .full, window: placed)
            let take = VoiceLabFitTake(assetFrames: 16_800, assetSampleRate: 24_000, trimStart: 0.02, trimEnd: changed ? 0.62 : 0.52,
                                       words: [VoiceLabWord(text: "patch", start: 0.05, end: changed ? 0.56 : 0.45, synthetic: true)],
                                       envelope: AudioEnvelope(sampleRate: 24_000, levels: Array(repeating: 0.1, count: 70)))
            let result = try VoiceLabFitPlanner.plan(window: placed, incomingSilence: silence.incoming, outgoingSilence: silence.outgoing,
                                                     take: take, tokens: ["patch"], sourceSampleRate: rate)
            let fitted = result.plan
            let residual: Double
            switch result {
            case .exact: residual = 0; #expect(!changed, "\(variant)")
            case let .changedDuration(_, _, seconds): residual = seconds; #expect(changed, "\(variant)")
            }
            let duration = fitted.windowEnd - fitted.windowStart + residual
            var window = placed
            window.start = fitted.windowStart; window.end = fitted.windowEnd
            window.startSample = fitted.windowStartSample; window.endSample = fitted.windowEndSample
            let total = VoiceLabGeometry.samples(project.media.source.durationSeconds, rate)
            let tone = try VoiceLabRoomToneSelection.select(items: project.transcript!.words, envelope: sourceEnvelope, sourceSampleRate: rate, totalSamples: total)
            var (segment, asset) = try passageSegment(project, id: "segment-ms", window: window, tone: tone, words: fitted.words,
                                                      trimStart: 0.5, patch: "patch", fit: fitted, duration: duration)
            if changed {
                var recipe = try #require(segment.candidates[0].recipe)
                recipe.video.mode = .zoomCover
                let sourceSamples = Double(fitted.windowEndSample - fitted.windowStartSample)
                let outputSamples = Double(recipe.video.outputSamples)
                recipe.video.retimeFactor = sourceSamples / outputSamples
                recipe.video.zoom = 1.12; recipe.video.faceX = 0.5; recipe.video.faceY = 0.5
                segment.candidates[0].recipe = recipe
            }
            project.voiceLab.segments = [segment]; project.voiceLab.assets = [asset]
            try VoiceLabProject.validate(project); try VoiceLabRenderValidation.validate(project)
            let output = try VoiceLabOutputPlanner.build(project, scope: .full)
            let synth = try #require(output.pieces.first { $0.kind == .synth })
            let prepared = try VoiceLabRenderContract.prepare(project, scope: .full, labelPosition: .topRight)
            if changed {
                #expect(prepared.selectedSegmentRecipes.first?.recipe.video.mode == .zoomCover)
                #expect(throws: VoiceLabProjectError.videoModeUnsupported) {
                    try VoiceLabRenderInput(project: project, scope: .full, labelPosition: .topRight,
                                            paidRoot: URL(fileURLWithPath: "/not-opened"), prepared: prepared)
                }
            } else {
                #expect(synth.sourceEndSample - synth.sourceStartSample == synth.outputEndSample - synth.outputStartSample, "\(variant)")
                #expect(prepared.selectedSegmentRecipes.first?.recipe.video.mode == .source, "\(variant)")
            }
        }
    }

    @Test func handleVectors() throws {
        for test in try cases("handles") {
            let input = test["input"], expected = test["expected"]
            let kind = VoiceLabSeamKind(rawValue: input["kind"].vectorString ?? "") ?? .none, fade = input["fadeSamples"].vectorInteger
            let incoming = input["incoming"].vectorBool ?? false, assetRate = Int(input["assetSampleRate"].vectorInteger)
            let sourceRate = input["sourceSampleRate"].vectorNumber, stretch = input["stretch"].vectorNumber
            run(test, {
                try (VoiceLabHandles.minimum(fadeSamples: fade, incoming: incoming, assetSampleRate: assetRate, sourceSampleRate: sourceRate, stretch: stretch),
                     VoiceLabHandles.seam(kind: kind, fadeSamples: fade, incoming: incoming, assetSampleRate: assetRate, sourceSampleRate: sourceRate, stretch: stretch))
            }) { result, name in
                #expect(result.0.assetFrames == expected["assetFrames"].vectorInteger && result.0.sourceSamples == expected["sourceSamples"].vectorInteger, "\(name)")
                #expect(result.1 == seam(expected["seam"]), "\(name)")
            }
        }
    }

    @Test func trimHandleVectors() throws {
        for test in try cases("trimHandles") {
            let input = test["input"], seams = input["seams"]
            run(test, {
                try VoiceLabHandles.checkTrim(seams: VoiceLabSeams(in: seam(seams["in"]), out: seam(seams["out"])), trimStart: input["trimStart"].vectorNumber,
                                              trimEnd: input["trimEnd"].vectorNumber, assetDurationSeconds: input["assetDurationSeconds"].vectorNumber,
                                              assetSampleRate: Int(input["assetSampleRate"].vectorInteger))
            }) { _, name in #expect(test["expected"]["ok"].vectorBool == true, "\(name)") }
        }
    }

    @Test func alignmentVectors() throws {
        for test in try cases("alignment") {
            let input = test["input"]
            run(test, {
                try VoiceLabAlignment.words(characters: input["characters"].vectorStrings, starts: input["starts"].vectorItems?.map(\.vectorNumber),
                                            ends: input["ends"].vectorItems?.map(\.vectorNumber), expectedText: input["expectedText"].vectorString ?? "")
            }) { words, name in expectWords(words, test["expected"]["words"], name) }
        }
    }

    @Test func trimVectors() throws {
        for test in try cases("trim") {
            let input = test["input"], expected = test["expected"], duration = input["assetDuration"].vectorNumber
            run(test, {
                try input["envelope"].isVectorNull ? VoiceLabAlignment.trim(words: voiceWords(input["words"]), assetDuration: duration)
                    : VoiceLabAlignment.trim(envelope: envelope(input["envelope"]), assetDuration: duration)
            }) { trim, name in #expect(trim.start == expected["start"].vectorNumber && trim.end == expected["end"].vectorNumber, "\(name)") }
        }
    }

    @Test func relativeWordVectors() throws {
        for test in try cases("relativeWords") {
            let input = test["input"]
            run(test, {
                try VoiceLabAlignment.relativeWords(words: voiceWords(input["words"]), trimStart: input["trimStart"].vectorNumber, stretch: input["stretch"].vectorNumber,
                                                    outDuration: input["outDuration"].vectorNumber, sourceSampleRate: input["sourceSampleRate"].vectorNumber)
            }) { words, name in expectWords(words, test["expected"]["words"], name) }
        }
    }

    @Test func roomToneVectors() throws {
        for test in try cases("roomTone") {
            let input = test["input"], expected = test["expected"]
            run(test, {
                try VoiceLabRoomToneSelection.select(items: items(input["words"]), envelope: envelope(input["envelope"]),
                                                     sourceSampleRate: input["sampleRate"].vectorNumber, totalSamples: input["totalSamples"].vectorInteger)
            }) { tone, name in
                #expect(tone == VoiceLabRoomTone(sourceStartSample: expected["sourceStartSample"].vectorInteger, sourceEndSample: expected["sourceEndSample"].vectorInteger,
                                                 gainDb: expected["gainDb"].vectorNumber), "\(name)")
            }
        }
    }

    /// A five-word patch aligned by the §8.8 loop and placed on the window's output clock, then assembled.
    private func prepareRecipe(_ project: Project, window: VoiceLabWindow, tone: VoiceLabRoomTone,
                               id: String = "segment-window") throws -> (Project, VoiceLabPreparedRender) {
        let rate = Double(try #require(project.media.source.audio?.sampleRate))
        let patch = "new words uh the clipper."
        var characters: [String] = [], starts: [Double] = [], ends: [Double] = [], clock = 0.25
        for character in patch {
            characters.append(String(character)); starts.append(clock)
            clock += character == " " ? 0.02 : 0.09
            ends.append(clock)
        }
        let aligned = try VoiceLabAlignment.words(characters: characters, starts: starts, ends: ends, expectedText: patch)
        #expect(aligned.map(\.text) == ["new", "words", "uh", "the", "clipper."])
        let outDuration = Double(window.endSample - window.startSample) / rate
        let trimStart = try VoiceLabAlignment.trim(words: aligned, assetDuration: 4).start
        let relative = try VoiceLabAlignment.relativeWords(words: aligned, trimStart: trimStart, stretch: 1, outDuration: outDuration, sourceSampleRate: rate)
        return try assemble(project, window: window, tone: tone, words: relative, trimStart: trimStart, patch: patch, id: id)
    }

    /// The selected recipe a candidate would carry for `window`, built only from the geometry above, as segment `id` with its
    /// own asset. The asset holds `trimStart` seconds before the passage and 0.5 s after it. Without `words` the segment is a
    /// voice changer, which carries no text, words or room tone.
    private func passageSegment(_ project: Project, id: String, window: VoiceLabWindow, tone: VoiceLabRoomTone?, words: [VoiceLabWord]?,
                                trimStart: Double, patch: String?, fit: VoiceLabFitPlan? = nil, duration: Double? = nil) throws -> (VoiceLabSegment, VoiceLabAsset) {
        let rate = Double(try #require(project.media.source.audio?.sampleRate))
        let assetRate: Double = 24_000
        let windowSamples: Int64 = window.endSample - window.startSample
        let windowSampleCount: Double = Double(windowSamples)
        let sourceDuration: Double = windowSampleCount / rate
        let outDuration: Double = duration ?? sourceDuration
        let windowFrameCount: Double = windowSampleCount * assetRate / rate
        let roundedWindowFrames: Double = EditingPrimitives.jsRound(windowFrameCount)
        let windowFrames: Int64 = Int64(roundedWindowFrames)
        let frames: Int64 = fit?.outputFrames ?? windowFrames
        let trimStartFrame: Int64 = VoiceLabGeometry.samples(trimStart, assetRate)
        let trimEndFrame: Int64 = trimStartFrame + frames
        let trimEndFrameCount: Double = Double(trimEndFrame)
        let trimEnd: Double = trimEndFrameCount / assetRate
        let assetDuration: Double = trimEnd + 0.5
        let seams = VoiceLabSeams(
            in: try VoiceLabHandles.seam(kind: window.leftSeam.kind, fadeSamples: window.leftSeam.fadeSamples, incoming: true,
                                         assetSampleRate: 24_000, sourceSampleRate: rate, stretch: 1),
            out: try VoiceLabHandles.seam(kind: window.rightSeam.kind, fadeSamples: window.rightSeam.fadeSamples, incoming: false,
                                          assetSampleRate: 24_000, sourceSampleRate: rate, stretch: 1))
        try VoiceLabHandles.checkTrim(seams: seams, trimStart: trimStart, trimEnd: trimEnd, assetDurationSeconds: assetDuration, assetSampleRate: 24_000)

        let asset = VoiceLabAsset(id: "asset-" + id, file: project.id + "/asset-" + id + ".wav", sha256: String(repeating: "ab", count: 32),
                                  durationSeconds: assetDuration, sampleRate: 24_000, createdAt: Date(timeIntervalSince1970: 1_793_000_000))
        var segment = try #require(Self.passage?.voiceLab.segments.first)
        var recipe = try #require(segment.candidates[0].recipe)
        recipe.audio = VoiceLabAudio(assetId: asset.id, trimStart: trimStart, trimEnd: trimEnd, stretch: 1, gainDb: 0)
        recipe.words = words
        recipe.outDuration = outDuration
        recipe.chunks = [VoiceLabChunk(sourceStartSample: window.startSample, sourceEndSample: window.endSample, requestId: "request-" + id,
                                       seed: recipe.seed, assetId: asset.id, assetSha256: asset.sha256,
                                       assembledStartFrame: VoiceLabGeometry.samples(trimStart, 24_000), assembledEndFrame: VoiceLabGeometry.samples(trimEnd, 24_000))]
        recipe.roomTone = tone
        recipe.seams = seams
        recipe.video = VoiceLabVideoRecipe(mode: .source, sourceStartSample: window.startSample, sourceEndSample: window.endSample,
                                           outputSamples: VoiceLabGeometry.samples(outDuration, rate), retimeFactor: nil, zoom: nil, faceX: nil, faceY: nil,
                                           assetId: nil, provider: nil, model: nil, requestId: nil, windowStartSample: nil, windowEndSample: nil, syncMode: nil)
        if let words { recipe.qa.transcriptTokens = words.count }
        segment.id = id
        segment.kind = words == nil ? .voiceChanger : .tts
        segment.replace = VoiceLabReplacement(start: window.start, end: window.end, firstWordId: window.firstWordId, lastWordId: window.lastWordId)
        segment.text = patch.map { VoiceLabText(original: "we ship uh the clipper.", new: $0) }
        segment.audio = recipe.audio; segment.outDuration = recipe.outDuration; segment.words = recipe.words
        segment.candidates = [VoiceLabCandidate(assetId: asset.id, score: 0.9)]
        segment.candidates[0].recipe = recipe
        segment.selectedCandidateIndex = 0
        return (segment, asset)
    }

    /// Adds the recipe for `window` to the project's replacements as segment `id`, then validates and prepares the project
    /// in `scope`.
    private func assemble(_ project: Project, window: VoiceLabWindow, tone: VoiceLabRoomTone?, words: [VoiceLabWord]?, trimStart: Double,
                          patch: String?, scope: VoiceLabOutputScope = .full, id: String = "segment-window") throws -> (Project, VoiceLabPreparedRender) {
        let (segment, asset) = try passageSegment(project, id: id, window: window, tone: tone, words: words, trimStart: trimStart, patch: patch)
        var built = project
        built.voiceLab.segments.append(segment)
        built.voiceLab.assets = (built.voiceLab.assets ?? []) + [asset]
        try VoiceLabProject.validate(built)
        return (built, try VoiceLabRenderContract.prepare(built, scope: scope, labelPosition: .topLeft))
    }

    /// 10 ms frames at speech level wherever an item overlaps them, room level elsewhere.
    private func envelopeLevels(_ words: [TimedWord], frames: Int64) -> [Float] {
        (0..<Int(frames)).map { index in words.contains(where: { $0.start * 100 < Double(index + 1) && $0.end * 100 > Double(index) }) ? 0.25 : 0.0078125 }
    }

    /// A passage recipe built only from the geometry above validates and prepares; one short handle is refused.
    @Test func builtRecipeValidatesAndPrepares() throws {
        var project = try fixture()
        project.media.source.audio?.sampleRate = 48_000
        let rate = 48_000.0, duration = project.media.source.durationSeconds, total = VoiceLabGeometry.samples(duration, rate)
        let words = try #require(project.transcript?.words)
        var levels = envelopeLevels(words, frames: total / 480)
        levels[230] = 0.0009765625; levels[480] = 0.0009765625
        for index in 600..<650 { levels[index] = 0.00048828125 }
        let source = AudioEnvelope(sampleRate: rate, levels: levels)
        // The fixture's own replacement covers w4..w5: a window over it is refused, not stored beside it.
        var original = try #require(Self.passage)
        original.media.source.audio?.sampleRate = 48_000
        #expect(throws: VoiceLabGeometryError.overlapsReplacement("vl-passage")) {
            try VoiceLabWindowPlanner.place(project: original, scope: .full, envelope: source, firstWordId: "w4", lastWordId: "w5")
        }
        let window = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: source, firstWordId: "w4", lastWordId: "w5")
        #expect(window.startSample == 230 * 480 + 240 && window.endSample == 480 * 480 + 240)
        #expect(window.leftBridgeWordIds.isEmpty && window.rightBridgeWordIds == ["w6", "w7", "w8"] && window.lastWordId == "w8")
        let tone = try VoiceLabRoomToneSelection.select(items: words, envelope: source, sourceSampleRate: rate, totalSamples: total)
        #expect(tone == VoiceLabRoomTone(sourceStartSample: 600 * 480, sourceEndSample: 650 * 480, gainDb: 0))
        let (built, prepared) = try prepareRecipe(project, window: window, tone: tone)
        let seams = try #require(built.voiceLab.segments[0].candidates[0].recipe?.seams)
        #expect(seams.in == VoiceLabSeam(kind: .gap, fadeSamples: 960, sourceHandleSamples: 480, assetHandleFrames: 240))
        #expect(prepared.selectedSegmentRecipes.count == 1 && prepared.outputPlan.outputSamples == total)
        var broken = built
        broken.voiceLab.segments[0].candidates[0].recipe?.seams.in.assetHandleFrames -= 1
        #expect(throws: VoiceLabProjectError.invalidFadeHandles) { try VoiceLabProject.validate(broken) }
        #expect(throws: VoiceLabProjectError.invalidFadeHandles) { try VoiceLabRenderContract.prepare(broken, scope: .full, labelPosition: .topLeft) }
        broken = built
        broken.voiceLab.segments[0].candidates[0].recipe?.seams.out.sourceHandleSamples -= 1
        #expect(throws: VoiceLabProjectError.invalidFadeHandles) { try VoiceLabProject.validate(broken) }
    }

    /// Re-voicing the sentences before and after an accepted replacement. Each new window keeps its fade clear of the
    /// replacement's own, and the project holding all three validates and prepares.
    @Test func neighbourRecipesValidateAndPrepare() throws {
        var project = try fixture()
        project.media.source.audio?.sampleRate = 48_000
        let rate = 48_000.0, total = VoiceLabGeometry.samples(project.media.source.durationSeconds, rate)
        let words = try #require(project.transcript?.words)
        var levels = envelopeLevels(words, frames: total / 480)
        levels[230] = 0.0009765625; levels[480] = 0.0009765625
        for index in 600..<650 { levels[index] = 0.00048828125 }
        let source = AudioEnvelope(sampleRate: rate, levels: levels)
        let tone = try VoiceLabRoomToneSelection.select(items: words, envelope: source, sourceSampleRate: rate, totalSamples: total)
        let accepted = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: source, firstWordId: "w4", lastWordId: "w5")
        let (withAccepted, _) = try prepareRecipe(project, window: accepted, tone: tone, id: "segment-accepted")
        let after = try VoiceLabWindowPlanner.place(project: withAccepted, scope: .full, envelope: source, firstWordId: "w9", lastWordId: "w9")
        #expect(after.leftSeam.kind == .gap && after.startSample >= accepted.endSample + 960)
        let (withAfter, _) = try prepareRecipe(withAccepted, window: after, tone: tone, id: "segment-after")
        let before = try VoiceLabWindowPlanner.place(project: withAfter, scope: .full, envelope: source, firstWordId: "w3", lastWordId: "w3")
        #expect(before.rightSeam.kind == .gap && before.endSample + 960 <= accepted.startSample)
        let prepared = try prepareRecipe(withAfter, window: before, tone: tone, id: "segment-before").1
        #expect(prepared.selectedSegmentRecipes.map(\.segmentId) == ["segment-before", "segment-accepted", "segment-after"])
        // Placed again on its own words, the accepted passage now overlaps itself.
        #expect(throws: VoiceLabGeometryError.overlapsReplacement("segment-accepted")) {
            try VoiceLabWindowPlanner.place(project: withAfter, scope: .full, envelope: source, firstWordId: "w6", lastWordId: "w7")
        }
    }

    /// An edit after acceptance: cutting the pause after w8 removes the kept source after the accepted replacement's seam, so
    /// its fade now crosses the cut, and prepare still renders it. Re-voicing w1 is judged on its own and renders beside it.
    @Test func cutAfterAcceptanceRecipeValidatesAndPrepares() throws {
        var project = try fixture()
        project.media.source.audio?.sampleRate = 48_000
        let rate = 48_000.0, total = VoiceLabGeometry.samples(project.media.source.durationSeconds, rate)
        let words = try #require(project.transcript?.words)
        var levels = envelopeLevels(words, frames: total / 480)
        levels[230] = 0.0009765625; levels[480] = 0.0009765625
        for index in 600..<650 { levels[index] = 0.00048828125 }
        let source = AudioEnvelope(sampleRate: rate, levels: levels)
        let tone = try VoiceLabRoomToneSelection.select(items: words, envelope: source, sourceSampleRate: rate, totalSamples: total)
        let accepted = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: source, firstWordId: "w4", lastWordId: "w5")
        var withAccepted = try prepareRecipe(project, window: accepted, tone: tone, id: "segment-accepted").0
        withAccepted.edits.cutPauseIds = ["pause-after-w8"]
        let alone = try VoiceLabRenderContract.prepare(withAccepted, scope: .full, labelPosition: .topLeft).outputPlan.pieces
        #expect(alone.map(\.sourceStartSample) == [0, accepted.startSample, 256_800])
        let first = try VoiceLabWindowPlanner.place(project: withAccepted, scope: .full, envelope: source, firstWordId: "w1", lastWordId: "w1")
        #expect(first.startSample == 0 && first.endSample == 98_160)
        let pieces = try prepareRecipe(withAccepted, window: first, tone: tone, id: "segment-first").1.outputPlan.pieces
        #expect(pieces.map(\.kind) == [.synth, .source, .synth, .source])
        #expect(pieces.map(\.sourceStartSample) == [0, 98_160, accepted.startSample, 256_800])
    }

    /// A whole take whose duration is off the 44.1 kHz grid: both seams are `none`, at 0 and exactly at `durationSeconds`.
    @Test func takeEdgeRecipeValidatesAndPrepares() throws {
        var project = try fixture()
        let rate = 44_100.0, duration = 1237.0 / 600.0, total = VoiceLabGeometry.samples(duration, rate)
        #expect(total == 90_920 && Double(total) / rate > duration)
        project.media.source.audio?.sampleRate = 44_100
        project.media.source.durationSeconds = duration
        project.transcript?.words = [TimedWord(id: "w1", text: "we", start: 0, end: 0.6), TimedWord(id: "w2", text: "ship", start: 1.2, end: 1.5),
                                     TimedWord(id: "w3", text: "it", start: 1.6, end: duration)]
        project.edits.clips = []
        project.edits.activeClipId = nil
        let words = try #require(project.transcript?.words)
        let source = AudioEnvelope(sampleRate: rate, levels: envelopeLevels(words, frames: total / 441))
        let window = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: source, firstWordId: "w1", lastWordId: "w3")
        #expect(window.leftSeam == VoiceLabSeamPlacement(kind: .none, time: 0, sample: 0, fadeSamples: 0))
        #expect(window.rightSeam == VoiceLabSeamPlacement(kind: .none, time: duration, sample: total, fadeSamples: 0))
        let tone = try VoiceLabRoomToneSelection.select(items: words, envelope: source, sourceSampleRate: rate, totalSamples: total)
        let (_, prepared) = try prepareRecipe(project, window: window, tone: tone)
        #expect(prepared.outputPlan.pieces.count == 1 && prepared.outputPlan.outputSamples == total)
    }

    /// A cut word next to the window. Its quietest frame would fade into the cut's reach, so the seam takes the next frame,
    /// and the kept source between the cut and the seam still holds half the fade.
    @Test func cutNeighbourRecipeValidatesAndPrepares() throws {
        var project = try fixture()
        project.media.source.audio?.sampleRate = 48_000
        project.edits.cutWordIds = ["w3"]
        let rate = 48_000.0, duration = project.media.source.durationSeconds, total = VoiceLabGeometry.samples(duration, rate)
        let words = try #require(project.transcript?.words)
        var levels = envelopeLevels(words, frames: total / 480)
        levels[160] = 0.00048828125; levels[161] = 0.0009765625; levels[480] = 0.0009765625
        for index in 600..<650 { levels[index] = 0.00048828125 }
        let source = AudioEnvelope(sampleRate: rate, levels: levels)
        let window = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: source, firstWordId: "w4", lastWordId: "w5")
        // w3's cut reaches 0.1 s past 1.5 s, to sample 76800; frame 160's fade would start 240 samples inside it.
        #expect(window.startSample == 161 * 480 + 240)
        let tone = try VoiceLabRoomToneSelection.select(items: words, envelope: source, sourceSampleRate: rate, totalSamples: total)
        let pieces = try prepareRecipe(project, window: window, tone: tone).1.outputPlan.pieces
        let synth = try #require(pieces.firstIndex(where: { $0.kind == .synth }))
        #expect(pieces[synth - 1].sourceStartSample == 76_800 && pieces[synth - 1].sourceEndSample == window.startSample)
    }

    /// The core use: a cut filler at 0.0 s before a rewrite of the first sentence. The window absorbs the filler and starts at
    /// the take start, so no fade crosses the cut and the synth is the first output piece.
    @Test func cutFillerAtTakeStartRecipeValidatesAndPrepares() throws {
        var project = try fixture()
        project.media.source.audio?.sampleRate = 48_000
        project.transcript?.words.insert(TimedWord(id: "um", text: "um", start: 0, end: 0.25), at: 0)
        project.edits.cutWordIds = ["um"]
        let rate = 48_000.0, total = VoiceLabGeometry.samples(project.media.source.durationSeconds, rate)
        let words = try #require(project.transcript?.words)
        let source = AudioEnvelope(sampleRate: rate, levels: envelopeLevels(words, frames: total / 480))
        let window = try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: source, firstWordId: "w1", lastWordId: "w2")
        #expect(window.leftSeam == VoiceLabSeamPlacement(kind: .none, time: 0, sample: 0, fadeSamples: 0))
        #expect(window.firstWordId == "um" && window.leftBridgeWordIds.isEmpty && window.rightBridgeWordIds == ["w3"])
        let tone = try VoiceLabRoomToneSelection.select(items: words, envelope: source, sourceSampleRate: rate, totalSamples: total)
        let pieces = try prepareRecipe(project, window: window, tone: tone).1.outputPlan.pieces
        #expect(pieces.first?.kind == .synth && pieces.first?.sourceStartSample == 0 && pieces.first?.sourceEndSample == window.endSample)
    }

    @Test func insertionAndInvalidInputAreTyped() throws {
        var project = try fixture()
        let words = [TimedWord(id: "w1", text: "a", start: 0.2, end: 0.5), TimedWord(id: "w2", text: "b", start: 0.7, end: 0.9)]
        project.media.source.durationSeconds = 1
        project.transcript?.words = words
        let source = AudioEnvelope(sampleRate: 1_000, levels: [Float](repeating: 0.01, count: 100))
        #expect(throws: VoiceLabGeometryError.insertionUnsupported) {
            try VoiceLabWindowPlanner.place(project: project, scope: .full, envelope: source, afterWordId: "w1")
        }
        var invalid = [project, project, project, project, project]
        invalid[0].transcript?.words.append(TimedWord(id: "w1", text: "c", start: 0.95, end: 0.99))
        invalid[1].edits.pauseThresholdSeconds = 0
        invalid[2].edits.pauseKeepSeconds = 1.5
        // The project transcript rule: starts in order and every item longer than zero.
        invalid[3].transcript?.words.append(TimedWord(id: "w3", text: "c", start: 0.6, end: 0.99))
        invalid[4].transcript?.words.append(TimedWord(id: "w3", text: "c", start: 0.95, end: 0.95))
        for take in invalid {
            #expect(throws: VoiceLabGeometryError.invalidInput()) {
                try VoiceLabWindowPlanner.place(project: take, scope: .full, envelope: source, firstWordId: "w2", lastWordId: "w2")
            }
        }
        // An unknown clip, and the fixture's clip, whose words this take does not have.
        for scope in [VoiceLabOutputScope.clip("missing"), .clip("clip-main")] {
            #expect(throws: VoiceLabGeometryError.invalidInput()) {
                try VoiceLabWindowPlanner.place(project: project, scope: scope, envelope: source, firstWordId: "w2", lastWordId: "w2")
            }
        }
        #expect(throws: VoiceLabGeometryError.invalidInput()) {
            try VoiceLabRoomToneSelection.select(items: words, envelope: AudioEnvelope(sampleRate: 1_000, levels: []), sourceSampleRate: 1_000, totalSamples: 1_000)
        }
        #expect(throws: VoiceLabGeometryError.invalidInput()) {
            try VoiceLabHandles.minimum(fadeSamples: 20, incoming: true, assetSampleRate: 24_000, sourceSampleRate: 1_000, stretch: .nan)
        }
        #expect(throws: VoiceLabGeometryError.alignmentUnavailable) {
            try VoiceLabAlignment.relativeWords(words: [], trimStart: 0, stretch: 1, outDuration: 1, sourceSampleRate: 1_000)
        }
    }
}
