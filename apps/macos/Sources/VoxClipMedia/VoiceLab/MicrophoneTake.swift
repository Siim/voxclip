import Foundation
import VoxClipCore

/// Hears the words of a microphone take on this Mac, with their timing from the start of the recording.
public protocol MicrophoneTakeTranscribing: Sendable {
    /// `samples` are mono 16 kHz. Returns the recognizer's model name with the words; no words means no speech.
    func words(_ samples: [Float], language: String) async throws -> (model: String, words: [VoiceLabSpokenWord])
}

public enum MicrophoneTakeError: Error, Equatable {
    /// The recognizer heard no words.
    case noSpeech
    /// No on-device recognizer is ready for the project's language.
    case transcriptionUnavailable
}

/// A phrase's microphone take, checked on this Mac (design.md §6.3 "Say it myself", voice-lab.md §8.13).
public struct MicrophoneTake: Sendable {
    public let row: VoiceLabTakeRow
    public let scratch: VoiceLabTakeScratch
    /// The phrase's input with the recognized words as its text: what the take says.
    public let input: VoiceLabTakeInput
    public let words: [VoiceLabSpokenWord]
    /// The recognizer that heard the words, recorded in the take's provenance.
    public let model: String
    public let recordedSeconds: Double
    public var text: String { input.text }
}

/// Makes a microphone take from the user's recording: the recognizer gives its words and timings, the take is trimmed
/// to the speech, its loudness is matched to the source beside the window, and it is fitted and joined as a generated
/// take is, with the word, clipping and join checks. Nothing leaves the Mac: the recording is written to the project's
/// Voice Lab asset folder only.
public enum MicrophoneTakeMaker {
    public static let recordingRate = 48_000

    public static func make(samples: [Float], sampleRate: Int = recordingRate, input: VoiceLabTakeInput,
                            transcriber: any MicrophoneTakeTranscribing, storage: VoiceLabTakeStorage,
                            id: UUID = UUID(), at date: Date = Date()) async throws -> MicrophoneTake {
        guard sampleRate > 0, !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw VoiceLabError.invalidAudio }
        let clamped = samples.map { max(-1, min(1, $0)) }
        let heard = try await transcriber.words(VoiceConsentAudio.resample(clamped, rate: sampleRate), language: input.language)
        let words = heard.words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.end > $0.start }
        guard !words.isEmpty else { throw MicrophoneTakeError.noSpeech }
        let text = words.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
        var spoken = VoiceLabTakeInput(text: text, modelID: input.modelID, recordID: input.recordID, language: input.language,
            seed: 0, contentKey: input.contentKey, source: input.source, sourceEnvelope: input.sourceEnvelope,
            sourceSampleRate: input.sourceSampleRate, items: input.items, cutWordIDs: input.cutWordIDs, window: input.window,
            incomingSilence: input.incomingSilence, outgoingSilence: input.outgoingSilence, cleanAudioOn: input.cleanAudioOn,
            providerConsent: input.providerConsent, pace: nil, hardJoinSmoothing: input.hardJoinSmoothing, audioTags: [])
        spoken.pauseProfile = input.pauseProfile
        let assetRate = 24_000
        let audio = try VoiceLabSourceAudio.resample(clamped, from: Double(sampleRate), to: Double(assetRate)).map { max(-1, min(1, $0)) }
        let timed = words.map { VoiceLabSpokenWord(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
            start: min($0.start, Double(audio.count) / Double(assetRate)), end: min($0.end, Double(audio.count) / Double(assetRate))) }
        var pcm = Data(capacity: audio.count * 2)
        for sample in audio {
            let value = Int16(max(-32_768, min(32_767, (Double(sample) * 32_767).rounded())))
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let receipt = VoiceLabReceipt(provider: VoiceLabRecordedTake.provider, region: .default, endpoint: VoiceLabRecordedTake.endpoint,
            modelID: nil, voiceID: nil, requestID: id, providerRequestID: nil, spendWarning: nil)
        let result = VoiceLabAudioResult(pcm: pcm, sampleRate: assetRate, alignment: VoiceLabRecordedTake.alignment(timed), receipt: receipt)
        // The room tone and source level come from the phrase as planned; the take itself says the recognized words.
        let preflight = try VoiceLabTakeProcessing.preflight(input)
        let analysis = try VoiceLabTakeProcessing.process(result, input: spoken, preflight: preflight)
        let asset = try VoiceLabAssetStore.write(pcm16: pcm, sampleRate: assetRate, projectId: storage.projectId,
            assetId: UUID().uuidString.lowercased(), paidRoot: storage.paidRoot, createdAt: date)
        let snapshot = try VoiceLabAssets.preparePaid(asset: asset, projectId: storage.projectId, paidRoot: storage.paidRoot,
            scratchRoot: storage.scratchRoot)
        let fitted = try VoiceLabSilenceFit.prepare(snapshot: snapshot, paidAsset: asset, fit: analysis.fit,
            window: spoken.window, sourceSampleRate: spoken.sourceSampleRate)
        let source = try VoiceLabSourceAudio.resample(spoken.source, from: Double(spoken.sourceSampleRate), to: Double(assetRate))
        let scratch = try VoiceLabAudioRenderer.stageTake(fitted: fitted, analysis: analysis, input: spoken,
            sourceAtAssetRate: source, scratchRoot: storage.scratchRoot)
        let processed = scratch.audio
        // The words are what was said, so the word check passes by construction; clipping and the joins are measured.
        let qa = try VoiceLabTakeQuality.evaluate(expected: text, recognized: timed.map(\.text), mixed: processed.mixed,
            sampleRate: processed.sampleRate, seams: processed.seams, sourceSeamSteps: processed.sourceSeamSteps,
            sourceSeamPauses: processed.sourceSeamPauses, generatedAfter: processed.generatedAfter,
            measuredSeamSteps: processed.measuredSeamSteps, measuredPauseExcesses: processed.measuredPauseExcesses,
            speakerScore: nil, threshold: 0)
        let flatness = try VoiceLabLoudness.flatness(processed.trimmed, sampleRate: processed.sampleRate)
        let rank = try VoiceLabTakeQuality.rank(fit: processed.fit, windowSeconds: spoken.window.end - spoken.window.start,
            matchRatio: qa.values.transcriptMatch ?? 0, flatness: flatness)
        let row = VoiceLabTakeRow(id: id, index: 0, seed: 0, audio: processed, qa: qa, score: rank,
            failure: qa.hardFailures.isEmpty ? nil : .qa(qa.hardFailures))
        return MicrophoneTake(row: row, scratch: scratch, input: spoken, words: timed, model: heard.model,
            recordedSeconds: Double(samples.count) / Double(sampleRate))
    }

    /// The take's audio as a project asset, at Use.
    public static func publish(_ take: MicrophoneTake, storage: VoiceLabTakeStorage, at date: Date) throws -> VoiceLabPublishedTake {
        guard take.scratch.isValid else { throw VoiceLabError.invalidAudio }
        let publication = try take.scratch.fitted.publish(projectId: storage.projectId, assetId: UUID().uuidString.lowercased(),
            paidRoot: storage.paidRoot, createdAt: date, requestId: take.row.id.uuidString.lowercased(), seed: 0,
            gainDb: take.scratch.audio.gainDb)
        return VoiceLabPublishedTake(assets: publication.assets, audio: publication.audio, outDuration: publication.outDuration,
            words: publication.words, chunks: publication.chunks)
    }
}

/// The on-device recognizers a microphone take uses, in order: Apple's speech engine when its assets for the language
/// are installed, then the Whisper model the project was transcribed with, if any. Neither downloads anything.
public struct OnDeviceTakeTranscriber: MicrophoneTakeTranscribing {
    let engines: [@Sendable () -> (any Transcriber, TranscriptionPlan)]
    public init(locations: DataLocations, whisper: (catalog: BundledModelCatalog, model: String)?) {
        var engines: [@Sendable () -> (any Transcriber, TranscriptionPlan)] = [{
            (AppleSpeechTranscriber(locations: locations), TranscriptionPlan(engine: .appleSpeech))
        }]
        if let whisper {
            engines.append { (WhisperCppTranscriber(catalog: whisper.catalog, locations: locations),
                              TranscriptionPlan(engine: .whispercpp, model: whisper.model)) }
        }
        self.engines = engines
    }
    public func words(_ samples: [Float], language: String) async throws -> (model: String, words: [VoiceLabSpokenWord]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-mic-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("take.wav")
        try VoiceLabTakeWAV.encode(samples.map { max(-1, min(1, $0)) }, rate: 16_000).write(to: wav)
        let audio = ExtractedAudio(wav16k: wav, sampleCount: Int64(samples.count), durationSeconds: Double(samples.count) / 16_000)
        for make in engines {
            var (engine, plan) = make()
            plan.language = .forced(language)
            guard await engine.readiness(for: plan) == .ready else { continue }
            let raw = try await engine.transcribe(TranscriptionRequest(plan: plan, audio: audio,
                contentKey: "microphone-take-" + UUID().uuidString.lowercased())) { _ in }
            let model = plan.engine == .appleSpeech ? "apple-speech" : "whisper.cpp " + (plan.model ?? "")
            return (model, Self.words(raw.tokens))
        }
        throw MicrophoneTakeError.transcriptionUnavailable
    }
    /// Tokens joined into words: a token that joins the previous one (punctuation, a word piece) extends it.
    static func words(_ tokens: [RawToken]) -> [VoiceLabSpokenWord] {
        var words: [VoiceLabSpokenWord] = []
        for token in tokens {
            let text = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = words.last, token.joinsPrevious || token.start == nil || token.end == nil {
                words[words.count - 1] = VoiceLabSpokenWord(text: last.text + text, start: last.start, end: max(last.end, token.end ?? last.end))
            } else if let start = token.start, let end = token.end, end > start {
                words.append(VoiceLabSpokenWord(text: text, start: start, end: end))
            }
        }
        return words
    }
}
