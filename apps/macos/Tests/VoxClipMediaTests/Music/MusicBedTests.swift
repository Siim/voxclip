import AVFoundation
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// The bed under the voice, measured on decoded audio. All audio is synthetic: tones and seeded noise, never music.
@Suite(.serialized, .offlineFixtures) struct MusicBedTests {
    static let rate = 48_000

    private static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-music-bed-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes interleaved float samples as a CAF.
    static func caf(_ samples: [Float], channels: Int, to url: URL) throws {
        let writer = try MusicCAFWriter(url: url, channels: channels)
        try writer.append(samples)
        writer.close()
    }

    /// Deterministic white noise, uncorrelated with itself at any loop point.
    static func noise(frames: Int, amplitude: Float, seed: UInt64 = 7) -> [Float] {
        var state = seed
        return (0..<(frames * 2)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return amplitude * (Float(state >> 40) / Float(1 << 24) * 2 - 1)
        }
    }

    /// A mono "voice": tone bursts where `speech` says so, near-silence elsewhere.
    static func voice(seconds: Double, speech: [ClosedRange<Double>]) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { index in
            let time = Double(index) / Double(rate)
            return speech.contains { $0.contains(time) } ? Float(0.3 * sin(2 * Double.pi * 300 * time)) : 0
        }
    }

    static func readBed(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        var result: [Float] = []
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536))
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let pointer = try #require(buffer.audioBufferList.pointee.mBuffers.mData)
            let count = Int(buffer.frameLength) * Int(file.processingFormat.channelCount)
            result += UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: Float.self), count: count)
        }
        return result
    }

    /// RMS in dBFS of the left channel between two times.
    static func level(_ bed: [Float], _ from: Double, _ to: Double) -> Double {
        let start = Int(from * Double(rate)), end = Int(to * Double(rate))
        var sum = 0.0
        for frame in start..<end { sum += Double(bed[2 * frame]) * Double(bed[2 * frame]) }
        return 10 * log10(max(1e-30, sum / Double(end - start)))
    }

    private func entry(_ projectId: String, duration: Double, ducking: Bool = true, fadeIn: Double = 0.5, fadeOut: Double = 1.5,
                       offset: Double = 0, gain: Double = -20) -> ProjectMusic {
        ProjectMusic(id: "music-a", clipId: nil, asset: MusicAsset(file: projectId + "/music-test.wav", sha256: String(repeating: "a", count: 64),
                                                                  durationSeconds: duration),
                     source: .file, title: "test", license: .own, gainDb: gain, ducking: ducking, fadeInSeconds: fadeIn,
                     fadeOutSeconds: fadeOut, startOffsetSeconds: offset)
    }

    private func stage(voice: [Float], music: [Float], entry: ProjectMusic, seconds: Double, in directory: URL) async throws -> (MusicBedLease, [Float]) {
        let voiceURL = directory.appendingPathComponent("voice.caf")
        let musicURL = directory.appendingPathComponent("music.caf")
        try Self.caf(voice, channels: 1, to: voiceURL)
        try Self.caf(music, channels: 2, to: musicURL)
        let composition = AVMutableComposition()
        let voiceAsset = AVURLAsset(url: voiceURL)
        let source = try #require(try await MediaSupport.audioTrack(in: voiceAsset))
        let track = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try withExtendedLifetime(voiceAsset) {
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 48_000)), of: source, at: .zero)
        }
        let lease = try await MusicBedRenderer.stage(MusicRenderInput(entry: entry, assetURL: musicURL), composition: composition,
                                                     voiceTrack: track, durationSeconds: seconds, scratchRoot: directory)
        return (lease, try Self.readBed(lease.url))
    }

    @Test func bedSitsTwentyDecibelsUnderSpeechDucksTwelveAndFades() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let voice = Self.voice(seconds: 5, speech: [1.5...2.5])
        let music = Self.noise(frames: 6 * Self.rate, amplitude: 0.5)
        let (lease, bed) = try await stage(voice: voice, music: music, entry: entry("p", duration: 6), seconds: 5, in: directory)
        #expect(bed.count == 2 * 5 * Self.rate && lease.frames == 5 * Self.rate, "\(bed.count) \(lease.frames)")
        try #require(bed.count == 2 * 5 * Self.rate)
        let speechDb = 20 * log10(0.3 / sqrt(2.0))
        let open = Self.level(bed, 0.7, 1.2)
        // About 20 dB under the speech's loudness between words.
        #expect(abs(open - (speechDb - 20)) < 0.6, "\(open)")
        // About 12 dB lower while the voice talks.
        let ducked = Self.level(bed, 1.6, 2.4)
        #expect(abs(ducked - open + 12) < 0.6, "\(ducked) vs \(open)")
        // The attack has finished at the onset; the release is over 400 ms after speech ends.
        #expect(Self.level(bed, 1.25, 1.33) > open - 3 && Self.level(bed, 1.51, 1.55) < open - 10)
        #expect(abs(Self.level(bed, 2.95, 3.4) - open) < 0.6)
        // Fade-in from silence over 0.5 s, fade-out to silence over 1.5 s.
        #expect(Self.level(bed, 0, 0.01) < open - 30 && Self.level(bed, 0.2, 0.3) < open - 3)
        #expect(Self.level(bed, 4.99, 5) < open - 30 && Self.level(bed, 4.2, 4.3) < open - 3)
    }

    @Test func duckingOffKeepsOneLevelAndShortTracksLoopWithoutDips() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let voice = Self.voice(seconds: 4, speech: [0.5...3.5])
        let music = Self.noise(frames: Int(1.5 * Double(Self.rate)), amplitude: 0.4)
        let (_, bed) = try await stage(voice: voice, music: music,
                                       entry: entry("p", duration: 1.5, ducking: false, fadeIn: 0, fadeOut: 0, offset: 0.5), seconds: 4, in: directory)
        try #require(bed.count == 2 * 4 * Self.rate, "\(bed.count)")
        let levels = stride(from: 0.0, to: 3.9, by: 0.1).map { Self.level(bed, $0, $0 + 0.1) }
        let mean = levels.reduce(0, +) / Double(levels.count)
        #expect(levels.allSatisfy { abs($0 - mean) < 1.5 }, "\(levels)")
        #expect(abs(mean - (20 * log10(0.3 / sqrt(2.0)) - 20)) < 1)
    }

    @Test func noMusicLeavesTheGraphVoiceOnly() async throws {
        let source = try await NativeMediaFixtures.shared.file("bars-tone.mov")
        let plan = EditPlan(sampleRate: 48000, totalSamples: 96000, kept: [MediaInterval(startSample: 0, endSample: 96000)])
        let request = RenderRequest(sourceURL: source, plan: plan, output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 1_000_000))
        let graph = try await CompositionBuilder().build(request)
        #expect(graph.musicTrack == nil && graph.musicLease == nil)
        #expect(graph.mixedAudioTracks.map(\.trackID) == [try #require(graph.audioTrack).trackID])
        #expect(graph.composition.tracks(withMediaType: .audio).count == 1)
        #expect(request.withoutMusic == request)
    }

    /// The smoke: a library track found through Openverse (fixture reply), downloaded (synthetic noise), stored, mixed
    /// into an export, with its credit in the post text and the edited-audio check still voice-only.
    @Test(.timeLimit(.minutes(2))) func libraryTrackExportsUnderTheVoiceWithItsCredit() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let download = directory.appendingPathComponent("download.wav")
        try Self.pcmWAV(Self.noise(frames: 3 * Self.rate, amplitude: 0.5), to: download)
        let http = StubMusicHTTP([.init(status: 200, body: OpenverseFixture.mixed),
                                  .init(status: 200, headers: ["Content-Type": "audio/wav"], body: try Data(contentsOf: download))])
        let library = OpenverseMusicClient(http: http)
        let service = MusicSuggestionService(library: library, eleven: nil, hasElevenKey: { false }, folder: { nil })
        var candidate = try #require(await service.candidates(for: MusicBrief(mood: "calm piano"), clipSeconds: 2).candidates.first)
        #expect(candidate.id == "openverse-piano")
        candidate.fileExtension = "wav"
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/music/music-project.voxclip"))
        project.music = []
        let dataRoot = directory.appendingPathComponent("data", isDirectory: true)
        let entry = try await MusicAssetStore.importing(try await library.download(candidate), candidate: candidate, projectId: project.id,
                                                        clipId: nil, dataRoot: dataRoot)
        project = try MusicProject.setting(entry, clipId: nil, in: project)
        #expect(try ProjectJSON.decode(ProjectJSON.encode(project)).music == [entry])

        let source = try await NativeMediaFixtures.shared.file("bars-tone.mov")
        let plan = EditPlan(sampleRate: 48000, totalSamples: 96000, kept: [MediaInterval(startSample: 0, endSample: 96000)])
        var render = RenderRequest(sourceURL: source, plan: plan, output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 1_000_000))
        let plain = directory.appendingPathComponent("plain.mp4")
        _ = try await AVExporter().export(ExportJob(render: render, outputURL: plain)) { _ in }
        render.music = MusicRenderInput.resolve(project: project, clipId: nil, dataRoot: dataRoot)
        #expect(render.music?.assetURL.path.hasPrefix(dataRoot.appendingPathComponent("Music").path) == true)
        let mixed = directory.appendingPathComponent("mixed.mp4")
        let result = try await AVExporter().export(ExportJob(render: render, outputURL: mixed)) { _ in }
        #expect(result.audioSamples == 96000)
        let plainAudio = try await Self.decodedAudio(plain), mixedAudio = try await Self.decodedAudio(mixed)
        #expect(plainAudio.count == mixedAudio.count && !plainAudio.isEmpty)
        let difference = zip(plainAudio, mixedAudio).map { Double($0 - $1) * Double($0 - $1) }.reduce(0, +) / Double(plainAudio.count)
        #expect(10 * log10(difference) > -60, "music is audible in the export")
        #expect(MusicCredits.postText("Today we shipped the clipper.", music: project.music.first)
                == "Today we shipped the clipper.\n\nMusic: \"Quiet piano\" by Artist piano is licensed under CC BY 3.0.")
        // The edited-audio path (word and speaker checks) reads the voice alone.
        let voiceOnly = directory.appendingPathComponent("voice.wav"), withMusic = directory.appendingPathComponent("voice-music.wav")
        var unmixed = render; unmixed.music = nil
        try await AVExporter().writeEditedAudio(unmixed, to: voiceOnly)
        try await AVExporter().writeEditedAudio(render, to: withMusic)
        #expect(try Data(contentsOf: voiceOnly) == Data(contentsOf: withMusic))
    }

    /// A 16-bit PCM WAV, as a download or a user's file would be.
    static func pcmWAV(_ samples: [Float], to url: URL) throws {
        let file = try PCMFile(url: url, rate: rate, channels: 2, float: false)
        let ints = samples.map { Int16(max(-1, min(1, $0)) * 32_767).littleEndian }
        try file.append(ints.withUnsafeBufferPointer { Data(buffer: $0) })
        try file.finish()
    }

    static func decodedAudio(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: MediaSupport.pcm(rate: 48_000, channels: 2))
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }
}
