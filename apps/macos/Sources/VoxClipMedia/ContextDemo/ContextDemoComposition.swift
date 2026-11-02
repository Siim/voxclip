import AVFoundation
import CoreImage
import Foundation
import ImageIO
import VoxClipCore

struct CompositionVideoSpan: Sendable {
    let source: CMTimeRange
    let output: CMTimeRange
    let zoom: Double
    let anchorX: Double
    let anchorY: Double

    static func build(_ request: RenderRequest) throws -> [CompositionVideoSpan] {
        let timeline = request.timeline
        guard timeline.sampleRate.isFinite, timeline.sampleRate >= 1,
              timeline.sampleRate <= Double(Int32.max), timeline.sampleRate.rounded() == timeline.sampleRate,
              timeline.outputSamples > 0 else {
            throw VoxClipError.exportFailed("Invalid video sample grid")
        }
        let rate = Int32(timeline.sampleRate)
        func range(_ start: Int64, _ end: Int64) -> CMTimeRange {
            CMTimeRange(start: CMTime(value: start, timescale: rate), end: CMTime(value: end, timescale: rate))
        }
        switch timeline {
        case .legacy(let plan):
            var cursor: Int64 = 0
            return plan.kept.map { interval in
                defer { cursor += interval.count }
                return CompositionVideoSpan(source: range(interval.startSample, interval.endSample),
                    output: range(cursor, cursor + interval.count), zoom: 1, anchorX: 0.5, anchorY: 0.5)
            }
        case .voiceLab(let plan):
            var cursor: Int64 = 0
            return try plan.pieces.map { piece in
                guard piece.sourceStartSample >= 0, piece.sourceEndSample > piece.sourceStartSample,
                      piece.sourceEndSample <= plan.totalSourceSamples, piece.outputStartSample == cursor,
                      piece.outputEndSample > cursor else {
                    throw VoxClipError.exportFailed("Invalid video output piece")
                }
                let sourceCount = piece.sourceEndSample - piece.sourceStartSample
                let outputCount = piece.outputEndSample - piece.outputStartSample
                var zoom = 1.0, anchorX = 0.5, anchorY = 0.5
                if piece.kind == .synth {
                    guard let selected = request.voiceLab?.prepared.selectedSegmentRecipes.first(where: {
                        $0.segmentId == piece.segmentId && $0.piece == piece
                    }) else { throw VoiceLabProjectError.staleRenderContract }
                    let recipe = selected.recipe.video
                    guard recipe.sourceStartSample == piece.sourceStartSample,
                          recipe.sourceEndSample == piece.sourceEndSample, recipe.outputSamples == outputCount else {
                        throw VoiceLabProjectError.staleRenderContract
                    }
                    switch recipe.mode {
                    case .source:
                        guard sourceCount == outputCount else { throw VoiceLabProjectError.videoModeUnsupported }
                    case .zoomCover:
                        let factor = Double(sourceCount) / Double(outputCount)
                        guard (0.80...1.25).contains(factor), let declared = recipe.retimeFactor,
                              declared.isFinite, abs(factor - declared) <= 1e-6,
                              let crop = recipe.zoom, crop.isFinite, abs(crop - 1.12) <= 1e-9,
                              let faceX = recipe.faceX, faceX.isFinite, (0...1).contains(faceX),
                              let faceY = recipe.faceY, faceY.isFinite, (0...1).contains(faceY) else {
                            throw VoiceLabProjectError.videoModeUnsupported
                        }
                        zoom = crop; anchorX = faceX; anchorY = faceY
                    case .retimed, .lipsync:
                        throw VoiceLabProjectError.videoModeUnsupported
                    }
                } else if sourceCount != outputCount { throw VoiceLabProjectError.videoModeUnsupported }
                cursor = piece.outputEndSample
                return CompositionVideoSpan(source: range(piece.sourceStartSample, piece.sourceEndSample),
                    output: range(piece.outputStartSample, piece.outputEndSample), zoom: zoom,
                    anchorX: anchorX, anchorY: anchorY)
            }
        }
    }
}

struct CompositionDemoLayer: Sendable {
    let trackID: CMPersistentTrackID
    let output: CMTimeRange
    let orientation: CGImagePropertyOrientation
}

enum ContextDemoCompositionRoute {
    static func validate(_ request: RenderRequest) throws {
        guard let input = request.contextDemo else { return }
        try input.verifyRenderedTimeline(request.timeline)
        if let voiceLab = request.voiceLab, voiceLab.project.id != input.projectId {
            throw ContextDemoCompositionError.invalidBinding
        }
        if !input.placements.isEmpty {
            guard let contentKey = request.sourceContentKey, contentKey == input.sourceContentKey,
                  request.sourceURL.isFileURL,
                  try JSONProjectStore.contentKey(for: request.sourceURL) == contentKey else {
                throw ContextDemoCompositionError.invalidBinding
            }
        }
        guard input.placements.isEmpty || request.contextDemoRoot?.isFileURL == true else {
            throw ContextDemoCompositionError.unsafePath
        }
    }

    static func insert(_ request: RenderRequest, into composition: AVMutableComposition,
                       scratchRoot: URL, isolation: isolated (any Actor)? = #isolation) async throws
        -> (layers: [CompositionDemoLayer], lease: ContextDemoCompositionLease?) {
        try validate(request)
        guard let input = request.contextDemo, !input.placements.isEmpty else { return ([], nil) }
        guard let root = request.contextDemoRoot else { throw ContextDemoCompositionError.unsafePath }
        let lease = try await ContextDemoCompositionAssets.prepare(input.assets, projectId: input.projectId,
            root: root, scratchRoot: scratchRoot)
        var layers: [CompositionDemoLayer] = []
        let rate = Int32(request.timeline.sampleRate)
        func time(_ seconds: Double) throws -> CMTime {
            let value = seconds * Double(rate)
            guard value.isFinite, value >= 0, value <= 9_007_199_254_740_991,
                  abs(value - EditingPrimitives.jsRound(value)) <= 0.000_001 else {
                throw ContextDemoCompositionError.invalidPlacement
            }
            return CMTime(value: Int64(EditingPrimitives.jsRound(value)), timescale: rate)
        }
        for placement in input.placements {
            try Task.checkCancellation()
            guard let record = input.assets.first(where: { $0.id == placement.assetId }),
                  let url = lease.urls[placement.assetId] else { throw ContextDemoCompositionError.missingAsset }
            let source = try CMTimeRange(start: time(placement.source.start), end: time(placement.source.end))
            let output = try CMTimeRange(start: time(placement.output.start), end: time(placement.output.end))
            guard source.duration > .zero, source.duration == output.duration,
                  output.end <= CMTime(value: request.timeline.outputSamples, timescale: rate),
                  layers.last.map({ $0.output.end <= output.start }) ?? true else {
                throw ContextDemoCompositionError.invalidPlacement
            }
            let captured = try await ContextDemoCompositionAssets.video(record, url: url)
            let (range, transform) = try await captured.track.load(.timeRange, .preferredTransform)
            guard source.start >= range.start, source.end <= range.end else {
                throw ContextDemoCompositionError.invalidPlacement
            }
            guard let track = composition.addMutableTrack(withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VoxClipError.exportFailed("Cannot create context-demo video track")
            }
            // AVAssetTrack does not retain its source asset through insertion.
            try withExtendedLifetime(captured.asset) {
                try track.insertTimeRange(source, of: captured.track, at: output.start)
            }
            layers.append(CompositionDemoLayer(trackID: track.trackID, output: output,
                orientation: MediaSupport.orientation(transform)))
        }
        try Task.checkCancellation()
        return (layers, lease)
    }
}

enum CompositionFrameGeometry {
    static func faceCrop(in source: CGRect, aspectCrop: CGRect, scale: Double, faceX: Double, faceY: Double) -> CGRect {
        let width = aspectCrop.width / scale, height = aspectCrop.height / scale
        let centerX = source.minX + source.width * faceX
        let centerY = source.maxY - source.height * faceY
        return CGRect(x: min(source.maxX - width, max(source.minX, centerX - width / 2)),
            y: min(source.maxY - height, max(source.minY, centerY - height / 2)), width: width, height: height)
    }

    static func crop(in frame: CGRect, scale: Double, anchorX: Double, anchorY: Double) -> CGRect {
        let width = frame.width / scale, height = frame.height / scale
        return CGRect(x: frame.minX + (frame.width - width) * anchorX,
            y: frame.minY + (frame.height - height) * (1 - anchorY), width: width, height: height)
    }

    static func fill(_ image: CIImage, crop: CGRect, output: CGSize) -> CIImage {
        image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: output.height / crop.height,
                kCIInputAspectRatioKey: (output.width / crop.width) / (output.height / crop.height)])
            .cropped(to: CGRect(origin: .zero, size: output))
    }
}
