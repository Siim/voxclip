#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClip
@testable import VoxClipCore
@testable import VoxClipMedia

private actor InlineTranscriptionKeys: ProviderKeyStore {
    var keyed = false
    var saves = 0
    private var pauseRead = false
    var readIsWaiting = false
    private var continuation: TestContinuation<Void>?
    func pauseNextRead() { pauseRead = true }
    func resumeRead() { continuation?.resume(); continuation = nil }
    func hasKey(for provider: String) async -> Bool {
        if pauseRead {
            pauseRead = false; readIsWaiting = true
            await withTestDeadline { continuation = $0 }
        }
        return keyed
    }
    func save(_ value: String, for provider: String) { keyed = true; saves += 1 }
}

@MainActor private final class InlineRunBarrier {
    private var entered = false
    private var released = false
    private var continuation: TestContinuation<Void>?
    private var observer: TestContinuation<Void>?
    func suspend() async {
        guard !released else { return }
        await withTestDeadline { continuation in
            self.continuation = continuation; entered = true
            observer?.resume(); observer = nil
        }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withTestDeadline { observer = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@Suite("Inline Transcribe", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil), .offlineFixtures)
@MainActor struct InlineTranscriptionTests {
    @Test(arguments: ["missing", "unreadable", "relink", "version", "duration"])
    func integratedMediaGuardsRefuseTranscriptionAndKeepCurrentProject(reason: String) async throws {
        let model = try editor(); defer { model.close() }
        let flow = model.transcription
        await flow.open()
        flow.readiness = .ready
        var calls = 0
        let result = try transcript()
        flow.runOverride = { _ in calls += 1; return result }
        switch reason {
        case "missing": model.mediaResolved = false
        case "unreadable": model.mediaUnreadable = true
        case "relink": model.mediaRelinkCandidate = EditorModel.MediaRelinkCandidate(url: URL(fileURLWithPath: "/fixture/replacement.mov"),
            probe: MediaProbeResult(durationSeconds: model.sourceDuration, isPlayable: true))
        case "version": model.document.versionForTesting = true
        default:
            var project = model.project; project.media.source.durationSeconds = 0
            model.document.replaceProject(project)
        }
        let current = model.project
        #expect(!flow.mediaReady && !flow.canStart)
        flow.startApprovedRun(); await model.workTask?.value
        #expect(calls == 0 && model.project == current)
    }

    @Test func dailyAndMonthlySpendShareOneSlotWithoutHarnessBilling() async throws {
        let model = try editor(); defer { model.close() }
        model.app.set("voiceLab.enabled", .bool(true))
        await model.app.refreshMonthlySpend()
        model.transcription.spendToday = 0.03
        model.transcription.pendingCost = 0.02
        let status = StatusBarContent.make(app: model.app, editor: model, now: Date())
        let spend = try #require(status[.spend])
        #expect(spend.text.contains("today") && spend.text.contains("pending") && spend.text.contains("this month"))
        #expect(status.items.values.filter { $0.kind == .spend }.count == 1 && status[.billing] == nil)
        #expect(spend.help?.contains("separate local ledgers") == true)
    }

    private func editor(transcribed: Bool = false, locations: DataLocations? = nil) throws -> EditorModel {
        _ = NSApplication.shared
        let shared = try SharedResources.locate()
        var project = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        project.id = UUID().uuidString.lowercased(); project.media.source.durationSeconds = 326
        if !transcribed { project.transcript = nil; project.edits = ProjectEdits() }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: locations)
        app.providerKeyStoreOverride = InlineTranscriptionKeys()
        app.set("transcription.language", .string("en"))
        let model = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
        model.mediaResolved = true
        model.markMediaCheckedForAudit()
        model.transcription.readinessOverride = { _ in .ready }
        return model
    }
    private func transcript() throws -> Transcript {
        let shared = try SharedResources.locate()
        return try #require(DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip")).transcript)
    }
    @Test func englishOnThisMacStartsAppleWithoutAChoiceBlock() async throws {
        let model = try editor(); defer { model.close() }
        let result = try transcript()
        var plans: [TranscriptionPlan] = []
        model.transcription.runOverride = { plan in plans.append(plan); return result }
        await model.transcription.openOnImport()
        #expect(model.transcription.phase != .choosing)
        await model.workTask?.value
        #expect(plans.count == 1 && plans.first?.engine == .appleSpeech && plans.first?.model == nil && plans.first?.language == .forced("en"))
        #expect(model.project.transcript == result && model.transcription.phase == .hidden)
    }
    @Test(arguments: ["ask", "elevenlabs"])
    func storedConsentNeverStartsAPaidOrAskEngineAutomatically(mode: String) async throws {
        let model = try editor(); defer { model.close() }
        model.app.set("transcription.engineMode", .string(mode))
        model.app.set("transcription.cloudConsent.elevenlabs", .bool(true))
        var calls = 0
        let result = try transcript()
        model.transcription.runOverride = { _ in calls += 1; return result }
        await model.transcription.openOnImport()
        #expect(model.transcription.phase == .choosing && calls == 0)
        if mode == "elevenlabs" { model.transcription.startApprovedRun(); #expect(calls == 0 && !model.transcription.isRunning) }
    }
    @Test func noKnownLanguageAsksInsteadOfInventingEnglish() async throws {
        let model = try editor(); defer { model.close() }
        model.app.set("transcription.language", .string("auto"))
        model.transcription.readinessOverride = { _ in .unsupportedLanguage("unknown") }
        await model.transcription.openOnImport()
        #expect(model.transcription.phase == .choosing && model.transcription.language == "auto")
        #expect(model.transcription.error == "Which language is spoken?" && !model.transcription.canStart)
    }
    /// Apple Speech that doesn't answer in time is not ready, never unsupported (design.md §7.1 "Engine"): the block says so and
    /// Retry asks again, starting nothing; the other engines stay choosable.
    @Test func appleSpeechThatDoesNotAnswerSaysSoAndRetryAsksAgain() async throws {
        let model = try editor(); defer { model.close() }
        let noAnswer = Readiness.unavailable(reason: AppleSpeechTranscriber.noAnswerReason)
        var answers: [Readiness] = [noAnswer, .ready], asked: [TranscriptionPlan] = [], runs = 0
        model.transcription.readinessOverride = { plan in asked.append(plan); return answers.isEmpty ? .ready : answers.removeFirst() }
        let result = try transcript()
        model.transcription.runOverride = { _ in runs += 1; return result }
        await model.transcription.openOnImport()
        let flow = model.transcription
        #expect(flow.phase == .choosing && flow.engine == "apple" && runs == 0)
        #expect(flow.error == "Apple Speech didn't answer. Try again, or choose On this Mac.")
        #expect(flow.sendLine == flow.error && flow.primaryTitle == "Retry" && flow.canStart)
        flow.activate()
        await flow.choiceTask?.value
        #expect(asked.count == 2 && asked.allSatisfy { $0.engine == .appleSpeech } && runs == 0)
        #expect(flow.readiness == .ready && flow.error == nil && flow.primaryTitle == "Transcribe" && flow.phase == .choosing)
        // Another engine's unavailable reason keeps its own copy and its disabled primary.
        flow.readinessOverride = { _ in .unavailable(reason: "Choose a catalogue model") }
        flow.engine = "local"; flow.choicesChanged()
        await flow.choiceTask?.value
        #expect(flow.error == "Transcription is not available in this build. Your video and edits are still here." && !flow.canStart)
    }
    @Test func settingsAppleSpeechRowSaysWhenTheServiceDoesNotAnswer() async throws {
        let model = try editor(); defer { model.close() }
        let assets = model.app.appleSpeechAssets
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-apple-speech-row-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // A service that never answers: the stream stays open until the test ends; the bound's cancellation ends the wait.
        let (service, hold) = AsyncStream<Locale?>.makeStream(); defer { hold.finish() }
        let never = AppleSpeechLocaleSource(isAvailable: { true }, preferredLanguages: { ["en-GB"] },
            resolve: { _ in for await answer in service { return answer }; return nil }, bound: .milliseconds(100))
        assets.engine = AppleSpeechTranscriber(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]), localeSource: never)
        // A missing bound fails here instead of holding the suite.
        _ = try await TestDeadline.value(Task { await assets.check("en") }, "Apple Speech row check", timeout: .seconds(20))
        #expect(assets.state == .noAnswer && assets.statusText == "Apple Speech didn't answer. Try again, or choose On this Mac.")
    }
    @Test func reopeningDisablesStaleReadinessAndResetsReturnBeforeTheKeyLookup() async throws {
        let model = try editor(); defer { model.close() }
        let keys = InlineTranscriptionKeys()
        await keys.save("fixture-only", for: "elevenlabs")
        model.app.providerKeyStoreOverride = keys
        model.app.set("transcription.engineMode", .string("elevenlabs"))
        let flow = model.transcription
        flow.readiness = .ready; flow.hasKey = true; flow.rate = 0.22
        flow.keyGuard.reset(now: 100)
        await keys.pauseNextRead()
        let opening = Task { await flow.open() }
        for _ in 0..<10_000 {
            if await keys.readIsWaiting { break }
            await Task.yield()
        }
        let waiting = await keys.readIsWaiting
        #expect(waiting && flow.phase == .choosing)
        #expect(flow.readiness == nil && !flow.canStart)
        #expect(flow.keyGuard.appearedAt > 100)
        await keys.resumeRead()
        await opening.value
        #expect(flow.canStart)
    }
    @Test func missingKeyDisablesPaidApprovalAndSavingDoesNotSend() async throws {
        let model = try editor(); defer { model.close() }
        let keys = InlineTranscriptionKeys()
        model.app.providerKeyStoreOverride = keys
        model.app.set("transcription.engineMode", .string("elevenlabs"))
        await model.transcription.open()
        let flow = model.transcription
        #expect(!flow.hasKey && !flow.canStart && flow.primaryTitle.contains("$0.02"))
        var sends = 0
        let result = try transcript()
        flow.runOverride = { _ in sends += 1; return result }
        flow.activate(); #expect(sends == 0 && !model.app.bool("transcription.cloudConsent.elevenlabs"))
        flow.key = "fixture-only"; await flow.saveKey()
        let saves = await keys.saves
        #expect(flow.hasKey && flow.canStart && flow.key.isEmpty && sends == 0 && saves == 1)
        flow.pressReturn(timestamp: flow.keyGuard.appearedAt + 0.1, now: flow.keyGuard.appearedAt + 0.1, repeatKey: false, command: false)
        #expect(!flow.isRunning && sends == 0)
        flow.activate(); await model.workTask?.value
        #expect(sends == 1 && model.app.bool("transcription.cloudConsent.elevenlabs"))
    }
    @Test func priceComesFromDurationRateAndKeyTermsAndRememberOnlyWritesLanguage() async throws {
        let model = try editor(); defer { model.close() }
        model.app.set("transcription.engineMode", .string("elevenlabs"))
        await model.transcription.open()
        let flow = model.transcription
        #expect(flow.rate == 0.22 && flow.price == "≈ $0.02")
        flow.keyterms = "VoxClip, TalTech"; flow.speakers = "2"
        #expect(abs((flow.estimate ?? 0) - 326.0 / 3600 * 0.22 * 1.2) < 0.000001)
        var longer = model.project; longer.media.source.durationSeconds = 3600; model.document.replaceProject(longer)
        #expect(flow.price == "≈ $0.26")
        flow.hasKey = true; flow.language = "et"
        let result = try transcript()
        var plan: TranscriptionPlan?
        flow.runOverride = { value in plan = value; return result }
        flow.activate(); await model.workTask?.value
        #expect(plan?.options.diarize == true && plan?.options.numSpeakers == 2 && plan?.options.keyterms == ["VoxClip", "TalTech"])
        #expect(model.app.string("transcription.language") == "et" && model.app.string("transcription.engineMode") == "elevenlabs")
    }
    @Test(arguments: [false, true])
    func downloadCompletionUsesTheCurrentLocalChoiceButNeverThePaidChoice(installed: Bool) async throws {
        let model = try editor(); defer { model.close() }
        let flow = model.transcription
        await flow.open()
        let result = try transcript()
        var plans: [TranscriptionPlan] = []
        flow.runOverride = { value in plans.append(value); return result }
        flow.engine = "elevenlabs"; flow.hasKey = true
        await flow.finishedDownload(installed: installed, failure: installed ? nil : "Hugging Face is busy. Try again in a minute.")
        #expect(flow.phase == .choosing && plans.isEmpty && flow.error == nil)
        #expect(flow.primaryTitle.hasPrefix("Upload and Transcribe"))
        flow.engine = "local"; flow.language = "et"
        await flow.finishedDownload(installed: true, failure: nil)
        await model.workTask?.value
        #expect(plans.count == 1 && plans.first?.language == .forced("et") && plans.first?.engine == .whispercpp)
    }
    @Test func earlyReturnRepeatAndPreRowReturnCannotUpload() async throws {
        let model = try editor(); defer { model.close() }
        model.app.set("transcription.engineMode", .string("elevenlabs"))
        await model.transcription.open()
        let flow = model.transcription
        flow.hasKey = true
        let result = try transcript()
        var sends = 0
        flow.runOverride = { _ in sends += 1; return result }
        let at = flow.keyGuard.appearedAt
        for delta in [0, 0.08, 0.49] { flow.pressReturn(timestamp: at + delta, now: at + delta, repeatKey: false, command: false) }
        flow.pressReturn(timestamp: at + 1, now: at + 1, repeatKey: true, command: true)
        flow.pressReturn(timestamp: at - 1, now: at + 1, repeatKey: false, command: false)
        flow.pressReturn(timestamp: at + 0.1, now: at + 0.6, repeatKey: false, command: false)
        #expect(flow.phase == .choosing && sends == 0)
        flow.pressReturn(timestamp: at + 0.1, now: at + 0.1, repeatKey: false, command: true)
        await model.workTask?.value
        #expect(sends == 1)
    }
    @Test func aGenuinelyFreshReturnCanApproveThePaidRun() async throws {
        let model = try editor(); defer { model.close() }
        let flow = model.transcription
        model.app.set("transcription.engineMode", .string("elevenlabs"))
        await flow.open(); flow.hasKey = true
        let result = try transcript()
        var sends = 0
        flow.runOverride = { _ in sends += 1; return result }
        let opened = flow.keyGuard.appearedAt
        flow.pressReturn(timestamp: opened + 0.5, now: opened + 0.6, repeatKey: false, command: false)
        await model.workTask?.value
        #expect(sends == 1 && model.project.transcript == result)
    }
    @Test(arguments: [false, true])
    func cancellationExplainsWhatCanBeBilled(uploaded: Bool) async throws {
        let model = try editor(); defer { model.close() }
        model.app.set("transcription.engineMode", .string("elevenlabs"))
        await model.transcription.open()
        let flow = model.transcription
        flow.hasKey = true
        let barrier = InlineRunBarrier()
        defer { barrier.release(); flow.requestRunOverride = nil }
        flow.requestRunOverride = { request in
            if uploaded { flow.updateProgress(TranscriptionProgress(stage: .uploading, fraction: 0.4), request: request) }
            await barrier.suspend()
            throw CancellationError()
        }
        flow.activate()
        await barrier.waitUntilEntered()
        #expect(flow.cancelCopy == (uploaded ? "If you cancel now, ElevenLabs may still bill audio it already received." : "Nothing has been sent yet. Cancel now and nothing is billed."))
        let content = StatusBarContent.make(app: model.app, editor: model, now: Date())
        #expect(content[.billing] == nil && content[.spend]?.text.contains("pending") == true)
        #expect(content[.summary]?.text.contains("Transcribing") == true)
        flow.cancel(); barrier.release(); await model.workTask?.value
        #expect(model.project.transcript == nil && flow.phase == .folded)
        #expect(flow.cancelledNote?.contains(uploaded ? "may still bill" : "nothing is billed") == true)
        #expect(flow.pendingCost == nil)
    }
    @Test(arguments: [VoxClipError.keyRejected("elevenlabs"), .keyPermissionMissing, .quotaExceeded("elevenlabs"), .offline])
    func failedUploadsReplaceTheSendLineAndWaitForAnotherClick(failure: VoxClipError) async throws {
        let model = try editor(); defer { model.close() }
        model.app.set("transcription.engineMode", .string("elevenlabs"))
        await model.transcription.open()
        let flow = model.transcription
        flow.hasKey = true
        flow.runOverride = { _ in throw failure }
        flow.activate(); await model.workTask?.value
        #expect(flow.phase == .choosing && flow.error != nil && flow.sendLine == flow.error)
        #expect(model.project.transcript == nil && flow.pendingCost == nil)
        if failure.code == .keyRejected || failure.code == .keyPermissionMissing { #expect(!flow.hasKey && !flow.canStart) }
    }
    @Test(arguments: [false, true])
    func transcribeAgainWarnsKeepsOnCancelAndClearsEverythingItNamesOnSuccess(paid: Bool) async throws {
        let model = try editor(transcribed: true); defer { model.close() }
        var seeded = model.project
        let words = try #require(seeded.transcript?.words)
        seeded.edits.clips = [ClipRange(id: "test-clip", startWordId: words[0].id, endWordId: words[2].id)]
        seeded.ai.results = [ProjectAIResult(id: "test-ai", createdAt: Date(), provider: "fixture", model: "fixture", preset: .best, inputSha256: String(repeating: "0", count: 64))]
        model.document.replaceProject(seeded); model.refresh()
        let rewrite = RewriteSession(editor: model, scope: .fullTake, envelope: nil, connector: nil)
        model.openRewrite = rewrite
        try rewrite.receivePassage(RewriteSession.corrected(model.project).dropLast().map(\.text).joined(separator: " "))
        rewrite.finishRun(seconds: 1)
        #expect(model.proposal != nil)
        let before = model.project
        let flow = model.transcription
        if paid { model.app.set("transcription.engineMode", .string("elevenlabs")) }
        await flow.open(again: true)
        flow.hasKey = true
        #expect(flow.warning == "This replaces the transcript and removes 3 cuts, 1 correction, 1 clip and the AI suggestions.")
        #expect(flow.primaryTitle == "Transcribe Again" + (paid ? " · " + flow.price : ""))
        flow.pressReturn(timestamp: 100, now: 100, repeatKey: false, command: true)
        flow.pressReturn(timestamp: flow.keyGuard.appearedAt + 1, now: flow.keyGuard.appearedAt + 1, repeatKey: false, command: true, focusedPrimary: true)
        #expect(!flow.isRunning && model.project == before)
        flow.notNow(); #expect(model.project == before && flow.phase == .hidden)
        await flow.open(again: true)
        flow.hasKey = true
        flow.runOverride = { _ in try self.transcript() }
        let host = NSHostingView(rootView: InlineTranscriptionView(transcription: flow).frame(width: 652).environment(model.app))
        host.safeAreaRegions = []
        host.frame = NSRect(x: 0, y: 0, width: 652, height: 600)
        for _ in 0..<5 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        func primary(_ view: NSView) -> InlineGuardedButton? {
            if let button = view as? InlineGuardedButton { return button }
            return view.subviews.lazy.compactMap(primary).first
        }
        let button = try #require(primary(host))
        #expect(!button.accented && button.title == flow.primaryTitle && host.window == nil)
        let undoSteps = model.undoSteps
        button.spaceHandler?()
        if paid { #expect(!flow.isRunning); button.actionHandler() }
        await model.workTask?.value
        #expect(flow.phase == .hidden)
        #expect(model.undoSteps == undoSteps + 1)
        #expect(model.project.edits.cutWordIds.isEmpty && model.project.edits.cutPauseIds.isEmpty && model.project.edits.corrections.isEmpty && model.project.edits.clips.isEmpty)
        #expect(model.project.ai == ProjectAI() && model.openRewrite == nil && model.proposal == nil)
    }
    @Test(arguments: [false, true])
    func cancelledOrFailedReplacementPreservesThePendingRewriteReview(fails: Bool) async throws {
        let model = try editor(transcribed: true); defer { model.close() }
        let rewrite = RewriteSession(editor: model, scope: .fullTake, envelope: nil, connector: nil)
        model.openRewrite = rewrite
        let corrected = RewriteSession.corrected(model.project)
        try rewrite.receivePassage(corrected.dropLast().map(\.text).joined(separator: " "))
        rewrite.finishRun(seconds: 1)
        let proposal = try #require(model.proposal)
        let before = model.project
        let flow = model.transcription
        await flow.open(again: true)
        flow.runOverride = { _ in
            if fails { throw VoxClipError.offline }
            await TestDeadline.until { Task.isCancelled }
            throw CancellationError()
        }
        flow.activate()
        if !fails { flow.cancel() }
        await model.workTask?.value
        #expect(model.project == before)
        #expect(model.openRewrite === rewrite && rewrite.isOpen)
        #expect(model.proposal?.id == proposal.id)
    }
    @Test(arguments: ["cut", "correction", "clip", "source"], [false, true])
    func approvalBaselineRejectsEditsBeforeTheWorkerOrDuringItsLease(edit: String, waitingForLease: Bool) async throws {
        let model = try editor(transcribed: true); defer { model.close() }
        let flow = model.transcription
        let review = RewriteSession(editor: model, scope: .fullTake, envelope: nil, connector: nil)
        model.openRewrite = review
        try review.receivePassage(RewriteSession.corrected(model.project).dropLast().map(\.text).joined(separator: " "))
        review.finishRun(seconds: 1)
        let proposalID = try #require(model.proposal?.id)
        model.app.set("transcription.engineMode", .string("elevenlabs"))
        await flow.open(again: true); flow.hasKey = true
        let before = model.project
        let barrier = InlineRunBarrier()
        defer { barrier.release(); flow.leaseOverride = nil; flow.runOverride = nil }
        var leasedKey: String?
        if waitingForLease {
            flow.leaseOverride = { key in
                leasedKey = key
                await barrier.suspend()
                return await model.app.cacheKeys.lease(key)
            }
        }
        var sends = 0
        let result = try transcript()
        flow.runOverride = { _ in sends += 1; return result }
        let undoSteps = model.undoSteps
        flow.activate()
        let request = try #require(flow.activeRun)
        #expect(request.project == before && request.plan.engine == .elevenlabs)
        if waitingForLease { await barrier.waitUntilEntered() }
        var changed = model.project
        let words = try #require(changed.transcript?.words)
        switch edit {
        case "cut": changed.edits.cutWordIds.append(words.last!.id)
        case "correction": changed.edits.corrections[words[0].id] = "Keep my new correction"
        case "clip": changed.edits.clips.append(ClipRange(id: "post-approval", startWordId: words[0].id, endWordId: words[2].id))
        default:
            changed.media.source.absolutePath = "/synthetic/new-source.mp4"
            changed.media.source.contentKey = "post-approval-source"
            changed.media.source.durationSeconds += 30
        }
        model.document.replaceProject(changed)
        if waitingForLease { barrier.release() }
        await model.workTask?.value
        #expect(request.project == before && model.project == changed && sends == 0)
        #expect(!waitingForLease || leasedKey == before.media.source.contentKey)
        #expect(flow.error?.contains("project changed") == true && flow.phase == .choosing)
        #expect(model.project.transcript == before.transcript && model.openRewrite === review)
        #expect(model.proposal?.id == proposalID && model.undoSteps == undoSteps)
        #expect(!request.evidence.snapshot.uploadStarted && !request.spendRecorded)
    }

    @Test func postApprovalEditsDuringASimulatedDownloadAreNotRebasedIntoTheRun() async throws {
        let model = try editor(transcribed: true); defer { model.close() }
        let flow = model.transcription
        await flow.open(again: true)
        flow.engine = "local"; flow.selectedModel = nil
        flow.readiness = .needsModels(ids: ["synthetic-not-installed"], bytes: 1)
        let before = model.project
        let barrier = InlineRunBarrier()
        defer { barrier.release(); flow.leaseOverride = nil }
        flow.leaseOverride = { key in await barrier.suspend(); return await model.app.cacheKeys.lease(key) }
        let result = try transcript()
        var sends = 0
        flow.runOverride = { _ in sends += 1; return result }
        flow.activate()
        #expect(!flow.isDownloading && flow.phase == .choosing)
        var changed = model.project
        changed.edits.corrections[changed.transcript!.words[0].id] = "Edited during download"
        model.document.replaceProject(changed)
        await flow.finishedDownload(installed: true, failure: nil)
        await barrier.waitUntilEntered()
        let request = try #require(flow.activeRun)
        #expect(request.project == before && request.plan.engine == .whispercpp)
        barrier.release(); await model.workTask?.value
        #expect(model.project == changed && sends == 0 && flow.error?.contains("project changed") == true)
    }

    @Test func editingAfterTheSendAlsoPreservesThePriorTranscriptAndReview() async throws {
        let model = try editor(transcribed: true); defer { model.close() }
        let flow = model.transcription
        let review = RewriteSession(editor: model, scope: .fullTake, envelope: nil, connector: nil)
        model.openRewrite = review
        try review.receivePassage(RewriteSession.corrected(model.project).dropLast().map(\.text).joined(separator: " "))
        review.finishRun(seconds: 1)
        let proposalID = try #require(model.proposal?.id)
        await flow.open(again: true)
        let barrier = InlineRunBarrier(), result = try transcript()
        defer { barrier.release(); flow.runOverride = nil }
        flow.runOverride = { _ in await barrier.suspend(); return result }
        flow.activate(); await barrier.waitUntilEntered()
        var changed = model.project
        changed.edits.corrections[changed.transcript!.words[0].id] = "Edited while running"
        model.document.replaceProject(changed)
        let undoSteps = model.undoSteps
        barrier.release(); await model.workTask?.value
        #expect(model.project == changed && model.openRewrite === review && model.proposal?.id == proposalID)
        #expect(flow.error?.contains("project changed") == true && model.undoSteps == undoSteps)
    }

    @Test(arguments: ["accepted", "cancelled", "keyRejected", "cached", "preupload"], [false, true])
    func oldWorkersCannotMutateANewRunOrBorrowItsUploadEvidence(outcome: String, newUploaded: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-inline-overlap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try editor(transcribed: true, locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        defer { model.close() }
        let flow = model.transcription
        model.app.set("transcription.engineMode", .string("elevenlabs"))
        await flow.open(again: true); flow.hasKey = true
        let oldBarrier = InlineRunBarrier(), newBarrier = InlineRunBarrier()
        let oldStream = AsyncStream<TranscriptionProgress>.makeStream()
        let newStream = AsyncStream<TranscriptionProgress>.makeStream()
        defer {
            oldBarrier.release(); newBarrier.release()
            oldStream.continuation.finish(); newStream.continuation.finish()
            flow.requestRunOverride = nil
        }
        let result = try transcript()
        var oldRequest: InlineTranscription.ApprovedRun?
        flow.requestRunOverride = { request in
            oldRequest = request
            request.watch = flow.watchProgress(oldStream.stream, request: request)
            if outcome != "preupload" { flow.updateProgress(TranscriptionProgress(stage: .uploading, fraction: 0.3), request: request) }
            await oldBarrier.suspend()
            flow.updateProgress(TranscriptionProgress(stage: .aligning, fraction: 1), request: request)
            switch outcome {
            case "accepted": return TranscriptionResult(transcript: result)
            case "cached": return TranscriptionResult(transcript: result, fromCache: true)
            case "keyRejected": throw VoxClipError.keyRejected("elevenlabs")
            default: throw CancellationError()
            }
        }
        flow.activate()
        let oldWorker = try #require(model.workTask)
        await oldBarrier.waitUntilEntered()
        let oldRun = try #require(oldRequest), oldCost = try #require(oldRun.cost)
        let oldWatch = try #require(oldRun.watch)
        flow.close(); await oldWatch.value
        #expect(oldWatch.isCancelled)
        var next = model.project
        next.media.source.contentKey = "new-upload-source"; next.media.source.durationSeconds *= 2
        model.document.replaceProject(next)
        await flow.open(again: true); flow.hasKey = true
        flow.requestRunOverride = { request in
            request.watch = flow.watchProgress(newStream.stream, request: request)
            if newUploaded { flow.updateProgress(TranscriptionProgress(stage: .uploading, fraction: 0.6), request: request) }
            await newBarrier.suspend()
            throw VoxClipError.offline
        }
        flow.activate()
        let newWorker = try #require(model.workTask), newRun = try #require(flow.activeRun)
        await newBarrier.waitUntilEntered()
        let newCost = try #require(newRun.cost)
        let displayedProgress = model.progress, displayedFraction = model.progressFraction, displayedStage = model.progressStage
        let guardTime = flow.keyGuard.appearedAt, announcements = model.announcements, displayedSpend = flow.spendToday
        oldStream.continuation.yield(TranscriptionProgress(stage: .uploading, fraction: 1))
        oldBarrier.release(); await oldWorker.value
        #expect(oldRun.watch == nil && oldRun.project.media.source.contentKey != newRun.project.media.source.contentKey)
        #expect(flow.activeRun === newRun && flow.phase == .running && flow.pendingCost == newCost)
        #expect(flow.error == nil && flow.cancelledNote == nil && flow.completion == nil && flow.completedAt == nil && flow.hasKey)
        #expect(flow.uploadStarted == newUploaded && newRun.evidence.snapshot.uploadStarted == newUploaded)
        #expect(model.progress == displayedProgress && model.progressFraction == displayedFraction && model.progressStage == displayedStage)
        #expect(model.announcements == announcements && flow.keyGuard.appearedAt == guardTime && flow.spendToday == displayedSpend)
        let oldCharge = outcome == "cached" || outcome == "preupload" ? 0 : oldCost
        let afterOld = await model.app.transcriptionSpend.total(at: oldRun.approvedAt)
        #expect(abs(afterOld.amount - oldCharge) < 0.000001 && afterOld.uncertain == (oldCharge > 0))
        #expect(oldRun.spendRecorded == (oldCharge > 0))
        newBarrier.release(); await newWorker.value
        let total = await model.app.transcriptionSpend.total(at: newRun.approvedAt)
        let expected = oldCharge + (newUploaded ? newCost : 0)
        #expect(abs(total.amount - expected) < 0.000001 && total.uncertain == (expected > 0))
        #expect(newRun.watch == nil && newRun.spendRecorded == newUploaded)
        #expect(flow.phase == .choosing && flow.error != nil && flow.cancelledNote == nil && flow.hasKey)
        #expect(model.project == next)
    }

    @Test func oldErrorRedactionCannotRejectTheNewKeyOrAnnounceIntoItsRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-inline-redaction-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try editor(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        defer { model.close() }
        let flow = model.transcription
        model.app.set("transcription.engineMode", .string("elevenlabs"))
        await flow.open(); flow.hasKey = true
        let redaction = InlineRunBarrier(), current = InlineRunBarrier()
        defer { redaction.release(); current.release(); flow.requestRunOverride = nil; flow.runErrorOverride = nil }
        flow.requestRunOverride = { request in request.evidence.recordUploadStarted(); throw VoxClipError.keyRejected("elevenlabs") }
        flow.runErrorOverride = { _ in await redaction.suspend(); return "Old request rejected its key" }
        flow.activate()
        let oldWorker = try #require(model.workTask), oldRun = try #require(flow.activeRun)
        await redaction.waitUntilEntered()
        flow.close(); await flow.open(); flow.hasKey = true
        flow.runErrorOverride = nil
        flow.requestRunOverride = { _ in await current.suspend(); throw VoxClipError.offline }
        flow.activate()
        let newWorker = try #require(model.workTask), newRun = try #require(flow.activeRun)
        await current.waitUntilEntered()
        let announcements = model.announcements, guardTime = flow.keyGuard.appearedAt
        redaction.release(); await oldWorker.value
        #expect(flow.activeRun === newRun && flow.hasKey && flow.error == nil && flow.cancelledNote == nil)
        #expect(flow.phase == .running && flow.pendingCost == newRun.cost && flow.keyGuard.appearedAt == guardTime)
        #expect(model.announcements == announcements && !flow.uploadStarted && oldRun.spendRecorded)
        let total = await model.app.transcriptionSpend.total(at: oldRun.approvedAt)
        #expect(abs(total.amount - (oldRun.cost ?? 0)) < 0.000001 && total.uncertain)
        current.release(); await newWorker.value
        #expect(flow.phase == .choosing && flow.hasKey && !newRun.spendRecorded)
    }

    @Test func replacementWarningLeavesOutZeroEdits() throws {
        let model = try editor(); defer { model.close() }
        #expect(AppDelegate.retranscriptionWarning(for: model.project) == "This replaces the transcript and removes the AI suggestions.")
    }
    @Test func canceledDownloadKeepsResumableBytesAndNotNowFoldsTheBlock() async throws {
        let model = try editor(); defer { model.close() }
        let flow = model.transcription
        await flow.open()
        flow.lastDownload = ModelDownloadProgress(modelID: try #require(flow.selectedModel?.id), receivedBytes: 212_000_000, totalBytes: 574_000_000)
        flow.cancelDownload()
        #expect(flow.downloadCancelled && flow.keptDownloadCopy?.contains("212") == true)
        flow.notNow(); #expect(flow.phase == .folded && model.project.transcript == nil)
    }
    @Test func estimatesPersistByDayAndCancelledUploadsRemainAnUpperBound() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"]!).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])
        let ledger = TranscriptionSpend(locations: locations), date = Date(timeIntervalSince1970: 1_000_000)
        let first = await ledger.record(0.02, uncertain: false, at: date)
        let second = await ledger.record(0.02, uncertain: true, at: date)
        let reopened = await TranscriptionSpend(locations: locations).total(at: date)
        #expect(first.amount == 0.02 && second.amount == 0.04 && reopened.amount == 0.04 && reopened.uncertain)
        #expect(await ledger.total(at: date.addingTimeInterval(172_800)).amount == 0)
    }
    @Test func choiceStatesDrawTheirAvailableActionsWithoutWindows() async throws {
        for state in ["download", "paid", "missing-key", "again", "folded", "running", "failed"] {
            let model = try editor(transcribed: state == "again")
            let flow = model.transcription
            await flow.open(again: state == "again")
            flow.engine = state == "paid" || state == "missing-key" || state == "running" ? "elevenlabs" : "local"
            flow.hasKey = state != "missing-key"
            flow.readiness = state == "download" ? .needsModels(ids: ["fixture"], bytes: 574_000_000) : .ready
            flow.error = state == "failed" ? "You're offline." : nil
            if state == "folded" { flow.phase = .folded }
            if state == "running" { flow.phase = .running; flow.pendingCost = 0.02; flow.progress = TranscriptionProgress(stage: .uploading, fraction: 0.8); flow.uploadStarted = true; flow.runStage = 2 }
            for width in [652, 440] {
                let host = NSHostingView(rootView: InlineTranscriptionView(transcription: flow).frame(width: CGFloat(width), alignment: .topLeading).environment(model.app).environment(\.colorScheme, .dark))
                host.safeAreaRegions = []
                host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
                host.layoutSubtreeIfNeeded()
                for _ in 0..<5 { await Task.yield(); host.layoutSubtreeIfNeeded() }
                func buttons(_ view: NSView) -> [InlineGuardedButton] {
                    (view as? InlineGuardedButton).map { [$0] } ?? view.subviews.flatMap(buttons)
                }
                let primaries = buttons(host), titles = primaries.map(\.title)
                if state == "folded" || state == "running" { #expect(titles.isEmpty, "\(state): \(titles)") }
                else {
                    let primary = try #require(primaries.first { $0.title == flow.primaryTitle }, "\(state): \(titles)")
                    #expect(primary.isEnabled == flow.canStart, "\(state): primary availability")
                    if state == "missing-key" {
                        #expect(!primary.acceptsFirstResponder)
                        var activations = 0
                        primary.actionHandler = { activations += 1 }
                        primary.returnHandler = { _ in activations += 1 }
                        primary.spaceHandler = { activations += 1 }
                        primary.performClick(nil)
                        for code in [UInt16(36), UInt16(49)] {
                            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                characters: code == 36 ? "\r" : " ", charactersIgnoringModifiers: code == 36 ? "\r" : " ",
                                isARepeat: false, keyCode: code))
                            primary.keyDown(with: event)
                        }
                        #expect(activations == 0)
                    }
                }
                #expect(host.window == nil)
            }
            model.close()
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_INLINE_TRANSPORT_AUDIT"] == "1"))
    func paidClickRunsTheMovedExtractionPipelineWithAStubTransport() async throws {
        let shared = try SharedResources.locate()
        let fixture = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        let results = try await DebugTranscriptionConsent.run(fixture: fixture)
        for result in results { #expect(result.passed, "\(result.name)") }
    }
    @Test func sheetAndRetranscriptionDialogPathsAreDeleted() throws {
        let root = try SharedResources.locate().root.deletingLastPathComponent().appendingPathComponent("apps/macos/Sources/VoxClip")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("TranscriptionSheet.swift").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("TranscriptionConsentGate.swift").path))
        let workspace = try String(contentsOf: root.appendingPathComponent("EditorView.swift"), encoding: .utf8)
        #expect(!workspace.contains("showTranscribe") && workspace.contains("InlineTranscriptionView"))
        let controller = try String(contentsOf: root.appendingPathComponent("InlineTranscription.swift"), encoding: .utf8)
        #expect(!controller.contains("NSAlert(") && !controller.contains(".sheet("))
    }
}
#endif
