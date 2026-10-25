import Foundation

public enum ElevenLabsRegion: String, Codable, CaseIterable, Sendable {
    case `default`
    case us
    case eu
    case india = "in"
    case singapore = "sg"

    public var baseURL: URL {
        let base = switch self {
        case .default: "https://api.elevenlabs.io"
        case .us: "https://api.us.elevenlabs.io"
        case .eu: "https://api.eu.residency.elevenlabs.io"
        case .india: "https://api.in.residency.elevenlabs.io"
        case .singapore: "https://api.sg.residency.elevenlabs.io"
        }
        return URL(string: base)!
    }

    public static func from(settings: SettingsDocument, logger: any Redacting) async -> ElevenLabsRegion {
        guard let stored = settings.values["transcription.elevenlabs.region"] else { return .default }
        if case .string(let value) = stored, let region = ElevenLabsRegion(rawValue: value) { return region }
        await Log(logger: logger).write(.warn, category: "transcribe", message: "Unknown ElevenLabs region setting; using Default.")
        return .default
    }
}
