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
    public let contextDemoLease: ContextDemoCompositionLease?
    /// The music bed under the voice (doc/spec/music.md §4), a second audio track; nil without music.
    public let musicTrack: AVMutableCompositionTrack?
    public let musicLease: MusicBedLease?
    /// Bleep tones and sound effects (ai.md §18.5), a third audio track on the rendered timeline; nil without them.
    public let effectsTrack: AVMutableCompositionTrack?
    public let effectsLease: EffectAudioLease?
    /// The clip's voice staged with its speed, volume, fades and mute (design.md §6.9); nil at the defaults.
    public let clipVoiceLease: ClipVoiceLease?
    /// The tracks a reader mixes: the voice, then the music bed and the effects when there are any.
    public var mixedAudioTracks: [AVMutableCompositionTrack] { [audioTrack, musicTrack, effectsTrack].compactMap { $0 } }
    public init(composition: AVMutableComposition, videoTrack: AVMutableCompositionTrack, audioTrack: AVMutableCompositionTrack?, videoComposition: AVVideoComposition, audioMix: AVAudioMix?, renderSize: CGSize, frameDuration: CMTime, voiceLabLease: VoiceLabRenderLease? = nil, contextDemoLease: ContextDemoCompositionLease? = nil, musicTrack: AVMutableCompositionTrack? = nil, musicLease: MusicBedLease? = nil, effectsTrack: AVMutableCompositionTrack? = nil, effectsLease: EffectAudioLease? = nil, clipVoiceLease: ClipVoiceLease? = nil) {
        self.musicTrack = musicTrack; self.musicLease = musicLease; self.clipVoiceLease = clipVoiceLease
        self.effectsTrack = effectsTrack; self.effectsLease = effectsLease
        self.composition = composition; self.videoTrack = videoTrack; self.audioTrack = audioTrack; self.videoComposition = videoComposition; self.audioMix = audioMix; self.renderSize = renderSize; self.frameDuration = frameDuration
        self.voiceLabLease = voiceLabLease
        self.contextDemoLease = contextDemoLease
    }
}

public struct CompositionBuilder: Sendable {
    private let rasterizer: (any CaptionRasterizer)?
    private let sharedRasterizer: Result<CoreTextCaptionRasterizer, any Error>
    /// Where a Voice Lab render keeps its asset snapshots and mix: the temporary directory, or a test's own folder.
    let scratchRoot: URL
    /// Tests only: replaces the caption layout's draw in every frame, to force a failure.
    let captionDrawHook: CaptionLayoutDraw?
    public init() { self.init(legacyRasterizer: nil) }
    public init(rasterizer: any CaptionRasterizer) { self.init(legacyRasterizer: rasterizer) }
    init(scratchRoot: URL) { self.init(legacyRasterizer: nil, scratchRoot: scratchRoot) }
    init(captionDrawHook: @escaping CaptionLayoutDraw) { self.init(legacyRasterizer: nil, captionDrawHook: captionDrawHook) }
    private init(legacyRasterizer: (any CaptionRasterizer)?, scratchRoot: URL = FileManager.default.temporaryDirectory,
                 captionDrawHook: CaptionLayoutDraw? = nil) {
        rasterizer = legacyRasterizer
        sharedRasterizer = Result { try CoreTextCaptionRasterizer(shared: SharedResources.locate()) }
        self.scratchRoot = scratchRoot
        self.captionDrawHook = captionDrawHook
    }

    /// `allowsFractionalFrameRate` is only for the lip-sync mezzanine and result conform, which keep the source's own rate
    /// (29.97 fps and similar); exports keep whole frame rates.
    /// `previewFailures` hears about a preview's failed or degraded frames (design.md §5.4.4 g); exports pass none.
    public func build(_ request: RenderRequest, includeDisclosure: Bool = true,
                      colorCorrection: (scale: Double, bias: Double)? = nil, allowsFractionalFrameRate: Bool = false,
                      previewFailures: PreviewFrameFailures? = nil,
                      isolation: isolated (any Actor)? = #isolation) async throws -> RenderGraph {
        try Task.checkCancellation()
        let plan = request.plan
        let voicePlan = request.voiceLab?.prepared.outputPlan
        let synthetic = voicePlan?.requiresSyntheticRendering == true
        try VoiceLabRenderPreflight.validate(request)
        try ContextDemoCompositionRoute.validate(request)
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
              allowsFractionalFrameRate || request.output.fps.rounded() == request.output.fps,
              request.output.videoBitrate > 0 else {
            throw VoxClipError.exportFailed("Invalid output dimensions or frame rate")
        }
        let videoSpans = try CompositionVideoSpan.build(request)
        let asset = AVURLAsset(url: request.sourceURL)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw VoxClipError.decodeFailed("No video track") }
        let (transform, videoRange, nominalRate) = try await sourceVideo.load(.preferredTransform, .timeRange, .nominalFrameRate)
        let sourceAudio = try await MediaSupport.audioTrack(in: asset)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw VoxClipError.exportFailed("Cannot create video track") }
        let audio = sourceAudio == nil ? nil : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let rate = Int32(synthetic ? voicePlan!.sampleRate : plan.sampleRate)
        for span in videoSpans {
            try Task.checkCancellation()
            let range = span.source
            let cursor = span.output.start
            let scaled = range.duration != span.output.duration
            guard (!scaled && span.zoom == 1) || (range.start >= videoRange.start && range.end <= videoRange.end) else {
                throw VoxClipError.decodeFailed("Retimed source video does not cover its replacement window")
            }
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
            if scaled { video.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: span.output.duration) }
            if !synthetic, let audio, let sourceAudio { try audio.insertTimeRange(range, of: sourceAudio, at: cursor) }
        }
        let duration = CMTime(value: request.timeline.outputSamples, timescale: rate)
        try EffectAudio.freeze(request, video: video, sourceVideo: sourceVideo, videoRange: videoRange, nominalRate: nominalRate, duration: duration)
        let demos = try await ContextDemoCompositionRoute.insert(request, into: composition, scratchRoot: scratchRoot)
        let lipsync = try await LipsyncComposition.insert(request, into: composition, scratchRoot: scratchRoot)
        var lease: VoiceLabRenderLease?
        if synthetic {
            guard sourceAudio != nil, let audio, let voicePlan else { throw VoxClipError.noAudioTrack }
            lease = try await VoiceLabAudioRenderer.stage(request: request, scratchRoot: scratchRoot)
            let mixed = AVURLAsset(url: lease!.mixedAudioURL)
            guard let mixedTrack = try await MediaSupport.audioTrack(in: mixed) else { throw VoxClipError.decodeFailed("Mixed CAF has no audio track") }
            try audio.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: voicePlan.outputSamples, timescale: rate)),
                                      of: mixedTrack, at: .zero)
        }
        var mix: AVAudioMix?
        // Bleeps and mutes silence the edited voice (ai.md §18.5) before clip controls stage it, so a sped-up clip
        // keeps its censoring.
        let silenced = EffectAudio.silencedRanges(request)
        if let audio, !synthetic || !silenced.isEmpty {
            let parameters = AVMutableAudioMixInputParameters(track: audio)
            // The synthetic voice mix has its joins baked in; it only needs the bleeps' silence.
            let tapPlan = synthetic ? EditPlan(sampleRate: Double(rate), totalSamples: request.timeline.outputSamples,
                                               kept: [MediaInterval(startSample: 0, endSample: request.timeline.outputSamples)]) : plan
            parameters.audioTapProcessor = try FadeTap.make(plan: tapPlan, silenced: silenced)
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [parameters]
            mix = audioMix
        }
        // Clip controls (design.md §6.9): the voice is staged with its speed, level, fades and mute, then the whole
        // composition is time-scaled; captions, motion and Voice Lab layers keep edited times the compositor maps back.
        let rendered = CMTime(value: request.renderedSamples, timescale: rate)
        var voiceTrack = audio
        var voiceLease: ClipVoiceLease?
        if let controls = request.clipControls, controls.changesAudio, let audio {
            voiceLease = try await ClipVoiceRenderer.stage(composition: composition, voice: audio, audioMix: mix, editedDuration: duration,
                                                           renderedDuration: rendered, controls: controls, scratchRoot: scratchRoot)
            composition.removeTrack(audio)
            voiceTrack = nil; mix = nil
        }
        if request.speed != 1 { composition.scaleTimeRange(CMTimeRange(start: .zero, duration: duration), toDuration: rendered) }
        if let voiceLease {
            let staged = AVURLAsset(url: voiceLease.url) // Held while its track is inserted.
            guard let stagedTrack = try await MediaSupport.audioTrack(in: staged),
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VoxClipError.decodeFailed("Cannot add the clip voice")
            }
            let stagedRange = try await stagedTrack.load(.timeRange)
            try withExtendedLifetime(staged) {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: min(stagedRange.duration, rendered)), of: stagedTrack, at: .zero)
            }
            voiceTrack = track
        }
        let videoComposition = try makeVideoComposition(request, trackID: video.trackID, duration: duration,
            orientation: MediaSupport.orientation(transform), videoSpans: videoSpans,
            demoLayers: demos.layers, contextDemoLease: demos.lease, lipsyncLayers: lipsync,
            includeDisclosure: includeDisclosure, colorCorrection: colorCorrection, previewFailures: previewFailures)
        let size = videoComposition.renderSize
        let frameDuration = videoComposition.frameDuration
        var musicTrack: AVMutableCompositionTrack?
        var musicLease: MusicBedLease?
        if let music = request.music {
            // The bed is fitted to the rendered length, never sped up, and ducks under the voice as it plays.
            let bed = try await MusicBedRenderer.stage(music, composition: composition, voiceTrack: voiceTrack,
                                                       durationSeconds: rendered.seconds, scratchRoot: scratchRoot)
            let bedAsset = AVURLAsset(url: bed.url) // Held while its track is inserted.
            guard let bedTrack = try await MediaSupport.audioTrack(in: bedAsset),
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VoxClipError.decodeFailed("Cannot add the music track")
            }
            let bedRange = try await bedTrack.load(.timeRange)
            try withExtendedLifetime(bedAsset) {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: min(bedRange.duration, rendered)), of: bedTrack, at: .zero)
            }
            musicTrack = track; musicLease = bed
        }
        var effectsTrack: AVMutableCompositionTrack?
        // Bleep tones and sounds are placed on the rendered timeline (a clip's speed moves them, never their pitch).
        let effectsLease = try await EffectAudio.stage(request, durationSeconds: rendered.seconds, scratchRoot: scratchRoot)
        if let effectsLease {
            let effectsAsset = AVURLAsset(url: effectsLease.url) // Held while its track is inserted.
            guard let effectTrack = try await MediaSupport.audioTrack(in: effectsAsset),
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VoxClipError.decodeFailed("Cannot add the effects track")
            }
            let effectRange = try await effectTrack.load(.timeRange)
            try withExtendedLifetime(effectsAsset) {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: min(effectRange.duration, rendered)), of: effectTrack, at: .zero)
            }
            effectsTrack = track
        }
        return RenderGraph(composition: composition, videoTrack: video, audioTrack: voiceTrack, videoComposition: videoComposition,
                           audioMix: mix, renderSize: size, frameDuration: frameDuration, voiceLabLease: lease,
                           contextDemoLease: demos.lease, musicTrack: musicTrack, musicLease: musicLease,
                           effectsTrack: effectsTrack, effectsLease: effectsLease, clipVoiceLease: voiceLease)
    }

    func makeVideoComposition(_ request: RenderRequest, trackID: CMPersistentTrackID, duration: CMTime,
                              orientation: CGImagePropertyOrientation, videoSpans: [CompositionVideoSpan] = [],
                              demoLayers: [CompositionDemoLayer] = [],
                              contextDemoLease: ContextDemoCompositionLease? = nil,
                              lipsyncLayers: [LipsyncVideoLayer] = [], includeDisclosure: Bool = true,
                              colorCorrection: (scale: Double, bias: Double)? = nil,
                              previewFailures: PreviewFrameFailures? = nil) throws -> AVVideoComposition {
        let size = CGSize(width: request.output.size.width, height: request.output.size.height)
        guard size.width >= 2, size.height >= 2, max(size.width, size.height) <= 1920,
              request.output.fps.isFinite, request.output.fps >= 1, request.output.fps <= 60 else {
            throw VoxClipError.exportFailed("Invalid render configuration")
        }
        let fps = request.output.fps
        let frameDuration = fps.rounded() == fps ? CMTime(value: 1, timescale: Int32(fps)) : CMTime(seconds: 1 / fps, preferredTimescale: 600_000)
        let needsRasterizer = request.captionLayout != nil || request.style != nil
        let disclosure: VoiceLabDisclosureOverlay?
        if let input = request.voiceLab, input.prepared.disclosure.required, includeDisclosure {
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
        let captionRasterizer = needsRasterizer ? try sharedRasterizer.get() : nil
        let effects = request.effects.flatMap { $0.picture.isEmpty ? nil : EffectFrames(input: $0) }
        let framingSpans = videoSpans.filter { $0.zoom > 1 }
        let boundaries = ([CMTime.zero, duration] + framingSpans.flatMap { [$0.output.start, $0.output.end] } +
            demoLayers.flatMap { [$0.output.start, $0.output.end] } +
            lipsyncLayers.flatMap { [$0.output.start, $0.output.end] }).sorted().reduce(into: [CMTime]()) { result, time in
                if result.last != time { result.append(time) }
            }
        var spanIndex = 0, layerIndex = 0
        // Edited boundaries onto the rendered timeline: identical at 1×, divided by the clip's speed otherwise.
        let speed = request.speed
        let samples = request.renderedSamples
        let timescale = Int32(request.timeline.sampleRate)
        func rendered(_ time: CMTime) -> CMTime {
            guard speed != 1 else { return time }
            if time == duration { return CMTime(value: samples, timescale: timescale) }
            return CMTime(value: min(samples, Int64((time.seconds * request.timeline.sampleRate / speed).rounded())), timescale: timescale)
        }
        let instructions = zip(boundaries, boundaries.dropFirst()).compactMap { start, end -> RenderInstruction? in
            while spanIndex < framingSpans.count && framingSpans[spanIndex].output.end <= start { spanIndex += 1 }
            while layerIndex < demoLayers.count && demoLayers[layerIndex].output.end <= start { layerIndex += 1 }
            let span = spanIndex < framingSpans.count && framingSpans[spanIndex].output.start <= start ? framingSpans[spanIndex] : nil
            let layer = layerIndex < demoLayers.count && demoLayers[layerIndex].output.start <= start ? demoLayers[layerIndex] : nil
            let range = CMTimeRange(start: rendered(start), end: rendered(end))
            guard !range.isEmpty else { return nil }
            return RenderInstruction(timeRange: range, sourceTrackID: trackID,
                request: request, orientation: orientation, rasterizer: captionRasterizer,
                legacyRasterizer: rasterizer, disclosure: disclosure, demoLayer: layer,
                contextDemoLease: contextDemoLease, videoZoom: span?.zoom ?? 1,
                videoAnchorX: span?.anchorX ?? 0.5, videoAnchorY: span?.anchorY ?? 0.5,
                lipsyncLayers: lipsyncLayers.filter { $0.output.start < end && $0.output.end > start }, colorCorrection: colorCorrection,
                effects: effects, previewFailures: request.forPreview ? previewFailures : nil, captionDrawHook: captionDrawHook)
        }
        let config = AVVideoComposition.Configuration(colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2, colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
            customVideoCompositorClass: FrameCompositor.self, frameDuration: frameDuration, instructions: instructions, renderSize: size)
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
