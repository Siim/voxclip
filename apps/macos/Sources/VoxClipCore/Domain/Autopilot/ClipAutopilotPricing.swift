import Foundation

/// What applying a plan would cost (ai.md §16.7): the creator's voice for the rewrites, the picked music track, and the
/// plan's own LLM send. Pure: it reads no file and sends nothing.
public struct ClipAutopilotPrice: Sendable, Equatable {
    public enum LLMCost: String, Sendable, Equatable {
        /// A CLI on the creator's plan, a local server or Apple on-device: nothing extra.
        case none
        /// An API key, or a CLI whose sign-in is unknown or an API key: VoxClip can't tell what the send costs.
        case unknown
    }

    /// The rewrites' text-to-speech, nil when the plan has none.
    public let voice: CostEstimate?
    /// The picked track, nil when the plan has none.
    public let music: CostEstimate?
    public let llm: LLMCost

    /// Voice plus music, when every present part has a known price; nil when one is unknown. The LLM send is not part of it.
    public var usd: Decimal? {
        let parts = [voice, music].compactMap { $0 }
        guard parts.allSatisfy({ $0.usd != nil }) else { return nil }
        return parts.reduce(Decimal(0)) { $0 + ($1.usd ?? 0) }
    }
}

public enum ClipAutopilotPricing {
    public static let musicOperation = VoiceLabPricedOperation(provider: "elevenlabs", operation: "music", unit: "second")
    /// `shared/catalog/music-prices.json`, in the Voice Lab price format.
    public static let musicCatalogPath = "catalog/music-prices.json"

    /// - `voiceModel` and `candidates`: the text-to-speech model and takes per phrase the rewrites would use. Each rewrite
    ///   bills its whole spoken text, bridge words included (voice-lab.md §8.2 step 8).
    /// - `musicSeconds`: the clip's edited length (`ClipAutopilotMapping.editedSeconds`), rounded up to whole seconds.
    /// - `connector` and `signIn`: who answered the plan, priced as an LLM send (`VoiceLabCostPresentation.kind`).
    public static func price(_ plan: ClipAutopilotPlan, voiceModel: String, candidates: Int, voiceCatalog: VoiceLabPriceCatalog,
                             musicCatalog: VoiceLabPriceCatalog?, musicSeconds: Double, connector: ConnectorID,
                             signIn: CLISignIn?) throws -> ClipAutopilotPrice {
        guard musicSeconds.isFinite, musicSeconds >= 0 else { throw VoiceLabError.invalidInput }
        let characters = plan.rewrites.reduce(0) { $0 + $1.text.unicodeScalars.count }
        let voice = plan.rewrites.isEmpty ? nil : try VoiceLabPricing.estimate(operation: .elevenLabsTextToSpeech, model: voiceModel,
            units: Double(characters), candidates: candidates, catalog: voiceCatalog)
        var music: CostEstimate?
        if plan.pickedMusic != nil {
            let seconds = musicSeconds.rounded(.up)
            if let musicCatalog {
                music = try VoiceLabPricing.estimate(operation: musicOperation, model: nil, units: seconds, catalog: musicCatalog)
            } else {
                music = CostEstimate(provider: musicOperation.provider, operation: musicOperation.operation, units: seconds, unit: "second",
                                     basis: VoiceLabPricing.unknownBasis)
            }
        }
        let kind = VoiceLabCostPresentation.kind(forLLMSendTo: connector, signIn: signIn, providerName: connector.rawValue)
        let free: Bool
        if case .inline = kind { free = true } else { free = false }
        return ClipAutopilotPrice(voice: voice, music: music, llm: free ? .none : .unknown)
    }
}

/// The list input prices that price a plan's frames on an API-key connector (`shared/catalog/llm-image-prices.json`,
/// ADR-R48, ai.md §19.6). The tokens are the frame sheet's estimate; a model not listed takes its connector's highest
/// listed price, so an estimate never reads low. A connector the file does not list is unpriced: its billed sends carry
/// the text summary only.
public struct ClipAutopilotImagePrices: Sendable, Equatable {
    public static let path = "catalog/llm-image-prices.json"
    public static let schema = "voxclip-llm-image-prices/1"

    /// USD per million input tokens, by connector and model.
    public let perMillion: [ConnectorID: [String: Decimal]]

    public init(perMillion: [ConnectorID: [String: Decimal]]) { self.perMillion = perMillion }

    public init(shared: SharedResources) throws {
        guard let data = try? Data(contentsOf: shared.root.appendingPathComponent(Self.path)) else { throw VoxClipError.sharedResourcesMissing }
        try self.init(data: data)
    }

    public init(data: Data) throws {
        guard let document = try? JSONDecoder().decode(JSONValue.self, from: data), document[ai: "schema"].aiString == Self.schema,
              let connectors = document[ai: "connectors"].aiObject else { throw VoxClipError.sharedResourcesMissing }
        var result: [ConnectorID: [String: Decimal]] = [:]
        for (key, value) in connectors {
            guard let id = ConnectorID(rawValue: key), let models = value[ai: "usdPerMillionInputTokens"].aiObject, !models.isEmpty else {
                throw VoxClipError.sharedResourcesMissing
            }
            var prices: [String: Decimal] = [:]
            for (model, price) in models {
                guard let text = price.aiString, let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), amount > 0 else {
                    throw VoxClipError.sharedResourcesMissing
                }
                prices[model] = amount
            }
            result[id] = prices
        }
        perMillion = result
    }

    /// The USD price of `tokens` input tokens on `connector`'s `model`; nil when the connector is not priced.
    public func usd(tokens: Int, connector: ConnectorID, model: String) -> Decimal? {
        guard let prices = perMillion[connector], let rate = prices[model] ?? prices.values.max() else { return nil }
        return Decimal(max(0, tokens)) * rate / 1_000_000
    }
}
