import AVFoundation
import CoreImage
import VoxClipCore

struct FootageLayer: Sendable {
    let output: CMTimeRange
    let kind: ClipFootage.Kind
    let trackID: CMPersistentTrackID?
    let orientation: CGImagePropertyOrientation
    let still: CGImage?

    static func insert(_ request: RenderRequest, into composition: AVMutableComposition,
                       isolation: isolated (any Actor)? = #isolation) async throws -> [Self] {
        var layers: [Self] = []
        let timeline = request.timeline
        for input in request.footage.sorted(by: { $0.entry.start < $1.entry.start }) {
            try Task.checkCancellation()
            let entry = input.entry
            func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600_000) }
            let output = CMTimeRange(start: time(timeline.mapTime(entry.start)), end: time(timeline.mapTime(entry.end)))
            guard output.isValid, output.duration > .zero else { continue }
            if let key = input.expectedKey, (try? JSONProjectStore.contentKey(for: input.url)) != key {
                throw VoxClipError.mediaMissing("Companion recording")
            }
            let asset = AVURLAsset(url: input.url)
            let start = time(entry.footage.start)
            if entry.kind == .screenshot {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1920, height: 1920)
                generator.requestedTimeToleranceBefore = .positiveInfinity
                generator.requestedTimeToleranceAfter = .zero
                let image = try await generator.image(at: start).image
                layers.append(.init(output: output, kind: entry.kind, trackID: nil, orientation: .up, still: image))
                continue
            }
            guard let source = try await asset.loadTracks(withMediaType: .video).first,
                  let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VoxClipError.decodeFailed("A companion recording has no video track")
            }
            let (range, transform) = try await source.load(.timeRange, .preferredTransform)
            let selected = CMTimeRange(start: max(start, range.start), end: min(range.end, start + time(entry.end - entry.start)))
            guard selected.isValid, selected.duration > .zero else { throw VoxClipError.decodeFailed("A companion recording is too short") }
            try track.insertTimeRange(selected, of: source, at: output.start)
            if selected.duration != output.duration {
                track.scaleTimeRange(CMTimeRange(start: output.start, duration: selected.duration), toDuration: output.duration)
            }
            layers.append(.init(output: output, kind: entry.kind, trackID: track.trackID,
                                orientation: MediaSupport.orientation(transform), still: nil))
        }
        return layers
    }
}
