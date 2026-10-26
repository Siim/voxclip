import Foundation
import AVFoundation
import VoxClipCore

/// The item, including AVFoundation's outstanding callbacks, owns its staged audio lease.
final class LeasedPlayerItem: AVPlayerItem {
    let renderGraph: RenderGraph
    init(graph: RenderGraph) {
        renderGraph = graph
        super.init(asset: graph.composition, automaticallyLoadedAssetKeys: nil)
    }
}

/// Preview on the source-preserving edited clock; architecture §5.5.
@MainActor public final class PreviewPlayerController: PreviewEngine {
    public let player = AVPlayer()
    public let events: AsyncStream<PreviewEvent>
    public private(set) var isPlaying = false
    public private(set) var editedTime: Double = 0
    private let continuation: AsyncStream<PreviewEvent>.Continuation
    private var request: RenderRequest?
    private var observer: Any?
    private var revision: UInt64 = 0
    private var seeking = false
    private var pendingSeek: (Double, Bool)?
    private var lastCaptionUpdate: ContinuousClock.Instant?
    private let builder = CompositionBuilder()

    public init() {
        let stream = AsyncStream<PreviewEvent>.makeStream(bufferingPolicy: .bufferingNewest(2))
        events = stream.stream; continuation = stream.continuation
    }

    public func load(_ request: RenderRequest) async throws {
        revision &+= 1
        _ = try await apply(request, revision: revision)
    }

    private func apply(_ request: RenderRequest, revision current: UInt64) async throws -> Bool {
        var preview = request; preview.forPreview = true
        let graph = try await builder.build(preview)
        guard current == revision else { return false }
        let item = LeasedPlayerItem(graph: graph)
        item.videoComposition = graph.videoComposition; item.audioMix = graph.audioMix
        player.replaceCurrentItem(with: item)
        self.request = preview; editedTime = 0
        if observer == nil {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, let request = self.request, time.isNumeric else { return }
                    self.editedTime = min(request.timeline.duration, max(0, time.seconds))
                    self.continuation.yield(.time(edited: self.editedTime, source: request.timeline.sourceTime(self.editedTime)))
                    let playing = self.player.rate != 0
                    if self.isPlaying != playing { self.isPlaying = playing; self.continuation.yield(.playing(playing)) }
                    if self.player.currentItem?.status == .failed { self.continuation.yield(.failed(.decodeFailed(self.player.currentItem?.error?.localizedDescription ?? "Preview failed"))) }
                }
            }
        }
        return true
    }

    public func update(_ request: RenderRequest) async throws {
        try VoiceLabRenderPreflight.validate(request)
        guard let old = self.request else { try await load(request); return }
        revision &+= 1
        let current = revision
        if old.timeline == request.timeline && old.voiceLab == request.voiceLab && old.sourceURL == request.sourceURL,
           let item = player.currentItem {
            if let lastCaptionUpdate {
                let remaining = Duration.milliseconds(34) - lastCaptionUpdate.duration(to: .now)
                if remaining > .zero { try await Task.sleep(for: remaining) }
            }
            guard current == revision,
                  let instruction = item.videoComposition?.instructions.first as? RenderInstruction else { return }
            var preview = request; preview.forPreview = true
            item.videoComposition = try builder.makeVideoComposition(preview, trackID: instruction.sourceTrackID,
                duration: instruction.timeRange.duration, orientation: instruction.orientation)
            self.request = preview
            lastCaptionUpdate = .now
            return
        }
        try await Task.sleep(for: .milliseconds(150))
        guard current == revision else { return }
        let sourceTime = old.timeline.sourceTime(player.currentTime().seconds)
        let rate = player.rate
        guard try await apply(request, revision: current) else { return }
        try await seek(to: request.timeline.mapTime(sourceTime), exact: true)
        guard current == revision else { return }
        if rate != 0 { player.rate = rate; isPlaying = true }
    }

    public func seek(to editedTime: Double, exact: Bool) async throws {
        guard let request, editedTime.isFinite else { return }
        pendingSeek = (min(request.timeline.duration, max(0, editedTime)), exact)
        if seeking { return }
        seeking = true
        defer { seeking = false }
        while let (time, exact) = pendingSeek {
            pendingSeek = nil
            try Task.checkCancellation()
            let current = revision
            let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)
            _ = await player.seek(to: CMTime(seconds: time, preferredTimescale: Int32(request.timeline.sampleRate)), toleranceBefore: tolerance, toleranceAfter: tolerance)
            guard current == revision else { continue }
            self.editedTime = time
            continuation.yield(.time(edited: time, source: request.timeline.sourceTime(time)))
        }
    }
    public func play() { guard player.currentItem != nil else { return }; player.play(); isPlaying = true; continuation.yield(.playing(true)) }
    public func pause() { player.pause(); isPlaying = false; continuation.yield(.playing(false)) }
    public func close() {
        revision &+= 1; pendingSeek = nil
        player.pause(); player.replaceCurrentItem(with: nil); request = nil; isPlaying = false; editedTime = 0
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        lastCaptionUpdate = nil
        continuation.yield(.playing(false))
    }
}
