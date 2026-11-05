@preconcurrency import AVFoundation
import Foundation
import VoxClipCore

/// Keeps the rendered effects track on disk while a preview or export reads it, and removes it afterwards.
public final class EffectAudioLease: Sendable {
    public let url: URL
    public let frames: Int
    init(url: URL, frames: Int) { self.url = url; self.frames = frames }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

/// The audio half of a render's effects (ai.md §18.5) and its freeze frames. Bleeps and mutes silence the voice over
/// their words' exact output bounds, ramping over `ClipEffect.bleepRampSeconds` outside them; a bleep's 1 kHz tone is the
/// complement of that ramp, so the voice and the tone cross-fade without a click. Sound effects play at their start with
/// their own gain. Tones and sounds go to one 48 kHz stereo float track beside the voice, as the music bed does, so preview
/// and export mix the same audio.
enum EffectAudio {
    static let rate = 48_000.0

    /// The output ranges (seconds) a bleep or mute silences in `request`, in order.
    static func silencedRanges(_ request: RenderRequest) -> [ClosedRange<Double>] {
        guard let input = request.effects else { return [] }
        let timeline = request.timeline
        return input.audio.filter(\.kind.usesWords).compactMap { effect in
            let start = timeline.mapTime(effect.start), end = timeline.mapTime(effect.end)
            return end > start ? start...end : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// The voice's gain at output second `time` under `ranges`: 0 inside, a linear ramp over `bleepRampSeconds` outside.
    static func voiceGain(at time: Double, ranges: [ClosedRange<Double>]) -> Double {
        let ramp = ClipEffect.bleepRampSeconds
        var gain = 1.0
        for range in ranges {
            if range.contains(time) { return 0 }
            if time < range.lowerBound, range.lowerBound - time < ramp { gain = min(gain, (range.lowerBound - time) / ramp) }
            if time > range.upperBound, time - range.upperBound < ramp { gain = min(gain, (time - range.upperBound) / ramp) }
        }
        return gain
    }

    /// Replaces the picture over each freeze's output range with its first frame held, leaving the voice untouched.
    static func freeze(_ request: RenderRequest, video: AVMutableCompositionTrack, sourceVideo: AVAssetTrack, videoRange: CMTimeRange,
                       nominalRate: Float, duration: CMTime) throws {
        guard let freezes = request.effects?.freezes, !freezes.isEmpty else { return }
        let frame = CMTime(seconds: 1 / max(1, Double(nominalRate)), preferredTimescale: 600_000)
        let timeline = request.timeline
        for effect in freezes.sorted(by: { $0.start < $1.start }) {
            let start = CMTime(seconds: timeline.mapTime(effect.start), preferredTimescale: 600_000)
            let end = min(duration, CMTime(seconds: timeline.mapTime(effect.end), preferredTimescale: 600_000))
            guard end - start > frame else { continue }
            let held = CMTime(seconds: effect.start, preferredTimescale: 600_000)
            let source = CMTimeRange(start: max(videoRange.start, min(held, videoRange.end - frame)), duration: frame)
            let range = CMTimeRange(start: start, end: end)
            video.removeTimeRange(range)
            try video.insertTimeRange(source, of: sourceVideo, at: start)
            video.scaleTimeRange(CMTimeRange(start: start, duration: frame), toDuration: range.duration)
        }
    }

    /// The effects track for `request`, or nil when it has no bleep tone or sound inside the output.
    static func stage(_ request: RenderRequest, durationSeconds: Double, scratchRoot: URL,
                      isolation: isolated (any Actor)? = #isolation) async throws -> EffectAudioLease? {
        guard let input = request.effects, durationSeconds > 0 else { return nil }
        let timeline = request.timeline
        let outputFrames = Int((durationSeconds * rate).rounded())
        let tones = input.audio.filter { $0.kind == .bleep }.compactMap { effect -> ClosedRange<Double>? in
            let start = timeline.mapTime(effect.start), end = timeline.mapTime(effect.end)
            return end > start ? start...end : nil
        }
        var sounds: [(start: Int, samples: [Float], gain: Float)] = []
        for effect in input.audio where effect.kind == .sound {
            guard let url = input.soundURLs[effect.id] else { throw VoxClipError.sharedResourcesMissing }
            let start = Int((timeline.mapTime(effect.start) * rate).rounded())
            guard start < outputFrames else { continue }
            let samples = try await MusicBedRenderer.decodeStereo(url, upToSeconds: effect.sound?.durationSeconds ?? ClipEffect.maximumSoundSeconds)
            sounds.append((start, samples, Float(pow(10, (effect.gainDb ?? 0) / 20))))
        }
        guard !tones.isEmpty || !sounds.isEmpty else { return nil }
        try Task.checkCancellation()
        let directory = scratchRoot.appendingPathComponent("voxclip-effects-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("effects.caf")
        let lease = EffectAudioLease(url: url, frames: outputFrames)
        let file = try MusicCAFWriter(url: url, channels: 2)
        let ramp = ClipEffect.bleepRampSeconds
        let block = Int(rate)
        var start = 0
        while start < outputFrames {
            try Task.checkCancellation()
            let count = min(block, outputFrames - start)
            var samples = [Float](repeating: 0, count: count * 2)
            let blockStart = Double(start) / rate, blockEnd = Double(start + count) / rate
            for tone in tones where tone.lowerBound - ramp < blockEnd && tone.upperBound + ramp > blockStart {
                let first = max(start, Int(((tone.lowerBound - ramp) * rate).rounded(.down)))
                let last = min(start + count, Int(((tone.upperBound + ramp) * rate).rounded(.up)) + 1)
                guard first < last else { continue }
                for frame in first..<last {
                    let seconds = Double(frame) / rate
                    let level = 1 - voiceGain(at: seconds, ranges: [tone])
                    let value = Float(ClipEffect.bleepToneAmplitude * level * sin(2 * .pi * ClipEffect.bleepToneHz * seconds))
                    samples[2 * (frame - start)] += value
                    samples[2 * (frame - start) + 1] += value
                }
            }
            for sound in sounds where sound.start < start + count && sound.start + sound.samples.count / 2 > start {
                let from = max(start, sound.start), to = min(start + count, sound.start + sound.samples.count / 2)
                for frame in from..<to {
                    let index = 2 * (frame - sound.start)
                    samples[2 * (frame - start)] += sound.samples[index] * sound.gain
                    samples[2 * (frame - start) + 1] += sound.samples[index + 1] * sound.gain
                }
            }
            try file.append(samples)
            start += count
        }
        file.close()
        return lease
    }
}
