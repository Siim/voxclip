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
    private let valid = Mutex(true)
    public var isValid: Bool { valid.withLock { $0 } }
    public func invalidate() {
        valid.withLock { valid in
            guard valid else { return }
            valid = false
            try? FileManager.default.removeItem(at: directory)
        }
    }
    init(directory: URL, fitted: VoiceLabFittedAudio, audio: VoiceLabTakeAudio) {
        self.directory = directory; self.fitted = fitted; self.audio = audio
        mixedAudioURL = directory.appendingPathComponent("mixed.wav")
        fittedAudioURL = directory.appendingPathComponent("fitted.wav")
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
