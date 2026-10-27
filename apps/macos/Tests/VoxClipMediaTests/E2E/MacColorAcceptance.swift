import AVFoundation
import Foundation
import Synchronization
import Testing
import VideoToolbox
import VoxClipCore
@testable import VoxClipMedia

// Independent test-side BT.709 limited-range arithmetic. Production has no RGB/YUV converter.
enum MacColorAcceptance {
    static let frames: [Int64] = [9, 15, 30]
    static let canonical = [[191,191,191], [191,191,0], [0,191,191], [0,191,0],
                            [191,0,191], [191,0,0], [0,0,191], [0,0,0]]
    static let points: [(x: Int, y: Int)] = (0..<8).flatMap { bar in
        (0..<3).map { position in (x: bar * 240 + 60 * (position + 1), y: 300 + 200 * position) }
    }

    static func forward(_ rgb: [Int]) -> [Int] {
        let r = Double(rgb[0]), g = Double(rgb[1]), b = Double(rgb[2])
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        func halfUp(_ value: Double) -> Int { Int(floor(value + 0.5)) }
        return [halfUp(16 + luma * 219 / 255),
                halfUp(128 + (b - luma) * 224 / (255 * 1.8556)),
                halfUp(128 + (r - luma) * 224 / (255 * 1.5748))]
    }

    static func inverse(_ yuv: [Int]) -> [Double] {
        let y = (Double(yuv[0]) - 16) * 255 / 219
        let u = (Double(yuv[1]) - 128) * 255 / 224
        let v = (Double(yuv[2]) - 128) * 255 / 224
        return [y + 1.5748 * v, y - 0.187324 * u - 0.468124 * v, y + 1.8556 * u]
            .map { min(255, max(0, $0)) }
    }

    struct DecodedFrame {
        let pts: Double
        let yuv: [[Int]]
        let rgb: [[Int]]
    }

    struct DecodedVideo {
        let frames: [Int64: DecodedFrame]
        let yuvFrameCount: Int64
        let rgbFrameCount: Int64
    }

    static func matchingPTS(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= 0.000001
    }

    struct Metadata {
        let codec: FourCharCode
        let high: Bool
        let chroma420: Bool
        let eightBit: Bool
        let limited: Bool
        let primaries709: Bool
        let transfer709: Bool
        let matrix709: Bool
        var failures: [String] {
            [codec == kCMVideoCodecType_H264 ? nil : "codec",
             high ? nil : "profile High", chroma420 ? nil : "4:2:0",
             eightBit ? nil : "8-bit", limited ? nil : "limited range",
             primaries709 ? nil : "BT.709 primaries", transfer709 ? nil : "BT.709 transfer",
             matrix709 ? nil : "BT.709 matrix"].compactMap { $0 }
        }
    }

    static func metadata(_ url: URL) async throws -> Metadata {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Data]
        let avcC = atoms?["avcC"]
        let sps = avcC.flatMap { bytes -> [UInt8]? in
            let value = [UInt8](bytes)
            guard value.count >= 8, value[0] == 1 else { return nil }
            let length = Int(value[6]) << 8 | Int(value[7])
            guard length > 1, value.count >= 8 + length else { return nil }
            return Array(value[8..<(8 + length)])
        }
        let coding = sps.flatMap(spsCoding)
        let bt709 = kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String
        let limited = (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? NSNumber)?.boolValue == false
        return Metadata(codec: CMFormatDescriptionGetMediaSubType(format), high: sps?.dropFirst().first == 100,
                        chroma420: coding?.0 == 1, eightBit: coding?.1 == 0 && coding?.2 == 0,
                        limited: limited,
                        primaries709: CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String == bt709,
                        transfer709: CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String),
                        matrix709: CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String))
    }

    private struct Bits {
        let data: [UInt8]
        var offset = 0
        mutating func read(_ count: Int) -> Int? {
            guard count >= 0, count <= 24, offset + count <= data.count * 8 else { return nil }
            var result = 0
            for _ in 0..<count {
                result = (result << 1) | Int((data[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return result
        }
        mutating func ue() -> Int? {
            var zeros = 0
            while true {
                guard let bit = read(1) else { return nil }
                if bit == 1 { break }
                zeros += 1
                if zeros > 23 { return nil }
            }
            guard let suffix = read(zeros) else { return nil }
            return (1 << zeros) - 1 + suffix
        }
    }

    private static func spsCoding(_ sps: [UInt8]) -> (Int, Int, Int)? {
        guard sps.count > 4, sps[0] & 0x1f == 7, sps[1] == 100 else { return nil }
        var rbsp = [UInt8](), zeros = 0
        for byte in sps.dropFirst() {
            if zeros == 2 && byte == 3 { zeros = 0; continue }
            rbsp.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        var bits = Bits(data: rbsp)
        guard bits.read(8) == 100, bits.read(8) != nil, bits.read(8) != nil,
              bits.ue() != nil, let chroma = bits.ue() else { return nil }
        if chroma == 3 && bits.read(1) == nil { return nil }
        guard let luma = bits.ue(), let chromaDepth = bits.ue() else { return nil }
        return (chroma, luma, chromaDepth)
    }

    static func decoded(_ url: URL) async throws -> DecodedVideo {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        func read(_ format: OSType) async throws -> ([Double], [Int64: [[Int]]]) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
            let provider = reader.outputProvider(for: output)
            try #require(reader.startReading())
            var pts = [Double](), samples = [Int64: [[Int]]]()
            while let ready = try await provider.next() {
                let index = Int64(pts.count)
                let framePTS = ready.presentationTimeStamp.seconds
                try #require(framePTS.isFinite, "frame \(index): non-finite decoded PTS")
                pts.append(framePTS)
                if frames.contains(index) {
                    let pixels = try ready.withUnsafeSampleBuffer { raw -> [[Int]] in
                        let buffer = try #require(CMSampleBufferGetImageBuffer(raw))
                        try #require(CVPixelBufferGetPixelFormatType(buffer) == format)
                        try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
                        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                        try #require(points.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x < width && $0.y < height },
                                     "frame \(index): sample point outside decoded \(width)x\(height) image")
                        if format == kCVPixelFormatType_32BGRA {
                            let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
                            let stride = CVPixelBufferGetBytesPerRow(buffer)
                            try #require(stride >= 4 && points.allSatisfy { $0.x <= (stride - 4) / 4 },
                                         "frame \(index): BGRA point outside row stride")
                            return points.map { point in
                                let offset = point.y * stride + point.x * 4
                                return [Int(base[offset + 2]), Int(base[offset + 1]), Int(base[offset])]
                            }
                        }
                        try #require(CVPixelBufferGetPlaneCount(buffer) == 2)
                        let yWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
                        let yHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
                        let uvWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
                        let uvHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
                        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
                        try #require(uvStride >= 2 && points.allSatisfy { point in
                            point.x < yWidth && point.y < yHeight && point.x < yStride &&
                            point.x / 2 < uvWidth && point.y / 2 < uvHeight &&
                            point.x / 2 <= (uvStride - 2) / 2
                        }, "frame \(index): sample point outside YUV plane bounds")
                        let y = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
                        let uv = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
                        return points.map { point in
                            let chroma = point.y / 2 * uvStride + point.x / 2 * 2
                            return [Int(y[point.y * yStride + point.x]), Int(uv[chroma]), Int(uv[chroma + 1])]
                        }
                    }
                    samples[index] = pixels
                }
            }
            try #require(reader.status == .completed)
            return (pts, samples)
        }
        let yuv = try await read(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let rgb = try await read(kCVPixelFormatType_32BGRA)
        try #require(yuv.0.count == rgb.0.count, "YUV and BGRA decoded frame counts differ")
        for index in yuv.0.indices {
            try #require(matchingPTS(yuv.0[index], rgb.0[index]),
                         "frame \(index): YUV PTS \(yuv.0[index]) vs BGRA PTS \(rgb.0[index])")
        }
        var result = [Int64: DecodedFrame]()
        for frame in frames {
            guard let y = yuv.1[frame], let r = rgb.1[frame] else { continue }
            result[frame] = DecodedFrame(pts: yuv.0[Int(frame)], yuv: y, rgb: r)
        }
        return DecodedVideo(frames: result, yuvFrameCount: Int64(yuv.0.count), rgbFrameCount: Int64(rgb.0.count))
    }

    /// Decoded-YUV bound for the encoder that wrote the export (ADR-R22). Physical VideoToolbox hardware is the
    /// required-hardware acceptance at ±1. Hosted CI's paravirtualized encoder is a drift guard at ±2; a matrix,
    /// range or primaries error moves decoded YUV by tens of codes. Every other check is the same for both.
    struct EncoderProfile: Equatable {
        static let requiredHardware = EncoderProfile(encoderID: "com.apple.videotoolbox.videoencoder.ave.avc")
        let encoderID: String
        var isParavirtualized: Bool { encoderID.hasPrefix("paravirtualized:") }
        var name: String { isParavirtualized ? "paravirtualized drift guard" : "required hardware" }
        var decodedYUVTolerance: Int { isParavirtualized ? 2 : 1 }
        var report: [String: Any] { ["encoderID": encoderID, "profile": name, "decodedYUVTolerance": decodedYUVTolerance] }

        /// The encoder VideoToolbox selects for H.264 when hardware is required, as the exporter requires it, named
        /// as VideoToolbox lists it. A session that reports no encoder, or one VideoToolbox does not list as hardware
        /// H.264, is taken to use the only listed hardware H.264 encoder.
        static func selected() -> EncoderProfile {
            var list: CFArray?
            let listed = VTCopyVideoEncoderList(nil, &list) == noErr ? ((list as? [Any]) ?? []).compactMap { $0 as? [String: Any] } : []
            let hardware = listed.filter {
                ($0[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == kCMVideoCodecType_H264
                    && ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
            }.compactMap { $0[kVTVideoEncoderList_EncoderID as String] as? String }
            var session: VTCompressionSession?
            guard VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 1920, height: 1080, codecType: kCMVideoCodecType_H264,
                encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &session) == noErr, let session else { return EncoderProfile(encoderID: "unavailable") }
            defer { VTCompressionSessionInvalidate(session) }
            var id: CFString?
            let status = withUnsafeMutablePointer(to: &id) {
                VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID, allocator: kCFAllocatorDefault, valueOut: $0)
            }
            let reported = status == noErr ? id.map { $0 as String } : nil
            if let reported, hardware.contains(reported) { return EncoderProfile(encoderID: reported) }
            return EncoderProfile(encoderID: hardware.count == 1 ? hardware[0] : reported ?? "unknown")
        }
    }

    struct Row {
        let frame: Int64
        let point: Int
        let pts: Double
        let decodedPTS: Double
        let input: [Int]
        let yuv: [Int]
        let rgb: [Int]
    }

    static func validate(_ rows: [Row], metadata: Metadata, label: String, profile: EncoderProfile = .requiredHardware) -> [String] {
        var failures = metadata.failures.map { "\(label): \($0)" }
        let expectedKeys = Set(frames.flatMap { frame in (0..<24).map { "\(frame):\($0)" } })
        let keys = rows.map { "\($0.frame):\($0.point)" }
        for key in expectedKeys.subtracting(Set(keys)).sorted() { failures.append("\(label): missing \(key)") }
        for (key, count) in Dictionary(grouping: keys, by: { $0 }).mapValues(\.count) where count != 1 {
            failures.append("\(label): duplicate \(key) count \(count)")
        }
        for row in rows {
            let bar = row.point / 3
            guard frames.contains(row.frame), row.point >= 0, row.point < 24,
                  row.input.count == 3, row.yuv.count == 3, row.rgb.count == 3 else {
                failures.append("\(label): malformed row"); continue
            }
            let expectedPTS = Double(row.frame) / 30
            if !matchingPTS(row.pts, expectedPTS) { failures.append("\(label): frame \(row.frame) point \(row.point) PTS \(row.pts)") }
            if !matchingPTS(row.decodedPTS, row.pts) { failures.append("\(label): frame \(row.frame) point \(row.point) decoded PTS \(row.decodedPTS) vs input \(row.pts)") }
            let forwardYUV = forward(row.input)
            for channel in 0..<3 {
                if abs(row.input[channel] - canonical[bar][channel]) > 3 {
                    failures.append("\(label): frame \(row.frame) point \(row.point) preinput RGB \(channel) \(row.input[channel])")
                }
                if abs(row.yuv[channel] - forwardYUV[channel]) > profile.decodedYUVTolerance {
                    failures.append("\(label): frame \(row.frame) point \(row.point) decoded YUV \(channel) \(row.yuv[channel]) vs \(forwardYUV[channel])")
                }
            }
            let inverseRGB = inverse(row.yuv)
            for channel in 0..<3 where !inverseRGB[channel].isFinite || abs(Double(row.rgb[channel]) - inverseRGB[channel]) > 2 {
                failures.append("\(label): frame \(row.frame) point \(row.point) inverse RGB \(channel) \(row.rgb[channel]) vs \(inverseRGB[channel])")
            }
        }
        return failures.sorted()
    }

    static func csv(_ rows: [Row], to url: URL) throws {
        var text = "frame,inputPTS,decodedPTS,bar,position,x,y,canonicalRGB,submittedRGB,independentYUV,decodedYUV,decodedRGB,maxInputRGBerror,Yerror,Uerror,Verror\n"
        for row in rows.sorted(by: { ($0.frame, $0.point) < ($1.frame, $1.point) }) {
            let bar = row.point / 3, position = row.point % 3, expected = forward(row.input)
            func triple(_ values: [Int]) -> String { values.map(String.init).joined(separator: "/") }
            let error = zip(row.input, canonical[bar]).map { abs($0 - $1) }.max() ?? -1
            text += "\(row.frame),\(row.pts),\(row.decodedPTS),\(bar),\(position),\(points[row.point].x),\(points[row.point].y),\(triple(canonical[bar])),\(triple(row.input)),\(triple(expected)),\(triple(row.yuv)),\(triple(row.rgb)),\(error),\(abs(row.yuv[0]-expected[0])),\(abs(row.yuv[1]-expected[1])),\(abs(row.yuv[2]-expected[2]))\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

@Test func macBT709AcceptanceRejectsMutations() {
    typealias A = MacColorAcceptance
    #expect(A.forward([0,0,0]) == [16,128,128])
    #expect(A.forward([255,255,255]) == [235,128,128])
    #expect(A.forward([0,191,0]) == [133,63,52])
    #expect(A.forward([191,0,0]) == [51,109,212])
    // BT.601 green has a different luma; full-range black starts at zero.
    let bt601GreenY = Int(floor(16 + 0.587 * 191 * 219 / 255 + 0.5))
    #expect(bt601GreenY != A.forward([0,191,0])[0])
    #expect(A.forward([0,0,0])[0] != 0)
    let good = A.Metadata(codec: kCMVideoCodecType_H264, high: true, chroma420: true, eightBit: true,
                          limited: true, primaries709: true, transfer709: true, matrix709: true)
    let base = A.Row(frame: 9, point: 0, pts: 0.3, decodedPTS: 0.3, input: [191,191,191], yuv: [180,128,128], rgb: [191,191,191])
    #expect(A.validate([base], metadata: good, label: "test").filter { !$0.contains("missing") }.isEmpty)
    for channel in 0..<3 {
        var bad = base.yuv; bad[channel] += 2
        let row = A.Row(frame: 9, point: 0, pts: 0.3, decodedPTS: 0.3, input: base.input, yuv: bad, rgb: base.rgb)
        #expect(A.validate([row], metadata: good, label: "test").contains { $0.contains("decoded YUV \(channel)") })
    }
    let wrongInput = A.Row(frame: 9, point: 0, pts: 0.3, decodedPTS: 0.3, input: [195,191,191], yuv: [181,129,130], rgb: base.rgb)
    #expect(A.validate([wrongInput], metadata: good, label: "test").contains { $0.contains("preinput RGB") })
    let green601 = A.Row(frame: 9, point: 9, pts: 0.3, decodedPTS: 0.3, input: [0,191,0],
                         yuv: [bt601GreenY, 63, 52], rgb: [0,191,0])
    #expect(A.validate([green601], metadata: good, label: "test").contains { $0.contains("decoded YUV 0") })
    let fullRangeBlack = A.Row(frame: 9, point: 21, pts: 0.3, decodedPTS: 0.3, input: [0,0,0],
                               yuv: [0,128,128], rgb: [0,0,0])
    #expect(A.validate([fullRangeBlack], metadata: good, label: "test").contains { $0.contains("decoded YUV 0") })
    #expect(A.validate([base, base], metadata: good, label: "test").contains { $0.contains("duplicate") })
    #expect(A.validate([], metadata: good, label: "test").contains { $0.contains("missing") })
    #expect(!A.matchingPTS(.nan, 0.3))
    #expect(!A.matchingPTS(0.3, .infinity))
    #expect(!A.matchingPTS(0.3, 0.31))
    let badInputPTS = A.Row(frame: 9, point: 0, pts: .nan, decodedPTS: 0.3,
                            input: base.input, yuv: base.yuv, rgb: base.rgb)
    #expect(A.validate([badInputPTS], metadata: good, label: "test").contains { $0.contains("point 0 PTS nan") })
    let badDecodedPTS = A.Row(frame: 9, point: 0, pts: 0.3, decodedPTS: .infinity,
                              input: base.input, yuv: base.yuv, rgb: base.rgb)
    #expect(A.validate([badDecodedPTS], metadata: good, label: "test").contains { $0.contains("decoded PTS inf") })
    let wrong = A.Metadata(codec: kCMVideoCodecType_H264, high: false, chroma420: false, eightBit: false,
                           limited: false, primaries709: false, transfer709: false, matrix709: false)
    let metadataFailures = A.validate([base], metadata: wrong, label: "test").filter { !$0.contains("missing") }
    #expect(Set(metadataFailures) == Set(["profile High", "4:2:0", "8-bit", "limited range",
                                          "BT.709 primaries", "BT.709 transfer", "BT.709 matrix"].map { "test: \($0)" }))
}

@Test func macBT709EncoderProfilesBoundOnlyDecodedYUV() {
    typealias A = MacColorAcceptance
    let hosted = A.EncoderProfile(encoderID: "paravirtualized:com.apple.videotoolbox.videoencoder.ave.avc")
    #expect(hosted.isParavirtualized && hosted.decodedYUVTolerance == 2)
    #expect(!A.EncoderProfile.requiredHardware.isParavirtualized && A.EncoderProfile.requiredHardware.decodedYUVTolerance == 1)
    #expect(hosted.report["encoderID"] as? String == hosted.encoderID && hosted.report["profile"] as? String == "paravirtualized drift guard")
    let good = A.Metadata(codec: kCMVideoCodecType_H264, high: true, chroma420: true, eightBit: true,
                          limited: true, primaries709: true, transfer709: true, matrix709: true)
    let magenta = [191, 0, 191], expected = A.forward(magenta)
    func row(_ yuv: [Int], input: [Int]) -> A.Row {
        A.Row(frame: 30, point: 12, pts: 1, decodedPTS: 1, input: input, yuv: yuv, rgb: input)
    }
    func yuvFailures(_ row: A.Row, _ profile: A.EncoderProfile) -> [String] {
        A.validate([row], metadata: good, label: "test", profile: profile).filter { $0.contains("decoded YUV") }
    }
    for channel in 0..<3 {
        var two = expected, three = expected
        two[channel] -= 2; three[channel] -= 3
        #expect(!yuvFailures(row(two, input: magenta), .requiredHardware).isEmpty)
        #expect(yuvFailures(row(two, input: magenta), hosted).isEmpty)
        #expect(!yuvFailures(row(three, input: magenta), hosted).isEmpty)
    }
    // Matrix and range errors are tens of codes, so the drift guard still rejects them.
    let bt601GreenY = Int(floor(16 + 0.587 * 191 * 219 / 255 + 0.5))
    #expect(!yuvFailures(A.Row(frame: 30, point: 9, pts: 1, decodedPTS: 1, input: [0, 191, 0], yuv: [bt601GreenY, 63, 52], rgb: [0, 191, 0]), hosted).isEmpty)
    #expect(!yuvFailures(A.Row(frame: 30, point: 21, pts: 1, decodedPTS: 1, input: [0, 0, 0], yuv: [0, 128, 128], rgb: [0, 0, 0]), hosted).isEmpty)
    // Submitted RGB and format checks do not depend on the profile.
    #expect(A.validate([row(expected, input: [195, 0, 191])], metadata: good, label: "test", profile: hosted).contains { $0.contains("preinput RGB 0") })
    let wrong = A.Metadata(codec: kCMVideoCodecType_H264, high: false, chroma420: true, eightBit: true,
                           limited: false, primaries709: true, transfer709: true, matrix709: false)
    let tags = A.validate([row(expected, input: magenta)], metadata: wrong, label: "test", profile: hosted)
    #expect(tags.contains("test: profile High") && tags.contains("test: limited range") && tags.contains("test: BT.709 matrix"))
}
