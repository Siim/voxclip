import Foundation
import VoxClipCore
import whisper

public enum SpeakerVAD {
    public static func ranges(_ pcm: [Float], model: URL) throws -> [Range<Int>] {
        guard pcm.count >= 48_000, pcm.count <= 16_000 * 240, pcm.allSatisfy(\.isFinite) else { throw VoiceConsentError.speakerMismatch }
        try Task.checkCancellation()
        var options = whisper_vad_default_context_params()
        options.n_threads = 2; options.use_gpu = false
        guard let context = model.path.withCString({ whisper_vad_init_from_file_with_params($0, options) }) else { throw VoiceConsentError.speakerUnavailable }
        defer { whisper_vad_free(context) }
        var parameters = whisper_vad_default_params()
        parameters.threshold = 0.5
        parameters.min_speech_duration_ms = 250; parameters.min_silence_duration_ms = 100
        parameters.max_speech_duration_s = Float.greatestFiniteMagnitude
        parameters.speech_pad_ms = 0; parameters.samples_overlap = 0
        guard let segments = pcm.withUnsafeBufferPointer({ whisper_vad_segments_from_samples(context, parameters, $0.baseAddress, Int32($0.count)) }) else { throw VoiceConsentError.speakerMismatch }
        defer { whisper_vad_free_segments(segments) }
        try Task.checkCancellation()
        var result: [Range<Int>] = []
        for index in 0..<whisper_vad_segments_n_segments(segments) {
            let start = max(0, min(pcm.count, Int((Double(whisper_vad_segments_get_segment_t0(segments, index)) * 160).rounded())))
            let end = max(start, min(pcm.count, Int((Double(whisper_vad_segments_get_segment_t1(segments, index)) * 160).rounded())))
            guard end > start else { continue }
            if let previous = result.last, start <= previous.upperBound { result[result.count - 1] = previous.lowerBound..<max(previous.upperBound, end) }
            else { result.append(start..<end) }
        }
        return result
    }
}
