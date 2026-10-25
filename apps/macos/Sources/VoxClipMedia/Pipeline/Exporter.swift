import Foundation
import AVFoundation
import VideoToolbox
import VoxClipCore

private struct ExportPumpSource: @unchecked Sendable {
    let samples: ExportSampleReader
    let receiver: AVAssetWriterInput.SampleBufferReceiver
}

// Test seam at the composed writer input. No pixel buffer or sample buffer escapes the callback.
struct WriterBoundarySample: Sendable {
    let frame: Int64
    let pts: Double
    let rgb: [[Int]]
}

struct WriterBoundaryObservation: Sendable {
    let frames: Set<Int64>
    let points: [(x: Int, y: Int)]
    let receive: @Sendable (WriterBoundarySample) -> Void

    func capture(_ sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>, frame: Int64) throws -> WriterBoundarySample {
        try sample.withUnsafeSampleBuffer { raw in
            guard let buffer = CMSampleBufferGetImageBuffer(raw),
                  CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
                throw VoxClipError.decodeFailed("Observed writer input is not BGRA")
            }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            guard points.allSatisfy({ $0.x >= 0 && $0.x < width && $0.y >= 0 && $0.y < height }) else {
                throw VoxClipError.decodeFailed("Writer observation point is outside the frame")
            }
            let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
            guard status == kCVReturnSuccess else { throw VoxClipError.decodeFailed("Cannot lock writer input") }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
                throw VoxClipError.decodeFailed("Writer input has no base address")
            }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let rgb = points.map { point in
                let offset = point.y * stride + point.x * 4
                return [Int(base[offset + 2]), Int(base[offset + 1]), Int(base[offset])]
            }
            return WriterBoundarySample(frame: frame, pts: sample.presentationTimeStamp.seconds, rgb: rgb)
        }
    }
}

/// Native export implementation; architecture §5.6.
public actor AVExporter: Exporter {
    private let builder: CompositionBuilder
    private var busy = false
    private var waiting: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var activeID: UUID?
    private var activePumps: ExportPumpState?
    private let appendCheck: (@Sendable (Int, Int64) throws -> Void)?
    private let pumpObserver: (@Sendable (ExportPumpEvent) -> Void)?
    private let pullCheck: (@Sendable (Int) -> Void)?
    private let decodeCheck: (@Sendable (Int) -> Void)?
    private let writerObservation: WriterBoundaryObservation?
    public init() { builder = CompositionBuilder(); appendCheck = nil; pumpObserver = nil; pullCheck = nil; decodeCheck = nil; writerObservation = nil }
    public init(rasterizer: any CaptionRasterizer) { builder = CompositionBuilder(rasterizer: rasterizer); appendCheck = nil; pumpObserver = nil; pullCheck = nil; decodeCheck = nil; writerObservation = nil }
    init(appendCheck: @escaping @Sendable (Int, Int64) throws -> Void,
         pumpObserver: (@Sendable (ExportPumpEvent) -> Void)? = nil,
         pullCheck: (@Sendable (Int) -> Void)? = nil,
         decodeCheck: (@Sendable (Int) -> Void)? = nil,
         writerObservation: WriterBoundaryObservation? = nil) {
        builder = CompositionBuilder(); self.appendCheck = appendCheck; self.pumpObserver = pumpObserver; self.pullCheck = pullCheck
        self.decodeCheck = decodeCheck; self.writerObservation = writerObservation
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard busy else { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancelWaiting(id) } }
    }
    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().1.resume() }
    }

    public func export(_ job: ExportJob, progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        try await export(job, additionalOutputs: [], progress: progress)
    }

    package func export(_ job: ExportJob, additionalOutputs: [(partial: URL, destination: URL)],
                        progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        try await acquire()
        defer { release() }
        let id = UUID()
        activeID = id
        defer { activeID = nil; activePumps = nil }
        do {
            return try await withTaskCancellationHandler {
                try await perform(job, additionalOutputs: additionalOutputs, progress: progress)
            } onCancel: {
                Task { await self.cancelActive(id) }
            }
        } catch {
            if let failure = error as? VoxClipError, failure.requiresExportRecovery { throw failure }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ExportSafety.failure(error, destination: job.outputURL)
        }
    }

    private func cancelActive(_ id: UUID) {
        guard activeID == id else { return }
        activePumps?.stop()
    }

    private func perform(_ job: ExportJob, additionalOutputs: [(partial: URL, destination: URL)],
                         progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let destination = job.outputURL.standardizedFileURL.resolvingSymlinksInPath()
        try ExportSafety.validateDestination(destination)
        let reservedPartial = try ExportSafety.partialURL(for: destination)
        guard destination != job.render.sourceURL.standardizedFileURL.resolvingSymlinksInPath() else { throw VoxClipError.exportFailed("The export must not overwrite the source") }
        let srtURL = job.writeSRT ? (job.srtURL ?? destination.deletingPathExtension().appendingPathExtension("srt")).standardizedFileURL.resolvingSymlinksInPath() : nil
        if let sidecar = srtURL {
            try ExportSafety.validateDestination(sidecar)
            let sidecarPartial = try ExportSafety.partialURL(for: sidecar)
            guard sidecar != destination, sidecar != reservedPartial,
                  sidecarPartial != destination,
                  sidecar != job.render.sourceURL.standardizedFileURL.resolvingSymlinksInPath(),
                  sidecarPartial != job.render.sourceURL.standardizedFileURL.resolvingSymlinksInPath() else {
                throw VoxClipError.exportFailed("SRT destination overlaps the video")
            }
        }
        progress(ExportProgress(phase: .preparing, fraction: 0))
        let graph = try await builder.build(job.render)
        try Task.checkCancellation()
        let partial = try ExportSafety.preparePartial(for: destination)
        var srtPartial: URL?
        defer {
            try? FileManager.default.removeItem(at: partial)
            if let srtPartial { try? FileManager.default.removeItem(at: srtPartial) }
        }
        if let srtURL { srtPartial = try ExportSafety.preparePartial(for: srtURL) }
        let workDirectory = destination.deletingLastPathComponent().appendingPathComponent("voxclip-export-\(UUID().uuidString).partial")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let output = job.render.output
        let timeRange = CMTimeRange(start: .zero, duration: CMTime(value: job.render.plan.outputSamples, timescale: Int32(job.render.plan.sampleRate)))
        guard let videoComposition = graph.composition.copy() as? AVComposition,
              let videoTrack = videoComposition.track(withTrackID: graph.videoTrack.trackID) else {
            throw VoxClipError.decodeFailed("Cannot copy export video composition")
        }
        let videoReader = try AVAssetReader(asset: videoComposition)
        videoReader.timeRange = timeRange
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = graph.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        let videoProvider = videoReader.outputProvider(for: videoOutput)
        var audioReader: AVAssetReader?
        var audioProvider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>?
        if let track = graph.audioTrack {
            guard let composition = graph.composition.copy() as? AVComposition,
                  let audioTrack = composition.track(withTrackID: track.trackID) else {
                throw VoxClipError.decodeFailed("Cannot copy export audio composition")
            }
            let reader = try AVAssetReader(asset: composition)
            reader.timeRange = timeRange
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: MediaSupport.pcm(rate: 48000, channels: 2))
            audioOutput.audioMix = graph.audioMix
            audioOutput.alwaysCopiesSampleData = false
            audioProvider = reader.outputProvider(for: audioOutput)
            audioReader = reader
        }
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
        writer.directoryForTemporaryFiles = workDirectory
        writer.shouldOptimizeForNetworkUse = true
        writer.movieTimeScale = 48000
        let compression: [String: Any] = [AVVideoAverageBitRateKey: output.videoBitrate,
            AVVideoExpectedSourceFrameRateKey: output.fps, AVVideoMaxKeyFrameIntervalKey: Int(2 * output.fps),
            AVVideoAllowFrameReorderingKey: true, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC]
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: output.size.width,
            AVVideoHeightKey: output.size.height, AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: MediaSupport.colorProperties,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw VoxClipError.encoderUnavailable }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.mediaTimeScale = 600
        let videoReceiver = writer.inputReceiver(for: videoInput)
        var audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
        let hasAudio = audioReader != nil
        if hasAudio {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160000])
            audioReceiver = writer.inputReceiver(for: audioInput)
        }
        let pumps = ExportPumpState(observer: pumpObserver)
        activePumps = pumps
        let videoSamples = ExportSampleReader(reader: videoReader, provider: videoProvider, pump: 0, pumps: pumps, pullCheck: pullCheck, decodeCheck: decodeCheck)
        let audioSamples: ExportSampleReader?
        if let audioReader, let audioProvider {
            audioSamples = ExportSampleReader(reader: audioReader, provider: audioProvider, pump: 1, pumps: pumps, pullCheck: pullCheck, decodeCheck: decodeCheck)
        } else { audioSamples = nil }
        do {
            try Task.checkCancellation()
            guard writer.startWriting() else { throw writer.error ?? VoxClipError.exportFailed("Cannot start export") }
            writer.startSession(atSourceTime: .zero)
            let videoSource = ExportPumpSource(samples: videoSamples, receiver: videoReceiver)
            let audioSource: ExportPumpSource?
            if let audioSamples, let audioReceiver {
                audioSource = ExportPumpSource(samples: audioSamples, receiver: audioReceiver)
            } else { audioSource = nil }
            let (frames, audioSampleCount) = try await withThrowingTaskGroup(of: (Int, Int64).self) { group in
                group.addTask {
                    (0, try await self.pumpVideo(videoSource, duration: job.render.plan.duration,
                        frameLimit: Int64((job.render.plan.duration * output.fps).rounded()),
                        pumps: pumps, started: started, progress: progress))
                }
                group.addTask {
                    (1, try await self.pumpAudio(audioSource,
                        sampleLimit: Int64((job.render.plan.duration * 48000).rounded()), pumps: pumps))
                }
                var counts: [Int64] = [0, 0]
                do {
                    for try await (pump, count) in group { counts[pump] = count }
                } catch {
                    pumps.stop(error)
                    group.cancelAll()
                    throw pumps.failure ?? error
                }
                return (counts[0], counts[1])
            }
            videoSamples.cancelAfterJoining()
            audioSamples?.cancelAfterJoining()
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
            activePumps = nil
            progress(ExportProgress(phase: .finalizing, fraction: 1))
            try Task.checkCancellation()
            writer.endSession(atSourceTime: CMTime(value: job.render.plan.outputSamples, timescale: Int32(job.render.plan.sampleRate)))
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? VoxClipError.exportFailed("Encoder did not finish") }
            if let srtPartial {
                let sidecar = job.render.captionLayout.map { CaptionSubtitles.srt($0) } ?? Self.srt(job.render.captions)
                try sidecar.write(to: srtPartial, atomically: true, encoding: .utf8)
            }
            try Task.checkCancellation()
            var outputs = [(partial: partial, destination: destination)]
            if let srtPartial, let srtURL { outputs.append((srtPartial, srtURL)) }
            try ExportSafety.publishAll(outputs + additionalOutputs)
            let elapsed = started.duration(to: .now).components
            return ExportResult(outputURL: destination, srtURL: srtURL, durationSeconds: job.render.plan.duration,
                                width: output.size.width, height: output.size.height, fps: output.fps, frames: frames,
                                audioSampleRate: 48000, audioSamples: audioSampleCount,
                                videoCodec: "h264", encoder: "h264_videotoolbox",
                                elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        } catch {
            pumps.stop(error)
            videoSamples.cancelAfterJoining()
            audioSamples?.cancelAfterJoining()
            if writer.status == .writing {
                pumps.writerWillCancel()
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: partial)
            if let failure = error as? VoxClipError, failure.requiresExportRecovery { throw failure }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ExportSafety.failure(error, destination: destination)
        }
    }

    private nonisolated func pumpVideo(_ source: ExportPumpSource,
                           duration: Double, frameLimit: Int64,
                           pumps: ExportPumpState, started: ContinuousClock.Instant,
                           progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> Int64 {
        let receiver = source.receiver
        do {
            try Task.checkCancellation()
            try pumps.checkRunning()
            try source.samples.start()
            var frames: Int64 = 0
            var lastProgress = started
            while true {
                try Task.checkCancellation()
                try pumps.checkRunning()
                guard let sample = try await source.samples.next() else { break }
                try pumps.checkRunning()
                if frames >= frameLimit { continue }
                try Task.checkCancellation()
                try appendCheck?(0, frames)
                try pumps.checkRunning()
                var observed: WriterBoundarySample?
                while try !pumps.append({
                    observed = try writerObservation?.frames.contains(frames) == true
                        ? writerObservation?.capture(sample, frame: frames) : nil
                    return try receiver.appendImmediately(sample)
                }) {
                    try Task.checkCancellation()
                    try pumps.checkRunning()
                    try await Task.sleep(for: .milliseconds(1))
                }
                if let observed { writerObservation?.receive(observed) }
                frames += 1
                if lastProgress.duration(to: .now) >= .milliseconds(100) {
                    progress(ExportProgress(phase: .encoding, fraction: min(1, max(0, sample.presentationTimeStamp.seconds / duration))))
                    lastProgress = .now
                }
            }
            pumps.finishInput { receiver.finish() }
            return frames
        } catch {
            pumps.stop(error)
            throw error
        }
    }

    private nonisolated func pumpAudio(_ source: ExportPumpSource?, sampleLimit: Int64,
                           pumps: ExportPumpState) async throws -> Int64 {
        guard let source else { return 0 }
        let receiver = source.receiver
        do {
            try Task.checkCancellation()
            try pumps.checkRunning()
            try source.samples.start()
            var frames: Int64 = 0
            while true {
                try Task.checkCancellation()
                try pumps.checkRunning()
                guard let sample = try await source.samples.next() else { break }
                try pumps.checkRunning()
                let count = min(Int64(sample.sampleCount), max(0, sampleLimit - frames))
                guard count > 0 else { continue }
                let accepted = count == sample.sampleCount ? [sample] : Array(sample.splitSamples().prefix(Int(count)))
                for buffer in accepted {
                    try appendCheck?(1, frames)
                    try pumps.checkRunning()
                    while try !pumps.append({ try receiver.appendImmediately(buffer) }) {
                        try Task.checkCancellation()
                        try pumps.checkRunning()
                        try await Task.sleep(for: .milliseconds(1))
                    }
                }
                frames += count
            }
            while frames < sampleLimit, !pumps.stopped {
                try Task.checkCancellation()
                let count = Int(min(8192, sampleLimit - frames))
                let silence = try MediaSupport.silentExportAudio(start: frames, count: count)
                try appendCheck?(1, frames)
                try pumps.checkRunning()
                while try !pumps.append({ try receiver.appendImmediately(silence) }) {
                    try Task.checkCancellation()
                    try pumps.checkRunning()
                    try await Task.sleep(for: .milliseconds(1))
                }
                frames += Int64(count)
            }
            pumps.finishInput { receiver.finish() }
            return frames
        } catch {
            pumps.stop(error)
            throw error
        }
    }

    static func srt(_ track: CaptionTrack) -> String {
        func timestamp(_ time: Double) -> String {
            let milliseconds = max(0, Int((time * 1000).rounded()))
            return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3600000,
                          milliseconds / 60000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
        }
        return track.pages.filter { $0.end > $0.start }.enumerated().map { index, page in
            let validLines = !page.lines.isEmpty && page.lines.allSatisfy { line in
                line.words.allSatisfy { track.words.indices.contains($0) }
            }
            let text = !validLines ? page.words.map(\.text).joined(separator: " ") : page.lines.map { line in
                line.words.map { track.words[$0].text }.joined(separator: " ")
            }.joined(separator: "\n")
            return "\(index + 1)\n\(timestamp(page.start)) --> \(timestamp(page.end))\n\(text)\n"
        }.joined(separator: "\n")
    }

    public func writeEditedAudio(_ request: RenderRequest, to destination: URL) async throws {
        let partial = try await stageEditedAudio(request, to: destination)
        defer { try? FileManager.default.removeItem(at: partial) }
        do {
            try Task.checkCancellation()
            try ExportSafety.publish(partial, to: destination.standardizedFileURL.resolvingSymlinksInPath())
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ExportSafety.failure(error, destination: destination)
        }
    }

    package func stageEditedAudio(_ request: RenderRequest, to destination: URL) async throws -> URL {
        try await acquire(); defer { release() }
        let id = UUID()
        activeID = id
        defer { activeID = nil; activePumps = nil }
        do {
            return try await withTaskCancellationHandler {
                try await performEditedAudio(request, to: destination)
            } onCancel: { Task { await self.cancelActive(id) } }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let failure = ExportSafety.failure(error, destination: destination)
            switch failure {
            case .diskFull: throw VoxClipError.diskFull(destination.path)
            case .exportFailed(let details): throw VoxClipError.exportFailed("\(destination.path): \(details)")
            default: throw failure
            }
        }
    }

    private func performEditedAudio(_ request: RenderRequest, to destination: URL) async throws -> URL {
        try Task.checkCancellation()
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        try ExportSafety.validateDestination(destination)
        _ = try ExportSafety.partialURL(for: destination)
        guard destination != request.sourceURL.standardizedFileURL.resolvingSymlinksInPath() else { throw VoxClipError.exportFailed("Unsafe audio destination") }
        let graph = try await builder.build(request)
        guard let track = graph.audioTrack else { throw VoxClipError.noAudioTrack }
        let reader = try AVAssetReader(asset: graph.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: MediaSupport.pcm(rate: request.plan.sampleRate, channels: 2))
        output.audioMix = graph.audioMix; output.alwaysCopiesSampleData = false
        let provider = reader.outputProvider(for: output)
        let temporary = try ExportSafety.preparePartial(for: destination)
        var prepared = false
        defer { if !prepared { try? FileManager.default.removeItem(at: temporary) } }
        let wav = try PCMFile(url: temporary, rate: Int(request.plan.sampleRate), channels: 2, float: true)
        do {
            guard reader.startReading() else { throw VoxClipError.decodeFailed("Cannot read edited audio") }
            while let ready = try await MediaSupport.nextSample(provider) {
                try Task.checkCancellation()
                let data = try ready.withUnsafeSampleBuffer { sample -> Data in
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { throw VoxClipError.decodeFailed("Missing PCM data") }
                    var data = Data(count: CMBlockBufferGetDataLength(block))
                    let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                    guard status == noErr else { throw VoxClipError.decodeFailed("Cannot copy PCM") }
                    return data
                }
                try wav.append(data)
            }
            try Task.checkCancellation()
            guard reader.status == .completed else { throw VoxClipError.decodeFailed(reader.error?.localizedDescription ?? "Edited audio did not finish") }
            let deficit = request.plan.outputSamples - wav.frames
            if deficit > 0, let last = request.plan.kept.last {
                let sourceEnd = try await decodedSourceAudioEnd(request)
                let missingTail = max(0, last.endSample - max(last.startSample, sourceEnd))
                if deficit == missingTail {
                    try Task.checkCancellation()
                    try wav.finish(expectedFrames: request.plan.outputSamples)
                } else {
                    throw VoxClipError.exportFailed("Edited audio has \(wav.frames) samples, expected \(request.plan.outputSamples)")
                }
            } else {
                try wav.finish()
            }
            guard wav.frames == request.plan.outputSamples else {
                throw VoxClipError.exportFailed("Edited audio has \(wav.frames) samples, expected \(request.plan.outputSamples)")
            }
            prepared = true
            return temporary
        } catch {
            reader.cancelReading(); try? wav.handle.close(); try? FileManager.default.removeItem(at: temporary)
            if Task.isCancelled { throw CancellationError() }
            throw ExportSafety.failure(error, destination: destination)
        }
    }

    private func decodedSourceAudioEnd(_ request: RenderRequest) async throws -> Int64 {
        let asset = AVURLAsset(url: request.sourceURL)
        guard let track = try await MediaSupport.audioTrack(in: asset) else { throw VoxClipError.noAudioTrack }
        let range = try await track.load(.timeRange)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: max(range.start, range.end - CMTime(seconds: 1, preferredTimescale: 48000)), end: range.end)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: request.plan.sampleRate, channels: 2))
        output.alwaysCopiesSampleData = false
        let provider = reader.outputProvider(for: output)
        guard reader.startReading() else { throw VoxClipError.decodeFailed("Cannot verify the source audio tail") }
        defer { reader.cancelReading() }
        var end: Int64?
        while let sample = try await MediaSupport.nextSample(provider) {
            try Task.checkCancellation()
            end = Int64((sample.presentationTimeStamp.seconds * request.plan.sampleRate).rounded()) + Int64(sample.sampleCount)
        }
        guard reader.status == .completed, let end else { throw VoxClipError.decodeFailed("Cannot verify the source audio tail") }
        return end
    }
}

/// Sequential per-window exports; architecture §7.1.
public actor ExportQueue: Exporter {
    private let exporter: any Exporter
    private var busy = false
    private var waiting: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var continuations: [UUID: AsyncStream<ExportProgress>.Continuation] = [:]
    public init(exporter: any Exporter = AVExporter()) { self.exporter = exporter }
    public func export(_ job: ExportJob, progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        try Task.checkCancellation()
        if busy {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waiting.append((id, continuation)) }
                }
            } onCancel: { Task { await self.cancelWaiting(id) } }
        }
        busy = true
        defer { if waiting.isEmpty { busy = false } else { waiting.removeFirst().1.resume() } }
        try Task.checkCancellation()
        let listeners = Array(continuations.values)
        return try await exporter.export(job) { value in
            progress(value)
            for continuation in listeners { continuation.yield(value) }
        }
    }
    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    public func progress() -> AsyncStream<ExportProgress> {
        let id = UUID()
        let stream = AsyncStream<ExportProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = stream.continuation
        stream.continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream.stream
    }
    private func remove(_ id: UUID) { continuations.removeValue(forKey: id) }
}
