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
#endif
