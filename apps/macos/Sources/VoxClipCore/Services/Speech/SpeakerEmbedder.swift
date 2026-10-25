import Foundation

/// Reserved M3 speaker verification; voice-lab §6.6. No model or provider ships in this skeleton.
public protocol SpeakerEmbedder: Sendable {
    var modelID: String { get }
    var dimension: Int { get }
    func embed(_ pcm16k: [Float]) async throws -> [Float]
}
