import Darwin
import Foundation

public struct LipsyncUploadFile: Sendable {
    package let data: Data
    public let sha256: String
    public let durationSeconds: Double
    public let contentType: String

    public init(file: URL, durationSeconds: Double, contentType: String) throws {
        let directory = try LipsyncLocalPath.openDirectory(file.deletingLastPathComponent())
        defer { Darwin.close(directory) }
        let descriptor = openat(directory, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw LipsyncError.unsafeFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              durationSeconds.isFinite, (3...300).contains(durationSeconds),
              ["video/mp4", "audio/wav"].contains(contentType), before.st_size > 0,
              before.st_size <= (contentType == "video/mp4" ? LipsyncLimits.maximumVideoBytes : 64 * 1_024 * 1_024) else {
            throw LipsyncError.invalidInput
        }
        let data = try handle.readToEnd() ?? Data()
        guard data.count == before.st_size, fstat(descriptor, &after) == 0,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw LipsyncError.unsafeFile }
        if contentType == "video/mp4" {
            guard data.count >= 12, Data(data[4..<8]) == Data("ftyp".utf8) else { throw LipsyncError.invalidMedia }
        } else {
            guard data.count >= 44 else { throw LipsyncError.invalidMedia }
            func integer(_ offset: Int, _ count: Int) -> Int {
                (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
            }
            guard Data(data[0..<4]) == Data("RIFF".utf8), Data(data[8..<16]) == Data("WAVEfmt ".utf8),
                  integer(16, 4) == 16, integer(20, 2) == 1, integer(22, 2) == 1,
                  integer(24, 4) == 48_000, integer(34, 2) == 16,
                  Data(data[36..<40]) == Data("data".utf8), integer(40, 4) == data.count - 44,
                  abs(Double(data.count - 44) / 96_000 - durationSeconds) <= 1 / 48_000 else { throw LipsyncError.invalidMedia }
        }
        self.data = data; self.sha256 = VoiceLabFingerprint.bytes(data)
        self.durationSeconds = durationSeconds; self.contentType = contentType
    }
}
