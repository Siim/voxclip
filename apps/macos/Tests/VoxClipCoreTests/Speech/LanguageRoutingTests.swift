import Foundation
import Testing
@testable import VoxClipCore

@Suite("Speech language routing")
struct LanguageRoutingTests {
    private func snapshot(installed: Set<String> = [], apple: [String] = ["en-GB", "de-DE"], key: Bool = false) async throws -> SpeechRoutingSnapshot {
        let catalog = BundledModelCatalog(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        return try await catalog.routingSnapshot(installedModels: installed, supportedAppleLocales: apple, hasElevenLabsKey: key, installedRAMBytes: 16 * 1_073_741_824)
    }

    @Test(arguments: [("est", "et"), ("EST-ee", "et"), ("ekk", "et"), ("eng-US", "en"), ("deu-DE", "de"), ("fil", "tl"), ("pt-BR", "pt"), ("zzz", "zzz")])
    func catalogNormalizesISOAliasesAndPrimarySubtags(_ code: String, _ expected: String) async throws {
        let catalog = try SpeechTestFiles.catalog()
        #expect(try await catalog.normalizeLanguage(code) == expected)
    }

    @Test func normalizationKeepsExplicitAppleRegion() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var request = try SpeechTestFiles.request(root)
        request.plan = TranscriptionPlan(engine: .appleSpeech, language: .forced("eng-GB"))
        let normalized = try await SpeechRawCacheKey.normalizedRequest(request, catalog: SpeechTestFiles.catalog())
        #expect(normalized.plan.language == .forced("en-GB"))
        let key = SpeechRawCacheKey(request: normalized, identity: EngineRef(id: .appleSpeech, engineVersion: "test", locale: "en-GB"))
        #expect(key.language == "en" && key.locale == "en-GB")
    }

    @Test func englishSpecificModelWinsBeforeApple() async throws {
        let context = try await snapshot(installed: ["whisper-large-v3-turbo-q8_0", "whisper-small.en-q5_1"])
        #expect(try LanguageRouter.route(language: .forced("en"), mode: .local, snapshot: context) == .plan(TranscriptionPlan(engine: .whispercpp, model: "whisper-small.en-q5_1", language: .forced("en"))))
    }

    @Test func appleDefersRegionalChoiceAndNeverUsesEstonian() async throws {
        let context = try await snapshot(apple: ["en-AU", "en-US", "et-EE"])
        for mode in [SpeechEngineMode.local, .apple] {
            #expect(try LanguageRouter.route(language: .forced("en"), mode: mode, snapshot: context) == .plan(TranscriptionPlan(engine: .appleSpeech, language: .forced("en"))))
        }
        #expect(try LanguageRouter.route(language: .forced("et"), mode: .local, snapshot: context) == .download(modelID: "taltech-et-verbatim-2604-q8_0", alsoOffer: nil))
        #expect(try LanguageRouter.route(language: .forced("et"), mode: .apple, snapshot: context) == .appleUnsupported(language: "et", local: .download(modelID: "taltech-et-verbatim-2604-q8_0", alsoOffer: nil)))
    }

    @Test func detectionReroutesWithoutUploading() async throws {
        var context = try await snapshot(installed: ["whisper-large-v3-turbo-q5_0", "taltech-et-verbatim-2604-q4_0"], key: true)
        context.detectedLanguage = "et"
        context.detectionProbability = 0.9
        #expect(try LanguageRouter.route(language: .auto, mode: .local, snapshot: context) == .plan(TranscriptionPlan(engine: .whispercpp, model: "taltech-et-verbatim-2604-q4_0", language: .forced("et"))))
        context.detectionProbability = 0.49
        #expect(try LanguageRouter.route(language: .auto, mode: .local, snapshot: context) == .chooseLanguage)
        context.installedModels = []
        context.detectionProbability = 1
        #expect(try LanguageRouter.route(language: .auto, mode: .local, snapshot: context) == .chooseLanguage)
    }

    @Test func explicitCloudRequiresKeyAndAskIsOnlyAPrompt() async throws {
        let context = try await snapshot(apple: [])
        let local = SpeechRoutingDecision.download(modelID: "taltech-et-verbatim-2604-q8_0", alsoOffer: nil)
        #expect(try LanguageRouter.route(language: .forced("et"), mode: .elevenlabs, snapshot: context) == .addKey(local: local))
        #expect(try LanguageRouter.route(language: .forced("et"), mode: .ask, snapshot: context) == .choose(local: local, cloud: nil))
        var keyed = context
        keyed.hasElevenLabsKey = true
        #expect(try LanguageRouter.route(language: .auto, mode: .elevenlabs, snapshot: keyed) == .plan(TranscriptionPlan(engine: .elevenlabs, model: "scribe_v2", language: .auto)))
    }

    @Test func lowMemoryChoiceComesFromCatalogue() async throws {
        var context = try await snapshot(apple: [])
        let data = Data(#"{"local":[],"recommendedDownload":"large","lowMemoryDownload":"small"}"#.utf8)
        context.defaults["en"] = try JSONDecoder().decode(SpeechLanguageDefault.self, from: data)
        context.installedRAMBytes = 4 * 1_073_741_824
        #expect(try LanguageRouter.route(language: .forced("en"), mode: .local, snapshot: context) == .download(modelID: "small", alsoOffer: nil))
    }
    @Test func routedWhisperUsesCatalogueDTWDefault() async throws {
        for identifier in ["whisper-small.en-q5_1", "whisper-large-v3-turbo-q5_0"] {
            var context = try await snapshot(installed: [identifier], apple: [])
            context.modelDTWDefaults[identifier] = false
            #expect(try LanguageRouter.route(language: .forced("en"), mode: .local, snapshot: context) == .plan(TranscriptionPlan(engine: .whispercpp, model: identifier, language: .forced("en"), options: TranscriptionOptions(dtw: false))))
        }
    }
}
