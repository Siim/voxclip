#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

private struct DurationHookKeys: KeyProvider {
    func key(for provider: String) async throws -> String? {
        Issue.record("Duration hook integration must not request credentials")
        return nil
    }
}

@Suite("Production duration hooks", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil), .offlineFixtures)
@MainActor struct DurationHookIntegrationTests {
    @MainActor private final class Backend {
        let record: VoiceConsentRecord
        let root: URL
        var changedFirst = true
        var preparations = 0
        var executions = 0
        var publications = 0
        var inputs: [VoiceLabTakeInput] = []
        var published: [UUID: VoiceLabPublishedTake] = [:]

        init(root: URL, record: VoiceConsentRecord) { self.root = root; self.record = record }

        func quote(seed: UInt32, modelID: String) -> VoiceLabTakeQuote {
            let estimate = CostEstimate(provider: "elevenlabs", operation: "test", units: 1, unit: "test", usd: 0.01, basis: "fixture")
            func request(_ operation: VoiceLabOperation) -> VoiceLabQuote {
                VoiceLabQuote(id: UUID(), operation: operation, requestID: UUID(), estimate: estimate, region: .default,
                    endpoint: operation == .speechToText ? "v1/speech-to-text" : modelID == "eleven_v4" ? "v1/text-to-dialogue/with-timestamps" : "v1/text-to-speech/\(record.voiceId)/with-timestamps",
                    languageMode: .explicit("en"), fingerprint: "fixture")
            }
            return VoiceLabTakeQuote(index: 0, seed: seed, synthesis: request(.textToSpeech), qa: request(.speechToText))
        }

        func row(input: VoiceLabTakeInput, quote: VoiceLabTakeQuote, changed: Bool) -> VoiceLabTakeRow {
            let window = input.window
            let sourceDuration = window.end - window.start
            let frames = Int64(EditingPrimitives.jsRound((sourceDuration + (changed ? 0.2 : 0)) * 24_000))
            let duration = Double(frames) / 24_000
            let tokens = input.text.split(separator: " ").map(String.init)
            let words = tokens.enumerated().map { index, text in
                VoiceLabWord(text: text, start: 0.1 + Double(index) * (duration - 0.2) / Double(tokens.count),
                    end: 0.1 + Double(index + 1) * (duration - 0.2) / Double(tokens.count), synthetic: true)
            }
            let fit = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0),
                outgoing: .init(padFrames: 0, borrowedSamples: 0), trimStartFrame: 2_400, trimEndFrame: frames + 2_400,
                windowStart: window.start, windowEnd: window.end, windowStartSample: window.startSample,
                windowEndSample: window.endSample, outputFrames: frames, words: words)
            let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [], mixed: [], patchRange: 0..<0, seams: [], gainDb: 0,
                roomTone: .init(sourceStartSample: 504_000, sourceEndSample: 528_000, gainDb: -30),
                fit: changed ? .changedDuration(fit, naturalOut: duration, residualSeconds: duration - sourceDuration) : .exact(fit))
            let receipt = VoiceLabReceipt(provider: "elevenlabs", region: .default, endpoint: quote.synthesis.endpoint,
                modelID: input.modelID, voiceID: record.voiceId, requestID: quote.synthesis.requestID,
                providerRequestID: nil, spendWarning: nil)
            let qa = VoiceLabTakeQAResult(values: .init(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -10, speakerScore: 0.95), failures: [])
            return VoiceLabTakeRow(id: quote.synthesis.requestID, index: 0, seed: quote.seed, receipt: receipt, audio: audio,
                qa: qa, score: 0.95, quote: quote, accepted: [quote.synthesis.requestID, quote.qa.requestID])
        }

        func publish(_ row: VoiceLabTakeRow, input: VoiceLabTakeInput, at date: Date) throws -> (VoiceLabPublishedTake, VoiceConsentRecord) {
            publications += 1
            if let saved = published[row.id] { return (saved, record) }
            let fit = try #require(row.audio?.fit.plan)
            let frames = Int(fit.outputFrames) + 4_800
            let samples = (0..<frames).map { Float(0.1 * sin(2 * Double.pi * 220 * Double($0) / 24_000)) }
            let wav = try VoiceTrainingAudio.wav(samples, rate: 24_000)
            let id = row.id.uuidString.lowercased()
            let file = try VoiceLabAssetNaming.file(projectId: projectID, assetId: id, extension: "wav")
            let path = root.appendingPathComponent("VoiceLab").appendingPathComponent(file)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wav.write(to: path, options: .withoutOverwriting)
            let asset = VoiceLabAsset(id: id, file: file, sha256: VoiceLabFingerprint.bytes(wav),
                durationSeconds: Double(frames) / 24_000, sampleRate: 24_000, createdAt: date)
            let audio = VoiceLabAudio(assetId: id, trimStart: 0.1, trimEnd: Double(fit.outputFrames + 2_400) / 24_000)
            let chunk = VoiceLabChunk(sourceStartSample: input.window.startSample, sourceEndSample: input.window.endSample,
                requestId: row.id.uuidString, seed: row.seed, assetId: id, assetSha256: asset.sha256,
                assembledStartFrame: 2_400, assembledEndFrame: fit.outputFrames + 2_400)
            let output = VoiceLabPublishedTake(assets: [asset], audio: audio, outDuration: Double(fit.outputFrames) / 24_000,
                words: fit.words, chunks: [chunk])
            published[row.id] = output
            return (output, record)
        }

        var projectID = ""

        func connected() -> ClipTakePlan.Backend {
            var backend = ClipTakePlan.Backend(runs: [])
            backend.prepare = { inputs, _, _ in
                self.preparations += 1
                self.inputs = inputs
                return try VoiceLabTakeBatch(windows: inputs.map { input in
                    .init(input: input, quote: .init(id: UUID(), takes: [self.quote(seed: input.seed, modelID: input.modelID)], preparedAt: Date()))
                })
            }
            backend.approve = { _, _ in }
            backend.execute = { batch, index, phrase, _ in
                self.executions += 1
                let window = batch.windows[index]
                let row = self.row(input: window.input, quote: try #require(window.quote.takes.first), changed: self.changedFirst && phrase == 0)
                return VoiceLabTakeRunResult(rows: [row], end: .completed)
            }
            backend.publish = { _, row, input, date in try self.publish(row, input: input, at: date) }
            backend.discard = {}; backend.invalidate = {}; backend.scratch = { _, _ in nil }; backend.retire = { _, _ in }
            return backend
        }
    }

    @MainActor private struct Fixture {
        let root: URL
        let editor: EditorModel
        let session: RewriteSession
        let backend: Backend
        func close() {
            editor.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture(clipped: Bool = false, passages: Int = 2) throws -> Fixture {
        _ = NSApplication.shared
        let shared = try SharedResources.locate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-duration-hooks-\(UUID().uuidString)")
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
        project.transcript?.words = (0..<100).map { index in
            let start = 0.1 + Double(index) * 0.1
            return TimedWord(id: "w\(index)", text: "x", start: start, end: start + 0.08,
                rawStart: start + 0.002, rawEnd: start + 0.078, conf: 0.99, speaker: "owner")
        }
        if clipped {
            let clip = ClipRange(id: "review-clip", startWordId: "w2", endWordId: "w95")
            project.edits.clips = [clip]; project.edits.activeClipId = clip.id
        }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        let envelope = AudioEnvelope(sampleRate: 48_000, levels: [Float](repeating: 0.01, count: 1_200))
        let session = RewriteSession(editor: editor, scope: clipped ? .clip("review-clip") : .fullTake,
            envelope: envelope, connector: nil)
        editor.rewrite = session
        func hunk(_ kind: VoiceLabDiffHunkKind, _ indices: ClosedRange<Int>, _ tokens: [String]) -> RewriteChange {
            RewriteChange(hunk: VoiceLabDiffHunk(kind: kind, sourceWordIds: indices.map { "w\($0)" }, newTokens: tokens,
                correctedTexts: kind == .textOnly ? tokens : [], absorbedItemIds: [], bridgeWordIds: [],
                sourceStartIndex: indices.lowerBound, sourceEndIndex: indices.upperBound + 1, anchorSeconds: nil))
        }
        let tokens = ["Carefully", "reviewed", "replacement", "stays", "natural"]
        var changes = [hunk(.cut, 5...5, []), hunk(.textOnly, 8...8, ["Reviewed"]), hunk(.voice, 15...46, tokens)]
        if passages == 2 { changes.append(hunk(.voice, 55...86, tokens)) }
        session.receive(changes); session.finishRun(seconds: 1); session.showProposal()
        for ordinal in session.blockedVoiceOrdinals { session.pricedAnyway.insert(ordinal) }
        session.showProposal()
        session.configureGeneration(client: ElevenLabsVoiceLab(keys: DurationHookKeys(), region: .default),
            store: VoiceConsentStore(locations: app.locations), speaker: .unavailable)
        let generation = try #require(session.generation)
        generation.showFixture("cost-confirmation", voice: record)
        let backend = Backend(root: root, record: record); backend.projectID = project.id
        session.takeBackend = { _, _ in backend.connected() }
        return Fixture(root: root, editor: editor, session: session, backend: backend)
    }

    private func preparedPlan(_ fixture: Fixture) async throws -> ClipTakePlan {
        await fixture.session.prepareTakes()
        let plan = try #require(fixture.session.takePlan)
        #expect(plan.prepareDurationRender != nil && fixture.session.generation?.prepareDurationRender != nil)
        #expect(plan.problem.isEmpty, Comment(rawValue: "\(plan.problem) cause: \(String(reflecting: plan.videoPreparationFailure))"))
        #expect(plan.approvalID != nil && fixture.backend.preparations == 1)
        await plan.start(approved: true)
        #expect(plan.problem.isEmpty, Comment(rawValue: "\(plan.problem) cause: \(String(reflecting: plan.videoPreparationFailure))"))
        #expect(plan.phrases.allSatisfy { $0.selected?.row.selectable == true && $0.videoChoice == nil })
        #expect(!plan.canAccept && fixture.backend.publications == 0)
        return plan
    }

    @Test(arguments: [false, true])
    func productionPlansPrepareExactStagedScopeAndCommitOneUndo(clipped: Bool) async throws {
        let fixture = try fixture(clipped: clipped); defer { fixture.close() }
        let editor = fixture.editor, session = fixture.session
        let original = editor.project
        let plan = try await preparedPlan(fixture)
        let selected = plan.phrases.map(\.selectedID), spent = plan.spent
        #expect(plan.phrases.count == 2 && plan.phrases[0].selected?.fits == false)
        #expect(!plan.chooseVideo(.source, phrase: 0))
        #expect(plan.chooseVideo(.retimed, phrase: 0) && !plan.canAccept)
        #expect(plan.chooseVideo(.source, phrase: 1) && !plan.canAccept)
        let factory = try #require(plan.prepareDurationRender)
        var requests: [RenderRequest] = []
        plan.prepareDurationRender = { proposed, scope in
            let request = try await factory(proposed, scope)
            requests.append(request)
            return request
        }
        await plan.prepareVideoChoices()
        #expect(plan.problem.isEmpty, Comment(rawValue: "\(plan.problem) cause: \(String(reflecting: plan.videoPreparationFailure))"))
        #expect(plan.canAccept && editor.project == original)
        let request = try #require(requests.first), input = try #require(request.voiceLab)
        #expect(input.project != original && input.project.edits.cutWordIds.contains("w5"))
        #expect(input.project.edits.cutWordIds.filter { $0 == "w5" }.count == 1)
        #expect(input.project.edits.corrections["w8"] == "Reviewed" && input.project.transcript == original.transcript)
        #expect(input.scope == session.scope && request.motionClipID == (clipped ? "review-clip" : nil))
        #expect(input.paidRoot == editor.app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true))
        #expect(request.sourceURL == URL(fileURLWithPath: original.media.source.absolutePath))
        #expect(request.sourceContentKey == original.media.source.contentKey && !request.forPreview)
        #expect(!request.plan.kept.contains { $0.startSample <= 30_000 && $0.endSample > 30_000 })
        #expect(input.prepared.selectedSegmentRecipes.map(\.recipe.video.mode) == [.zoomCover, .source])
        #expect(input.prepared.outputPlan.duration > request.plan.duration)
        #expect(input.prepared.selectedSegmentRecipes.allSatisfy { $0.recipe.audio.stretch == 1 })
        #expect(plan.phrases.map(\.selectedID) == selected && plan.spent == spent && fixture.backend.executions == 2)
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        undo.beginUndoGrouping()
        let accepted = await session.acceptTakes()
        undo.endUndoGrouping()
        #expect(accepted && requests.count == 2)
        let proposed = editor.project
        #expect(proposed.edits == input.project.edits)
        #expect(proposed.voiceLab.segments.count == 2 && proposed.transcript == original.transcript && proposed.media == original.media)
        #expect(proposed.edits.cutWordIds.contains("w5") && proposed.edits.corrections["w8"] == "Reviewed")
        #expect(editor.currentVoiceFeedback?.phrases.count == 2 && editor.currentVoiceFeedback?.spent == spent)
        #expect(editor.undoSteps == 1 && undo.canUndo)
        undo.undo()
        #expect(editor.project == original && !undo.canUndo && undo.canRedo)
        undo.redo()
        #expect(editor.project == proposed && !undo.canRedo)
        let chosen = try VoiceLabRenderContract.prepare(editor.project, scope: session.scope, labelPosition: .topRight)
        #expect(chosen.selectedSegmentRecipes.map(\.recipe.video.mode) == [.zoomCover, .source])
    }

    @Test func removedPaidAssetAfterReadinessCannotBeAcceptedOrCreateUndo() async throws {
        let fixture = try fixture(); defer { fixture.close() }
        let plan = try await preparedPlan(fixture), original = fixture.editor.project
        #expect(plan.chooseVideo(.retimed, phrase: 0) && plan.chooseVideo(.source, phrase: 1))
        await plan.prepareVideoChoices()
        #expect(plan.canAccept, Comment(rawValue: plan.problem))
        let asset = try #require(fixture.backend.published.values.first?.assets.first)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("VoiceLab").appendingPathComponent(asset.file))
        let undo = UndoManager(); undo.groupsByEvent = false; fixture.editor.undoManager = undo
        #expect(await fixture.session.acceptTakes() == false)
        #expect(fixture.editor.project == original && !undo.canUndo && fixture.editor.undoSteps == 0)
        #expect(fixture.editor.currentVoiceFeedback == nil && !fixture.session.problem.isEmpty)
        #expect(fixture.backend.executions == 2)
    }

    @Test func attachedSingleFactoryRejectsWrongSourceScopeAndStaleEditor() async throws {
        let fixture = try fixture(passages: 1); defer { fixture.close() }
        let factory = try #require(fixture.session.generation?.prepareDurationRender)
        let plan = try await preparedPlan(fixture)
        #expect(plan.phrases.count == 1 && plan.chooseVideo(.retimed, phrase: 0))
        var staged: Project?
        let planFactory = try #require(plan.prepareDurationRender)
        plan.prepareDurationRender = { proposed, scope in
            staged = proposed
            return try await planFactory(proposed, scope)
        }
        await plan.prepareVideoChoices()
        let proposed = try #require(staged)
        let request = try await factory(proposed, .full)
        #expect(request.voiceLab?.project == proposed && request.voiceLab?.scope == .full)
        var otherSource = proposed; otherSource.media.source.contentKey = String(repeating: "b", count: 64)
        await #expect(throws: VoiceLabProjectError.staleRenderContract) { try await factory(otherSource, .full) }
        await #expect(throws: VoiceLabProjectError.staleRenderContract) { try await factory(proposed, .clip("missing")) }
        var changed = fixture.editor.project; changed.edits.corrections["w9"] = "Newer editor edit"
        fixture.editor.document.replaceProject(changed)
        await #expect(throws: VoiceLabProjectError.staleRenderContract) { try await factory(proposed, .full) }
        #expect(fixture.backend.executions == 1 && fixture.editor.project == changed)
    }

    @Test func compatibilityGenerationUsesAttachedFactoryAndRebuildsBeforeOneUndo() async throws {
        let fixture = try fixture(passages: 1); defer { fixture.close() }
        let editor = fixture.editor, session = fixture.session, original = editor.project
        let generation = try #require(session.generation)
        let plan = try await preparedPlan(fixture)
        let row = try #require(plan.phrases.first?.selected?.row)
        let input = try #require(fixture.backend.inputs.first)
        generation.publishForTests = { row, input, date in try fixture.backend.publish(row, input: input, at: date) }
        generation.review(.init(rows: [row], end: .completed), input: input)
        #expect(generation.videoChoice == nil && !generation.readyToAccept && row.fits == false)
        #expect(generation.chooseVideo(.retimed) && !generation.readyToAccept)
        let factory = try #require(generation.prepareDurationRender)
        var calls = 0
        generation.prepareDurationRender = { proposed, scope in
            calls += 1
            return try await factory(proposed, scope)
        }
        await generation.prepareVideoChoice(into: editor, localCommands: session.localCommands)
        #expect(generation.readyToAccept && calls == 1, Comment(rawValue: generation.problem))
        #expect(editor.project == original && generation.selectedID == row.id)
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        undo.beginUndoGrouping()
        let accepted = await generation.accept(into: editor, localCommands: session.localCommands)
        undo.endUndoGrouping()
        #expect(accepted && calls == 2 && fixture.backend.executions == 1)
        let proposed = editor.project
        #expect(proposed.edits.cutWordIds.contains("w5") && proposed.edits.corrections["w8"] == "Reviewed")
        #expect(proposed.transcript == original.transcript && proposed.media == original.media && editor.undoSteps == 1)
        let recipe = try #require(proposed.voiceLab.segments.first?.candidates.first?.recipe)
        #expect(recipe.video.mode == .zoomCover && recipe.audio.stretch == 1)
        undo.undo()
        #expect(editor.project == original && !undo.canUndo)
        undo.redo()
        #expect(editor.project == proposed && !undo.canRedo)
    }
}
#endif
