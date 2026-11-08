import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// A synthetic result shaped like fal.ai's own sync-3 example (measured by the lead on 2026-11-08, never committed): H.264
/// at the window's size and rate, `frames` frames that keep the input's start and stop short at the end, and a separate
/// AAC track resampled to 24 kHz that is shorter than the picture. Frame k is a flat grey of `level(k)`, so a test can
/// read which input frame it is.
enum FalShapedResult {
    static func level(_ frame: Int) -> UInt8 { UInt8(30 + (frame * 2) % 200) }

    static func write(to destination: URL, frames: Int, fps: Int, width: Int = 320, height: Int = 180,
                      audioSeconds: Double?) async throws {
        let folder = destination.deletingLastPathComponent().appendingPathComponent("fal-shaped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("video.mp4")
        try await writeVideo(to: video, frames: frames, fps: fps, width: width, height: height)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let videoTrack = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: Int64(frames), timescale: Int32(fps))),
                                       of: sourceVideo, at: .zero)
        if let audioSeconds {
            let audio = try await writeAAC24k(in: folder, seconds: audioSeconds)
            let audioAsset = AVURLAsset(url: audio)
            let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio)[0]
            let range = try await sourceAudio.load(.timeRange)
            let audioTrack = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        }
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: destination, as: .mp4)
    }

    private static func writeVideo(to url: URL, frames: Int, fps: Int, width: Int, height: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoColorPropertiesKey: MediaSupport.colorProperties,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoExpectedSourceFrameRateKey: fps,
                                              AVVideoMaxKeyFrameIntervalKey: fps]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                await Task.yield()
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                      [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &buffer) == kCVReturnSuccess,
                  let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let value = level(frame)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<height {
                let line = base.advanced(by: row * rowBytes)
                for column in 0..<width {
                    line[column * 4] = value; line[column * 4 + 1] = value; line[column * 4 + 2] = value; line[column * 4 + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: Int32(fps)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// fal.ai's audio: AAC resampled to 24 kHz, mono, a tone (never our voice).
    private static func writeAAC24k(in folder: URL, seconds: Double) async throws -> URL {
        let frames = Int((seconds * 48_000).rounded())
        var pcm = Data(count: frames * 2)
        pcm.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frames { samples[index] = Int16(8_000 * sin(2 * Double.pi * 330 * Double(index) / 48_000)) }
        }
        let wav = folder.appendingPathComponent("tone.wav")
        try (VoiceLabAssetStore.wavHeader(frames: frames, sampleRate: 48_000) + pcm).write(to: wav)
        let asset = AVURLAsset(url: wav)
        let reader = try AVAssetReader(asset: asset)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: 24_000, channels: 1)))
        let destination = folder.appendingPathComponent("fal-audio.m4a")
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000])
        let receiver = writer.inputReceiver(for: input)
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        while let sample = try await provider.next() { try await receiver.append(sample) }
        receiver.finish()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return destination
    }

    /// The video track's frame count and its last frame's grey level (read back through the decoder).
    static func frames(_ url: URL) async throws -> (count: Int, levels: [UInt8]) {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var levels: [UInt8] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let center = base.advanced(by: (CVPixelBufferGetHeight(buffer) / 2) * rowBytes + (CVPixelBufferGetWidth(buffer) / 2) * 4)
            levels.append(center[1])
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        return (levels.count, levels)
    }
}

/// fal.ai's queue, stubbed: one accepted job whose result is `bytes`, and the documented payload delete. No network.
actor LipsyncImportHTTP: LipsyncHTTPClient {
    let bytes: Data
    let app: String
    private(set) var deletions = 0
    private(set) var submits = 0
    private(set) var resultFetches = 0
    private(set) var downloads = 0
    var downloadFails = false
    var deleteBody = #"{"cdn_delete_results":[{"link":"https://v3.fal.media/files/fixture/output.mp4","exception":null}]}"#
    var deleteStatus = 200
    private let barrier: LipsyncImportBarrier?
    static let requestID = "11111111-2222-4333-8444-555555555555"

    init(bytes: Data, app: String = "fal-ai/latentsync", barrier: LipsyncImportBarrier? = nil) {
        self.bytes = bytes; self.app = app; self.barrier = barrier
    }
    func failDownloads(_ value: Bool) { downloadFails = value }
    func setDelete(status: Int, body: String) { deleteStatus = status; deleteBody = body }

    func send(_ request: URLRequest, limit: Int, permit: VoiceDispatchPermit?) async throws -> LipsyncHTTPResponse {
        if let permit { try permit.start {} }
        let prefix = "https://queue.fal.run/\(app)/requests/\(Self.requestID)"
        let body: String
        if request.httpMethod == "POST" {
            submits += 1
            body = "{\"request_id\":\"\(Self.requestID)\",\"status_url\":\"\(prefix)/status\",\"response_url\":\"\(prefix)\",\"cancel_url\":\"\(prefix)/cancel\"}"
        } else if request.httpMethod == "PUT" {
            return .init(status: 202, body: Data(#"{"status":"CANCELLATION_REQUESTED"}"#.utf8))
        } else if request.httpMethod == "DELETE" {
            deletions += 1
            return .init(status: deleteStatus, body: Data(deleteBody.utf8))
        } else if request.url?.path.hasSuffix("/status") == true {
            body = #"{"status":"COMPLETED"}"#
        } else {
            resultFetches += 1
            body = "{\"video\":{\"url\":\"https://v3.fal.media/files/fixture/output.mp4\",\"content_type\":\"video/mp4\",\"file_size\":\(bytes.count)}}"
        }
        return .init(status: 200, body: Data(body.utf8))
    }

    func download(_ request: URLRequest, to file: URL, limit: Int) async throws {
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        if let barrier { await barrier.block() }
        downloads += 1
        if downloadFails { throw LipsyncError.network }
        try bytes.write(to: file)
    }
}

actor LipsyncImportBarrier {
    private var entered = false
    private var waiter: TestContinuation<Void>?
    private var arrival: TestContinuation<Void>?
    func block() async {
        entered = true; arrival?.resume(); arrival = nil
        await withTestDeadline { waiter = $0 }
    }
    func waitUntilEntered() async { if !entered { await withTestDeadline { arrival = $0 } } }
    func release() { waiter?.resume(); waiter = nil }
}

struct LipsyncImportKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { "synthetic-import-fixture-key" }
}

/// Records the provider's log lines (already redacted) for the check tests.
actor LipsyncImportLog: Redacting {
    private(set) var lines: [String] = []
    func register(secret: String) {}
    func redact(_ text: String) -> String { text }
    func write(_ entry: LogEntry) { lines.append(entry.message) }
}

enum LipsyncImportFixture {
    static let projectID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    static func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("lipsync-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    static func provider(http: LipsyncImportHTTP, logger: any Redacting = RedactingLogger(homeDirectory: "/synthetic-home")) throws -> FalLipsyncProvider {
        let prices = try VoiceLabPriceCatalog.load(shared: SharedResources(root: FixtureLoader.sharedRoot()))
        return FalLipsyncProvider(keys: LipsyncImportKeys(), prices: prices, http: http, logger: logger,
                                  now: { Date(timeIntervalSince1970: 1_793_577_600) }, monotonic: { .zero }, sleep: { _ in })
    }

    static func consent(root: URL) async throws -> (VoiceConsentStore, String) {
        let store = VoiceConsentStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path], home: root))
        let wav = VoiceLabAssetStore.wavHeader(frames: 240_000, sampleRate: 48_000) + Data(repeating: 0, count: 480_000)
        var object = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/consent-record.json")) as? [String: Any])
        var statement = try #require(object["statement"] as? [String: Any])
        statement["audioSha256"] = SpeechSHA256.hex(wav); object["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        if (try? await store.load(record.id)) == nil {
            try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        }
        return (store, record.id)
    }

    static func signedInput(video: Bool, seconds: Double, sha: String? = nil) throws -> LipsyncSignedInput {
        let text = "https://fixture-bucket.s3.us-east-1.amazonaws.com/\(video ? "window.mp4" : "mixed.wav")"
            + "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=fixture&X-Amz-Date=20261102T000000Z"
            + "&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=\(String(repeating: "0", count: 64))&versionId=fixture-version"
        return try LipsyncSignedInput(url: URL(string: text)!, sha256: sha ?? String(repeating: video ? "a" : "b", count: 64),
                                      durationSeconds: seconds, contentType: video ? "video/mp4" : "audio/wav", byteCount: 1_200)
    }

    /// A quoted, approved and submitted job over signed inputs of `seconds` (video and audio alike).
    static func submit(root: URL, provider: FalLipsyncProvider, model: LipsyncModel, seconds: Double, fps: Double,
                       syncMode: SyncMode = .cutOff) async throws -> (LipsyncQuote, LipsyncJob) {
        let quote = try await provider.quote(model: model, video: signedInput(video: true, seconds: seconds),
                                             audio: signedInput(video: false, seconds: seconds), options: .init(syncMode: syncMode), fps: fps)
        let (store, recordID) = try await consent(root: root)
        let approval = try await provider.approve(quote, consentStore: store, recordID: recordID, acceptsPaidJob: true, acceptsMediaTransfer: true)
        return (quote, try await provider.submit(quote, approval: approval))
    }
}
