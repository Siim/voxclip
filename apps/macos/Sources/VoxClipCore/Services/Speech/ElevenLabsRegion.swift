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

    /// Data-residency hosts serve separate Enterprise workspaces with their own keys.
    public var isResidency: Bool { self == .eu || self == .india || self == .singapore }

    /// Appended to a 400, 401 or key error from a residency host; empty elsewhere.
    public var residencyHint: String { isResidency ? "ElevenLabs \(rawValue.uppercased()) residency needs a key from a data-residency workspace; most accounts use Region: Default" : "" }

    public static func from(settings: SettingsDocument, logger: any Redacting) async -> ElevenLabsRegion {
        guard let stored = settings.values["transcription.elevenlabs.region"] else { return .default }
        if case .string(let value) = stored, let region = ElevenLabsRegion(rawValue: value) { return region }
        await Log(logger: logger).write(.warn, category: "transcribe", message: "Unknown ElevenLabs region setting; using Default.")
        return .default
    }
}
