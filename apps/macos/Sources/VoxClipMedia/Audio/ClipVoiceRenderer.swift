@preconcurrency import AVFoundation
import Foundation
import VoxClipCore

/// Keeps the staged clip voice on disk while a preview or export reads it, and removes it afterwards.
public final class ClipVoiceLease: Sendable {
    public let url: URL
    public let frames: Int
    init(url: URL, frames: Int) { self.url = url; self.frames = frames }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

/// Stages a clip's voice with its controls (design.md §6.9), the one path preview and export share:
/// 1. the edited voice at 1× is read through the graph's own mix (the join fades, or the Voice Lab mix as staged);
/// 2. a speed other than 1 stretches it in a scaled composition read with `AVAudioTimePitchAlgorithm.spectral`, so the
///    voice keeps its pitch;
/// 3. volume, the fades and mute are applied in rendered time (`ClipAudioMix`).
/// The result is a 48 kHz stereo float CAF the composition inserts in place of the voice track, so a music bed measures the
/// voice exactly as it plays.
enum ClipVoiceRenderer {
    static let rate = 48_000.0

    static func stage(composition: AVComposition, voice: AVCompositionTrack, audioMix: AVAudioMix?, editedDuration: CMTime,
                      renderedDuration: CMTime, controls: ProjectClipControls, scratchRoot: URL,
                      isolation: isolated (any Actor)? = #isolation) async throws -> ClipVoiceLease {
        try Task.checkCancellation()
        let directory = scratchRoot.appendingPathComponent("voxclip-clip-voice-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("voice.caf")
        let frames = Int((renderedDuration.seconds * rate).rounded())
        let lease = ClipVoiceLease(url: url, frames: frames)
        guard frames > 0 else { throw VoxClipError.everythingCut }
        // 1. The edited voice at 1×, as the graph mixes it.
        let flat = directory.appendingPathComponent("voice-1x.caf")
        guard let copy = composition.copy() as? AVComposition, let track = copy.track(withTrackID: voice.trackID) else {
            throw VoxClipError.decodeFailed("Cannot copy the clip voice")
        }
        let flatWriter = try MusicCAFWriter(url: flat, channels: 2)
        try await read(copy, tracks: [track], mix: audioMix, range: CMTimeRange(start: .zero, duration: editedDuration),
                       pitch: nil) { try flatWriter.append($0) }
        flatWriter.close()
        // 2. The stretch, pitch kept; 3. level, fades and mute, padded or trimmed to the rendered length.
        let staged = AVURLAsset(url: flat)
        guard let flatTrack = try await MediaSupport.audioTrack(in: staged) else { throw VoxClipError.decodeFailed("Staged voice has no audio") }
        let flatRange = try await flatTrack.load(.timeRange)
        let stretch = AVMutableComposition()
        guard let stretched = stretch.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VoxClipError.decodeFailed("Cannot stage the clip speed")
        }
        try withExtendedLifetime(staged) {
            try stretched.insertTimeRange(CMTimeRange(start: .zero, duration: flatRange.duration), of: flatTrack, at: .zero)
        }
        if controls.speed != 1 {
            stretched.scaleTimeRange(CMTimeRange(start: .zero, duration: flatRange.duration),
                                     toDuration: CMTimeMultiplyByFloat64(flatRange.duration, multiplier: 1 / controls.speed))
        }
        let writer = try MusicCAFWriter(url: url, channels: 2)
        let duration = Double(frames) / rate
        var written = 0
        func write(_ samples: [Float]) throws {
            let count = min(samples.count / 2, frames - written)
            guard count > 0 else { return }
            var block = Array(samples[0..<(count * 2)])
            for frame in 0..<count {
                let seconds = Double(written + frame) / rate
                let gain = Float(ClipAudioMix.gain(at: seconds, duration: duration, controls: controls))
                block[2 * frame] *= gain
                block[2 * frame + 1] *= gain
            }
            try writer.append(block)
            written += count
        }
        try await read(stretch, tracks: [stretched], mix: nil, range: CMTimeRange(start: .zero, duration: stretched.timeRange.duration),
                       pitch: controls.speed == 1 ? nil : .spectral, handle: write)
        while written < frames { try write([Float](repeating: 0, count: min(48_000, frames - written) * 2)) }
        writer.close()
        try? FileManager.default.removeItem(at: flat)
        return lease
    }

    /// Streams interleaved stereo floats at 48 kHz from `tracks` through `mix`, stretching with `pitch` when given.
    private static func read(_ asset: AVAsset, tracks: [AVAssetTrack], mix: AVAudioMix?, range: CMTimeRange,
                             pitch: AVAudioTimePitchAlgorithm?, isolation: isolated (any Actor)? = #isolation,
                             handle: ([Float]) throws -> Void) async throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: MediaSupport.pcm(rate: rate, channels: 2))
        output.audioMix = mix
        if let pitch { output.audioTimePitchAlgorithm = pitch }
        output.alwaysCopiesSampleData = false
        let provider = reader.outputProvider(for: output)
        guard reader.startReading() else { throw reader.error ?? VoxClipError.decodeFailed("Cannot read the clip voice") }
        while let ready = try await MediaSupport.nextSample(provider) {
            try Task.checkCancellation()
            try handle(try MusicBedRenderer.floats(ready))
        }
        guard reader.status == .completed else {
            throw VoxClipError.decodeFailed(reader.error?.localizedDescription ?? "The clip voice did not finish reading")
        }
    }
}
