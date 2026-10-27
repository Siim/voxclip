import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite struct VoiceLabSourceAudioTests {
    // Sample-unique content per channel, so a shifted cut, a swapped channel or another downmix cannot match.
    private static func left(_ index: Int) -> Float { Float((index * 7_919) % 4_001 - 2_000) / 4_000 }
    private static func right(_ index: Int) -> Float { Float((index * 104_729) % 3_001 - 1_500) / 6_000 }
    private static func mono(_ index: Int) -> Int16 { Int16((index * 7_919) % 65_001 - 32_500) }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-vl-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func format(rate: Int, channels: Int, float: Bool) throws -> AVAudioFormat {
        try #require(AVAudioFormat(commonFormat: float ? .pcmFormatFloat32 : .pcmFormatInt16, sampleRate: Double(rate),
                                   channels: AVAudioChannelCount(channels), interleaved: true))
    }

    /// One interleaved LPCM sample buffer, built from values alone so it can be sent to the writer.
    private static func block(_ bytes: Data, start: Int, frames: Int, rate: Int, channels: Int,
                              float: Bool, presentationTime: CMTime? = nil) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr,
              let block,
              bytes.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                    offsetIntoDestination: 0, dataLength: $0.count) }) == noErr else {
            throw CocoaError(.fileWriteUnknown)
        }
        let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                        presentationTimeStamp: presentationTime ?? CMTime(value: Int64(start), timescale: CMTimeScale(rate)),
                                        decodeTimeStamp: .invalid)
        return CMReadySampleBuffer(unsafeBuffer: try CMSampleBuffer(dataBuffer: block,
            formatDescription: format(rate: rate, channels: channels, float: float).formatDescription,
            numSamples: frames, sampleTimings: [timing], sampleSizes: [bytes.count / frames]))
    }

    /// LPCM-in-MOV written by AVAssetWriter in passthrough, so every decoded sample is exact.
    private func movie(_ url: URL, rate: Int, channels: Int, frames: Int, float: Bool,
                       bufferFrames: Int = 4_800, timescale: CMTimeScale? = nil, gapSamples: Int = 0,
                       value: (_ frame: Int, _ channel: Int) -> Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                       sourceFormatHint: try Self.format(rate: rate, channels: channels, float: float).formatDescription)
        input.expectsMediaDataInRealTime = false
        let receiver = writer.inputReceiver(for: input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let width = float ? 4 : 2
        var start = 0
        while start < frames {
            let count = min(bufferFrames, frames - start)
            var bytes = Data(count: count * channels * width)
            bytes.withUnsafeMutableBytes { raw in
                for frame in 0..<count {
                    for channel in 0..<channels {
                        let offset = (frame * channels + channel) * width, sample = value(start + frame, channel)
                        if float { raw.storeBytes(of: Float(sample).bitPattern.littleEndian, toByteOffset: offset, as: UInt32.self) }
                        else { raw.storeBytes(of: Int16(sample).littleEndian, toByteOffset: offset, as: Int16.self) }
                    }
                }
            }
            let timestampSample: Int = start + (start >= bufferFrames ? gapSamples : 0)
            let timestamp: CMTime = CMTime(value: Int64(timestampSample), timescale: CMTimeScale(rate))
            let presentation: CMTime = timescale.map { (scale: CMTimeScale) -> CMTime in
                CMTimeConvertScale(timestamp, timescale: scale, method: .roundHalfAwayFromZero)
            } ?? timestamp
            try await receiver.append(Self.block(bytes, start: start, frames: count, rate: rate, channels: channels,
                                                  float: float, presentationTime: presentation))
            start += count
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: CMTimeScale(rate)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// 2.5 s of 48 kHz float stereo with different content in each channel.
    private func stereo(in folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent("stereo-48k.mov")
        try await movie(url, rate: 48_000, channels: 2, frames: 120_000, float: true) { frame, channel in
            Double(channel == 0 ? Self.left(frame) : Self.right(frame))
        }
        return url
    }

    /// 2 s of 44.1 kHz PCM16 mono reaching ±32500, where decoding to Float32 and back moves values by at most 1 LSB.
    private func mono(in folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent("mono-44k.mov")
        try await movie(url, rate: 44_100, channels: 1, frames: 88_200, float: false) { frame, _ in Double(Self.mono(frame)) }
        return url
    }

    private func samples(_ wav: Data) -> [Int16] {
        wav.dropFirst(44).withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
    }

    private static func floatBuffer(_ content: [Float], channels: Int = 1,
                                    time: CMTime) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        let bytes: Data = content.withUnsafeBytes { Data($0) }
        let frames: Int = content.count / channels
        return try block(bytes, start: 0, frames: frames, rate: 48_000, channels: channels, float: true,
                         presentationTime: time)
    }

    private func expectedMean(_ index: Int) -> Int16 {
        VoiceLabAssetStore.pcm16(Float((Double(Self.left(index)) + Double(Self.right(index))) / 2))
    }

    @Test(arguments: [48_000, 1_000])
    func continuousWriterBuffersPreserveEverySample(timescale: Int) async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("continuous.mov")
        try await movie(source, rate: 48_000, channels: 2, frames: 24_000, float: true,
                        timescale: CMTimeScale(timescale)) { (frame: Int, channel: Int) -> Double in
            Double(channel == 0 ? Self.left(frame) : Self.right(frame))
        }
        let wav = try await VoiceLabSourceAudio.conversionInput(source: source, startSample: 0, endSample: 24_000,
                                                               sourceSampleRate: 48_000)
        #expect(samples(wav) == (0..<24_000).map(expectedMean))
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let storedScale = try await track.load(.naturalTimeScale)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: 48_000, channels: 2))
        let provider = reader.outputProvider(for: output)
        try #require(reader.startReading())
        defer { reader.cancelReading() }
        var buffers: Int = 0
        while let _ = try await MediaSupport.nextSample(provider) { buffers += 1 }
        #expect(buffers > 1)
        print("VOICE_LAB_WRITER inputTimescale=\(timescale) storedTimescale=\(storedScale) decodedBuffers=\(buffers)")
    }

    @Test(arguments: [48_000, 1_000])
    func writerNormalizesLPCMTimestampGaps(timescale: Int) async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("gap.mov")
        let gap: Int = timescale == 48_000 ? 1 : 96
        try await movie(source, rate: 48_000, channels: 1, frames: 24_000, float: true,
                        timescale: CMTimeScale(timescale), gapSamples: gap) { (frame: Int, _: Int) -> Double in
            Double(Self.left(frame))
        }
        let wav = try await VoiceLabSourceAudio.conversionInput(source: source, startSample: 0, endSample: 24_000,
                                                               sourceSampleRate: 48_000)
        let expected: [Int16] = (0..<24_000).map { (frame: Int) -> Int16 in VoiceLabAssetStore.pcm16(Self.left(frame)) }
        #expect(samples(wav) == expected)
    }

    @Test func timestampPlacementUsesStrictStreamTickAndDecodedEnd() throws {
        let rate: Int = 48_000
        let next: Int64 = 4_800
        let early = CMTime(value: 23_997, timescale: 240_000)
        #expect(try VoiceLabSourceAudio.bufferFirstSample(presentationTime: early, rate: rate, previousEnd: next) == next)
        #expect(try VoiceLabSourceAudio.bufferFirstSample(presentationTime: CMTime(value: next - 1, timescale: 48_000),
                                                        rate: rate, previousEnd: next) == next - 1)
        #expect(try VoiceLabSourceAudio.bufferFirstSample(presentationTime: CMTime(value: 99, timescale: 1_000),
                                                        rate: rate, previousEnd: next) == 4_752)
        var decodedEnd: Int64 = 0
        let buffers: Range<Int64> = 0..<10
        for buffer in buffers {
            let start: Int64 = buffer * 4_807
            let timestamp: CMTime = CMTimeConvertScale(CMTime(value: start, timescale: 48_000),
                                                      timescale: 1_000, method: .roundHalfAwayFromZero)
            let placed = try VoiceLabSourceAudio.bufferFirstSample(presentationTime: timestamp, rate: rate, previousEnd: decodedEnd)
            #expect(placed == start)
            decodedEnd = placed + 4_807
        }
        #expect(decodedEnd == 48_070)
    }

    @Test(arguments: [48_000, 1_000])
    func timestampPlacementKeepsExactOneTickAndTwoTickGaps(timescale: Int) throws {
        let next: Int64 = 4_800
        let tickSamples: Int = 48_000 / timescale
        let tick: Int64 = Int64(tickSamples)
        for ticks in 1...2 {
            let position: Int64 = next + tick * Int64(ticks)
            let timestamp = CMTime(value: position / tick, timescale: CMTimeScale(timescale))
            let bytes = Data(count: 4_800 * 4)
            let buffer = try Self.block(bytes, start: 4_800, frames: 4_800, rate: 48_000, channels: 1,
                                        float: true, presentationTime: timestamp)
            let first = try VoiceLabSourceAudio.bufferFirstSample(presentationTime: buffer.presentationTimeStamp,
                                                                rate: 48_000, previousEnd: next)
            #expect(first == position)
            #expect(first > next)
        }
    }

    @Test func firstFrameUsesItsOwnHalfUpAnchorAndNegativeOverlap() throws {
        let early = CMTime(value: 23_997, timescale: 240_000)
        #expect(try VoiceLabSourceAudio.bufferFirstSample(presentationTime: early, rate: 48_000, previousEnd: nil) == 4_799)
        #expect(try VoiceLabSourceAudio.bufferFirstSample(presentationTime: early, rate: 48_000, previousEnd: 4_800) == 4_800)
        let negative = CMTime(value: -3, timescale: 240_000)
        #expect(try VoiceLabSourceAudio.bufferFirstSample(presentationTime: negative, rate: 48_000, previousEnd: nil) == -1)
        #expect(try VoiceLabSourceAudio.bufferFirstSample(presentationTime: negative, rate: 48_000, previousEnd: 0) == 0)
    }

    @Test func missingTimestampRequiresAnAnchorThenContinuesSequentially() throws {
        #expect(throws: VoiceLabSourceAudioError.unreadable) {
            try VoiceLabSourceAudio.bufferFirstSample(presentationTime: .invalid, rate: 48_000, previousEnd: nil)
        }
        #expect(try VoiceLabSourceAudio.bufferFirstSample(presentationTime: .invalid, rate: 48_000, previousEnd: 1_920) == 1_920)
    }

    @Test func nonfinitePresentationTimeIsNotAMissingTimestamp() throws {
        for time in [CMTime.positiveInfinity, CMTime.negativeInfinity, CMTime.indefinite] {
            #expect(throws: VoiceLabSourceAudioError.unreadable) {
                try VoiceLabSourceAudio.bufferFirstSample(presentationTime: time, rate: 48_000, previousEnd: 1_920)
            }
        }
    }

    @Test(arguments: [0, 4_800]) func bufferPointSixSamplesEarlyLosesNoDecodedSample(start: Int) throws {
        let first: [Float] = (0..<4_800).map { (frame: Int) -> Float in Self.left(frame) }
        let second: [Float] = (4_800..<9_600).map { (frame: Int) -> Float in Self.left(frame) }
        let frames: Int = 9_600 - start
        var accumulator = VoiceLabSourceAudio.ConversionAccumulator(rate: 48_000, channels: 1, startSample: Int64(start),
                                                                   endSample: 9_600, frames: frames)
        try accumulator.append(Self.floatBuffer(first, time: .zero))
        try accumulator.append(Self.floatBuffer(second, time: CMTime(value: 23_997, timescale: 240_000)))
        let expected: [Int16] = (start..<9_600).map { (frame: Int) -> Int16 in VoiceLabAssetStore.pcm16(Self.left(frame)) }
        #expect(accumulator.isComplete)
        #expect(accumulator.next == 9_600)
        #expect(samples(accumulator.wav) == expected)
        #expect(accumulator.wav.prefix(44) == VoiceLabAssetStore.wavHeader(frames: frames, sampleRate: 48_000))
    }

    @Test(arguments: [0, 4_800]) func accumulatorFirstFrameUsesItsOwnAnchorAndSkipsOverlap(start: Int) throws {
        let content: [Float] = (0..<1_024).map { (frame: Int) -> Float in Self.left(frame) }
        let begin: Int64 = Int64(start)
        let end: Int64 = begin + 960
        let timestampValue: Int64 = begin * 5 - 3
        var accumulator = VoiceLabSourceAudio.ConversionAccumulator(rate: 48_000, channels: 1, startSample: begin,
                                                                   endSample: end, frames: 960)
        try accumulator.append(Self.floatBuffer(content, time: CMTime(value: timestampValue, timescale: 240_000)))
        let expected: [Int16] = (1...960).map { (frame: Int) -> Int16 in VoiceLabAssetStore.pcm16(content[frame]) }
        #expect(accumulator.isComplete)
        #expect(samples(accumulator.wav) == expected)
    }

    @Test func accumulatorMissingTimeNeedsAnAnchorThenWritesSequentialPCM() throws {
        let first: [Float] = (0..<960).map { (frame: Int) -> Float in Self.left(frame) }
        let second: [Float] = (960..<1_920).map { (frame: Int) -> Float in Self.left(frame) }
        var accumulator = VoiceLabSourceAudio.ConversionAccumulator(rate: 48_000, channels: 1, startSample: 0,
                                                                   endSample: 1_920, frames: 1_920)
        let missing = try Self.floatBuffer(first, time: .invalid)
        #expect(throws: VoiceLabSourceAudioError.unreadable) { try accumulator.append(missing) }
        #expect(accumulator.next == 0)
        try accumulator.append(Self.floatBuffer(first, time: .zero))
        try accumulator.append(Self.floatBuffer(second, time: .invalid))
        let expected: [Int16] = (first + second).map { (sample: Float) -> Int16 in VoiceLabAssetStore.pcm16(sample) }
        #expect(accumulator.isComplete)
        #expect(samples(accumulator.wav) == expected)
    }

    @Test func accumulatorSkippedPrerollStillAnchorsMissingTime() throws {
        let preroll: [Float] = (0..<4_800).map { (frame: Int) -> Float in Self.left(frame) }
        let content: [Float] = (4_800..<5_760).map { (frame: Int) -> Float in Self.left(frame) }
        var accumulator = VoiceLabSourceAudio.ConversionAccumulator(rate: 48_000, channels: 1, startSample: 4_800,
                                                                   endSample: 5_760, frames: 960)
        try accumulator.append(Self.floatBuffer(preroll, time: .zero))
        #expect(accumulator.next == 4_800)
        try accumulator.append(Self.floatBuffer(content, time: .invalid))
        let expected: [Int16] = content.map { (sample: Float) -> Int16 in VoiceLabAssetStore.pcm16(sample) }
        #expect(accumulator.isComplete)
        #expect(samples(accumulator.wav) == expected)
    }

    @Test(arguments: [48_000, 1_000]) func accumulatorRefusesExactOneTickAndTwoTickGaps(timescale: Int) throws {
        let content: [Float] = (0..<4_800).map { (frame: Int) -> Float in Self.left(frame) }
        let tick: Int = 48_000 / timescale
        for ticks in 1...2 {
            var accumulator = VoiceLabSourceAudio.ConversionAccumulator(rate: 48_000, channels: 1, startSample: 0,
                                                                       endSample: 9_600, frames: 9_600)
            try accumulator.append(Self.floatBuffer(content, time: .zero))
            let first: Int = 4_800 / tick + ticks
            let timestamp: CMTime = CMTime(value: Int64(first), timescale: CMTimeScale(timescale))
            let gap = try Self.floatBuffer(content, time: timestamp)
            #expect(throws: VoiceLabSourceAudioError.rangeOutsideMedia) { try accumulator.append(gap) }
            #expect(accumulator.next == 4_800)
        }
    }

    @Test(arguments: [48_000, 1_000]) func accumulatorSkipsExactTickOverlapInPCM(timescale: Int) throws {
        let tick: Int = 48_000 / timescale
        let count: Int = 4_800 + tick
        let first: [Float] = (0..<4_800).map { (frame: Int) -> Float in Self.left(frame) }
        let second: [Float] = (0..<count).map { (frame: Int) -> Float in Self.right(frame) }
        var accumulator = VoiceLabSourceAudio.ConversionAccumulator(rate: 48_000, channels: 1, startSample: 0,
                                                                   endSample: 9_600, frames: 9_600)
        try accumulator.append(Self.floatBuffer(first, time: .zero))
        let position: Int = 4_800 / tick - 1
        let timestamp: CMTime = CMTime(value: Int64(position), timescale: CMTimeScale(timescale))
        try accumulator.append(Self.floatBuffer(second, time: timestamp))
        let expectedFloats: [Float] = first + second.dropFirst(tick)
        let expected: [Int16] = expectedFloats.map { (sample: Float) -> Int16 in VoiceLabAssetStore.pcm16(sample) }
        #expect(accumulator.isComplete)
        #expect(samples(accumulator.wav) == expected)
    }

    @Test func accumulatorRepeatedFortySampleGapsCannotAccumulate() throws {
        let first: [Float] = (0..<920).map { (frame: Int) -> Float in Self.left(frame) }
        let second: [Float] = (920..<1_840).map { (frame: Int) -> Float in Self.left(frame) }
        var accumulator = VoiceLabSourceAudio.ConversionAccumulator(rate: 48_000, channels: 1, startSample: 0,
                                                                   endSample: 2_760, frames: 2_760)
        try accumulator.append(Self.floatBuffer(first, time: .zero))
        try accumulator.append(Self.floatBuffer(second, time: CMTime(value: 20, timescale: 1_000)))
        #expect(accumulator.next == 1_840)
        let gap = try Self.floatBuffer(second, time: CMTime(value: 40, timescale: 1_000))
        #expect(throws: VoiceLabSourceAudioError.rangeOutsideMedia) { try accumulator.append(gap) }
        let expected: [Int16] = (first + second).map { (sample: Float) -> Int16 in VoiceLabAssetStore.pcm16(sample) }
        #expect(Array(samples(accumulator.wav).prefix(1_840)) == expected)
    }

    @Test func accumulatorReadsStereoPCMAndWritesEqualWeightMono() throws {
        var content: [Float] = []
        for frame in 0..<960 { content.append(Self.left(frame)); content.append(Self.right(frame)) }
        var accumulator = VoiceLabSourceAudio.ConversionAccumulator(rate: 48_000, channels: 2, startSample: 0,
                                                                   endSample: 960, frames: 960)
        try accumulator.append(Self.floatBuffer(content, channels: 2, time: .zero))
        let expected: [Int16] = (0..<960).map { (frame: Int) -> Int16 in expectedMean(frame) }
        #expect(accumulator.isComplete)
        #expect(samples(accumulator.wav) == expected)
    }

    @Test func stereoChunkIsTheChannelMeanOnTheSourceGridWithHalfOpenBounds() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await stereo(in: folder)
        let wav = try await VoiceLabSourceAudio.conversionInput(source: source, startSample: 12_345, endSample: 60_007,
                                                                 sourceSampleRate: 48_000)
        let expectedBytes: Int = 44 + 2 * 47_662
        #expect(wav.count == expectedBytes)
        #expect(wav.prefix(44) == VoiceLabAssetStore.wavHeader(frames: 47_662, sampleRate: 48_000))
        let values = samples(wav)
        let expected = (12_345..<60_007).map(expectedMean)
        #expect(values.count == expected.count)
        #expect(zip(values, expected).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        #expect(values == expected, "float LPCM decodes exactly, so the mean is exact")
        #expect(values.first == expectedMean(12_345) && values.last == expectedMean(60_006))
        // Neither channel alone, nor a sum, matches.
        #expect(zip(values, (12_345..<60_007).map { VoiceLabAssetStore.pcm16(Self.left($0)) }).filter { $0 != $1 }.count > 40_000)
        #expect(zip(values, (12_345..<60_007).map { VoiceLabAssetStore.pcm16(Self.right($0)) }).filter { $0 != $1 }.count > 40_000)

        // [a, b) followed by [b, c) is exactly [a, c).
        let head = try await VoiceLabSourceAudio.conversionInput(source: source, startSample: 12_345, endSample: 30_000,
                                                                  sourceSampleRate: 48_000)
        let tail = try await VoiceLabSourceAudio.conversionInput(source: source, startSample: 30_000, endSample: 60_007,
                                                                  sourceSampleRate: 48_000)
        #expect(samples(head) + samples(tail) == values)
        let last = try await VoiceLabSourceAudio.conversionInput(source: source, startSample: 119_000, endSample: 120_000,
                                                                  sourceSampleRate: 48_000)
        #expect(samples(last) == (119_000..<120_000).map(expectedMean))
    }

    @Test func monoPCM16SourceStaysWithinOneLSB() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await mono(in: folder)
        let wav = try await VoiceLabSourceAudio.conversionInput(source: source, startSample: 0, endSample: 88_200,
                                                                 sourceSampleRate: 44_100)
        #expect(wav.prefix(44) == VoiceLabAssetStore.wavHeader(frames: 88_200, sampleRate: 44_100))
        let values = samples(wav)
        #expect(values.count == 88_200)
        let stored: [Int16] = (0..<88_200).map(Self.mono)
        let pairs: [(value: Int16, stored: Int16)] = Array(zip(values, stored))
        #expect(pairs.allSatisfy { (pair: (value: Int16, stored: Int16)) -> Bool in abs(Int(pair.value) - Int(pair.stored)) <= 1 })
        // Decoded as v / 32768 and written as round(v × 32767 / 32768): exact up to 2^14 in magnitude, then 1 LSB closer to 0.
        func written(_ stored: Int16) -> Int {
            let value = Int(stored)
            return abs(value) > 16_384 ? value - value.signum() : value
        }
        #expect(pairs.allSatisfy { (pair: (value: Int16, stored: Int16)) -> Bool in Int(pair.value) == written(pair.stored) })
        let changed = pairs.contains { (pair: (value: Int16, stored: Int16)) -> Bool in pair.value != pair.stored }
        let unchanged = pairs.contains { (pair: (value: Int16, stored: Int16)) -> Bool in pair.value == pair.stored }
        #expect(changed && unchanged)
        let late = try await VoiceLabSourceAudio.conversionInput(source: source, startSample: 44_101, endSample: 44_983,
                                                                  sourceSampleRate: 44_100)
        #expect(samples(late) == Array(values[44_101..<44_983]))
    }

    @Test func chunkLimitsFollowSection7_2BeforeTheSourceIsOpened() async throws {
        func chunk(_ start: Int64, _ end: Int64, _ rate: Double) throws -> Int {
            try VoiceLabSourceAudio.conversionChunk(startSample: start, endSample: end, sourceSampleRate: rate).frames
        }
        for rate in [7_999, 96_001, 44_100.5, .nan, .infinity, -48_000] as [Double] {
            #expect(throws: VoiceLabSourceAudioError.unsupportedRate) { try chunk(0, 48_000, rate) }
        }
        #expect(throws: VoiceLabSourceAudioError.rangeOutsideMedia) { try chunk(-1, 48_000, 48_000) }
        #expect(throws: VoiceLabSourceAudioError.rangeOutsideMedia) { try chunk(500, 500, 48_000) }
        #expect(throws: VoiceLabSourceAudioError.rangeOutsideMedia) { try chunk(500, 499, 48_000) }
        // Core's 20 ms minimum is ceil(rate / 50) frames, including nonround rates.
        for (rate, minimum) in [(8_000, 160), (11_025, 221), (44_100, 882), (48_000, 960), (96_000, 1_920)] {
            #expect(throws: VoiceLabSourceAudioError.tooShort) { try chunk(10, 10 + Int64(minimum) - 1, Double(rate)) }
            #expect(try chunk(10, 10 + Int64(minimum), Double(rate)) == minimum)
        }
        // maxFrames = min(290 × rate, floor((50,000,000 − 1 − 44) / 2) = 24,999,977).
        for (rate, maxFrames) in [(8_000, 2_320_000), (48_000, 13_920_000), (86_200, 24_998_000), (86_206, 24_999_740),
                                  (86_207, 24_999_977), (88_200, 24_999_977), (96_000, 24_999_977)] {
            #expect(try chunk(7, 7 + Int64(maxFrames), Double(rate)) == maxFrames)
            #expect(44 + 2 * maxFrames < 50_000_000)
            let over: VoiceLabSourceAudioError = maxFrames == 290 * rate ? .tooLong : .tooLarge
            #expect(throws: over) { try chunk(7, 8 + Int64(maxFrames), Double(rate)) }
        }
        // 24,999,977 frames make a 49,999,998-byte WAV; one more frame reaches 50,000,000 bytes.
        #expect(44 + 2 * 24_999_977 == 49_999_998 && 44 + 2 * 24_999_978 == 50_000_000)
        #expect(throws: VoiceLabSourceAudioError.tooLarge) { try chunk(0, 27_840_000, 96_000) }
        #expect(throws: VoiceLabSourceAudioError.tooLong) { try chunk(0, 27_840_001, 96_000) }

        // The public entry point refuses those limits without opening the (missing) source; within them it opens it.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-vl-missing-\(UUID().uuidString).mov")
        await #expect(throws: VoiceLabSourceAudioError.tooLarge) {
            try await VoiceLabSourceAudio.conversionInput(source: missing, startSample: 0, endSample: 24_999_978, sourceSampleRate: 96_000)
        }
        await #expect(throws: VoiceLabSourceAudioError.tooLong) {
            try await VoiceLabSourceAudio.conversionInput(source: missing, startSample: 0, endSample: 13_920_001, sourceSampleRate: 48_000)
        }
        await #expect(throws: VoiceLabSourceAudioError.unreadable) {
            try await VoiceLabSourceAudio.conversionInput(source: missing, startSample: 0, endSample: 24_999_977, sourceSampleRate: 96_000)
        }
    }

    @Test func sourceRateRangeAndTrackAreChecked() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await stereo(in: folder)
        await #expect(throws: VoiceLabSourceAudioError.rateMismatch) {
            try await VoiceLabSourceAudio.conversionInput(source: source, startSample: 0, endSample: 4_800, sourceSampleRate: 44_100)
        }
        for (start, end) in [(119_000, 120_001), (120_000, 121_000), (200_000, 201_000)] as [(Int64, Int64)] {
            await #expect(throws: VoiceLabSourceAudioError.rangeOutsideMedia) {
                try await VoiceLabSourceAudio.conversionInput(source: source, startSample: start, endSample: end, sourceSampleRate: 48_000)
            }
        }
        let video = folder.appendingPathComponent("video-only.mov")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        #expect(adaptor.append(frame, withPresentationTime: .zero))
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
        await writer.finishWriting()
        #expect(writer.status == .completed)
        await #expect(throws: VoiceLabSourceAudioError.noAudioTrack) {
            try await VoiceLabSourceAudio.conversionInput(source: video, startSample: 0, endSample: 960, sourceSampleRate: 48_000)
        }
    }

    @Test func extractedChunksSatisfyCoreConversionInputContract() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let chunks = [
            try await VoiceLabSourceAudio.conversionInput(source: stereo(in: folder), startSample: 4_800, endSample: 100_800,
                                                          sourceSampleRate: 48_000),
            try await VoiceLabSourceAudio.conversionInput(source: mono(in: folder), startSample: 441, endSample: 88_200,
                                                          sourceSampleRate: 44_100),
        ]
        func u16(_ data: Data, _ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ data: Data, _ at: Int) -> Int { u16(data, at) | u16(data, at + 2) << 16 }
        for (wav, rate) in zip(chunks, [48_000, 44_100]) {
            #expect(wav.count < 16 * 1_024 * 1_024)
            #expect(wav.prefix(4) == Data("RIFF".utf8) && u32(wav, 4) == wav.count - 8)
            #expect(wav[8..<16] == Data("WAVEfmt ".utf8) && u32(wav, 16) == 16)
            #expect(u16(wav, 20) == 1 && u16(wav, 22) == 1 && u32(wav, 24) == rate && u32(wav, 28) == rate * 2)
            #expect(u16(wav, 32) == 2 && u16(wav, 34) == 16)
            #expect(wav[36..<40] == Data("data".utf8) && u32(wav, 40) == wav.count - 44)
        }
        // Core's own validator, after offline discovery; no request leaves the process.
        let lab = ElevenLabsVoiceLab(keys: OfflineKeys(), session: URLSession(configuration: OfflineDiscovery.configuration()),
                                     region: .default, logger: OfflineLog())
        #expect(try await lab.models().map(\.id) == ["offline_sts_model"])
        #expect(try await lab.voices().map(\.id) == ["offline-stock"])
        for wav in chunks {
            let quote = try await lab.prepareConversion(audio: wav, modelID: "offline_sts_model", voice: .stock(voiceID: "offline-stock"),
                                                        language: "en", seed: 7, cleanAudioOn: false, requestID: UUID())
            #expect(quote.operation == .voiceChange && quote.endpoint == "v1/voice-changer/offline-stock")
            #expect(quote.languageMode == .autoDetected(expected: "en"))
        }
        var damaged = chunks[0]
        damaged[22] = 2
        await #expect(throws: VoiceLabError.unsupportedFormat) {
            try await lab.prepareConversion(audio: damaged, modelID: "offline_sts_model", voice: .stock(voiceID: "offline-stock"),
                                            language: "en", seed: 7, cleanAudioOn: false, requestID: UUID())
        }
    }

    /// A paid asset written by the store into a temporary data directory, as a provider result would be.
    private func asset(_ samples: [Float], rate: Int, in folder: URL, id: String) throws -> URL {
        let paid = DataLocations(environment: ["VOXCLIP_DATA_DIR": folder.path]).root.appendingPathComponent("VoiceLab", isDirectory: true)
        try FileManager.default.createDirectory(at: paid, withIntermediateDirectories: true)
        let written = try VoiceLabAssetStore.writeDerived(samples: samples, sampleRate: rate, projectId: "5b7e0f7a-3c1d-4b8e-9a51-2f6d0c8e4a11",
                                                          assetId: id, paidRoot: paid, createdAt: Date(timeIntervalSince1970: 1_793_000_000))
        return paid.appendingPathComponent(written.file)
    }

    @Test func decodedAssetIsResampledToTheSourceRateAlignedAtSampleZero() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tone = (0..<24_000).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 24_000)) }
        let url = try asset(tone, rate: 24_000, in: folder, id: "tone")
        #expect(try VoiceLabSourceAudio.decodeAsset(url: url, targetSampleRate: 24_000)
                == tone.map { Float(VoiceLabAssetStore.pcm16($0)) / 32_768 })
        for target in [48_000, 44_100] {
            let decoded = try VoiceLabSourceAudio.decodeAsset(url: url, targetSampleRate: Double(target))
            #expect(abs(decoded.count - target) <= 1, "24,000 frames at \(target) Hz gave \(decoded.count)")
            // Away from the edges it is the same tone on the target grid. A one-sample delay would err by about 0.03.
            let margin = target / 20, amplitude = 0.5 * 32_767 / 32_768, step = 2 * Double.pi * 440 / Double(target)
            var error = 0.0
            for index in margin..<(decoded.count - margin) {
                let ideal: Double = amplitude * sin(step * Double(index))
                error = max(error, abs(Double(decoded[index]) - ideal))
            }
            #expect(error < 1e-3, "max error \(error) at \(target) Hz")
        }
    }

    @Test func decodedAssetDownmixesByTheChannelMeanAndRefusesUnsafeFiles() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stereo = folder.appendingPathComponent("stereo.wav")
        do {
            let file = try AVAudioFile(forWriting: stereo, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2_400))
            buffer.frameLength = 2_400
            let planes = try #require(buffer.floatChannelData)
            for index in 0..<2_400 { planes[0][index] = Self.left(index); planes[1][index] = Self.right(index) }
            try file.write(from: buffer)
        }
        #expect(try VoiceLabSourceAudio.decodeAsset(url: stereo, targetSampleRate: 24_000)
                == (0..<2_400).map { Float((Double(Self.left($0)) + Double(Self.right($0))) / 2) })
        let flac = folder.appendingPathComponent("mono.flac")
        do {
            let file = try AVAudioFile(forWriting: flac, settings: [
                AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24_000))
            buffer.frameLength = 24_000
            for index in 0..<24_000 { buffer.floatChannelData![0][index] = Self.left(index) }
            try file.write(from: buffer)
            file.close()
        }
        #expect(try VoiceLabSourceAudio.decodeAsset(url: flac, targetSampleRate: 24_000).count == 24_000)

        for rate in [7_999, 192_001, 44_100.5, .nan] as [Double] {
            #expect(throws: VoiceLabSourceAudioError.unsupportedRate) { try VoiceLabSourceAudio.decodeAsset(url: stereo, targetSampleRate: rate) }
        }
        #expect(throws: VoiceLabSourceAudioError.unsupportedFormat) {
            try VoiceLabSourceAudio.decodeAsset(url: folder.appendingPathComponent("take.mp3"), targetSampleRate: 24_000)
        }
        #expect(throws: VoiceLabSourceAudioError.unreadable) {
            try VoiceLabSourceAudio.decodeAsset(url: folder.appendingPathComponent("missing.wav"), targetSampleRate: 24_000)
        }
        let link = folder.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: stereo)
        let pipe = folder.appendingPathComponent("pipe.wav")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let empty = folder.appendingPathComponent("empty.wav")
        try Data().write(to: empty)
        for unsafe in [link, pipe, empty] {
            #expect(throws: VoiceLabSourceAudioError.unreadable) { try VoiceLabSourceAudio.decodeAsset(url: unsafe, targetSampleRate: 24_000) }
        }
        let garbage = folder.appendingPathComponent("garbage.wav")
        try Data("RIFFbad".utf8).write(to: garbage)
        #expect(throws: VoiceLabSourceAudioError.unsupportedFormat) {
            try VoiceLabSourceAudio.decodeAsset(url: garbage, targetSampleRate: 24_000)
        }
    }

    @Test func decodedAssetIsTheCheckedFileEvenIfThePathIsSwapped() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let checked = try asset((0..<4_800).map(Self.left), rate: 24_000, in: folder, id: "checked")
        let decoy = try asset((0..<4_800).map(Self.right), rate: 24_000, in: folder, id: "decoy")
        let bytes = try Data(contentsOf: checked)
        let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let expected = (0..<4_800).map { Float(VoiceLabAssetStore.pcm16(Self.left($0))) / 32_768 }
        #expect(try VoiceLabSourceAudio.decodeAsset(url: checked, targetSampleRate: 24_000, expectedSha256: sha256) == expected)

        /// Decodes a fresh copy of the checked asset at `take`, running `swap` on that path once its descriptor is checked.
        /// The snapshot is then an empty 0600 file in a 0700 folder, and the folder is gone once decoding returns or throws.
        let take = folder.appendingPathComponent("take.wav")
        func decode(expecting hash: String? = nil, swap: @escaping (_ path: String) -> Void) throws -> [Float] {
            _ = unlink(take.path)
            try bytes.write(to: take)
            var scratch: URL?
            defer {
                #expect(scratch != nil)
                if let scratch { #expect(access(scratch.path, F_OK) != 0, "the snapshot outlived decoding") }
            }
            return try VoiceLabSourceAudio.decodeAsset(url: take, targetSampleRate: 24_000, expectedSha256: hash ?? sha256) { snapshot in
                let parent = snapshot.deletingLastPathComponent()
                scratch = parent
                var fileInfo = stat(), parentInfo = stat()
                let found = lstat(snapshot.path, &fileInfo) == 0 && lstat(parent.path, &parentInfo) == 0
                let fileMode = fileInfo.st_mode, parentMode = parentInfo.st_mode, size = fileInfo.st_size
                #expect(found && fileMode == mode_t(S_IFREG) | 0o600 && size == 0)
                #expect(found && parentMode == mode_t(S_IFDIR) | 0o700)
                swap(take.path)
            }
        }
        // Reopening the path would decode the decoy through the link, and would hang on the FIFO, so stop here if it did.
        let throughLink = try decode { path in
            let swapped = unlink(path) == 0 && symlink(decoy.path, path) == 0
            #expect(swapped)
        }
        try #require(throughLink == expected)
        let throughFIFO = try decode { path in
            let swapped = unlink(path) == 0 && mkfifo(path, 0o600) == 0
            #expect(swapped)
        }
        #expect(throughFIFO == expected)

        // Bytes added or removed after the check, a wrong hash, and another asset's bytes are all refused.
        #expect(throws: VoiceLabSourceAudioError.altered) {
            try decode { path in
                let fd = open(path, O_WRONLY | O_APPEND)
                let grew = fd >= 0 && write(fd, [UInt8(0), 0], 2) == 2
                #expect(grew)
                close(fd)
            }
        }
        #expect(throws: VoiceLabSourceAudioError.altered) {
            try decode { path in
                let shrank = truncate(path, 100) == 0
                #expect(shrank)
            }
        }
        #expect(throws: VoiceLabSourceAudioError.altered) { try decode(expecting: String(repeating: "0", count: 64)) { _ in } }
        #expect(throws: VoiceLabSourceAudioError.altered) {
            try VoiceLabSourceAudio.decodeAsset(url: decoy, targetSampleRate: 24_000, expectedSha256: sha256)
        }
        #expect(try VoiceLabSourceAudio.decodeAsset(url: decoy, targetSampleRate: 24_000)
                == (0..<4_800).map { Float(VoiceLabAssetStore.pcm16(Self.right($0))) / 32_768 })
    }

    @Test func envelopeFollowsTheCore10msConventionAndFeedsConform() throws {
        // An independent statement of the rule: frames of round_half_up(rate / 100) samples from sample 0, Float64 sums of
        // squares in order, Float32 RMS, and no partial final frame.
        func reference(_ samples: [Float], _ rate: Int) -> [Float] {
            let frame = (rate + 50) / 100
            return stride(from: 0, through: samples.count - frame, by: frame).map { (start: Int) -> Float in
                let sum = samples[start..<(start + frame)].reduce(0.0) { (sum: Double, value: Float) -> Double in
                    sum + Double(value) * Double(value)
                }
                return Float((sum / Double(frame)).squareRoot())
            }
        }
        for (rate, count) in [(22_050, 22_150), (24_000, 7_211), (44_100, 44_100), (48_000, 48_479)] {
            let samples: [Float] = (0..<count).map { (index: Int) -> Float in
                let gain = 0.1 + 0.4 * Double((index / 300) % 3)
                return Float(sin(Double(index) * 0.37) * gain)
            }
            let envelope = VoiceLabSourceAudio.envelope(samples: samples, sampleRate: rate)
            #expect(envelope.sampleRate == Double(rate) && envelope.frameSeconds == 0.01)
            #expect(envelope.levels == reference(samples, rate))
            #expect(envelope.levels.count == count / ((rate + 50) / 100))
            #expect(try VoiceLabConform.decide(inputEnvelope: envelope, outputEnvelope: envelope, inputSamples: count, outputSamples: count,
                                               sampleRate: rate, searchSeconds: VoiceLabConform.voiceChangerSearchSeconds)
                    == .trimOrPad(delta: 0))
        }

        // A 24 kHz provider take 0.1 s late, decoded to the 48 kHz source grid, conforms with a 4,800-sample shift.
        func speech(_ time: Double) -> Double {
            let bursts: [(start: Double, end: Double)] = [(0.10, 0.35), (0.50, 0.62), (0.80, 1.05)]
            var gate = 0.0
            for burst in bursts where time >= burst.start && time <= burst.end {
                gate = min(1, (time - burst.start) / 0.01, (burst.end - time) / 0.01)
            }
            let low: Double = 0.3 * sin(2 * Double.pi * 220 * time)
            let high: Double = 0.2 * sin(2 * Double.pi * 1_330 * time + 1)
            return gate * (low + high)
        }
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = (0..<57_600).map { Float(speech(Double($0) / 48_000)) }
        let late = try asset((0..<31_200).map { Float(speech(Double($0) / 24_000 - 0.1)) }, rate: 24_000, in: folder, id: "late")
        let output = try VoiceLabSourceAudio.decodeAsset(url: late, targetSampleRate: 48_000)
        let decision = try VoiceLabConform.decide(inputEnvelope: VoiceLabSourceAudio.envelope(samples: input, sampleRate: 48_000),
                                                  outputEnvelope: VoiceLabSourceAudio.envelope(samples: output, sampleRate: 48_000),
                                                  inputSamples: input.count, outputSamples: output.count, sampleRate: 48_000,
                                                  searchSeconds: VoiceLabConform.voiceChangerSearchSeconds)
        guard case .shift(let lag, let peak) = decision else {
            Issue.record("expected a shift, got \(decision)")
            return
        }
        #expect(lag == 4_800 && peak > 0.95, "lag \(lag), peak \(peak)")
    }
}

private struct OfflineKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { "offline-synthetic-key" }
}

private actor OfflineLog: Redacting {
    func register(secret: String) {}
    func redact(_ message: String) -> String { message }
    func write(_ entry: LogEntry) {}
}

/// Answers Core's two discovery GETs in process and fails every other request, so nothing reaches a network.
private final class OfflineDiscovery: URLProtocol {
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineDiscovery.self]
        return configuration
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String? = switch (request.httpMethod, request.url?.path) {
        case ("GET"?, "/v1/models"?):
            #"[{"model_id":"offline_sts_model","can_do_text_to_speech":false,"can_do_voice_conversion":true,"languages":[{"language_id":"en"}]}]"#
        case ("GET"?, "/v2/voices"?):
            #"{"voices":[{"voice_id":"offline-stock","name":"Offline","category":"premade","is_owner":false}],"has_more":false}"#
        default: nil
        }
        guard let body, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
