#if DEBUG
import ArgumentParser
import Foundation
import VoxClipCore
import VoxClipMedia

struct SpeakerDiagnostic: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "speaker-diagnostic", abstract: "Offline S6 calibration preprocessing; never downloads.")
    @Option var input: String
    @Option var vad: String
    @Option var output: String
    struct Item: Codable { let id: String; let wav: String }
    struct Result: Codable { let id: String; let ranges: [[Int]]; let features: [[Float]] }
    func run() async throws {
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for item in items {
            guard item.id.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil else { throw ValidationError("Invalid item id") }
            let pcm = try VoiceConsentAudio.pcm16k(Data(contentsOf: URL(fileURLWithPath: item.wav)))
            let ranges = try SpeakerVAD.ranges(pcm, model: URL(fileURLWithPath: vad))
            let speech = try SpeakerAudio.select(pcm, ranges: ranges)
            let features = speech.count >= SpeakerAudio.windowSize ? try SpeakerAudio.windows(speech).map { try SpeakerAudio.features($0) } : []
            let result = Result(id: item.id, ranges: ranges.map { [$0.lowerBound, $0.upperBound] }, features: features)
            try JSONEncoder().encode(result).write(to: directory.appendingPathComponent(item.id + ".json"), options: .atomic)
        }
    }
}
#endif
