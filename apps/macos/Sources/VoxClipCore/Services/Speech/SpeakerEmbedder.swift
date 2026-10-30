import Foundation

public protocol SpeakerEmbedder: Sendable {
    var modelID: String { get }
    var dimension: Int { get }
    func embed(_ pcm16k: [Float]) async throws -> [Float]
    func voicedSamples(_ pcm16k: [Float]) async throws -> [Float]
    func validateAvailability() async throws
}

extension SpeakerEmbedder {
    public func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] { try SpeakerAudio.energySpeech(pcm16k) }
    public func validateAvailability() async throws {}
}
