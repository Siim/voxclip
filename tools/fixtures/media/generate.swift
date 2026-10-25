import AVFoundation
import AudioToolbox
import CoreGraphics
import CryptoKit
import Foundation
import VideoToolbox

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureError(message) }
}

let sampleRate = 48_000
let frameRate = 30
let maximumBytes = 2_000_000
func makeColorProperties() -> [String: Any] {
    [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
     AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
     AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
}
let barColors: [[Int]] = [
    [191, 191, 191], [191, 191, 0], [0, 191, 191], [0, 191, 0],
    [191, 0, 191], [191, 0, 0], [0, 0, 191], [0, 0, 0]
]

struct Fixture {
    let file: String
    let width: Int
    let height: Int
    let seconds: Int
    let picture: String
    let audio: String?
    var codec: AVVideoCodecType = .h264
    var bitrate = 100_000
    var transcripts: [String] = []
    var main10 = false
    var audioChannels = 1
    var audioBitrate = 128_000
    var audioTones: [Double] = []
    var nativeChirp = false
}

let fixtures: [Fixture] = [
    Fixture(file: "joins-tone.mov", width: 640, height: 360, seconds: 12, picture: "gray", audio: "pcm",
            transcripts: ["joins-tone.transcript.json"]),
    Fixture(file: "fillers-chirp.mp4", width: 1280, height: 720, seconds: 30, picture: "gray", audio: "chirp",
            transcripts: ["fillers-chirp.transcript.json", "fillers-only.transcript.json"]),
    Fixture(file: "counter-1080p.mp4", width: 1920, height: 1080, seconds: 4, picture: "counter", audio: "chirp"),
    Fixture(file: "big-2400x1350.mp4", width: 2400, height: 1350, seconds: 2, picture: "black", audio: "chirp"),
    Fixture(file: "bars-1080p.mp4", width: 1920, height: 1080, seconds: 2, picture: "bars", audio: nil,
            bitrate: 1_000_000)
]

let pocketFixture = Fixture(file: "pocket4-like-2tracks.mov", width: 1280, height: 720, seconds: 6,
    picture: "pocket", audio: "tone", codec: .hevc, bitrate: 1_000_000, main10: true,
    audioChannels: 2, audioBitrate: 96_000, audioTones: [1000, 300])
// Test-only input for the Windows native suite. Zero selects the same chirp as bars-two-audio.mkv.
let windowsHevcFixture = Fixture(file: "hevc10-two-audio.mp4", width: 640, height: 360, seconds: 4,
    picture: "bars", audio: "chirp", codec: .hevc, bitrate: 600_000, main10: true,
    audioBitrate: 160_000, audioTones: [0, 2011], nativeChirp: true)

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func writeJSON(_ object: Any, to url: URL) throws {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(10)
    try data.write(to: url, options: .atomic)
}

func transcript(file: String, seconds: Int, count: Int, long: Bool = false) -> [String: Any] {
    let words: [[String: Any]] = (0..<count).map { index in
        let tone = file == "joins-tone.transcript.json"
        let start = long ? Double(index) * 1.49 + 0.1 : tone ? Double(10 * index + 1) / 100 : Double(20 + 50 * index) / 100
        let end = long ? start + 0.5 : tone ? Double(10 * index + 9) / 100 : Double(45 + 50 * index) / 100
        let filler = long || tone ? index % 2 == 1 : index >= 2 && index <= 50 && (index - 2) % 3 == 0
        let text = file == "fillers-only.transcript.json" ? "um" : filler
            ? (tone || long || ((index - 2) / 3) % 2 == 0 ? "um" : "uh")
            : tone ? "w\(index / 2)" : "word\(index)"
        return ["id": "w\(index + 1)", "text": text, "kind": "word", "start": start, "end": end,
                "rawStart": start, "rawEnd": end, "conf": NSNull(), "speaker": NSNull(), "timing": "native"]
    }
    return ["schemaVersion": 1, "words": words, "language": "en", "languageProbability": NSNull(),
            "durationSeconds": seconds, "engine": ["id": "elevenlabs", "modelId": "scribe_v2",
                "modelSha256": NSNull(), "engineVersion": "synthetic-fixture", "locale": NSNull()],
            "verbatim": true, "refined": false, "pipelineVersion": 1,
            "rawKey": sha256(Data(file.utf8)), "createdAt": "2026-10-25T00:00:00Z"]
}

func makeNoise() throws -> CGImage {
    var state: UInt32 = 0x564f5843
    var bytes = [UInt8](repeating: 0, count: 256 * 144 * 4)
    for pixel in 0..<(256 * 144) {
        state = state &* 1_664_525 &+ 1_013_904_223
        let value = UInt8(32 + (state >> 24) % 160)
        bytes[pixel * 4] = value
        bytes[pixel * 4 + 1] = value
        bytes[pixel * 4 + 2] = value
        bytes[pixel * 4 + 3] = 255
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: 256, height: 144, bitsPerComponent: 8, bitsPerPixel: 32,
              bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
              shouldInterpolate: false, intent: .defaultIntent) else { throw FixtureError("cannot create noise texture") }
    return image
}

func drawFrame(_ buffer: CVPixelBuffer, fixture: Fixture, frame: Int, noise: CGImage) throws {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: fixture.width,
        height: fixture.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { throw FixtureError("cannot create BGRA drawing context") }
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    context.translateBy(x: 0, y: CGFloat(fixture.height))
    context.scaleBy(x: 1, y: -1)
    context.setShouldAntialias(false)
    let width = CGFloat(fixture.width)
    let height = CGFloat(fixture.height)
    let background: CGFloat = fixture.picture == "gray" ? 32.0 / 255 : 0
    context.setFillColor(red: background, green: background, blue: background, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if fixture.picture == "motion" {
        context.interpolationQuality = .none
        let shift = CGFloat((frame * 7) % fixture.width)
        context.draw(noise, in: CGRect(x: shift, y: 0, width: width, height: height))
        context.draw(noise, in: CGRect(x: shift - width, y: 0, width: width, height: height))
    }
    if fixture.picture == "bars" || fixture.picture == "pocket" {
        for (index, color) in barColors.enumerated() {
            context.setFillColor(red: CGFloat(color[0]) / 255, green: CGFloat(color[1]) / 255,
                                 blue: CGFloat(color[2]) / 255, alpha: 1)
            context.fill(CGRect(x: index * fixture.width / 8, y: 0, width: fixture.width / 8, height: fixture.height))
        }
    }
    if fixture.picture == "pocket" {
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: (frame * 7) % (fixture.width - 64), y: fixture.height / 2, width: 64, height: 64))
    }
    if fixture.picture == "counter" {
        context.setFillColor(gray: 1, alpha: 1)
        for column in [760, 1160] {
            context.fill(CGRect(x: column - 2, y: 200, width: 4, height: fixture.height - 200))
        }
    }
    let origin = fixture.picture == "counter" ? 720 : 16
    for bit in 0..<12 {
        context.setFillColor(gray: frame & (1 << (11 - bit)) == 0 ? 0 : 1, alpha: 1)
        context.fill(CGRect(x: origin + 40 * bit, y: 16, width: 32, height: 32))
    }
}

func pcmBuffer(start: Int, count: Int, channels: Int = 1, tone: Double? = nil,
               nativeChirp: Bool = false) throws -> CMSampleBuffer {
    var samples = [Int16](repeating: 0, count: count * channels)
    for index in 0..<count {
        let time = Double(start + index) / Double(sampleRate)
        let phase = tone.map { 2 * Double.pi * $0 * time }
            ?? (2 * Double.pi * (nativeChirp ? 997 * time + 81 * time * time
                : 200 * time + 1800 * time * time / 60))
        let amplitude = tone == 440 ? 0.4 : (nativeChirp && tone == nil ? 0.35 : 0.3)
        let value = Int16((amplitude * sin(phase) * 32767).rounded())
        for channel in 0..<channels { samples[index * channels + channel] = value }
    }
    var description = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(channels * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 2),
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    try require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format) == noErr, "cannot create PCM format")
    var block: CMBlockBuffer?
    let length = samples.count * 2
    try require(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr, "cannot allocate PCM")
    let status = samples.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
                                      dataLength: length)
    }
    try require(status == noErr, "cannot copy PCM")
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
        presentationTimeStamp: CMTime(value: Int64(start), timescale: Int32(sampleRate)), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    try require(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, "cannot create PCM samples")
    return sample!
}

func generate(_ fixture: Fixture, at url: URL) async throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(url: url, fileType: url.pathExtension == "mov" ? .mov : .mp4)
    let compression: [String: Any] = [AVVideoAverageBitRateKey: fixture.bitrate,
        AVVideoExpectedSourceFrameRateKey: frameRate, AVVideoMaxKeyFrameIntervalKey: 60,
        AVVideoAllowFrameReorderingKey: false,
        AVVideoProfileLevelKey: fixture.codec == .h264 ? AVVideoProfileLevelH264HighAutoLevel
            : (fixture.main10 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String]
    let settings: [String: Any] = [AVVideoCodecKey: fixture.codec, AVVideoWidthKey: fixture.width,
        AVVideoHeightKey: fixture.height, AVVideoColorPropertiesKey: makeColorProperties(),
        AVVideoCompressionPropertiesKey: compression,
        AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]]
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: fixture.main10
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: fixture.width, kCVPixelBufferHeightKey as String: fixture.height,
        kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
    try require(writer.canAdd(video), "cannot add video input")
    writer.add(video)
    var audioInputs: [AVAssetWriterInput] = []
    if let kind = fixture.audio {
        for index in 0..<max(1, fixture.audioTones.count) {
            var output: [String: Any] = [AVFormatIDKey: kind == "pcm" ? kAudioFormatLinearPCM : kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: fixture.audioChannels]
            if kind == "pcm" {
                output[AVLinearPCMBitDepthKey] = 16
                output[AVLinearPCMIsFloatKey] = false
                output[AVLinearPCMIsBigEndianKey] = false
                output[AVLinearPCMIsNonInterleaved] = false
            } else {
                output[AVEncoderBitRateKey] = fixture.audioBitrate
                output[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: output)
            if !fixture.audioTones.isEmpty {
                let title = AVMutableMetadataItem()
                title.identifier = .commonIdentifierTitle
                title.value = (index == 0 ? "DJI Mic" : "Built-in microphones") as NSString
                input.metadata = [title]
            }
            try require(writer.canAdd(input), "cannot add audio input")
            writer.add(input)
            audioInputs.append(input)
        }
    }
    var transfer: VTPixelTransferSession?
    if fixture.main10 {
        try require(VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer) == noErr,
                    "cannot create P010 pixel transfer session")
    }
    defer { if let transfer { VTPixelTransferSessionInvalidate(transfer) } }
    try require(writer.startWriting(), "cannot start writer: \(writer.error?.localizedDescription ?? "unknown error")")
    writer.startSession(atSourceTime: .zero)
    let noise = try makeNoise()
    do {
        let totalFrames = fixture.seconds * frameRate
        var frame = 0
        var audioFrames = [Int](repeating: 0, count: audioInputs.count)
        var deadline = Date().addingTimeInterval(60)
        while frame < totalFrames || audioFrames.contains(where: { $0 < totalFrames }) {
            try require(writer.status == .writing, "writer stopped: \(writer.error?.localizedDescription ?? "unknown error")")
            var progressed = false
            try autoreleasepool {
                if frame < totalFrames && video.isReadyForMoreMediaData {
                    var buffer: CVPixelBuffer?
                    try require(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool!, &buffer)
                        == kCVReturnSuccess, "cannot allocate video frame")
                    if let transfer {
                        var source: CVPixelBuffer?
                        try require(CVPixelBufferCreate(kCFAllocatorDefault, fixture.width, fixture.height,
                            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                            &source) == kCVReturnSuccess, "cannot allocate BGRA source frame")
                        try drawFrame(source!, fixture: fixture, frame: frame, noise: noise)
                        CVBufferPropagateAttachments(source!, buffer!)
                        try require(VTPixelTransferSessionTransferImage(transfer, from: source!, to: buffer!) == noErr,
                                    "cannot convert BGRA to P010")
                    } else { try drawFrame(buffer!, fixture: fixture, frame: frame, noise: noise) }
                    try require(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)),
                        "cannot append video: \(writer.error?.localizedDescription ?? "unknown error")")
                    frame += 1
                    if frame == totalFrames { video.markAsFinished() }
                    progressed = true
                }
                for (index, audio) in audioInputs.enumerated() where audioFrames[index] < totalFrames && audio.isReadyForMoreMediaData {
                    let tone = fixture.audioTones.isEmpty ? (fixture.audio == "pcm" ? 440.0 : nil)
                        : (fixture.audioTones[index] == 0 ? nil : fixture.audioTones[index])
                    let sample = try pcmBuffer(start: audioFrames[index] * 1600, count: 1600,
                        channels: fixture.audioChannels, tone: tone, nativeChirp: fixture.nativeChirp)
                    try require(audio.append(sample), "cannot append audio: \(writer.error?.localizedDescription ?? "unknown error")")
                    audioFrames[index] += 1
                    if audioFrames[index] == totalFrames { audio.markAsFinished() }
                    progressed = true
                }
            }
            if progressed { deadline = Date().addingTimeInterval(60) }
            else {
                try require(Date() < deadline, "writer inputs timed out")
                usleep(1000)
            }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(fixture.seconds), timescale: 1))
        await writer.finishWriting()
        try require(writer.status == .completed, "encode failed: \(writer.error?.localizedDescription ?? "unknown error")")
    } catch {
        writer.cancelWriting()
        throw error
    }
    print("wrote \(url.lastPathComponent) (\(try Data(contentsOf: url).count) bytes)")
}

func mediaIndex(in directory: URL) throws -> [[String: Any]] {
    var entries: [[String: Any]] = []
    for fixture in fixtures {
        let data = try Data(contentsOf: directory.appendingPathComponent(fixture.file))
        try require(data.count < maximumBytes, "\(fixture.file): exceeds 2 MB (\(data.count) bytes)")
        entries.append(["file": fixture.file, "bytes": data.count, "sha256": sha256(data), "width": fixture.width,
            "height": fixture.height, "fps": frameRate, "codec": "h264", "durationSeconds": fixture.seconds,
            "audio": fixture.audio.map { ["codec": $0 == "pcm" ? "pcm_s16le" : "aac", "sampleRate": sampleRate,
                                           "channels": 1] } as Any? ?? NSNull(),
            "transcript": fixture.transcripts.first as Any? ?? NSNull()])
    }
    let tinyURL = directory.appendingPathComponent("tiny.webm")
    if FileManager.default.fileExists(atPath: tinyURL.path) {
        let data = try Data(contentsOf: tinyURL)
        try require(data.count < maximumBytes, "tiny.webm: exceeds 2 MB (\(data.count) bytes)")
        entries.append(["file": "tiny.webm", "bytes": data.count, "sha256": sha256(data), "width": 320,
            "height": 180, "fps": frameRate, "codec": "vp9", "durationSeconds": 1,
            "audio": ["codec": "opus", "sampleRate": sampleRate, "channels": 1], "transcript": NSNull()])
    }
    return entries
}

func makeIndex(in directory: URL) throws {
    try writeJSON(mediaIndex(in: directory), to: directory.appendingPathComponent("index.json"))
}

func rgb(_ buffer: CVPixelBuffer, x: Int, y: Int) -> [Int] {
    let address = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return [Int(address[2]), Int(address[1]), Int(address[0])]
}

func verifyPixels(width: Int, height: Int, frame: Int, picture: String,
                  pixel: (Int, Int) -> [Int]) throws {
    let scale = Double(width) / (picture == "tiny" ? 1920 : Double(width))
    let origin = picture == "counter" || picture == "tiny" ? 720 : 16
    var barcode = 0
    for bit in 0..<12 {
        let values = pixel(Int(Double(origin + 40 * bit + 16) * scale), Int(32 * scale))
        let luma = values.reduce(0, +) / 3
        try require(luma < 65 || luma > 190, "frame \(frame): ambiguous barcode bit \(bit): \(values)")
        barcode = (barcode << 1) | (luma > 127 ? 1 : 0)
    }
    try require(barcode == frame, "frame \(frame): barcode is \(barcode), expected \(frame)")
    if picture == "counter" {
        for column in [760, 1160] {
            for row in 200..<height {
                for position in (column - 2)..<(column + 2) {
                    try require(pixel(position, row).allSatisfy { $0 > 235 },
                                "frame \(frame): missing marker at (\(position), \(row))")
                }
                for position in [column - 5, column + 4] {
                    try require(pixel(position, row).allSatisfy { $0 < 20 },
                                "frame \(frame): marker too wide at (\(position), \(row))")
                }
            }
        }
    }
    if picture == "bars" {
        for (index, expected) in barColors.enumerated() {
            for row in [height / 4, height / 2, height * 3 / 4] {
                let actual = pixel(index * 240 + 120, row)
                try require(zip(actual, expected).allSatisfy { abs($0 - $1) <= 3 },
                    "frame \(frame): bar \(index) is \(actual), expected \(expected) ±3")
            }
        }
    }
}

func verifyVideo(_ asset: AVAsset, fixture: Fixture, verifyPicture: Bool = true) async throws {
    let tracks = try await asset.loadTracks(withMediaType: .video)
    try require(tracks.count == 1, "expected exactly one video track")
    let track = tracks[0]
    let size = try await track.load(.naturalSize)
    let fps = try await track.load(.nominalFrameRate)
    let formats = try await track.load(.formatDescriptions)
    try require(Int(size.width) == fixture.width && Int(size.height) == fixture.height, "wrong video dimensions: \(size)")
    try require(abs(fps - 30) < 0.001, "wrong fps: \(fps)")
    try require(formats.count == 1 && CMFormatDescriptionGetMediaSubType(formats[0])
        == (fixture.codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC), "wrong video codec")
    if fixture.codec == .h264 {
        var parameterSet: UnsafePointer<UInt8>?
        var parameterSize = 0
        try require(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formats[0], parameterSetIndex: 0,
            parameterSetPointerOut: &parameterSet, parameterSetSizeOut: &parameterSize,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr
            && parameterSize > 1 && parameterSet?[1] == 100, "expected H.264 High profile")
    }
    let extensions = CMFormatDescriptionGetExtensions(formats[0])! as NSDictionary
    for (key, expected) in [(kCMFormatDescriptionExtension_ColorPrimaries, AVVideoColorPrimaries_ITU_R_709_2),
                            (kCMFormatDescriptionExtension_TransferFunction, AVVideoTransferFunction_ITU_R_709_2),
                            (kCMFormatDescriptionExtension_YCbCrMatrix, AVVideoYCbCrMatrix_ITU_R_709_2)] {
        try require(extensions[key] as? String == expected, "missing BT.709 \(key)")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    try require(reader.startReading(), "cannot decode video")
    var frame = 0
    while let sample = output.copyNextSampleBuffer() {
        try autoreleasepool {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try require(abs(timestamp - Double(frame) / 30) < 0.0001, "frame \(frame): wrong PTS \(timestamp)")
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw FixtureError("missing decoded frame") }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            if verifyPicture {
                try verifyPixels(width: fixture.width, height: fixture.height, frame: frame, picture: fixture.picture) {
                    rgb(buffer, x: $0, y: $1)
                }
            }
        }
        frame += 1
    }
    try require(reader.status == .completed, "video decode failed: \(reader.error?.localizedDescription ?? "unknown")")
    try require(frame == fixture.seconds * 30, "wrong frame count: \(frame)")
}

func correlate(_ samples: [Float], tone: Double?, seconds: Int, channels: Int = 1,
               nativeChirp: Bool = false) throws {
    try require(abs(samples.count / channels - seconds * sampleRate) <= 1024, "wrong decoded audio sample count: \(samples.count)")
    for fraction in [0.08, 0.5, 0.94] {
        let start = Int(Double(seconds * sampleRate) * fraction)
        let length = min(8192, samples.count / channels - start)
        var dot = 0.0
        var actualEnergy = 0.0
        var expectedEnergy = 0.0
        for offset in 0..<length {
            let time = Double(start + offset) / Double(sampleRate)
            let phase = tone.map { 2 * Double.pi * $0 * time }
                ?? (2 * Double.pi * (nativeChirp ? 997 * time + 81 * time * time
                    : 200 * time + 1800 * time * time / 60))
            let expected = (tone == 440 ? 0.4 : (nativeChirp && tone == nil ? 0.35 : 0.3)) * sin(phase)
            for channel in 0..<channels {
                let actual = Double(samples[(start + offset) * channels + channel])
                dot += expected * actual
                actualEnergy += actual * actual
                expectedEnergy += expected * expected
            }
        }
        let correlation = dot / sqrt(actualEnergy * expectedEnergy)
        try require(correlation.isFinite && correlation > 0.98, "audio correlation at \(fraction): \(correlation), expected >0.98")
        let gain = sqrt(actualEnergy / expectedEnergy)
        try require(abs(gain - 1) < 0.08, "audio amplitude at \(fraction): gain \(gain)")
    }
}

func verifyAudio(_ asset: AVAsset, fixture: Fixture) async throws {
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    try require(tracks.count == (fixture.audio == nil ? 0 : max(1, fixture.audioTones.count)), "wrong audio track count: \(tracks.count)")
    for (index, track) in tracks.enumerated() {
        let formats = try await track.load(.formatDescriptions)
        guard let description = formats.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee })
        else { throw FixtureError("missing audio format") }
        try require(description.mSampleRate == 48_000 && description.mChannelsPerFrame == fixture.audioChannels,
                    "wrong audio sample rate or channel count")
        let pcm = fixture.audio == "pcm"
        try require(description.mFormatID == (pcm ? kAudioFormatLinearPCM : kAudioFormatMPEG4AAC), "wrong audio codec")
        if pcm {
            try require(description.mBitsPerChannel == 16 && description.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
                        "expected LPCM s16")
        } else {
            let bitrate = try await track.load(.estimatedDataRate)
            try require(abs(bitrate - Float(fixture.audioBitrate)) < 20_000, "wrong AAC bitrate: \(bitrate)")
            if let format = formats.first, let list = CMAudioFormatDescriptionGetFormatList(format, sizeOut: nil) {
                try require(list.pointee.mASBD.mFormatID == kAudioFormatMPEG4AAC, "expected AAC-LC")
            }
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        try require(reader.startReading(), "cannot decode audio")
        var samples = [Float]()
        while let sample = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sample) {
                let length = CMBlockBufferGetDataLength(block)
                var decoded = [Float](repeating: 0, count: length / 4)
                let status = decoded.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
                }
                try require(status == noErr, "cannot read decoded PCM")
                samples.append(contentsOf: decoded)
            }
        }
        try require(reader.status == .completed, "audio decode failed")
        if pcm {
            try require(samples.count == fixture.seconds * sampleRate * fixture.audioChannels,
                        "wrong exact LPCM sample count: \(samples.count)")
        }
        let tone = fixture.audioTones.isEmpty ? (pcm ? 440.0 : nil)
            : (fixture.audioTones[index] == 0 ? nil : fixture.audioTones[index])
        try correlate(samples, tone: tone, seconds: fixture.seconds, channels: fixture.audioChannels,
                      nativeChirp: fixture.nativeChirp)
    }
}

func verifyPocket(_ url: URL) async throws {
    let data = try Data(contentsOf: url)
    try require(data.count < maximumBytes, "camera fixture exceeds 2 MB")
    let metadata = try runTool("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path])
    let object = try JSONSerialization.jsonObject(with: metadata) as! [String: Any]
    let streams = object["streams"] as! [[String: Any]]
    let video = streams.first { $0["codec_type"] as? String == "video" }
    try require(video?["profile"] as? String == "Main 10" && video?["pix_fmt"] as? String == "yuv420p10le"
        && video?["codec_tag_string"] as? String == "hvc1", "camera fixture must be HEVC Main 10 P010/hvc1")
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    try require(abs(duration - 6) < 0.001, "camera fixture must be six seconds")
    try await verifyVideo(asset, fixture: pocketFixture)
    try await verifyAudio(asset, fixture: pocketFixture)
    print("ok \(url.lastPathComponent): \(data.count) bytes, \(sha256(data).prefix(12)), Main 10 and both stereo tones verified")
}

func verifyWindowsHevc(_ url: URL) async throws {
    let data = try Data(contentsOf: url)
    try require(data.count < maximumBytes, "Windows HEVC fixture exceeds 2 MB")
    let asset = AVURLAsset(url: url)
    let videos = try await asset.loadTracks(withMediaType: .video)
    try require(videos.count == 1, "Windows HEVC fixture needs one video track")
    let formats = try await videos[0].load(.formatDescriptions)
    try require(formats.count == 1 && CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_HEVC,
                "Windows HEVC fixture needs hvc1")
    let extensions = CMFormatDescriptionGetExtensions(formats[0]) as NSDictionary? ?? [:]
    let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary
    guard let hvcC = atoms?["hvcC"] as? Data, hvcC.count >= 19 else {
        throw FixtureError("Windows HEVC fixture has no hvcC decoder configuration")
    }
    try require(hvcC[0] == 1 && hvcC[1] & 0x1f == 2 && hvcC[16] & 3 == 1
                && hvcC[17] & 7 == 2 && hvcC[18] & 7 == 2,
                "Windows HEVC fixture needs Main 10, 4:2:0, ten-bit luma and chroma")
    let duration = try await asset.load(.duration).seconds
    try require(abs(duration - 4) < 0.04, "Windows HEVC fixture duration must be four seconds")
    try await verifyVideo(asset, fixture: windowsHevcFixture, verifyPicture: false)
    try await verifyAudio(asset, fixture: windowsHevcFixture)
    print("ok \(url.lastPathComponent): \(data.count) bytes, Main 10 and two audio tracks verified")
}

func toolURL(_ name: String) throws -> URL {
    let candidates = [ProcessInfo.processInfo.environment["VOXCLIP_\(name.uppercased())"],
        NSHomeDirectory() + "/miniconda3/bin/" + name, "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]
    guard let path = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { throw FixtureError("\(name) is required for WebM or camera profile verification; set VOXCLIP_\(name.uppercased())") }
    return URL(fileURLWithPath: path)
}

func runTool(_ name: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = try toolURL(name)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "\(name) failed with exit \(process.terminationStatus)")
    return data
}

func verifyTiny(_ url: URL) throws {
    let metadata = try runTool("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path])
    let object = try JSONSerialization.jsonObject(with: metadata) as! [String: Any]
    let streams = object["streams"] as! [[String: Any]]
    let video = streams.first { $0["codec_type"] as? String == "video" }
    let audio = streams.first { $0["codec_type"] as? String == "audio" }
    try require(streams.count == 2 && video?["codec_name"] as? String == "vp9" && audio?["codec_name"] as? String == "opus",
                "tiny.webm: expected VP9 and Opus")
    try require(video?["width"] as? Int == 320 && video?["height"] as? Int == 180 && video?["r_frame_rate"] as? String == "30/1",
                "tiny.webm: expected 320×180 30 fps")
    try require(audio?["sample_rate"] as? String == "48000" && audio?["channels"] as? Int == 1,
                "tiny.webm: expected 48 kHz mono Opus")
    let duration = Double((object["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
    try require(abs(duration - 1) < 0.02, "tiny.webm: wrong duration \(duration)")
    for key in ["color_primaries", "color_transfer", "color_space"] {
        try require(video?[key] as? String == "bt709", "tiny.webm: missing BT.709 \(key)")
    }
    let frames = try runTool("ffmpeg", ["-v", "error", "-i", url.path, "-map", "0:v:0", "-f", "rawvideo", "-pix_fmt", "bgra", "-"])
    let stride = 320 * 180 * 4
    try require(frames.count == stride * 30, "tiny.webm: wrong frame count")
    try frames.withUnsafeBytes { bytes in
        let pixels = bytes.bindMemory(to: UInt8.self)
        for frame in 0..<30 {
            try verifyPixels(width: 320, height: 180, frame: frame, picture: "tiny") { column, row in
                let offset = frame * stride + (row * 320 + column) * 4
                return [Int(pixels[offset + 2]), Int(pixels[offset + 1]), Int(pixels[offset])]
            }
        }
    }
    let audioBytes = try runTool("ffmpeg", ["-v", "error", "-i", url.path, "-map", "0:a:0", "-f", "f32le", "-"])
    let samples = audioBytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    try correlate(samples, tone: nil, seconds: 1)
}

func verifyTranscripts(_ directory: URL) throws {
    for (file, seconds, count, fillers) in [("joins-tone.transcript.json", 12, 119, 59),
        ("fillers-chirp.transcript.json", 30, 60, 17), ("fillers-only.transcript.json", 30, 60, 60)] {
        guard let actual = try JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent(file))) as? NSDictionary else {
            throw FixtureError("\(file): transcript must be a JSON object")
        }
        let expected = transcript(file: file, seconds: seconds, count: count) as NSDictionary
        try require(actual == expected, "\(file): transcript content differs from architecture 9.5")
        let words = actual["words"] as! [[String: Any]]
        let fillerWords = words.filter { ["um", "uh"].contains($0["text"] as! String) }
        try require(fillerWords.count == fillers, "\(file): wrong filler count")
        if file == "fillers-chirp.transcript.json" {
            let kept = words.filter { !["um", "uh"].contains($0["text"] as! String) }
            for (previous, next) in zip(kept, kept.dropFirst()) {
                let gap = (next["start"] as! Double) - (previous["end"] as! Double)
                try require(gap >= 0.25 - 0.000001, "\(file): caption gap below 0.25 s")
            }
        }
    }
}

func verify(_ directory: URL) async throws {
    guard let entries = try JSONSerialization.jsonObject(with: Data(contentsOf:
        directory.appendingPathComponent("index.json"))) as? [[String: Any]] else {
        throw FixtureError("index.json must be an array of media records")
    }
    let names = entries.compactMap { $0["file"] as? String }
    try require(Set(names) == Set(fixtures.map(\.file) + ["tiny.webm"]) && entries.count == 6,
                "index.json must list exactly the six canonical media files")
    let expected = try mediaIndex(in: directory)
    for entry in entries {
        let file = entry["file"] as! String
        try require(NSDictionary(dictionary: entry) == NSDictionary(dictionary:
            expected.first { $0["file"] as? String == file }!), "\(file): index metadata differs from canonical specification")
    }
    for entry in entries {
        let file = entry["file"] as! String
        let url = directory.appendingPathComponent(file)
        do {
            let data = try Data(contentsOf: url)
            try require(data.count < maximumBytes && data.count == entry["bytes"] as? Int, "size does not match index or exceeds 2 MB")
            try require(sha256(data) == entry["sha256"] as? String, "SHA-256 does not match index")
            if file == "tiny.webm" { try verifyTiny(url) }
            else {
                let fixture = fixtures.first { $0.file == file }!
                try require(entry["width"] as? Int == fixture.width && entry["height"] as? Int == fixture.height
                    && entry["fps"] as? Int == 30 && entry["durationSeconds"] as? Int == fixture.seconds
                    && entry["codec"] as? String == "h264", "index video metadata differs from specification")
                let expectedAudio: Any = fixture.audio.map { ["codec": $0 == "pcm" ? "pcm_s16le" : "aac",
                    "sampleRate": sampleRate, "channels": 1] } as Any? ?? NSNull()
                try require(NSDictionary(dictionary: ["audio": entry["audio"] as Any]) == NSDictionary(dictionary: ["audio": expectedAudio]),
                            "index audio metadata differs from specification")
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                try require(abs(duration - Double(fixture.seconds)) < 0.001, "wrong duration: \(duration)")
                try await verifyVideo(asset, fixture: fixture)
                try await verifyAudio(asset, fixture: fixture)
            }
            print("ok \(file): \(data.count) bytes, \(sha256(data).prefix(12)), content verified")
        } catch { throw FixtureError("\(file): \(error)") }
    }
    try verifyTranscripts(directory)
    print("ok transcript companions: 119/60/60 items, 59/17/60 fillers, caption gaps ≥0.25 s")
}

func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    try require(arguments.count == 2, "usage: swift tools/fixtures/media/generate.swift --out DIR | --verify DIR | --index DIR | --long-hevc FILE | --motion-60s FILE | --pocket4 FILE | --verify-pocket4 FILE | --win-hevc FILE | --verify-win-hevc FILE")
    let destination = URL(fileURLWithPath: arguments[1])
    switch arguments[0] {
    case "--out":
        for fixture in fixtures { try await generate(fixture, at: destination.appendingPathComponent(fixture.file)) }
        for (file, seconds, count) in [("joins-tone.transcript.json", 12, 119),
            ("fillers-chirp.transcript.json", 30, 60), ("fillers-only.transcript.json", 30, 60)] {
            try writeJSON(transcript(file: file, seconds: seconds, count: count), to: destination.appendingPathComponent(file))
        }
        try makeIndex(in: destination)
    case "--index": try makeIndex(in: destination)
    case "--verify": try await verify(destination)
    case "--pocket4":
        try await generate(pocketFixture, at: destination)
        try await verifyPocket(destination)
    case "--verify-pocket4": try await verifyPocket(destination)
    case "--win-hevc":
        try await generate(windowsHevcFixture, at: destination)
        try await verifyWindowsHevc(destination)
    case "--verify-win-hevc": try await verifyWindowsHevc(destination)
    case "--long-hevc", "--motion-60s":
        let long = arguments[0] == "--long-hevc"
        try await generate(Fixture(file: destination.lastPathComponent, width: 1920, height: 1080,
            seconds: long ? 600 : 60, picture: "motion", audio: "chirp", codec: long ? .hevc : .h264,
            bitrate: 1_000_000), at: destination)
        if long {
            let companion = destination.deletingPathExtension().appendingPathExtension("transcript.json")
            try writeJSON(transcript(file: companion.lastPathComponent, seconds: 600, count: 401, long: true), to: companion)
        }
    default: throw FixtureError("unknown option: \(arguments[0])")
    }
}

do { try await main() }
catch {
    FileHandle.standardError.write(Data("media fixtures: \(error)\n".utf8))
    exit(1)
}
