// Prints what the hosted macOS runner offers for H.264 encoding, before the Swift tests run.
// Encoding uses VideoToolbox and CoreMedia only; Foundation bridges the encoder list and formats
// output. Diagnostic only: every outcome is printed and the script always exits 0.
// Usage: swift tools/ci/macos-encoder-probe.swift "$(xcrun --sdk macosx --show-sdk-version)"
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

setvbuf(stdout, nil, _IOLBF, 0)

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: value)
}

func sysctlInteger(_ name: String) -> String {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? String(value) : "unknown"
}

func seconds(since start: UInt64) -> String {
    String(format: "%.3f s", Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9)
}

final class EncodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var encoded = 0
    private var failures: [OSStatus] = []

    func record(_ status: OSStatus, sample: CMSampleBuffer?) {
        lock.withLock { if status == noErr && sample != nil { encoded += 1 } else { failures.append(status) } }
    }

    var summary: String { lock.withLock { "\(encoded) of 60 frames encoded; failures \(failures)" } }
}

print("hw.ncpu: \(sysctlInteger("hw.ncpu"))")
print("hw.memsize: \(sysctlInteger("hw.memsize"))")
print("os: macOS \(sysctlString("kern.osproductversion")) (\(sysctlString("kern.osversion")))")
print("sdk: \(CommandLine.arguments.dropFirst().first ?? "unknown")")

var encoders: CFArray?
print("VTCopyVideoEncoderList: status \(VTCopyVideoEncoderList(nil, &encoders))")
for case let encoder as [String: Any] in (encoders as? [Any]) ?? [] {
    let codec = (encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber).map { value in
        let bytes = [24, 16, 8, 0].map { UInt8((value.uint32Value >> $0) & 0xff) }
        return bytes.allSatisfy { (0x20...0x7e).contains($0) } ? String(decoding: bytes, as: UTF8.self) : "\(value)"
    } ?? "?"
    print("  encoder \(codec) \(encoder[kVTVideoEncoderList_EncoderID as String] ?? "?")"
        + " \"\(encoder[kVTVideoEncoderList_EncoderName as String] ?? "?")\""
        + " hardware=\(encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] ?? "unlisted")")
}

/// Encodes 60 synthetic 1280x720 frames with the given encoder specification and prints the time.
func probe(_ label: String, specification: [CFString: Any]) {
    var session: VTCompressionSession?
    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 1280, height: 720,
        codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &session)
    guard status == noErr, let session else {
        print("\(label): VTCompressionSessionCreate failed with status \(status) after \(seconds(since: start))")
        return
    }
    defer { VTCompressionSessionInvalidate(session) }
    var usingHardware: CFBoolean?
    let hardwareStatus = withUnsafeMutablePointer(to: &usingHardware) {
        VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: kCFAllocatorDefault, valueOut: $0)
    }
    let hardware = hardwareStatus == noErr ? usingHardware.map { "\(CFBooleanGetValue($0))" } ?? "unknown" : "status \(hardwareStatus)"
    print("\(label): session created in \(seconds(since: start)); using hardware: \(hardware)")
    var frame: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &frame) == kCVReturnSuccess, let frame else {
        print("\(label): could not create a pixel buffer")
        return
    }
    let frames = EncodedFrames()
    let encodeStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    for index in 0..<60 {
        CVPixelBufferLockBaseAddress(frame, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(frame) {
            memset(CVPixelBufferGetBaseAddressOfPlane(frame, plane), Int32((index * 4 + plane * 64) & 0xff),
                CVPixelBufferGetBytesPerRowOfPlane(frame, plane) * CVPixelBufferGetHeightOfPlane(frame, plane))
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let submitted = VTCompressionSessionEncodeFrame(session, imageBuffer: frame,
            presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30), duration: CMTime(value: 1, timescale: 30),
            frameProperties: nil, infoFlagsOut: nil) { status, _, sample in frames.record(status, sample: sample) }
        if submitted != noErr { frames.record(submitted, sample: nil) }
        if index % 20 == 19 { print("\(label): submitted \(index + 1) frames after \(seconds(since: encodeStart))") }
    }
    let completed = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    print("\(label): \(frames.summary) in \(seconds(since: encodeStart)); complete status \(completed)")
}

probe("hardware H.264 (required)", specification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true])
probe("software H.264 (hardware disabled)", specification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false])
print("encoder probe finished")
exit(0)
