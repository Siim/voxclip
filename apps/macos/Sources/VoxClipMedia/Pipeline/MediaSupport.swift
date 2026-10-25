import AVFoundation
import ImageIO
import VoxClipCore

enum MediaSupport {
    static func nextSample(_ provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>) async throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent>? {
        try await withTaskExecutorPreference(DispatchQueue.global(qos: .userInitiated)) {
            try await provider.next()
        }
    }

    static func audioTrack(in asset: AVAsset, index: Int? = nil) async throws -> AVAssetTrack? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        if let index {
            guard tracks.indices.contains(index) else { throw VoxClipError.noAudioTrack }
            return tracks[index]
        }
        for track in tracks where try await track.load(.isEnabled) { return track }
        return tracks.first
    }

    static func orientation(_ transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let mirrored = transform.a * transform.d - transform.b * transform.c < 0
        let angle = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
        switch angle {
        case 90: return mirrored ? .leftMirrored : .right
        case -90: return mirrored ? .rightMirrored : .left
        case 180, -180: return mirrored ? .upMirrored : .down
        default: return mirrored ? .downMirrored : .up
        }
    }

    static func pcm(rate: Double, channels: Int, float: Bool = true) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
         AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: float ? 32 : 16,
         AVLinearPCMIsFloatKey: float, AVLinearPCMIsNonInterleaved: false,
         AVLinearPCMIsBigEndianKey: false]
    }

    static func silentExportAudio(start: Int64, count: Int) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        let bytesPerFrame = 2 * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: count * bytesPerFrame, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count * bytesPerFrame, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * bytesPerFrame) == noErr,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true) else {
            throw VoxClipError.exportFailed("Cannot allocate export audio padding")
        }
        let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(value: start, timescale: 48000), decodeTimeStamp: .invalid)
        return CMReadySampleBuffer(unsafeBuffer: try CMSampleBuffer(dataBuffer: block, formatDescription: format.formatDescription,
            numSamples: count, sampleTimings: [timing], sampleSizes: [bytesPerFrame]))
    }

    static var colorProperties: [String: Any] {
        [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
         AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    }

    static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255),
                       UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii) ?? "unknown"
    }
}

extension OutputSpec {
    package static func resolved(source: MediaProbeResult, aspect: AspectRatio = .source,
                         quality: ExportQuality = .standard, fps: Double? = nil) throws -> OutputSpec {
        guard let sourceSize = source.orientedSize, sourceSize.width > 0, sourceSize.height > 0 else {
            throw VoxClipError.decodeFailed("No video track")
        }
        let size = try OutputSizing.outputSize(source: sourceSize, aspect: aspect)
        let nominal = fps ?? source.video?.frameRate ?? 30
        let rate = try OutputSizing.outputFrameRate(nominal: nominal)
        return OutputSpec(size: size, fps: rate,
                          videoBitrate: OutputSizing.videoBitrate(size: size, aspect: aspect, quality: quality, fps: rate), quality: quality)
    }
}
