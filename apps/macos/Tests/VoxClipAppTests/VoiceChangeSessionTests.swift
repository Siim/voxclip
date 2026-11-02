#if DEBUG
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

private final class VoiceChangeClock: Sendable {
    private let value = Mutex(Duration.zero)
    func now() -> Duration { value.withLock { $0 } }
    func advance(_ duration: Duration) { value.withLock { $0 += duration } }
}

private final class VoiceChangeDispatches: Sendable {
    private let value = Mutex<[UUID]>([])
    var ids: [UUID] { value.withLock { $0 } }
    func append(_ id: UUID) { value.withLock { $0.append(id) } }
}

private actor VoiceChangeFixtureKeys: KeyProvider {
    var value: String? = "inert-voice-fixture-key"
    func key(for provider: String) async throws -> String? { value }
    func rotate() { value = "inert-rotated-voice-fixture-key" }
}

@MainActor private final class VoiceChangeBarrier {
    private var arrived = false
    private var arrival: TestContinuation<Void>?
    private var release: TestContinuation<Void>?
    func pause() async {
        await withTestDeadline { continuation in
            release = continuation; arrived = true; arrival?.resume(); arrival = nil
        }
    }
    func wait() async {
        if arrived { return }
        await withTestDeadline { arrival = $0 }
    }
    func resume() { release?.resume(); release = nil }
}

@MainActor private final class VoiceChangeHarness {
    let snapshot: VoiceChangeSession.Snapshot
    let template: Project
    let record: VoiceConsentRecord
    let model = VoiceLabModel(id: "fixture-conversion", name: "Conversion fixture", languages: ["en"],
        canSpeak: false, canConvert: true, maximumTextLength: nil, characterCostMultiplier: nil)
    let clock = VoiceChangeClock()
    let dispatches = VoiceChangeDispatches()
    var current = true
    var revoked = false
    var unknownPrice = false
    var malformedQuote = false
    var invalidCoverage = false
    var failBeforeStart = false
    var failAfterAcceptance = false
    var failReview = false
    var failPreservation = false
    var denySpendAtDispatch = false
    var denySpend = false
    var duplicateDispatch = false
    var duplicateAcceptance = false
    var staleAtDispatch = false
    var revokeAtDispatch = false
    var tamperedReview = false
    var chunkCount = 1
    var validationBarrier: VoiceChangeBarrier?
    var conversionBarrier: VoiceChangeBarrier?
    var approvalBarrier: VoiceChangeBarrier?
    var approvals: [UUID] = []
    var discarded: [UUID] = []
    var approvedQuotes: [VoiceLabQuote] = []
    var discoveries = 0
    var preparations = 0
    var reviews = 0
    var ledgerRefreshes = 0
    var commits = 0
    var plays = 0
    var stops = 0
    var committed: Project?

    init() throws {
        let shared = try SharedResources.locate()
        template = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        record = try JSONDecoder().decode(VoiceConsentRecord.self,
            from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json")))
        var original = template
        original.voiceLab.segments = []
        let segment = try #require(template.voiceLab.segments.first)
        let rate = original.media.source.audio?.sampleRate ?? 1_000
        let start = Int64(EditingPrimitives.jsRound(segment.replace.start * Double(rate)))
        let end = Int64(EditingPrimitives.jsRound(segment.replace.end * Double(rate)))
        let window = VoiceLabWindow(firstWordId: segment.replace.firstWordId, lastWordId: segment.replace.lastWordId,
            leftBridgeWordIds: [], rightBridgeWordIds: [], start: segment.replace.start, end: segment.replace.end,
            startSample: start, endSample: end,
            leftSeam: VoiceLabSeamPlacement(kind: .gap, time: segment.replace.start, sample: start, fadeSamples: 20),
            rightSeam: VoiceLabSeamPlacement(kind: .gap, time: segment.replace.end, sample: end, fadeSamples: 20))
        let words = try #require(original.transcript?.words)
        let first = try #require(words.firstIndex { $0.id == segment.replace.firstWordId })
        let last = try #require(words.firstIndex { $0.id == segment.replace.lastWordId })
        snapshot = VoiceChangeSession.Snapshot(project: original, scope: .selection(first...last),
            outputScope: original.edits.activeClipId.map(VoiceLabOutputScope.clip) ?? .full,
            source: URL(fileURLWithPath: original.media.source.absolutePath), window: window,
            envelope: AudioEnvelope(sampleRate: Double(rate), levels: Array(repeating: 0.1, count: 700)))
    }
    func makeSession() -> VoiceChangeSession {
        let backend = VoiceChangeSession.Backend(discover: { [self] _ in
            discoveries += 1
            return VoiceChangeSession.Choices(voices: [record], models: [model])
        }, prepare: { [self] snapshot, _, _, seed in
            preparations += 1
            let length = snapshot.window.endSample - snapshot.window.startSample
            let requests = (0..<chunkCount).map { index in
                let start = snapshot.window.startSample + length * Int64(index) / Int64(chunkCount)
                let end = snapshot.window.startSample + length * Int64(index + 1) / Int64(chunkCount)
                let data = Data([UInt8(index), 1, 2, 3])
                let estimate = CostEstimate(provider: "elevenlabs", operation: "voiceChange", units: 1, unit: "second",
                    usd: unknownPrice ? nil : Decimal(string: "0.01"), basis: "inert-fixture")
                let quote = VoiceLabQuote(id: UUID(), operation: malformedQuote ? .textToSpeech : .voiceChange,
                    requestID: UUID(), estimate: estimate, region: .us, endpoint: "v1/voice-changer/\(record.voiceId)",
                    languageMode: .autoDetected(expected: "en"), fingerprint: "inert-fixture",
                    guardAudioHash: VoiceLabFingerprint.bytes(data), modelID: model.id)
                return VoiceChangeSession.Request(sourceRange: (invalidCoverage ? start + 1 : start)..<end, audio: data, quote: quote)
            }
            return VoiceChangeSession.Prepared(id: UUID(), record: record, modelID: model.id, seed: seed,
                requests: requests, preparedAt: clock.now())
        }, validate: { [self] _ in
            if let barrier = validationBarrier { validationBarrier = nil; await barrier.pause() }
            if revoked { throw VoiceConsentError.inactive }
        }, checkSpend: { [self] _ in
            if denySpend { throw ClipTakePlan.Failure.spendingCap }
        }, approve: { [self] prepared in
            approvals.append(prepared.id); approvedQuotes = prepared.requests.map(\.quote)
            if let barrier = approvalBarrier { approvalBarrier = nil; await barrier.pause() }
        }, discard: { [self] prepared in
            discarded.append(prepared.id)
        }, convert: { [self] prepared, request, boundary, accepted in
            if failBeforeStart { throw VoiceLabError.voiceAccessDenied }
            if denySpendAtDispatch { denySpend = true }
            if staleAtDispatch { current = false }
            if revokeAtDispatch { revoked = true }
            let dispatches = dispatches
            let requestID = request.quote.requestID
            try await boundary(requestID) { dispatches.append(requestID) }
            await accepted(requestID)
            if duplicateAcceptance { await accepted(requestID) }
            if duplicateDispatch { try await boundary(requestID) { dispatches.append(requestID) } }
            if let barrier = conversionBarrier { conversionBarrier = nil; await barrier.pause() }
            if failAfterAcceptance { throw VoiceLabError.invalidAudio }
            let receipt = VoiceLabReceipt(provider: "elevenlabs", region: request.quote.region, endpoint: request.quote.endpoint,
                modelID: prepared.modelID, voiceID: prepared.record.voiceId, requestID: requestID,
                providerRequestID: nil, spendWarning: nil)
            return VoiceLabAudioResult(pcm: Data(repeating: 0, count: 100), sampleRate: 24_000, alignment: nil, receipt: receipt)
        }, preserve: { [self] result, request in
            if failPreservation { throw VoiceLabError.invalidAudio }
            return VoiceChangeSession.Output(requestID: request.quote.requestID,
                asset: template.voiceLab.assets![0], receipt: result.receipt)
        }, review: { [self] _, prepared, _ in
            reviews += 1
            if failReview { throw VoiceChangeSession.Failure.invalidReview }
            return try makeReview(prepared)
        }, chargesChanged: { [self] in ledgerRefreshes += 1 })
        return VoiceChangeSession(snapshot: snapshot, backend: backend, isCurrent: { [self] in current },
            commit: { [self] review in commits += 1; committed = review.project }, now: { [clock] in clock.now() })
    }
    func quote(_ session: VoiceChangeSession) async throws -> UUID {
        await session.discover()
        session.chooseVoice(record.id); session.chooseModel(model.id)
        await session.prepare()
        return try #require(session.prepared?.id)
    }
    func makeReview(_ prepared: VoiceChangeSession.Prepared) throws -> VoiceChangeSession.Review {
        var project = template
        var segment = project.voiceLab.segments[0]
        var candidate = segment.candidates[0]
        var recipe = try #require(candidate.recipe)
        let voice = VoiceLabVoiceReference(id: record.id, provider: "elevenlabs", voiceId: record.voiceId,
            consentRecordId: record.id, displayName: record.voiceName, status: .active)
        project.voiceLab.voices = [voice]
        recipe.words = nil; recipe.roomTone = nil; recipe.voiceRefId = record.id; recipe.seed = prepared.seed
        recipe.audio.stretch = 1
        recipe.provenance.voiceId = record.voiceId; recipe.provenance.consentRecordId = record.id
        recipe.provenance.endpoint = "v1/voice-changer/\(record.voiceId)"; recipe.provenance.model = model.id
        recipe.provenance.requestId = prepared.requests[0].quote.requestID.uuidString
        recipe.provenance.seed = prepared.seed
        recipe.cost = VoiceLabCost(quoteId: prepared.requests[0].quote.id.uuidString, usd: unknownPrice ? nil : 0.01)
        let asset = try #require(project.voiceLab.assets?.first)
        let firstFrame = Int64(EditingPrimitives.jsRound(recipe.audio.trimStart * Double(asset.sampleRate)))
        let count = Int64(EditingPrimitives.jsRound(recipe.outDuration * Double(asset.sampleRate)))
        recipe.chunks = prepared.requests.enumerated().map { index, request in
            VoiceLabChunk(sourceStartSample: request.sourceRange.lowerBound, sourceEndSample: request.sourceRange.upperBound,
                requestId: request.quote.requestID.uuidString, seed: prepared.seed, assetId: asset.id, assetSha256: asset.sha256,
                assembledStartFrame: firstFrame + count * Int64(index) / Int64(prepared.requests.count),
                assembledEndFrame: firstFrame + count * Int64(index + 1) / Int64(prepared.requests.count))
        }
        candidate.recipe = recipe
        segment.kind = .voiceChanger; segment.text = nil; segment.words = nil
        segment.audio = recipe.audio; segment.provenance = recipe.provenance; segment.candidates = [candidate]
        project.voiceLab.segments = [segment]
        let contract = try VoiceLabRenderContract.prepare(project, scope: snapshot.outputScope, labelPosition: .topRight)
        return VoiceChangeSession.Review(project: project, contract: contract, media: nil,
            play: { [self] in plays += 1 }, stop: { [self] in stops += 1 }, verify: { [self] in
                if tamperedReview { throw VoiceChangeSession.Failure.invalidReview }
            })
    }
}

@Suite("Voice change session safety", .serialized, .offlineFixtures)
@MainActor struct VoiceChangeSessionTests {
    @Test func openingAndChoosingNeverDiscoversQuotesUploadsOrPlays() throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        #expect(fake.discoveries == 0 && fake.preparations == 0 && fake.dispatches.ids.isEmpty && fake.plays == 0)
        #expect(session.phase == .idle && !session.canGenerate && !session.canAccept)
    }
    @Test func exactApprovalRunsOnceReviewsWithoutAutoplayAndCommitsOnce() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session)
        await session.generate(approvedQuoteID: UUID())
        #expect(fake.dispatches.ids.isEmpty && session.phase == .quoted && fake.approvals.isEmpty)
        await session.generate(approvedQuoteID: quote)
        #expect(fake.dispatches.ids.count == 1 && fake.reviews == 1 && fake.plays == 0 && fake.commits == 0)
        #expect(session.canAccept && session.outputs.count == 1 && session.acceptedRequestIDs.count == 1)
        #expect(fake.approvals == [quote] && fake.discarded == [quote])
        #expect(fake.approvedQuotes == session.prepared?.requests.map(\.quote))
        session.playReview(); #expect(fake.plays == 1)
        await session.accept(); await session.accept(); await session.generate(approvedQuoteID: quote)
        #expect(fake.commits == 1 && fake.dispatches.ids.count == 1 && session.phase == .accepted)
        #expect(fake.committed?.transcript == fake.snapshot.project.transcript)
    }
    @Test func unknownCostRequiresTheSameExplicitQuoteApproval() async throws {
        let fake = try VoiceChangeHarness(); fake.unknownPrice = true
        let session = fake.makeSession(), quote = try await fake.quote(session)
        #expect(session.prepared?.estimate.usd == nil && session.costCopy.contains("Price unavailable"))
        #expect(fake.dispatches.ids.isEmpty)
        await session.generate(approvedQuoteID: quote)
        #expect(session.acceptedEstimate.usd == nil && session.chargeCopy.contains("unknown"))
    }
    @Test(arguments: [true, false])
    func malformedQuoteOrCoverageNeverBecomesApprovable(malformedQuote: Bool) async throws {
        let fake = try VoiceChangeHarness(); fake.malformedQuote = malformedQuote; fake.invalidCoverage = !malformedQuote
        let session = fake.makeSession()
        await session.discover(); session.chooseVoice(fake.record.id); session.chooseModel(fake.model.id); await session.prepare()
        #expect(session.prepared == nil && !session.canGenerate && fake.dispatches.ids.isEmpty && session.phase == .failed)
    }
    @Test func selectionChangeInvalidatesQuoteWithoutAutomaticRequote() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let old = try await fake.quote(session)
        session.chooseModel(nil)
        await session.generate(approvedQuoteID: old)
        #expect(session.prepared == nil && fake.preparations == 1 && fake.dispatches.ids.isEmpty)
    }
    @Test func expiredQuoteNeverUploadsAndNeverRequotes() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session)
        fake.clock.advance(.seconds(300))
        await session.generate(approvedQuoteID: quote)
        #expect(session.phase == .failed && session.problem.contains("expired"))
        #expect(fake.dispatches.ids.isEmpty && fake.preparations == 1)
    }
    @Test func staleInputsWhileOwnerValidationIsSuspendedNeverDispatch() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session), barrier = VoiceChangeBarrier()
        fake.validationBarrier = barrier
        let running = Task { await session.generate(approvedQuoteID: quote) }
        await barrier.wait(); fake.current = false; barrier.resume(); await running.value
        #expect(fake.dispatches.ids.isEmpty && fake.commits == 0 && session.phase == .failed)
    }
    @Test func capIsRecheckedAtActualDispatchNotJustAtQuote() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session); fake.denySpendAtDispatch = true
        await session.generate(approvedQuoteID: quote)
        #expect(fake.dispatches.ids.isEmpty && session.acceptedRequestIDs.isEmpty && session.outputs.isEmpty)
    }
    @Test(arguments: [true, false])
    func staleSourceOrWithdrawnVoiceAtTheTransportBoundaryNeverSends(staleSource: Bool) async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session)
        fake.staleAtDispatch = staleSource; fake.revokeAtDispatch = !staleSource
        await session.generate(approvedQuoteID: quote)
        #expect(fake.dispatches.ids.isEmpty && session.acceptedRequestIDs.isEmpty && fake.commits == 0)
    }
    @Test func providerRefusalBeforeDispatchDoesNotClaimACharge() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session); fake.failBeforeStart = true
        await session.generate(approvedQuoteID: quote)
        #expect(fake.dispatches.ids.isEmpty && session.acceptedRequestIDs.isEmpty && fake.ledgerRefreshes == 0)
        #expect(session.phase == .failed && fake.commits == 0)
    }
    @Test func acceptedHeadersCountEvenWhenBodyIsInvalidAndCallbacksRepeat() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session); fake.failAfterAcceptance = true; fake.duplicateAcceptance = true
        await session.generate(approvedQuoteID: quote)
        #expect(session.acceptedRequestIDs.count == 1 && fake.ledgerRefreshes == 1 && session.outputs.isEmpty)
        #expect(session.acceptedEstimate.usd == Decimal(string: "0.01") && fake.commits == 0)
        await session.generate(approvedQuoteID: quote)
        #expect(fake.dispatches.ids.count == 1 && fake.preparations == 1)
    }
    @Test func aRepeatedTransportBoundaryCannotSendTwice() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session); fake.duplicateDispatch = true
        await session.generate(approvedQuoteID: quote)
        #expect(fake.dispatches.ids.count == 1 && session.phase == .failed && fake.commits == 0)
    }
    @Test func stopKeepsLatePaidOutputAndAcceptedChargeButNeverAppliesIt() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session), barrier = VoiceChangeBarrier()
        fake.conversionBarrier = barrier
        let running = Task { await session.generate(approvedQuoteID: quote) }
        await barrier.wait(); session.cancel(); barrier.resume(); await running.value
        #expect(session.phase == .stopped && session.problem.isEmpty && session.outputs.count == 1)
        #expect(session.acceptedRequestIDs.count == 1 && fake.ledgerRefreshes == 1 && fake.commits == 0 && fake.reviews == 0)
    }
    @Test func stoppedInFlightSessionRefusesCloseUntilLateOutputIsSaved() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session), barrier = VoiceChangeBarrier()
        fake.conversionBarrier = barrier
        let running = Task { await session.generate(approvedQuoteID: quote) }
        await barrier.wait()
        #expect(!session.close() && !session.canClose && session.busy)
        barrier.resume(); await running.value
        #expect(session.outputs.count == 1 && session.acceptedRequestIDs.count == 1 && fake.commits == 0)
        #expect(session.canClose && session.close() && fake.discarded == [quote])
    }
    @Test func staleWhileBatchApprovalWaitsDiscardsExactBatchWithoutDispatch() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session), barrier = VoiceChangeBarrier()
        fake.approvalBarrier = barrier
        let running = Task { await session.generate(approvedQuoteID: quote) }
        await barrier.wait(); fake.current = false; barrier.resume(); await running.value
        #expect(fake.approvals == [quote] && fake.discarded == [quote])
        #expect(fake.dispatches.ids.isEmpty && session.outputs.isEmpty && fake.commits == 0)
    }
    @Test func sessionOwnsSettlementAndFailedSaveAfterItsEditorOwnerDropsIt() async throws {
        let fake = try VoiceChangeHarness()
        var owner: VoiceChangeSession? = fake.makeSession()
        let quote = try await fake.quote(try #require(owner)), barrier = VoiceChangeBarrier()
        fake.conversionBarrier = barrier; fake.failPreservation = true
        weak var observed = owner
        owner?.startGeneration(approvedQuoteID: quote)
        await barrier.wait(); owner = nil
        #expect(observed != nil)
        let held = try #require(observed)
        held.cancel(); barrier.resume()
        await TestDeadline.until { !held.busy }
        #expect(held.unpublished.count == 1 && held.acceptedRequestIDs.count == 1)
        #expect(VoiceChangeSession.recoverable(for: fake.snapshot.project).contains { $0 === held })
        fake.failPreservation = false; held.retrySaving()
        #expect(held.unpublished.isEmpty && held.outputs.count == 1)
        #expect(!VoiceChangeSession.recoverable(for: fake.snapshot.project).contains { $0 === held })
    }
    @Test func accountKeyPinRefusesRotationBeforeAnyTransport() async throws {
        let source = VoiceChangeFixtureKeys(), pinned = VoiceChangePinnedKeys(source: source)
        let first = try await pinned.key(for: "elevenlabs")
        let again = try await pinned.key(for: "elevenlabs")
        #expect(first != nil && again == first)
        await source.rotate()
        do {
            _ = try await pinned.key(for: "elevenlabs")
            Issue.record("A changed account key must not be accepted by an existing voice session")
        } catch {
            #expect((error as? VoiceConsentError) == .creatorMismatch)
        }
    }
    @Test func eachChunkHasItsOwnBillingAndASecondFailureKeepsTheFirst() async throws {
        let fake = try VoiceChangeHarness(); fake.chunkCount = 2
        let session = fake.makeSession(), quote = try await fake.quote(session)
        let barrier = VoiceChangeBarrier(); fake.conversionBarrier = barrier
        let running = Task { await session.generate(approvedQuoteID: quote) }
        await barrier.wait(); fake.failBeforeStart = true; barrier.resume(); await running.value
        #expect(fake.dispatches.ids.count == 1 && session.outputs.count == 1 && session.acceptedRequestIDs.count == 1)
        #expect(fake.reviews == 0 && fake.commits == 0)
    }
    @Test func failedLocalReviewPreservesOutputsAndCanRetryWithoutBuyingAgain() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session); fake.failReview = true
        await session.generate(approvedQuoteID: quote)
        #expect(session.outputs.count == 1 && !session.canAccept && fake.commits == 0)
        fake.failReview = false; await session.retryLocalReview()
        #expect(session.canAccept && fake.reviews == 2 && fake.dispatches.ids.count == 1 && fake.preparations == 1)
    }
    @Test func failedSaveKeepsPaidBytesForExplicitLocalSaveAndReview() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session); fake.failPreservation = true
        await session.generate(approvedQuoteID: quote)
        #expect(session.unpublished.count == 1 && session.outputs.isEmpty && !session.canAccept)
        #expect(!session.close() && !session.canClose && session.unpublished.count == 1)
        fake.failPreservation = false; session.retrySaving(); await session.retryLocalReview()
        #expect(session.unpublished.isEmpty && session.outputs.count == 1 && session.canAccept)
        #expect(fake.dispatches.ids.count == 1 && session.acceptedRequestIDs.count == 1)
    }
    @Test func anApprovedBatchCanFinishAfterItsOriginalQuoteClockExpires() async throws {
        let fake = try VoiceChangeHarness(); fake.chunkCount = 2
        let session = fake.makeSession(), quote = try await fake.quote(session)
        let barrier = VoiceChangeBarrier(); fake.conversionBarrier = barrier
        let running = Task { await session.generate(approvedQuoteID: quote) }
        await barrier.wait(); fake.clock.advance(.seconds(301)); barrier.resume(); await running.value
        #expect(fake.dispatches.ids.count == 2 && session.outputs.count == 2 && session.canAccept)
    }
    @Test func aChangedPaidSnapshotCannotBeAcceptedOrPlayed() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session); await session.generate(approvedQuoteID: quote)
        fake.tamperedReview = true
        session.playReview(); await session.accept()
        #expect(fake.plays == 0 && fake.commits == 0 && session.outputs.count == 1 && session.phase == .failed)
    }
    @Test func revokedVoiceAtAcceptanceCannotCommitAReviewedOutput() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session); await session.generate(approvedQuoteID: quote)
        fake.revoked = true; await session.accept()
        #expect(fake.commits == 0 && session.outputs.count == 1 && session.phase == .failed)
    }
    @Test func staleInputsDuringAcceptanceNeverCommit() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session); await session.generate(approvedQuoteID: quote)
        let barrier = VoiceChangeBarrier(); fake.validationBarrier = barrier
        let accepting = Task { await session.accept() }
        await barrier.wait(); fake.current = false; barrier.resume(); await accepting.value
        #expect(fake.commits == 0 && session.outputs.count == 1 && !session.canAccept)
    }
    @Test func savedRecipeRoundTripsSourceWordsAndConversionProvenance() async throws {
        let fake = try VoiceChangeHarness(), session = fake.makeSession()
        let quote = try await fake.quote(session); await session.generate(approvedQuoteID: quote); await session.accept()
        let saved = try #require(fake.committed)
        let reopened = try JSONProjectStore.decode(ProjectJSON.encode(saved))
        #expect(reopened == saved && reopened.transcript == fake.snapshot.project.transcript)
        #expect(reopened.voiceLab.segments[0].kind == .voiceChanger && reopened.voiceLab.segments[0].words == nil)
        #expect(reopened.voiceLab.segments[0].provenance.voiceId == fake.record.voiceId)
        _ = try VoiceLabRenderContract.prepare(reopened, scope: fake.snapshot.outputScope, labelPosition: .topRight)
    }
}
#endif
