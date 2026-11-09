#if DEBUG
import AVFoundation
import Foundation
import VoxClipCore

/// The Rewrite smoke's fal.ai answer (DEBUG only): what sync-3 does to an upload, as measured on fal.ai's own example
/// (MVP46): the start is kept and `droppingFrames` frames are dropped at the end, re-encoded as H.264, with a separate AAC
/// track of the upload's audio resampled to 24 kHz and a little shorter than the picture. The picture is the upload's own,
/// so the face, colour and size checks see what they would.
package enum LipsyncShortResultStandIn {
    package static func make(video: Data, audio: Data, droppingFrames: Int) async throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-fal-standin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let upload = folder.appendingPathComponent("upload.mp4"), wav = folder.appendingPathComponent("upload.wav")
        try video.write(to: upload); try audio.write(to: wav)
        let asset = AVURLAsset(url: upload)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LipsyncError.invalidMedia }
        let (size, rate) = try await track.load(.naturalSize, .nominalFrameRate)
        let fps = Double(rate)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw LipsyncError.invalidMedia }
        var frames: [CVPixelBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) { frames.append(buffer) }
        }
        guard frames.count > droppingFrames + 1 else { throw LipsyncError.invalidMedia }
        frames.removeLast(droppingFrames)
        let picture = folder.appendingPathComponent("picture.mp4")
        try await writePicture(frames, fps: fps, size: size, to: picture)
        let pictureSeconds = Double(frames.count) / fps
        let sound = folder.appendingPathComponent("sound.m4a")
        try await writeAAC24k(wav, to: sound)
        let composition = AVMutableComposition()
        let pictureAsset = AVURLAsset(url: picture), soundAsset = AVURLAsset(url: sound)
        guard let sourceVideo = try await pictureAsset.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await soundAsset.loadTracks(withMediaType: .audio).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw LipsyncError.invalidMedia }
        try videoTrack.insertTimeRange(try await sourceVideo.load(.timeRange), of: sourceVideo, at: .zero)
        // fal.ai's audio ran about 0.17 s under its picture in the example.
        let audioRange = try await sourceAudio.load(.timeRange)
        let audioSeconds = min(audioRange.duration.seconds, max(0.5, pictureSeconds - 0.17))
        try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: audioSeconds, preferredTimescale: 24_000)),
                                       of: sourceAudio, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw LipsyncError.invalidMedia }
        let result = folder.appendingPathComponent("result.mp4")
        try await session.export(to: result, as: .mp4)
        return try Data(contentsOf: result)
    }

    private static func writePicture(_ frames: [CVPixelBuffer], fps: Double, size: CGSize, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height), AVVideoColorPropertiesKey: MediaSupport.colorProperties])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw LipsyncError.invalidMedia }
        writer.startSession(atSourceTime: .zero)
        let frameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 600_000)
        for (index, frame) in frames.enumerated() {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw LipsyncError.invalidMedia }
                await Task.yield()
            }
            guard adaptor.append(frame, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(index))) else {
                throw LipsyncError.invalidMedia
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(frames.count)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw LipsyncError.invalidMedia }
    }

    private static func writeAAC24k(_ wav: URL, to url: URL) async throws {
        let asset = AVURLAsset(url: wav)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw LipsyncError.invalidMedia }
        let reader = try AVAssetReader(asset: asset)
        let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: 24_000, channels: 1)))
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000])
        let receiver = writer.inputReceiver(for: input)
        guard writer.startWriting(), reader.startReading() else { throw LipsyncError.invalidMedia }
        writer.startSession(atSourceTime: .zero)
        while let sample = try await provider.next() { try await receiver.append(sample) }
        receiver.finish()
        await writer.finishWriting()
        guard writer.status == .completed else { throw LipsyncError.invalidMedia }
    }
}

/// fal.ai, stood in for the Rewrite smoke (DEBUG only): uploads are kept, every submit is accepted, the job is done at the
/// first poll, the result is `LipsyncShortResultStandIn` over the last upload, and the payload delete answers as documented.
package actor LipsyncSmokeFalHTTP: LipsyncHTTPClient {
    private let droppingFrames: Int
    private var uploads: [Data] = []
    package private(set) var submits = 0
    package private(set) var deletions = 0
    private var requestID = UUID().uuidString.lowercased()

    package init(droppingFrames: Int) { self.droppingFrames = droppingFrames }

    package func send(_ request: URLRequest, limit: Int, permit: VoiceDispatchPermit?) async throws -> LipsyncHTTPResponse {
        if let permit { try permit.start {} }
        let path = request.url?.path ?? ""
        let app = path.hasPrefix("/fal-ai/latentsync") ? "fal-ai/latentsync" : "fal-ai/sync-lipsync"
        let body: String
        switch (request.url?.host, request.httpMethod) {
        case ("rest.fal.ai", _):
            body = "{\"upload_url\":\"https://storage.fal.ai/upload/smoke-\(uploads.count)\",\"file_url\":\"https://v3.fal.media/files/smoke/\(uploads.count)\"}"
        case ("storage.fal.ai", _):
            uploads.append(request.httpBody ?? Data())
            return .init(status: 200, body: Data())
        case ("api.fal.ai", "DELETE"?):
            deletions += 1
            body = #"{"cdn_delete_results":[{"link":"https://v3.fal.media/files/smoke/result.mp4","exception":null}]}"#
        case ("queue.fal.run", "POST"?):
            submits += 1; requestID = UUID().uuidString.lowercased()
            let fresh = "https://queue.fal.run/\(app)/requests/\(requestID)"
            body = "{\"request_id\":\"\(requestID)\",\"status_url\":\"\(fresh)/status\",\"response_url\":\"\(fresh)\",\"cancel_url\":\"\(fresh)/cancel\"}"
        case ("queue.fal.run", "PUT"?):
            body = #"{"status":"CANCELLATION_REQUESTED"}"#
            return .init(status: 202, body: Data(body.utf8))
        default:
            body = path.hasSuffix("/status") ? #"{"status":"COMPLETED"}"#
                : #"{"video":{"url":"https://v3.fal.media/files/smoke/result.mp4","content_type":"video/mp4"}}"#
        }
        return .init(status: 200, body: Data(body.utf8))
    }

    package func download(_ request: URLRequest, to file: URL, limit: Int) async throws {
        guard uploads.count >= 2 else { throw LipsyncError.invalidResponse }
        let result = try await LipsyncShortResultStandIn.make(video: uploads[uploads.count - 2], audio: uploads[uploads.count - 1],
                                                              droppingFrames: droppingFrames)
        try result.write(to: file)
    }
}
#endif
