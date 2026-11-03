#if DEBUG
import Foundation
import AppKit
import Synchronization
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

private struct GenerationTestKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { Issue.record("State tests must not ask for credentials"); return nil }
}

@MainActor private final class GenerationQuoteTestState {
    var preparations = 0
    var executions = 0
    var suspended: TestContinuation<Void>?
    var resume: TestContinuation<Void>?
    var unknown = false
    var failing = false
    var usdPerCall = Decimal(string: "0.01")!
}

@MainActor private final class GenerationSuspension {
    private var reached = false
    private var arrival: TestContinuation<Void>?
    private var release: TestContinuation<Void>?
    func pause() async {
        await withTestDeadline { release = $0; reached = true; arrival?.resume(); arrival = nil }
    }
    func wait() async { if !reached { await withTestDeadline { arrival = $0 } } }
    func resume() { release?.resume(); release = nil }
}

private final class GenerationDispatchCount: Sendable {
    let value = Mutex(0)
    func start() { value.withLock { $0 += 1 } }
}

@Suite("Headless Rewrite generation", .serialized, .offlineFixtures)
@MainActor struct RewriteGenerationTests {
    @Test func sourceAudioRefusalsSayWhatWentWrong() {
        #expect(RewriteSession.refusal(VoiceLabSourceAudioError.unreadable) == "The audio cannot be read. Check that the file is still available. Your edits are saved.")
        #expect(RewriteSession.refusal(VoiceLabSourceAudioError.rateMismatch) == "The source audio's sample rate differs from the project. Reopen the original source. Your edits are saved.")
    }
    @Test(arguments: ["before-click", "during-confirmation", "before-launch", "transport"])
    func monthlyCapIsRecheckedAfterQuoteSheetAndTransportSuspensions(point: String) async throws {
        let (session, state) = try await replacementSession()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel()
        let ledger = VoiceLabSpendLedger(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        app.settings.values["voiceLab.monthlyCapUsd.elevenlabs"] = .string("1")
        session.readMonthlyCap = {
            let total = await ledger.total(provider: "elevenlabs", at: Date())
            let limit = try #require(Decimal(string: app.string("voiceLab.monthlyCapUsd.elevenlabs")))
            return VoiceLabMonthlyCap(limit: limit, spent: try #require(total).usd)
        }
        func addSpend(_ amount: Decimal) async {
            let estimate = CostEstimate(provider: "elevenlabs", operation: "test", units: 1, unit: "action", usd: amount, basis: "test")
            #expect(await ledger.record(estimate, at: Date()) == nil)
        }
        if point == "during-confirmation" {
            state.usdPerCall = Decimal(string: "0.10")!
            session.requestQuote(); await session.finishQuotePreparationForTests()
        }
        let previous = session.rows, selection = session.selectedID
        if point == "before-click" { await addSpend(Decimal(string: "0.97")!) }
        let suspension = GenerationSuspension(), dispatched = GenerationDispatchCount()
        var copies: [String] = []
        session.executeForTests = { _, _, started in
            if point == "before-launch" { await addSpend(Decimal(string: "0.97")!) }
            try await started()
            if point == "transport" { await addSpend(Decimal(string: "0.97")!) }
            try await session.dispatchWithCurrentCost { dispatched.start() }
            return .init(rows: [row(index: 0)], end: .completed)
        }
        session.approve(true, confirmation: { copy in
            copies.append(copy)
            #expect(dispatched.value.withLock { $0 } == 0)
            #expect(session.rows == previous && session.selectedID == selection)
            if point == "during-confirmation", copies.count == 1 { await suspension.pause() }
            return true
        })
        if point == "during-confirmation" {
            await suspension.wait()
            await addSpend(Decimal(string: "0.50")!)
            suspension.resume()
        }
        await session.finishGenerationForTests()
        #expect(copies.count == (point == "during-confirmation" ? 2 : 1))
        #expect(copies.last?.contains("past your $1 limit") == true)
        #expect(dispatched.value.withLock { $0 } == 1)
        session.invalidate()
    }
    @Test(arguments: [false, true])
    func cancellingTheActualCostConfirmationKeepsPriorTakesAndQuote(atLaunch: Bool) async throws {
        let (session, state) = try await replacementSession()
        state.unknown = !atLaunch
        var spent = Decimal.zero
        session.readMonthlyCap = { VoiceLabMonthlyCap(limit: 1, spent: spent) }
        session.requestQuote(); await session.finishQuotePreparationForTests()
        let previous = session.rows, selection = session.selectedID, quote = session.quote, price = session.buttonTitle
        let suspension = GenerationSuspension()
        session.executeForTests = { _, _, started in
            if atLaunch { spent = Decimal(string: "0.97")!; try await started() }
            Issue.record("A declined confirmation must not launch")
            return .init(rows: [], end: .completed)
        }
        session.approve(true, confirmation: { _ in await suspension.pause(); return false })
        await suspension.wait()
        #expect(session.rows == previous && session.selectedID == selection)
        suspension.resume()
        await session.finishGenerationForTests()
        #expect(session.rows == previous && session.selectedID == selection && session.readyToAccept)
        #expect(session.canExecute && state.preparations == 2)
        #expect(session.quote == quote && session.buttonTitle == price)
        var confirmations = 0
        session.approve(true, confirmation: { _ in confirmations += 1; return false })
        await session.finishGenerationForTests()
        #expect(confirmations == 1 && session.quote == quote)
        session.invalidate()
    }
    @Test(arguments: [false, true])
    func firstTransportCapDecisionKeepsRowsUntilStart(approved: Bool) async throws {
        let (session, state) = try await replacementSession()
        let previous = session.rows, selection = session.selectedID, quote = session.quote, title = session.buttonTitle
        var spent = Decimal.zero
        session.readMonthlyCap = { VoiceLabMonthlyCap(limit: 1, spent: spent) }
        let count = GenerationDispatchCount()
        let confirmation = GenerationSuspension()
        session.executeForTests = { _, _, started in
            try await started()
            spent = Decimal(string: "0.97")!
            try await session.dispatchWithCurrentCost { count.start() }
            #expect(session.rows.isEmpty && session.selectedID == nil)
            return .init(rows: [row(index: 0)], end: .completed)
        }
        var confirmations = 0
        session.approve(true, confirmation: { _ in
            confirmations += 1
            #expect(session.rows == previous && session.selectedID == selection)
            await confirmation.pause()
            return approved
        })
        await confirmation.wait()
        #expect(session.rows == previous && session.selectedID == selection)
        #expect(count.value.withLock { $0 } == 0)
        confirmation.resume()
        await session.finishGenerationForTests()
        if approved {
            #expect(count.value.withLock { $0 } == 1)
            #expect(session.rows.count == 1 && session.rows.first?.index == 0)
        } else {
            #expect(session.rows == previous && session.selectedID == selection)
            #expect(session.quote == quote && session.buttonTitle == title && session.canExecute)
            #expect(state.preparations == 1)
            session.approve(true, confirmation: { _ in confirmations += 1; return false })
            await session.finishGenerationForTests()
            #expect(confirmations == 2 && count.value.withLock { $0 } == 0)
        }
        session.invalidate()
    }
    @Test func cancellationRacingFirstTransportKeepsRowsAndSelection() async throws {
        let (session, _) = try await replacementSession()
        let previous = session.rows, selection = session.selectedID
        let suspension = GenerationSuspension(), count = GenerationDispatchCount()
        var reads = 0
        session.readMonthlyCap = {
            reads += 1
            if reads == 3 { await suspension.pause() }
            return nil
        }
        session.executeForTests = { _, _, started in
            try await started()
            try await session.dispatchWithCurrentCost { count.start() }
            return .init(rows: [], end: .completed)
        }
        session.approve(true)
        await suspension.wait()
        session.cancel()
        #expect(session.rows == previous && session.selectedID == selection)
        suspension.resume()
        await session.finishGenerationForTests()
        #expect(count.value.withLock { $0 } == 0)
        #expect(session.rows == previous && session.selectedID == selection && session.canExecute)
        session.invalidate()
    }
    private func replacementSession() async throws -> (RewriteGenerationSession, GenerationQuoteTestState) {
        let session = session(), state = GenerationQuoteTestState()
        let shared = try SharedResources.locate()
        let voice = try JSONDecoder().decode(VoiceConsentRecord.self,
            from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json")))
        session.showFixture("ready", voice: voice)
        #expect(session.chooseVideo(.source))
        let window = VoiceLabWindow(firstWordId: "word", lastWordId: "word", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: 1, end: 2, startSample: 24_000, endSample: 48_000,
            leftSeam: .init(kind: .hard, time: 1, sample: 24_000, fadeSamples: 288),
            rightSeam: .init(kind: .hard, time: 2, sample: 48_000, fadeSamples: 288))
        let input = VoiceLabTakeInput(text: "Hello", modelID: "eleven_multilingual_v2", recordID: voice.id, language: "en",
            seed: 7, contentKey: "test", source: [], sourceSampleRate: 24_000, items: [], window: window,
            incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        session.prepareForTests = { _ in
            state.preparations += 1
            let takes = (0..<3).map { index in
                let estimate = CostEstimate(provider: "elevenlabs", operation: "test", units: 1, unit: "take",
                    usd: state.unknown ? nil : state.usdPerCall, basis: "test")
                let quote = VoiceLabQuote(id: UUID(), operation: .textToSpeech, requestID: UUID(), estimate: estimate,
                    region: .default, endpoint: "test", languageMode: nil, fingerprint: "test")
                return VoiceLabTakeQuote(index: index, seed: UInt32(index), synthesis: quote, qa: quote)
            }
            return VoiceLabTakeRunQuote(id: UUID(), takes: takes, preparedAt: Date())
        }
        session.prepareQuote = { await session.prepare(input) }
        session.requestQuote()
        await session.finishQuotePreparationForTests()
        return (session, state)
    }
    @Test(arguments: ["before-approval", "confirmation", "launch"])
    func cancellingReplacementPreservesSelectionAndAutomaticallyRequotes(point: String) async throws {
        let (session, state) = try await replacementSession()
        let previous = session.rows, selected = session.selectedID, quote = session.quote
        let suspension = GenerationSuspension()
        session.executeForTests = { _, _, started in
            await suspension.pause()
            try await started()
            state.executions += 1
            return .init(rows: [], end: .completed)
        }
        if point == "confirmation" { session.approve(false) }
        if point == "launch" { session.approve(true); await suspension.wait() }
        session.cancel()
        #expect(session.rows == previous && session.selectedID == selected && session.readyToAccept)
        if point == "launch" { suspension.resume() }
        await session.finishGenerationForTests()
        #expect(state.executions == 0 && state.preparations == 2)
        #expect(session.rows == previous && session.selectedID == selected && session.readyToAccept)
        #expect(session.canExecute && session.quote?.id != quote?.id && session.buttonTitle.contains("0.06"))
        session.invalidate()
    }
    @Test func proposalErrorsNameTheConnectorAndRewrite() {
        #expect(RewriteSession.proposalError(.unauthorized, provider: "Example", model: "test").hasPrefix("Example rejected"))
        #expect(RewriteSession.proposalError(.refused(category: nil), provider: "Example", model: "test").contains("declined to rewrite"))
        #expect(RewriteSession.proposalError(.truncated, provider: "Example", model: "test").contains("rewrite was incomplete"))
    }
    /// Takes keep Voice Lab's beta gate; text Rewrite needs none (impl-plan V13): Edit › Rewrite is on in every case.
    @Test(arguments: 0..<4) func takesShareTheBetaGateAndTextRewriteDoesNot(bits: Int) throws {
        let enabled = bits & 1 != 0, accepted = bits & 2 != 0
        let app = AppModel()
        app.settings.values["voiceLab.enabled"] = .bool(enabled)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(accepted)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        app.settings.values["transcription.elevenlabs.region"] = .string("default")
        let shared = try SharedResources.locate()
        let project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        defer { editor.close() }
        let session = RewriteSession(editor: editor, scope: .selection(0...0), envelope: nil, connector: nil)
        let expected = VoiceLabGate.rewriteEnabled(enabled: enabled, noticeAccepted: accepted, internalBuild: AppModel.internalBuild)
        #expect(app.voiceLabRewriteEnabled == expected)
        #expect(editor.mutationEnabled(38) == true)
        #expect(session.generationIsCurrent(region: .default) == expected)
        #expect(!session.generationIsCurrent(region: .eu))
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(false)
        #expect(!session.generationIsCurrent(region: .default))
        let lease = try #require(editor.llmRuns.acquire())
        #expect(editor.mutationEnabled(38) == false)
        editor.llmRuns.release(lease)
        #expect(editor.mutationEnabled(38) == true)
        editor.mediaResolved = false
        #expect(editor.mutationEnabled(38) == false)
    }
    private func session(current: @escaping @MainActor () -> Bool = { true }) -> RewriteGenerationSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VoiceConsentStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let client = ElevenLabsVoiceLab(keys: GenerationTestKeys(), region: .default)
        return RewriteGenerationSession(run: VoiceLabTakeRun(client: client, store: store, speaker: .unavailable,
            storage: VoiceLabTakeStorage(projectId: UUID().uuidString.lowercased(), paidRoot: root.appendingPathComponent("VoiceLab"), scratchRoot: root.appendingPathComponent("scratch")), dispatchIfCurrent: { _, start in
            try await MainActor.run {
                guard current() else { throw VoiceLabError.consentRequired }
                try start()
            }
        }, inputsAreCurrent: { true }), inputsAreCurrent: current)
    }
    private func fixtureInput() -> VoiceLabTakeInput {
        let window = VoiceLabWindow(firstWordId: "word", lastWordId: "word", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: 1, end: 2, startSample: 24_000, endSample: 48_000,
            leftSeam: .init(kind: .hard, time: 1, sample: 24_000, fadeSamples: 288),
            rightSeam: .init(kind: .hard, time: 2, sample: 48_000, fadeSamples: 288))
        return VoiceLabTakeInput(text: "Hello", modelID: "fixture-model", recordID: "fixture-record", language: "en", seed: 7,
            contentKey: "test", source: [], sourceSampleRate: 24_000, items: [], window: window,
            incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
    }

    private func row(index: Int, residual: Double = 0, failure: Bool = false, score: Double = 1) -> VoiceLabTakeRow {
        let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
            trimStartFrame: 0, trimEndFrame: 24_000, windowStart: 1, windowEnd: 2, windowStartSample: 24_000, windowEndSample: 48_000,
            outputFrames: 24_000, words: [VoiceLabWord(text: "Hello", start: 0.1, end: 0.9, synthetic: true)])
        let fit: VoiceLabFitResult = residual == 0 ? .exact(plan) : .changedDuration(plan, naturalOut: 1 + residual, residualSeconds: residual)
        let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [0.1], mixed: [0.1], patchRange: 0..<1, seams: [], gainDb: 0, roomTone: nil, fit: fit)
        let qa = VoiceLabTakeQAResult(values: VoiceLabQA(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -20, speakerScore: failure ? 0.1 : 0.8), failures: failure ? [.speaker] : [])
        return VoiceLabTakeRow(id: UUID(), index: index, seed: UInt32(index), audio: audio, qa: qa, score: score, failure: failure ? .qa([.speaker]) : nil)
    }
    @Test func compatibilityReviewNeverAutomaticallySelectsAJoinAdvisory() async {
        let session = session()
        let clean = row(index: 0, score: 0.8)
        let qa = VoiceLabTakeQAResult(values: .init(transcriptMatch: 1, lufsJumpLu: 4, peakDbfs: -10, speakerScore: 0.9),
            failures: [.loudness], joinSeams: [.init(side: .right, excessLu: 4)])
        let advisory = VoiceLabTakeRow(id: UUID(), index: 1, seed: 1, audio: clean.audio, qa: qa, score: 1)
        session.review(.init(rows: [advisory], end: .completed), input: fixtureInput())
        #expect(session.selectedID == nil && session.bestID == nil && !session.readyToAccept)
        #expect(session.announcement == "One take has a join advisory. Listen before using.")
        let selected = session.select(advisory.id)
        #expect(!selected && session.takeToAutoplay() == nil)
        session.review(.init(rows: [advisory, clean], end: .completed), input: fixtureInput())
        #expect(session.selectedID == clean.id)
        await session.reject(clean)
        #expect(session.selectedID == nil && !session.readyToAccept)
        session.invalidate()
    }
    @Test func compatibilityProgressNeverAnnouncesAnAdvisoryAsFitting() async throws {
        let (session, _) = try await replacementSession()
        let clean = row(index: 0)
        let qa = VoiceLabTakeQAResult(values: .init(transcriptMatch: 1, lufsJumpLu: 4, peakDbfs: -10, speakerScore: 0.9),
            failures: [.loudness], joinSeams: [.init(side: .right, excessLu: 4)])
        let advisory = VoiceLabTakeRow(id: UUID(), index: 0, seed: 1, audio: clean.audio, qa: qa, score: 1)
        session.executeForTests = { _, progress, started in
            try await started()
            try await session.dispatchWithCurrentCost({})
            await progress([advisory])
            #expect(!session.announcement.contains("Take 1 fits."))
            return .init(rows: [advisory], end: .completed)
        }
        session.approve(true)
        await session.finishGenerationForTests()
        #expect(session.selectedID == nil && !session.readyToAccept)
        #expect(session.announcement.contains("join advisory"))
        session.invalidate()
    }

    @Test func exactBestIsPreselectedButRejectedRowsNeverAre() {
        let session = session()
        let rejected = row(index: 0, failure: true, score: 1)
        let best = row(index: 1, score: 0.9)
        session.review(VoiceLabTakeRunResult(rows: [rejected, best], end: .earlyStop), input: fixtureInput())
        #expect(session.chooseVideo(.source))
        #expect(session.bestID == best.id && session.selectedID == best.id && session.readyToAccept)
        #expect(!session.select(rejected.id))
        session.invalidate()
        #expect(session.rows.isEmpty && !session.readyToAccept && session.quote == nil)
    }
    @Test(arguments: [false, true]) func replacementQuoteKeepsTakesUntilApproved(unknownPrice: Bool) async throws {
        let session = session()
        let shared = try SharedResources.locate()
        let voice = try JSONDecoder().decode(VoiceConsentRecord.self,
            from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json")))
        session.showFixture("ready", voice: voice)
        #expect(session.chooseVideo(.source))
        let first = row(index: 0), chosen = row(index: 2, score: 0.9)
        let window = VoiceLabWindow(firstWordId: "word", lastWordId: "word", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: 1, end: 2, startSample: 24_000, endSample: 48_000,
            leftSeam: .init(kind: .hard, time: 1, sample: 24_000, fadeSamples: 288),
            rightSeam: .init(kind: .hard, time: 2, sample: 48_000, fadeSamples: 288))
        let input = VoiceLabTakeInput(text: "Hello", modelID: "eleven_multilingual_v2", recordID: voice.id, language: "en",
            seed: 7, contentKey: "test", source: [], sourceSampleRate: 24_000, items: [], window: window,
            incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        session.review(.init(rows: [first, chosen], end: .completed), input: input)
        #expect(session.select(chosen.id))
        #expect(session.chooseVideo(.source))
        let originalRows = session.rows
        var prepared: [UUID] = []
        session.prepareForTests = { _ in
            #expect(session.rows == originalRows && session.selectedID == chosen.id)
            #expect(session.select(first.id) && session.select(chosen.id))
            #expect(session.chooseVideo(.source))
            let takes = (0..<3).map { index in
                let estimate = CostEstimate(provider: "elevenlabs", operation: "test", units: 1, unit: "take",
                    usd: unknownPrice ? nil : Decimal(string: "0.01"), basis: "test")
                let quote = VoiceLabQuote(id: UUID(), operation: .textToSpeech, requestID: UUID(), estimate: estimate,
                    region: .default, endpoint: "test", languageMode: nil, fingerprint: "test")
                return VoiceLabTakeQuote(index: index, seed: UInt32(index), synthesis: quote, qa: quote)
            }
            let quote = VoiceLabTakeRunQuote(id: UUID(), takes: takes, preparedAt: Date())
            prepared.append(quote.id)
            return quote
        }
        await session.prepare(input)
        let quote = try #require(session.quote)
        #expect(quote.takes.map(\.index) == [0, 1, 2])
        if unknownPrice { guard case .confirm = session.cost else { Issue.record("Unknown price needs confirmation"); return } }
        else { #expect(session.buttonTitle.contains("0.06")) }
        session.approve(false)
        #expect(session.rows == originalRows && session.selectedID == chosen.id && session.readyToAccept)
        #expect(session.quote == quote)
        let replacement = row(index: 0)
        session.executeForTests = { approved, _, started in
            #expect(approved == quote && session.rows == originalRows && session.selectedID == chosen.id)
            try await started()
            try await session.dispatchWithCurrentCost({})
            #expect(session.rows.isEmpty && session.selectedID == nil)
            return .init(rows: [replacement], end: .completed)
        }
        session.approve(true)
        await session.finishGenerationForTests()
        #expect(session.rows == [replacement] && session.selectedID == replacement.id)
        #expect(session.cost == nil && session.quote == nil)
        session.prepareForTests = { _ in throw CancellationError() }
        #expect(prepared == [quote.id])
        session.invalidate()
    }
    @Test func completedRunAutomaticallyPricesTheNextSingleClickRun() async throws {
        let session = session()
        let shared = try SharedResources.locate()
        let voice = try JSONDecoder().decode(VoiceConsentRecord.self,
            from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json")))
        session.showFixture("ready", voice: voice)
        #expect(session.chooseVideo(.source))
        let window = VoiceLabWindow(firstWordId: "word", lastWordId: "word", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: 1, end: 2, startSample: 24_000, endSample: 48_000,
            leftSeam: .init(kind: .hard, time: 1, sample: 24_000, fadeSamples: 288),
            rightSeam: .init(kind: .hard, time: 2, sample: 48_000, fadeSamples: 288))
        let input = VoiceLabTakeInput(text: "Hello", modelID: "eleven_multilingual_v2", recordID: voice.id, language: "en",
            seed: 7, contentKey: "test", source: [], sourceSampleRate: 24_000, items: [], window: window,
            incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
        let state = GenerationQuoteTestState()
        session.prepareForTests = { _ in
            state.preparations += 1
            if let suspended = state.suspended {
                await withTestDeadline { state.resume = $0; suspended.resume() }
            }
            if state.failing { throw VoiceLabError.unauthorized }
            let takes = (0..<3).map { index in
                let estimate = CostEstimate(provider: "elevenlabs", operation: "test", units: 1, unit: "take",
                    usd: state.unknown ? nil : state.usdPerCall, basis: "test")
                let quote = VoiceLabQuote(id: UUID(), operation: .textToSpeech, requestID: UUID(), estimate: estimate,
                    region: .default, endpoint: "test", languageMode: nil, fingerprint: "test")
                return VoiceLabTakeQuote(index: index, seed: UInt32(index), synthesis: quote, qa: quote)
            }
            return VoiceLabTakeRunQuote(id: UUID(), takes: takes, preparedAt: Date())
        }
        session.prepareQuote = { await session.prepare(input) }
        session.executeForTests = { _, _, started in
            state.executions += 1
            try await started()
            try await session.dispatchWithCurrentCost({})
            return .init(rows: [row(index: 0), row(index: 1, failure: true)], end: .completed)
        }
        session.requestQuote()
        await session.finishQuotePreparationForTests()
        #expect(state.preparations == 1 && state.executions == 0 && session.canExecute)
        session.approve(true)
        await session.finishGenerationForTests()
        #expect(state.preparations == 2 && state.executions == 1 && session.canExecute)
        #expect(session.buttonTitle.contains("0.06") && session.generationButtonTitle("Try Another", takes: 3).contains("0.06"))
        let previous = session.rows, selected = session.selectedID, quote = session.quote
        session.approve(false)
        #expect(session.rows == previous && session.selectedID == selected && session.quote == quote)
        session.approve(true)
        await session.finishGenerationForTests()
        #expect(state.executions == 2 && state.preparations == 3 && session.rows.map(\.index) == [0, 1])
        let retained = session.rows, retainedID = session.selectedID
        await withTestDeadline { ready in
            state.suspended = ready
            session.requestQuote()
        }
        #expect(session.preparingQuote && !session.canExecute && session.buttonTitle == "Generate Again")
        #expect(session.rows == retained && session.selectedID == retainedID)
        state.suspended = nil; state.resume?.resume()
        await session.finishQuotePreparationForTests()
        state.unknown = true
        session.requestQuote()
        await session.finishQuotePreparationForTests()
        guard case .confirm = session.cost else { Issue.record("Unknown price must ask"); return }
        session.approve(false)
        #expect(session.rows == retained && session.selectedID == retainedID)
        state.unknown = false; state.usdPerCall = Decimal(string: "0.10")!; session.requestQuote()
        await session.finishQuotePreparationForTests()
        guard case .confirm = session.cost else { Issue.record("Above S14 must ask"); return }
        #expect(session.canExecute && session.buttonTitle.contains("0.60") && session.generationButtonTitle("Try Another", takes: 3).contains("0.60"))
        session.approve(false)
        #expect(session.rows == retained && session.selectedID == retainedID)
        state.failing = true; session.requestQuote()
        await session.finishQuotePreparationForTests()
        #expect(session.quotePreparationFailed && session.problem.contains("ElevenLabs") && !session.canExecute && session.canGenerate)
        state.failing = false; state.unknown = false; session.requestQuote()
        await session.finishQuotePreparationForTests()
        #expect(session.canExecute && !session.quotePreparationFailed)
        session.chooseVoice(nil); session.chooseVoice(voice.id)
        await session.finishQuotePreparationForTests()
        #expect(session.canExecute && session.rows == retained && !session.readyToAccept)
        session.chooseModel(nil); session.chooseModel(input.modelID)
        await session.finishQuotePreparationForTests()
        #expect(session.canExecute && session.rows == retained && !session.readyToAccept)
        session.executeForTests = { _, _, _ in
            await withTestDeadline { state.resume = $0; state.suspended?.resume() }
            #expect(!session.dispatchIsCurrent)
            return .init(rows: [], end: .cancelled)
        }
        await withTestDeadline { ready in
            state.suspended = ready
            session.approve(true)
        }
        session.inputsChanged()
        #expect(!session.dispatchIsCurrent && session.rows == retained && session.selectedID == retainedID)
        #expect(session.phase == .readyToAccept && !session.readyToAccept)
        state.suspended = nil; state.resume?.resume()
        await session.finishQuotePreparationForTests()
        #expect(session.canExecute && session.rows == retained && session.selectedID == retainedID)
        session.invalidate()
    }
    @Test func changedLengthRequiresExplicitTakeAndVideoChoices() {
        let session = session(); let take = row(index: 0, residual: 0.5)
        session.review(VoiceLabTakeRunResult(rows: [take], end: .completed), input: fixtureInput())
        #expect(session.phase == .lengthChanged && session.bestID == take.id && session.selectedID == take.id)
        #expect(!session.readyToAccept && session.videoChoice == nil)
        #expect(session.select(take.id) && !session.readyToAccept)
        #expect(!session.chooseVideo(.source))
        #expect(!session.chooseVideo(.retimed) && !session.readyToAccept)
        #expect(!session.chooseVideo(.lipsync) && session.videoChoice == nil)
        session.cancel()
        #expect(!session.readyToAccept && session.select(take.id) && session.videoChoice == nil)
        session.invalidate()
        #expect(!session.readyToAccept && !session.select(take.id))
    }
    @Test(arguments: [false, true]) func rejectionSelectsNextEligibleTakeByRank(changedLength: Bool) async {
        let session = session()
        let first = row(index: 0, score: 1)
        let next = row(index: 2, residual: changedLength ? 0.5 : 0, score: 0.9)
        let lower = row(index: 1, score: 0.1)
        let failed = row(index: 3, failure: true, score: 2)
        session.review(.init(rows: [first, lower, next, failed], end: .completed), input: fixtureInput())
        await session.reject(first)
        #expect(session.selectedID == next.id && session.bestID == next.id)
        #expect(session.phase == (changedLength ? .lengthChanged : .readyToAccept))
        #expect(session.announcement == "Rejected Take 1. Take 3 selected.")
        await session.reject(lower)
        #expect(session.selectedID == next.id && session.phase != .nonePassed)
        await session.reject(next)
        #expect(session.selectedID == nil && session.bestID == nil && session.phase == .nonePassed)
        #expect(session.announcement == "No usable takes. One take left out. The voice did not pass the speaker-match check.")
        session.invalidate()
    }
    @Test func nonePassedFatalAndStaleStatesCannotBeAccepted() {
        let session = session()
        session.review(VoiceLabTakeRunResult(rows: [row(index: 0, failure: true)], end: .completed), input: fixtureInput())
        #expect(session.phase == .nonePassed && session.selectedID == nil && !session.readyToAccept)
        let passing = row(index: 1)
        session.review(VoiceLabTakeRunResult(rows: [passing], end: .fatal), input: fixtureInput())
        #expect(session.phase == .failed && !session.select(passing.id) && !session.readyToAccept)
        let stale = self.session(current: { false })
        stale.review(VoiceLabTakeRunResult(rows: [passing], end: .completed))
        #expect(!stale.readyToAccept)
    }
    @Test func pauseNotesHaveStableCrossPlatformSigns() {
        #expect(RewriteGenerationSession.pauseFitNote(0.4) == "pauses +0.4 s")
        #expect(RewriteGenerationSession.pauseFitNote(-0.4) == "pauses −0.4 s")
        #expect(RewriteGenerationSession.pauseFitNote(0) == "pauses +0.0 s")
        #expect(RewriteGenerationSession.pauseFitNote(-0.0) == "pauses +0.0 s")
        #expect(RewriteGenerationSession.pauseFitNote(-0.01) == "pauses −0.0 s")
        #expect(RewriteGenerationSession.pauseFitNote(0.01) == "pauses +0.0 s")
        #expect(RewriteGenerationSession.pauseFitNote(-12.36) == "pauses −12.4 s")
        #expect(RewriteGenerationSession.pauseFitNote(12.36) == "pauses +12.4 s")
    }
    @Test func pauseFitNotesReplayEverySharedVectorByteForByte() throws {
        struct Vector: Decodable { let seconds: Double; let expected: String }
        struct Fixture: Decodable { let cases: [Vector] }
        let shared = try SharedResources.locate()
        let data = try Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/pause-fit-note-cases.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        #expect(fixture.cases.count == 18)
        for vector in fixture.cases {
            let actual = RewriteGenerationSession.pauseFitNote(vector.seconds)
            #expect(Array(actual.utf8) == Array(vector.expected.utf8), "seconds=\(vector.seconds), expected=\(vector.expected), actual=\(actual)")
        }
    }
    @Test func completionAnnouncementsCountOnlyActualTakes() {
        #expect(RewriteGenerationSession.completionAnnouncement(rows: [], fittedTake: nil) == "No usable takes.")
        #expect(RewriteGenerationSession.completionAnnouncement(rows: [row(index: 0)], fittedTake: nil) == "One take fits.")
        #expect(RewriteGenerationSession.completionAnnouncement(rows: [row(index: 0), row(index: 1)], fittedTake: nil) == "Two takes fit.")
        #expect(RewriteGenerationSession.completionAnnouncement(rows: (0..<4).map { row(index: $0) }, fittedTake: nil) == "4 takes fit.")
        #expect(RewriteGenerationSession.completionAnnouncement(rows: [row(index: 0)], fittedTake: 1) == "Take 1 fits.")
    }
    @Test func completionAnnouncementsCountEveryFailedTake() {
        for failures in [1, 2] {
            for fits in [false, true] {
                let session = session()
                session.review(VoiceLabTakeRunResult(rows: [row(index: 0, failure: true),
                    row(index: 1, residual: 0.5, failure: failures == 2, score: 0.1),
                    row(index: 2, residual: fits ? 0 : 0.5, score: 0.9)], end: .completed), input: fixtureInput())
                let count = failures == 1 ? "One take" : "Two takes"
                let checked = failures == 1 ? "Two takes passed checks but need" : "One take passed checks but needs"
                let first = fits ? "Take 3 fits." : "No take fits yet. \(checked) a timing change."
                let expected = "\(first) \(count) left out. The voice did not pass the speaker-match check."
                #expect(session.announcement == expected)
            }
        }
    }
    @Test(arguments: [VoiceLabTakeRunEnd.completed, .fatal, .invalidated])
    func unavailableChecksKeepTheirCauseAndNeverOfferAUsableTake(end: VoiceLabTakeRunEnd) async {
        let session = session()
        var preparations = 0
        session.prepareQuote = { preparations += 1 }
        let failure = VoiceLabTakeFailure.qa([.insufficientGeneratedSpeech])
        let take = VoiceLabTakeRow(id: UUID(), index: 0, seed: 1,
            qa: .init(values: .init(), failures: [.insufficientGeneratedSpeech]), failure: failure)
        session.review(.init(rows: [take], end: end, failure: failure), input: fixtureInput())
        #expect(session.runFailure == failure && session.rows == [take])
        #expect(session.problem.contains("at least 3 seconds of voiced speech"))
        #expect(session.selectedID == nil && session.bestID == nil && !session.readyToAccept)
        #expect(!session.select(take.id) && session.takeToAutoplay() == nil)
        await session.play(take)
        #expect(!session.audition.isPlaying && session.audition.takeId == nil)
        #expect(!session.announcement.contains("ready") && !session.announcement.contains("did not pass"))
        await session.finishQuotePreparationForTests()
        #expect(preparations == 0 && session.quote == nil && session.cost == nil)
        session.invalidate()
        #expect(session.runFailure == nil)
    }
    @Test(arguments: [VoiceLabTakeRunEnd.completed, .fatal])
    func failedRunsDoNotAutomaticallyRequoteOrRetry(end: VoiceLabTakeRunEnd) async throws {
        let (session, state) = try await replacementSession()
        let failure: VoiceLabTakeFailure = end == .fatal ? .provider(.network) : .qa([.insufficientGeneratedSpeech])
        let take = VoiceLabTakeRow(id: UUID(), index: 0, seed: 1, failure: failure)
        session.executeForTests = { _, progress, started in
            state.executions += 1
            try await started()
            try await session.dispatchWithCurrentCost({})
            await progress([take])
            return .init(rows: [take], end: end, failure: failure)
        }
        session.approve(true)
        await session.finishGenerationForTests()
        #expect(state.preparations == 1 && state.executions == 1)
        #expect(session.runFailure == failure && !session.problem.isEmpty)
        #expect(!session.canExecute && !session.readyToAccept && session.rows == [take])
        session.approve(true)
        await session.finishGenerationForTests()
        #expect(state.preparations == 1 && state.executions == 1)
        session.invalidate()
    }
    @Test func fatalProviderCauseIsNotReplacedByGenericOperationCopy() {
        let session = session()
        let passing = row(index: 0)
        session.review(.init(rows: [passing], end: .fatal, failure: .provider(.network)), input: fixtureInput())
        #expect(session.runFailure == .provider(.network))
        #expect(session.problem.contains("connection problem"))
        #expect(session.announcement.contains("No take can be used"))
        #expect(!session.announcement.contains("fits") && !session.announcement.contains("ready"))
        #expect(!session.readyToAccept && !session.select(passing.id))
        session.invalidate()
    }
    @Test func changedInputsAnnounceStalenessInsteadOfReadiness() {
        let session = session()
        let take = row(index: 0)
        session.review(.init(rows: [take], end: .completed), input: fixtureInput())
        #expect(session.chooseVideo(.source))
        #expect(session.readyToAccept)
        session.inputsChanged(prepareNewQuote: false)
        #expect(session.rows == [take] && !session.readyToAccept)
        #expect(session.announcement.contains("no longer match") && !session.announcement.contains("fits"))
        session.invalidate()
        #expect(session.announcement.isEmpty)
    }
    @Test func refusalBeforeLaunchRetainsPriorSelectionAndActualCauseWithoutRequoting() async throws {
        let (session, state) = try await replacementSession()
        let previous = session.rows, selection = session.selectedID
        session.executeForTests = { _, _, _ in
            state.executions += 1
            return .init(rows: [], end: .fatal, failure: .provider(.quotaExceeded))
        }
        session.approve(true)
        await session.finishGenerationForTests()
        #expect(session.rows == previous && session.selectedID == selection)
        #expect(session.runFailure == .provider(.quotaExceeded) && session.problem.contains("quota"))
        #expect(!session.problem.contains("consent") && session.announcement.contains("No new takes"))
        #expect(state.preparations == 1 && state.executions == 1 && !session.canExecute)
        session.invalidate()
    }
    @Test func thrownTransportFailureKeepsItsCauseWithoutRequoting() async throws {
        let (session, state) = try await replacementSession()
        session.executeForTests = { _, _, started in
            state.executions += 1
            try await started()
            try await session.dispatchWithCurrentCost({})
            throw VoiceLabError.network
        }
        session.approve(true)
        await session.finishGenerationForTests()
        #expect(session.phase == .failed && session.runFailure == .provider(.network))
        #expect(session.problem.contains("connection problem") && session.announcement.contains("No take can be used"))
        #expect(state.preparations == 1 && state.executions == 1 && !session.canExecute)
        #expect(session.selectedID == nil && !session.readyToAccept && session.rows.isEmpty)
        session.invalidate()
    }
    @Test func remoteLocalServerNeverClaimsNothingLeavesTheMac() {
        for url in ["http://localhost:11434", "http://127.0.0.1:8080", "http://[::1]:8080"] {
            #expect(RewriteSession.localSendLine(words: "these 12 words", baseURL: url) == "Runs on this Mac. Nothing leaves it.")
        }
        #expect(RewriteSession.localSendLine(words: "these 12 words", baseURL: "http://192.168.1.2:8080") == "Sends these 12 words to 192.168.1.2.")
        #expect(RewriteSession.localSendLine(words: "the 118 words of clip 1", baseURL: "https://inference.example.test") == "Sends the 118 words of clip 1 to inference.example.test.")
        #expect(!RewriteSession.localSendLine(words: "these 12 words", baseURL: "invalid").contains("Nothing leaves"))
    }
    @Test func unavailableCleaningHasAnExplicitReasonAndSafeAlternative() {
        let copy = RewriteSession.refusal(VoiceLabGeometryError.roomToneUnavailable)
        #expect(copy == "This take has no half-second pause to copy the room sound from. Clean audio removes background sound from the whole take, so new words can blend in. Clean audio is not available in this build. Re-record this sentence instead.")
    }
    @Test func theBestTakeAutoplaysOnlyOnceAndNeverAfterAnotherSelection() {
        let session = session(); let first = row(index: 0); let second = row(index: 1, score: 0.9)
        session.review(.init(rows: [first, second], end: .completed), input: fixtureInput())
        #expect(session.takeToAutoplay()?.id == first.id)
        #expect(session.takeToAutoplay() == nil)
        #expect(session.select(second.id))
        #expect(session.takeToAutoplay() == nil)
    }
    @Test func layoutAuditIgnoresEmptyScrollerFramesButNotVisibleOverflow() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let element = NSView(frame: NSRect(x: -1, y: 10, width: 17, height: 0))
        element.setAccessibilityElement(true)
        host.addSubview(element)
        #expect(DebugRightColumn.accessibilityOverflow(host).isEmpty)
        element.frame.size.height = 17
        #expect(!DebugRightColumn.accessibilityOverflow(host).isEmpty)
    }
    @Test func layoutAuditIntersectsEveryNestedScrollViewport() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let outer = NSScrollView(frame: host.bounds)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 900))
        outer.clipsToBounds = true; outer.contentView.clipsToBounds = true
        outer.documentView = content; host.addSubview(outer)
        let inner = NSScrollView(frame: NSRect(x: 0, y: 600, width: 300, height: 100))
        inner.clipsToBounds = true; inner.contentView.clipsToBounds = true
        inner.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        content.addSubview(inner)
        #expect(DebugRightColumn.viewOverflow(host).isEmpty)
        outer.clipsToBounds = false; outer.contentView.clipsToBounds = false
        #expect(!DebugRightColumn.viewOverflow(host).isEmpty)
    }
}
#endif
