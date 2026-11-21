#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

private struct ReasonKeys: KeyProvider {
    func key(for provider: String) async throws -> String? {
        Issue.record("Stuck-reason tests must not request credentials")
        return nil
    }
}

/// Why a phrase's takes are stuck (RewriteAutoFix.swift `stuckReason`, voice-lab §8.2.2): a failed take is fixed by what
/// failed, never by its length, and the length test counts every video duration, the matched speed included. On the
/// production session and plan with a scripted take backend: no provider, AI or speaker is reached.
@Suite("Rewrite auto-fix stuck reasons", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil),
       .offlineFixtures, .timeLimit(.minutes(2)))
@MainActor struct RewriteAutoFixReasonTests {
    /// One scripted take: its length as a share of the slot, and its failed checks.
    struct Script {
        var ratio = 1.0
        var failures: [VoiceLabTakeQAFailure] = []
        /// A failure other than a check (the take's audio, say), with no failed check.
        var failure: VoiceLabTakeFailure?
    }

    @MainActor private final class Backend {
        let record: VoiceConsentRecord
        var scripts: [Script] = []
        var inputs: [VoiceLabTakeInput] = []
        var executions = 0
        init(record: VoiceConsentRecord) { self.record = record }

        func quote(seed: UInt32) -> VoiceLabTakeQuote {
            let estimate = CostEstimate(provider: "elevenlabs", operation: "test", units: 1, unit: "test", usd: 0.01, basis: "fixture")
            func request(_ operation: VoiceLabOperation) -> VoiceLabQuote {
                VoiceLabQuote(id: UUID(), operation: operation, requestID: UUID(), estimate: estimate, region: .default,
                    endpoint: operation == .speechToText ? "v1/speech-to-text" : "v1/text-to-dialogue/with-timestamps",
                    languageMode: .explicit("en"), fingerprint: "fixture")
            }
            return VoiceLabTakeQuote(index: 0, seed: seed, synthesis: request(.textToSpeech), qa: request(.speechToText))
        }
        /// A take `script.ratio` times its slot: an exact fit at 1, else a changed duration with no cut.
        func row(input: VoiceLabTakeInput, quote: VoiceLabTakeQuote, script: Script) -> VoiceLabTakeRow {
            let window = input.window
            let slot = window.end - window.start
            let frames = Int64(EditingPrimitives.jsRound(slot * script.ratio * 24_000))
            let duration = Double(frames) / 24_000
            let tokens = input.text.split(separator: " ").map(String.init)
            let words = tokens.enumerated().map { index, text in
                VoiceLabWord(text: text, start: 0.1 + Double(index) * (duration - 0.2) / Double(tokens.count),
                    end: 0.1 + Double(index + 1) * (duration - 0.2) / Double(tokens.count), synthetic: true)
            }
            let plan = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
                trimStartFrame: 2_400, trimEndFrame: frames + 2_400, windowStart: window.start, windowEnd: window.end,
                windowStartSample: window.startSample, windowEndSample: window.endSample, outputFrames: frames, words: words)
            let fit: VoiceLabFitResult = script.ratio == 1 ? .exact(plan) : .changedDuration(plan, naturalOut: duration, residualSeconds: duration - slot)
            let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [], mixed: [], patchRange: 0..<0, seams: [], gainDb: 0,
                roomTone: .init(sourceStartSample: 504_000, sourceEndSample: 528_000, gainDb: -30), fit: fit)
            let receipt = VoiceLabReceipt(provider: "elevenlabs", region: .default, endpoint: quote.synthesis.endpoint,
                modelID: input.modelID, voiceID: record.voiceId, requestID: quote.synthesis.requestID, providerRequestID: nil, spendWarning: nil)
            let match = script.failures.contains(.transcript) ? 0.4 : 1
            let speaker = script.failures.contains(.speaker) ? 0.2 : 0.95
            let qa = VoiceLabTakeQAResult(values: .init(transcriptMatch: match, lufsJumpLu: 0, peakDbfs: -10, speakerScore: speaker), failures: script.failures)
            let failure = script.failure ?? (script.failures.isEmpty ? nil : .qa(script.failures))
            return VoiceLabTakeRow(id: quote.synthesis.requestID, index: 0, seed: quote.seed, receipt: receipt, audio: audio, qa: qa,
                score: failure == nil ? speaker : nil, failure: failure, quote: quote, accepted: [quote.synthesis.requestID, quote.qa.requestID])
        }
        func connected() -> ClipTakePlan.Backend {
            var backend = ClipTakePlan.Backend(runs: [])
            backend.prepare = { inputs, _, _ in
                self.inputs = inputs
                return try VoiceLabTakeBatch(windows: inputs.map { input in
                    .init(input: input, quote: .init(id: UUID(), takes: [self.quote(seed: input.seed)], preparedAt: Date()))
                })
            }
            backend.approve = { _, _, _ in }
            backend.execute = { batch, index, _, _ in
                let script = self.scripts.isEmpty ? Script() : self.scripts.removeFirst()
                self.executions += 1
                let window = batch.windows[index]
                return VoiceLabTakeRunResult(rows: [self.row(input: window.input, quote: try #require(window.quote.takes.first), script: script)],
                    end: .completed)
            }
            backend.publish = { _, _, _, _ in
                Issue.record("No take is published here")
                throw VoiceLabError.consentRequired
            }
            backend.discard = {}; backend.invalidate = {}; backend.scratch = { _, _ in nil }; backend.retire = { _, _ in }
            return backend
        }
    }

    @MainActor private struct Fixture {
        let root: URL
        let editor: EditorModel
        let session: RewriteSession
        let backend: Backend
        func close() { editor.close(); try? FileManager.default.removeItem(at: root) }
    }

    private static let tokens = ["Carefully", "reviewed", "replacement", "stays", "natural"]

    private func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let shared = try SharedResources.locate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-stuck-reason-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = try JSONDecoder().decode(VoiceConsentRecord.self,
            from: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json")))
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        project.id = UUID().uuidString.lowercased()
        project.voiceLab.segments = []; project.voiceLab.assets = []; project.edits = ProjectEdits()
        project.captions.styleId = "off"
        let source = shared.root.appendingPathComponent("fixtures/media/joins-tone.mov")
        project.media.source.absolutePath = source.path
        project.media.source.contentKey = try JSONProjectStore.contentKey(for: source)
        project.media.source.sizeBytes = try #require(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber).int64Value
        project.media.source.durationSeconds = 12
        project.media.source.video = MediaVideo(width: 640, height: 360, frameRate: 30, rotationDegrees: 0)
        project.media.source.audio?.sampleRate = 48_000
        project.transcript?.durationSeconds = 12
        project.transcript?.words = (0..<90).map { index in
            let start = 0.1 + Double(index) * 0.1
            return TimedWord(id: "w\(index)", text: "x", start: start, end: start + 0.08,
                rawStart: start + 0.002, rawEnd: start + 0.078, conf: 0.99, speaker: "owner")
        }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        let envelope = AudioEnvelope(sampleRate: 48_000, levels: [Float](repeating: 0.01, count: 1_200))
        let session = RewriteSession(editor: editor, scope: .fullTake, envelope: envelope, connector: nil)
        editor.rewrite = session
        session.receive([RewriteChange(hunk: VoiceLabDiffHunk(kind: .voice, sourceWordIds: (15...46).map { "w\($0)" }, newTokens: Self.tokens,
            correctedTexts: [], absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: 15, sourceEndIndex: 47, anchorSeconds: nil))])
        session.finishRun(seconds: 1); session.showProposal()
        for ordinal in session.blockedVoiceOrdinals { session.pricedAnyway.insert(ordinal) }
        session.showProposal()
        session.configureGeneration(client: ElevenLabsVoiceLab(keys: ReasonKeys(), region: .default),
            store: VoiceConsentStore(locations: app.locations), speaker: .unavailable)
        try #require(session.generation).showFixture("cost-confirmation", voice: record)
        let backend = Backend(record: record)
        session.takeBackend = { _, _ in backend.connected() }
        await session.prepareTakes()
        let plan = try #require(session.takePlan)
        #expect(plan.inputs.count == 1 && plan.prepareDurationRender != nil, Comment(rawValue: plan.problem))
        return Fixture(root: root, editor: editor, session: session, backend: backend)
    }

    /// Makes the plan's first takes with `script`, unapproved by the resolver (no automatic step runs).
    private func takes(_ fixture: Fixture, _ script: Script) async throws -> ClipTakePlan {
        let plan = try #require(fixture.session.takePlan)
        fixture.backend.scripts = [script]
        await plan.start(approved: true)
        #expect(plan.phrases[0].takes.count == 1, Comment(rawValue: plan.problem))
        return plan
    }
    /// The plan's phrase with `scripts`' takes in place of its own, none selected: the unselected branch.
    private func phrase(_ fixture: Fixture, _ plan: ClipTakePlan, _ scripts: [Script]) throws -> ClipTakePlan.Phrase {
        var phrase = plan.phrases[0]
        let input = try #require(fixture.backend.inputs.first)
        phrase.takes = scripts.enumerated().map { index, script in
            ClipTakePlan.Take(number: index + 1, row: fixture.backend.row(input: input, quote: fixture.backend.quote(seed: UInt32(index)), script: script))
        }
        phrase.selectedID = nil
        return phrase
    }

    /// The finding (2026-11-21): eleven_v4 skipped two words, so the phrase's only take failed its word check and ran
    /// about 25% short, with no cut. The resolver asked for a longer wording ("say the same point more fully") and paid
    /// for a take of the padded text; one more take of the same words was the fix.
    @Test func aTakeThatSkippedWordsIsRetakenNeverRewordedLonger() async throws {
        let fixture = try await fixture(); defer { fixture.close() }
        let session = fixture.session
        let plan = try await takes(fixture, Script(ratio: 0.75, failures: [.transcript]))
        let take = try #require(plan.phrases[0].takes.first)
        #expect(!take.row.selectable && plan.phrases[0].selectedID == nil)
        #expect(!plan.lengthFits(take: take) && !session.durationCarries(take, plan: plan))
        #expect(session.stuckReason(plan.phrases[0], plan: plan) == .words)
        // A failed speaker check, or too little speech to check the voice, is named the same way at any length.
        #expect(session.stuckReason(try phrase(fixture, plan, [Script(ratio: 0.7, failures: [.speaker])]), plan: plan) == .voice)
        #expect(session.stuckReason(try phrase(fixture, plan, [Script(ratio: 1.6, failures: [.transcript])]), plan: plan) == .words)
        #expect(session.stuckReason(try phrase(fixture, plan, [Script(ratio: 0.6, failures: [.insufficientGeneratedSpeech])]), plan: plan) == .shortSpeech)
    }

    /// The length test counts the matched speed: a take 1.1× its slot whose picture can be slowed to 0.91× is carried
    /// (`lengthFits` counted only keep source and a cut). Past 1.25× nothing carries it, and only then is it too long.
    @Test func aTakeTheMatchedSpeedCarriesIsNotTooLong() async throws {
        let fixture = try await fixture(); defer { fixture.close() }
        let session = fixture.session
        let plan = try await takes(fixture, Script(ratio: 1.1, failure: .invalidAudio))
        let take = try #require(plan.phrases[0].takes.first)
        #expect(!take.row.selectable && !plan.lengthFits(take: take) && session.durationCarries(take, plan: plan))
        let carried = try #require(session.stuckReason(plan.phrases[0], plan: plan))
        if case .length = carried { Issue.record("A take the matched speed carries is not too long: \(carried)") }
        let far = try phrase(fixture, plan, [Script(ratio: 1.4, failure: .invalidAudio)])
        let long = try #require(session.stuckReason(far, plan: plan))
        guard case .length(let tooLong, _, _, _, _, let selected) = long else { Issue.record("\(long)"); return }
        #expect(tooLong && !selected)
    }

    /// A take shorter than its slot with no failed check is never reworded longer (ADR-R42): unselected, it is fixed by
    /// what did fail; selected (it passed), its phrase keeps the recorded audio with one line and no click.
    @Test func aShortTakeIsNeverRewordedLonger() async throws {
        let fixture = try await fixture(); defer { fixture.close() }
        let session = fixture.session
        let plan = try await takes(fixture, Script(ratio: 0.7, failure: .invalidAudio))
        let failed = try #require(session.stuckReason(plan.phrases[0], plan: plan))
        if case .length = failed { Issue.record("A short take is never reworded longer: \(failed)") }

        // Passing, it is chosen and its phrase settles as recorded as the takes land (`settleTakesThatFitNoDuration`).
        let second = try await self.fixture()
        defer { second.close() }
        let passing = try await takes(second, Script(ratio: 0.7))
        let take = try #require(passing.phrases[0].takes.first)
        #expect(take.row.selectable && !second.session.durationCarries(take, plan: passing))
        #expect(passing.phrases[0].leftOut && second.session.autoFix.notes.contains(ClipTakePlan.noDurationCopy([1])),
            "\(second.session.autoFix.notes)")
        var chosen = passing.phrases[0]
        chosen.leftOut = false; chosen.selectedID = take.id
        #expect(second.session.stuckReason(chosen, plan: passing) == nil)
        #expect(second.session.wordingFit.measured == nil && second.backend.executions == 1)
    }

    /// End to end: the approved price arms the resolver, the only take skipped words, and the resolver makes one more
    /// take of the same words, which passes. No wording round runs and nothing longer is asked for.
    @Test func theResolverRetakesASkippedWordsTakeWithTheSameWords() async throws {
        let fixture = try await fixture(); defer { fixture.close() }
        let session = fixture.session, plan = try #require(session.takePlan)
        fixture.backend.scripts = [Script(ratio: 0.75, failures: [.transcript]), Script()]
        let action = try #require(session.pricedTakeAction(), "\(session.task.footer)")
        action.perform()
        if let confirm = session.task.confirm { confirm.confirm.perform() }
        #expect(session.autoFix.armed)
        await TestDeadline.until {
            if let task = session.takesTask { await task.value }
            if let work = session.autoFix.work { await work.value }
            return !session.takesBusy && session.autoFix.work == nil && session.wordingFit.measuredWork == nil
                && (fixture.backend.executions == 2 || !session.autoFix.running || !session.autoFix.gaveUp.isEmpty)
        }
        #expect(fixture.backend.executions == 2, "\(fixture.editor.announcements)")
        #expect(fixture.backend.inputs.allSatisfy { $0.text == plan.phrases[0].text })
        #expect(session.autoFix.triedAnother == [0] && session.autoFix.rounds[0] == 1 && session.autoFix.gaveUp.isEmpty)
        #expect(plan.phrases[0].selected?.number == 2 && plan.phrases[0].selected?.row.selectable == true)
        #expect(fixture.editor.announcements.contains("Fixing phrase 1: trying another take…"), "\(fixture.editor.announcements)")
        #expect(!fixture.editor.announcements.contains { $0.contains("longer wording") }, "\(fixture.editor.announcements)")
    }
}
#endif
