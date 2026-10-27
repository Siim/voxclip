import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import RecorderSupport
import ScreenCaptureKit
import Synchronization

// SDK callbacks and signal handlers capture this Sendable reference, never a mutable local.
private final class RecordingState: Sendable {
    struct Snapshot: Sendable {
        var startedAt: Date?
        var uptime: Double = 0
        var finished = false
        var interrupted = false
        var error: String?
    }
    private let storage = Mutex(Snapshot())
    func snapshot() -> Snapshot { storage.withLock { $0 } }
    func started() { storage.withLock { $0.startedAt = Date(); $0.uptime = ProcessInfo.processInfo.systemUptime } }
    func finished() { storage.withLock { $0.finished = true } }
    func interrupt() { storage.withLock { $0.interrupted = true } }
    func failed(_ error: any Error) { storage.withLock { $0.error = String(describing: error) } }
}

private final class Delegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    let state: RecordingState
    init(state: RecordingState) { self.state = state }
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { state.started() }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { state.finished() }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) { state.failed(error) }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { state.failed(error) }
}

@main
struct Recorder {
    static func main() async {
        if CommandLine.arguments.contains("--help") { print(Arguments.usage); return }
        do {
            try await record(Arguments(Array(CommandLine.arguments.dropFirst())))
        } catch {
            FileHandle.standardError.write(Data("sckrec: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func record(_ args: Arguments) async throws {
        // ScreenCaptureKit's window geometry needs an initialized WindowServer connection.
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard CGPreflightScreenCaptureAccess() else {
            throw ArgumentError.invalid("Screen Recording permission is required for this executable. Enable it in System Settings > Privacy & Security > Screen & System Audio Recording, then run again.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let matches = content.windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            let appMatches = args.app.isEmpty || owner.applicationName.caseInsensitiveCompare(args.app) == .orderedSame || owner.bundleIdentifier == args.app
            let titleMatches = (window.title ?? "").localizedCaseInsensitiveContains(args.title)
            return appMatches && (args.title.isEmpty || titleMatches) && window.frame.width > 0 && window.frame.height > 0
        }
        if args.list {
            for window in matches.sorted(by: { $0.windowID < $1.windowID }) {
                print("\(window.windowID)\t\(window.owningApplication?.applicationName ?? "")\t\(window.title ?? "")")
            }
            return
        }
        guard matches.count == 1, let window = matches.first, let output = args.output else {
            throw ArgumentError.invalid("Expected exactly one matching window; found \(matches.count). Use --list and a more specific --title.")
        }
        let sidecarURL = output.appendingPathExtension("json")
        guard !FileManager.default.fileExists(atPath: output.path), !FileManager.default.fileExists(atPath: sidecarURL.path) else {
            throw ArgumentError.invalid("Output or sidecar already exists; choose a new output path.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        config.width = max(2, Int(filter.contentRect.width * scale) / 2 * 2)
        config.height = max(2, Int(filter.contentRect.height * scale) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.capturesAudio = false
        config.captureMicrophone = false
        config.queueDepth = 6
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = output
        recordingConfig.videoCodecType = args.codec == "hevc" ? .hevc : .h264
        recordingConfig.outputFileType = output.pathExtension.lowercased() == "mov" ? .mov : .mp4
        guard recordingConfig.availableVideoCodecTypes.contains(recordingConfig.videoCodecType),
              recordingConfig.availableOutputFileTypes.contains(recordingConfig.outputFileType) else {
            throw ArgumentError.invalid("Requested codec/container is unavailable.")
        }
        let state = RecordingState()
        let delegate = Delegate(state: state)
        let recording = SCRecordingOutput(configuration: recordingConfig, delegate: delegate)
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try stream.addRecordingOutput(recording)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        interrupt.setEventHandler { @Sendable in state.interrupt() }
        terminate.setEventHandler { @Sendable in state.interrupt() }
        interrupt.resume(); terminate.resume()
        defer { interrupt.cancel(); terminate.cancel() }
        try await stream.startCapture()
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while state.snapshot().startedAt == nil {
                if let error = state.snapshot().error { throw ArgumentError.invalid(error) }
                guard ProcessInfo.processInfo.systemUptime < deadline, !state.snapshot().interrupted else {
                    throw ArgumentError.invalid("Recording did not start within 15 seconds or was interrupted.")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let started = state.snapshot()
            guard let startedAt = started.startedAt else { throw ArgumentError.invalid("Missing recording start time") }
            var sidecar = Sidecar(startedAt: startedAt, uptime: started.uptime, app: args.app,
                                  title: window.title ?? "", windowID: window.windowID,
                                  width: config.width, height: config.height, codec: args.codec)
            try sidecar.write(to: sidecarURL)
            print("Recording \(config.width)x\(config.height) at 60 fps; Ctrl+C to finish.")
            while !state.snapshot().interrupted {
                if let error = state.snapshot().error { throw ArgumentError.invalid(error) }
                if let seconds = args.seconds, ProcessInfo.processInfo.systemUptime - started.uptime >= seconds { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await stream.stopCapture()
            let finishDeadline = ProcessInfo.processInfo.systemUptime + 15
            while !state.snapshot().finished {
                if let error = state.snapshot().error { throw ArgumentError.invalid(error) }
                guard ProcessInfo.processInfo.systemUptime < finishDeadline else { throw ArgumentError.invalid("Timed out finalizing recording") }
                try await Task.sleep(for: .milliseconds(50))
            }
            // SCRecordingOutput.recordedDuration can be rounded to whole seconds.
            let duration = try await AVURLAsset(url: output).load(.duration)
            sidecar.durationSeconds = duration.seconds
            try sidecar.write(to: sidecarURL)
        } catch {
            try? await stream.stopCapture()
            throw error
        }
    }
}
