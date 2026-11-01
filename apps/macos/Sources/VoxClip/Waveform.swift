import AVFoundation
import VoxClipCore

/// One level of the waveform pyramid (impl-plan §3.1): per frame, the loudest 10 ms RMS
/// value in it (`max`) and the RMS over it (`rms`).
struct WaveformLevel: Sendable {
    /// Seconds per frame: 0.01, 0.04, 0.16 or 0.64.
    let frameSeconds: Double
    let max: [Float]
    let rms: [Float]
}

/// A take's audio for the timeline: today's 10 ms RMS envelope (`fine`, the cache's
/// `envelope-10ms.f32`) and a pyramid built from it once, off the main thread, where the
/// cache loads it. The A1 lane reads a pixel column from the coarsest level whose frames
/// fit in it, so a column costs a few frames at any zoom.
struct WaveformData: Sendable {
    /// Frames per level beyond the first: 10, 40, 160 and 640 ms.
    static let factor = 4
    static let frameSeconds = 0.01
    /// The column a typical spoken peak reaches, as a fraction of the half-height
    /// (notes.md §6: typical peaks at 55–70%).
    static let typicalPeak: Float = 0.62
    /// Frames quieter than this (−60 dBFS) never count as voice.
    static let voicedFloor: Float = 0.001

    let fine: [Float]
    let levels: [WaveformLevel]
    /// Per level, the median of the voiced frames' loudest values: what a typical spoken
    /// column of that length reaches. Zero when nothing is voiced.
    let references: [Float]
    /// Columns whose loudest frame is under this draw nothing: 30 dB under the typical
    /// 10 ms frame, and never under −60 dBFS (notes.md §6: nothing drawn in silence).
    let silence: Float
    /// Identifies this load, so a lane redraws when the waveform changes without comparing it.
    let identity = UUID()

    var byteCount: Int {
        // The first level shares `fine`'s storage.
        let count: Int = fine.count + levels.dropFirst().reduce(0) { $0 + $1.max.count + $1.rms.count }
        return count * MemoryLayout<Float>.size
    }

    init(fine: [Float]) {
        self.fine = fine
        var levels = [WaveformLevel(frameSeconds: Self.frameSeconds, max: fine, rms: fine)]
        // Each level folds four frames of the one before: the loudest of their maxima, and
        // the RMS of their RMS weighted by the 10 ms frames each covers.
        var counts = [Float](repeating: 1, count: fine.count)
        for _ in 1...3 {
            let previous = levels[levels.count - 1]
            let size = (previous.max.count + Self.factor - 1) / Self.factor
            var maxima = [Float](repeating: 0, count: size), rms = [Float](repeating: 0, count: size), covered = [Float](repeating: 0, count: size)
            previous.max.withUnsafeBufferPointer { peaks in
                previous.rms.withUnsafeBufferPointer { values in
                    counts.withUnsafeBufferPointer { weights in
                        for frame in 0..<size {
                            let lower = frame * Self.factor, upper = Swift.min(peaks.count, lower + Self.factor)
                            var peak: Float = 0, energy: Float = 0, weight: Float = 0
                            for index in lower..<upper {
                                peak = Swift.max(peak, peaks[index])
                                energy += values[index] * values[index] * weights[index]
                                weight += weights[index]
                            }
                            maxima[frame] = peak
                            rms[frame] = weight > 0 ? (energy / weight).squareRoot() : 0
                            covered[frame] = weight
                        }
                    }
                }
            }
            counts = covered
            levels.append(WaveformLevel(frameSeconds: previous.frameSeconds * Double(Self.factor), max: maxima, rms: rms))
        }
        self.levels = levels
        references = levels.map { Self.voicedMedian($0.max) }
        silence = Swift.max(Self.voicedFloor, references[0] * 0.0316)
    }

    /// The median of the values at or over `voicedFloor`, to 0.1 dB, from a histogram:
    /// one pass, no copy of an hour of frames.
    static func voicedMedian(_ values: [Float]) -> Float {
        let bins = 600, floor = Double(voicedFloor)
        var histogram = [Int](repeating: 0, count: bins)
        var voiced = 0
        for value in values where value >= voicedFloor {
            let decibels = 20 * log10(Double(Swift.min(value, 1)) / floor)
            histogram[Swift.min(bins - 1, Int(decibels * 10))] += 1
            voiced += 1
        }
        guard voiced > 0 else { return 0 }
        var seen = 0
        for (bin, count) in histogram.enumerated() {
            seen += count
            if seen * 2 > voiced { return Float(floor * pow(10, (Double(bin) + 0.5) / 200)) }
        }
        return 1
    }

    /// The pixel column for `start..<end` seconds of the take, as fractions of the half-height:
    /// the peak (the loudest frame's RMS times √2) and the core (the RMS over the frames), from
    /// the coarsest level whose frames fit in the column. A column takes the frames whose
    /// middles fall in it, or the one under its middle. Its scale puts a typical spoken
    /// column of its length at `typicalPeak` at every zoom. Both are zero in silence.
    func column(from start: Double, to end: Double) -> (peak: Float, core: Float) {
        guard let first = levels.first, !first.max.isEmpty, start.isFinite, end.isFinite, end > start else { return (0, 0) }
        let span = end - start
        let index = levels.lastIndex { $0.frameSeconds <= span + 1e-9 } ?? 0
        let level = levels[index], seconds = level.frameSeconds
        var lower = Int((start / seconds - 0.5).rounded(.up)), upper = Int((end / seconds - 0.5).rounded(.up))
        if lower >= upper {
            lower = Int(((start + end) / 2 / seconds).rounded(.down))
            upper = lower + 1
        }
        lower = Swift.max(0, lower)
        upper = Swift.min(level.max.count, upper)
        guard lower < upper else { return (0, 0) }
        var peak: Float = 0, energy: Float = 0
        for frame in lower..<upper {
            peak = Swift.max(peak, level.max[frame])
            energy += level.rms[frame] * level.rms[frame]
        }
        let reference = reference(span: span, level: index)
        guard peak >= silence, reference > 0 else { return (0, 0) }
        let core = (energy / Float(upper - lower)).squareRoot()
        let gain = Self.typicalPeak / (reference * Float(2).squareRoot())
        return (Swift.min(1, peak * Float(2).squareRoot() * gain), Swift.min(1, core * gain))
    }

    /// What a typical spoken column `span` seconds long reaches at `level`: between this
    /// level's typical frame and the next level's, by how many frames the column holds.
    private func reference(span: Double, level index: Int) -> Float {
        let here = references[index]
        guard index + 1 < references.count, here > 0, references[index + 1] > here else { return here }
        let frames = Swift.max(1, span / levels[index].frameSeconds)
        let position = Swift.min(1, log(frames) / log(Double(Self.factor)))
        return here * pow(references[index + 1] / here, Float(position))
    }
}

/// Two loads are equal only when they are the same load: comparing envelopes would cost a
/// pass over an hour of frames on every lane update.
extension WaveformData: Equatable {
    static func == (lhs: WaveformData, rhs: WaveformData) -> Bool { lhs.identity == rhs.identity }
}

actor WaveformCache {
    static let shared = WaveformCache()
    struct Key: Hashable, Sendable {
        let contentKey: String
        let source: URL
        let cache: URL
    }
    private var values: [Key: WaveformData] = [:]
    private var order: [Key] = []
    private var pending: [Key: Task<WaveformData?, Never>] = [:]
    func load(_ key: Key) async -> WaveformData? {
        if let value = values[key] {
            order.removeAll { $0 == key }; order.append(key)
            return value
        }
        if let task = pending[key] { return await task.value }
        let task = Task<WaveformData?, Never>.detached(priority: .utility) {
            // Eviction leaves the entry alone while its envelope is read (architecture §8.2).
            let lease = await CacheKeyRegistry.shared(cache: key.cache).lease(key.contentKey)
            let cached = Self.readEnvelope(key)
            lease.release()
            if let cached { return cached }
            return try? await Self.decode(key.source)
        }
        pending[key] = task
        let value = await task.value
        pending[key] = nil
        let byteLimit: Int = 24 << 20
        if let value, value.byteCount <= byteLimit {
            values[key] = value; order.append(key)
            while order.count > 1, values.values.reduce(0, { (total: Int, waveform: WaveformData) -> Int in total + waveform.byteCount }) > byteLimit {
                values[order.removeFirst()] = nil
            }
        }
        return value
    }
    nonisolated static func readEnvelope(_ key: Key) -> WaveformData? {
        guard key.contentKey.count == 64, key.contentKey.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        let directory = key.cache.appendingPathComponent(key.contentKey, isDirectory: true)
        let metadata = directory.appendingPathComponent("meta.json")
        let envelope = directory.appendingPathComponent("envelope-10ms.f32")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .utcTimestamp(allowingOffset: true)
        guard regular(directory, type: .typeDirectory), regular(metadata), regular(envelope),
              let size = try? metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1 << 20,
              let data = try? Data(contentsOf: metadata), let entry = try? decoder.decode(CacheEntry.self, from: data),
              entry.schema == "voxclip-cache/1", entry.contentKey == key.contentKey, let spec = entry.envelope,
              spec.frameSeconds == 0.01, spec.sampleRate.isFinite, spec.sampleRate > 0,
              spec.count > 0, spec.count <= 8_640_000,
              let bytes = try? envelope.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes == spec.count * 4,
              let stored = try? Data(contentsOf: envelope) else { return nil }
        let samples = stored.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map { offset in
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
        }
        guard samples.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return nil }
        return WaveformData(fine: samples)
    }
    nonisolated private static func regular(_ url: URL, type: FileAttributeType = .typeRegular) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == type
    }
    nonisolated private static func decode(_ source: URL) async throws -> WaveformData? {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 86_400 else { return nil }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var selected = tracks.first
        for track in tracks where try await track.load(.isEnabled) { selected = track; break }
        guard let track = selected, let format = try await track.load(.formatDescriptions).first,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        let rate = description.mSampleRate
        let channels = Int(description.mChannelsPerFrame)
        guard rate.isFinite, rate >= 100, rate <= 384_000, channels > 0, channels <= 32 else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        let provider = reader.outputProvider(for: output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        let framesPerBucket: Double = rate * 0.01
        let roundedFrames: Int = Int(framesPerBucket.rounded())
        let bucketSize: Int = max(1, roundedFrames) * channels
        var count = 0
        var sum = 0.0
        var levels: [Float] = []
        while let ready = try await provider.next() {
            try Task.checkCancellation()
            try ready.withUnsafeSampleBuffer { sample in
                let frames = CMSampleBufferGetNumSamples(sample)
                guard frames <= 1_048_576, let block = CMSampleBufferGetDataBuffer(sample) else { throw CocoaError(.fileReadCorruptFile) }
                var samples = [Float](repeating: 0, count: frames * channels)
                let status = samples.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
                }
                guard status == noErr else { throw CocoaError(.fileReadCorruptFile) }
                for sample in samples {
                    let converted: Double = Double(sample)
                    let amplitude: Double = sample.isFinite ? converted.clamped(to: -1...1) : 0
                    sum += amplitude * amplitude; count += 1
                    if count == bucketSize {
                        let divisor: Double = Double(count)
                        let mean: Double = sum / divisor
                        levels.append(Float(mean.squareRoot()))
                        sum = 0; count = 0
                    }
                }
            }
            guard levels.count <= 8_640_000 else { return nil }
        }
        guard reader.status == .completed else { return nil }
        if count > 0 {
            let divisor: Double = Double(count)
            let mean: Double = sum / divisor
            levels.append(Float(mean.squareRoot()))
        }
        return levels.isEmpty ? nil : WaveformData(fine: levels)
    }
}
