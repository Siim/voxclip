import Foundation
import OnnxRuntimeBindings
import VoxClipCore

public actor ONNXSpeakerEmbedder: SpeakerEmbedder {
    public nonisolated let modelID: String
    public nonisolated let dimension = 256
    private let environment: ORTEnv
    private let session: ORTSession
    private let vad: URL
    private let model: SpeakerModel
    private let directory: URL
    public init(model: SpeakerModel, directory: URL) throws {
        let files = try model.verifiedFiles(at: directory)
        modelID = model.id; vad = files.vad; self.model = model; self.directory = directory
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)
        self.environment = environment
        session = try ORTSession(env: environment, modelPath: files.model.path, sessionOptions: options)
        guard try session.inputNames() == ["feats"], try session.outputNames() == ["embs"] else { throw VoiceConsentError.speakerUnavailable }
    }
    public func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] {
        try SpeakerAudio.select(pcm16k, ranges: SpeakerVAD.ranges(pcm16k, model: vad))
    }
    public func validateAvailability() async throws { _ = try model.verifiedFiles(at: directory) }
    public func speakerCheck(language: String = "en") async throws -> VoiceSpeakerCheck {
        let trusted = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        return try await VoiceSpeakerCheck.make(verifiedModel: self, trustedEntry: trusted, language: language)
    }
    func validateIdentity(trustedEntry trusted: SpeakerModel) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard trusted.id == model.id, trusted.preprocessing == model.preprocessing,
              trusted.dimension == model.dimension,
              try encoder.encode(trusted.files) == encoder.encode(model.files) else { throw VoiceConsentError.speakerUnavailable }
        _ = try trusted.verifiedFiles(at: directory)
    }
    public func embed(_ pcm16k: [Float]) async throws -> [Float] {
        guard pcm16k.count <= 240 * 16_000 else { throw VoiceConsentError.speakerMismatch }
        var mean = [Float](repeating: 0, count: dimension)
        for window in try SpeakerAudio.windows(pcm16k) {
            let result = try infer(window)
            for index in mean.indices { mean[index] += result[index] }
        }
        return try SpeakerAudio.normalized(mean)
    }
    private func infer(_ pcm16k: [Float]) throws -> [Float] {
        try Task.checkCancellation()
        let features = try SpeakerAudio.features(pcm16k)
        let bytes = features.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        let tensor = try ORTValue(tensorData: bytes, elementType: .float, shape: [1, 298, 80])
        let output = try session.run(withInputs: ["feats": tensor], outputNames: ["embs"], runOptions: nil)
        guard let value = output["embs"] else { throw VoiceConsentError.speakerUnavailable }
        let data = try value.tensorData() as Data
        guard data.count == dimension * MemoryLayout<Float>.size else { throw VoiceConsentError.speakerUnavailable }
        let vector = data.withUnsafeBytes { bytes in (0..<dimension).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
        try Task.checkCancellation()
        return try SpeakerAudio.normalized(vector)
    }
}
