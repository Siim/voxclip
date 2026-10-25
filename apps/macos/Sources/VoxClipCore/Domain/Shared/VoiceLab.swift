import Foundation

/// Reserved M2/M3 cost preview; voice-lab §3.1. No provider action is enabled in M1.
public struct CostEstimate: Codable, Sendable, Equatable {
    /// provider; Reserved M2/M3 cost preview; voice-lab §3.1. No provider action is enabled in M1.
    public var provider: String
    /// operation; Reserved M2/M3 cost preview; voice-lab §3.1. No provider action is enabled in M1.
    public var operation: String
    /// units; Reserved M2/M3 cost preview; voice-lab §3.1. No provider action is enabled in M1.
    public var units: Double
    /// unit; Reserved M2/M3 cost preview; voice-lab §3.1. No provider action is enabled in M1.
    public var unit: String
    /// usd; Reserved M2/M3 cost preview; voice-lab §3.1. No provider action is enabled in M1.
    public var usd: Decimal?
    /// credits; Reserved M2/M3 cost preview; voice-lab §3.1. No provider action is enabled in M1.
    public var credits: Int?
    /// basis; Reserved M2/M3 cost preview; voice-lab §3.1. No provider action is enabled in M1.
    public var basis: String

    /// Creates an explicit value without I/O or generated identifiers.
    public init(provider: String, operation: String, units: Double, unit: String, usd: Decimal? = nil, credits: Int? = nil, basis: String) {
        self.provider = provider
        self.operation = operation
        self.units = units
        self.unit = unit
        self.usd = usd
        self.credits = credits
        self.basis = basis
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case operation
        case units
        case unit
        case usd
        case credits
        case basis
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try values.decode(String.self, forKey: .provider)
        self.operation = try values.decode(String.self, forKey: .operation)
        self.units = try values.decode(Double.self, forKey: .units)
        self.unit = try values.decode(String.self, forKey: .unit)
        self.usd = try values.decodeIfPresent(Decimal.self, forKey: .usd) ?? nil
        self.credits = try values.decodeIfPresent(Int.self, forKey: .credits) ?? nil
        self.basis = try values.decode(String.self, forKey: .basis)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.provider, forKey: .provider)
        try values.encode(self.operation, forKey: .operation)
        try values.encode(self.units, forKey: .units)
        try values.encode(self.unit, forKey: .unit)
        try values.encode(self.usd, forKey: .usd)
        try values.encode(self.credits, forKey: .credits)
        try values.encode(self.basis, forKey: .basis)
    }

}

/// Reserved M3 tier; voice-lab §9.1.
public enum LipsyncTier: String, Codable, Sendable, Hashable, CaseIterable {
    case fast
    case quality
    case best
}

/// Reserved M3 model identity; voice-lab §9.1.
public struct LipsyncModel: Codable, Sendable, Equatable {
    /// provider; Reserved M3 model identity; voice-lab §9.1.
    public var provider: String
    /// id; Reserved M3 model identity; voice-lab §9.1.
    public var id: String
    /// tier; Reserved M3 model identity; voice-lab §9.1.
    public var tier: LipsyncTier
    /// supportsRemap; Reserved M3 model identity; voice-lab §9.1.
    public var supportsRemap: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(provider: String, id: String, tier: LipsyncTier, supportsRemap: Bool) {
        self.provider = provider
        self.id = id
        self.tier = tier
        self.supportsRemap = supportsRemap
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case id
        case tier
        case supportsRemap
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try values.decode(String.self, forKey: .provider)
        self.id = try values.decode(String.self, forKey: .id)
        self.tier = try values.decode(LipsyncTier.self, forKey: .tier)
        self.supportsRemap = try values.decode(Bool.self, forKey: .supportsRemap)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.provider, forKey: .provider)
        try values.encode(self.id, forKey: .id)
        try values.encode(self.tier, forKey: .tier)
        try values.encode(self.supportsRemap, forKey: .supportsRemap)
    }

}

/// Reserved M3 timing mode; voice-lab §9.1.
public enum SyncMode: String, Codable, Sendable, Hashable { case cutOff = "cut_off", remap }

/// Reserved M3 options; voice-lab §9.1.
public struct LipsyncOptions: Codable, Sendable, Equatable {
    /// syncMode; Reserved M3 options; voice-lab §9.1.
    public var syncMode: SyncMode
    /// seed; Reserved M3 options; voice-lab §9.1.
    public var seed: UInt32?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(syncMode: SyncMode, seed: UInt32? = nil) {
        self.syncMode = syncMode
        self.seed = seed
    }

    private enum CodingKeys: String, CodingKey {
        case syncMode
        case seed
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.syncMode = try values.decode(SyncMode.self, forKey: .syncMode)
        self.seed = try values.decodeIfPresent(UInt32.self, forKey: .seed) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.syncMode, forKey: .syncMode)
        try values.encode(self.seed, forKey: .seed)
    }

}

/// Reserved M3 job receipt; voice-lab §9.1.
public struct LipsyncJob: Codable, Sendable, Equatable {
    /// model; Reserved M3 job receipt; voice-lab §9.1.
    public var model: LipsyncModel
    /// remoteID; Reserved M3 job receipt; voice-lab §9.1.
    public var remoteID: String
    /// statusURL; Reserved M3 job receipt; voice-lab §9.1.
    public var statusURL: URL?
    /// responseURL; Reserved M3 job receipt; voice-lab §9.1.
    public var responseURL: URL?
    /// cancelURL; Reserved M3 job receipt; voice-lab §9.1.
    public var cancelURL: URL?
    /// uploadedAssetIDs; Reserved M3 job receipt; voice-lab §9.1.
    public var uploadedAssetIDs: [String]
    /// submittedAt; Reserved M3 job receipt; voice-lab §9.1.
    public var submittedAt: Date

    /// Creates an explicit value without I/O or generated identifiers.
    public init(model: LipsyncModel, remoteID: String, statusURL: URL? = nil, responseURL: URL? = nil, cancelURL: URL? = nil, uploadedAssetIDs: [String] = [], submittedAt: Date) {
        self.model = model
        self.remoteID = remoteID
        self.statusURL = statusURL
        self.responseURL = responseURL
        self.cancelURL = cancelURL
        self.uploadedAssetIDs = uploadedAssetIDs
        self.submittedAt = submittedAt
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case remoteID
        case statusURL
        case responseURL
        case cancelURL
        case uploadedAssetIDs
        case submittedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try values.decode(LipsyncModel.self, forKey: .model)
        self.remoteID = try values.decode(String.self, forKey: .remoteID)
        self.statusURL = try values.decodeIfPresent(URL.self, forKey: .statusURL) ?? nil
        self.responseURL = try values.decodeIfPresent(URL.self, forKey: .responseURL) ?? nil
        self.cancelURL = try values.decodeIfPresent(URL.self, forKey: .cancelURL) ?? nil
        self.uploadedAssetIDs = try values.decodeIfPresent([String].self, forKey: .uploadedAssetIDs) ?? []
        self.submittedAt = try values.decode(Date.self, forKey: .submittedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.model, forKey: .model)
        try values.encode(self.remoteID, forKey: .remoteID)
        try values.encode(self.statusURL, forKey: .statusURL)
        try values.encode(self.responseURL, forKey: .responseURL)
        try values.encode(self.cancelURL, forKey: .cancelURL)
        try values.encode(self.uploadedAssetIDs, forKey: .uploadedAssetIDs)
        try values.encode(self.submittedAt, forKey: .submittedAt)
    }

}

/// Reserved M3 progress; voice-lab §9.1.
public enum LipsyncState: Sendable, Equatable { case queued(position: Int?), running(progress: Double?), done(URL), failed(code: String, message: String) }
extension CostEstimate: Hashable {}
extension LipsyncModel: Hashable {}
