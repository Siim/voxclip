import Foundation
import VoxClipCore

public struct LipsyncRun: Sendable {
    public let provider: FalLipsyncProvider
    public let consentStore: VoiceConsentStore
    public let paidRoot: URL
    public let scratchRoot: URL
    /// The window's face check; nil uses Vision. Tests and the DEBUG smoke stand in for a face their synthetic media lack.
    package var detector: LipsyncWindowPreparation.FaceDetector?
    package var beforeSubmit: (@Sendable (LipsyncQuote) async -> Void)?
    package var redoVersion: String?

    public init(provider: FalLipsyncProvider, consentStore: VoiceConsentStore, paidRoot: URL, scratchRoot: URL) {
        self.provider = provider; self.consentStore = consentStore; self.paidRoot = paidRoot; self.scratchRoot = scratchRoot
    }

    package static func hasIndexedResult(request: RenderRequest, window: LipsyncRenderWindow, model: LipsyncModel,
                                         paidRoot: URL, scratchRoot: URL, now: Date = Date(), redoVersion: String? = nil,
                                         detector: LipsyncWindowPreparation.FaceDetector? = nil) async -> Bool {
        guard let projectID = request.voiceLab?.project.id,
              !LipsyncAttemptStore.importedAssets(inProject: projectID, paidRoot: paidRoot).isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let prepared = try await LipsyncWindowPreparation.prepare(request: request, window: window, scratchRoot: scratchRoot, detector: detector)
            guard let attempt = LipsyncAttemptStore.find(prepared, model: model.id, projectID: projectID, paidRoot: paidRoot, redoVersion: redoVersion),
                  let importedAt = attempt.importedAt, now.timeIntervalSince(importedAt) <= LipsyncAttemptStore.importedLifetime else { return false }
            return LipsyncAttemptStore.importedResult(attempt, projectID: projectID, paidRoot: paidRoot) != nil
        } catch { return false }
    }

    /// Prepares the window (the needed length and its tail margin), then never pays twice for one result:
    /// 1. The window's imported index (a result already imported over these exact inputs, even before a restart): its file,
    ///    after a SHA-256 check, for free and with nothing fetched.
    /// 2. An earlier paid attempt over these inputs (its sidecar): its kept file, else its result fetched again by request
    ///    ID, waiting out a job fal.ai still runs, for free. That recovery is spent for the run of the app only by a
    ///    definite outcome (the result failed its checks again, or fal.ai failed or forgot the job); a cancel, a passing
    ///    error or a job still running leaves it open. While fal.ai may still finish the earlier job, nothing new is paid.
    /// 3. Only then, and only when `mayPay` (the click was priced), a new job is uploaded and submitted. A "Try Again · free"
    ///    click passes `mayPay: false`.
    /// Once fal.ai finished a job its result is kept whatever stops the caller: it is never cancelled or deleted at fal.ai
    /// before it is safe on this Mac.
    public func execute(request: RenderRequest, window: LipsyncRenderWindow, recordID: String, model: LipsyncModel? = nil,
                        mayPay: Bool = true,
                        onProgress: @escaping @Sendable (Double?) async -> Void = { _ in }) async throws -> ImportedLipsyncResult {
        guard let projectID = request.voiceLab?.project.id else { throw LipsyncError.invalidInput }
        let prepared: PreparedLipsyncWindow
        do { prepared = try await LipsyncWindowPreparation.prepare(request: request, window: window, scratchRoot: scratchRoot, detector: detector) }
        catch { throw LipsyncNotSubmitted.wrap(error) }
        if prepared.videoBitrate < prepared.naturalBitrate {
            await provider.note("lipsync upload bitrate=\(prepared.videoBitrate) from=\(prepared.naturalBitrate) reason=size")
        }
        try Task.checkCancellation()
        let chosen = model ?? provider.rewriteModel
        LipsyncAttemptStore.prune(projectID: projectID, paidRoot: paidRoot, now: await provider.date())
        var recoveryClosed = false
        if let attempt = LipsyncAttemptStore.find(prepared, model: chosen.id, projectID: projectID, paidRoot: paidRoot, redoVersion: redoVersion) {
            if attempt.importedAsset != nil {
                if let result = LipsyncAttemptStore.importedResult(attempt, projectID: projectID, paidRoot: paidRoot) {
                    await provider.note("lipsync result reused=imported")
                    await onProgress(1)
                    return result
                }
                // Its asset is gone or changed: only the index entry goes.
                LipsyncAttemptStore.discard(attempt, projectID: projectID, paidRoot: paidRoot)
            } else if await LipsyncRecoveryMemo.shared.claim(attempt.requestID) {
                do {
                    let result = try await LipsyncResultImporter().importRecovered(attempt, provider: provider, projectID: projectID,
                        paidRoot: paidRoot, sourceWidth: prepared.width, sourceHeight: prepared.height, referenceVideo: prepared.video) { state in
                        if case .running = state { await onProgress(nil) }
                    }
                    await onProgress(1)
                    return result
                } catch {
                    let settled = error is LipsyncAttemptFailure || LipsyncRecoveryFailed.settles(error)
                    if !settled { await LipsyncRecoveryMemo.shared.release(attempt.requestID) }
                    // Never pay while the earlier job may still be finished or fetched: a cancel, a free click, a job
                    // still running, or a check that may pass later.
                    if Task.isCancelled || error is CancellationError || !mayPay || !settled { throw error }
                }
            } else { recoveryClosed = true }
        }
        guard mayPay else { throw LipsyncRecoveryFailed(error: LipsyncError.unknownJob, settled: true) }
        if recoveryClosed { await provider.note("lipsync recovery=spent") }
        let quote: LipsyncQuote, approval: LipsyncApproval
        do {
            (quote, approval) = try await provider.prepareApprovedUpload(video: prepared.video, audio: prepared.audio,
                options: LipsyncOptions(syncMode: window.syncMode), fps: prepared.fps, consentStore: consentStore,
                recordID: recordID, acceptsPaidJob: true, acceptsMediaTransfer: true, model: chosen)
        } catch { throw LipsyncNotSubmitted.wrap(error) }
        let job: LipsyncJob
        await beforeSubmit?(quote)
        do { job = try await provider.submit(quote, approval: approval) }
        catch {
            // Once the POST may have crossed the boundary, its failed response cannot prove that it was free.
            if await provider.status(quoteID: quote.id)?.billing == .submissionUncertain { throw LipsyncError.submissionUncertain }
            if case LipsyncError.http(let status) = error, (400...499).contains(status) {
                throw LipsyncNotSubmitted(error: error, queueRefused: true)
            }
            throw LipsyncNotSubmitted.wrap(error)
        }
        var attempt = LipsyncAttempt(job: job, quote: quote, neededSeconds: prepared.neededSeconds)
        attempt.picture = prepared.picture
        attempt.redoVersion = redoVersion
        var recorded = false
        /// A free Try Again finds the attempt only by its record on disk: written when fal.ai accepted the job, or by the
        /// import (a kept file, the imported index).
        func findable() -> Bool {
            recorded || LipsyncAttemptStore.load(videoSHA256: attempt.videoSHA256, audioSHA256: attempt.audioSHA256,
                                                 projectID: projectID, paidRoot: paidRoot, model: chosen.id, redoVersion: redoVersion) != nil
        }
        do {
            // The attempt's sidecar: written as soon as fal.ai accepted the job, so its result is never lost.
            do { try LipsyncAttemptStore.record(attempt, projectID: projectID, paidRoot: paidRoot); recorded = true }
            catch { await provider.note("lipsync attempt record=unwritten") }
            _ = try await provider.wait(job) { state in
                switch state {
                case .running(let progress): await onProgress(progress)
                case .done: await onProgress(1)
                default: await onProgress(nil)
                }
            }
            let result = try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote,
                neededSeconds: prepared.neededSeconds, picture: prepared.picture, projectID: projectID, paidRoot: paidRoot,
                sourceWidth: prepared.width, sourceHeight: prepared.height, referenceVideo: prepared.video, redoVersion: redoVersion)
            await provider.untrack(job)
            return result
        } catch let failure as LipsyncAttemptFailure {
            // The import already kept what it could and cleaned up at fal.ai only once the result was safe here. Try Again
            // is free only when it can find the attempt: its record was written (here, or with a kept file).
            await provider.untrack(job)
            throw failure.freeRetry && !findable() ? LipsyncAttemptFailure(error: failure.error, attempt: failure.attempt, freeRetry: false) : failure
        } catch {
            // A finished job is billed and its result waits at fal.ai: never cancelled or deleted. Try Again fetches it for
            // free once it can find the attempt: its record is written once more if it wasn't when fal.ai accepted the job.
            if await provider.isDone(job) {
                await provider.untrack(job)
                if !findable() {
                    do { try LipsyncAttemptStore.record(attempt, projectID: projectID, paidRoot: paidRoot); recorded = true }
                    catch { await provider.note("lipsync attempt record=unwritten") }
                }
                throw LipsyncAttemptFailure(error: error, attempt: attempt, freeRetry: findable())
            }
            if Task.isCancelled || error is CancellationError {
                await provider.cancel(job); await provider.cleanup(job); throw CancellationError()
            }
            // Keep the accepted request identity even when polling gives up: cleanup deletes only a failed or cancelled
            // job's payloads, and a still-running one is eligible for a free status check and fetch later.
            await provider.cleanup(job)
            await provider.untrack(job)
            if case LipsyncError.providerFailed = error {
                // fal.ai failed the job itself: nothing of it can be fetched again.
                LipsyncAttemptStore.discard(attempt, projectID: projectID, paidRoot: paidRoot)
            }
            let status = await provider.status(quoteID: quote.id)
            let withinRetention = attempt.refetchable(at: await provider.date())
            let recoverable = recorded && status?.cancelled == false && status?.cleanup == .pending && withinRetention
            throw LipsyncAttemptFailure(error: error, attempt: attempt, freeRetry: recoverable)
        }
    }
}

/// A lip sync that failed before its job was submitted (preparing the window, uploading, quoting or approving): fal.ai
/// cannot have charged for it. Local preparation errors, a missing key, a window outside the limits, an unsafe local file
/// and cancellation keep their own types (`RewriteLipsyncSession.isLocal`).
public struct LipsyncNotSubmitted: Error, Sendable {
    public let error: any Error
    public var queueRefused = false

    static func wrap(_ error: any Error) -> any Error {
        if error is CancellationError || error is LipsyncPreparationError { return error }
        if let local = error as? LipsyncError, [.missingKey, .invalidInput, .unsafeFile].contains(local) { return local }
        return LipsyncNotSubmitted(error: error)
    }
}

/// The free recovery of a paid attempt runs once per attempt in a run of the app once it reaches a definite outcome (a
/// kept result that fails again, or a job fal.ai failed or no longer has): the next Try Again is then a priced one. A
/// recovery that was cancelled, met a passing error or found the job still running gives its claim back. A restart (a
/// fixed build) tries again for free.
actor LipsyncRecoveryMemo {
    static let shared = LipsyncRecoveryMemo()
    private var tried: Set<String> = []
    func claim(_ requestID: String) -> Bool { tried.insert(requestID).inserted }
    func release(_ requestID: String) { tried.remove(requestID) }
}
