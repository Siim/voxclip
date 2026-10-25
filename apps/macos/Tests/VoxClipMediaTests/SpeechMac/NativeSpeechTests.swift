import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

@Suite("Native speech adapters", .serialized)
struct NativeSpeechTests {
    @Test func whisperSplitUTF8AndGroupedTiming() throws {
        let pieces = [WhisperTokenPiece(bytes: Data([0x20, 0xc3]), start: 0.1, end: 0.2, confidence: 0.9), WhisperTokenPiece(bytes: Data([0xb5]), start: 0.2, end: 0.3, confidence: 0.8), WhisperTokenPiece(bytes: Data("htu".utf8), start: 0.3, end: 0.4, confidence: 1), WhisperTokenPiece(bytes: Data(" maailm".utf8), start: 0.7, end: 1, confidence: 0.9)]
        let tokens = WhisperTokenMapper.tokens(pieces, group: 3, offset: 10, duration: 2)
        #expect(tokens.count == 3)
        #expect(tokens[0].text == "õ" && tokens[0].start == 10.1)
        let words = try WordAssembler.group(tokens, rule: GroupingRule(end: .nextWordStart, conf: .mean, bracketEvents: true), timelineStart: 0.5)
        #expect(words.map(\.text) == ["õhtu", "maailm"])
        #expect(words[0].start == 10.6 && words[0].end == 11.2)
    }
    @Test func appleWhitespacePunctuationAndConfidence() throws {
        let runs = [AppleSpeechRun(text: "Hello", start: 0, end: 0.3, confidence: 0.9), AppleSpeechRun(text: ",", start: 0.3, end: 0.3, confidence: 0.8), AppleSpeechRun(text: " ", start: nil, end: nil, confidence: nil), AppleSpeechRun(text: "world", start: 0.5, end: 0.9, confidence: 0.7)]
        let tokens = AppleSpeechRunMapper.tokens(runs, language: "en-US", group: 1)
        let words = try WordAssembler.group(tokens, rule: GroupingRule(end: .lastToken, conf: .min, bracketEvents: false), timelineStart: 0)
        #expect(words.map(\.text) == ["Hello,", "world"])
        #expect(words[0].conf == 0.8)
        #expect(tokens[2].joinsPrevious == false)
    }
    @Test func appleCJKAndUnsupportedLanguages() async throws {
        let runs = [AppleSpeechRun(text: "你", start: 0, end: 0.3, confidence: 0.9), AppleSpeechRun(text: "好", start: 0.3, end: 0.6, confidence: 0.8), AppleSpeechRun(text: "。", start: 0.6, end: 0.6, confidence: 0.9)]
        let tokens = AppleSpeechRunMapper.tokens(runs, language: "zh-CN", group: 0)
        #expect(!tokens[1].joinsPrevious && tokens[2].joinsPrevious)
        let engine = AppleSpeechTranscriber()
        #expect(await !engine.supports(.forced("et"), model: nil))
        #expect(await !engine.supports(.auto, model: nil))
        do { _ = try await engine.cacheIdentity(for: TranscriptionPlan(engine: .appleSpeech, language: .forced("et"))); Issue.record("Expected unsupported language") }
        catch let error as VoxClipError { #expect(error.errorDescription == "Apple can't transcribe et.") }
    }
    @Test func whisperCatalogueSupportsAndReadiness() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = BundledModelCatalog(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let engine = WhisperCppTranscriber(catalog: catalog, locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let detectionRequest = TranscriptionRequest(plan: TranscriptionPlan(engine: .whispercpp, model: "taltech-et-verbatim-2604-q8_0", language: .auto), audio: ExtractedAudio(wav16k: root.appendingPathComponent("not-read.wav"), sampleCount: 16000, durationSeconds: 1), contentKey: "test-detection")
        do { _ = try await engine.detectLanguage(detectionRequest); Issue.record("TalTech must not detect language") }
        catch let error as VoxClipError { #expect(error.code == .transcriptionLanguageUnsupported) }
        #expect(await engine.supports(.forced("et"), model: "taltech-et-verbatim-2604-q8_0"))
        #expect(await !engine.supports(.forced("en"), model: "taltech-et-verbatim-2604-q8_0"))
        #expect(await !engine.supports(.auto, model: "whisper-base.en-q5_1"))
        #expect(await engine.supports(.auto, model: "whisper-large-v3-turbo-q5_0"))
        let readiness = await engine.readiness(for: TranscriptionPlan(engine: .whispercpp, model: "whisper-base.en-q5_1", language: .forced("en")))
        guard case .needsModels(let ids, let bytes) = readiness else { Issue.record("Expected missing models"); return }
        #expect(ids.contains("silero-vad-v6.2.0") && bytes > 59_000_000)
        var missingRequest = detectionRequest
        missingRequest.plan = TranscriptionPlan(engine: .whispercpp, model: "whisper-base.en-q5_1", language: .forced("en"))
        let model = try await catalog.model(id: "whisper-base.en-q5_1")
        do { _ = try await engine.transcribe(missingRequest) { _ in }; Issue.record("Expected missing model before reading audio") }
        catch let error as VoxClipError {
            #expect(error == .modelMissing(model.displayName, size: SpeechErrorCopy.bytes(Double(bytes))))
            #expect(error.errorDescription == "Download the \(model.displayName) model (\(SpeechErrorCopy.bytes(Double(bytes)))) to transcribe on this Mac.")
        }
    }
    @Test func nativeProgressIsThrottledAndWhisperSpecialsAreSkipped() async {
        let calls = Mutex(0)
        let reporter = SpeechProgressLimiter<Int> { _ in calls.withLock { $0 += 1 } }
        for index in 0..<1000 { reporter.report(index) }
        #expect(calls.withLock { $0 } == 1)
        await reporter.finish()
        #expect(calls.withLock { $0 } == 2)
        let pieces = [WhisperTokenPiece(bytes: Data("[_BEG_]".utf8), start: 0, end: 0, confidence: 1), WhisperTokenPiece(bytes: Data("<|en|>".utf8), start: 0, end: 0, confidence: 1), WhisperTokenPiece(bytes: Data(" word".utf8), start: 0.1, end: 0.3, confidence: 0.8)]
        let tokens = WhisperTokenMapper.tokens(pieces, group: 0, offset: 0, duration: 1)
        #expect(tokens.map(\.text) == ["word"])
        #expect(tokens.first?.joinsPrevious == false)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_LIVE_TESTS"] == "1" || ProcessInfo.processInfo.environment["VOXCLIP_TEST_DOWNLOAD"] == "1"))
    func liveWhisper() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = BundledModelCatalog(shared: SharedResources(root: try FixtureLoader.sharedRoot()))
        let locations = DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])
        let store = ModelStore(catalog: catalog, locations: locations, confirm: { _, _ in true })
        let model = "whisper-base.en-q5_1"
        try await store.install(id: model) { _ in }
        #expect(try await store.verify(id: model))
        let audio = try generatedAudio(root)
        let request = TranscriptionRequest(plan: TranscriptionPlan(engine: .whispercpp, model: model, language: .forced("en")), audio: audio, contentKey: "generated-speech")
        let engine = WhisperCppTranscriber(catalog: catalog, locations: locations)
        let raw = try await engine.transcribe(request) { _ in }
        let words = try SpeechEditingImportAdapter.cleanWords(WordAssembler.group(raw.tokens, rule: raw.grouping, timelineStart: 0), timing: raw.timing)
        #expect(words.count >= 5)
        #expect(words.allSatisfy { $0.start >= 0 && $0.end > $0.start })
        #expect(words.contains { $0.text.lowercased().hasPrefix("hello") })
        #expect(words.contains { $0.text.lowercased().hasPrefix("today") })
        #expect(words.contains { $0.text.lowercased().hasPrefix("um") })
        print("VOXCLIP_LIVE_WHISPER " + words.map { "\($0.text)=\(String(format: "%.3f", $0.start))-\(String(format: "%.3f", $0.end))" }.joined(separator: " "))
        let holder = Mutex<Task<RawTranscript, any Error>?>(nil)
        let cancelStart = Mutex<ContinuousClock.Instant?>(nil)
        let cancelled = Task {
            try await engine.transcribe(request) { _ in
                if let task = holder.withLock({ $0 }) {
                    cancelStart.withLock { if $0 == nil { $0 = .now } }
                    task.cancel()
                }
            }
        }
        holder.withLock { $0 = cancelled }
        do { _ = try await cancelled.value; Issue.record("Expected native whisper cancellation") }
        catch let error as VoxClipError { #expect(error.code == .cancelled) }
        let elapsed = try #require(cancelStart.withLock { $0 }).duration(to: .now)
        #expect(elapsed < .seconds(1))
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("VOXCLIP_WHISPER_CANCEL_SECONDS \(String(format: "%.3f", seconds))")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_LIVE_TESTS"] == "1" || ProcessInfo.processInfo.environment["VOXCLIP_TEST_APPLE_SPEECH"] == "1"))
    func liveAppleSpeech() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = try generatedAudio(root)
        let engine = AppleSpeechTranscriber(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        let request = TranscriptionRequest(plan: TranscriptionPlan(engine: .appleSpeech, language: .forced("en-US")), audio: audio, contentKey: "generated-speech")
        let raw = try await engine.transcribe(request) { _ in }
        let words = try SpeechEditingImportAdapter.cleanWords(WordAssembler.group(raw.tokens, rule: raw.grouping, timelineStart: 0), timing: raw.timing)
        #expect(words.count >= 5)
        #expect(raw.language == "en-US")
        #expect(words.allSatisfy { $0.start >= 0 && $0.end > $0.start })
        print("VOXCLIP_LIVE_APPLE " + words.map { "\($0.text)=\(String(format: "%.3f", $0.start))-\(String(format: "%.3f", $0.end))" }.joined(separator: " "))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_LIVE_TESTS"] == "1" && ProcessInfo.processInfo.environment["VOXCLIP_ELEVENLABS_API_KEY"] != nil))
    func liveElevenLabs() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = try generatedAudio(root)
        let engine = ElevenLabsTranscriber(keys: LiveSpeechKey(), session: URLSession(configuration: .ephemeral), catalog: BundledModelCatalog(shared: SharedResources(root: try FixtureLoader.sharedRoot())))
        let raw = try await engine.transcribe(TranscriptionRequest(plan: TranscriptionPlan(engine: .elevenlabs, language: .forced("en")), audio: audio, contentKey: "generated-speech")) { _ in }
        #expect(raw.language == "en")
        #expect(raw.tokens.contains { $0.text.lowercased().hasPrefix("um") })
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-native-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func generatedAudio(_ directory: URL) throws -> ExtractedAudio {
        let aiff = directory.appendingPathComponent("spoken.aiff"), wav = directory.appendingPathComponent("spoken.wav")
        try run("/usr/bin/say", ["-v", "Samantha", "-o", aiff.path, "Hello, um, today we cut videos by words. Let me show you."])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        let file = try AVAudioFile(forReading: wav)
        return ExtractedAudio(wav16k: wav, sampleCount: file.length, durationSeconds: Double(file.length) / file.processingFormat.sampleRate)
    }
    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw VoxClipError.transcriptionFailed("Synthetic speech generation") }
    }
}

private struct LiveSpeechKey: KeyProvider {
    func key(for provider: String) async throws -> String? { ProcessInfo.processInfo.environment["VOXCLIP_ELEVENLABS_API_KEY"] }
}
