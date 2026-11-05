#if DEBUG
import Foundation
import VoxClipCore
import VoxClipMedia

// Stand-ins for Say it myself (MicrophoneTake.swift), shared by the Rewrite smoke's own-words scenarios and the App
// tests: a microphone that "records" a scripted take, a silent cue, and a recognizer that hears scripted words. Nothing
// touches the real microphone, speakers or speech engines.

@MainActor final class ScriptedPhraseMicrophone: PhraseMicrophone {
    private(set) var recording = false
    private(set) var seconds = 0.0
    private(set) var level = 0.0
    private(set) var samples: [Float] = []
    private(set) var failure: MicrophoneError?
    private(set) var starts = 0
    /// What the next Stop hands over.
    var next: [Float] = []
    var startError: (any Error)?
    func start(maximumSeconds: Int) async throws {
        starts += 1
        if let startError { throw startError }
        recording = true; samples = []; seconds = 0; level = 0.3; failure = nil
    }
    func stop() {
        guard recording else { return }
        recording = false; samples = next; seconds = Double(next.count) / Double(MicrophoneTakeMaker.recordingRate)
    }
    func discard() { recording = false; samples = []; seconds = 0; level = 0 }
}

@MainActor final class SilentPhraseCue: PhraseCuePlayer {
    private(set) var played: [PhraseTakeCue] = []
    func play(_ cue: PhraseTakeCue) async { played.append(cue) }
    func stop() {}
}

struct ScriptedTakeTranscriber: MicrophoneTakeTranscribing {
    let heard: [VoiceLabSpokenWord]
    func words(_ samples: [Float], language: String) async throws -> (model: String, words: [VoiceLabSpokenWord]) {
        ("scripted-speech", heard)
    }
}

/// A spoken-like recording of `words` filling `speechSeconds`, with quiet lead and tail: each word is a voiced burst
/// at `amplitude` (about 12 dB under the fixtures' source speech by default), so the take's loudness must be matched.
enum ScriptedOwnTake {
    static let lead = 0.3
    static func recording(words: [String], speechSeconds: Double, amplitude: Float = 0.025) -> (samples: [Float], heard: [VoiceLabSpokenWord]) {
        let rate = Double(MicrophoneTakeMaker.recordingRate)
        let gap = 0.08
        let count = Double(max(1, words.count))
        let span: Double = max(0.12, (speechSeconds - gap * (count - 1)) / count)
        var heard: [VoiceLabSpokenWord] = []
        let total = Int((lead * 2 + speechSeconds) * rate)
        var samples = [Float](repeating: 0, count: total)
        for (index, word) in words.enumerated() {
            let start: Double = lead + Double(index) * (span + gap)
            heard.append(VoiceLabSpokenWord(text: word, start: start, end: start + span))
            let first = Int(start * rate), length = Int(span * rate)
            for offset in 0..<length where first + offset < total {
                let time: Double = Double(offset) / rate
                let envelope: Double = sin(Double.pi * Double(offset) / Double(length))
                let voice: Double = sin(2 * Double.pi * 160 * time) + 0.5 * sin(2 * Double.pi * 320 * time) + 0.25 * sin(2 * Double.pi * 480 * time)
                samples[first + offset] = amplitude * Float(envelope * voice / 1.75)
            }
        }
        return (samples, heard)
    }
}

extension RewriteSession {
    /// Points Say it myself at the stand-ins, with a scripted take to hand over at Stop.
    func useScriptedMicrophone(words: [String], speechSeconds: Double, access: MicrophoneAccess = .allowed) {
        let take = ScriptedOwnTake.recording(words: words, speechSeconds: speechSeconds)
        let microphone = ScriptedPhraseMicrophone()
        microphone.next = take.samples
        phraseMicrophone.microphone = microphone
        phraseMicrophone.cue = SilentPhraseCue()
        phraseMicrophone.transcriber = ScriptedTakeTranscriber(heard: take.heard)
        phraseMicrophone.access = { access }
        phraseMicrophone.headphones = { false }
        phraseMicrophone.meters = false
    }
}
extension DebugRewriteSmoke {
    /// My words and Say it myself (design.md §6.3), driven as a user clicks them, with the scripted microphone above.
    static var ownTakeScenarios: [Definition] { [
        Definition(id: "S-own-typed", title: "My words: the user types the wording, the cloned voice reads it, Use", voiced: 1,
            fixture: Fixture(rewrites: [.passage(replace([twoChanges[0]]))], voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            try await harness.start()
            try await harness.click(["prepareTakes", "makeTakes"])
            guard let session = harness.session, session.takePlan?.phrases.isEmpty == false else { throw Failure.setup("S-own-typed needs a takes plan") }
            try await harness.act("choose [My words] on phrase 1", clicked: "wording") { session.chooseWording(.ownWords, phrase: 0) }
            try await harness.act("type 'shoot the clip in one go' in My words", clicked: "ownWords") {
                session.editOwnWords("shoot the clip in one go", phrase: 0)
                await session.priceOwnWords(phrase: 0)
            }
            guard let action = session.ownWordsTakeAction(phrase: 0) else { throw Failure.missing("Make take", "My words has no priced take") }
            try await harness.act("click [\(action.title)]", clicked: action.id) { action.perform() }
            if session.task.confirm != nil { try await harness.click(["approveTakeQuote"]) }
            try await harness.finish()
        },
        Definition(id: "S-own-mic", title: "Say it myself: the user records the phrase, it is checked on this Mac, Use", voiced: 1,
            fixture: Fixture(rewrites: [.passage(replace([twoChanges[0]]))], voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            try await harness.start()
            try await harness.click(["prepareTakes", "makeTakes"])
            try await recordOwnTake(harness, factor: 1, step: "click [● Record]")
            try await useOwnTake(harness)
            try await harness.finish()
        },
        Definition(id: "S-own-mic-misfit", title: "Say it myself runs too long, then Record again fits, Use", voiced: 1,
            fixture: Fixture(rewrites: [.passage(replace([twoChanges[0]]))], voice: RewriteSmokeVoiceScript(offset: -0.2))) { harness in
            try await harness.start()
            try await harness.click(["prepareTakes", "makeTakes"])
            try await recordOwnTake(harness, factor: 2.2, step: "click [● Record]")
            try await recordOwnTake(harness, factor: 1, step: "click [Record again]")
            try await useOwnTake(harness)
            try await harness.finish()
        },
    ] }

    /// Chooses Say it myself on phrase 1, records a take `factor` times the gap's speech, and stops.
    @MainActor private static func recordOwnTake(_ harness: Harness, factor: Double, step: String) async throws {
        guard let session = harness.session, let plan = session.takePlan, !plan.phrases.isEmpty else { throw Failure.setup("no takes plan") }
        let phrase = plan.phrases[0]
        try await harness.act("choose [● Say it myself] on phrase 1", clicked: "wording") {
            session.useScriptedMicrophone(words: EditingPrimitives.splitWords(phrase.text),
                speechSeconds: (phrase.window.end - phrase.window.start - 0.25) * factor)
            session.chooseWording(.microphone, phrase: 0)
        }
        try await harness.act(step, clicked: "microphone.record") { await session.phraseMicrophone.record(phrase: 0, plan: plan) }
        try await harness.act("click [Stop]", clicked: "microphone.stop") { await session.phraseMicrophone.stop() }
        if !session.phraseMicrophone.problem.isEmpty { throw Failure.setup("the take could not be checked: " + session.phraseMicrophone.problem) }
    }

    /// [Use your take], or [Use anyway] for a take that changes the video's duration (ADR-R39).
    @MainActor private static func useOwnTake(_ harness: Harness) async throws {
        guard let session = harness.session, let plan = session.takePlan,
              let take = plan.phrases.first?.takes.last(where: { $0.source == .microphone }) else { throw Failure.setup("no own take") }
        let anyway = !plan.lengthFits(take: take)
        try await harness.act("click [\(anyway ? "Use anyway" : "Use your take")] on phrase 1", clicked: "microphone.use") {
            session.mutateLipsync(phrase: 0) { _ = plan.select(take: take.id, phrase: 0) }
        }
    }
}
#endif
