import Foundation
import AVFoundation
import VideoToolbox
import Darwin
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
    private let appVersion: String?
    private let capacityProvider: DiskCapacity.Provider
    public init(appVersion: String? = nil) { builder = CompositionBuilder(); appendCheck = nil; pumpObserver = nil; pullCheck = nil; decodeCheck = nil; writerObservation = nil; self.appVersion = appVersion; capacityProvider = DiskCapacity.systemVolume }
    public init(rasterizer: any CaptionRasterizer, appVersion: String? = nil) { builder = CompositionBuilder(rasterizer: rasterizer); appendCheck = nil; pumpObserver = nil; pullCheck = nil; decodeCheck = nil; writerObservation = nil; self.appVersion = appVersion; capacityProvider = DiskCapacity.systemVolume }
    init(capacityProvider: @escaping DiskCapacity.Provider, scratchRoot: URL = FileManager.default.temporaryDirectory, appVersion: String? = nil) {
        builder = CompositionBuilder(scratchRoot: scratchRoot); appendCheck = nil; pumpObserver = nil; pullCheck = nil
        decodeCheck = nil; writerObservation = nil; self.appVersion = appVersion; self.capacityProvider = capacityProvider
    }
    init(appendCheck: @escaping @Sendable (Int, Int64) throws -> Void,
         pumpObserver: (@Sendable (ExportPumpEvent) -> Void)? = nil,
         pullCheck: (@Sendable (Int) -> Void)? = nil,
         decodeCheck: (@Sendable (Int) -> Void)? = nil,
         writerObservation: WriterBoundaryObservation? = nil,
         appVersion: String? = nil) {
        builder = CompositionBuilder(); self.appendCheck = appendCheck; self.pumpObserver = pumpObserver; self.pullCheck = pullCheck
        self.decodeCheck = decodeCheck; self.writerObservation = writerObservation; self.appVersion = appVersion
        capacityProvider = DiskCapacity.systemVolume
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
            if error is VoiceLabRenderCapabilityError { throw error }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ExportSafety.failure(error, destination: job.outputURL)
        }
    }

    private func cancelActive(_ id: UUID) {
        guard activeID == id else { return }
        activePumps?.stop()
    }

    private struct TransactionPreflight {
        let destination: URL
        let marked: Bool
        let provenanceURL: URL?
        let provenancePartial: URL?
        let srtURL: URL?
        let srtText: String?
        let sidecarLimit: Int64
        let outputNeeds: [DiskCapacity.Need]
    }

    /// The CLI calls this before staging WAV. Export calls the same calculation
    /// after the WAV partial exists, when free space already reflects its bytes.
    package func preflightCombinedExport(_ job: ExportJob, editedAudioURL: URL) throws {
        _ = try transactionPreflight(job, additionalOutputs: [], plannedEditedAudioURL: editedAudioURL)
    }

    private func transactionPreflight(_ job: ExportJob,
        additionalOutputs: [(partial: URL, destination: URL)], plannedEditedAudioURL: URL?) throws -> TransactionPreflight {
        let destination = job.outputURL.standardizedFileURL.resolvingSymlinksInPath()
        try ExportSafety.validateDestination(destination)
        let reservedPartial = try ExportSafety.partialURL(for: destination)
        let marked = job.render.voiceLab?.prepared.disclosure.required == true
        if marked { _ = try Self.resolvedAppVersion(explicit: appVersion) }
        let provenanceURL = marked ? URL(fileURLWithPath: destination.path + ".provenance.json") : nil
        let provenancePartial = try provenanceURL.map { url -> URL in
            try ExportSafety.validateDestination(url)
            return try ExportSafety.partialURL(for: url)
        }
        let source = job.render.sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard destination != source else { throw VoxClipError.exportFailed("The export must not overwrite the source") }
        let srtURL = job.writeSRT ? (job.srtURL ?? destination.deletingPathExtension().appendingPathExtension("srt")).standardizedFileURL.resolvingSymlinksInPath() : nil
        let srtText = srtURL == nil ? nil : (job.render.captionLayout.map { CaptionSubtitles.srt($0) } ?? Self.srt(job.render.captions))
        if let sidecar = srtURL {
            try ExportSafety.validateDestination(sidecar)
            let sidecarPartial = try ExportSafety.partialURL(for: sidecar)
            guard sidecar != destination, sidecar != reservedPartial,
                  sidecarPartial != destination, sidecar != source,
                  sidecarPartial != source else {
                throw VoxClipError.exportFailed("SRT destination overlaps the video")
            }
        }
        let primary = [(destination, reservedPartial)] +
            (srtURL.map { [($0, URL(fileURLWithPath: $0.path + ".partial"))] } ?? []) +
            (provenanceURL.flatMap { url in provenancePartial.map { [(url, $0)] } } ?? [])
        var extras = additionalOutputs
        if let plannedEditedAudioURL {
            let wav = plannedEditedAudioURL.standardizedFileURL.resolvingSymlinksInPath()
            extras.append((try ExportSafety.partialURL(for: wav), wav))
        }
        let allPaths = primary.flatMap { [$0.0, $0.1] } + extras.flatMap { [$0.partial, $0.destination] }
        let normalized = allPaths.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        guard Set(normalized).count == normalized.count, !normalized.contains(source.path) else {
            throw VoxClipError.exportFailed("Export outputs overlap")
        }
        if let input = job.render.voiceLab { try Self.preventPaidOverwrite(input, paths: allPaths) }
        for extra in extras {
            try ExportSafety.validateDestination(extra.destination)
            _ = try ExportSafety.partialURL(for: extra.destination)
        }
        try VoiceLabRenderPreflight.validate(job.render)
        guard job.render.timeline.outputSamples > 0 else { throw VoxClipError.everythingCut }
        let plannedWAVBytes = try plannedEditedAudioURL.map { _ in
            try PCMFile.plannedBytes(frames: job.render.timeline.outputSamples, channels: 2, bits: 32)
        }
        let estimate = job.render.timeline.duration * (Double(job.render.output.videoBitrate) + 192_000) / 8 * 1.5
        guard estimate.isFinite, estimate > 0, estimate < Double(Int64.max / 4) else {
            throw VoxClipError.diskFull(destination.path)
        }
        let mp4Bytes = Int64(ceil(estimate))
        let outputBytes = try DiskCapacity.checkedMultiply(mp4Bytes, marked ? 3 : 2, at: destination)
        let sidecarLimit: Int64 = 16 * 1024 * 1024
        var needs = [DiskCapacity.Need(directory: destination.deletingLastPathComponent(), bytes: outputBytes)]
        for path in primary.map({ $0.0 }) + extras.map(\.destination) {
            needs.append(.init(directory: path.deletingLastPathComponent(), bytes: try DiskCapacity.fileBytes(path)))
        }
        if let srtURL, let srtText { needs.append(.init(directory: srtURL.deletingLastPathComponent(), bytes: Int64(srtText.utf8.count))) }
        if let provenanceURL { needs.append(.init(directory: provenanceURL.deletingLastPathComponent(), bytes: sidecarLimit)) }
        if let plannedEditedAudioURL, let plannedWAVBytes {
            needs.append(.init(directory: plannedEditedAudioURL.deletingLastPathComponent(), bytes: plannedWAVBytes))
        }
        let outputNeeds = needs
        if let input = job.render.voiceLab, input.prepared.outputPlan.requiresSyntheticRendering {
            needs.append(.init(directory: builder.scratchRoot,
                               bytes: try VoiceLabAudioRenderer.scratchBytes(input: input)))
        }
        try DiskCapacity.check(needs, provider: capacityProvider)
        return TransactionPreflight(destination: destination, marked: marked, provenanceURL: provenanceURL,
                                    provenancePartial: provenancePartial, srtURL: srtURL, srtText: srtText,
                                    sidecarLimit: sidecarLimit, outputNeeds: outputNeeds)
    }

    private func perform(_ job: ExportJob, additionalOutputs: [(partial: URL, destination: URL)],
                         progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let preflight = try transactionPreflight(job, additionalOutputs: additionalOutputs, plannedEditedAudioURL: nil)
        let destination = preflight.destination
        let marked = preflight.marked
        let provenanceURL = preflight.provenanceURL
        let provenancePartial = preflight.provenancePartial
        let srtURL = preflight.srtURL
        let srtText = preflight.srtText
        let sidecarLimit = preflight.sidecarLimit
        let outputNeeds = preflight.outputNeeds
        progress(ExportProgress(phase: .preparing, fraction: 0))
        let graph = try await builder.build(job.render)
        defer { withExtendedLifetime(graph.voiceLabLease) {} }
        try DiskCapacity.check(outputNeeds, provider: capacityProvider)
        try Task.checkCancellation()
        let partial = try ExportSafety.preparePartial(for: destination)
        var srtPartial: URL?
        var ownsProvenancePartial = false
        defer {
            try? FileManager.default.removeItem(at: partial)
            if let srtPartial { try? FileManager.default.removeItem(at: srtPartial) }
            if ownsProvenancePartial, let provenancePartial { try? FileManager.default.removeItem(at: provenancePartial) }
        }
        if let srtURL { srtPartial = try ExportSafety.preparePartial(for: srtURL) }
        let workDirectory = destination.deletingLastPathComponent().appendingPathComponent("voxclip-export-\(UUID().uuidString).partial")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let output = job.render.output
        let timeRange = CMTimeRange(start: .zero, duration: CMTime(value: job.render.timeline.outputSamples, timescale: Int32(job.render.timeline.sampleRate)))
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
                    (0, try await self.pumpVideo(videoSource, duration: job.render.timeline.duration,
                        frameLimit: Int64((job.render.timeline.duration * output.fps).rounded()),
                        pumps: pumps, started: started, progress: progress))
                }
                group.addTask {
                    (1, try await self.pumpAudio(audioSource,
                        sampleLimit: Int64((job.render.timeline.duration * 48000).rounded()), pumps: pumps))
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
            writer.endSession(atSourceTime: CMTime(value: job.render.timeline.outputSamples, timescale: Int32(job.render.timeline.sampleRate)))
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? VoxClipError.exportFailed("Encoder did not finish") }
            if let srtPartial, let srtText {
                try srtText.write(to: srtPartial, atomically: true, encoding: .utf8)
            }
            try Task.checkCancellation()
            var outputs = [(partial: partial, destination: destination)]
            if let input = job.render.voiceLab, marked, let provenanceURL, let provenancePartial {
                try Self.reserveDisclosureCopy(partial)
                let stagedMP4 = workDirectory.appendingPathComponent("marked.mp4")
                let disclosure = try VoiceLabDisclosureWriter.stage(sourceMP4: partial, stagedMP4: stagedMP4,
                    finalFilename: destination.lastPathComponent, project: input.project, prepared: input.prepared,
                    appVersion: try Self.resolvedAppVersion(explicit: appVersion))
                guard disclosure.sidecarFilename == provenanceURL.lastPathComponent else {
                    throw VoiceLabDisclosureError.invalidMP4
                }
                guard disclosure.sidecarData.count <= sidecarLimit else { throw VoxClipError.diskFull(provenanceURL.path) }
                let descriptor = Darwin.open(provenancePartial.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                ownsProvenancePartial = true
                let sidecar = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                try sidecar.write(contentsOf: disclosure.sidecarData)
                try sidecar.synchronize()
                try sidecar.close()
                outputs[0].partial = disclosure.mp4URL
                outputs.append((provenancePartial, provenanceURL))
            }
            if let srtPartial, let srtURL { outputs.append((srtPartial, srtURL)) }
            let rollbackNeeds = try (outputs + additionalOutputs).map { output in
                DiskCapacity.Need(directory: output.destination.deletingLastPathComponent(),
                                  bytes: try DiskCapacity.fileBytes(output.destination))
            }
            try DiskCapacity.check(rollbackNeeds, provider: capacityProvider)
            try ExportSafety.publishAll(outputs + additionalOutputs)
            let elapsed = started.duration(to: .now).components
            return ExportResult(outputURL: destination, srtURL: srtURL, durationSeconds: job.render.timeline.duration,
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

    private nonisolated static func reserveDisclosureCopy(_ source: URL) throws {
        let bytes = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard bytes > 0 else { throw VoxClipError.diskFull(source.path) }
        try DiskCapacity.check([.init(directory: source.deletingLastPathComponent(), bytes: bytes)])
    }

    static func resolvedAppVersion(explicit: String?, bundle: Bundle = .main) throws -> String {
        guard let version = explicit ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty, version != "0.0.0", !version.contains("/"), !version.contains("\\") else {
            throw VoxClipError.exportFailed("App version is unavailable for provenance")
        }
        return version
    }

    private nonisolated static func preventPaidOverwrite(_ input: VoiceLabRenderInput, paths: [URL]) throws {
        let outputs = Set(paths.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        for asset in input.project.voiceLab.assets ?? [] {
            let paid = input.paidRoot.appendingPathComponent(asset.file).standardizedFileURL.resolvingSymlinksInPath().path
            guard !outputs.contains(paid) else { throw VoxClipError.exportFailed("Export must not overwrite a Voice Lab asset") }
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
            if error is VoiceLabRenderCapabilityError { throw error }
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
            if error is VoiceLabRenderCapabilityError { throw error }
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
        if let input = request.voiceLab {
            try Self.preventPaidOverwrite(input, paths: [destination, URL(fileURLWithPath: destination.path + ".partial")])
        }
        let synthetic = request.voiceLab?.prepared.outputPlan.requiresSyntheticRendering == true
        guard request.timeline.outputSamples >= 0 else { throw VoxClipError.diskFull(destination.path) }
        let bytes = try PCMFile.plannedBytes(frames: request.timeline.outputSamples, channels: 2, bits: 32)
        var needs = [DiskCapacity.Need(directory: destination.deletingLastPathComponent(),
                                       bytes: try DiskCapacity.checkedAdd(bytes, DiskCapacity.fileBytes(destination), at: destination))]
        if synthetic, let input = request.voiceLab {
            needs.append(.init(directory: builder.scratchRoot,
                               bytes: try VoiceLabAudioRenderer.scratchBytes(input: input)))
        }
        try DiskCapacity.check(needs, provider: capacityProvider)
        let graph = try await builder.build(request)
        defer { withExtendedLifetime(graph.voiceLabLease) {} }
        guard let track = graph.audioTrack else { throw VoxClipError.noAudioTrack }
        let reader = try AVAssetReader(asset: graph.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: MediaSupport.pcm(rate: request.timeline.sampleRate, channels: 2))
        output.audioMix = graph.audioMix; output.alwaysCopiesSampleData = false
        let provider = reader.outputProvider(for: output)
        let temporary = try ExportSafety.preparePartial(for: destination)
        var prepared = false
        defer { if !prepared { try? FileManager.default.removeItem(at: temporary) } }
        let wav = try PCMFile(url: temporary, rate: Int(request.timeline.sampleRate), channels: 2, float: true)
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
            let deficit = request.timeline.outputSamples - wav.frames
            if !synthetic, deficit > 0, let last = request.plan.kept.last {
                let sourceEnd = try await decodedSourceAudioEnd(request)
                let missingTail = max(0, last.endSample - max(last.startSample, sourceEnd))
                if deficit == missingTail {
                    try Task.checkCancellation()
                    try wav.finish(expectedFrames: request.timeline.outputSamples)
                } else {
                    throw VoxClipError.exportFailed("Edited audio has \(wav.frames) samples, expected \(request.timeline.outputSamples)")
                }
            } else {
                try wav.finish()
            }
            guard wav.frames == request.timeline.outputSamples else {
                throw VoxClipError.exportFailed("Edited audio has \(wav.frames) samples, expected \(request.timeline.outputSamples)")
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
