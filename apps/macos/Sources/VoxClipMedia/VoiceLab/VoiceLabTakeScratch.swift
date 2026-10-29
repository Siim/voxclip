import Foundation
import Synchronization
import VoxClipCore

public struct VoiceLabTakeStorage: Sendable {
    public let projectId: String
    public let paidRoot: URL
    public let scratchRoot: URL
    public init(projectId: String, paidRoot: URL, scratchRoot: URL) {
        self.projectId = projectId; self.paidRoot = paidRoot; self.scratchRoot = scratchRoot
    }
}

public final class VoiceLabTakeScratch: Sendable {
    public let mixedAudioURL: URL
    public let fittedAudioURL: URL
    public let fitted: VoiceLabFittedAudio
    public let audio: VoiceLabTakeAudio
    private let directory: URL
    private struct State {
        var valid = true
        var consumers: [UUID: @Sendable () async -> Void] = [:]
        var cleanup: Task<Void, Never>?
    }
    private let state = Mutex(State())
    public var isValid: Bool { state.withLock { $0.valid } }
    func attach(_ stop: @escaping @Sendable () async -> Void) throws -> UUID {
        try state.withLock { state in
            guard state.valid else { throw VoiceLabError.invalidAudio }
            let id = UUID(); state.consumers[id] = stop; return id
        }
    }
    func detach(_ id: UUID) { _ = state.withLock { $0.consumers.removeValue(forKey: id) } }
    public func invalidate() async {
        let directory = directory, snapshot = fitted.snapshot
        let cleanup = state.withLock { state in
            if let cleanup = state.cleanup { return cleanup }
            state.valid = false
            let consumers = Array(state.consumers.values)
            state.consumers.removeAll()
            let cleanup = Task.detached(priority: .utility) {
                for stop in consumers { await stop() }
                snapshot.invalidate()
                try? FileManager.default.removeItem(at: directory)
            }
            state.cleanup = cleanup
            return cleanup
        }
        await cleanup.value
    }
    init(directory: URL, fitted: VoiceLabFittedAudio, audio: VoiceLabTakeAudio) {
        self.directory = directory; self.fitted = fitted; self.audio = audio
        mixedAudioURL = directory.appendingPathComponent("mixed.wav")
        fittedAudioURL = directory.appendingPathComponent("fitted.wav")
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
