import Foundation
import whisper
import VoxClipCore

/// Native engine adapter; transcription §9, architecture §7.1. No native context crosses an actor.
public actor WhisperCppTranscriber: Transcriber {
    public nonisolated let engine: TranscriptEngine = .whispercpp
    public init() {}
    public nonisolated func capabilities(model: String?) -> TranscriberCapabilities { TranscriberCapabilities(timing: .dtw, verbatim: false, autoLanguage: true, onDevice: true) }
    public func supports(_ language: LanguageChoice, model: String?) async -> Bool {
        // TODO(mac-speech)
        return false
    }
    public func readiness(for plan: TranscriptionPlan) async -> Readiness {
        // TODO(mac-speech)
        return .unavailable(reason: "mac-speech")
    }
    public func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws { throw VoxClipError.notImplemented("mac-speech") }
    public func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript { throw VoxClipError.notImplemented("mac-speech") }
}
