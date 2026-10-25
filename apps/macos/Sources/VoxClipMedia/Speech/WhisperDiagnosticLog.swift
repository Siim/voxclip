import Foundation
import Synchronization
import VoxClipCore
import whisper

/// The process-lifetime box outlives both C callbacks; its logger is accessed only under the mutex.
final class WhisperDiagnosticLog: Sendable {
    static let shared = WhisperDiagnosticLog()
    private let logger = Mutex<(any Redacting)?>(nil)

    static func install(logger: any Redacting) {
        shared.logger.withLock { $0 = logger }
        let opaque = Unmanaged.passUnretained(shared).toOpaque()
        whisper_log_set({ level, text, context in
            guard let text, let context else { return }
            _ = Unmanaged<WhisperDiagnosticLog>.fromOpaque(context).takeUnretainedValue().forward(level: level, message: String(cString: text))
        }, opaque)
        ggml_log_set({ level, text, context in
            guard let text, let context else { return }
            _ = Unmanaged<WhisperDiagnosticLog>.fromOpaque(context).takeUnretainedValue().forward(level: level, message: String(cString: text))
        }, opaque)
    }

    func forward(level: ggml_log_level, message: String) -> Task<Void, Never>? {
        guard level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR, let logger = logger.withLock({ $0 }) else { return nil }
        return Task { await Log(logger: logger).write(.warn, category: "transcribe", message: "whisper: " + message.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
