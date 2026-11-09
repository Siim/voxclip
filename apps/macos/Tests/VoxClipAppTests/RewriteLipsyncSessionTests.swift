#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

@Suite("Rewrite lip-sync job ownership", .serialized) @MainActor
struct RewriteLipsyncSessionTests {
    /// The formatted price already carries its "≈"; the controls must not add a second one (MVP21 showed "≈ ≈ $1.90").
    @Test func lipSyncPriceCopyCarriesOneApproximationSign() {
        let price = VoiceLabCostPresentation.format(Decimal(string: "1.90")!)
        #expect(price == "≈ $1.90")
        let label = RewriteLipsyncControls.approveLabel(verb: "Lip sync", phrase: 0, price: price)
        #expect(label == "Lip sync, phrase 1, approximately $1.90, upload video and audio to fal.ai sync-3")
        let source = try? String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/VoxClipAppTests/RewriteLipsyncSessionTests.swift", with: "Sources/VoxClip/RewriteLipsyncControls.swift"), encoding: .utf8)
        #expect(source?.contains("≈ \\(") == false, "a literal ≈ before an already formatted price")
    }

    @MainActor private final class RunGate {
        var started = false
        var consent = false
        var count = 0
        var pending: TestContinuation<Void>?
        var current = true
        func wait() async { started = true; count += 1; await withTestDeadline { pending = $0 } }
        func release() { pending?.resume(); pending = nil }
    }

    private func setup(key: Bool = true, failure: LipsyncPreparationError? = nil) throws -> (RewriteLipsyncSession, RewriteLipsyncSession.Offer, RunGate) {
        let gate = RunGate(), session = RewriteLipsyncSession()
        let piece = VoiceLabOutputPiece(kind: .source, sourceStartSample: 0, sourceEndSample: 480_000,
            outputStartSample: 0, outputEndSample: 480_000, segmentId: nil, assetId: nil, audio: nil)
        let plan = VoiceLabOutputPlan(sampleRate: 48_000, totalSourceSamples: 480_000, pieces: [piece], captions: [], scope: .full)
        let source = try LipsyncWindow.make(seamIn: 96_000, seamOut: 144_000, totalSamples: 480_000, sampleRate: 48_000, phraseID: 0)
        let window = try LipsyncRenderWindow(source: source, plan: plan)
        let request = RenderRequest(sourceURL: URL(fileURLWithPath: "/synthetic/source.mp4"),
            plan: EditPlan(sampleRate: 48_000, totalSamples: 480_000), output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 1_000_000))
        let estimate = CostEstimate(provider: "fal", operation: "lipsync", units: 3, unit: "second", usd: Decimal(string: "0.4"), basis: "fixture")
        let offer = RewriteLipsyncSession.Offer(id: UUID(), request: request, windows: [window], estimate: estimate,
            recordID: "fixture-consent", dependencies: [0, 1], isCurrent: { gate.current })
        let asset = VoiceLabVideoAsset(id: UUID().uuidString.lowercased(), file: "fixture.mp4", sha256: String(repeating: "a", count: 64),
            durationSeconds: 3, frameRate: 30, width: 320, height: 180)
        let provenance = LipsyncResultProvenance(provider: "fal", model: "fal-ai/sync-lipsync/v3", requestID: UUID().uuidString.lowercased(),
            quoteID: offer.id, videoInputSHA256: asset.sha256, audioInputSHA256: asset.sha256, outputSHA256: asset.sha256,
            syncMode: .cutOff, seed: nil, submittedAt: Date(), importedAt: Date(), estimate: estimate)
        session.backend = .init(offers: { ([0: offer], offer) }, hasKey: { key }, hasConsent: { gate.consent },
            acceptConsent: { gate.consent = true }, cap: { .init(limit: Decimal(string: "0.3")!, spent: 0) },
            run: { _, _, _, _, _, progress in
                if let failure { throw failure }
                await gate.wait()
                await progress(0.5)
                return ImportedLipsyncResult(asset: asset, url: URL(fileURLWithPath: "/synthetic/result.mp4"), provenance: provenance)
            }, changed: {})
        return (session, offer, gate)
    }

    @MainActor private final class PayLog {
        var pays: [Bool] = []
        var fail = true
    }

    /// MVP46: a billed attempt whose result failed its checks but is kept. The row says fal.ai charged for it, Try Again
    /// reads "free" and runs without paying (`mayPay` false), and the kept result then applies.
    @Test func aKeptPaidResultMakesTryAgainFreeAndItNeverPays() async throws {
        let (session, offer, _) = try setup()
        let log = PayLog()
        let json = """
            {"requestID":"11111111-2222-4333-8444-555555555555","provider":"fal","model":"fal-ai/sync-lipsync/v3",
             "quoteID":"\(offer.id.uuidString)","syncMode":"cut_off","estimate":{"provider":"fal","operation":"lipsync","units":3.4,
             "unit":"second","usd":0.45,"basis":"fixture"},"submittedAt":"2026-11-08T22:49:22Z",
             "videoSHA256":"\(String(repeating: "a", count: 64))","audioSHA256":"\(String(repeating: "b", count: 64))",
             "neededSeconds":3,"uploadedSeconds":3.4,"fps":30,"keptResult":true}
            """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let attempt = try decoder.decode(LipsyncAttempt.self, from: Data(json.utf8))
        let check = LipsyncResultCheck.duration(LipsyncResultLength(got: 2.8, needed: 3, uploaded: 3.4, fps: 30))
        let asset = VoiceLabVideoAsset(id: UUID().uuidString.lowercased(), file: "fixture.mp4", sha256: String(repeating: "a", count: 64),
            durationSeconds: 3, frameRate: 30, width: 320, height: 180)
        let provenance = LipsyncResultProvenance(provider: "fal", model: attempt.model, requestID: attempt.requestID, quoteID: offer.id,
            videoInputSHA256: attempt.videoSHA256, audioInputSHA256: attempt.audioSHA256, outputSHA256: asset.sha256,
            syncMode: .cutOff, seed: nil, submittedAt: attempt.submittedAt, importedAt: Date(), estimate: attempt.estimate)
        session.backend = .init(offers: {
            let fresh = RewriteLipsyncSession.Offer(id: UUID(), request: offer.request, windows: offer.windows, estimate: offer.estimate,
                                                    recordID: offer.recordID, dependencies: offer.dependencies, isCurrent: { true })
            return ([0: fresh], fresh)
        }, hasKey: { true }, hasConsent: { true }, acceptConsent: {}, cap: { nil }, run: { _, _, _, _, mayPay, _ in
            log.pays.append(mayPay)
            if log.fail { log.fail = false; throw LipsyncAttemptFailure(error: check, attempt: attempt, freeRetry: true) }
            var result = ImportedLipsyncResult(asset: asset, url: URL(fileURLWithPath: "/synthetic/result.mp4"), provenance: provenance)
            result.recovered = !mayPay
            return result
        }, changed: {})
        await session.refresh()
        session.start(try #require(session.offers[0]))
        await session.waitForRun()
        guard case .failed(let reason, let price, let mayBill) = session.states[0] else { Issue.record("not failed"); return }
        #expect(reason == "fal.ai's video came back 0.2 s shorter than the voice." && mayBill)
        #expect(price == VoiceLabCostPresentation.format(Decimal(string: "0.45")!))
        #expect(session.freeRetries == [0])
        #expect(RewriteLipsyncSession.failureLine(phrase: 0, reason: reason, price: price, mayBill: mayBill, free: true)
            == "Couldn't lip sync phrase 1: fal.ai's video came back 0.2 s shorter than the voice. fal.ai charged for the attempt (≈ $0.45). Its result is kept, so Try Again is free.")
        let retry = try #require(session.offers[0])
        #expect(RewriteLipsyncControls.price(retry, free: session.freeRetries.contains(0)) == "free")
        session.start(retry)
        await session.waitForRun()
        #expect(log.pays == [true, false], "Try Again · free never pays")
        #expect(session.applied[0]?.result.recovered == true && session.freeRetries.isEmpty)
    }

    /// A failure before the job was submitted (the smoke's whole clip met one preparing its audio) never says fal.ai charged.
    @Test func aFailureBeforeTheSubmitClaimsNoCharge() async throws {
        let (session, offer, _) = try setup()
        session.backend = .init(offers: { ([0: offer], offer) }, hasKey: { true }, hasConsent: { true }, acceptConsent: {}, cap: { nil },
            run: { _, _, _, _, _, _ in throw LipsyncNotSubmitted(error: LipsyncError.invalidMedia) }, changed: {})
        await session.refresh()
        session.start(offer)
        await session.waitForRun()
        guard case .failed(let reason, _, let mayBill) = session.states[0] else { Issue.record("not failed"); return }
        #expect(!mayBill && session.freeRetries.isEmpty)
        #expect(reason == "The job could not be completed. Your original video and edits are safe.")
    }

    @Test func approvalKeyCapAndUndoKeepReceipt() async throws {
        let (session, offer, gate) = try setup()
        await session.refresh()
        #expect(!session.consentAccepted && session.capWarning(for: offer) != nil)
        session.start(offer)
        await TestDeadline.until { gate.started }
        #expect(gate.consent && session.blocksMutation(0) && session.blocksMutation(1) && !session.blocksMutation(2))
        gate.release()
        try await session.waitForUseTakes()
        session.finishUseTakes()
        #expect(session.applied[0] != nil && session.receipts[0].requestIDs.count == 1)
        session.undo(0)
        #expect(session.applied.isEmpty && !session.blocksMutation(0))
        #expect(session.receipts.count == 1 && session.receipts[0].requestIDs.count == 1)
        let (missing, missingOffer, missingGate) = try setup(key: false)
        await missing.refresh(); missing.start(missingOffer)
        #expect(!missing.running && !missingGate.consent && missing.receipts.isEmpty)
    }

    @Test func useTakesWaitsAndPreventsAnotherPaidStartUntilAcceptanceFinishes() async throws {
        let (session, offer, gate) = try setup()
        await session.refresh(); session.start(offer)
        await TestDeadline.until { gate.started }
        var accepted = false
        let acceptance = Task { try await session.waitForUseTakes(); accepted = true }
        await TestDeadline.until { session.usingTakes }
        #expect(!accepted)
        gate.release(); try await acceptance.value
        #expect(accepted && session.usingTakes)
        session.undo(0); session.start(offer)
        #expect(gate.count == 1 && !session.running)
        session.finishUseTakes()
    }

    @Test(arguments: [true, false]) func cancellationAndMutationDiscardLateCompletion(invalidate: Bool) async throws {
        let (session, offer, gate) = try setup()
        await session.refresh(); session.start(offer)
        await TestDeadline.until { gate.started }
        if invalidate {
            session.invalidate(1)
            #expect(!session.blocksMutation(1))
        } else { session.cancel(0) }
        gate.release()
        try await session.waitForUseTakes(); session.finishUseTakes()
        #expect(session.applied.isEmpty)
        #expect(session.receipts.count == 1)
    }

    @Test func failedFaceCheckStaysInlineAndDoesNotClaimBilling() async throws {
        let (session, offer, _) = try setup(failure: .noClearFace)
        await session.refresh(); session.start(offer)
        try await session.waitForUseTakes(); session.finishUseTakes()
        #expect(session.states[0] == .failed(reason: "No clear face in this part.", price: offer.price, mayBill: false))
        #expect(session.applied.isEmpty)
    }

    /// MVP45: a window that couldn't be prepared read "The job could not be completed." and kept no error to log.
    @Test func anUnpreparableWindowSaysWhyAndKeepsItsError() async throws {
        let (session, offer, _) = try setup(failure: .unsupportedVideo)
        await session.refresh()
        #expect(session.start(offer))
        try await session.waitForUseTakes(); session.finishUseTakes()
        #expect(session.states[0] == .failed(reason: "This part cannot be prepared for lip sync. Your original video is unchanged.",
                                             price: offer.price, mayBill: false))
        #expect(session.errors[0] as? LipsyncPreparationError == .unsupportedVideo)
        #expect(!session.start(offer), "the same offer never starts twice")
    }
}
#endif
