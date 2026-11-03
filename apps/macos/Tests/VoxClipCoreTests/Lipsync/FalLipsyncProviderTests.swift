#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore

@Suite("Fal lip-sync bounded jobs", .timeLimit(.minutes(1)), .offlineFixtures)
struct FalLipsyncProviderTests {
    private typealias Fixtures = LipsyncProviderFixtures

    @Test func bareContractCannotSubmitOrDownloadArbitraryResults() async throws {
        let http = LipsyncFixtureHTTP([]), provider = try Fixtures.provider(http)
        await #expect(throws: LipsyncError.approvalRequired) {
            _ = try await provider.submit(provider.models[0], video: URL(fileURLWithPath: "/private/tmp/source.mp4"),
                                          audio: URL(fileURLWithPath: "/private/tmp/source.wav"), options: .init(syncMode: .cutOff))
        }
        await #expect(throws: LipsyncError.unknownJob) { try await provider.download(Fixtures.result, to: URL(fileURLWithPath: "/private/tmp/output.mp4")) }
        #expect(await http.requests.isEmpty); #expect(await http.downloads.isEmpty)
    }

    @Test func existingContractCanSubmitOnlyThroughTheApprovalBoundFacade() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt())]), provider = try Fixtures.provider(http)
        let quote = try await Fixtures.quote(provider), approval = try await Fixtures.approval(provider, quote: quote, root: root)
        let approved: any LipsyncProvider = try await provider.approvedProvider(using: approval)
        await #expect(throws: LipsyncError.approvalRequired) {
            _ = try await approved.submit(quote.model, video: quote.video.url, audio: quote.audio.url, options: .init(syncMode: .remap))
        }
        #expect(await http.requests.isEmpty)
        let job = try await approved.submit(quote.model, video: quote.video.url, audio: quote.audio.url, options: quote.options)
        #expect(job.model == quote.model); #expect(approved.models == [quote.model])
        #expect(await http.requests.count == 1)
    }

    @Test func estimatesUseExistingCatalogNotInventedFPSPricing() async throws {
        let provider = try Fixtures.provider(LipsyncFixtureHTTP([]))
        #expect(try await provider.estimate(provider.models[0], seconds: 10, fps: 30).usd == Decimal(string: "0.20"))
        #expect(try await provider.estimate(provider.models[0], seconds: 50, fps: 30).usd == Decimal(string: "0.25"))
        #expect(try await provider.estimate(provider.models[1], seconds: 10, fps: 30).usd == Decimal(string: "0.50"))
        #expect(try await provider.estimate(provider.models[2], seconds: 60, fps: 30).usd == Decimal(5))
        #expect(try await provider.estimate(provider.models[3], seconds: 60, fps: 60).usd == Decimal(8))
        for value in [Double.nan, Double.infinity, 0, 301] {
            await #expect(throws: LipsyncError.invalidInput) { _ = try await provider.estimate(provider.models[0], seconds: value, fps: 30) }
        }
    }

    @Test func invalidModelRemapAndSeedAreNeverSilentlyChanged() async throws {
        let provider = try Fixtures.provider(LipsyncFixtureHTTP([]))
        await #expect(throws: LipsyncError.invalidInput) { _ = try await Fixtures.quote(provider, mode: .remap) }
        await #expect(throws: LipsyncError.invalidInput) { _ = try await Fixtures.quote(provider, modelIndex: 1, seed: 4) }
        var model = provider.models[0]; model.supportsRemap = true
        await #expect(throws: LipsyncError.unsupportedModel) { _ = try await provider.estimate(model, seconds: 10, fps: 30) }
    }

    @Test func remapPreviewDoesNotUnderquoteALongerAudioWindow() async throws {
        let provider = try Fixtures.provider(LipsyncFixtureHTTP([]))
        let quote = try await provider.quote(model: provider.models[1], video: Fixtures.input(), audio: Fixtures.input(video: false, seconds: 20),
                                              options: .init(syncMode: .remap), fps: 30)
        #expect(quote.outputDurationSeconds == 20)
        #expect(quote.estimate.units == 20); #expect(quote.estimate.usd == Decimal(1))
    }

    @Test(arguments: [0, 1, 2, 3]) func exactRequestSchemasAndReturnedRootURLs(modelIndex: Int) async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = modelIndex == 0 ? "fal-ai/latentsync" : "fal-ai/sync-lipsync"
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt(app: app)), .json(200, Fixtures.completed), .json(200, Fixtures.output)])
        let provider = try Fixtures.provider(http)
        let quote = try await Fixtures.quote(provider, modelIndex: modelIndex, seed: modelIndex == 0 ? 42 : nil)
        let approval = try await Fixtures.approval(provider, quote: quote, root: root)
        let job = try await provider.submit(quote, approval: approval)
        #expect(try await provider.poll(job) == .done(Fixtures.result))
        let requests = await http.requests
        let data = try #require(requests[0].httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.path == "/" + quote.model.id.components(separatedBy: ":")[0])
        #expect(requests[1].url == job.statusURL); #expect(requests[2].url == job.responseURL)
        #expect(body["enable_safety_checker"] as? Bool == true)
        #expect(body["video_url"] as? String == quote.video.url.absoluteString)
        #expect(body["audio_url"] as? String == quote.audio.url.absoluteString)
        if modelIndex == 0 {
            #expect(body["guidance_scale"] as? Double == 1); #expect(body["seed"] as? Int == 42)
            #expect(body["sync_mode"] == nil); #expect(body["model"] == nil)
        } else {
            #expect(body["seed"] == nil); #expect(body["sync_mode"] as? String == "cut_off")
            #expect(body["model"] as? String == (modelIndex == 3 ? nil : modelIndex == 1 ? "lipsync-2" : "lipsync-2-pro"))
        }
    }

    @Test func consentAndTransferConfirmationAreBothRequired() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncFixtureHTTP([]), provider = try Fixtures.provider(http)
        let quote = try await Fixtures.quote(provider), (store, id) = try await Fixtures.consent(root)
        await #expect(throws: LipsyncError.approvalRequired) {
            _ = try await provider.approve(quote, consentStore: store, recordID: id, acceptsPaidJob: false, acceptsMediaTransfer: true)
        }
        await #expect(throws: LipsyncError.approvalRequired) {
            _ = try await provider.approve(quote, consentStore: store, recordID: id, acceptsPaidJob: true, acceptsMediaTransfer: false)
        }
        try await store.removeFromVoxClipOnly(id)
        await #expect(throws: VoiceConsentError.inactive) {
            _ = try await provider.approve(quote, consentStore: store, recordID: id, acceptsPaidJob: true, acceptsMediaTransfer: true)
        }
        #expect(await http.requests.isEmpty)
    }

    @Test func withdrawalBetweenApprovalAndDispatchStopsTransport() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncFixtureHTTP([]), provider = try Fixtures.provider(http)
        let quote = try await Fixtures.quote(provider), (store, id) = try await Fixtures.consent(root)
        let approval = try await provider.approve(quote, consentStore: store, recordID: id, acceptsPaidJob: true, acceptsMediaTransfer: true)
        try await store.removeFromVoxClipOnly(id)
        await #expect(throws: VoiceConsentError.inactive) { _ = try await provider.submit(quote, approval: approval) }
        #expect(await http.requests.isEmpty)
    }

    @Test func approvalCannotReplayAndAcceptedSpendIsWrittenOnce() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let spend = VoiceLabSpendLedger(url: root.appendingPathComponent("spend.json"), timeZone: TimeZone(secondsFromGMT: 0)!)
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt()), .json(200, Fixtures.completed), .json(200, Fixtures.output)])
        let provider = try Fixtures.provider(http, spend: spend), quote = try await Fixtures.quote(provider)
        let approval = try await Fixtures.approval(provider, quote: quote, root: root)
        let job = try await provider.submit(quote, approval: approval)
        _ = try await provider.poll(job)
        await #expect(throws: LipsyncError.approvalRequired) { _ = try await provider.submit(quote, approval: approval) }
        #expect(await http.requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(await spend.total(provider: "fal", at: job.submittedAt)?.usd == quote.estimate.usd)
        #expect(await provider.status(quoteID: quote.id)?.billing == .accepted)
    }

    @Test func changedKeyAndMonotonicExpiryInvalidateAnApproval() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncFixtureHTTP([]), keys = LipsyncFixtureKeys(), clock = LipsyncFixtureClock()
        let provider = try Fixtures.provider(http, clock: clock, keys: keys)
        let quote = try await Fixtures.quote(provider), approval = try await Fixtures.approval(provider, quote: quote, root: root)
        await keys.replace()
        await #expect(throws: LipsyncError.approvalRequired) { _ = try await provider.submit(quote, approval: approval) }
        let next = try await Fixtures.quote(provider)
        clock.state.withLock { $0.uptime += .seconds(301); $0.wall.addTimeInterval(-3_600) }
        let (store, id) = try await Fixtures.consent(root)
        await #expect(throws: LipsyncError.expiredQuote) {
            _ = try await provider.approve(next, consentStore: store, recordID: id, acceptsPaidJob: true, acceptsMediaTransfer: true)
        }
        #expect(await http.requests.isEmpty)
    }

    @Test(arguments: [429, 500, 503]) func submitRetriesOnlyTwoTimesAfterExplicitResponse(status: Int) async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncFixtureHTTP(Array(repeating: .json(status, #"{"error":"synthetic failure"}"#), count: 3))
        let provider = try Fixtures.provider(http), quote = try await Fixtures.quote(provider)
        let approval = try await Fixtures.approval(provider, quote: quote, root: root)
        await #expect(throws: LipsyncError.http(status)) { _ = try await provider.submit(quote, approval: approval) }
        #expect(await http.requests.count == 3)
        #expect(await provider.status(quoteID: quote.id) == nil)
    }

    @Test func lostSubmissionReceiptBlocksAnotherPaidDispatch() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncFixtureHTTP([.network]), provider = try Fixtures.provider(http)
        let quote = try await Fixtures.quote(provider), approval = try await Fixtures.approval(provider, quote: quote, root: root)
        await #expect(throws: LipsyncError.submissionUncertain) { _ = try await provider.submit(quote, approval: approval) }
        await #expect(throws: LipsyncError.busy) { _ = try await provider.submit(quote, approval: approval) }
        #expect(await provider.status(quoteID: quote.id)?.billing == .submissionUncertain)
        #expect(await http.requests.count == 1)
    }

    @Test func approvalIsBoundToExactOptionsAndMediaQuote() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt())]), provider = try Fixtures.provider(http)
        let original = try await Fixtures.quote(provider, seed: 42)
        let changed = try await Fixtures.quote(provider, seed: 43)
        let approval = try await Fixtures.approval(provider, quote: original, root: root)
        await #expect(throws: LipsyncError.approvalRequired) { _ = try await provider.submit(changed, approval: approval) }
        #expect(await http.requests.isEmpty)
        let job = try await provider.submit(original, approval: approval)
        #expect(job.remoteID == Fixtures.requestID)
        #expect(await http.requests.count == 1)
    }

    @Test func cancelledSubmitStillRetainsALateAcceptedReceiptAndBillingWarning() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let barrier = LipsyncFixtureBarrier()
        let http = LipsyncFixtureHTTP([.held(Fixtures.receipt(), barrier), .json(202, #"{"status":"CANCELLATION_REQUESTED"}"#)])
        let provider = try Fixtures.provider(http), quote = try await Fixtures.quote(provider)
        let approval = try await Fixtures.approval(provider, quote: quote, root: root)
        let submission = Task { try await provider.submit(quote, approval: approval) }
        try await barrier.waitUntilEntered()
        submission.cancel()
        await barrier.release()
        let job = try await submission.value
        #expect(job.remoteID == Fixtures.requestID)
        #expect(await provider.status(quoteID: quote.id)?.cancelled == true)
        #expect(await provider.status(quoteID: quote.id)?.billing.mayBill == true)
        #expect(await http.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func forgedJobCannotRedirectAnAuthenticatedFollowUp() async throws {
        let http = LipsyncFixtureHTTP([]), provider = try Fixtures.provider(http)
        let job = LipsyncJob(model: provider.models[0], remoteID: Fixtures.requestID,
                             statusURL: URL(string: "https://127.0.0.1/status"), submittedAt: Date())
        await #expect(throws: LipsyncError.unknownJob) { _ = try await provider.poll(job) }
        await provider.cancel(job); await provider.cleanup(job)
        #expect(await http.requests.isEmpty)
    }

    @Test func cancellationSuppressesAnAlreadyInFlightLateCompletion() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let barrier = LipsyncFixtureBarrier()
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt()), .held(Fixtures.completed, barrier), .json(202, #"{"status":"CANCELLATION_REQUESTED"}"#)])
        let provider = try Fixtures.provider(http), quote = try await Fixtures.quote(provider)
        let approval = try await Fixtures.approval(provider, quote: quote, root: root)
        let job = try await provider.submit(quote, approval: approval)
        let polling = Task { try await provider.poll(job) }
        try await barrier.waitUntilEntered()
        await provider.cancel(job)
        await barrier.release()
        await #expect(throws: CancellationError.self) { _ = try await polling.value }
        #expect(await provider.status(quoteID: quote.id)?.billing == .cancellationRequested)
        #expect(await provider.status(quoteID: quote.id)?.billing.mayBill == true)
        #expect(await http.requests.count == 3)
        await #expect(throws: CancellationError.self) { _ = try await provider.poll(job) }
    }

    @Test func cancelledCallerCannotConsumeACachedTerminalResult() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt()), .json(200, Fixtures.completed), .json(200, Fixtures.output)])
        let provider = try Fixtures.provider(http), quote = try await Fixtures.quote(provider)
        let approval = try await Fixtures.approval(provider, quote: quote, root: root), job = try await provider.submit(quote, approval: approval)
        _ = try await provider.poll(job)
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.wait(job)
        }
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        let polling = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.poll(job)
        }
        await #expect(throws: CancellationError.self) { _ = try await polling.value }
        #expect(await http.requests.count == 3)
    }

    @Test(arguments: [200, 400]) func cancelDoesNotPromiseARefund(status: Int) async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let body = status == 200 ? #"{"status":"OK"}"# : #"{"status":"ALREADY_COMPLETED"}"#
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt()), .json(status, body)])
        let provider = try Fixtures.provider(http), quote = try await Fixtures.quote(provider)
        let approval = try await Fixtures.approval(provider, quote: quote, root: root), job = try await provider.submit(quote, approval: approval)
        await provider.cancel(job); await provider.cancel(job)
        #expect(await provider.status(quoteID: quote.id)?.billing.mayBill == (status != 200))
        #expect(await http.requests.count == 2)
    }

    @Test func waitUsesFiveThenFifteenSecondsAndThirtyMinuteDeadline() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = LipsyncFixtureClock()
        var replies: [LipsyncFixtureHTTP.Reply] = [.json(200, Fixtures.receipt())]
        replies += Array(repeating: .json(200, #"{"status":"IN_PROGRESS"}"#), count: 135)
        replies.append(.json(200, #"{"status":"OK"}"#))
        let http = LipsyncFixtureHTTP(replies), provider = try Fixtures.provider(http, clock: clock)
        let quote = try await Fixtures.quote(provider), approval = try await Fixtures.approval(provider, quote: quote, root: root)
        let job = try await provider.submit(quote, approval: approval)
        await #expect(throws: LipsyncError.deadlineExceeded) { _ = try await provider.wait(job) }
        let sleeps = clock.state.withLock { $0.sleeps }
        #expect(Array(sleeps.prefix(24)) == Array(repeating: .seconds(5), count: 24))
        #expect(sleeps.dropFirst(24).allSatisfy { $0 == .seconds(15) })
        #expect(sleeps.count <= LipsyncLimits.maximumPolls)
        #expect(await http.requests.last?.httpMethod == "PUT")
    }

    @Test func hostileReceiptNeverReceivesTheKey() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt(host: "127.0.0.1"))]), provider = try Fixtures.provider(http)
        let quote = try await Fixtures.quote(provider), approval = try await Fixtures.approval(provider, quote: quote, root: root)
        await #expect(throws: LipsyncError.submissionUncertain) { _ = try await provider.submit(quote, approval: approval) }
        #expect(await http.requests.count == 1)
    }

    @Test func providerErrorsAreFixedCopyAndCleanupFailureIsNotHidden() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt()), .json(200, #"{"status":"COMPLETED","error":"private URL and provider detail","error_type":"bad_input"}"#),
                                      .json(200, #"{"cdn_delete_results":[{"link":"private URL","exception":"not deleted"}]}"#), .json(200, Fixtures.cleanup)])
        let provider = try Fixtures.provider(http), quote = try await Fixtures.quote(provider)
        let approval = try await Fixtures.approval(provider, quote: quote, root: root), job = try await provider.submit(quote, approval: approval)
        #expect(try await provider.poll(job) == .failed(code: "provider_error", message: "Lip sync failed. Your original media and edits are safe."))
        await provider.cleanup(job)
        #expect(await provider.status(quoteID: quote.id)?.cleanup == .failed)
        await provider.cleanup(job); await provider.cleanup(job)
        #expect(await provider.status(quoteID: quote.id)?.cleanup == .completed)
        #expect(await http.requests.filter { $0.httpMethod == "DELETE" }.count == 2)
    }

    @Test func logsRegisterCredentialsAndSignedInputsButNeverContainProviderBodies() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let log = LipsyncFixtureLog()
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt()), .json(200, #"{"error":"private-provider-body-detail"}"#),
                                      .json(403, #"{"message":"private-provider-body-detail"}"#)])
        let provider = try Fixtures.provider(http, logger: log), quote = try await Fixtures.quote(provider)
        let approval = try await Fixtures.approval(provider, quote: quote, root: root), job = try await provider.submit(quote, approval: approval)
        _ = try await provider.poll(job); await provider.cleanup(job)
        let messages = await log.messages.joined(separator: "\n")
        #expect(!messages.contains("private-provider-body-detail")); #expect(!messages.contains("X-Amz"))
        #expect(!messages.contains("synthetic-lipsync-fixture-key"))
        #expect(await log.secrets.contains(quote.video.url.absoluteString))
        #expect(await log.secrets.contains(quote.audio.url.absoluteString))
    }
}
#endif
