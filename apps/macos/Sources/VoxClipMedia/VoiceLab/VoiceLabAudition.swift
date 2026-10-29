import AVFoundation
import Foundation
import Observation
import VoxClipCore

@MainActor protocol VoiceLabAuditionBackend: AnyObject {
    var position: Double { get }
    func play() -> Bool
    func stop()
}

@MainActor private final class VoiceLabAudioPlayback: NSObject, VoiceLabAuditionBackend, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    private let finished: @MainActor @Sendable () -> Void
    init(url: URL, finished: @escaping @MainActor @Sendable () -> Void) throws {
        player = try AVAudioPlayer(contentsOf: url)
        self.finished = finished
        super.init()
        player.delegate = self
    }
    var position: Double { player.currentTime }
    func play() -> Bool { player.play() }
    func stop() { player.stop() }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finished() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self] in self?.finished() }
    }
}

@Observable @MainActor public final class VoiceLabAudition {
    public private(set) var isPlaying = false
    public private(set) var completed = false
    public private(set) var position = 0.0
    public private(set) var takeId: UUID?
    private var selectionId: String?
    private var token = UUID()
    private var scratch: VoiceLabTakeScratch?
    private var backend: (any VoiceLabAuditionBackend)?
    private var subscription: UUID?
    private let makeBackend: @MainActor (URL, @escaping @MainActor @Sendable () -> Void) throws -> any VoiceLabAuditionBackend
    public init() { makeBackend = { try VoiceLabAudioPlayback(url: $0, finished: $1) } }
    #if DEBUG
    init(makeBackend: @escaping @MainActor (URL, @escaping @MainActor @Sendable () -> Void) throws -> any VoiceLabAuditionBackend) {
        self.makeBackend = makeBackend
    }
    #endif
    public func play(_ scratch: VoiceLabTakeScratch, takeId: UUID, selectionId: String) throws {
        stop()
        guard scratch.isValid else { throw VoiceLabError.invalidAudio }
        self.scratch = scratch; self.takeId = takeId; self.selectionId = selectionId
        let current = UUID(); token = current
        let playback = try makeBackend(scratch.mixedAudioURL) { [weak self] in
            guard let self, self.token == current else { return }
            self.refreshPosition(); self.isPlaying = false; self.completed = true
        }
        backend = playback
        subscription = try scratch.attach { [weak self] in await self?.leaseInvalidated(token: current) }
        guard playback.play() else { stop(); throw VoiceLabError.invalidAudio }
        isPlaying = true
    }
    private func leaseInvalidated(token: UUID) {
        guard self.token == token else { return }
        stop(); scratch = nil; takeId = nil
    }
    public func refreshPosition() {
        if scratch?.isValid == false { stop(); return }
        position = backend?.position ?? position
    }
    public func stop() {
        token = UUID()
        if let subscription { scratch?.detach(subscription) }
        subscription = nil
        backend?.stop(); backend = nil
        isPlaying = false; completed = false; position = 0
    }
    public func takeChanged(to id: UUID?) {
        guard takeId != id else { return }
        stop(); scratch = nil; takeId = nil
    }
    public func selectionChanged(to id: String?) {
        guard selectionId != id else { return }
        stop(); scratch = nil; takeId = nil; selectionId = id
    }
    public func reject(_ id: UUID) async {
        guard takeId == id else { return }
        stop(); await scratch?.invalidate(); scratch = nil; takeId = nil
    }
    public func endSession() async {
        stop(); await scratch?.invalidate(); scratch = nil; takeId = nil; selectionId = nil
    }
}
