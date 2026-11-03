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
}

public enum LipsyncWindowPreparation {
    public typealias FaceDetector = @Sendable (CGImage) throws -> Double

    public static func prepare(request: RenderRequest, window: LipsyncRenderWindow, scratchRoot: URL,
                               detector: FaceDetector? = nil) async throws -> PreparedLipsyncWindow {
        let folder = scratchRoot.appendingPathComponent("lipsync-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = request
        guard let sourceVideo = request.voiceLab?.project.media.source.video else { throw LipsyncPreparationError.unsupportedVideo }
        let rotated = sourceVideo.rotationDegrees == 90 || sourceVideo.rotationDegrees == 270
        let width = rotated ? sourceVideo.height : sourceVideo.width
        let height = rotated ? sourceVideo.width : sourceVideo.height
        let fps = sourceVideo.frameRate
        guard (16...1920).contains(width), (16...1920).contains(height), width.isMultiple(of: 2),
              height.isMultiple(of: 2), (1...60).contains(fps) else { throw LipsyncPreparationError.unsupportedVideo }
        request.output = OutputSpec(size: PixelSize(width: width, height: height), fps: fps,
            videoBitrate: Int((0.33 * Double(width) * Double(height) * fps).rounded()))
        request.captions = CaptionTrack(); request.captionLayout = nil; request.style = nil
        let graph = try await CompositionBuilder().build(request, includeDisclosure: false)
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
            else {
                let faces = VNDetectFaceRectanglesRequest()
                try VNImageRequestHandler(cgImage: frame, options: [:]).perform([faces])
                heights.append(faces.results?.map { Double($0.boundingBox.height) }.max() ?? 0)
            }
        }
        guard LipsyncFaceCheck.passes(largestFaceHeights: heights) else { throw LipsyncPreparationError.noClearFace }
        let videoURL = folder.appendingPathComponent("window.mp4")
        try await LipsyncMezzanine.write(graph: graph, range: range, output: request.output, to: videoURL)
        let audioURL = folder.appendingPathComponent("mixed.wav")
        let wav = try await mixedWAV(graph: graph, range: range)
        try wav.write(to: audioURL, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioURL.path)
        let seconds = range.duration.seconds
        return try PreparedLipsyncWindow(video: LipsyncUploadFile(file: videoURL, durationSeconds: seconds, contentType: "video/mp4"),
            audio: LipsyncUploadFile(file: audioURL, durationSeconds: seconds, contentType: "audio/wav"),
            width: width, height: height, fps: fps, window: window)
    }

    static func mixedWAV(graph: RenderGraph, range: CMTimeRange) async throws -> Data {
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
        guard frames >= 144_000, frames <= 14_400_000 else { throw LipsyncError.invalidInput }
        var pcm = Data(count: frames * 2), readFrames = 0
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
        guard reader.status == .completed, readFrames >= frames - 1 else { throw LipsyncError.invalidMedia }
        return VoiceLabWavePCM(rate: 48_000, channels: 1, bits: 16, floating: false, pcm: pcm).bytes
    }
}

enum LipsyncMezzanine {
    static func write(graph: RenderGraph, range: CMTimeRange, output: OutputSpec, to url: URL,
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
            while let sample = try await MediaSupport.nextSample(provider) {
                try Task.checkCancellation()
                guard var frame = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(sample) else { throw LipsyncError.invalidMedia }
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
            guard reader.status == .completed else { throw LipsyncError.invalidMedia }
            let encodedDuration = ceil(range.duration.seconds * output.fps) / output.fps
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
