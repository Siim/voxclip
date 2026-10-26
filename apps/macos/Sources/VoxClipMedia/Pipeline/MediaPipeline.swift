import Foundation
import AVFoundation
import ImageIO
import VoxClipCore

public actor AVMediaProbe: MediaProbe {
    public init() {}

    public func probe(_ source: URL) async throws -> MediaProbeResult {
        let ext = source.pathExtension.lowercased()
        guard !["webm", "mkv"].contains(ext) else { throw VoxClipError.unsupportedContainer(ext.uppercased()) }
        guard FileManager.default.fileExists(atPath: source.path) else { throw VoxClipError.mediaMissing(source.lastPathComponent) }
        do {
            let asset = AVURLAsset(url: source)
            guard try await asset.load(.isPlayable) else { throw VoxClipError.unsupportedContainer(ext.uppercased()) }
            let audioTrack = try await MediaSupport.audioTrack(in: asset)
            let duration: Double
            if let audioTrack { duration = try await audioTrack.load(.timeRange).end.seconds }
            else if let video = try await asset.loadTracks(withMediaType: .video).first { duration = try await video.load(.timeRange).end.seconds }
            else { duration = try await asset.load(.duration).seconds }
            guard duration.isFinite, duration > 0 else { throw VoxClipError.decodeFailed("Invalid duration") }
            var result = MediaProbeResult(durationSeconds: duration, isPlayable: true)
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (size, transform, rate, descriptions) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
                let oriented = CGRect(origin: .zero, size: size).applying(transform).standardized
                let angle = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
                result.video = MediaVideo(width: Int(size.width), height: Int(size.height), frameRate: Double(rate), rotationDegrees: (angle + 360) % 360)
                result.orientedSize = PixelSize(width: Int(oriented.width.rounded()), height: Int(oriented.height.rounded()))
                if let format = descriptions.first {
                    let code = CMFormatDescriptionGetMediaSubType(format)
                    result.videoCodec = code == kCMVideoCodecType_H264 ? "h264" : code == kCMVideoCodecType_HEVC ? "hevc" : MediaSupport.fourCC(code)
                    let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                    result.isHDR = transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String || transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
                }
            }
            if let track = try await MediaSupport.audioTrack(in: asset),
               let format = try await track.load(.formatDescriptions).first,
               let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                result.audio = MediaAudio(sampleRate: Int(description.mSampleRate.rounded()), channels: Int(description.mChannelsPerFrame))
            }
            return result
        } catch let error as VoxClipError { throw error }
        catch { throw VoxClipError.decodeFailed(error.localizedDescription) }
    }
}

public struct RenderGraph {
    public let composition: AVMutableComposition
    public let videoTrack: AVMutableCompositionTrack
    public let audioTrack: AVMutableCompositionTrack?
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix?
    public let renderSize: CGSize
    public let frameDuration: CMTime
    /// Keeps paid snapshots and staged CAF alive through every player/reader callback.
    public let voiceLabLease: VoiceLabRenderLease?
    public init(composition: AVMutableComposition, videoTrack: AVMutableCompositionTrack, audioTrack: AVMutableCompositionTrack?, videoComposition: AVVideoComposition, audioMix: AVAudioMix?, renderSize: CGSize, frameDuration: CMTime, voiceLabLease: VoiceLabRenderLease? = nil) {
        self.composition = composition; self.videoTrack = videoTrack; self.audioTrack = audioTrack; self.videoComposition = videoComposition; self.audioMix = audioMix; self.renderSize = renderSize; self.frameDuration = frameDuration
        self.voiceLabLease = voiceLabLease
    }
}

public struct CompositionBuilder: Sendable {
    private let rasterizer: (any CaptionRasterizer)?
    private let sharedRasterizer: Result<CoreTextCaptionRasterizer, any Error>
    public init() { self.init(legacyRasterizer: nil) }
    public init(rasterizer: any CaptionRasterizer) { self.init(legacyRasterizer: rasterizer) }
    private init(legacyRasterizer: (any CaptionRasterizer)?) {
        rasterizer = legacyRasterizer
        sharedRasterizer = Result { try CoreTextCaptionRasterizer(shared: SharedResources.locate()) }
    }

    public func build(_ request: RenderRequest, isolation: isolated (any Actor)? = #isolation) async throws -> RenderGraph {
        try Task.checkCancellation()
        let plan = request.plan
        let voicePlan = request.voiceLab?.prepared.outputPlan
        let synthetic = voicePlan?.requiresSyntheticRendering == true
        try VoiceLabRenderPreflight.validate(request)
        guard synthetic || (plan.outputSamples > 0 && !plan.kept.isEmpty) else { throw VoxClipError.everythingCut }
        guard synthetic || (plan.totalSamples >= 0 && plan.sampleRate.isFinite && plan.sampleRate > 0 && plan.sampleRate <= Double(Int32.max) &&
              plan.sampleRate.rounded() == plan.sampleRate &&
              plan.kept.allSatisfy({ $0.startSample >= 0 && $0.endSample <= plan.totalSamples && $0.count > 0 }) &&
              zip(plan.kept, plan.kept.dropFirst()).allSatisfy({ $0.endSample <= $1.startSample }) &&
              plan.kept.reduce(Int64(0), { $0.addingReportingOverflow($1.count).overflow ? -1 : $0 + $1.count }) == plan.outputSamples &&
              plan.joins.allSatisfy({ $0.outSample >= 0 && $0.outSample <= plan.outputSamples && $0.fadeInLen >= 0 && $0.fadeOutLen >= 0 }) &&
              zip(plan.joins, plan.joins.dropFirst()).allSatisfy({ $0.outSample <= $1.outSample })) else {
            throw VoxClipError.exportFailed("Invalid kept sample ranges")
        }
        guard request.output.size.width >= 2, request.output.size.height >= 2,
              max(request.output.size.width, request.output.size.height) <= 1920,
              request.output.size.width % 2 == 0, request.output.size.height % 2 == 0,
              request.output.fps.isFinite, request.output.fps > 0, request.output.fps <= 60,
              request.output.fps.rounded() == request.output.fps, request.output.videoBitrate > 0 else {
            throw VoxClipError.exportFailed("Invalid output dimensions or frame rate")
        }
        let asset = AVURLAsset(url: request.sourceURL)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw VoxClipError.decodeFailed("No video track") }
        let (transform, videoRange, nominalRate) = try await sourceVideo.load(.preferredTransform, .timeRange, .nominalFrameRate)
        let sourceAudio = try await MediaSupport.audioTrack(in: asset)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw VoxClipError.exportFailed("Cannot create video track") }
        let audio = sourceAudio == nil ? nil : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let rate = Int32(synthetic ? voicePlan!.sampleRate : plan.sampleRate)
        let ranges: [(Int64, Int64)] = synthetic ? voicePlan!.pieces.map { ($0.sourceStartSample, $0.sourceEndSample) } :
            plan.kept.map { ($0.startSample, $0.endSample) }
        var cursor = CMTime.zero
        for (start, end) in ranges {
            try Task.checkCancellation()
            let range = CMTimeRange(start: CMTime(value: start, timescale: rate), end: CMTime(value: end, timescale: rate))
            let overlap = CMTimeRangeGetIntersection(range, otherRange: videoRange)
            if overlap.isValid, !overlap.isEmpty {
                try video.insertTimeRange(overlap, of: sourceVideo, at: cursor + overlap.start - range.start)
            }
            if range.end > videoRange.end {
                let tailStart = max(range.start, videoRange.end)
                let tailDuration = range.end - tailStart
                let frameDuration = min(videoRange.duration, CMTime(seconds: 1 / max(1, Double(nominalRate)), preferredTimescale: 600000))
                let lastFrame = CMTimeRange(start: videoRange.end - frameDuration, duration: frameDuration)
                let insertion = cursor + tailStart - range.start
                try video.insertTimeRange(lastFrame, of: sourceVideo, at: insertion)
                video.scaleTimeRange(CMTimeRange(start: insertion, duration: frameDuration), toDuration: tailDuration)
            }
            if !synthetic, let audio, let sourceAudio { try audio.insertTimeRange(range, of: sourceAudio, at: cursor) }
            cursor = cursor + range.duration
        }
        var lease: VoiceLabRenderLease?
        if synthetic {
            guard sourceAudio != nil, let audio, let voicePlan else { throw VoxClipError.noAudioTrack }
            lease = try await VoiceLabAudioRenderer.stage(request: request)
            let mixed = AVURLAsset(url: lease!.mixedAudioURL)
            guard let mixedTrack = try await MediaSupport.audioTrack(in: mixed) else { throw VoxClipError.decodeFailed("Mixed CAF has no audio track") }
            try audio.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: voicePlan.outputSamples, timescale: rate)),
                                      of: mixedTrack, at: .zero)
        }
        let videoComposition = try makeVideoComposition(request, trackID: video.trackID, duration: cursor,
                                                        orientation: MediaSupport.orientation(transform))
        let size = videoComposition.renderSize
        let frameDuration = videoComposition.frameDuration
        var mix: AVAudioMix?
        if let audio, !synthetic {
            let parameters = AVMutableAudioMixInputParameters(track: audio)
            parameters.audioTapProcessor = try FadeTap.make(plan: plan)
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [parameters]
            mix = audioMix
        }
        return RenderGraph(composition: composition, videoTrack: video, audioTrack: audio, videoComposition: videoComposition,
                           audioMix: mix, renderSize: size, frameDuration: frameDuration, voiceLabLease: lease)
    }

    func makeVideoComposition(_ request: RenderRequest, trackID: CMPersistentTrackID, duration: CMTime,
                              orientation: CGImagePropertyOrientation) throws -> AVVideoComposition {
        let size = CGSize(width: request.output.size.width, height: request.output.size.height)
        guard size.width >= 2, size.height >= 2, max(size.width, size.height) <= 1920,
              request.output.fps.isFinite, request.output.fps >= 1, request.output.fps <= 60 else {
            throw VoxClipError.exportFailed("Invalid render configuration")
        }
        let frameDuration = CMTime(value: 1, timescale: Int32(request.output.fps.rounded()))
        let needsRasterizer = request.captionLayout != nil || request.style != nil
        let disclosure: VoiceLabDisclosureOverlay?
        if let input = request.voiceLab, input.prepared.disclosure.required {
            let blocks: [VoiceLabDisclosureCaptionBlock] = request.captionLayout?.pages.map { page in
                let bounds = page.page.visual
                return VoiceLabDisclosureCaptionBlock(start: page.page.start, end: page.page.end,
                    bounds: CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height))
            } ?? []
            let font = try SharedResources.locate().root.appendingPathComponent("fonts/dm-sans/DMSans-Bold.ttf")
            disclosure = try VoiceLabDisclosureOverlay(plan: input.prepared.disclosure,
                width: request.output.size.width, height: request.output.size.height, fontURL: font,
                captionBlocks: blocks)
        } else { disclosure = nil }
        let instruction = RenderInstruction(timeRange: CMTimeRange(start: .zero, duration: duration), sourceTrackID: trackID,
            request: request, orientation: orientation, rasterizer: needsRasterizer ? try sharedRasterizer.get() : nil,
            legacyRasterizer: rasterizer, disclosure: disclosure)
        let config = AVVideoComposition.Configuration(colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2, colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
            customVideoCompositorClass: FrameCompositor.self, frameDuration: frameDuration, instructions: [instruction], renderSize: size)
        return AVVideoComposition(configuration: config)
    }
}

public actor ThumbnailService {
    public init() {}
    public func thumbnail(source: URL, at time: Double, maxHeight: Int = 160) async throws -> Data {
        guard time.isFinite, maxHeight > 0 else { throw VoxClipError.decodeFailed("Invalid thumbnail request") }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 0, height: min(160, maxHeight))
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
        let image = try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw VoxClipError.decodeFailed("Cannot encode thumbnail") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw VoxClipError.decodeFailed("Cannot encode thumbnail") }
        return data as Data
    }
}
