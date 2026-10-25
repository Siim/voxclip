import Foundation

public enum SpeechEngineMode: String, Sendable { case local, apple, elevenlabs, ask }

public struct SpeechLanguageDetection: Sendable, Equatable {
    public let language: String
    public let probability: Double
    public init(language: String, probability: Double) { self.language = language; self.probability = probability }
}

public struct SpeechLanguageDefault: Decodable, Sendable {
    public let local: [String]
    public let recommendedDownload: String
    public let lowMemoryDownload: String?
}

public struct SpeechRoutingSnapshot: Sendable {
    public var models: [ModelDescriptor]
    public var defaults: [String: SpeechLanguageDefault]
    public var installedModels: Set<String>
    public var supportedAppleLocales: [String]
    public var hasElevenLabsKey: Bool
    public var installedRAMBytes: Int64
    public var lowMemoryThresholdBytes: Int64
    public var detectedLanguage: String?
    public var detectionProbability: Double?
    public var modelDTWDefaults: [String: Bool] = [:]

    public init(models: [ModelDescriptor], defaults: [String: SpeechLanguageDefault], installedModels: Set<String>, supportedAppleLocales: [String], hasElevenLabsKey: Bool, installedRAMBytes: Int64, lowMemoryThresholdBytes: Int64, detectedLanguage: String? = nil, detectionProbability: Double? = nil) {
        self.models = models
        self.defaults = defaults
        self.installedModels = installedModels
        self.supportedAppleLocales = supportedAppleLocales
        self.hasElevenLabsKey = hasElevenLabsKey
        self.installedRAMBytes = installedRAMBytes
        self.lowMemoryThresholdBytes = lowMemoryThresholdBytes
        self.detectedLanguage = detectedLanguage
        self.detectionProbability = detectionProbability
    }
}

public indirect enum SpeechRoutingDecision: Sendable, Equatable {
    case plan(TranscriptionPlan)
    case chooseLanguage
    case download(modelID: String, alsoOffer: TranscriptionPlan?)
    case addKey(local: SpeechRoutingDecision)
    case appleUnsupported(language: String, local: SpeechRoutingDecision)
    case choose(local: SpeechRoutingDecision, cloud: TranscriptionPlan?)
}

extension LanguageRouter {
    public static func route(language: LanguageChoice, mode: SpeechEngineMode, snapshot: SpeechRoutingSnapshot) throws -> SpeechRoutingDecision {
        let cloud = TranscriptionPlan(engine: .elevenlabs, model: "scribe_v2", language: language)
        switch mode {
        case .elevenlabs:
            return snapshot.hasElevenLabsKey ? .plan(cloud) : .addKey(local: try route(language: language, mode: .local, snapshot: snapshot))
        case .ask:
            return .choose(local: try route(language: language, mode: .local, snapshot: snapshot), cloud: snapshot.hasElevenLabsKey ? cloud : nil)
        case .apple:
            if case .forced(let code) = language, appleSupports(code, snapshot: snapshot) {
                return .plan(TranscriptionPlan(engine: .appleSpeech, language: .forced(SpeechText.primaryLanguage(code))))
            }
            return .appleUnsupported(language: language.code ?? "auto", local: try route(language: language, mode: .local, snapshot: snapshot))
        case .local: break
        }
        guard case .forced(let code) = language else {
            let hasDetector = snapshot.models.contains { snapshot.installedModels.contains($0.id) && $0.id.hasPrefix("whisper-large-v3-turbo-") }
            guard hasDetector, let detected = snapshot.detectedLanguage,
                  let probability = snapshot.detectionProbability, probability.isFinite, probability >= 0.5 else { return .chooseLanguage }
            return try route(language: .forced(detected), mode: .local, snapshot: snapshot)
        }
        let primary = SpeechText.primaryLanguage(code)
        guard let defaults = snapshot.defaults[primary] ?? snapshot.defaults["*"] else { throw SpeechErrorCopy.unsupported(.whispercpp, language: language) }
        let installed = defaults.local.compactMap { identifier in
            snapshot.models.first { $0.id == identifier && snapshot.installedModels.contains(identifier) }
        }
        if let specific = installed.first(where: { $0.languages == [primary] }) {
            return whisperPlan(specific, language: primary, snapshot: snapshot)
        }
        if appleSupports(primary, snapshot: snapshot) {
            return .plan(TranscriptionPlan(engine: .appleSpeech, language: .forced(primary)))
        }
        if let model = installed.first(where: { $0.languages.contains(primary) }) {
            return whisperPlan(model, language: primary, snapshot: snapshot)
        }
        let recommended = snapshot.installedRAMBytes < snapshot.lowMemoryThresholdBytes ? defaults.lowMemoryDownload ?? defaults.recommendedDownload : defaults.recommendedDownload
        return .download(modelID: recommended, alsoOffer: snapshot.hasElevenLabsKey ? TranscriptionPlan(engine: .elevenlabs, model: "scribe_v2", language: .forced(primary)) : nil)
    }

    private static func appleSupports(_ language: String, snapshot: SpeechRoutingSnapshot) -> Bool {
        let primary = SpeechText.primaryLanguage(language)
        return primary != "et" && snapshot.supportedAppleLocales.contains { SpeechText.primaryLanguage($0) == primary }
    }
    private static func whisperPlan(_ model: ModelDescriptor, language: String, snapshot: SpeechRoutingSnapshot) -> SpeechRoutingDecision {
        .plan(TranscriptionPlan(engine: .whispercpp, model: model.id, language: .forced(language), options: TranscriptionOptions(dtw: snapshot.modelDTWDefaults[model.id] ?? true)))
    }
}

private extension LanguageChoice {
    var code: String? { if case .forced(let code) = self { code } else { nil } }
}
