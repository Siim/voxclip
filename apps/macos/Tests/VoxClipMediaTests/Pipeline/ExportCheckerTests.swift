import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia
@testable import voxclip_cli

/// A local engine stand-in: it hears `words` (output seconds), and records the audio it was given.
final class StubHearing: Transcriber, Sendable {
    let engine: TranscriptEngine = .whispercpp
    let words: [ExportCheckInput.Heard]
    private let received = Mutex<[ExtractedAudio]>([])
    init(words: [ExportCheckInput.Heard]) { self.words = words }
    var heardAudio: [ExtractedAudio] { received.withLock { $0 } }
    func capabilities(model: String?) -> TranscriberCapabilities { TranscriberCapabilities(timing: .tokenGrouped, verbatim: false, autoLanguage: true, onDevice: true) }
    func supports(_ language: LanguageChoice, model: String?) async -> Bool { true }
    func readiness(for plan: TranscriptionPlan) async -> Readiness { .ready }
    func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript {
        received.withLock { $0.append(request.audio) }
        let tokens = words.map { RawToken(text: $0.text, start: $0.start, end: $0.end, conf: 0.9) }
        return RawTranscript(engine: EngineRef(id: .whispercpp, modelId: "stub", engineVersion: "stub"),
                             grouping: GroupingRule(end: .lastToken, conf: .mean, bracketEvents: true), tokens: tokens, language: "en",
                             verbatim: false, timing: .tokenGrouped)
    }
    static func hearing(_ words: [ExportCheckInput.Heard]) -> (StubHearing, ExportChecker.Hearing) {
        let stub = StubHearing(words: words)
        return (stub, ExportChecker.Hearing(transcriber: stub, plan: TranscriptionPlan(engine: .whispercpp, model: "stub", language: .forced("en"))))
    }
}

/// "We ship the clipper today, and it shows you." over 0.8–4.6 s of speech-bursts.mov (6 s, 16:9, speech-like bursts).
func checkerProject(source: URL) async throws -> Project {
    let texts = ["We", "ship", "the", "clipper", "today,", "and", "it", "shows", "you."]
    let words = texts.enumerated().map { index, text in
        TimedWord(id: "w\(index)", text: text, start: 0.8 + Double(index) * 0.42, end: 1.1 + Double(index) * 0.42)
    }
    let transcript = Transcript(words: words, language: "en", durationSeconds: 6, engine: EngineRef(id: .whispercpp, modelId: "stub", engineVersion: "fixture"),
                                rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    let probe = try await AVMediaProbe().probe(source)
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    return Project(id: UUID().uuidString.lowercased(), createdAt: Date(), modifiedAt: Date(), savedBy: ProjectWriter(version: "9.8.7"),
        media: ProjectMedia(source: MediaReference(absolutePath: source.path,
            sizeBytes: try #require((attributes[.size] as? NSNumber)?.int64Value), durationSeconds: probe.durationSeconds,
            contentKey: try JSONProjectStore.contentKey(for: source), video: probe.video, audio: probe.audio)),
        transcript: transcript, edits: ProjectEdits(cutWordIds: ["w2"], clips: [ClipRange(id: "clip-1", startWordId: "w0", endWordId: "w8")]))
}

/// The export self-check on real exported files (ADR-R49), with a stub engine in place of the local model.
extension HeavyMediaTests {
    /// The clip exported through the export command's own path, and the render it ran (`CLIWorkflow.prepare`).
    private func exported(_ directory: URL, extra: [String] = []) async throws -> (url: URL, prepared: CLIWorkflow.PreparedExport) {
        let source = try await NativeMediaFixtures.shared.file("speech-bursts.mov")
        let projectURL = directory.appendingPathComponent("check.voxclip")
        try await JSONProjectStore().save(try await checkerProject(source: source), to: projectURL)
        let output = directory.appendingPathComponent("clip.mp4")
        let arguments = ["--open", projectURL.path, "--export", output.path, "--clip", "clip-1", "--aspect", "16:9", "--style", "off", "--quiet"] + extra
        _ = try await CLIWorkflow.export(try Export.parse(arguments), input: projectURL.path)
        let prepared = try await CLIWorkflow.prepare(try Export.parse(arguments), input: projectURL.path, checkingOutputs: false)
        return (output, prepared)
    }

    @Test(.timeLimit(.minutes(2)))
    func theCheckerMeasuresARealExportAndComparesWhatItHears() async throws {
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (url, prepared) = try await exported(directory)
        let edit = try ExportCheckExpectation.edit(render: prepared.render, state: prepared.state)
        // The clip's words without the cut "the", in output time.
        #expect(edit.words.map(\.text) == ["We", "ship", "clipper", "today,", "and", "it", "shows", "you."])
        #expect(edit.cuts.count == 1)
        let (stub, hearing) = StubHearing.hearing(edit.words.map { ExportCheckInput.Heard(text: $0.text, start: $0.start, end: $0.end) })
        let outcome = try await ExportChecker(hearing: hearing, scratch: directory).check(export: url, render: prepared.render, edit: edit, loudness: .social)
        let report = outcome.report
        #expect(report.passed, "\(report)")
        #expect(report[.words]?.status == .ok && report[.words]?.matched == 8 && report[.words]?.total == 8)
        // Both tracks start together and end within a frame of each other in a real export.
        let sync = try #require(report[.sync])
        #expect(sync.status == .ok && abs(sync.startOffset ?? 1) <= 1 / 30.0 && abs(sync.endOffset ?? 1) <= 1 / 30.0, "\(sync)")
        // ADR-R47's social loudness, decoded from the AAC: -14 LUFS, at most -1 dBTP (plus the meter tolerance).
        let loudness = try #require(report[.loudness])
        #expect(loudness.status == .ok && abs((loudness.integratedLufs ?? 0) + 14) <= 1, "\(loudness)")
        #expect(report[.captions]?.status == .skipped)
        // The engine was handed the export's own audio, at 16 kHz, its length.
        let audio = try #require(stub.heardAudio.first)
        #expect(abs(audio.durationSeconds - edit.duration) < 0.1, "\(audio.durationSeconds) against \(edit.duration)")
        #expect(!FileManager.default.fileExists(atPath: audio.wav16k.path), "the 16 kHz copy is removed")
        #expect(outcome.engine == .whispercpp && outcome.model == "stub")

        // Heard wrong: "ship" as "chip" and the last word not at all: a mismatch, and a cut-off at the clip's edge.
        var wrong = edit.words.dropLast().map { ExportCheckInput.Heard(text: $0.text, start: $0.start, end: $0.end) }
        wrong[1].text = "chip"
        let (_, misheard) = StubHearing.hearing(wrong)
        let checked = try await ExportChecker(hearing: misheard, scratch: directory).check(export: url, render: prepared.render, edit: edit, loudness: .social)
        let words = try #require(checked.report[.words])
        #expect(words.status == .warning && !checked.report.passed)
        #expect(words.items.map(\.kind) == [.mismatch, .cutOff] && words.items.map(\.expected) == ["ship", "you."])
        #expect(words.items.first?.heard == "chip" && abs((words.items.first?.time ?? 0) - edit.words[1].start) < 1e-9)

        // Without a local engine the words are skipped, and with loudness off so is loudness.
        let unheard = try await ExportChecker(hearing: nil, scratch: directory).check(export: url, render: prepared.render, edit: edit, loudness: .off)
        #expect(unheard.report[.words]?.status == .skipped && unheard.report[.words]?.reason == "No local transcription model")
        #expect(unheard.report[.loudness]?.status == .skipped && unheard.report[.loudness]?.reason == "Loudness is off for this export")
        #expect(unheard.report.passed && unheard.hearSeconds == 0 && unheard.engine == nil)
    }

    /// A file whose audio runs half a second past its picture: the sync check measures it from the file, not the edit.
    @Test(.timeLimit(.minutes(1)))
    func aFileWhoseAudioOverhangsItsPictureFailsSync() async throws {
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await NativeMediaFixtures.shared.file("audio-overhang.mov")
        let render = RenderRequest(sourceURL: source, plan: EditPlan(sampleRate: 48_000, totalSamples: 96_000),
                                   output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 1_000_000))
        let edit = ExportCheckExpectation.Edit(words: [], phrases: [], cuts: [], duration: 2)
        let outcome = try await ExportChecker(hearing: nil, scratch: directory).check(export: source, render: render, edit: edit, loudness: .off)
        let sync = try #require(outcome.report[.sync])
        #expect(sync.status == .warning && sync.items.map(\.kind) == [.trackEnd], "\(sync)")
        #expect(abs((sync.endOffset ?? 0) - 0.5) < 0.05, "\(String(describing: sync.endOffset))")
    }
}

/// The check with the real local model, when one is installed: `VOXCLIP_TEST_WHISPER_MODELS` names a `Models` folder
/// holding whisper-large-v3-turbo (it is linked into a temporary data folder, never written). Skipped without it, so
/// hosted CI stays green.
@Suite(.offlineFixtures) struct ExportCheckerRealModelTests {
    static var models: URL? {
        guard let path = ProcessInfo.processInfo.environment["VOXCLIP_TEST_WHISPER_MODELS"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let model = url.appendingPathComponent("whispercpp/whisper-large-v3-turbo-q5_0/installed.json")
        return FileManager.default.fileExists(atPath: model.path) ? url : nil
    }

    /// LibriSpeech 1089-134686-0000 (shared/fixtures/voice-lab/speaker, the first six seconds) as the "export".
    @Test(.enabled(if: models != nil), .timeLimit(.minutes(2)))
    func theInstalledModelHearsEveryWordOfTheSpeechFixture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-check-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Models"), withDestinationURL: try #require(Self.models))
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])
        let shared = try SharedResources.locate()
        let transcript = Transcript(words: [], language: "en", durationSeconds: 6, engine: EngineRef(id: .elevenlabs, engineVersion: "fixture"),
                                    rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
        // A project transcribed by a provider is heard by the installed Whisper model instead, never the provider.
        let hearing = try #require(await ExportChecker.localHearing(transcript: transcript, locations: locations, shared: shared))
        #expect(hearing.plan.engine == .whispercpp && hearing.plan.model == "whisper-large-v3-turbo-q5_0" && hearing.plan.language == .forced("en"))
        let text = "He hoped there would be stew for dinner, turnips and carrots and bruised potatoes and fat mutton"
        let expected = text.split(separator: " ").enumerated().map { index, word in
            ExportCheckInput.Word(text: String(word), start: 0.3 + Double(index) * 0.33, end: 0.6 + Double(index) * 0.33)
        }
        let speech = try FixtureLoader.sharedRoot().appendingPathComponent("fixtures/voice-lab/speaker/1089-134686-0000-48000.wav")
        let render = RenderRequest(sourceURL: speech, plan: EditPlan(sampleRate: 48_000, totalSamples: 288_000),
                                   output: OutputSpec(size: PixelSize(width: 1080, height: 1920), fps: 30, videoBitrate: 4_000_000))
        let edit = ExportCheckExpectation.Edit(words: expected, phrases: [], cuts: [], duration: 6)
        let checker = ExportChecker(hearing: hearing, scratch: root)
        let cold = try await checker.check(export: speech, render: render, edit: edit, loudness: .off)
        let outcome = try await checker.check(export: speech, render: render, edit: edit, loudness: .off)
        let words = try #require(outcome.report[.words])
        print(String(format: "export-check real model: %d/%d words; first check %.3f s (hear %.3f s, the model loading); then measure %.3f s, hear %.3f s, total %.3f s",
                     words.matched ?? 0, words.total ?? 0, cold.totalSeconds, cold.hearSeconds, outcome.measureSeconds, outcome.hearSeconds, outcome.totalSeconds))
        #expect(words.status == .ok && words.matched == words.total && words.total == 17, "\(words)")
        #expect(outcome.engine == .whispercpp && outcome.totalSeconds < 5)
    }
}

/// A local engine whose model can't be read.
private struct FailingHearing: Transcriber {
    let engine: TranscriptEngine = .whispercpp
    func capabilities(model: String?) -> TranscriberCapabilities { TranscriberCapabilities(timing: .tokenGrouped, verbatim: false, autoLanguage: true, onDevice: true) }
    func supports(_ language: LanguageChoice, model: String?) async -> Bool { true }
    func readiness(for plan: TranscriptionPlan) async -> Readiness { .ready }
    func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript {
        throw VoxClipError.transcriptionFailed("Could not load the whisper model")
    }
}

extension HeavyMediaTests {
    /// An engine that fails leaves the words unchecked and the rest of the report standing.
    @Test(.timeLimit(.minutes(1)))
    func aFailingEngineSkipsTheWordsOnly() async throws {
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await NativeMediaFixtures.shared.file("speech-bursts.mov")
        let render = RenderRequest(sourceURL: source, plan: EditPlan(sampleRate: 48_000, totalSamples: 288_000),
                                   output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 1_000_000))
        let edit = ExportCheckExpectation.Edit(words: [ExportCheckInput.Word(text: "ship", start: 1, end: 1.3)], phrases: [], cuts: [], duration: 6)
        let hearing = ExportChecker.Hearing(transcriber: FailingHearing(), plan: TranscriptionPlan(engine: .whispercpp, model: "stub"))
        let outcome = try await ExportChecker(hearing: hearing, scratch: directory).check(export: source, render: render, edit: edit, loudness: .off)
        #expect(outcome.report[.words]?.status == .skipped && outcome.report[.words]?.reason == "The local transcription failed")
        #expect(outcome.report[.sync]?.status == .ok && outcome.engine == nil)
    }
}
