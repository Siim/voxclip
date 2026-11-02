import Foundation

struct ApprovedLipsyncProvider: LipsyncProvider {
    let provider: FalLipsyncProvider
    let quote: LipsyncQuote
    let approval: LipsyncApproval
    var id: String { provider.id }
    var models: [LipsyncModel] { [quote.model] }
    func estimate(_ model: LipsyncModel, seconds: Double, fps: Double) async throws -> CostEstimate {
        try await provider.estimate(model, seconds: seconds, fps: fps)
    }
    func submit(_ model: LipsyncModel, video: URL, audio: URL, options: LipsyncOptions) async throws -> LipsyncJob {
        guard model == quote.model, video == quote.video.url, audio == quote.audio.url, options == quote.options else {
            throw LipsyncError.approvalRequired
        }
        return try await provider.submit(quote, approval: approval)
    }
    func poll(_ job: LipsyncJob) async throws -> LipsyncState { try await provider.poll(job) }
    func cancel(_ job: LipsyncJob) async { await provider.cancel(job) }
    func download(_ result: URL, to file: URL) async throws { try await provider.download(result, to: file) }
    func cleanup(_ job: LipsyncJob) async { await provider.cleanup(job) }
}
