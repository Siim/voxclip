import Foundation
import VoxClipCore

/// "Did matching help" (voice-lab §6.13): how close a take's voice is to the creator's own speech right beside it, with
/// the production speaker model, on this Mac. The original speech is the use-time guard's (§6.9): the transcript words
/// nearest the patch, in the patch speaker's turns. Nothing is sent.
public enum VoicePerVideoMatch {
    /// The cosine between the take's trimmed speech and that original speech, or nil when either has too little speech
    /// to embed.
    public static func score(take: VoiceLabTakeAudio, input: VoiceLabTakeInput, check: VoiceSpeakerCheck) async -> Double? {
        guard check.available, take.sampleRate > 0, !take.trimmed.isEmpty,
              let original = try? VoiceLabTakeRun.guardSpeech(input), !original.isEmpty else { return nil }
        let speech = take.sampleRate == 16_000 ? take.trimmed : VoiceConsentAudio.resample(take.trimmed, rate: take.sampleRate)
        guard let generated = try? await check.embedding(speech), let beside = try? await check.embedding(original) else { return nil }
        return try? VoiceSpeakerCheck.cosine(generated, beside)
    }
}
