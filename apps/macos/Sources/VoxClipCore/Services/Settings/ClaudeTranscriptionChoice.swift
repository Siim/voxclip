public struct ClaudeTranscriptionChoice: Sendable {
    public enum Apple: String, Sendable, Decodable { case ready, unavailable, unknown }

    public let confirmation: TranscriptEngine
    public let firstPass: Bool
    public let label: String

    public init(mode: String, apple: Apple) {
        confirmation = mode == "elevenlabs" ? .elevenlabs : .whispercpp
        firstPass = mode != "ask" && apple == .ready
        if mode == "ask" {
            label = "Ask before transcribing"
        } else {
            let verifier = confirmation == .elevenlabs ? "Scribe (approval required)" : "Whisper"
            switch apple {
            case .ready: label = "Apple Speech → " + verifier
            case .unknown: label = "Apple Speech if available → " + verifier
            case .unavailable: label = confirmation == .whispercpp ? "Whisper on this device" : verifier
            }
        }
    }
}
