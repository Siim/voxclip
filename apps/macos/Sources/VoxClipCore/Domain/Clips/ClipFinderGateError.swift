import Foundation

public enum ClipFinderGateError: Error, Sendable, Equatable, LocalizedError {
    case noWords(message: String)
    case needInstructions(message: String)

    public var userMessage: String {
        switch self {
        case .noWords(let message), .needInstructions(let message): message
        }
    }

    public var errorDescription: String? { userMessage }
}
