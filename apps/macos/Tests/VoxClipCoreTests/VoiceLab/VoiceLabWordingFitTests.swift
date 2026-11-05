import Foundation
import Testing
@testable import VoxClipCore

@Suite(.offlineFixtures) struct VoiceLabWordingFitTests {
    /// One phrase the fit request can't take names its check, so the App drops just that phrase (priced as written)
    /// and logs the check, instead of the whole fit failing with invalidInput (MVP25, 2026-11-05).
    @Test func aRefusedPhraseNamesItsCheck() async throws {
        let target = try VoiceLabWordingFit.wordTarget(wordsPerSecond: 2, multiplier: 1, minimumSeconds: 1, maximumSeconds: 2, overheadSeconds: 0)
        func phrase(original: String = "a similar way", proposed: String = "I use a similar method as",
                    slot: Double = 2, direction: String = "shorter") -> VoiceLabFitPhrase {
            VoiceLabFitPhrase(ordinal: 1, original: original, proposed: proposed, estimateSeconds: 3, slotSeconds: slot,
                direction: direction, target: target, calibrated: true)
        }
        #expect(VoiceLabWordingFitService.refusal(phrase()) == nil)
        #expect(VoiceLabWordingFitService.refusal(phrase(original: "")) == "original_empty")
        #expect(VoiceLabWordingFitService.refusal(phrase(proposed: "")) == "proposed_empty")
        #expect(VoiceLabWordingFitService.refusal(phrase(slot: 0)) == "slot")
        #expect(VoiceLabWordingFitService.refusal(phrase(direction: "sideways")) == "direction")
        // The request refuses exactly what refusal names.
        let service = VoiceLabWordingFitService(shared: try SharedResources.locate())
        await #expect(throws: VoiceLabError.invalidInput) {
            _ = try await service.request([phrase(), phrase(slot: 0)], connector: .ollama, language: "en")
        }
    }

    struct Vectors: Decodable {
        struct Target: Decodable {
            struct Input: Decodable {
                let wordsPerSecond: Double; let multiplier: Double; let minimumSeconds: Double
                let maximumSeconds: Double; let overheadSeconds: Double; let bridgeWords: Int
            }
            let id: String; let input: Input; let expected: VoiceLabWordTarget
        }
        struct Calibration: Decodable { let ratios: [Double]; let expected: Double }
        struct Round: Decodable {
            let roundsCompleted: Int; let candidates: [Int]; let fitting: [Int]; let kept: [Int]
            let stopped: Bool; let expected: [Int]
        }
        struct Request: Decodable {
            struct Expected: Decodable { let system: String; let cachedBlock: String; let instruction: String; let schemaName: String; let schema: JSONValue }
            let phrase: VoiceLabFitPhrase; let expected: Expected
        }
        let targets: [Target]; let calibration: [Calibration]; let rounds: [Round]; let requests: [Request]
    }

    @Test func longerShorterAndMeasuredPromptGoldens() async throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data("fixtures/voice-lab/autofit-cases.json"))
        let service = VoiceLabWordingFitService(shared: try SharedResources.locate())
        for row in vectors.requests {
            let request = try await service.request([row.phrase], connector: .ollama, language: "en")
            #expect(request.system == row.expected.system)
            #expect(request.cachedBlock == row.expected.cachedBlock)
            #expect(request.instruction == row.expected.instruction)
            #expect(request.schemaName == row.expected.schemaName)
            #expect(request.schema == row.expected.schema)
        }
    }

    @Test func sharedWordTargetsCalibrationAndRoundSelection() throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data("fixtures/voice-lab/autofit-cases.json"))
        for row in vectors.targets {
            let input = row.input
            #expect(try VoiceLabWordingFit.wordTarget(wordsPerSecond: input.wordsPerSecond, multiplier: input.multiplier,
                minimumSeconds: input.minimumSeconds, maximumSeconds: input.maximumSeconds, overheadSeconds: input.overheadSeconds,
                bridgeWords: input.bridgeWords) == row.expected, "\(row.id)")
        }
        for row in vectors.calibration {
            let samples = row.ratios.enumerated().map { VoiceLabRateSample(id: String($0.offset), ratio: $0.element) }
            #expect(VoiceLabWordingFit.multiplier(samples) == row.expected)
        }
        for row in vectors.rounds {
            #expect(VoiceLabWordingFit.nextOrdinals(roundsCompleted: row.roundsCompleted, candidates: row.candidates,
                fitting: Set(row.fitting), kept: Set(row.kept), stopped: row.stopped) == row.expected)
        }
    }

    @Test func calibrationKeepsTenDistinctMeasuredTakesAndIgnoresBadMeasurements() throws {
        var samples: [VoiceLabRateSample] = []
        for index in 0..<12 {
            samples = VoiceLabWordingFit.recording(samples, id: String(index), measured: Double(index + 1), estimated: 1)
        }
        #expect(samples.count == 10)
        #expect(samples.first?.id == "2")
        #expect(VoiceLabWordingFit.multiplier(samples) == 7.5)
        #expect(VoiceLabWordingFit.recording(samples, id: "11", measured: 1, estimated: 1) == samples)
        #expect(VoiceLabWordingFit.recording(samples, id: "bad", measured: .nan, estimated: 1) == samples)
        #expect(VoiceLabWordingFit.recording(samples, id: "bad", measured: 1, estimated: 0) == samples)
        #expect(VoiceLabWordingFit.multiplier([.init(id: "bad", ratio: .infinity)]) == 1)
        #expect(throws: VoiceLabLengthBudgetError.self) {
            try VoiceLabWordingFit.wordTarget(wordsPerSecond: .nan, multiplier: 1, minimumSeconds: 1, maximumSeconds: 2, overheadSeconds: 0)
        }
    }

    @Test func oldVoiceLabDecodesAndOptionalCalibrationRoundTripsWithoutChangingSegments() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let old = try decoder.decode(ProjectVoiceLab.self, from: Data(#"{"segments":[]}"#.utf8))
        #expect(old.speakingRateSamples == nil)
        #expect(try JSONSerialization.jsonObject(with: encoder.encode(old)) as? NSDictionary == ["segments": []] as NSDictionary)
        var calibrated = old
        calibrated.speakingRateSamples = ["eleven_v4": [.init(id: "a", ratio: 1.2), .init(id: "b", ratio: 1.4)],
                                         "eleven_multilingual_v2": [.init(id: "legacy", ratio: 0.8)]]
        #expect(try decoder.decode(ProjectVoiceLab.self, from: encoder.encode(calibrated)) == calibrated)
        #expect(calibrated.segments == old.segments)
    }

    @Test func oldV2ProjectRecipesStillOpenAndPrepareForRendering() throws {
        let data = try FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip")
        let source = try #require(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "fixture-model", with: "eleven_multilingual_v2")
        let project = try JSONProjectStore.decode(Data(source.utf8))
        #expect(project.voiceLab.speakingRateSamples == nil)
        let opened = try ProjectJSON.decode(ProjectJSON.encode(project))
        #expect(opened == project)
        let render = try VoiceLabRenderContract.prepare(opened, scope: .full, labelPosition: .topRight)
        #expect(render.outputPlan.outputSamples == 7_000 && render.selectedSegmentRecipes.count == 1)
        try render.verify(project: opened, scope: .full, labelPosition: .topRight)
        var calibrated = opened
        calibrated.voiceLab.speakingRateSamples = ["eleven_v4": [.init(id: "first", ratio: 1.1), .init(id: "second", ratio: 1.3)]]
        #expect(try ProjectJSON.decode(ProjectJSON.encode(calibrated)) == calibrated)
        for invalid in [[VoiceLabRateSample(id: "", ratio: 1)], [.init(id: "bad", ratio: 0)],
                        [.init(id: "bad", ratio: .infinity)], Array(repeating: .init(id: "many", ratio: 1), count: 11)] {
            calibrated.voiceLab.speakingRateSamples = ["eleven_v4": invalid]
            #expect(throws: (any Error).self) { try ProjectJSON.encode(calibrated) }
        }
    }

    @Test func fitServiceUsesStructuredKeepOriginalAndRejectsFrozenOrDuplicatePhrases() async throws {
        let shared = try SharedResources.locate()
        let service = VoiceLabWordingFitService(shared: shared)
        let target = try VoiceLabWordingFit.wordTarget(wordsPerSecond: 2, multiplier: 1, minimumSeconds: 1, maximumSeconds: 2, overheadSeconds: 0.15)
        let phrases = [VoiceLabFitPhrase(ordinal: 2, original: "The original words", proposed: "The current proposal",
            estimateSeconds: 3, slotSeconds: 2, direction: "shorter", target: target)]
        let request = try await service.request(phrases, connector: .ollama, language: "en")
        #expect(request.tag == "voice-rewrite-fit")
        #expect(request.cachedBlock?.contains("Phrase 2") == true)
        #expect(request.cachedBlock?.contains("fewer words") == true)
        for (response, valid) in [
            (#"{"phrases":[{"ordinal":2,"action":"keepOriginal","text":""}]}"#, true),
            (#"{"phrases":[{"ordinal":2,"action":"reword","text":"Shorter words"}]}"#, true),
            (#"{"phrases":[{"ordinal":1,"action":"reword","text":"Frozen phrase"}]}"#, false),
            (#"{"phrases":[{"ordinal":2,"action":"keepOriginal","text":"not empty"}]}"#, false),
            (#"{"phrases":[{"ordinal":2,"action":"keep the original words","text":""}]}"#, false),
            (#"{"phrases":[{"ordinal":2,"action":"reword","text":"[laughs] Nope"}]}"#, false),
            (#"{"phrases":[{"ordinal":2,"action":"reword","text":"One"},{"ordinal":2,"action":"reword","text":"Two"}]}"#, false)
        ] {
            let connector = WordingFitStub(reply: response)
            let quote = try await service.prepare(phrases, connector: connector.id, model: "fixture", language: "en")
            do {
                let result = try await service.propose(phrases, connector: connector, model: "fixture", language: "en", quote: quote, approved: true)
                #expect(valid)
                #expect(result.count == 1)
            } catch { #expect(!valid, "\(error)") }
        }
    }

    /// A measured round rewords the whole phrase, so the request names its bridge words as required, from the shared
    /// template, and the reply is checked as the take's preflight checks it. Without bridge words the request and its
    /// fingerprint are unchanged (the shared request goldens).
    @Test func bridgeWordsAreRequiredInTheRequestAndCheckedAsThePreflightChecksThem() async throws {
        let shared = try SharedResources.locate()
        let service = VoiceLabWordingFitService(shared: shared)
        let target = try VoiceLabWordingFit.wordTarget(wordsPerSecond: 2, multiplier: 1, minimumSeconds: 1, maximumSeconds: 2, overheadSeconds: 0)
        var phrase = VoiceLabFitPhrase(ordinal: 1, original: "a similar way", proposed: "I use a similar method as",
            estimateSeconds: 3, slotSeconds: 2, direction: "shorter", target: target, measuredSeconds: 3, calibrated: true)
        let plain = try await service.request([phrase], connector: .ollama, language: "en")
        let plainQuote = try await service.prepare([phrase], connector: .ollama, model: "fixture", language: "en")
        #expect(plain.cachedBlock?.contains("Required:") == false)
        #expect(String(decoding: try JSONEncoder().encode(phrase), as: UTF8.self).contains("bridge") == false)
        let rows: [(VoiceLabFitBridge, String)] = [
            (.init(leading: ["I", "use"], trailing: ["as"]), "Required: the text must begin with “I use” and end with “as”, exactly these words."),
            (.init(leading: ["I", "use"], trailing: []), "Required: the text must begin with “I use”, exactly these words."),
            (.init(leading: [], trailing: ["as"]), "Required: the text must end with “as”, exactly these words."),
        ]
        for (bridge, line) in rows {
            phrase.bridge = bridge
            let request = try await service.request([phrase], connector: .ollama, language: "en")
            #expect(request.cachedBlock?.contains(line) == true, "\(request.cachedBlock ?? "")")
            #expect(request.system == plain.system && request.instruction == plain.instruction)
            let quote = try await service.prepare([phrase], connector: .ollama, model: "fixture", language: "en")
            #expect(quote.fingerprint != plainQuote.fingerprint)
        }
        let bridge = VoiceLabFitBridge(leading: ["I", "use"], trailing: ["as,"])
        #expect(bridge.display == "I use … as,")
        #expect(bridge.keeps("I use a like method as"))
        #expect(bridge.keeps("i USE, the same way AS"))
        #expect(!bridge.keeps("a similar method as"))
        #expect(!bridge.keeps("I use a similar method"))
        #expect(!bridge.keeps(""))
        #expect(VoiceLabFitBridge(leading: [], trailing: []).keeps("Anything"))
    }

    @Test func fitQuoteCannotAuthorizeAnotherReplyOrAnUnapprovedSend() async throws {
        let service = VoiceLabWordingFitService(shared: try SharedResources.locate())
        let target = try VoiceLabWordingFit.wordTarget(wordsPerSecond: 2, multiplier: 1, minimumSeconds: 1, maximumSeconds: 2, overheadSeconds: 0)
        let phrase = VoiceLabFitPhrase(ordinal: 1, original: "Original", proposed: "Proposed", estimateSeconds: 3, slotSeconds: 2, direction: "shorter", target: target)
        let connector = WordingFitStub(reply: #"{"phrases":[]}"#)
        let quote = try await service.prepare([phrase], connector: connector.id, model: "fixture", language: "en")
        await #expect(throws: VoiceLabError.consentRequired) {
            try await service.propose([phrase], connector: connector, model: "fixture", language: "en", quote: quote, approved: false)
        }
        await #expect(throws: VoiceLabError.consentRequired) {
            try await service.propose([phrase], connector: connector, model: "different", language: "en", quote: quote, approved: true)
        }
        #expect(await connector.sends == 0)
    }
}

private actor WordingFitStub: LLMConnector {
    nonisolated let id = ConnectorID.ollama
    let reply: String
    var sends = 0
    init(reply: String) { self.reply = reply }
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [.init(id: "fixture", name: "Fixture", contextTokens: 128_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 128_000 }
    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        sends += 1
        return RawCompletion(text: reply, model: model, stop: .complete)
    }
}
