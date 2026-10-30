#if DEBUG
import ArgumentParser
import Foundation
import VoxClipCore
import VoxClipMedia

struct SpeakerDiagnostic: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "speaker-diagnostic", abstract: "Offline production speaker calibration; never downloads.")
    @Option var input: String
    @Option var modelDirectory: String
    @Option var output: String
    @Flag var includeFeatures = false
    struct Item: Codable { let id: String; let wav: String; let group: String? }
    struct Result: Codable { let id: String; let ranges: [[Int]]; let features: [[Float]]?; let embedding: [Float]? }
    struct Score: Codable { let left: String; let right: String; let value: Double }
    func run() async throws {
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        guard Set(items.map(\.id)).count == items.count else { throw ValidationError("Duplicate item id") }
        let model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        let modelRoot = URL(fileURLWithPath: modelDirectory, isDirectory: true)
        let files = try model.verifiedFiles(at: modelRoot)
        let embedder = try ONNXSpeakerEmbedder(model: model, directory: modelRoot)
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var embedded: [(Item, [Float])] = []
        for item in items {
            guard item.id.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil else { throw ValidationError("Invalid item id") }
            let pcm = try VoiceConsentAudio.pcm16k(Data(contentsOf: URL(fileURLWithPath: item.wav)))
            let ranges = try SpeakerVAD.ranges(pcm, model: files.vad)
            let speech = try SpeakerAudio.select(pcm, ranges: ranges)
            let features = includeFeatures && speech.count >= SpeakerAudio.windowSize ? try SpeakerAudio.windows(speech).map { try SpeakerAudio.features($0) } : nil
            let embedding = speech.count >= SpeakerAudio.windowSize ? try await SpeakerAudio.embedding(pcm, using: embedder) : nil
            if let embedding { embedded.append((item, embedding)) }
            let result = Result(id: item.id, ranges: ranges.map { [$0.lowerBound, $0.upperBound] }, features: features, embedding: embedding)
            try JSONEncoder().encode(result).write(to: directory.appendingPathComponent(item.id + ".json"), options: .atomic)
        }
        var scores: [Score] = []
        for (index, left) in embedded.enumerated() {
            for right in embedded.dropFirst(index + 1) where left.0.group == right.0.group {
                scores.append(Score(left: left.0.id, right: right.0.id, value: try VoiceSpeakerCheck.cosine(left.1, right.1)))
            }
        }
        try JSONEncoder().encode(scores).write(to: directory.appendingPathComponent("scores.json"), options: .atomic)
    }
}
#endif
