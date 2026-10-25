import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

private actor GatedExporter: Exporter {
    private(set) var started: [String] = []
    private var pending: [CheckedContinuation<Void, Never>] = []

    func export(_ job: ExportJob, progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        started.append(job.outputURL.lastPathComponent)
        await withCheckedContinuation { pending.append($0) }
        return ExportResult(outputURL: job.outputURL, durationSeconds: 1, width: 320, height: 180,
            fps: 30, frames: 30, audioSampleRate: 48000, audioSamples: 48000,
            videoCodec: "h264", encoder: "test", elapsedSeconds: 0)
    }

    func finish() { pending.removeFirst().resume() }
}

@Test(.timeLimit(.minutes(1))) func exportQueueSerializesAndCancelsWaitingJobs() async throws {
    let exporter = GatedExporter()
    let queue = ExportQueue(exporter: exporter)
    let render = RenderRequest(sourceURL: URL(fileURLWithPath: "/unused.mov"), plan: EditPlan(sampleRate: 48000, totalSamples: 48000, kept: [MediaInterval(startSample: 0, endSample: 48000)]),
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    let first = Task { try await queue.export(ExportJob(render: render, outputURL: URL(fileURLWithPath: "/first.mp4"))) { _ in } }
    while await exporter.started.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
    let cancelled = Task { try await queue.export(ExportJob(render: render, outputURL: URL(fileURLWithPath: "/cancelled.mp4"))) { _ in } }
    try await Task.sleep(for: .milliseconds(20))
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let last = Task { try await queue.export(ExportJob(render: render, outputURL: URL(fileURLWithPath: "/last.mp4"))) { _ in } }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await exporter.started == ["first.mp4"])
    await exporter.finish()
    _ = try await first.value
    while await exporter.started.count < 2 { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await exporter.started == ["first.mp4", "last.mp4"])
    await exporter.finish()
    _ = try await last.value
}

@Test(.timeLimit(.minutes(1))) func chirpCutsKeepCrossCorrelationWithinOneMillisecond() async throws {
    let source = try await NativeMediaFixtures.shared.file("chirp.mov")
    let total: Int64 = 30 * 48000
    var kept: [MediaInterval] = []
    var joins: [Join] = []
    var cursor: Int64 = 0
    var outputSamples: Int64 = 0
    for filler in 0..<17 {
        let start = Int64((0.2 + 0.5 * Double(2 + 3 * filler)) * 48000)
        kept.append(MediaInterval(startSample: cursor, endSample: start))
        outputSamples += start - cursor
        joins.append(Join(outSample: outputSamples, fadeOutLen: 240, fadeInLen: 240))
        cursor = start + 12000
    }
    kept.append(MediaInterval(startSample: cursor, endSample: total))
    outputSamples += total - cursor
    let plan = EditPlan(sampleRate: 48000, totalSamples: total, kept: kept)
    #expect(plan.outputSamples == outputSamples)
    #expect(plan.joins == joins)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-chirp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("edited.wav")
    let render = RenderRequest(sourceURL: source, plan: plan,
        output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
    try await AVExporter().writeEditedAudio(render, to: destination)
    let samples = try Data(contentsOf: destination).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    #expect(samples.count == Int(outputSamples) * 2)
    for fraction in [0.08, 0.5, 0.94] {
        let center = Int64((fraction * Double(outputSamples)).rounded())
        var outputStart: Int64 = 0
        var sourceCenter: Int64 = 0
        for interval in kept {
            if center < outputStart + interval.count {
                sourceCenter = interval.startSample + center - outputStart
                break
            }
            outputStart += interval.count
        }
        var bestLag = 0
        var bestScore = -Double.infinity
        for lag in -96...96 {
            var score = 0.0
            for offset in -1024..<1024 {
                let time = Double(sourceCenter + Int64(offset + lag)) / 48000
                let expected = 0.3 * sin(2 * .pi * (200 * time + 1800 * time * time / 60))
                score += Double(samples[(Int(center) + offset) * 2]) * expected
            }
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        #expect(abs(bestLag) < 48, "fraction=\(fraction), lag=\(bestLag)")
    }
}
