import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Synchronization

final class ContextDemoRecordingEvents: Sendable {
    let value = Mutex(ContextDemoCaptureSnapshot())
}

private final class ContextDemoRecordingDelegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    let events: ContextDemoRecordingEvents
    init(_ events: ContextDemoRecordingEvents) { self.events = events }
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        events.value.withLock { $0.started = true }
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        events.value.withLock { $0.finished = true }
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        events.value.withLock { $0.error = ContextDemoScreenCapture.map(error); $0.finished = true }
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        events.value.withLock { $0.error = ContextDemoScreenCapture.map(error); $0.stopped = true }
    }
}

@MainActor final class ContextDemoScreenCapture: ContextDemoCaptureBackend {
    private var stream: SCStream?
    private var recording: SCRecordingOutput?
    private var delegate: ContextDemoRecordingDelegate?
    private var events = ContextDemoRecordingEvents()
    private var stopping = false
    private var stopRequested = false
    private var activeTarget: ContextDemoCaptureTarget?

    func availability() -> ContextDemoCaptureAvailability {
        CGPreflightScreenCaptureAccess() ? .available : .screenRecordingPermissionRequired
    }

    func windows() async throws -> [ContextDemoCaptureTarget] {
        guard availability() == .available else { throw ContextDemoCaptureError.permissionRequired }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            return content.windows.compactMap(Self.binding).sorted { $0.windowID < $1.windowID }
        } catch is CancellationError { throw CancellationError() }
        catch { throw Self.map(error) }
    }

    private static func binding(_ window: SCWindow) -> ContextDemoCaptureTarget? {
        guard window.windowLayer == 0, window.isOnScreen, window.frame.width >= 2, window.frame.height >= 2,
              let owner = window.owningApplication, !owner.bundleIdentifier.isEmpty,
              let application = NSRunningApplication(processIdentifier: owner.processID),
              let launched = application.launchDate, !application.isTerminated else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return ContextDemoCaptureTarget(windowID: window.windowID, processID: owner.processID,
            bundleIdentifier: owner.bundleIdentifier, applicationName: owner.applicationName,
            windowTitle: window.title ?? "", processLaunchDate: launched,
            widthPoints: Double(filter.contentRect.width), heightPoints: Double(filter.contentRect.height),
            pixelScale: Double(filter.pointPixelScale))
    }

    func begin(window: ContextDemoCaptureTarget, output: URL, width: Int, height: Int) async throws {
        guard stream == nil else { throw ContextDemoCaptureError.alreadyRecording }
        guard availability() == .available else { throw ContextDemoCaptureError.permissionRequired }
        events = ContextDemoRecordingEvents(); stopping = false; stopRequested = false
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard !stopRequested else { throw CancellationError() }
            guard let selected = content.windows.first(where: { $0.windowID == window.windowID }),
                  Self.binding(selected) == window else { throw ContextDemoCaptureError.staleReview }
            let filter = SCContentFilter(desktopIndependentWindow: selected)
            let configuration = SCStreamConfiguration()
            configuration.width = width; configuration.height = height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.captureMicrophone = false
            configuration.excludesCurrentProcessAudio = true
            configuration.includeChildWindows = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.scalesToFit = true
            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = output
            outputConfiguration.videoCodecType = .h264
            outputConfiguration.outputFileType = .mp4
            guard outputConfiguration.availableVideoCodecTypes.contains(.h264),
                  outputConfiguration.availableOutputFileTypes.contains(.mp4) else {
                throw ContextDemoCaptureError.encoderUnavailable
            }
            let delegate = ContextDemoRecordingDelegate(events)
            let recording = SCRecordingOutput(configuration: outputConfiguration, delegate: delegate)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
            self.delegate = delegate; self.recording = recording; self.stream = stream
            activeTarget = window
            try stream.addRecordingOutput(recording)
            let events = events
            stream.startCapture { [weak self] error in
                events.value.withLock {
                    $0.startAcknowledged = true
                    if let error { $0.error = Self.map(error) }
                }
                Task { @MainActor [weak self] in
                    if self?.stopRequested == true { self?.stop() }
                }
            }
        } catch is CancellationError {
            events.value.withLock { $0.finished = true; $0.stopped = true }
            throw CancellationError()
        } catch {
            let mapped = Self.map(error)
            events.value.withLock { $0.error = mapped; $0.finished = true; $0.stopped = true }
            throw mapped
        }
    }

    func snapshot() -> ContextDemoCaptureSnapshot {
        var value = events.value.withLock { $0 }
        value.bytes = max(0, recording?.recordedFileSize ?? 0)
        if let target = activeTarget, !value.finished {
            let application = NSRunningApplication(processIdentifier: target.processID)
            if application?.launchDate != target.processLaunchDate || application?.isTerminated != false {
                value.error = .targetUnavailable
            }
        }
        return value
    }

    func stop() {
        stopRequested = true
        guard let stream else {
            events.value.withLock { $0.stopped = true; $0.finished = true }
            return
        }
        guard !stopping else { return }
        let state = snapshot()
        guard state.startAcknowledged || state.started else { return }
        stopping = true
        let events = events
        stream.stopCapture { error in
            events.value.withLock {
                $0.stopped = true
                if let error { $0.error = Self.map(error) }
            }
        }
    }

    func release() {
        stop()
        stream = nil; recording = nil; delegate = nil; activeTarget = nil
    }

    nonisolated static func map(_ error: any Error) -> ContextDemoCaptureError {
        if let error = error as? ContextDemoCaptureError { return error }
        let native = error as NSError
        guard native.domain == SCStreamErrorDomain else { return .invalidRecording }
        switch native.code {
        case -3801: return .permissionDenied
        case -3803: return .encoderUnavailable
        case -3804, -3805, -3806, -3813, -3814, -3815: return .targetUnavailable
        case -3802, -3807, -3810, -3812: return .failedToStart
        default: return .interrupted
        }
    }
}

@MainActor struct ContextDemoRecordingInspector: ContextDemoRecordingInspecting {
    func inspect(_ url: URL) async throws -> ContextDemoRecordingMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard duration.isFinite, duration > 0, video.count == 1, audio.isEmpty,
              let track = video.first else { throw ContextDemoCaptureError.invalidRecording }
        let size = try await track.load(.naturalSize)
        let range = try await track.load(.timeRange)
        let frameRate = try await track.load(.nominalFrameRate)
        guard range.start == .zero, range.duration.isNumeric,
              abs(range.duration.seconds - duration) <= 1 / 600.0,
              frameRate.isFinite, frameRate > 0, frameRate <= 30 else {
            throw ContextDemoCaptureError.invalidRecording
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard !descriptions.isEmpty,
              descriptions.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else {
            throw ContextDemoCaptureError.invalidRecording
        }
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 2, bounds.height >= 2,
              bounds.width <= 1_920, bounds.height <= 1_080 else { throw ContextDemoCaptureError.invalidRecording }
        try await Self.decodeFirstFrame(url)
        try Task.checkCancellation()
        return ContextDemoRecordingMetadata(duration: duration, width: Int(bounds.width), height: Int(bounds.height))
    }

    /// Throws unless the recording's first frame decodes. The reader runs on `MediaReadQueue`, not on the main thread, while
    /// the main actor awaits it; its own asset keeps the main actor's out of the read.
    nonisolated private static func decodeFirstFrame(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ContextDemoCaptureError.invalidRecording }
        try await MediaReadQueue.run {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            guard reader.canAdd(output) else { throw ContextDemoCaptureError.invalidRecording }
            reader.add(output)
            guard reader.startReading(), let sample = MediaReadQueue.copyNext(output),
                  CMSampleBufferIsValid(sample), CMSampleBufferGetImageBuffer(sample) != nil else {
                reader.cancelReading(); throw ContextDemoCaptureError.invalidRecording
            }
            reader.cancelReading()
        }
    }
}
