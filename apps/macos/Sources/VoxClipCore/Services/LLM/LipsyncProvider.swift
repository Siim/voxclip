import Foundation

/// Reserved M3 contract only; voice-lab §9.1. Implementations require consent and a future schema revision.
public protocol LipsyncProvider: Sendable {
    var id: String { get }
    var models: [LipsyncModel] { get }
    func estimate(_ model: LipsyncModel, seconds: Double, fps: Double) async throws -> CostEstimate
    func submit(_ model: LipsyncModel, video: URL, audio: URL, options: LipsyncOptions) async throws -> LipsyncJob
    func poll(_ job: LipsyncJob) async throws -> LipsyncState
    func cancel(_ job: LipsyncJob) async
    func download(_ result: URL, to file: URL) async throws
    func cleanup(_ job: LipsyncJob) async
}
