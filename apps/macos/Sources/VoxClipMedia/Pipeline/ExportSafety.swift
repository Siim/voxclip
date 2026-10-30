import AVFoundation
import Darwin
import Foundation
import os
import Synchronization
import VideoToolbox
import VoxClipCore

enum ExportPumpEvent: Sendable {
    case pullStarted(Int, stopped: Bool)
    case sampleRead(Int, stopped: Bool)
    case pullEnded(Int)
    case readerWillCancel(Int)
    case writerWillCancel(appendsInFlight: Int)
}

final class ExportPumpState: Sendable {
    private struct State {
        var stopped = false
        var failure: (any Error)?
        var appendsInFlight = 0
        var stopHandlers: [UUID: @Sendable () -> Void] = [:]
    }
    private let state = Mutex(State())
    private let observer: (@Sendable (ExportPumpEvent) -> Void)?
    init(observer: (@Sendable (ExportPumpEvent) -> Void)? = nil) { self.observer = observer }
    var stopped: Bool { state.withLock { $0.stopped } }
    var failure: (any Error)? { state.withLock { $0.failure } }
    var appendsInFlight: Int { state.withLock { $0.appendsInFlight } }
    func stop(_ error: (any Error)? = nil) {
        let handlers = state.withLock {
            $0.stopped = true
            if $0.failure == nil { $0.failure = error }
            let handlers = Array($0.stopHandlers.values)
            $0.stopHandlers.removeAll()
            return handlers
        }
        for handler in handlers { handler() }
    }
    func whenStopped(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let stopped = state.withLock {
            if $0.stopped { return true }
            $0.stopHandlers[id] = handler
            return false
        }
        if stopped { handler() }
        return id
    }
    func removeStopHandler(_ id: UUID) { state.withLock { $0.stopHandlers[id] = nil } }
    func checkRunning() throws {
        try state.withLock {
            if let error = $0.failure { throw error }
            if $0.stopped { throw CancellationError() }
        }
    }
    func sampleStarted(_ pump: Int) { state.withLock { observer?(.pullStarted(pump, stopped: $0.stopped)) } }
    func sampleRead(_ pump: Int) { state.withLock { observer?(.sampleRead(pump, stopped: $0.stopped)) } }
    func sampleEnded(_ pump: Int) { observer?(.pullEnded(pump)) }
    func readerWillCancel(_ pump: Int) { observer?(.readerWillCancel(pump)) }
    func append(_ operation: () throws -> Bool) throws -> Bool {
        try state.withLock {
            if let error = $0.failure { throw error }
            if $0.stopped { throw CancellationError() }
            $0.appendsInFlight += 1
        }
        defer { state.withLock { $0.appendsInFlight -= 1 } }
        return try operation()
    }
    func writerWillCancel() {
        state.withLock { observer?(.writerWillCancel(appendsInFlight: $0.appendsInFlight)) }
    }
    func finishInput(_ finish: () -> Void) {
        state.withLock { if !$0.stopped { finish() } }
    }
}

package enum ExportSafety {
    package static func partialURL(for destination: URL) throws -> URL {
        let partial = URL(fileURLWithPath: destination.path + ".partial")
        var attributes = stat()
        if lstat(partial.path, &attributes) == 0 {
            guard attributes.st_mode & S_IFMT == S_IFREG else {
                throw VoxClipError.exportFailed("The partial output must be a regular file: \(partial.path)")
            }
        } else if errno != ENOENT {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return partial
    }

    static func preparePartial(for destination: URL, registry: URL? = nil) throws -> URL {
        let directory = try ScratchCleanup.createExportDirectory(in: destination.deletingLastPathComponent(), registry: registry)
        return directory.url.appendingPathComponent(destination.lastPathComponent + ".partial")
    }

    package static func discardPartial(_ partial: URL) {
        ScratchCleanup.discardExportDirectory(at: partial.deletingLastPathComponent())
    }

    static func validateDestination(_ destination: URL) throws {
        if let values = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]),
           values.isDirectory == true || values.isRegularFile != true {
            throw VoxClipError.exportFailed("The destination must be a regular file, not a folder or special file")
        }
    }

    package static func failure(_ error: any Error, destination: URL) -> VoxClipError {
        var chain: [NSError] = []
        var current: NSError? = error as NSError
        while let native = current, chain.count < 12 {
            chain.append(native)
            current = native.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let details = chain.map { "\($0.domain)(\($0.code)): \($0.localizedDescription)" }.joined(separator: " <- ")
        let redacted = Redactor(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path).redact(details)
        os.Logger(subsystem: "com.voxconvo.voxclip", category: "export").debug("\(redacted, privacy: .private)")
        if chain.contains(where: {
            ($0.domain == AVFoundationErrorDomain && $0.code == AVError.diskFull.rawValue) ||
            ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError) ||
            ($0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC))
        }) { return .diskFull(destination.deletingLastPathComponent().path) }
        if chain.contains(where: { $0.domain == NSOSStatusErrorDomain &&
            [Int(kVTVideoEncoderNotAvailableNowErr), Int(kVTCouldNotFindVideoEncoderErr)].contains($0.code) }) {
            return .encoderUnavailable
        }
        if let failure = error as? VoxClipError { return failure }
        return .exportFailed(redacted)
    }
}
