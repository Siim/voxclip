@preconcurrency import AVFoundation
import Foundation
import VoxClipCore

enum RecordingVoice {
    static func stage(_ spans: [CompositionVideoSpan], sources: [String: CompositionRecording], scratchRoot: URL,
                      isolation: isolated (any Actor)? = #isolation) async throws -> ClipVoiceLease {
        let grid: CMTimeScale = 48_000
        func samples(_ time: CMTime) -> Int64 { CMTimeConvertScale(time, timescale: grid, method: .roundHalfAwayFromZero).value }
        guard let end = spans.last?.output.end, end.isNumeric, samples(end) > 0 else { throw VoxClipError.everythingCut }
        let frames = samples(end)
        let bytes = try DiskCapacity.checkedMultiply(frames, 8, at: scratchRoot)
        try DiskCapacity.check([.init(directory: scratchRoot, bytes: bytes)])
        let directory = scratchRoot.appendingPathComponent("voxclip-recording-voice-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("voice.caf")
        let lease = ClipVoiceLease(url: url, frames: Int(frames))
        let writer = try MusicCAFWriter(url: url, channels: 2)
        defer { writer.close() }
        for span in spans {
            try Task.checkCancellation()
            let count = samples(span.output.end) - samples(span.output.start)
            guard let key = span.recordingKey, let recording = sources[key] else { throw VoxClipError.exportFailed("Invalid recording span") }
            var position: Int64 = 0
            if let track = recording.audio {
                let reader = try AVAssetReader(asset: recording.asset)
                reader.timeRange = span.localSource
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: Double(grid), channels: 2))
                output.alwaysCopiesSampleData = false
                let provider = reader.outputProvider(for: output)
                guard reader.startReading() else { throw reader.error ?? VoxClipError.decodeFailed("Cannot decode recording audio") }
                defer { if reader.status == .reading { reader.cancelReading() } }
                let start = samples(span.localSource.start)
                while position < count, let buffer = try await MediaReadQueue.next(provider) {
                    try Task.checkCancellation()
                    let pcm = try MusicBedRenderer.floats(buffer)
                    let bufferStart = samples(buffer.presentationTimeStamp) - start
                    let bufferEnd = bufferStart + Int64(pcm.count / 2)
                    if bufferEnd <= position { continue }
                    let from = max(position, min(count, bufferStart))
                    try ExportLoudnessPass.pad(from: position, to: from) { try writer.append(Array($0)) }
                    let to = min(count, bufferEnd)
                    if from < to {
                        let slice = Int(from - bufferStart) * 2..<Int(to - bufferStart) * 2
                        try writer.append(Array(pcm[slice]))
                    }
                    position = max(from, to)
                }
                if reader.status == .failed { throw reader.error ?? VoxClipError.decodeFailed("Recording audio did not finish decoding") }
            }
            try ExportLoudnessPass.pad(from: position, to: count) { try writer.append(Array($0)) }
        }
        return lease
    }
}
