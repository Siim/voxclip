import Foundation
import FoundationModels
import VoxClipCore

/// On-device text-only connector; AI §6.7, architecture §2.1. Never falls back to cloud.
public actor FoundationModelsConnector: LLMConnector {
    public nonisolated let id: ConnectorID = .appleFoundation
    public init() {}
    public func status() async -> ConnectorStatus {
        // TODO(mac-ai)
        return .unavailable(reason: "mac-ai")
    }
    public func models(refresh: Bool) async throws -> [LLMModel] { throw VoxClipError.notImplemented("mac-ai") }
    public func contextTokens(model: String) async -> Int? {
        // TODO(mac-ai)
        return nil
    }
    public func send(_ request: LLMRequest, model: String) async throws -> RawCompletion { throw VoxClipError.notImplemented("mac-ai") }
}
