import Foundation
import Speech
import VoxClipCore

/// Native engine adapter; transcription §10, architecture §7.1. No native context crosses an actor.
public actor AppleSpeechTranscriber: Transcriber {
    public nonisolated let engine: TranscriptEngine = .appleSpeech
    public init() {}
    public nonisolated func capabilities(model: String?) -> TranscriberCapabilities { TranscriberCapabilities(timing: .runGrouped, verbatim: false, autoLanguage: false, onDevice: true) }
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
