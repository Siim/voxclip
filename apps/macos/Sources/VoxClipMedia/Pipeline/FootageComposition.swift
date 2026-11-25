import AVFoundation
import CoreImage
import VoxClipCore

struct FootageLayer: Sendable {
    let output: CMTimeRange
    let kind: ClipFootage.Kind
    let trackID: CMPersistentTrackID?
    let orientation: CGImagePropertyOrientation
    let still: CGImage?
    let fadeIn: Double
    let fadeOut: Double

    static func insert(_ request: RenderRequest, into composition: AVMutableComposition,
                       isolation: isolated (any Actor)? = #isolation) async throws -> [Self] {
        var layers: [Self] = []
        let timeline = request.timeline
        let timing = request.speedTiming
        let renderedDuration = Double(request.renderedSamples) / timeline.sampleRate
        for input in request.footage.sorted(by: { $0.entry.start < $1.entry.start }) {
            try Task.checkCancellation()
            let entry = input.entry
            func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600_000) }
            let output = CMTimeRange(start: time(timeline.mapTime(entry.start)), end: time(timeline.mapEndTime(entry.end)))
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
                layers.append(.init(output: output, kind: entry.kind, trackID: nil, orientation: .up, still: image,
                                    fadeIn: entry.fadeInSeconds ?? 0, fadeOut: entry.fadeOutSeconds ?? 0))
                continue
            }
            guard let source = try await asset.loadTracks(withMediaType: .video).first,
                  let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VoxClipError.decodeFailed("A companion recording has no video track")
            }
            let (range, transform) = try await source.load(.timeRange, .preferredTransform)
            func rendered(_ edited: CMTime) -> CMTime {
                if timing.isIdentity { return edited }
                let rate = timeline.sampleRate
                let seconds = min(renderedDuration, timing.rendered(edited.seconds))
                return CMTime(seconds: seconds, preferredTimescale: Int32(rate))
            }
            let placement = rendered(output.start)
            let sourceStart = max(start, range.start)
            let length = min(range.end - sourceStart, rendered(output.end) - placement)
            guard length > .zero else { continue }
            try track.insertTimeRange(CMTimeRange(start: sourceStart, duration: length), of: source, at: placement)
            let end = length < rendered(output.end) - placement ? time(timing.edited((placement + length).seconds)) : output.end
            layers.append(.init(output: CMTimeRange(start: output.start, end: end), kind: entry.kind, trackID: track.trackID,
                                orientation: MediaSupport.orientation(transform), still: nil,
                                fadeIn: entry.fadeInSeconds ?? 0, fadeOut: entry.fadeOutSeconds ?? 0))
        }
        return layers
    }
}
