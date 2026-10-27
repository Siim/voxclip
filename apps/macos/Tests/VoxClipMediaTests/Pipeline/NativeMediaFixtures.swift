import AVFoundation
import CoreGraphics
import Foundation
import Darwin
import Synchronization
import VideoToolbox
import VoxClipCore
@testable import VoxClipMedia

private let nativeFixtureRoot: URL = {
    let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("voxclip-fixtures-\(UUID().uuidString)")
    atexit { try? FileManager.default.removeItem(at: nativeFixtureRoot) }
    return root
}()

actor NativeMediaFixtures {
    struct Timeout: Error, CustomStringConvertible {
        let limit: Duration
        var description: String { "Fixture generation did not finish within \(limit)." }
    }

    static let shared = NativeMediaFixtures()
    static let generationLimit: Duration = .seconds(120)
    private static let hardwareH264 = hardwareEncoderAvailable(kCMVideoCodecType_H264)
    private static let hardwareHEVC = hardwareEncoderAvailable(kCMVideoCodecType_HEVC)
    private let root = nativeFixtureRoot
    private var pending: [String: Task<URL, any Error>] = [:]

    /// A generated fixture. Every caller of one name shares a generation that runs off the actor and
    /// fails, and is cancelled, after `generationLimit`; a caller's own cancellation, such as its time
    /// limit, ends its wait.
    func file(_ name: String = "bars-tone.mov") async throws -> URL {
        let task = pending[name] ?? {
            let generation = Task.detached { try await self.generate(name) }
            return Task {
                do { return try await Self.value(of: generation, within: Self.generationLimit) }
                catch { generation.cancel(); throw error }
            }
        }()
        pending[name] = task
        return try await Self.value(of: task)
    }

    /// The task's value, or an error as soon as the caller is cancelled or `limit` passes. The task
    /// is not awaited after that, so a stalled AVFoundation call cannot hold every waiting test.
    static func value<Value: Sendable>(of task: Task<Value, any Error>, within limit: Duration? = nil) async throws -> Value {
        let waiter = Waiter<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.start(continuation)
                let timer = limit.map { limit in
                    Task {
                        try await Task.sleep(for: limit)
                        waiter.resume(with: .failure(Timeout(limit: limit)))
                    }
                }
                Task {
                    let result = await task.result
                    timer?.cancel()
                    waiter.resume(with: result)
                }
                if Task.isCancelled { waiter.resume(with: .failure(CancellationError())) }
            }
        } onCancel: {
            waiter.resume(with: .failure(CancellationError()))
        }
    }

    /// One wait's continuation, resumed once by whichever of the result, the time limit and the
    /// caller's cancellation comes first. A Sendable class, so the escaping tasks share it by reference.
    private final class Waiter<Value: Sendable>: Sendable {
        private let continuation: Mutex<CheckedContinuation<Value, any Error>?> = Mutex(nil)

        func start(_ continuation: CheckedContinuation<Value, any Error>) {
            self.continuation.withLock { $0 = continuation }
        }

        func resume(with result: Result<Value, any Error>) {
            continuation.withLock { continuation in
                defer { continuation = nil }
                return continuation
            }?.resume(with: result)
        }
    }

    /// Fixtures need the hardware encoder, as export does; without one every caller fails at once.
    private static func hardwareEncoderAvailable(_ codec: CMVideoCodecType) -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 320, height: 180, codecType: codec,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr && session != nil
    }

    private nonisolated func generate(_ name: String) async throws -> URL {
        let pocket = name == "pocket-main10.mov"
        guard pocket ? Self.hardwareHEVC : Self.hardwareH264 else { throw VoxClipError.encoderUnavailable }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let big = name == "big.mov"
        let bars = name == "bars.mov"
        let counter = name == "counter.mov"
        let chirp = name == "chirp.mov"
        let downmix = name == "right-only.mov" || name == "six-channel.mov"
        let channels = name == "six-channel.mov" ? 6 : 2
        let benchmark = name == "benchmark.mov" || name == "interrupt-aac.mov"
        let audioRate = name == "rate-44100.mov" ? 44100 : name == "rate-32000.mov" ? 32000 : 48000
        let frameRate = name == "rate-44100.mov" ? 24 : 30
        let overhang = name == "audio-overhang.mov" ? 0.5 : name == "audio-overhang-short.mov" ? 0.02 : name == "rounded-tail.mov" ? 590.0 / 48000 : 0
        let duration = pocket ? 1 : name == "joins-tone.mov" ? 12 : chirp ? 30 : benchmark ? 60 : 2
        let fullHD = bars || counter || benchmark
        let size = big ? CGSize(width: 2400, height: 1350) : fullHD ? CGSize(width: 1920, height: 1080) : CGSize(width: 320, height: 180)
        let videoURL = root.appendingPathComponent("video-\(name)")
        var intermediates = [videoURL]
        defer { for url in intermediates { try? FileManager.default.removeItem(at: url) } }
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        var compression: [String: Any] = [AVVideoAverageBitRateKey: 2_000_000, AVVideoMaxKeyFrameIntervalKey: 30, AVVideoExpectedSourceFrameRateKey: 30]
        if bars {
            compression[AVVideoAverageBitRateKey] = 32_000_000
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoAllowFrameReorderingKey] = false
        }
        if pocket { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
        var settings: [String: Any] = [AVVideoCodecKey: pocket ? AVVideoCodecType.hevc : .h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoColorPropertiesKey: MediaSupport.colorProperties]
        if pocket {
            settings.removeValue(forKey: AVVideoColorPropertiesKey)
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pocket ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : bars ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        do {
            for frame in 0..<(duration * frameRate) {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard writer.status == .writing, ContinuousClock.now < deadline else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                    try await Task.sleep(for: .milliseconds(1))
                }
                let buffer = try pixelBuffer(size: size, frame: frame, counter: counter, compactCounter: overhang > 0, tenBit: pocket, bars: bars)
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(frameRate))) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: Int64(duration), timescale: 1))
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        } catch { writer.cancelWriting(); throw error }
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let source = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let range = CMTimeRange(start: .zero, duration: CMTime(value: Int64(duration), timescale: 1))
        try video.insertTimeRange(range, of: source, at: .zero)
        if name == "rotated.mov" { video.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0) }
        if !bars {
            for trackIndex in 0..<(pocket ? 2 : 1) {
                let audioURL = root.appendingPathComponent("tone-\(name)-\(trackIndex).wav")
                intermediates.append(audioURL)
                let pcm = try PCMFile(url: audioURL, rate: audioRate, channels: channels, float: true)
                let frequency = trackIndex == 0 ? 441.0 : 882.0
                let audioFrames = Int(((Double(duration) + overhang) * Double(audioRate)).rounded())
                var samples = [Float](repeating: 0, count: audioFrames * channels)
                for frame in 0..<audioFrames {
                    let time = Double(frame) / Double(audioRate)
                    let value = Float(chirp ? 0.3 * sin(2 * .pi * (200 * time + 1800 * time * time / 60)) : 0.4 * sin(2 * .pi * frequency * time))
                    if downmix { samples[frame * channels + 1] = time >= 0.5 ? 0.6 : 0 }
                    else { for channel in 0..<channels { samples[frame * channels + channel] = value } }
                }
                try samples.withUnsafeBytes { try pcm.append(Data($0)) }
                try pcm.finish()
                let encodedURL = pocket || name == "interrupt-aac.mov" ? try await encodeAAC(audioURL) : audioURL
                if encodedURL != audioURL { intermediates.append(encodedURL) }
                let asset = AVURLAsset(url: encodedURL)
                let track = try await asset.loadTracks(withMediaType: .audio)[0]
                let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try audio.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: Int64(audioFrames), timescale: Int32(audioRate))), of: track, at: .zero)
            }
        }
        let destination = root.appendingPathComponent(name)
        if name == "rounded-tail.mov" {
            try await muxRoundedTail(composition, to: destination)
            return destination
        }
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await session.export(to: destination, as: .mov)
        return destination
    }

    private nonisolated func muxRoundedTail(_ composition: AVComposition, to destination: URL) async throws {
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.movieTimeScale = 1000
        var inputs: [(AVAssetTrack, AVAssetWriterInput.SampleBufferReceiver)] = []
        for track in try await composition.load(.tracks) {
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil,
                sourceFormatHint: try await track.load(.formatDescriptions).first)
            inputs.append((track, writer.inputReceiver(for: input)))
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for (track, receiver) in inputs {
            let reader = try AVAssetReader(asset: composition)
            let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: nil))
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
            while let sample = try await MediaSupport.nextSample(provider) { try await receiver.append(sample) }
            guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
            receiver.finish()
        }
        let duration = try await composition.load(.duration)
        writer.endSession(atSourceTime: CMTimeConvertScale(duration, timescale: 1000, method: .roundAwayFromZero))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        try roundMoviePresentationEndsUp(destination)
    }

    private nonisolated func roundMoviePresentationEndsUp(_ destination: URL) throws {
        var data = try Data(contentsOf: destination)
        func integer(at offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func visit(from start: Int, to end: Int) throws {
            var offset = start
            while offset + 8 <= end {
                let size = Int(integer(at: offset))
                guard size >= 8, offset + size <= end else { throw CocoaError(.fileReadCorruptFile) }
                let kind = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
                if ["moov", "trak", "edts"].contains(kind) {
                    try visit(from: offset + 8, to: offset + size)
                } else if let relative = ["mvhd": 24, "tkhd": 28, "elst": 16][kind] {
                    guard data[offset + 8] == 0, relative + 4 <= size else { throw CocoaError(.fileReadCorruptFile) }
                    if integer(at: offset + relative) == 2012 {
                        var rounded = UInt32(2013).bigEndian
                        withUnsafeBytes(of: &rounded) { data.replaceSubrange((offset + relative)..<(offset + relative + 4), with: $0) }
                    }
                }
                offset += size
            }
        }
        try visit(from: 0, to: data.count)
        try data.write(to: destination)
    }

    private nonisolated func encodeAAC(_ source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let reader = try AVAssetReader(asset: asset)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: 48000, channels: 2))
        let provider = reader.outputProvider(for: output)
        let destination = source.deletingPathExtension().appendingPathExtension("m4a")
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160000])
        let receiver = writer.inputReceiver(for: input)
        do {
            guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown) }
            writer.startSession(atSourceTime: .zero)
            while let sample = try await provider.next() {
                try Task.checkCancellation()
                try await receiver.append(sample)
            }
            receiver.finish()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        } catch { reader.cancelReading(); writer.cancelWriting(); throw error }
        return destination
    }

    private nonisolated func pixelBuffer(size: CGSize, frame: Int, counter: Bool, compactCounter: Bool, tenBit: Bool, bars: Bool) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let format = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : bars ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output)
        guard status == kCVReturnSuccess, let output else { throw CocoaError(.coderInvalidValue) }
        if !tenBit {
            CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.itur_709)!, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        if tenBit {
            for plane in 0..<CVPixelBufferGetPlaneCount(output) {
                let values = CVPixelBufferGetBaseAddressOfPlane(output, plane)!.assumingMemoryBound(to: UInt16.self)
                let count = CVPixelBufferGetBytesPerRowOfPlane(output, plane) * CVPixelBufferGetHeightOfPlane(output, plane) / 2
                values.update(repeating: 512 << 6, count: count)
            }
            return output
        }
        if bars {
            let colors: [(Double, Double, Double)] = [(191,191,191), (191,191,0), (0,191,191), (0,191,0), (191,0,191), (191,0,0), (0,0,191), (0,0,0)]
            let luma = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self)
            let chroma = CVPixelBufferGetBaseAddressOfPlane(output, 1)!.assumingMemoryBound(to: UInt8.self)
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
            for (index, color) in colors.enumerated() {
                let luminance = 0.2126 * color.0 + 0.7152 * color.1 + 0.0722 * color.2
                let level = UInt8((16 + luminance * 219 / 255).rounded())
                let blueDifference = UInt8((128 + (color.2 - luminance) / 1.8556 * 224 / 255).rounded())
                let redDifference = UInt8((128 + (color.0 - luminance) / 1.5748 * 224 / 255).rounded())
                let start = index * Int(size.width) / 8
                let end = (index + 1) * Int(size.width) / 8
                for row in 0..<Int(size.height) {
                    luma.advanced(by: row * lumaStride + start).update(repeating: level, count: end - start)
                }
                for row in 0..<(Int(size.height) / 2) {
                    for column in stride(from: start, to: end, by: 2) {
                        chroma[row * chromaStride + column] = blueDifference
                        chroma[row * chromaStride + column + 1] = redDifference
                    }
                }
            }
            return output
        }
        let context = CGContext(data: CVPixelBufferGetBaseAddress(output), width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(output), space: CGColorSpace(name: CGColorSpace.itur_709)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1,1,1), (1,1,0), (0,1,1), (0,1,0), (1,0,1), (1,0,0), (0,0,1), (0,0,0)]
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        if counter {
            let bytes = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(output)
            for center in [760, 1160] {
                for row in 200..<Int(size.height) {
                    for column in (center - 2)..<(center + 2) {
                        for channel in 0..<3 { bytes[row * stride + column * 4 + channel] = 255 }
                    }
                }
            }
        } else {
            for (index, color) in colors.enumerated() {
                context.setFillColor(CGColor(red: color.0 * 191 / 255, green: color.1 * 191 / 255, blue: color.2 * 191 / 255, alpha: 1))
                context.fill(CGRect(x: CGFloat(index) * size.width / 8, y: 0, width: size.width / 8, height: size.height))
            }
        }
        for bit in 0..<12 {
            let origin = counter ? 720 : 16
            let bytes = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(output)
            let value: UInt8 = frame & (1 << (11 - bit)) == 0 ? 0 : 255
            let startColumn = origin + (compactCounter ? 24 : 40) * bit
            let endColumn = min(Int(size.width), startColumn + (compactCounter ? 16 : 32))
            guard startColumn < endColumn else { continue }
            for row in 16..<48 {
                for column in startColumn..<endColumn {
                    for channel in 0..<3 { bytes[row * stride + column * 4 + channel] = value }
                }
            }
        }
        return output
    }
}
