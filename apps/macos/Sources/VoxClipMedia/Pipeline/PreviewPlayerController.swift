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
    private let builder: CompositionBuilder
    /// The current item's compositor failures, kept for caption-only updates of the same item.
    private var failures: PreviewFrameFailures?
    /// The current item's status, watched so a failed item is reported even while paused.
    private var statusObservation: NSKeyValueObservation?
    /// The item whose failure was reported: one `.failed` per loaded item (design.md §5.4.4 g).
    private var reportedItem: ObjectIdentifier?

    public convenience init() { self.init(builder: CompositionBuilder()) }
    init(builder: CompositionBuilder) {
        self.builder = builder
        // A failure must not be pushed out by the clock's ticks before the editor reads it.
        let stream = AsyncStream<PreviewEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        events = stream.stream; continuation = stream.continuation
    }

    public func load(_ request: RenderRequest) async throws {
        revision &+= 1
        _ = try await apply(request, revision: revision)
    }

    private func apply(_ request: RenderRequest, revision current: UInt64) async throws -> Bool {
        var preview = request; preview.forPreview = true
        let box = WeakItem()
        let failures = PreviewFrameFailures { [weak self] reason in
            Task { @MainActor in self?.compositorFailed(reason, item: box) }
        }
        let graph = try await builder.build(preview, previewFailures: failures)
        guard current == revision else { return false }
        let item = LeasedPlayerItem(graph: graph)
        box.item = item
        item.videoComposition = graph.videoComposition; item.audioMix = graph.audioMix
        player.replaceCurrentItem(with: item)
        // A new item may reuse a freed item's address: its own failure must still be reported.
        self.failures = failures; reportedItem = nil
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.itemFailed(item) }
        }
        self.request = preview; editedTime = 0
        if observer == nil {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, let request = self.request, time.isNumeric else { return }
                    // The player runs on the rendered clock; the editor reads 1× edited time (design.md §6.9).
                    self.editedTime = min(request.timeline.duration, max(0, request.speedTiming.edited(time.seconds)))
                    self.continuation.yield(.time(edited: self.editedTime, source: request.timeline.sourceTime(self.editedTime)))
                    let playing = self.player.rate != 0
                    if self.isPlaying != playing { self.isPlaying = playing; self.continuation.yield(.playing(playing)) }
                    if let item = self.player.currentItem, item.status == .failed { self.itemFailed(item) }
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
        if let item = player.currentItem, canReuseComposition(old, request, item: item) {
            if let lastCaptionUpdate {
                let remaining = Duration.milliseconds(34) - lastCaptionUpdate.duration(to: .now)
                if remaining > .zero { try await Task.sleep(for: remaining) }
            }
            guard current == revision,
                  let instruction = item.videoComposition?.instructions.first as? RenderInstruction else { return }
            var preview = request; preview.forPreview = true
            item.videoComposition = try builder.makeVideoComposition(preview, trackID: instruction.sourceTrackID,
                duration: CMTime(value: request.timeline.outputSamples, timescale: Int32(request.timeline.sampleRate)),
                orientation: instruction.orientation, previewFailures: failures)
            self.request = preview
            lastCaptionUpdate = .now
            return
        }
        try await Task.sleep(for: .milliseconds(150))
        guard current == revision else { return }
        let sourceTime = old.timeline.sourceTime(old.speedTiming.edited(player.currentTime().seconds))
        let rate = player.rate
        guard try await apply(request, revision: current) else { return }
        try await seek(to: request.timeline.mapTime(sourceTime), exact: true)
        guard current == revision else { return }
        if rate != 0 { player.rate = rate; isPlaying = true }
    }

    /// Caption-only updates may reuse an ordinary source composition. Layered and
    /// synthetic compositions retain prepared tracks, framing spans and leases.
    private func canReuseComposition(_ old: RenderRequest, _ next: RenderRequest, item: AVPlayerItem) -> Bool {
        guard old.contextDemo == nil, next.contextDemo == nil,
              old.voiceLab?.prepared.outputPlan.requiresSyntheticRendering != true,
              next.voiceLab?.prepared.outputPlan.requiresSyntheticRendering != true,
              let leased = item as? LeasedPlayerItem, leased.renderGraph.contextDemoLease == nil else { return false }
        return old.sourceURL == next.sourceURL && old.sourceContentKey == next.sourceContentKey &&
            old.timeline == next.timeline && old.voiceLab == next.voiceLab && old.output == next.output &&
            old.motionCues == next.motionCues && old.motionClipID == next.motionClipID &&
            old.reduceMotion == next.reduceMotion && old.music == next.music && old.clipControls == next.clipControls
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
            _ = await player.seek(to: CMTime(seconds: request.speedTiming.rendered(time), preferredTimescale: Int32(request.timeline.sampleRate)), toleranceBefore: tolerance, toleranceAfter: tolerance)
            guard current == revision else { continue }
            self.editedTime = time
            continuation.yield(.time(edited: time, source: request.timeline.sourceTime(time)))
        }
    }
    public func play() { guard player.currentItem != nil else { return }; player.play(); isPlaying = true; continuation.yield(.playing(true)) }
    public func pause() { player.pause(); isPlaying = false; continuation.yield(.playing(false)) }
    public func close() {
        revision &+= 1; pendingSeek = nil
        statusObservation = nil; failures = nil; reportedItem = nil
        player.pause(); player.replaceCurrentItem(with: nil); request = nil; isPlaying = false; editedTime = 0
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        lastCaptionUpdate = nil
        continuation.yield(.playing(false))
    }

    /// The current item's compositor could not draw a frame, or drew it without an overlay: reported once per item.
    private func compositorFailed(_ reason: PreviewFailureReason, item box: WeakItem) {
        guard let item = box.item, item === player.currentItem else { return }
        report(item, .failed(.decodeFailed("Preview frames failed"), reason: reason))
    }

    /// The current item failed as a whole (its status, watched and polled): reported once per item.
    private func itemFailed(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        report(item, .failed(.decodeFailed(item.error?.localizedDescription ?? "Preview failed")))
    }

    private func report(_ item: AVPlayerItem, _ event: PreviewEvent) {
        let id = ObjectIdentifier(item)
        guard reportedItem != id else { return }
        reportedItem = id
        continuation.yield(event)
    }
}

/// The item a compositor failure belongs to, filled in once the item exists; the compositor never retains it.
private final class WeakItem: @unchecked Sendable {
    weak var item: AVPlayerItem?
}
