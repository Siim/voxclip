#if DEBUG
import Foundation
import Synchronization
import Testing
@_spi(Testing) @testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia

@Suite("Voice changer transport bridge", .timeLimit(.minutes(1)))
struct VoiceChangeTransportTests {
    @Test(arguments: [VoiceChangeTestHTTP.Mode.valid, .malformed, .failedBody, .lostBody, .oversized, .denied])
    func acceptanceSurvivesBodyErrors(mode: VoiceChangeTestHTTP.Mode) async throws {
        let fixture = try await VoiceChangeTransportFixture.make(mode: mode)
        defer { fixture.clean() }
        let quote = try await fixture.quote()
        let choice = try await fixture.choice(quote)
        var succeeded = false
        do {
            let result = try await fixture.convert(quote, choice: choice, boundary: { requestID, start in
                #expect(fixture.log.requests.withLock { !$0.contains("/" + quote.endpoint) })
                #expect(requestID == quote.requestID)
                try start()
                fixture.log.dispatched.withLock { $0.append(requestID) }
            }, accepted: { requestID in fixture.log.accepted.withLock { $0.append(requestID) } })
            succeeded = true
            #expect(result.receipt.requestID == quote.requestID && result.pcm.count == 4_800)
        } catch {
            #expect(mode != .valid)
        }
        #expect(succeeded == (mode == .valid))
        #expect(fixture.log.dispatched.withLock { $0 } == [quote.requestID])
        #expect(fixture.log.accepted.withLock { $0 } == (mode == .denied ? [] : [quote.requestID]))
        #expect(fixture.log.requests.withLock { $0.filter { $0.hasPrefix("/v1/voice-changer/") }.count } == 1)
        let total = await fixture.ledger.total(provider: "elevenlabs", at: Date())
        #expect(total?.usd == (mode == .denied ? 0 : quote.estimate.usd))
        await #expect(throws: (any Error).self) {
            _ = try await fixture.convert(quote, choice: choice, boundary: { _, start in try start() }, accepted: { _ in })
        }
        #expect(fixture.log.requests.withLock { $0.filter { $0.hasPrefix("/v1/voice-changer/") }.count } == 1)
    }

    @Test func cancellationAfterHeadersStillNotifiesAndBillsOnce() async throws {
        let fixture = try await VoiceChangeTransportFixture.make(mode: .hold)
        defer { fixture.clean() }
        let quote = try await fixture.quote(), choice = try await fixture.choice(quote)
        let accepted = VoiceChangeTestSignal()
        let task = Task {
            try await fixture.convert(quote, choice: choice, boundary: { requestID, start in
                try start(); fixture.log.dispatched.withLock { $0.append(requestID) }
            }, accepted: { requestID in
                fixture.log.accepted.withLock { $0.append(requestID) }
                await accepted.signal()
            })
        }
        await accepted.wait()
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled incomplete conversion returned audio") }
        catch { #expect(error as? VoiceLabError == .cancelled) }
        #expect(fixture.log.accepted.withLock { $0 } == [quote.requestID])
        #expect(await fixture.ledger.total(provider: "elevenlabs", at: Date())?.usd == quote.estimate.usd)
    }

    @Test(arguments: ["refused", "no-start", "revoked", "unbound", "duplicate"])
    func currentnessAndCapabilityAreCheckedAtResume(mode: String) async throws {
        let fixture = try await VoiceChangeTransportFixture.make()
        defer { fixture.clean() }
        let quote = try await fixture.quote()
        let choice: VoiceLabVoiceChoice
        if mode == "unbound" { choice = fixture.initial } else { choice = try await fixture.choice(quote) }
        let startCount = Mutex(0)
        let boundary: VoiceLabTakeDispatchBoundary = { _, start in
            if mode == "refused" { throw VoiceChangeFinisher.Failure.stale }
            if mode == "no-start" { return }
            if mode == "revoked" { try await fixture.store.markDeleted(fixture.record.id, at: Date()) }
            try start()
            startCount.withLock { $0 += 1 }
            if mode == "duplicate" {
                #expect(throws: VoiceLabError.consentRequired) { try start() }
            }
        }
        if mode == "duplicate" {
            _ = try await fixture.convert(quote, choice: choice, boundary: boundary, accepted: { _ in })
        } else {
            await #expect(throws: (any Error).self) {
                _ = try await fixture.convert(quote, choice: choice, boundary: boundary, accepted: { _ in })
            }
        }
        #expect(startCount.withLock { $0 } == (mode == "duplicate" ? 1 : 0))
        #expect(fixture.log.requests.withLock { $0.filter { $0.hasPrefix("/v1/voice-changer/") }.count } == (mode == "duplicate" ? 1 : 0))
    }

    @Test func approvedBatchPinsContinuationWithoutRequoting() async throws {
        let fixture = try await VoiceChangeTransportFixture.make()
        defer { fixture.clean() }
        let elapsed = Mutex<Duration>(.zero)
        await fixture.client.useClock({ Date(timeIntervalSince1970: 1_793_577_600) }, monotonic: { elapsed.withLock { $0 } })
        let first = try await fixture.quote(), second = try await fixture.quote()
        let batch = UUID()
        try await fixture.client.approveConversionBatch(id: batch, quotes: [first, second])
        let firstChoice = try await fixture.choice(first)
        _ = try await fixture.convert(first, choice: firstChoice, boundary: { _, start in try start() }, accepted: { _ in })
        elapsed.withLock { $0 = .seconds(301) }
        let secondChoice = try await fixture.choice(second)
        _ = try await fixture.convert(second, choice: secondChoice, boundary: { _, start in try start() }, accepted: { _ in })
        await fixture.client.discardConversionBatch(id: batch, quotes: [first, second])
        #expect(fixture.log.requests.withLock { $0.filter { $0.hasPrefix("/v1/voice-changer/") }.count } == 2)
        let expired = try await fixture.quote()
        elapsed.withLock { $0 = .seconds(602) }
        await #expect(throws: VoiceLabError.consentRequired) {
            try await fixture.client.approveConversionBatch(id: UUID(), quotes: [expired])
        }
        await #expect(throws: VoiceLabError.consentRequired) {
            try await fixture.client.approveConversionBatch(id: UUID(), quotes: [expired, expired])
        }
    }

    @Test func dispatchClosureCannotBeUsedAfterBoundaryReturns() throws {
        let dispatch = VoiceChangeDispatch()
        dispatch.close()
        #expect(throws: VoiceLabError.consentRequired) { try dispatch.start { Issue.record("Late resume") } }
    }

    @Test func conversionQuoteUsesExclusive50MBCapRatherThanClone16MiBCap() async throws {
        let fixture = try await VoiceChangeTransportFixture.make()
        defer { fixture.clean() }
        let frames = 48_000 * 180
        let bytes = VoiceLabAssetStore.wavHeader(frames: frames, sampleRate: 48_000) + Data(repeating: 1, count: frames * 2)
        #expect(bytes.count > 16 * 1_024 * 1_024 && bytes.count <= VoiceChangeFinisher.maximumUploadBytes)
        let quote = try await fixture.client.prepareConversion(audio: bytes, modelID: "eleven_multilingual_sts_v2", voice: fixture.initial,
            language: "en", seed: 7, cleanAudioOn: false, requestID: UUID())
        #expect(quote.estimate.units == 180 && quote.guardAudioHash == VoiceLabFingerprint.bytes(bytes))
        #expect(fixture.log.requests.withLock { !$0.contains(where: { $0.hasPrefix("/v1/voice-changer/") }) })
    }
}
#endif
