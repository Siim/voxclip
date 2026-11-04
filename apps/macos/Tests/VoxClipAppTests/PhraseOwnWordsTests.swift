#if DEBUG
import AppKit
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import VoxClip

private struct OwnWordsKeys: KeyProvider {
    func key(for provider: String) async throws -> String? {
        Issue.record("Own words must not request credentials")
        return nil
    }
}
private struct NoOwnWordsProviderKeys: ProviderKeyStore {
    func hasKey(for provider: String) async -> Bool { false }
    func save(_ value: String, for provider: String) async throws { Issue.record("Own words must not save keys") }
}

/// Rewrite phrase cards' My words and Say it myself (design.md §6.3, voice-lab.md §8.13), on the production session and
/// plan with a scripted take backend, scripted microphone and scripted recognizer: no live provider, mic or speaker.
@Suite("Phrase own words and own takes", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil),
       .offlineFixtures, .timeLimit(.minutes(2)))
@MainActor struct PhraseOwnWordsTests {
    @MainActor private final class Backend {
        let record: VoiceConsentRecord
        let root: URL
        var projectID = ""
        var inputs: [VoiceLabTakeInput] = []
        var executions = 0
        var failWords = false
        init(root: URL, record: VoiceConsentRecord) { self.root = root; self.record = record }

        func quote(seed: UInt32, modelID: String) -> VoiceLabTakeQuote {
            let estimate = CostEstimate(provider: "elevenlabs", operation: "test", units: 1, unit: "test", usd: 0.01, basis: "fixture")
            func request(_ operation: VoiceLabOperation) -> VoiceLabQuote {
                VoiceLabQuote(id: UUID(), operation: operation, requestID: UUID(), estimate: estimate, region: .default,
                    endpoint: operation == .speechToText ? "v1/speech-to-text" : "v1/text-to-dialogue/with-timestamps",
                    languageMode: .explicit("en"), fingerprint: "fixture")
            }
            return VoiceLabTakeQuote(index: 0, seed: seed, synthesis: request(.textToSpeech), qa: request(.speechToText))
        }
        func row(input: VoiceLabTakeInput, quote: VoiceLabTakeQuote) -> VoiceLabTakeRow {
            if failWords {
                return VoiceLabTakeRow(id: quote.synthesis.requestID, index: 0, seed: quote.seed,
                    qa: VoiceLabTakeQAResult(values: .init(transcriptMatch: 0.2, lufsJumpLu: 0, peakDbfs: -10, speakerScore: 0.9), failures: [.transcript]),
                    failure: .qa([.transcript]), quote: quote, accepted: [quote.synthesis.requestID, quote.qa.requestID])
            }
            let window = input.window
            let frames = Int64(EditingPrimitives.jsRound((window.end - window.start) * 24_000))
            let duration = Double(frames) / 24_000
            let tokens = input.text.split(separator: " ").map(String.init)
            let words = tokens.enumerated().map { index, text in
                VoiceLabWord(text: text, start: 0.1 + Double(index) * (duration - 0.2) / Double(tokens.count),
                    end: 0.1 + Double(index + 1) * (duration - 0.2) / Double(tokens.count), synthetic: true)
            }
            let fit = VoiceLabFitPlan(edits: [], incoming: .init(padFrames: 0, borrowedSamples: 0), outgoing: .init(padFrames: 0, borrowedSamples: 0),
                trimStartFrame: 2_400, trimEndFrame: frames + 2_400, windowStart: window.start, windowEnd: window.end,
                windowStartSample: window.startSample, windowEndSample: window.endSample, outputFrames: frames, words: words)
            let audio = VoiceLabTakeAudio(sampleRate: 24_000, trimmed: [], mixed: [], patchRange: 0..<0, seams: [], gainDb: 0,
                roomTone: .init(sourceStartSample: 504_000, sourceEndSample: 528_000, gainDb: -30), fit: .exact(fit))
            let receipt = VoiceLabReceipt(provider: "elevenlabs", region: .default, endpoint: quote.synthesis.endpoint,
                modelID: input.modelID, voiceID: record.voiceId, requestID: quote.synthesis.requestID, providerRequestID: nil, spendWarning: nil)
            return VoiceLabTakeRow(id: quote.synthesis.requestID, index: 0, seed: quote.seed, receipt: receipt, audio: audio,
                qa: VoiceLabTakeQAResult(values: .init(transcriptMatch: 1, lufsJumpLu: 0, peakDbfs: -10, speakerScore: 0.95), failures: []),
                score: 0.95, quote: quote, accepted: [quote.synthesis.requestID, quote.qa.requestID])
        }
        func connected() -> ClipTakePlan.Backend {
            var backend = ClipTakePlan.Backend(runs: [])
            backend.prepare = { inputs, _, _ in
                self.inputs = inputs
                return try VoiceLabTakeBatch(windows: inputs.map { input in
                    .init(input: input, quote: .init(id: UUID(), takes: [self.quote(seed: input.seed, modelID: input.modelID)], preparedAt: Date()))
                })
            }
            backend.approve = { _, _ in }
            backend.execute = { batch, index, _, _ in
                self.executions += 1
                let window = batch.windows[index]
                return VoiceLabTakeRunResult(rows: [self.row(input: window.input, quote: try #require(window.quote.takes.first))], end: .completed)
            }
            backend.publish = { _, _, _, _ in
                Issue.record("Only the user's own take is used here")
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
        let record: VoiceConsentRecord
        func close() { editor.close(); try? FileManager.default.removeItem(at: root) }
    }

    private static let tokens = ["Carefully", "reviewed", "replacement", "stays", "natural"]

    private func fixture(passages: Int = 1) async throws -> Fixture {
        _ = NSApplication.shared
        let shared = try SharedResources.locate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-own-words-\(UUID().uuidString)")
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
        // Words stop at 9.1 s: the rest of the take is the room, where a take's room tone comes from.
        project.transcript?.words = (0..<90).map { index in
            let start = 0.1 + Double(index) * 0.1
            return TimedWord(id: "w\(index)", text: "x", start: start, end: start + 0.08,
                rawStart: start + 0.002, rawEnd: start + 0.078, conf: 0.99, speaker: "owner")
        }
        let app = AppModel(settingsStore: RegressionSettingsStore(), locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        app.providerKeyStoreOverride = NoOwnWordsProviderKeys()
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.betaNoticeAccepted"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(true)
        let editor = EditorModel(document: VoxClipDocument(project: project, demo: true), app: app, preview: DemoPreviewEngine())
        let envelope = AudioEnvelope(sampleRate: 48_000, levels: [Float](repeating: 0.01, count: 1_200))
        let session = RewriteSession(editor: editor, scope: .fullTake, envelope: envelope, connector: nil)
        editor.rewrite = session
        func voice(_ indices: ClosedRange<Int>) -> RewriteChange {
            RewriteChange(hunk: VoiceLabDiffHunk(kind: .voice, sourceWordIds: indices.map { "w\($0)" }, newTokens: Self.tokens,
                correctedTexts: [], absorbedItemIds: [], bridgeWordIds: [], sourceStartIndex: indices.lowerBound,
                sourceEndIndex: indices.upperBound + 1, anchorSeconds: nil))
        }
        session.receive(passages == 2 ? [voice(15...46), voice(55...86)] : [voice(15...46)])
        session.finishRun(seconds: 1); session.showProposal()
        for ordinal in session.blockedVoiceOrdinals { session.pricedAnyway.insert(ordinal) }
        session.showProposal()
        session.configureGeneration(client: ElevenLabsVoiceLab(keys: OwnWordsKeys(), region: .default),
            store: VoiceConsentStore(locations: app.locations), speaker: .unavailable)
        try #require(session.generation).showFixture("cost-confirmation", voice: record)
        let backend = Backend(root: root, record: record); backend.projectID = project.id
        session.takeBackend = { _, _ in backend.connected() }
        await session.prepareTakes()
        let plan = try #require(session.takePlan)
        #expect(plan.inputs.count == passages && plan.microphoneStorage != nil, Comment(rawValue: plan.problem))
        return Fixture(root: root, editor: editor, session: session, backend: backend, record: record)
    }

    /// Records the scripted take for phrase 0 and returns it as listed.
    private func recordOwnTake(_ fixture: Fixture, speechSeconds: Double? = nil) async throws -> ClipTakePlan.Take {
        let session = fixture.session, plan = try #require(session.takePlan)
        let window = plan.phrases[0].window
        session.useScriptedMicrophone(words: Self.tokens, speechSeconds: speechSeconds ?? (window.end - window.start - 0.25))
        session.chooseWording(.microphone, phrase: 0)
        await session.phraseMicrophone.record(phrase: 0, plan: plan)
        #expect(session.phraseMicrophone.recording, Comment(rawValue: session.phraseMicrophone.problem))
        await session.phraseMicrophone.stop()
        #expect(session.phraseMicrophone.problem.isEmpty, Comment(rawValue: session.phraseMicrophone.problem))
        return try #require(plan.phrases[0].takes.last { $0.source == .microphone })
    }


    // MARK: A · My words

    @Test func ownWordsAreWhatTheClonedVoiceReadsAndTheWordCheckExpects() async throws {
        let fixture = try await fixture(); defer { fixture.close() }
        let session = fixture.session, plan = try #require(session.takePlan)
        session.chooseWording(.ownWords, phrase: 0)
        #expect(plan.phrases[0].wording == .ownWords && plan.phrases[0].ownWords == PhraseWording.change(of: plan.phrases[0]))
        #expect(session.ownWordsEditing == 0)
        session.editOwnWords("Every take stays my own", phrase: 0)
        let text = try #require(session.ownWordsText(plan.phrases[0]))
        let bridges = session.bridgeWords(plan.phrases[0])
        #expect(text == (bridges.left + ["Every", "take", "stays", "my", "own"] + bridges.right).joined(separator: " "))
        let fit = try #require(session.ownWordsFit(plan.phrases[0]))
        #expect(fit.line.hasPrefix("Your voice reads this. \(EditingPrimitives.splitWords(text).count) words · about "))
        #expect(fit.line.contains("the gap is \(String(format: "%.1f", plan.phrases[0].originalLength)) s"))
        await session.priceOwnWords(phrase: 0)
        #expect(plan.quotedText(phrase: 0) == text && fixture.backend.inputs.map(\.text) == [text])
        let action = try #require(session.ownWordsTakeAction(phrase: 0))
        #expect(action.title.hasPrefix("Make take") && action.priced)
        // Typing again drops the unpaid quote: [Make take] can only voice the words in the field.
        session.editOwnWords("Every take stays mine", phrase: 0)
        #expect(plan.approvalID == nil && session.ownWordsTakeAction(phrase: 0) == nil)
        await session.priceOwnWords(phrase: 0)
        let final = try #require(session.ownWordsText(plan.phrases[0]))
        #expect(plan.quotedText(phrase: 0) == final)
        await plan.start(approved: true)
        let take = try #require(plan.phrases[0].takes.last)
        #expect(plan.measuredInput(take: take.id)?.text == final)
        // The word check expects the user's words: they pass, the suggestion's words fail.
        let mixed = (0..<24_000).map { Float(0.05 * sin(2 * Double.pi * 200 * Double($0) / 24_000)) }
        let own = try VoiceLabTakeQuality.evaluate(expected: final, recognized: EditingPrimitives.splitWords(final), mixed: mixed,
            sampleRate: 24_000, seams: [], speakerScore: nil, threshold: 0.5)
        let suggested = try VoiceLabTakeQuality.evaluate(expected: final, recognized: Self.tokens, mixed: mixed,
            sampleRate: 24_000, seams: [], speakerScore: nil, threshold: 0.5)
        #expect(own.passed && suggested.failures.contains(.transcript))
        // Switching back to Suggested keeps the take; typing never drops a paid take.
        session.chooseWording(.suggested, phrase: 0)
        session.chooseWording(.ownWords, phrase: 0)
        session.editOwnWords("Something else", phrase: 0)
        #expect(plan.phrases[0].takes.contains { $0.id == take.id } && plan.phrases[0].ownWords == "Something else")
    }

    @Test func theResolverNeverRewritesOwnWordsOrOwnTakes() async throws {
        let fixture = try await fixture(passages: 2); defer { fixture.close() }
        let session = fixture.session, plan = try #require(session.takePlan)
        session.armAutoFix(plan)
        plan.showFixture("none-passed")
        session.chooseWording(.ownWords, phrase: 0)
        session.chooseWording(.microphone, phrase: 1)
        let words = plan.phrases.map(\.text)
        session.advanceAutoFix()
        #expect(session.autoFix.work == nil && session.autoFix.rounds.isEmpty && session.autoFix.lines.isEmpty)
        #expect(plan.phrases.map(\.text) == words && session.wordingFit.measured == nil)
        // A suggested phrase in the same state is fixed: the skip is the user's words, not the state.
        session.chooseWording(.suggested, phrase: 1)
        session.advanceAutoFix()
        #expect(session.autoFix.rounds[1] == 1 && session.autoFix.rounds[0] == nil)
        session.stopAutoFix()
    }

    // MARK: B · Say it myself

    @Test func ownTakeIsTranscribedTrimmedMatchedInLoudnessAndFitted() async throws {
        let fixture = try await fixture(); defer { fixture.close() }
        let take = try await recordOwnTake(fixture)
        let plan = try #require(fixture.session.takePlan)
        let own = try #require(plan.microphoneTake(take.id))
        #expect(own.text == Self.tokens.joined(separator: " ") && own.words.map(\.text) == Self.tokens)
        #expect(own.words.first.map { abs($0.start - ScriptedOwnTake.lead) < 0.001 } == true)
        #expect(own.model == "scripted-speech" && take.row.receipt == nil && take.row.quote == nil && take.row.acceptedRequestIDs.isEmpty)
        #expect(take.row.selectable && take.row.qa?.values.transcriptMatch == 1 && take.row.qa?.values.speakerScore == nil)
        let audio = try #require(take.row.audio)
        // Trimmed to the speech: the quiet lead and tail are gone.
        let trimmed = Double(audio.trimmed.count) / Double(audio.sampleRate)
        #expect(trimmed < own.recordedSeconds - ScriptedOwnTake.lead, Comment(rawValue: "trimmed \(trimmed) of \(own.recordedSeconds)"))
        // Quieter than the source by about 12 dB: its level is raised to match.
        #expect(audio.gainDb > 6, Comment(rawValue: "gain \(audio.gainDb)"))
        #expect(plan.durationAvailable(take: take), Comment(rawValue: "\(audio.fit)"))
        // Listed in the one take list, free, and never chosen automatically: the user clicks Use your take.
        #expect(plan.phrases[0].selectedID == nil && plan.phrases[0].takes.count == 1)
        #expect(PhraseMicrophoneRow.line(take, words: own.text, slot: plan.phrases[0].originalLength, fits: plan.lengthFits(take: take),
            carried: plan.durationAvailable(take: take))
            .hasPrefix("Your take · “Carefully reviewed replacement stays natural” · "))
    }

    @Test func recordAgainReplacesAnUnusedTakeAndAMisfitSaysItsLength() async throws {
        let fixture = try await fixture(); defer { fixture.close() }
        let plan = try #require(fixture.session.takePlan)
        let slot = plan.phrases[0].originalLength
        let long = try await recordOwnTake(fixture, speechSeconds: slot * 2.2)
        let line = PhraseMicrophoneRow.line(long, words: "w", slot: slot, fits: plan.lengthFits(take: long), carried: plan.durationAvailable(take: long))
        #expect(!plan.durationAvailable(take: long) && line.contains("too long to fit"), Comment(rawValue: line))
        let fitting = try await recordOwnTake(fixture)
        #expect(plan.phrases[0].takes.count == 1 && fitting.id != long.id && fitting.number == long.number)
        #expect(plan.microphoneTake(long.id) == nil && plan.durationAvailable(take: fitting))
    }

    @Test(arguments: [MicrophoneAccess.denied, .noMicrophone])
    func blockedMicrophoneShowsHowToRecordAndNeverStarts(access: MicrophoneAccess) async throws {
        let fixture = try await fixture(); defer { fixture.close() }
        let session = fixture.session, plan = try #require(session.takePlan)
        session.useScriptedMicrophone(words: Self.tokens, speechSeconds: 1, access: access)
        await session.phraseMicrophone.record(phrase: 0, plan: plan)
        let microphone = try #require(session.phraseMicrophone.microphone as? ScriptedPhraseMicrophone)
        #expect(microphone.starts == 0 && session.phraseMicrophone.state == .idle)
        #expect(session.phraseMicrophone.problem == (access == .denied ? PhraseMicrophoneCopy.denied : PhraseMicrophoneCopy.noMicrophone))
        // A permission the system refuses at start says the same, inline.
        session.useScriptedMicrophone(words: Self.tokens, speechSeconds: 1)
        let refusing = try #require(session.phraseMicrophone.microphone as? ScriptedPhraseMicrophone)
        refusing.startError = MicrophoneError.permission
        await session.phraseMicrophone.record(phrase: 0, plan: plan)
        #expect(session.phraseMicrophone.problem == PhraseMicrophoneCopy.denied && plan.phrases[0].takes.isEmpty)
    }

    @Test func noWordsHeardKeepsNoTake() async throws {
        let fixture = try await fixture(); defer { fixture.close() }
        let session = fixture.session, plan = try #require(session.takePlan)
        session.useScriptedMicrophone(words: Self.tokens, speechSeconds: 2)
        session.phraseMicrophone.transcriber = ScriptedTakeTranscriber(heard: [])
        await session.phraseMicrophone.record(phrase: 0, plan: plan)
        await session.phraseMicrophone.stop()
        #expect(session.phraseMicrophone.problem == PhraseMicrophoneCopy.copy(MicrophoneTakeError.noSpeech) && plan.phrases[0].takes.isEmpty)
    }

    @Test func autoStopAtTheGapPlusOneAndAHalfSeconds() async throws {
        let fixture = try await fixture(); defer { fixture.close() }
        let session = fixture.session, plan = try #require(session.takePlan)
        session.useScriptedMicrophone(words: Self.tokens, speechSeconds: 2)
        await session.phraseMicrophone.record(phrase: 0, plan: plan)
        #expect(await session.phraseMicrophone.tick() == false && session.phraseMicrophone.levels.count == 1)
        // The cue was the count-in: no headphones.
        #expect((session.phraseMicrophone.cue as? SilentPhraseCue)?.played == [.countIn])
        #expect(PhraseMicrophoneTake.limit(for: plan.phrases[0]) == plan.phrases[0].originalLength + 1.5)
    }

    @Test func ownTakeIsUsedExportedWithUndoAndLipSyncCanChooseIt() async throws {
        let fixture = try await fixture(); defer { fixture.close() }
        let session = fixture.session, editor = fixture.editor, plan = try #require(session.takePlan)
        let original = editor.project
        let take = try await recordOwnTake(fixture)
        // A join to listen to first is used with Use anyway, as for a cloned take.
        #expect(take.row.requiresJoinAdvisoryAcceptance ? plan.useAnyway(take: take.id, phrase: 0) : plan.select(take: take.id, phrase: 0))
        #expect(plan.phrases[0].text == Self.tokens.joined(separator: " ") && plan.phrases[0].takeDetail.hasPrefix("Your take · "),
            Comment(rawValue: plan.phrases[0].takeDetail))
        #expect(take.row.audio?.roomTone != nil, "the fixture's room gives the take its room tone")
        let choice = try #require(plan.validVideoChoices(phrase: 0).first)
        #expect(plan.chooseVideo(choice, phrase: 0))
        await plan.prepareVideoChoices()
        #expect(plan.canAccept, Comment(rawValue: "\(plan.problem) \(String(reflecting: plan.videoPreparationFailure))"))
        // Lip sync offers the user's own take, under the plan's own voice consent, as for a cloned take.
        let (offers, all) = try await plan.makeLipsyncOffers()
        let offer = try #require(offers[0])
        #expect(offer.recordID == fixture.record.id && all != nil && offer.windows.flatMap(\.source.phraseIDs) == [0])
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        undo.beginUndoGrouping()
        let accepted = await session.acceptTakes()
        undo.endUndoGrouping()
        #expect(accepted, Comment(rawValue: session.problem))
        let used = editor.project
        let segment = try #require(used.voiceLab.segments.first)
        let recipe = try #require(segment.candidates[segment.selectedCandidateIndex].recipe)
        #expect(segment.kind == .recorded && segment.text?.new == Self.tokens.joined(separator: " "))
        #expect(segment.words?.map(\.text) == Self.tokens && segment.words?.allSatisfy { !$0.synthetic } == true)
        #expect(VoiceLabRecordedTake.isRecorded(recipe.provenance) && recipe.voiceRefId == nil && recipe.consentVerifiedAt == nil)
        #expect(recipe.cost.usd == 0 && used.voiceLab.voices == original.voiceLab.voices, "no voice reference is added")
        // Export: the render contract renders it, labels nothing as AI and captions say the recognized words.
        let prepared = try VoiceLabRenderContract.prepare(used, scope: .full, labelPosition: .topRight)
        #expect(prepared.selectedSegmentRecipes.count == 1 && !prepared.disclosure.required && prepared.disclosure.kinds.isEmpty)
        #expect(Self.tokens.allSatisfy { word in prepared.outputPlan.captions.contains { $0.text == word } })
        // Nothing in the editor labels the user's own speech as AI.
        #expect(!editor.containsAISpeech() && segment.hasAISpeech == false && segment.isAIModified == false)
        let encoded = try JSONProjectStore.encode(used)
        #expect(try JSONProjectStore.encode(JSONProjectStore.decode(encoded)) == encoded)
        #expect(editor.undoSteps == 1 && undo.canUndo)
        undo.undo()
        #expect(editor.project == original && undo.canRedo)
        undo.redo()
        #expect(editor.project == used)
        #expect(fixture.backend.executions == 0)
    }
}
#endif
