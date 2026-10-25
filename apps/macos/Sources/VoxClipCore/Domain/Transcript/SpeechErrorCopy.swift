import Foundation

public enum SpeechErrorCopy {
    public static func duration(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, seconds) : 0
        return String(format: "%.0f:%02d:%02d", locale: Locale(identifier: "en_US_POSIX"), floor(value / 3600), Int(value.truncatingRemainder(dividingBy: 3600) / 60), Int(value.truncatingRemainder(dividingBy: 60)))
    }

    public static func bytes(_ bytes: Double) -> String {
        let value = bytes.isFinite ? max(0, bytes) : 0
        let divisor = value >= 1_000_000_000 ? 1_000_000_000.0 : value >= 1_000_000 ? 1_000_000.0 : 1.0
        if divisor == 1 { return String(format: "%.0f bytes", locale: Locale(identifier: "en_US_POSIX"), ceil(value)) }
        var number = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value / divisor)
        while number.last == "0" { number.removeLast() }
        if number.last == "." { number.removeLast() }
        return number + (divisor == 1_000_000_000 ? " GB" : " MB")
    }

    public static func engineName(_ engine: TranscriptEngine) -> String {
        switch engine {
        case .elevenlabs: "ElevenLabs"
        case .whispercpp: "Whisper"
        case .appleSpeech: "Apple"
        }
    }

    public static func unsupported(_ engine: TranscriptEngine, language: LanguageChoice) -> VoxClipError {
        let code: String
        switch language {
        case .auto: code = "automatically detected speech"
        case .forced(let value): code = value
        }
        return .transcriptionLanguageUnsupported(engineName(engine), language: code)
    }

    public static func modelMissing(_ model: ModelDescriptor, bytes: Int64? = nil) -> VoxClipError {
        .modelMissing(model.displayName, size: Self.bytes(Double(bytes ?? model.totalBytes)))
    }
}
