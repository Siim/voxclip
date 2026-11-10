import AVFoundation
import CoreImage
import Foundation
import Vision
import VoxClipCore

public enum LipsyncPreparationError: Error, LocalizedError, Sendable, Equatable {
    case noClearFace, unsupportedVideo
    public var errorDescription: String? {
        switch self {
        case .noClearFace: "No clear face in this part."
        case .unsupportedVideo: "This part cannot be prepared for lip sync. Your original video is unchanged."
        }
    }
}

public struct PreparedLipsyncWindow: Sendable {
    public let video: LipsyncUploadFile
    public let audio: LipsyncUploadFile
    public let width: Int
    public let height: Int
    public let fps: Double
    public let window: LipsyncRenderWindow
    /// The needed length, the voice's: what the result is cut back to. The uploads run `LipsyncLimits.tailMarginSeconds` longer.
    public let neededSeconds: Double
    /// The upload's picture (`LipsyncPictureFingerprint`), which finds a paid attempt again when the encode differs.
    let picture: Data
}

public enum LipsyncWindowPreparation {
    public typealias FaceDetector = @Sendable (CGImage) throws -> Double

    /// The uploaded window's size: the source as oriented, scaled down to the compositor's 1920-pixel bound with its aspect
    /// kept (`OutputSizing`, as a source-shaped export). A 4K camera file is sent at 1920 × 1080; the compositor fills the
    /// lip-synced frames into the output from their own size. A frame rate outside 1–60 or a picture under 16 pixels is
    /// refused before anything renders (MVP45: every 4K source was refused here, voice-lab §9).
    public static func uploadSize(_ video: MediaVideo) throws -> PixelSize {
        let oriented = OutputSizing.orientedSize(video)
        guard oriented.width >= 16, oriented.height >= 16, video.frameRate.isFinite, (1...60).contains(video.frameRate),
              let size = try? OutputSizing.outputSize(source: oriented, aspect: .source),
              (16...1920).contains(size.width), (16...1920).contains(size.height),
              size.width.isMultiple(of: 2), size.height.isMultiple(of: 2) else { throw LipsyncPreparationError.unsupportedVideo }
        return size
    }

    public static func prepare(request: RenderRequest, window: LipsyncRenderWindow, scratchRoot: URL,
                               detector: FaceDetector? = nil) async throws -> PreparedLipsyncWindow {
        let folder = scratchRoot.appendingPathComponent("lipsync-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = request
        guard let sourceVideo = request.voiceLab?.project.media.source.video else { throw LipsyncPreparationError.unsupportedVideo }
        let size = try uploadSize(sourceVideo)
        let width = size.width, height = size.height
        let fps = sourceVideo.frameRate
        request.output = OutputSpec(size: size, fps: fps,
            videoBitrate: Int((0.33 * Double(width) * Double(height) * fps).rounded()))
        // The window is the clean picture: the compositor applies the clip's controls (flip, turn, frame, look, speed), its
        // effects and captions once over the lip-synced frames, so none of them is baked in here, and fal.ai hears the
        // voice without the music bed.
        request.captions = CaptionTrack(); request.captionLayout = nil; request.style = nil
        request.clipControls = nil; request.effects = nil; request.music = nil
        let graph = try await CompositionBuilder().build(request, includeDisclosure: false, allowsFractionalFrameRate: true)
        let rate = request.timeline.sampleRate
        let range = CMTimeRange(start: CMTime(value: window.outputStartSample, timescale: Int32(rate)),
            end: CMTime(value: window.outputEndSample, timescale: Int32(rate)))
        let generator = AVAssetImageGenerator(asset: graph.composition)
        generator.videoComposition = graph.videoComposition
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var heights: [Double] = []
        for offset in stride(from: 0.0, to: range.duration.seconds, by: 0.5) {
            try Task.checkCancellation()
            let frame = try await generator.image(at: range.start + CMTime(seconds: offset, preferredTimescale: 600_000)).image
            if let detector { heights.append(try detector(frame)) }
            else { heights.append(try await VisionQueue.run(frame, largestFaceHeight)) }
        }
        guard LipsyncFaceCheck.passes(largestFaceHeights: heights) else { throw LipsyncPreparationError.noClearFace }
        // The tail margin (sync-3 drops frames at the end): the video runs on into the next frames where the timeline has
        // them, else holds its last frame; the audio runs on in silence. The import cuts the result back to `needed`.
        let needed = range.duration.seconds
        let neededFrames = Int((needed * 48_000).rounded())
        let marginFrames = Int((LipsyncLimits.tailMarginSeconds(needed) * 48_000).rounded(.up))
        let upload = Double(neededFrames + marginFrames) / 48_000
        let available = graph.composition.duration
        let uploadEnd = CMTimeMinimum(range.start + CMTime(value: Int64(neededFrames + marginFrames), timescale: 48_000), available)
        let videoFrames = Int((upload * fps - 1e-6).rounded(.up))
        let videoURL = folder.appendingPathComponent("window.mp4")
        try await LipsyncMezzanine.write(graph: graph, range: CMTimeRange(start: range.start, end: uploadEnd), output: request.output,
                                         to: videoURL, frames: videoFrames)
        let audioURL = folder.appendingPathComponent("mixed.wav")
        let picture = try await LipsyncPictureFingerprint.make(videoURL, seconds: needed)
        let wav = try await mixedWAV(graph: graph, range: range, silence: marginFrames)
        try wav.write(to: audioURL, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioURL.path)
        return try PreparedLipsyncWindow(video: LipsyncUploadFile(file: videoURL, durationSeconds: upload, contentType: "video/mp4"),
            audio: LipsyncUploadFile(file: audioURL, durationSeconds: upload, contentType: "audio/wav"),
            width: width, height: height, fps: fps, window: window, neededSeconds: needed, picture: picture)
    }

    /// The tallest face's height as a fraction of the frame, or 0. Synchronous Vision: `prepare` runs it on `VisionQueue`.
    static func largestFaceHeight(_ frame: CGImage) throws -> Double {
        VisionQueue.assertOnQueue()
        let faces = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: frame, options: [:]).perform([faces])
        return faces.results?.map { Double($0.boundingBox.height) }.max() ?? 0
    }

    /// The window's final mixed audio, then `silence` frames of silence (the tail margin).
    static func mixedWAV(graph: RenderGraph, range: CMTimeRange, silence: Int = 0) async throws -> Data {
        guard let track = graph.audioTrack else { throw LipsyncError.invalidMedia }
        let reader = try AVAssetReader(asset: graph.composition)
        reader.timeRange = range
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        output.audioMix = graph.audioMix
        let provider = reader.outputProvider(for: output)
        guard reader.startReading() else { throw LipsyncError.invalidMedia }
        defer { reader.cancelReading() }
        let frames = Int((range.duration.seconds * 48_000).rounded())
        guard frames >= 144_000, silence >= 0, frames + silence <= 14_400_000 else { throw LipsyncError.invalidInput }
        var pcm = Data(count: (frames + silence) * 2), readFrames = 0
        while let sample = try await MediaSupport.nextSample(provider) {
            try Task.checkCancellation()
            let first = Int(((sample.presentationTimeStamp.seconds - range.start.seconds) * 48_000).rounded())
            try sample.withUnsafeSampleBuffer { raw in
                guard let block = CMSampleBufferGetDataBuffer(raw) else { throw LipsyncError.invalidMedia }
                let count = CMSampleBufferGetNumSamples(raw)
                guard CMBlockBufferGetDataLength(block) == count * 2 else { throw LipsyncError.invalidMedia }
                let skip = max(0, -first), target = max(0, first)
                let length = min(count - skip, frames - target)
                guard length >= 0 else { return }
                let status = pcm.withUnsafeMutableBytes { buffer in
                    CMBlockBufferCopyDataBytes(block, atOffset: skip * 2, dataLength: length * 2,
                        destination: buffer.baseAddress!.advanced(by: target * 2))
                }
                guard status == noErr else { throw LipsyncError.invalidMedia }
                readFrames += length
            }
        }
        // A window that runs to the timeline's end can find the mixed audio a few samples short of the picture (the smoke's
        // whole clip: 32 samples, 0.7 ms); the missing tail is silence already. More than 10 ms missing is a broken mix.
        guard reader.status == .completed, readFrames >= frames - 480 else { throw LipsyncError.invalidMedia }
        return VoiceLabWavePCM(rate: 48_000, channels: 1, bits: 16, floating: false, pcm: pcm).bytes
    }
}

enum LipsyncMezzanine {
    /// Writes `range` of the graph's picture as H.264, at least `frames` frames: when the graph ends first, its last frame is
    /// held (the lip-sync upload's tail margin, a result a few frames short).
    static func write(graph: RenderGraph, range: CMTimeRange, output: OutputSpec, to url: URL, frames: Int? = nil,
                      isolation: isolated (any Actor)? = #isolation) async throws {
        let reader = try AVAssetReader(asset: graph.composition)
        reader.timeRange = range
        let video = AVAssetReaderVideoCompositionOutput(videoTracks: graph.composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        video.videoComposition = graph.videoComposition
        let provider = reader.outputProvider(for: video)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: output.size.width, AVVideoHeightKey: output.size.height,
            AVVideoColorPropertiesKey: MediaSupport.colorProperties,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: output.videoBitrate,
                AVVideoExpectedSourceFrameRateKey: output.fps, AVVideoMaxKeyFrameIntervalKey: Int(output.fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
        let receiver = writer.inputReceiver(for: input)
        do {
            guard writer.startWriting() else { throw LipsyncError.invalidMedia }
            writer.startSession(atSourceTime: .zero)
            guard reader.startReading() else { throw LipsyncError.invalidMedia }
            var frameIndex: Int64 = 0
            let frameDuration = CMTime(seconds: 1 / output.fps, preferredTimescale: 600_000)
            var last: CMReadySampleBuffer<CVReadOnlyPixelBuffer>?
            func append(_ source: CMReadySampleBuffer<CVReadOnlyPixelBuffer>) async throws {
                var frame = source
                frame.duration = frameDuration
                frame.presentationTimeStamp = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
                let encoded = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(frame)
                while try !receiver.appendImmediately(encoded) {
                    try Task.checkCancellation()
                    guard writer.status == .writing else { throw LipsyncError.invalidMedia }
                    await Task.yield()
                }
                frameIndex += 1
            }
            while let sample = try await MediaSupport.nextSample(provider) {
                try Task.checkCancellation()
                guard let frame = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(sample) else { throw LipsyncError.invalidMedia }
                try await append(frame)
                last = frame
            }
            guard reader.status == .completed, let last else { throw LipsyncError.invalidMedia }
            let wanted = max(Int64(frames ?? 0), Int64(ceil(range.duration.seconds * output.fps)))
            while frameIndex < wanted {
                try Task.checkCancellation()
                try await append(last)
            }
            let encodedDuration = Double(wanted) / output.fps
            receiver.finish()
            writer.endSession(atSourceTime: CMTime(seconds: encodedDuration, preferredTimescale: 600_000))
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw LipsyncError.invalidMedia }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            reader.cancelReading(); writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
