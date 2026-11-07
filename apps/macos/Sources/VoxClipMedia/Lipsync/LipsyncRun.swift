import Foundation
import VoxClipCore

public struct LipsyncRun: Sendable {
    public let provider: FalLipsyncProvider
    public let consentStore: VoiceConsentStore
    public let paidRoot: URL
    public let scratchRoot: URL

    public init(provider: FalLipsyncProvider, consentStore: VoiceConsentStore, paidRoot: URL, scratchRoot: URL) {
        self.provider = provider; self.consentStore = consentStore; self.paidRoot = paidRoot; self.scratchRoot = scratchRoot
    }

    public func execute(request: RenderRequest, window: LipsyncRenderWindow, recordID: String, model: LipsyncModel? = nil,
                        onProgress: @escaping @Sendable (Double?) async -> Void = { _ in }) async throws -> ImportedLipsyncResult {
        guard let projectID = request.voiceLab?.project.id else { throw LipsyncError.invalidInput }
        let prepared = try await LipsyncWindowPreparation.prepare(request: request, window: window, scratchRoot: scratchRoot)
        try Task.checkCancellation()
        let (quote, approval) = try await provider.prepareApprovedUpload(video: prepared.video, audio: prepared.audio,
            options: LipsyncOptions(syncMode: window.syncMode), fps: prepared.fps, consentStore: consentStore,
            recordID: recordID, acceptsPaidJob: true, acceptsMediaTransfer: true, model: model)
        let job = try await provider.submit(quote, approval: approval)
        do {
            try LipsyncReceiptStore.record(job: job, quote: quote, projectID: projectID, paidRoot: paidRoot)
            _ = try await provider.wait(job) { state in
                switch state {
                case .running(let progress): await onProgress(progress)
                case .done: await onProgress(1)
                default: await onProgress(nil)
                }
            }
            return try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote,
                projectID: projectID, paidRoot: paidRoot, sourceWidth: prepared.width, sourceHeight: prepared.height,
                referenceVideo: prepared.video)
        } catch {
            if Task.isCancelled || error is CancellationError { await provider.cancel(job) }
            await provider.cleanup(job)
            throw error
        }
    }
}
