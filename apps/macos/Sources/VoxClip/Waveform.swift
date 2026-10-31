import AVFoundation
import VoxClipCore

struct WaveformData: Sendable {
    let fine: [Float]
    let buckets: [Float]
    var byteCount: Int {
        let count: Int = fine.count + buckets.count
        return count * MemoryLayout<Float>.size
    }
    init(fine: [Float]) {
        self.fine = fine
        buckets = stride(from: 0, to: fine.count, by: 5).map { (start: Int) -> Float in
            let limit: Int = start + 5
            let end: Int = min(limit, fine.count)
            let sum: Double = fine[start..<end].reduce(0.0) { (partial: Double, sample: Float) -> Double in
                let amplitude: Double = Double(sample)
                let squared: Double = amplitude * amplitude
                return partial + squared
            }
            let count: Double = Double(end - start)
            let mean: Double = sum / count
            return Float(mean.squareRoot())
        }
    }
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
