import AVFoundation
import Foundation
import Synchronization
import VoxClipCore

private final class ExportPullResult: Sendable {
    typealias Sample = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
    private let continuation: Mutex<CheckedContinuation<Sample?, any Error>?>
    init(_ continuation: CheckedContinuation<Sample?, any Error>) {
        self.continuation = Mutex(continuation)
    }
    func finish(_ result: Result<Sample?, any Error>) {
        let pending = continuation.withLock { current in
            let pending = current
            current = nil
            return pending
        }
        pending?.resume(with: result)
    }
}

final class ExportSampleReader: @unchecked Sendable {
    private struct State {
        var pulling = false
        var cancellationRequested = false
        var cancelled = false
    }
    private let state = Mutex(State())
    private let reader: AVAssetReader
    private let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
    private let queue: DispatchQueue
    private let pump: Int
    private let pumps: ExportPumpState
    private let pullCheck: (@Sendable (Int) -> Void)?
    private let decodeCheck: (@Sendable (Int) -> Void)?

    init(reader: AVAssetReader,
         provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>,
         pump: Int, pumps: ExportPumpState, pullCheck: (@Sendable (Int) -> Void)?,
         decodeCheck: (@Sendable (Int) -> Void)?) {
        self.reader = reader
        self.provider = provider
        self.pump = pump
        self.pumps = pumps
        self.pullCheck = pullCheck
        self.decodeCheck = decodeCheck
        queue = DispatchQueue(label: "com.voxconvo.voxclip.export-pull.\(pump).\(UUID().uuidString)", qos: .userInitiated)
    }

    func start() throws {
        guard reader.startReading() else {
            throw reader.error ?? VoxClipError.decodeFailed("Cannot read export media")
        }
    }

    func next() async throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent>? {
        try pumps.checkRunning()
        let sample = try await withCheckedThrowingContinuation { continuation in
            let result = ExportPullResult(continuation)
            let handler = pumps.whenStopped { result.finish(.failure(CancellationError())) }
            Task(executorPreference: queue) { [self] in
                defer { pumps.removeStopHandler(handler) }
                do {
                    let sample = try await read()
                    result.finish(.success(sample))
                } catch { result.finish(.failure(error)) }
            }
        }
        try Task.checkCancellation()
        try pumps.checkRunning()
        return sample
    }

    private func read() async throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent>? {
        try pumps.checkRunning()
        try state.withLock {
            if $0.cancellationRequested { throw CancellationError() }
            $0.pulling = true
        }
        pumps.sampleStarted(pump)
        defer {
            pumps.sampleEnded(pump)
            let cancel = state.withLock {
                $0.pulling = false
                if $0.cancellationRequested && !$0.cancelled {
                    $0.cancelled = true
                    return true
                }
                return false
            }
            if cancel { cancelReader() }
        }
        pullCheck?(pump)
        try pumps.checkRunning()
        decodeCheck?(pump)
        let sample = try await provider.next()
        if sample != nil { pumps.sampleRead(pump) }
        if sample == nil, reader.status != .completed {
            throw reader.error ?? VoxClipError.decodeFailed("Export reader did not finish")
        }
        return sample
    }

    func cancelAfterJoining() {
        let cancel = state.withLock {
            $0.cancellationRequested = true
            guard !$0.pulling, !$0.cancelled else { return false }
            $0.cancelled = true
            return true
        }
        if cancel { cancelReader() }
    }

    private func cancelReader() {
        pumps.readerWillCancel(pump)
        reader.cancelReading()
    }
}
