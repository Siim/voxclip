import Darwin
import Foundation
import VoxClipCore

/// Puts the cover into an MP4 on disk (ADR-R48, doc/publishing.md §7) with `MP4CoverArt`, on every macOS. It streams:
/// only the top-level headers and `moov` are read into memory, the new `moov` is written, and the rest of the file is
/// copied in chunks into a staged file beside it, which then replaces the file in one rename. A refusal or a failure
/// leaves the file as it was and removes the staged copy.
enum MP4CoverEmbed {
    /// The largest `moov` read into memory: a 60 s 1080p export's is about 38 KB (2026-11-08), so even hours stay small.
    static let movieLimit: UInt64 = 256 << 20
    /// Bytes copied at a time.
    static let chunk = 4 << 20

    enum Failure: Error, Equatable {
        case movieTooLarge(UInt64)
        case shortRead
    }

    /// The copy is synchronous file I/O over the whole movie, so it runs on this queue rather than holding a thread of
    /// the cooperative pool (the pattern of `FrameAnalyzer.look`).
    static let queue = DispatchQueue(label: "voxclip.export.cover", qos: .userInitiated)

    /// `embedNow` off the cooperative pool.
    static func embed(_ image: Data, into file: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { continuation.resume(with: Result { try embedNow(image, into: file) }) }
        }
    }

    /// Writes `<file>.cover` beside `file`, then renames it over `file`.
    static func embedNow(_ image: Data, into file: URL) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        let layout = try MP4CoverArt.layout(length: length) { offset, count in
            try input.seek(toOffset: offset)
            return try input.read(upToCount: count) ?? Data()
        }
        let movie = try MP4CoverArt.movie(in: layout)
        guard movie.size <= movieLimit else { throw Failure.movieTooLarge(movie.size) }
        try input.seek(toOffset: movie.offset)
        let moov = try read(input, count: Int(movie.size))
        let edit = try MP4CoverArt.edit(layout: layout, moov: moov, image: image)

        let staged = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".cover")
        let descriptor = Darwin.open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var published = false
        defer { if !published { unlink(staged.path) } }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        try copy(input, from: 0, to: movie.offset, into: output)
        try output.write(contentsOf: edit.moov)
        try copy(input, from: movie.end, to: length, into: output)
        try output.synchronize()
        guard Darwin.rename(staged.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        published = true
    }

    static func read(_ input: FileHandle, count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let block = try input.read(upToCount: min(chunk, count - data.count)), !block.isEmpty else { throw Failure.shortRead }
            data.append(block)
        }
        return data
    }

    static func copy(_ input: FileHandle, from start: UInt64, to end: UInt64, into output: FileHandle) throws {
        guard start < end else { return }
        try input.seek(toOffset: start)
        var left = end - start
        while left > 0 {
            guard let block = try input.read(upToCount: Int(min(UInt64(chunk), left))), !block.isEmpty else { throw Failure.shortRead }
            try output.write(contentsOf: block)
            left -= UInt64(block.count)
        }
    }
}
