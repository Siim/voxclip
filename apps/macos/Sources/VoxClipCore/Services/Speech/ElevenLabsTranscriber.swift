import Foundation

/// Cloud adapter placeholder; transcription §8. Does not read keys, upload or silently replace a local engine.
public actor ElevenLabsTranscriber: Transcriber {
    public nonisolated let engine: TranscriptEngine = .elevenlabs
    public init(keys: any KeyProvider) {}
    public nonisolated func capabilities(model: String?) -> TranscriberCapabilities { TranscriberCapabilities(timing: .native, verbatim: true, autoLanguage: true, maxDurationSeconds: 36_000, maxUploadBytes: 3_000_000_000, onDevice: false) }
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
