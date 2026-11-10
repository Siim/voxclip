import AVFoundation
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// Local measurements, never run in CI. Every input is named by an environment variable and read only; nothing is
/// written beside them, and the numbers go to the test's output.
///
/// The guard (voice-lab §6.9): each phrase's cosine with the old raw 10 s window and with the speech the guard reads,
/// and (ADR-R41) the same phrases against references learned from other phrases.
///
/// VOXCLIP_GUARD_MEASURE_PROJECT     a .voxclip file
/// VOXCLIP_GUARD_MEASURE_MEDIA       its source media
/// VOXCLIP_GUARD_MEASURE_RECORD      the voice's consent record.json
/// VOXCLIP_SPEAKER_MODEL_DIR         the verified local speaker model and VAD
/// VOXCLIP_GUARD_MEASURE_PHRASES     phrases as first-last word ids, separated by commas (for example w10-w12,w20-w20)
/// VOXCLIP_GUARD_MEASURE_REFERENCES  optional: 1-based phrase numbers whose guard speech becomes a reference (for example 3,4)
/// VOXCLIP_GUARD_MEASURE_SWEEP       optional instead of phrases: first-last word ids and a longest phrase (w450-w512:8)
///
/// The clone (ADR-R41 part b): every paid take against the original speech around it and against the owner reference.
///
/// VOXCLIP_TAKE_MEASURE_EXPORT       an exported video with its .provenance.json beside it
/// VOXCLIP_TAKE_MEASURE_REFERENCE    the voice's reference.wav (or statement.wav)
/// VOXCLIP_TAKE_MEASURE_DIRS         optional: folders of take WAVs, separated by commas
extension HeavyMediaTests {
@Suite("Guard speech measurement (local only)", .serialized)
struct VoiceGuardSpeechMeasureTests {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static func has(_ names: [String]) -> Bool { names.allSatisfy { environment[$0]?.isEmpty == false } }
    static let guardInputs = ["VOXCLIP_GUARD_MEASURE_PROJECT", "VOXCLIP_GUARD_MEASURE_MEDIA", "VOXCLIP_GUARD_MEASURE_RECORD", "VOXCLIP_SPEAKER_MODEL_DIR"]
    static var enabled: Bool { has(guardInputs + ["VOXCLIP_GUARD_MEASURE_PHRASES"]) }
    static var sweepEnabled: Bool { has(guardInputs + ["VOXCLIP_GUARD_MEASURE_SWEEP"]) }
    static var takesEnabled: Bool { has(["VOXCLIP_TAKE_MEASURE_EXPORT", "VOXCLIP_TAKE_MEASURE_REFERENCE", "VOXCLIP_SPEAKER_MODEL_DIR"]) }

    /// The project, its source and the guard's check, read once.
    struct Context {
        let project: Project
        let media: URL
        let record: VoiceConsentRecord
        let owner: [Float]
        let embedder: ONNXSpeakerEmbedder
        let check: VoiceSpeakerCheck
        let words: [TimedWord]
        let rate: Int
        let frames: Int64
        let envelope: AudioEnvelope

        static func load() async throws -> Context {
            let env = VoiceGuardSpeechMeasureTests.environment
            let project = try ProjectJSON.decode(Data(contentsOf: URL(fileURLWithPath: env["VOXCLIP_GUARD_MEASURE_PROJECT"]!)))
            let media = URL(fileURLWithPath: env["VOXCLIP_GUARD_MEASURE_MEDIA"]!)
            let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: Data(contentsOf: URL(fileURLWithPath: env["VOXCLIP_GUARD_MEASURE_RECORD"]!)))
            let owner = try #require(VoiceConsentRecord.decodeEmbedding(record.speaker.embedding))
            let embedder = try await VoiceGuardSpeechMeasureTests.embedder()
            let check = try await embedder.speakerCheck(language: record.language)
            #expect(check.threshold == record.speaker.threshold)
            let words = try #require(project.transcript?.words)
            let audio = try #require(project.media.source.audio)
            let frames = Int64(EditingPrimitives.jsRound(project.media.source.durationSeconds * Double(audio.sampleRate)))
            let envelope = try await VoiceLabSourceAudio.rewriteEnvelope(source: media, frames: frames, sampleRate: audio.sampleRate)
            return Context(project: project, media: media, record: record, owner: owner, embedder: embedder, check: check,
                           words: words, rate: audio.sampleRate, frames: frames, envelope: envelope)
        }

        func window(_ firstID: String, _ lastID: String) throws -> VoiceLabWindow {
            let first = try #require(words.first { $0.id == firstID })
            let last = try #require(words.first { $0.id == lastID })
            let startSample = Int64(EditingPrimitives.jsRound(first.start * Double(rate)))
            let endSample = Int64(EditingPrimitives.jsRound(last.end * Double(rate)))
            let fade = Int64(rate / 50)
            return VoiceLabWindow(firstWordId: first.id, lastWordId: last.id, leftBridgeWordIds: [], rightBridgeWordIds: [],
                start: first.start, end: last.end, startSample: startSample, endSample: endSample,
                leftSeam: .init(kind: .hard, time: first.start, sample: startSample, fadeSamples: fade),
                rightSeam: .init(kind: .hard, time: last.end, sample: endSample, fadeSamples: fade))
        }

        /// The old raw 10 s window and the guard's speech, both at 16 kHz.
        func speech(_ window: VoiceLabWindow) async throws -> (raw: [Float], guarded: [Float]) {
            let source = try await VoiceLabSourceAudio.rewriteSource(source: media, frames: frames, sampleRate: rate, window: window,
                incomingSilence: nil, outgoingSilence: nil, items: words, envelope: envelope)
            let input = VoiceLabTakeInput(text: "measure", modelID: "eleven_v3", recordID: record.id, language: record.language, seed: 1,
                contentKey: project.media.source.contentKey, source: source.excerpt, sourceEnvelope: source.envelope,
                sourceSampleRate: rate, items: words, window: window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
            let center = Int((window.startSample + window.endSample) / 2)
            let rawStart = max(0, center - 5 * rate), rawEnd = min(source.excerpt.totalFrames, rawStart + 10 * rate)
            let raw = VoiceConsentAudio.resample(Array(try #require(source.excerpt.samples(rawStart..<rawEnd))), rate: rate)
            return (raw, try VoiceLabTakeRun.guardSpeech(input))
        }

        func embedding(_ pcm16k: [Float]) async throws -> [Float] { try await check.embedding(Array(pcm16k.prefix(160_000))) }
    }

    static func embedder() async throws -> ONNXSpeakerEmbedder {
        let model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        return try ONNXSpeakerEmbedder(model: model, directory: URL(fileURLWithPath: environment["VOXCLIP_SPEAKER_MODEL_DIR"]!))
    }

    static func format(_ value: Double) -> String { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value) }

    @Test(.enabled(if: enabled, "Local measurement: set the VOXCLIP_GUARD_MEASURE_* paths, read only."))
    func measuresOldAndNewGuardSpeech() async throws {
        let context = try await Context.load()
        let env = Self.environment
        print("guard-measure threshold=\(context.record.speaker.threshold) model=\(context.record.speaker.model)")
        var phrases: [(number: Int, embedding: [Float]?)] = []
        for (index, spec) in env["VOXCLIP_GUARD_MEASURE_PHRASES"]!.split(separator: ",").enumerated() {
            let ids = spec.split(separator: "-").map(String.init)
            let window = try context.window(try #require(ids.first), try #require(ids.last))
            let speech = try await context.speech(window)
            func score(_ pcm: [Float]) async -> (text: String, embedding: [Float]?) {
                do {
                    let voiced = try await context.embedder.voicedSamples(Array(pcm.prefix(160_000)))
                    let vector = try await context.embedding(pcm)
                    let cosine = try VoiceSpeakerCheck.cosine(context.owner, vector)
                    return ("cos=\(Self.format(cosine)) voiced=\(String(format: "%.2f", Double(voiced.count) / 16_000))s", vector)
                } catch { return ("error=\(error)", nil) }
            }
            let old = await score(speech.raw), new = await score(speech.guarded)
            let selection = VoiceLabGuardSpeech.select(items: context.words, start: window.start, end: window.end, sampleRate: context.rate, totalFrames: Int(context.frames))
            print("guard-measure phrase=\(index + 1) span=\(String(format: "%.2f-%.2f", window.start, window.end)) " +
                  "old[raw 10 s: \(old.text)] new[\(selection.ranges.count) word spans, \(String(format: "%.2f", Double(speech.guarded.count) / 16_000)) s: \(new.text)]")
            phrases.append((index + 1, new.embedding))
        }
        // ADR-R41: phrases named in VOXCLIP_GUARD_MEASURE_REFERENCES become references, if they pass against the statement
        // themselves (one hop), and every other phrase is scored against each of them.
        let chosen = Set((env["VOXCLIP_GUARD_MEASURE_REFERENCES"] ?? "").split(separator: ",").compactMap { Int($0) })
        let references = try phrases.filter { chosen.contains($0.number) }.compactMap { phrase -> (Int, [Float])? in
            guard let embedding = phrase.embedding else { return nil }
            let hop = try VoiceSpeakerCheck.cosine(context.owner, embedding)
            print("guard-measure reference=phrase \(phrase.number) statement=\(Self.format(hop)) " + (hop >= context.record.speaker.threshold ? "kept" : "refused (one hop)"))
            return hop >= context.record.speaker.threshold ? (phrase.number, embedding) : nil
        }
        guard !references.isEmpty else { return }
        for phrase in phrases where !chosen.contains(phrase.number) {
            guard let embedding = phrase.embedding else { continue }
            let statement = try VoiceSpeakerCheck.cosine(context.owner, embedding)
            let scores = try references.map { ($0.0, try VoiceSpeakerCheck.cosine($0.1, embedding)) }
            let best = max(statement, scores.map(\.1).max() ?? statement)
            print("guard-measure phrase=\(phrase.number) statement=\(Self.format(statement)) " +
                  scores.map { "ref(phrase \($0.0))=\(Self.format($0.1))" }.joined(separator: " ") +
                  " best=\(Self.format(best)) " + (best >= context.record.speaker.threshold ? "passes" : "blocked"))
        }
    }

    /// Every contiguous run of words in a range, up to a length, with the guard's speech cosine. Used to find which
    /// phrases a past Rewrite had, when only their cosines are known.
    @Test(.enabled(if: sweepEnabled, "Local measurement: set VOXCLIP_GUARD_MEASURE_SWEEP and the project paths, read only."))
    func sweepsGuardSpeech() async throws {
        let context = try await Context.load()
        let spec = Self.environment["VOXCLIP_GUARD_MEASURE_SWEEP"]!.split(separator: ":")
        let ids = spec[0].split(separator: "-").map(String.init)
        let longest = spec.count > 1 ? Int(spec[1]) ?? 8 : 8
        let all = context.words.filter { $0.kind == .word }
        let from = try #require(all.firstIndex { $0.id == ids.first }), to = try #require(all.firstIndex { $0.id == ids.last })
        // The source decoded once, whole: the guard reads only word spans from it.
        let decoded = try await Self.decodeMono(context.media, rate: context.rate)
        let whole = VoiceLabSourceExcerpt(whole: Array(decoded.prefix(Int(context.frames))) + [Float](repeating: 0, count: max(0, Int(context.frames) - decoded.count)))
        for first in from...to {
            for last in first...min(to, first + longest - 1) {
                let window = try context.window(all[first].id, all[last].id)
                let input = VoiceLabTakeInput(text: "measure", modelID: "eleven_v3", recordID: context.record.id, language: context.record.language,
                    seed: 1, contentKey: context.project.media.source.contentKey, source: whole, sourceEnvelope: context.envelope,
                    sourceSampleRate: context.rate, items: context.words, window: window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
                guard let vector = try? await context.embedding(VoiceLabTakeRun.guardSpeech(input)) else { continue }
                print("guard-sweep \(all[first].id)-\(all[last].id) cos=\(Self.format(try VoiceSpeakerCheck.cosine(context.owner, vector)))")
            }
        }
    }

    /// The clone against the creator: each take in an export against the original speech around it in the same export,
    /// and both against the voice's owner reference. Takes shorter than the 3 s embedding window are also pooled.
    @Test(.enabled(if: takesEnabled, "Local measurement: set VOXCLIP_TAKE_MEASURE_* and the model path, read only."))
    func measuresTakesAgainstTheOriginal() async throws {
        let env = Self.environment
        let embedder = try await Self.embedder()
        let check = try await embedder.speakerCheck(language: "en")
        let referenceWAV = try Data(contentsOf: URL(fileURLWithPath: env["VOXCLIP_TAKE_MEASURE_REFERENCE"]!))
        let owner = try await check.embedding(VoiceConsentAudio.pcm16k(referenceWAV))
        func cosine(_ a: [Float]?, _ b: [Float]?) -> String {
            guard let a, let b, let value = try? VoiceSpeakerCheck.cosine(a, b) else { return "n/a" }
            return Self.format(value)
        }
        func embed(_ pcm16k: [Float]) async -> [Float]? { try? await check.embedding(Array(pcm16k.prefix(160_000))) }
        func voicedSeconds(_ pcm16k: [Float]) async -> Double { Double((try? await embedder.voicedSamples(pcm16k).count) ?? 0) / 16_000 }

        let export = URL(fileURLWithPath: env["VOXCLIP_TAKE_MEASURE_EXPORT"]!)
        let provenance = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: export.path + ".provenance.json"))) as? [String: Any]
        let segments = ((provenance?["aiSegments"] as? [[String: Any]]) ?? []).filter { $0["kind"] as? String == "tts" }
        let ranges = segments.compactMap { segment -> (Double, Double, String)? in
            guard let start = segment["outputStart"] as? Double, let end = segment["outputEnd"] as? Double else { return nil }
            return (start, end, segment["text"] as? String ?? "")
        }
        let audio = try await Self.decodeMono16k(export)
        func slice(_ start: Double, _ end: Double) -> [Float] {
            let lower = max(0, Int(start * 16_000)), upper = min(audio.count, Int(end * 16_000))
            return lower < upper ? Array(audio[lower..<upper]) : []
        }
        /// Up to `seconds` of the export on both sides of a take, outside every take.
        func around(_ start: Double, _ end: Double, seconds: Double) -> [Float] {
            var pieces: [Float] = []
            for (lower, upper) in [(start - seconds, start), (end, end + seconds)] {
                let clippedLower = max(0, lower)
                var cursor = clippedLower
                for other in ranges.sorted(by: { $0.0 < $1.0 }) where other.1 > clippedLower && other.0 < upper {
                    if other.0 > cursor { pieces += slice(cursor, other.0) }
                    cursor = max(cursor, other.1)
                }
                if cursor < upper { pieces += slice(cursor, upper) }
            }
            return pieces
        }
        print("take-measure export=\(export.lastPathComponent) takes=\(ranges.count) model=\(embedder.modelID)")
        var pooledTakes: [Float] = [], pooledAround: [Float] = []
        for (index, range) in ranges.enumerated() {
            let take = slice(range.0, range.1), near = around(range.0, range.1, seconds: 8)
            pooledTakes += take; pooledAround += near
            let takeVector = await embed(take), nearVector = await embed(near)
            let takeVoiced = await voicedSeconds(take), nearVoiced = await voicedSeconds(near)
            print("take-measure take=\(index + 1) \"\(range.2)\" \(String(format: "%.2f-%.2f", range.0, range.1)) voiced=\(String(format: "%.2f", takeVoiced))s " +
                  "take~original=\(cosine(takeVector, nearVector)) original~reference=\(cosine(nearVector, owner)) take~reference=\(cosine(takeVector, owner)) " +
                  "original voiced=\(String(format: "%.2f", nearVoiced))s")
        }
        let takesVector = await embed(pooledTakes), aroundVector = await embed(pooledAround)
        print("take-measure pooled takes=\(String(format: "%.2f", await voicedSeconds(pooledTakes)))s voiced " +
              "take~original=\(cosine(takesVector, aroundVector)) original~reference=\(cosine(aroundVector, owner)) take~reference=\(cosine(takesVector, owner))")

        for folder in (env["VOXCLIP_TAKE_MEASURE_DIRS"] ?? "").split(separator: ",").map(String.init) where !folder.isEmpty {
            let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".wav") && !$0.hasPrefix(".") }.sorted()
            var pooled: [Float] = [], scores: [Double] = []
            for name in files {
                guard let wav = try? Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(name)),
                      let pcm = try? VoiceConsentAudio.pcm16k(wav) else { continue }
                pooled += pcm
                if let vector = await embed(pcm), let score = try? VoiceSpeakerCheck.cosine(vector, owner) { scores.append(score) }
            }
            let pooledVector = await embed(Array(pooled.prefix(160_000)))
            let sorted = scores.sorted()
            let median = sorted.isEmpty ? Double.nan : sorted[sorted.count / 2]
            print("take-measure folder=\(URL(fileURLWithPath: folder).lastPathComponent.prefix(8)) wavs=\(files.count) embeddable=\(scores.count) " +
                  "take~reference min=\(Self.format(sorted.first ?? .nan)) median=\(Self.format(median)) max=\(Self.format(sorted.last ?? .nan)) " +
                  "pooled(10 s)~reference=\(cosine(pooledVector, owner))")
        }
    }

    /// A media file's audio as mono 48 kHz, then the production 16 kHz resampler.
    static func decodeMono16k(_ url: URL) async throws -> [Float] {
        VoiceConsentAudio.resample(try await decodeMono(url, rate: 48_000), rate: 48_000)
    }

    /// A media file's first audio track, mixed to mono at `rate`.
    static func decodeMono(_ url: URL, rate: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        return try await MediaReadQueue.run {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
            var samples: [Float] = []
            while let buffer = MediaReadQueue.copyNext(output), let block = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(block)
                var chunk = [Float](repeating: 0, count: length / 4)
                _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                samples += chunk
            }
            return samples
        }
    }
}
}
