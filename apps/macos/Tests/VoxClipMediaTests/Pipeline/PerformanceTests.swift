import Foundation
import Testing
import VoxClipCore
import VoxClipMedia

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_MEDIA_BENCHMARK_DIR"] != nil), .timeLimit(.minutes(3)))
func benchmarkSixtySecondPortraitExport() async throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VOXCLIP_MEDIA_BENCHMARK_DIR"]), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let generated = try await NativeMediaFixtures.shared.file("benchmark.mov")
    let source = directory.appendingPathComponent("benchmark-source.mov")
    let outputURL = directory.appendingPathComponent("native-benchmark.mp4")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: outputURL)
    }
    try FileManager.default.copyItem(at: generated, to: source)
    let transcript = Transcript(durationSeconds: 60, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
        rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    try ProjectJSON.encoder().encode(transcript).write(to: directory.appendingPathComponent("benchmark-transcript.json"))
    let plan = EditPlan(sampleRate: 48000, totalSamples: 2880000,
        kept: [MediaInterval(startSample: 0, endSample: 2880000)])
    let probe = try await AVMediaProbe().probe(source)
    #expect(probe.orientedSize == PixelSize(width: 1920, height: 1080))
    let output = try OutputSpec.resolved(source: probe, aspect: .portrait)
    let render = RenderRequest(sourceURL: source, plan: plan, output: output)
    let result = try await AVExporter().export(ExportJob(render: render, outputURL: outputURL)) { _ in }
    #expect(result.width == 1080 && result.height == 1920)
    #expect(result.frames == 1800 && result.audioSamples == 2880000)
    try ProjectJSON.encoder().encode(result).write(to: directory.appendingPathComponent("native-benchmark.json"))
    print("PORTRAIT_BENCHMARK_SECONDS=\(result.elapsedSeconds)")
}
