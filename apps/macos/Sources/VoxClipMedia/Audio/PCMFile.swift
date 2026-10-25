import Foundation
import VoxClipCore

final class PCMFile {
    let handle: FileHandle
    let rate: Int
    let channels: Int
    let bits: Int
    let float: Bool
    private(set) var frames: Int64 = 0

    init(url: URL, rate: Int, channels: Int, float: Bool) throws {
        self.rate = rate; self.channels = channels; self.float = float; bits = float ? 32 : 16
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw VoxClipError.exportFailed("Cannot create audio file") }
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(repeating: 0, count: 44))
    }

    func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
        frames += Int64(data.count / (channels * bits / 8))
    }

    func finish(expectedFrames: Int64? = nil) throws {
        if let expectedFrames {
            if frames > expectedFrames { try handle.truncate(atOffset: UInt64(44 + expectedFrames * Int64(channels * bits / 8))) }
            while frames < expectedFrames {
                let count = min(8192, expectedFrames - frames)
                try append(Data(repeating: 0, count: Int(count) * channels * bits / 8))
            }
            frames = expectedFrames
        }
        let bytes = frames * Int64(channels * bits / 8)
        guard bytes <= Int64(UInt32.max) - 36 else { throw VoxClipError.exportFailed("WAV exceeds the RIFF size limit") }
        var header = Data()
        func text(_ value: String) { header.append(contentsOf: value.utf8) }
        func word(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { header.append(contentsOf: $0) } }
        func long(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { header.append(contentsOf: $0) } }
        text("RIFF"); long(UInt32(bytes + 36)); text("WAVEfmt "); long(16)
        word(float ? 3 : 1); word(UInt16(channels)); long(UInt32(rate))
        long(UInt32(rate * channels * bits / 8)); word(UInt16(channels * bits / 8)); word(UInt16(bits))
        text("data"); long(UInt32(bytes))
        try handle.seek(toOffset: 0); try handle.write(contentsOf: header); try handle.close()
    }
}
