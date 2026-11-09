import Foundation
import VoxClipCore

public struct LipsyncRun: Sendable {
    public let provider: FalLipsyncProvider
    public let consentStore: VoiceConsentStore
    public let paidRoot: URL
    public let scratchRoot: URL
    /// The window's face check; nil uses Vision. Tests and the DEBUG smoke stand in for a face their synthetic media lack.
    package var detector: LipsyncWindowPreparation.FaceDetector?

    public init(provider: FalLipsyncProvider, consentStore: VoiceConsentStore, paidRoot: URL, scratchRoot: URL) {
        self.provider = provider; self.consentStore = consentStore; self.paidRoot = paidRoot; self.scratchRoot = scratchRoot
    }

    /// Prepares the window (the needed length and its tail margin), then never pays twice for one result: an earlier paid
    /// attempt over these exact inputs (its sidecar, even from before a restart) is imported from its kept file or fetched
    /// again by request ID, for free, once per attempt in a run of the app. Only then, and only when `mayPay` (the click
    /// was priced), a new job is uploaded and submitted. A "Try Again · free" click passes `mayPay: false`.
    public func execute(request: RenderRequest, window: LipsyncRenderWindow, recordID: String, model: LipsyncModel? = nil,
                        mayPay: Bool = true,
                        onProgress: @escaping @Sendable (Double?) async -> Void = { _ in }) async throws -> ImportedLipsyncResult {
        guard let projectID = request.voiceLab?.project.id else { throw LipsyncError.invalidInput }
        let prepared: PreparedLipsyncWindow
        do { prepared = try await LipsyncWindowPreparation.prepare(request: request, window: window, scratchRoot: scratchRoot, detector: detector) }
        catch { throw LipsyncNotSubmitted.wrap(error) }
        try Task.checkCancellation()
        let chosen = model ?? provider.rewriteModel
        if let attempt = LipsyncAttemptStore.find(prepared, model: chosen.id, projectID: projectID, paidRoot: paidRoot),
           await LipsyncRecoveryMemo.shared.claim(attempt.requestID) {
            do {
                let result = try await LipsyncResultImporter().importRecovered(attempt, provider: provider, projectID: projectID,
                    paidRoot: paidRoot, sourceWidth: prepared.width, sourceHeight: prepared.height, referenceVideo: prepared.video)
                await onProgress(1)
                return result
            } catch {
                if Task.isCancelled || error is CancellationError || !mayPay { throw error }
            }
        }
        guard mayPay else { throw LipsyncRecoveryFailed(error: LipsyncError.unknownJob) }
        let quote: LipsyncQuote, approval: LipsyncApproval
        do {
            (quote, approval) = try await provider.prepareApprovedUpload(video: prepared.video, audio: prepared.audio,
                options: LipsyncOptions(syncMode: window.syncMode), fps: prepared.fps, consentStore: consentStore,
                recordID: recordID, acceptsPaidJob: true, acceptsMediaTransfer: true, model: chosen)
        } catch { throw LipsyncNotSubmitted.wrap(error) }
        let job = try await provider.submit(quote, approval: approval)
        do {
            // The attempt's sidecar: written as soon as fal.ai accepted the job, so its result is never lost.
            var attempt = LipsyncAttempt(job: job, quote: quote, neededSeconds: prepared.neededSeconds)
            attempt.picture = prepared.picture
            do { try LipsyncAttemptStore.record(attempt, projectID: projectID, paidRoot: paidRoot) }
            catch { await provider.note("lipsync attempt record=unwritten") }
            _ = try await provider.wait(job) { state in
                switch state {
                case .running(let progress): await onProgress(progress)
                case .done: await onProgress(1)
                default: await onProgress(nil)
                }
            }
            return try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote,
                neededSeconds: prepared.neededSeconds, picture: prepared.picture, projectID: projectID, paidRoot: paidRoot,
                sourceWidth: prepared.width, sourceHeight: prepared.height, referenceVideo: prepared.video)
        } catch let failure as LipsyncAttemptFailure {
            // The import already kept what it could and cleaned up at fal.ai.
            throw failure
        } catch {
            if Task.isCancelled || error is CancellationError { await provider.cancel(job) }
            await provider.cleanup(job)
            throw error
        }
    }
}

/// A lip sync that failed before its job was submitted (preparing the window, uploading, quoting or approving): fal.ai
/// cannot have charged for it. Local preparation errors, a missing key and cancellation keep their own types.
public struct LipsyncNotSubmitted: Error, Sendable {
    public let error: any Error

    static func wrap(_ error: any Error) -> any Error {
        if error is CancellationError || error is LipsyncPreparationError || error as? LipsyncError == .missingKey { return error }
        return LipsyncNotSubmitted(error: error)
    }
}

/// The free recovery runs once per paid attempt in a run of the app: a kept result that fails again makes the next Try
/// Again a priced one. A restart (a fixed build) tries again for free.
actor LipsyncRecoveryMemo {
    static let shared = LipsyncRecoveryMemo()
    private var tried: Set<String> = []
    func claim(_ requestID: String) -> Bool { tried.insert(requestID).inserted }
}
