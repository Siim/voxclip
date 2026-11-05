#if DEBUG
import Foundation
import Synchronization
import Testing
@_spi(Testing) @testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia

/// A scripted speaker model for the guard: a window that is mostly loud noise (|x| > 0.5) or whose mean is negative
/// (the other speaker's words) is a stranger; anything else is the voice owner, the fixture record's [1, 0].
private final class GuardEmbedder: SpeakerEmbedder, Sendable {
    let modelID = "fixture-calibrated"
    let dimension = 2
    let calls = Mutex(0)
    func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] { pcm16k }
    func embed(_ pcm16k: [Float]) async throws -> [Float] {
        calls.withLock { $0 += 1 }
        let noisy = pcm16k.filter { abs($0) > 0.5 }.count * 5 > pcm16k.count
        let mean = pcm16k.reduce(0, +) / Float(max(1, pcm16k.count))
        return noisy || mean < 0 ? [0, 1] : [1, 0]
    }
}

@Suite("Use-time guard hears the patch's speech", .serialized, .offlineFixtures)
struct VoiceLabGuardSpeechTests {
    private static let rate = 16_000

    private func word(_ id: String, _ start: Double, _ end: Double, speaker: String? = nil) -> TimedWord {
        TimedWord(id: id, text: id, kind: .word, start: start, end: end, speaker: speaker)
    }
    private func seconds(_ ranges: [Range<Int>], rate: Int = rate) -> [[Double]] {
        ranges.map { [Double($0.lowerBound) / Double(rate), Double($0.upperBound) / Double(rate)] }
    }

    // MARK: Selection

    @Test func readsOnlyWordSpansNearestThePatchUpToTenSeconds() {
        // Twenty one-second words, each followed by a second of silence, over 40 s; the patch is word 10 (18–19 s).
        let words = (0..<20).map { word("w\($0)", Double($0 * 2), Double($0 * 2 + 1)) }
        let selection = VoiceLabGuardSpeech.select(items: words, start: 18, end: 19, sampleRate: Self.rate, totalFrames: 40 * Self.rate)
        #expect(selection.frames == 10 * Self.rate, "ten seconds of words, no silence")
        // The patch's word (9) and the nine nearest, the earlier of two equally near words first: words 4 to 13.
        #expect(seconds(selection.ranges).map(\.[0]) == (4...13).map { Double($0 * 2) })
        #expect(selection.ranges.allSatisfy { $0.count == Self.rate })
        #expect(selection.speaker == nil)
    }

    @Test func widensOutwardWhenThePatchHasLittleSpeech() {
        let words = [word("a", 0, 4), word("b", 10, 10.3), word("c", 30, 34), word("d", 60, 62)]
        let selection = VoiceLabGuardSpeech.select(items: words, start: 10, end: 10.3, sampleRate: Self.rate, totalFrames: 70 * Self.rate)
        // The patch's 0.3 s, then the nearest words at their 2 s cap, each the part nearest the patch: a's end (6 s away),
        // c's start (19.7 s away), then d's start.
        #expect(seconds(selection.ranges) == [[2, 4], [10, 10.3], [30, 32], [60, 62]])
        #expect(abs(Double(selection.frames) / Double(Self.rate) - 6.3) < 1e-9)
    }

    @Test func stopsAtTenSecondsInsideTheLastWord() {
        let words = (0..<6).map { word("w\($0)", Double($0 * 3), Double($0 * 3 + 2)) }
        let selection = VoiceLabGuardSpeech.select(items: words, start: 0, end: 2, sampleRate: Self.rate, totalFrames: 20 * Self.rate)
        #expect(selection.frames == 10 * Self.rate)
        #expect(seconds(selection.ranges) == [[0, 2], [3, 5], [6, 8], [9, 11], [12, 14]])
    }

    @Test func staysWithThePatchSpeakerWhereTheTranscriptKnowsSpeakers() {
        // A interviews B: A 0–6 s, B 6–20 s, A 20–24 s. A patch on B's words reads B's turn only; one on A's reads A's
        // words, never B's, even though B's are nearer than A's other turn.
        let words = [word("a1", 0, 2, speaker: "A"), word("a2", 3, 5, speaker: "A"),
                     word("b1", 6, 8, speaker: "B"), word("b2", 9, 11, speaker: "B"), word("b3", 12, 14, speaker: "B"),
                     word("b4", 15, 17, speaker: "B"), word("b5", 18, 19.5, speaker: "B"),
                     word("a3", 20, 22, speaker: "A"), word("a4", 22.5, 24, speaker: "A")]
        let other = VoiceLabGuardSpeech.select(items: words, start: 12, end: 14, sampleRate: Self.rate, totalFrames: 25 * Self.rate)
        #expect(other.speaker == "B")
        #expect(seconds(other.ranges) == [[6, 8], [9, 11], [12, 14], [15, 17], [18, 19.5]])
        let owner = VoiceLabGuardSpeech.select(items: words, start: 3, end: 5, sampleRate: Self.rate, totalFrames: 25 * Self.rate)
        #expect(owner.speaker == "A")
        #expect(seconds(owner.ranges) == [[0, 2], [3, 5], [20, 22], [22.5, 24]])
    }

    @Test func aLongWordOverThePatchGivesThePartAroundIt() {
        let words = [word("long", 0, 49.9), word("next", 50.7, 60)]
        let selection = VoiceLabGuardSpeech.select(items: words, start: 30, end: 31, sampleRate: Self.rate, totalFrames: 60 * Self.rate)
        #expect(seconds(selection.ranges) == [[29.5, 31.5], [50.7, 52.7]])
    }

    @Test func skipsEventsAndUntimedItems() {
        let words = [TimedWord(id: "laugh", text: "(laughs)", kind: .event, start: 0, end: 5), word("x", 6, 6), word("y", 7, 8)]
        let selection = VoiceLabGuardSpeech.select(items: words, start: 0, end: 5, sampleRate: Self.rate, totalFrames: 10 * Self.rate)
        #expect(seconds(selection.ranges) == [[7, 8]])
        #expect(VoiceLabGuardSpeech.select(items: [], start: 0, end: 1, sampleRate: Self.rate, totalFrames: Self.rate).ranges.isEmpty)
    }

    @Test func coversJoinNearbyWordsForOneDecode() {
        let selection = VoiceLabGuardSpeech(ranges: [0..<10, 20..<30, 100..<110], speaker: nil)
        #expect(selection.covers(joiningWithin: 15) == [0..<30, 100..<110])
    }

    // MARK: The guard on a noisy recording

    /// Words of the owner's speech (a quiet tone) between stretches of loud road noise, at 16 kHz so no resampler blurs
    /// the scripted embedder's reading.
    private func noisyInput(words: [TimedWord], seconds total: Int, window start: Double, _ end: Double,
                            other: Set<String> = []) -> VoiceLabTakeInput {
        var samples = [Float](repeating: 0, count: total * Self.rate)
        for index in samples.indices { samples[index] = index.isMultiple(of: 2) ? 0.9 : -0.9 }
        for item in words {
            let sign: Float = other.contains(item.id) ? -1 : 1
            for index in Int(item.start * Double(Self.rate))..<Int(item.end * Double(Self.rate)) {
                samples[index] = sign * (0.1 + 0.05 * Float(sin(Double(index) * 0.05)))
            }
        }
        let startSample = Int64(start * Double(Self.rate)), endSample = Int64(end * Double(Self.rate))
        let window = VoiceLabWindow(firstWordId: "p", lastWordId: "p", leftBridgeWordIds: [], rightBridgeWordIds: [], start: start, end: end,
            startSample: startSample, endSample: endSample, leftSeam: .init(kind: .hard, time: start, sample: startSample, fadeSamples: 320),
            rightSeam: .init(kind: .hard, time: end, sample: endSample, fadeSamples: 320))
        return VoiceLabTakeInput(text: "new words", modelID: "eleven_v3", recordID: "r", language: "en", seed: 1, contentKey: "car-video",
            source: samples, sourceSampleRate: Self.rate, items: words, window: window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
    }
    private var wav: Data { VoiceLabRequestFixtures.wav(rate: 16_000, frames: 80_000, fill: 4_000) }
    private func guardFixture(_ root: URL) async throws -> (VoiceConsentStore, VoiceConsentRecord) {
        var json = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/consent-record.json")) as? [String: Any])
        var statement = try #require(json["statement"] as? [String: Any]); statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root))
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        return (store, record)
    }

    @Test func noisyRawWindowFailsButTheSpeechPasses() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, record) = try await guardFixture(root)
        let embedder = GuardEmbedder()
        let useGuard = VoiceUseGuard(store: store, check: .init(embedder: embedder, calibratedThreshold: 0.8))
        // One-second words with 1.5 s of road noise between them, over 30 s; the patch is the word at 12.5–13.5 s.
        let words = (0..<12).map { word("w\($0)", Double($0) * 2.5, Double($0) * 2.5 + 1) }
        let input = noisyInput(words: words, seconds: 30, window: 12.5, 13.5)
        // What the guard read before: 10 s of raw source centred on the patch (8–18 s), mostly noise.
        let raw = Array(input.source.samples(128_000..<288_000)!)
        await #expect(throws: VoiceConsentError.voiceOwnerMismatch) {
            try await useGuard.authorize(contentKey: input.contentKey, recordID: record.id, speech16k: raw, approved: true)
        }
        let speech = try VoiceLabTakeRun.guardSpeech(input)
        #expect(speech.count == 10 * Self.rate)
        #expect(speech.allSatisfy { abs($0) < 0.5 }, "no road noise between the words")
        _ = try await useGuard.authorize(contentKey: input.contentKey, recordID: record.id, speech16k: speech, approved: true)
    }

    @Test func aTranscriptWithoutWordsReadsThePatchesOwnTenSeconds() throws {
        let input = noisyInput(words: [], seconds: 30, window: 12.5, 13.5)
        #expect(try VoiceLabTakeRun.guardSpeech(input) == Array(input.source.samples(128_000..<288_000)!))
    }

    // MARK: The cache, per phrase

    @Test func eachPhraseIsJudgedOnItsOwnSpeechAndAnotherSpeakersPhraseStaysBlocked() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, record) = try await guardFixture(root)
        let embedder = GuardEmbedder()
        let useGuard = VoiceUseGuard(store: store, check: .init(embedder: embedder, calibratedThreshold: 0.8))
        // The owner (A) speaks 0–12 s, a guest (B) 12–24 s, in the same project.
        let words = (0..<8).map { index in
            word("w\(index)", Double(index) * 3, Double(index) * 3 + 2.5, speaker: index < 4 ? "A" : "B")
        }
        let guest = Set((4..<8).map { "w\($0)" })
        let own = noisyInput(words: words, seconds: 24, window: 3, 5.5, other: guest)
        let theirs = noisyInput(words: words, seconds: 24, window: 15, 17.5, other: guest)
        let ownSpeech = try VoiceLabTakeRun.guardSpeech(own)
        _ = try await useGuard.authorize(contentKey: own.contentKey, recordID: record.id, speech16k: ownSpeech, approved: true)
        let afterFirst = embedder.calls.withLock { $0 }
        // The same phrase again (Try another, a later part of the run) is not embedded again.
        _ = try await useGuard.authorize(contentKey: own.contentKey, recordID: record.id, speech16k: ownSpeech, approved: true)
        #expect(embedder.calls.withLock { $0 } == afterFirst)
        // The guest's phrase in the same project is judged on the guest's speech, and the owner's pass does not cover it.
        await #expect(throws: VoiceConsentError.voiceOwnerMismatch) {
            try await useGuard.authorize(contentKey: theirs.contentKey, recordID: record.id, speech16k: VoiceLabTakeRun.guardSpeech(theirs), approved: true)
        }
        #expect(embedder.calls.withLock { $0 } > afterFirst)
    }
}
#endif
