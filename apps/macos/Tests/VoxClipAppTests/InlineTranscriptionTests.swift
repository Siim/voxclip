#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxClip
@testable import VoxClipCore

private actor InlineTranscriptionKeys: ProviderKeyStore {
    var keyed = false
    var saves = 0
    private var pauseRead = false
    var readIsWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pauseNextRead() { pauseRead = true }
    func resumeRead() { continuation?.resume(); continuation = nil }
    func hasKey(for provider: String) async -> Bool {
        if pauseRead {
            pauseRead = false; readIsWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        return keyed
    }
    func save(_ value: String, for provider: String) { keyed = true; saves += 1 }
}

@Suite("Inline Transcribe", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil))
@MainActor struct InlineTranscriptionTests {
    private func editor(transcribed: Bool = false) throws -> EditorModel {
        _ = NSApplication.shared
        let shared = try SharedResources.locate()
        var project = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        project.id = UUID().uuidString.lowercased(); project.media.source.durationSeconds = 326
        if !transcribed { project.transcript = nil; project.edits = ProjectEdits() }
        let app = AppModel(settingsStore: RegressionSettingsStore())
        app.set("transcription.language", .string("en"))
        let model = EditorModel(document: VoxClipDocument(project: project), app: app, preview: DemoPreviewEngine())
        model.mediaResolved = true
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
    @Test func missingKeyHasNoPaidPrimaryAndSaveOnlyRevealsIt() async throws {
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
        #expect(flow.phase == .choosing && sends == 0)
        flow.pressReturn(timestamp: at + 0.1, now: at + 0.1, repeatKey: false, command: true)
        await model.workTask?.value
        #expect(sends == 1)
    }
    @Test(arguments: [false, true])
    func cancellationExplainsWhatCanBeBilled(uploaded: Bool) async throws {
        let model = try editor(); defer { model.close() }
        model.app.set("transcription.engineMode", .string("elevenlabs"))
        await model.transcription.open()
        let flow = model.transcription
        flow.hasKey = true
        flow.runOverride = { _ in
            if uploaded { flow.updateProgress(TranscriptionProgress(stage: .uploading, fraction: 0.4)) }
            while !Task.isCancelled { await Task.yield() }
            throw CancellationError()
        }
        flow.activate()
        for _ in 0..<10_000 where uploaded && !flow.uploadStarted { await Task.yield() }
        #expect(flow.cancelCopy == (uploaded ? "If you cancel now, ElevenLabs may still bill audio it already received." : "Nothing has been sent yet. Cancel now and nothing is billed."))
        let content = StatusBarContent.make(app: model.app, editor: model, now: Date())
        #expect(content[.billing] == nil && content[.spend]?.text.contains("pending") == true)
        #expect(content[.summary]?.text.contains("Transcribing") == true)
        flow.cancel(); await model.workTask?.value
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
        button.spaceHandler?()
        if paid { #expect(!flow.isRunning); button.actionHandler() }
        await model.workTask?.value
        #expect(flow.phase == .hidden)
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
            while !Task.isCancelled { await Task.yield() }
            throw CancellationError()
        }
        flow.activate()
        if !fails { flow.cancel() }
        await model.workTask?.value
        #expect(model.project == before)
        #expect(model.openRewrite === rewrite && rewrite.isOpen)
        #expect(model.proposal?.id == proposal.id)
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
            if state == "running" { flow.phase = .running; flow.pendingCost = 0.02; flow.updateProgress(TranscriptionProgress(stage: .uploading, fraction: 0.8)) }
            for width in [652, 440] {
                let host = NSHostingView(rootView: InlineTranscriptionView(transcription: flow).frame(width: CGFloat(width), alignment: .topLeading).environment(model.app).environment(\.colorScheme, .dark))
                host.safeAreaRegions = []
                host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
                host.layoutSubtreeIfNeeded()
                for _ in 0..<5 { await Task.yield(); host.layoutSubtreeIfNeeded() }
                func buttons(_ view: NSView) -> [InlineGuardedButton] {
                    (view as? InlineGuardedButton).map { [$0] } ?? view.subviews.flatMap(buttons)
                }
                let titles = buttons(host).map(\.title)
                if state == "missing-key" || state == "folded" || state == "running" { #expect(titles.isEmpty, "\(state): \(titles)") }
                else { #expect(titles.contains(flow.primaryTitle), "\(state): \(titles)") }
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
