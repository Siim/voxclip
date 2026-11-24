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
        for file in ["RewriteLipsyncControls.swift", "RewriteLipsyncWiring.swift"] {
            // Lip Sync All read "≈ ≈ $0.80" (the wiring's title).
            let source = try? String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/VoxClipAppTests/RewriteLipsyncSessionTests.swift", with: "Sources/VoxClip/" + file), encoding: .utf8)
            #expect(source?.contains("≈ \\(") == false, "a literal ≈ before an already formatted price in \(file)")
        }
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
        var lines: [String] = []
    }

    @Test func aPendingQuoteNeedsItsOwnRecoverableProviderReceipt() throws {
        let (_, offer, _) = try setup()
        var attempt = try keptAttempt(offer)
        attempt.keptResult = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), now = attempt.submittedAt
        func price(_ id: UUID, at date: Date, model: WholeClipRevoice.Lipsync = .sync3) -> Decimal? {
            let key = WholeClipRevoiceLedger.LipsyncKey(voice: .init(script: "fixture", recordId: "fixture", model: "eleven_v4"), retime: 1, model: model)
            return RewriteSavedProposal.PendingLipsync(key: key, quoteID: id, videoSHA256: attempt.videoSHA256, audioSHA256: attempt.audioSHA256)
                .acceptedUSD(projectID: project, root: root, now: date)
        }
        #expect(price(offer.id, at: now) == nil)
        try LipsyncAttemptStore.record(attempt, projectID: project, paidRoot: root)
        #expect(price(offer.id, at: now) == attempt.estimate.usd)
        #expect(price(UUID(), at: now) == nil)
        #expect(price(offer.id, at: now, model: .lipsync2) == nil)
        #expect(price(offer.id, at: now.addingTimeInterval(3600)) == nil)
    }

    private func keptAttempt(_ offer: RewriteLipsyncSession.Offer) throws -> LipsyncAttempt {
        let json = """
            {"requestID":"11111111-2222-4333-8444-555555555555","provider":"fal","model":"fal-ai/sync-lipsync/v3",
             "quoteID":"\(offer.id.uuidString)","syncMode":"cut_off","estimate":{"provider":"fal","operation":"lipsync","units":3.4,
             "unit":"second","usd":0.45,"basis":"fixture"},"submittedAt":"2026-11-08T22:49:22Z",
             "videoSHA256":"\(String(repeating: "a", count: 64))","audioSHA256":"\(String(repeating: "b", count: 64))",
             "neededSeconds":3,"uploadedSeconds":3.4,"fps":30,"keptResult":true}
            """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LipsyncAttempt.self, from: Data(json.utf8))
    }

    /// A backend whose first run throws `first`, then returns a result (recovered when the click was free), over fresh
    /// current offers.
    private func failingOnce(_ session: RewriteLipsyncSession, _ offer: RewriteLipsyncSession.Offer, _ log: PayLog,
                             first: any Error) {
        let estimate = offer.estimate
        session.backend = .init(offers: {
            let fresh = RewriteLipsyncSession.Offer(id: UUID(), request: offer.request, windows: offer.windows, estimate: estimate,
                                                    recordID: offer.recordID, dependencies: offer.dependencies, isCurrent: { true })
            return ([0: fresh], fresh)
        }, hasKey: { true }, hasConsent: { true }, acceptConsent: {}, cap: { nil }, run: { _, _, _, _, mayPay, _ in
            log.pays.append(mayPay)
            if log.fail { log.fail = false; throw first }
            var result = Self.result(offer)
            result.recovered = !mayPay
            return result
        }, changed: {}, report: { log.lines.append($0) })
    }

    private static func result(_ offer: RewriteLipsyncSession.Offer) -> ImportedLipsyncResult {
        let asset = VoiceLabVideoAsset(id: UUID().uuidString.lowercased(), file: "fixture.mp4", sha256: String(repeating: "a", count: 64),
            durationSeconds: 3, frameRate: 30, width: 320, height: 180)
        let provenance = LipsyncResultProvenance(provider: "fal", model: "fal-ai/sync-lipsync/v3", requestID: UUID().uuidString.lowercased(),
            quoteID: offer.id, videoInputSHA256: asset.sha256, audioInputSHA256: asset.sha256, outputSHA256: asset.sha256,
            syncMode: .cutOff, seed: nil, submittedAt: Date(), importedAt: Date(), estimate: offer.estimate)
        return ImportedLipsyncResult(asset: asset, url: URL(fileURLWithPath: "/synthetic/result.mp4"), provenance: provenance)
    }

    /// A billed attempt whose result is kept (its download failed: fal.ai still has it). The row says fal.ai charged for
    /// it, Try Again reads "free" and runs without paying (`mayPay` false), and the kept result then applies.
    @Test func aKeptPaidResultMakesTryAgainFreeAndItNeverPays() async throws {
        let (session, offer, _) = try setup()
        let log = PayLog()
        failingOnce(session, offer, log, first: LipsyncAttemptFailure(error: LipsyncError.network, attempt: try keptAttempt(offer), freeRetry: true))
        await session.refresh()
        session.start(try #require(session.offers[0]))
        await session.waitForRun()
        guard case .failed(_, let price, let mayBill) = session.states[0] else { Issue.record("not failed"); return }
        #expect(mayBill && price == VoiceLabCostPresentation.format(Decimal(string: "0.45")!))
        #expect(session.freeRetries == [0])
        #expect(session.failedActions(0) == [.tryAgain(free: true), .keepOriginal])
        #expect(session.failureLine(0)?.hasSuffix("fal.ai accepted the job (estimated cost: ≈ $0.45). Try Again checks the same job for free.") == true)
        let retry = try #require(session.offers[0])
        #expect(RewriteLipsyncControls.title(.tryAgain(free: true), offer: retry) == "Try Again · free")
        session.press(retry)
        await session.waitForRun()
        #expect(log.pays == [true, false], "Try Again · free never pays")
        #expect(session.applied[0]?.result.recovered == true && session.freeRetries.isEmpty)
    }

    /// MVP46's kept result that failed a check: re-checking the same file in this run fails the same way, so the row offers
    /// Keep Original Video and a priced Lip Sync Again, never a free Try Again that can't pass (a restart with a fixed build
    /// re-imports it for free before paying). Before: Try Again · free re-ran the check, failed, then offered a priced one.
    @Test func aKeptResultThatFailedACheckOffersKeepOriginalAndAPricedLipSyncAgain() async throws {
        let (session, offer, _) = try setup()
        let log = PayLog()
        let json = """
            {"requestID":"11111111-2222-4333-8444-555555555555","provider":"fal","model":"fal-ai/sync-lipsync/v3",
             "quoteID":"\(offer.id.uuidString)","syncMode":"cut_off","estimate":{"provider":"fal","operation":"lipsync","units":3.4,
             "unit":"second","usd":0.45,"basis":"fixture"},"submittedAt":"2026-11-08T22:49:22Z",
             "videoSHA256":"\(String(repeating: "a", count: 64))","audioSHA256":"\(String(repeating: "b", count: 64))",
             "neededSeconds":3,"uploadedSeconds":3.4,"fps":30,"keptResult":true}
            """
        let check = LipsyncResultCheck.duration(LipsyncResultLength(got: 2.8, needed: 3, uploaded: 3.4, fps: 30))
        failingOnce(session, offer, log, first: LipsyncAttemptFailure(error: check, attempt: try keptAttempt(offer), freeRetry: true))
        await session.refresh()
        session.start(try #require(session.offers[0]))
        await session.waitForRun()
        guard case .failed(let reason, let price, let mayBill) = session.states[0] else { Issue.record("not failed"); return }
        #expect(reason == "fal.ai's video came back 0.2 s shorter than the voice." && mayBill)
        #expect(session.freeRetries.isEmpty && session.repeatingChecks == [0])
        #expect(session.failureLine(0)
            == "Couldn't lip sync phrase 1: fal.ai's video came back 0.2 s shorter than the voice. fal.ai accepted the job (estimated cost: ≈ $0.45).")
        #expect(RewriteLipsyncSession.failureLine(phrase: 0, reason: reason, price: price, mayBill: mayBill, free: false) == session.failureLine(0))
        #expect(session.failedActions(0) == [.keepOriginal, .lipSyncAgain])
        let again = try #require(session.offers[0])
        #expect(RewriteLipsyncControls.title(.lipSyncAgain, offer: again) == "Lip Sync Again · ≈ $0.40")
        session.press(again)
        await session.waitForRun()
        #expect(log.pays == [true, true], "Lip Sync Again is the priced job it says")
        #expect(session.applied[0] != nil && session.repeatingChecks.isEmpty)
        // Keep Original Video dismisses a stop, keeping nothing applied.
        log.fail = true
        session.undo(0)
        session.start(try #require(session.offers[0]))
        await session.waitForRun()
        session.keepOriginal(0)
        #expect(session.states[0] == nil && session.repeatingChecks.isEmpty && session.errors[0] == nil)
    }

    /// A paid result that came back after the takes changed (an autosave, an outside edit while fal.ai worked) is kept,
    /// never shown as cancelled: the row says it was charged, and Try Again puts it in for free. Before: "Cancelled", the
    /// result dropped, and a priced Try Again.
    @Test func aResultThatComesBackAfterTheTakesChangedIsKeptNotCancelled() async throws {
        let (session, offer, gate) = try setup()
        let log = PayLog()
        let backend = try #require(session.backend)
        session.backend = .init(offers: backend.offers, hasKey: backend.hasKey, hasConsent: backend.hasConsent,
            acceptConsent: backend.acceptConsent, cap: backend.cap, run: backend.run, changed: {}, report: { log.lines.append($0) })
        await session.refresh(); session.start(offer)
        await TestDeadline.until { gate.started }
        gate.current = false
        gate.release()
        await session.waitForRun()
        guard case .failed(let reason, _, let mayBill) = session.states[0] else { Issue.record("not kept: \(String(describing: session.states[0]))"); return }
        #expect(mayBill && reason == "Lip sync finished after the takes changed. It's kept: Try Again puts it in for free.")
        #expect(session.applied.isEmpty && session.freeRetries == [0])
        let failure = try #require(session.errors[0] as? LipsyncAttemptFailure)
        #expect(failure.freeRetry && failure.error is RewriteLipsyncSession.SetAside && failure.attempt.estimate == offer.estimate)
        #expect(session.failureLine(0)?.hasPrefix("Phrase 1: Lip sync finished after the takes changed.") == true)
        #expect(session.failedActions(0) == [.tryAgain(free: true), .keepOriginal])
        #expect(session.receipts[0].requestIDs.count == 1)
        #expect(log.lines == ["lipsync result set-aside reason=stale"])
    }

    /// An offer error other than a change in the takes says what failed, is logged with its kind, and the row offers
    /// Prepare Lip Sync Again. Before: "Choose a passing take and its video duration…" whatever failed.
    @Test func anOfferErrorShowsItsOwnCopyAndCanBePreparedAgain() async throws {
        let (session, offer, _) = try setup()
        let log = PayLog()
        session.backend = .init(offers: {
            if log.fail { throw ClipTakePlan.Failure.missingLipsyncRender }
            return ([0: offer], offer)
        }, hasKey: { true }, hasConsent: { true }, acceptConsent: {}, cap: { nil }, run: { _, _, _, _, _, _ in throw CancellationError() },
           changed: {}, report: { log.lines.append($0) })
        await session.refresh()
        #expect(session.problem == ClipTakePlan.copy(ClipTakePlan.Failure.missingLipsyncRender))
        #expect(session.offersFailed && session.offers.isEmpty)
        #expect(log.lines == ["lipsync offers failure type=ClipTakePlan.Failure case=missingLipsyncRender"])
        log.fail = false
        await session.refresh()
        #expect(!session.offersFailed && session.problem.isEmpty && session.offers[0] != nil)
    }

    /// A button over an offer that went stale says why on the row and makes fresh offers. Before: the click did nothing.
    @Test func aStaleOfferButtonSaysWhy() async throws {
        let (session, offer, gate) = try setup()
        await session.refresh()
        gate.current = false
        #expect(session.hasStaleOffer)
        session.press(offer)
        #expect(session.problem == ClipTakePlan.copy(ClipTakePlan.Failure.stale))
        #expect(session.states.isEmpty && session.receipts.isEmpty && !session.running)
    }

    /// Lip Sync All over two windows, the first failing after fal.ai accepted it: only its phrase is billed and gets the
    /// free retry; the second window never ran, so its phrase goes back to its offer. Before: both said fal.ai accepted
    /// the job, and phrase 2's free Try Again could only fail.
    @Test func lipSyncAllAttributesAFailureToTheWindowThatRan() async throws {
        let (session, template, _) = try setup()
        let piece = VoiceLabOutputPiece(kind: .source, sourceStartSample: 0, sourceEndSample: 480_000,
            outputStartSample: 0, outputEndSample: 480_000, segmentId: nil, assetId: nil, audio: nil)
        let plan = VoiceLabOutputPlan(sampleRate: 48_000, totalSourceSamples: 480_000, pieces: [piece], captions: [], scope: .full)
        let second = try LipsyncRenderWindow(source: LipsyncWindow.make(seamIn: 336_000, seamOut: 384_000, totalSamples: 480_000,
                                                                        sampleRate: 48_000, phraseID: 1), plan: plan)
        let all = RewriteLipsyncSession.Offer(id: UUID(), request: template.request, windows: template.windows + [second],
            estimate: template.estimate, recordID: template.recordID, dependencies: [0, 1], isCurrent: { true })
        var runs = 0
        session.backend = .init(offers: { ([:], all) }, hasKey: { true }, hasConsent: { true }, acceptConsent: {}, cap: { nil },
            run: { _, _, _, _, _, _ in
                runs += 1
                throw LipsyncAttemptFailure(error: LipsyncError.network, attempt: try self.keptAttempt(template), freeRetry: true)
            }, changed: {})
        await session.refresh()
        #expect(session.start(all))
        await session.waitForRun()
        #expect(runs == 1)
        guard case .failed(_, _, let mayBill) = session.states[0] else { Issue.record("phrase 1 not failed"); return }
        #expect(mayBill && session.freeRetries == [0])
        #expect(session.states[1] == nil && session.errors[1] == nil, "phrase 2 never ran: back to its offer")
    }

    /// fal.ai's refusals at submit lead somewhere: a refused key to Settings, media it can't use to Keep Original first.
    @Test func aDeclinedSubmitLeadsToTheFixThatCanWork() async throws {
        for (status, actions, copy) in [
            (401, [RewriteLipsyncSession.FailedAction.settings, .tryAgain(free: false)], "fal.ai didn't accept your key (HTTP 401). Check it in Settings → Voice Lab."),
            (402, [.tryAgain(free: false), .keepOriginal], "Your fal.ai account needs credit (HTTP 402). Add credit at fal.ai, then try again."),
            (422, [.keepOriginal, .lipSyncAgain], "fal.ai couldn't use this part's video and audio (HTTP 422)."),
        ] {
            let (session, offer, _) = try setup()
            let log = PayLog()
            failingOnce(session, offer, log, first: LipsyncNotSubmitted(error: LipsyncError.http(status), queueRefused: true))
            await session.refresh(); session.start(try #require(session.offers[0])); await session.waitForRun()
            guard case .failed(let reason, _, let mayBill) = session.states[0] else { Issue.record("\(status) not failed"); continue }
            #expect(!mayBill && reason == "The lip-sync request was declined. " + copy, Comment(rawValue: "\(status)"))
            #expect(session.failedActions(0) == actions, Comment(rawValue: "\(status)"))
        }
    }

    /// fal.ai still running the earlier paid job: nothing new is paid, and checking again is free.
    @Test func aStillRunningEarlierJobOffersAFreeCheckAgain() async throws {
        let (session, offer, _) = try setup()
        let log = PayLog()
        failingOnce(session, offer, log, first: LipsyncError.stillRunning)
        await session.refresh(); session.start(try #require(session.offers[0])); await session.waitForRun()
        guard case .failed(_, _, let mayBill) = session.states[0] else { Issue.record("not failed"); return }
        #expect(!mayBill && session.freeRetries == [0])
        #expect(session.failedActions(0) == [.checkAgain, .keepOriginal])
        session.press(try #require(session.offers[0])); await session.waitForRun()
        #expect(log.pays == [true, false] && session.applied[0] != nil)
    }

    /// A free check that met a passing error stays free; one that can't help any more makes the next one priced.
    @Test(arguments: [false, true]) func aRecoveryFailureIsFreeToRetryOnlyWhileItCanPass(settled: Bool) async throws {
        let (session, offer, _) = try setup()
        let log = PayLog()
        failingOnce(session, offer, log, first: LipsyncRecoveryFailed(error: LipsyncError.network, settled: settled))
        await session.refresh(); session.start(try #require(session.offers[0])); await session.waitForRun()
        #expect(session.freeRetries == (settled ? [] : [0]))
        #expect(session.failedActions(0) == [.tryAgain(free: !settled), .keepOriginal])
    }

    /// A backend over fresh current offers (phrase 0's, and Lip Sync All's when `all` is given) whose run records `mayPay`
    /// and returns a result (recovered when the click was free), or, when `gone` and free, what `LipsyncRun` throws when the
    /// window's imported result is no longer on this Mac.
    @MainActor private final class ReuseLog {
        var pays: [Bool] = []
        var gone = false
    }

    private func reusing(_ session: RewriteLipsyncSession, _ template: RewriteLipsyncSession.Offer, _ log: ReuseLog,
                         all: (() -> RewriteLipsyncSession.Offer)? = nil, indexed: Bool = false) {
        session.backend = .init(offers: {
            let fresh = RewriteLipsyncSession.Offer(id: UUID(), request: template.request, windows: template.windows,
                estimate: template.estimate, recordID: template.recordID, dependencies: template.dependencies, isCurrent: { true })
            return ([0: fresh], all?() ?? fresh)
        }, hasKey: { true }, hasConsent: { true }, acceptConsent: {}, cap: { .init(limit: Decimal(string: "0.3")!, spent: 0) },
           run: { _, _, _, _, mayPay, _ in
            log.pays.append(mayPay)
            if log.gone, !mayPay { throw LipsyncRecoveryFailed(error: LipsyncError.unknownJob, settled: true) }
            var result = Self.result(template)
            result.recovered = !mayPay
            return result
        }, changed: {}, indexedWindows: { offer in indexed && !log.gone ? Set(offer.windows.indices) : [] })
    }

    @Test func aFreshSessionOffersAnIndexedResultForFreeBeforeAnyClick() async throws {
        let (_, template, _) = try setup()
        let relaunched = RewriteLipsyncSession(), log = ReuseLog()
        reusing(relaunched, template, log, indexed: true)
        await relaunched.refresh()
        let offer = try #require(relaunched.offers[0])
        #expect(offer.charge == "free" && relaunched.allOffer?.free == true)
        #expect(log.pays.isEmpty)

        relaunched.press(offer)
        await relaunched.waitForRun()
        #expect(log.pays == [false] && relaunched.applied[0]?.result.recovered == true)

        let nextLaunch = RewriteLipsyncSession()
        reusing(nextLaunch, template, log, indexed: true)
        await nextLaunch.refresh()
        let freeClick = try #require(nextLaunch.offers[0])
        log.gone = true
        nextLaunch.press(freeClick)
        await nextLaunch.waitForRun()
        #expect(log.pays == [false, false])
        #expect(nextLaunch.offers[0]?.charge == "≈ $0.40")
    }

    /// Undo keeps the paid result findable (the window's imported index): the next Lip Sync over the same takes gets it back,
    /// and its button says so ("free"), never the price it won't charge. When that result is gone from this Mac, the click
    /// still pays nothing and says why, and the next offer is priced again. Before: "Lip Sync · ≈ $0.40" for a free click.
    @Test func anUndoneResultIsOfferedBackForFree() async throws {
        let (session, template, _) = try setup()
        let log = ReuseLog()
        reusing(session, template, log)
        await session.refresh()
        let first = try #require(session.offers[0])
        #expect(!first.free && first.charge == "≈ $0.40" && session.capWarning(for: first) != nil)
        session.press(first); await session.waitForRun()
        #expect(session.applied[0] != nil)
        session.undo(0)
        await session.refresh()
        let again = try #require(session.offers[0])
        #expect(again.free && again.charge == "free" && again.price == "≈ $0.40")
        #expect(RewriteLipsyncControls.price(again, free: false) == "free")
        #expect(session.capWarning(for: again) == nil)
        session.press(again); await session.waitForRun()
        #expect(log.pays == [true, false], "the click said free and paid nothing")
        #expect(session.applied[0]?.result.recovered == true)
        // The kept file was removed meanwhile: nothing is paid, the row says why, and the next offer is priced.
        session.undo(0)
        await session.refresh()
        log.gone = true
        session.press(try #require(session.offers[0])); await session.waitForRun()
        guard case .failed(let reason, _, let mayBill) = session.states[0] else { Issue.record("not failed"); return }
        #expect(reason == RewriteLipsyncSession.reuseGone && !mayBill)
        #expect(log.pays == [true, false, false])
        let priced = try #require(session.offers[0])
        #expect(!priced.free && priced.charge == "≈ $0.40")
        #expect(session.failedActions(0) == [.tryAgain(free: false), .keepOriginal])
    }

    /// Lip Sync All over a reused window and a new one charges only the new one's share, pays only for it, and its first
    /// window puts the earlier result back for free. Before: the button said both windows' price.
    @Test func lipSyncAllChargesOnlyTheWindowsItBuys() async throws {
        let (session, template, _) = try setup()
        let piece = VoiceLabOutputPiece(kind: .source, sourceStartSample: 0, sourceEndSample: 480_000,
            outputStartSample: 0, outputEndSample: 480_000, segmentId: nil, assetId: nil, audio: nil)
        let plan = VoiceLabOutputPlan(sampleRate: 48_000, totalSourceSamples: 480_000, pieces: [piece], captions: [], scope: .full)
        let second = try LipsyncRenderWindow(source: LipsyncWindow.make(seamIn: 336_000, seamOut: 384_000, totalSamples: 480_000,
                                                                        sampleRate: 48_000, phraseID: 1), plan: plan)
        var both = template.estimate; both.usd = Decimal(string: "0.8")
        let log = ReuseLog()
        reusing(session, template, log) {
            RewriteLipsyncSession.Offer(id: UUID(), request: template.request, windows: template.windows + [second],
                                        estimate: both, recordID: template.recordID, dependencies: [0, 1], isCurrent: { true })
        }
        await session.refresh()
        #expect(session.allOffer?.charge == "≈ $0.80")
        session.press(try #require(session.offers[0])); await session.waitForRun()
        session.undo(0)
        await session.refresh()
        let all = try #require(session.allOffer)
        #expect(all.freeWindows == [0] && !all.free)
        #expect(all.price == "≈ $0.80" && all.charge == "≈ $0.40")
        #expect(session.allDisclosure?.hasPrefix("Uploads 1 phrases' prepared video") == true)
        #expect(session.allDisclosure?.contains("One phrase gets its paid lip sync back, for free.") == true)
        session.press(all); await session.waitForRun()
        #expect(log.pays == [true, false, true], "the reused window is free, the new one is paid")
        #expect(session.applied[0] != nil && session.applied[1] != nil)
    }

    /// A stop that lands just as fal.ai finished (Rewrite closing, or Cancel on the row): the job is billed and its result can
    /// be fetched for free, so the row says it was charged and kept, with Try Again · free. Before: "Lip sync cancelled. fal.ai
    /// may still charge" with a priced Try Again (Rewrite stopping), or "The job could not be completed." (the row's Cancel).
    @Test(arguments: [true, false]) func aStopAfterFalFinishedKeepsTheFreeRetry(closing: Bool) async throws {
        let (session, offer, gate) = try setup()
        let attempt = try keptAttempt(offer)
        session.backend = .init(offers: { ([0: offer], offer) }, hasKey: { true }, hasConsent: { true }, acceptConsent: {}, cap: { nil },
            run: { _, _, _, _, _, _ in
                await gate.wait()
                throw LipsyncAttemptFailure(error: CancellationError(), attempt: attempt, freeRetry: true)
            }, changed: {})
        await session.refresh(); session.start(offer)
        await TestDeadline.until { gate.started }
        if closing { session.stop() } else { session.cancel(0) }
        gate.release()
        await session.waitForRun()
        guard case .failed(let reason, let price, let mayBill) = session.states[0] else {
            Issue.record("not kept: \(String(describing: session.states[0]))"); return
        }
        #expect(reason == "Lip sync finished before the cancel reached fal.ai. It's kept: Try Again puts it in for free.")
        #expect(mayBill && price == VoiceLabCostPresentation.format(Decimal(string: "0.45")!))
        #expect(session.freeRetries == [0])
        #expect(session.failedActions(0) == [.tryAgain(free: true), .keepOriginal])
        #expect(session.failureLine(0) == "Phrase 1: \(reason) fal.ai charged for the job (estimated cost: ≈ $0.45).")
    }

    /// A stop on this Mac that the same inputs meet again offers no Try Again: Keep Original Video (a new take or wording
    /// makes a new offer). A missing key leads to Settings, and an unwritable file can pass once the disk has room.
    @Test func aDeterministicLocalStopOffersNoTryAgain() async throws {
        let attempt = try keptAttempt(try setup().1)
        let cases: [(any Error, [RewriteLipsyncSession.FailedAction])] = [
            (LipsyncPreparationError.noClearFace, [.keepOriginal]),
            (LipsyncPreparationError.unsupportedVideo, [.keepOriginal]),
            (LipsyncError.invalidInput, [.keepOriginal]),
            (LipsyncAttemptFailure(error: LipsyncError.invalidInput, attempt: attempt, freeRetry: false), [.keepOriginal]),
            (LipsyncError.missingKey, [.settings, .tryAgain(free: false)]),
            (LipsyncError.unsafeFile, [.tryAgain(free: false), .keepOriginal]),
        ]
        for (error, actions) in cases {
            let (session, offer, _) = try setup()
            let log = PayLog()
            failingOnce(session, offer, log, first: error)
            await session.refresh(); session.start(try #require(session.offers[0])); await session.waitForRun()
            #expect(session.failedActions(0) == actions, Comment(rawValue: String(describing: error)))
        }
    }

    /// The whole clip's restore (package B): applied entries go back when nothing runs and they match a current offer over
    /// the same phrases; a stale offer, or a phrase applied meanwhile, changes nothing.
    @Test func restorePutsBackMatchingEntriesOnly() async throws {
        let (session, offer, gate) = try setup()
        await session.refresh(); session.start(offer)
        await TestDeadline.until { gate.started }
        let early = session.applied
        #expect(!session.restore(early, matching: offer), "nothing to restore while it runs")
        gate.release()
        await session.waitForRun()
        let entries = session.applied
        #expect(entries.count == 1)
        #expect(!session.restore(entries, matching: offer), "already applied")
        session.undo(0)
        let fresh = RewriteLipsyncSession.Offer(id: UUID(), request: offer.request, windows: offer.windows, estimate: offer.estimate,
                                                recordID: offer.recordID, dependencies: offer.dependencies, isCurrent: { gate.current })
        gate.current = false
        #expect(!session.restore(entries, matching: fresh), "a stale offer")
        gate.current = true
        let other = RewriteLipsyncSession.Offer(id: UUID(), request: offer.request, windows: offer.windows, estimate: offer.estimate,
                                                recordID: offer.recordID, dependencies: [0], isCurrent: { true })
        #expect(!session.restore(entries, matching: other), "other dependencies")
        #expect(session.restore(entries, matching: fresh))
        #expect(session.applied[0]?.result == entries[0]?.result && session.applied[0]?.window == offer.windows[0])
        guard case .done = session.states[0] else { Issue.record("not done"); return }
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
        #expect(reason == "Stopped before submitting a lip-sync job. The media didn't pass the lip-sync file checks.")
    }

    @Test func anExplicitlyFreeOfferStaysFreeEvenWithoutAPhraseMarker() async throws {
        let (session, template, _) = try setup()
        var sent: [Bool] = []
        var offer = template; offer.mayPay = false
        session.backend = .init(offers: { ([0: template], template) }, hasKey: { true }, hasConsent: { true }, acceptConsent: {}, cap: { nil },
            run: { _, _, _, _, mayPay, _ in sent.append(mayPay); throw LipsyncRecoveryFailed(error: LipsyncError.unknownJob) }, changed: {})
        await session.refresh(); session.start(offer); await session.waitForRun()
        #expect(sent == [false])
    }

    @Test func anUnconfirmedSubmissionBlocksIndividualAndCombinedRetries() async throws {
        let (session, offer, _) = try setup()
        var submitted = 0
        session.backend = .init(offers: {
            let next = RewriteLipsyncSession.Offer(id: UUID(), request: offer.request, windows: offer.windows, estimate: offer.estimate,
                recordID: offer.recordID, dependencies: offer.dependencies, isCurrent: { true })
            return ([0: next], next)
        }, hasKey: { true }, hasConsent: { true }, acceptConsent: {}, cap: { nil }, run: { _, _, _, _, _, _ in
            submitted += 1; throw LipsyncError.submissionUncertain
        }, changed: {})
        await session.refresh(); session.start(offer); await session.waitForRun()
        guard case .failed(let reason, let price, let mayBill) = session.states[0] else { Issue.record("expected a stop"); return }
        let line = RewriteLipsyncSession.failureLine(phrase: 0, reason: reason, price: price, mayBill: mayBill, free: false,
            unconfirmed: session.submissionUnconfirmed(0))
        #expect(line.contains("couldn't confirm") && !line.contains("No new lip-sync charge") && !line.contains("charged for the attempt"))
        let fresh = try #require(session.offers[0]); #expect(!session.start(fresh))
        #expect(session.allOffer == nil && session.receipts.count == 1 && submitted == 1)
        // The way out is the user's own: after checking fal.ai, another paid job (it may charge twice). Before: none.
        #expect(session.failedActions(0) == [.checkedFal, .keepOriginal])
        #expect(RewriteLipsyncControls.title(.checkedFal, offer: fresh) == "I Checked fal.ai · Lip Sync Again · ≈ $0.40 (fal.ai may charge twice)")
        try session.startAfterCheckingFal(fresh)
        await session.waitForRun()
        #expect(submitted == 2)
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
        #expect(session.receipts.count == 1 && session.receipts[0].requestIDs.count == 1, "the charge stays on the receipt")
        if invalidate {
            // The user discarded it: the phrase goes back to its offer (the result stays findable by the same inputs).
            #expect(session.states[0] == nil && session.freeRetries.isEmpty)
        } else {
            // A cancel that landed after fal.ai finished: kept, charged, and Try Again is free.
            guard case .failed(let reason, _, true) = session.states[0] else { Issue.record("not kept"); return }
            #expect(reason == "Lip sync finished before the cancel reached fal.ai. It's kept: Try Again puts it in for free.")
            #expect(session.freeRetries == [0])
        }
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
