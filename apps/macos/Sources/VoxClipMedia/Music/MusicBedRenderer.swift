@preconcurrency import AVFoundation
import Foundation
import VoxClipCore

/// Keeps the rendered bed on disk while a preview or export reads it, and removes it afterwards.
public final class MusicBedLease: Sendable {
    public let url: URL
    public let frames: Int
    init(url: URL, frames: Int) { self.url = url; self.frames = frames }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

/// Interleaved 48 kHz float CAF, the format a composition can insert (as the Voice Lab mix uses).
final class MusicCAFWriter {
    let format: AVAudioFormat
    private let file: AVAudioFile

    init(url: URL, channels: Int) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MusicBedRenderer.rate,
                                         channels: AVAudioChannelCount(channels), interleaved: true) else {
            throw VoxClipError.exportFailed("Cannot describe the music format")
        }
        self.format = format
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
    }

    /// Appends interleaved samples (a whole number of frames).
    func append(_ samples: [Float]) throws {
        let channels = Int(format.channelCount)
        let frames = samples.count / channels
        guard frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.audioBufferList.pointee.mBuffers.mData else { throw VoxClipError.exportFailed("Cannot allocate music PCM") }
        samples.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: frames * channels * MemoryLayout<Float>.size) }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    /// Flushes the last partial packet and the header; nothing is readable in full before this.
    func close() { file.close() }
}

/// Renders the music bed that sits under the final voice (doc/spec/music.md §4). Every gain comes from `MusicMix`:
/// speech activity measured in the clip's final voice audio drives ~−12 dB ducking (150 ms attack, 400 ms release), the
/// bed sits `gainDb` (−20 by default) under the measured speech loudness, fades in and out, and is trimmed from its
/// start offset or looped with equal-power crossfades. The result is a 48 kHz stereo float CAF that the shared
/// composition adds as a second audio track, so preview and export play the same mix.
enum MusicBedRenderer {
    static let rate = 48_000.0

    static func stage(_ input: MusicRenderInput, composition: AVComposition, voiceTrack: AVCompositionTrack?,
                      durationSeconds: Double, scratchRoot: URL,
                      isolation: isolated (any Actor)? = #isolation) async throws -> MusicBedLease {
        try Task.checkCancellation()
        let outputFrames = Int((durationSeconds * rate).rounded())
        guard outputFrames > 0 else { throw VoxClipError.exportFailed("The clip is too short for music") }
        let speech = try await speechLevels(composition: composition, track: voiceTrack, durationSeconds: durationSeconds)
        let entry = input.entry
        let track = try await decodeStereo(input.assetURL, upToSeconds: entry.startOffsetSeconds + durationSeconds)
        guard let plan = MusicBedPlan(track: track, speech: speech, entry: entry, outputFrames: outputFrames, rate: rate) else {
            throw VoxClipError.decodeFailed("The music track is too short to use")
        }
        let directory = scratchRoot.appendingPathComponent("voxclip-music-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("bed.caf")
        let lease = MusicBedLease(url: url, frames: outputFrames)
        let file = try MusicCAFWriter(url: url, channels: 2)
        try write(track: track, plan: plan, to: file)
        file.close()
        return lease
    }

    /// Mixes the plan's pieces, gains, fades and ducking into `file` in one-second blocks.
    static func write(track: [Float], plan: MusicBedPlan, to file: MusicCAFWriter) throws {
        let block = Int(plan.rate)
        var start = 0
        while start < plan.outputFrames {
            try Task.checkCancellation()
            let count = min(block, plan.outputFrames - start)
            try file.append(plan.mix(track, from: start, count: count))
            start += count
        }
    }

    /// 10 ms speech levels of the final voice audio; empty without a voice track (a silent video takes the fallback level).
    static func speechLevels(composition: AVComposition, track: AVCompositionTrack?, durationSeconds: Double,
                             isolation: isolated (any Actor)? = #isolation) async throws -> [Double] {
        let frames = Int((durationSeconds / MusicMix.frameSeconds).rounded(.up))
        guard let track, let copy = composition.copy() as? AVComposition, let voice = copy.track(withTrackID: track.trackID) else {
            return Array(repeating: MusicMix.silenceFloorDb, count: frames)
        }
        let reader = try AVAssetReader(asset: copy)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: durationSeconds, preferredTimescale: 48_000))
        let output = AVAssetReaderAudioMixOutput(audioTracks: [voice], audioSettings: MediaSupport.pcm(rate: rate, channels: 1))
        output.alwaysCopiesSampleData = false
        let provider = reader.outputProvider(for: output)
        var levels = MusicMix.LevelAccumulator(frameSize: Int(rate * MusicMix.frameSeconds))
        guard reader.startReading() else { throw VoxClipError.decodeFailed("Cannot read the voice for the music mix") }
        while let ready = try await MediaReadQueue.next(provider) {
            try Task.checkCancellation()
            let samples = try floats(ready)
            levels.append(samples)
        }
        guard reader.status == .completed else { throw VoxClipError.decodeFailed(reader.error?.localizedDescription ?? "The voice did not finish reading") }
        return levels.finish()
    }

    /// Interleaved stereo floats at 48 kHz from the start of the file up to `seconds` (the whole file when shorter).
    static func decodeStereo(_ url: URL, upToSeconds seconds: Double,
                             isolation: isolated (any Actor)? = #isolation) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await MediaSupport.audioTrack(in: asset) else { throw VoxClipError.noAudioTrack }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds + 0.05, preferredTimescale: 48_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: rate, channels: 2))
        output.alwaysCopiesSampleData = false
        let provider = reader.outputProvider(for: output)
        var result: [Float] = []
        result.reserveCapacity(Int(min(seconds, ProjectMusic.maximumDuration) * rate) * 2)
        guard reader.startReading() else { throw VoxClipError.decodeFailed("Cannot read the music track") }
        while let ready = try await MediaReadQueue.next(provider) {
            try Task.checkCancellation()
            result.append(contentsOf: try floats(ready))
        }
        guard reader.status == .completed else { throw VoxClipError.decodeFailed(reader.error?.localizedDescription ?? "The music track did not finish reading") }
        return result
    }

    static func floats(_ ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) throws -> [Float] {
        try ready.withUnsafeSampleBuffer { sample -> [Float] in
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw VoxClipError.decodeFailed("Missing PCM data") }
            let bytes = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            guard status == noErr else { throw VoxClipError.decodeFailed("Cannot copy PCM") }
            return values
        }
    }

    /// The decoded length in seconds of a music file, for its asset record.
    static func durationSeconds(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await MediaSupport.audioTrack(in: asset) else { throw VoxClipError.noAudioTrack }
        let range = try await track.load(.timeRange)
        let seconds = range.end.seconds
        guard seconds.isFinite, seconds > 0 else { throw VoxClipError.decodeFailed("The music file has no length") }
        return seconds
    }
}

/// What a bed plays (doc/spec/music.md §4): the trim or loop, the measured music and speech levels, and the gain of each frame.
/// `MusicBedRenderer.stage` decodes the audio and writes the bed; this decides, at any sample rate, so the shared music-mix
/// vectors (shared/fixtures/music/music-mix-cases.json, Windows MusicBed.Create and Mix) replay the renderer itself.
struct MusicBedPlan: Sendable {
    let pieces: [MusicMix.LoopPiece]
    let musicDb: Double?
    let speechDb: Double?
    let bedGainDb: Double
    let ducking: [Double]
    let outputFrames: Int
    let rate: Double
    let fadeInSeconds: Double
    let fadeOutSeconds: Double

    /// The plan for interleaved stereo `track` under a voice of 10 ms `speech` levels; nil when the track is too short to use.
    init?(track: [Float], speech: [Double], entry: ProjectMusic, outputFrames: Int, rate: Double) {
        let trackFrames = track.count / 2
        let offsetFrames = Int((entry.startOffsetSeconds * rate).rounded())
        let pieces = MusicMix.loopPieces(trackFrames: trackFrames, offsetFrames: min(offsetFrames, max(0, trackFrames - 1)),
                                         outputFrames: outputFrames, crossfadeFrames: Int(MusicMix.loopCrossfadeSeconds * rate))
        guard !pieces.isEmpty else { return nil }
        // Per-frame power averaged over both channels, so a wide stereo track is not read 3 dB quieter than it plays.
        let first = pieces[0].sourceStart
        var power = [Float](repeating: 0, count: max(0, trackFrames - first))
        for index in power.indices {
            let left = track[2 * (index + first)], right = track[2 * (index + first) + 1]
            power[index] = ((left * left + right * right) / 2).squareRoot()
        }
        let musicDb = MusicMix.musicLevelDb(levels: MusicMix.frameLevels(power, sampleRate: rate))
        let activity = MusicMix.speechActivity(levels: speech)
        let speechDb = MusicMix.speechLevelDb(levels: speech, activity: activity)
        self.pieces = pieces
        self.musicDb = musicDb
        self.speechDb = speechDb
        bedGainDb = MusicMix.bedGainDb(speechDb: speechDb, musicDb: musicDb, gainDb: entry.gainDb)
        ducking = MusicMix.duckingGainsDb(activity: activity, ducking: entry.ducking)
        self.outputFrames = outputFrames
        self.rate = rate
        fadeInSeconds = entry.fadeInSeconds
        fadeOutSeconds = entry.fadeOutSeconds
    }

    /// The bed's gain at output `frame`: the static bed gain, the fades and the ducking.
    func gain(atFrame frame: Int) -> Double {
        let seconds = Double(frame) / rate
        let fade = MusicMix.fadeFactor(at: seconds, duration: Double(outputFrames) / rate, fadeIn: fadeInSeconds, fadeOut: fadeOutSeconds)
        return pow(10, bedGainDb / 20) * fade * MusicMix.duckFactor(ducking, at: seconds)
    }

    /// Interleaved stereo bed frames `start..<start + count`: the pieces' weighted samples of `track` times each frame's gain.
    func mix(_ track: [Float], from start: Int, count: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: count * 2)
        for piece in pieces where piece.outputStart < start + count && piece.outputStart + piece.count > start {
            let from = max(start, piece.outputStart), to = min(start + count, piece.outputStart + piece.count)
            for frame in from..<to {
                let index = frame - piece.outputStart
                let weight = Float(MusicMix.pieceWeight(piece, at: index))
                let source = 2 * (piece.sourceStart + index)
                samples[2 * (frame - start)] += track[source] * weight
                samples[2 * (frame - start) + 1] += track[source + 1] * weight
            }
        }
        for frame in 0..<count {
            let factor = Float(self.gain(atFrame: start + frame))
            samples[2 * frame] *= factor
            samples[2 * frame + 1] *= factor
        }
        return samples
    }
}
