import AVFoundation
import Darwin
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite struct VoiceLabAssetTests {
    private func project() throws -> Project {
        try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-project.voxclip"))
    }

    // The Windows test uses the same 24 kHz, mono PCM16, 440 Hz construction.
    private func wave(frames: Int = 24_000, rate: Int = 24_000) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var number = value.littleEndian; withUnsafeBytes(of: &number) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var number = value.littleEndian; withUnsafeBytes(of: &number) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + frames * 2)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(frames * 2))
        for index in 0..<frames {
            let value = Int16((sin(2 * Double.pi * 440 * Double(index) / Double(rate)) * 10_000).rounded())
            u16(UInt16(bitPattern: value))
        }
        return data
    }

    private func setup(_ bytes: Data? = nil) throws -> (Project, URL, URL) {
        var project = try project()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-voice-test-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(project.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("asset-one.wav")
        if let bytes {
            try bytes.write(to: file)
            project.voiceLab.assets![0].sha256 = SpeechSHA256.hex(bytes)
        }
        return (project, root, file)
    }

    @Test func resolvesAndKeepsSnapshotAfterPaidFileChanges() throws {
        #expect(SpeechSHA256.hex(wave()) == "f1b99f5f6d48cdb22577ab3c7aede2aff313f64afbba6897b6352d7868e11981")
        let (project, root, paid) = try setup(wave())
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try VoiceLabOutputPlanner.build(project, scope: .full)
        let disabled = try VoiceLabProject.setEnabled(false, id: "vl-passage", in: project)
        #expect(try VoiceLabAssets.prepare(project: disabled,
                                           plan: VoiceLabOutputPlanner.build(disabled, scope: .full), paidRoot: root).isEmpty)
        let selected = try VoiceLabProject.selectCandidate(1, id: "vl-passage", in: project)
        #expect(throws: VoiceLabAssetError.invalidSelection("output plan")) {
            try VoiceLabAssets.prepare(project: selected, plan: plan, paidRoot: root)
        }
        let prepared = try VoiceLabAssets.prepare(project: project, plan: plan, paidRoot: root)
        let handle = try #require(prepared["vl-passage"])
        #expect(handle.assetId == "asset-one")
        #expect(handle.frameCount == 24_000 && handle.sampleRate == 24_000 && handle.channels == 1)
        #expect(handle.trimStartFrame == 0 && handle.trimEndFrame == 24_000)
        #expect(handle.stretch == 1 && handle.gainDb == 0)
        #expect(try Data(contentsOf: handle.url) == Data(contentsOf: paid))
        try Data("changed".utf8).write(to: paid)
        #expect(try Data(contentsOf: handle.url) == wave())
        #expect(FileManager.default.fileExists(atPath: paid.path))
    }

    @Test func changedCaptionCorrectionRejectsStalePlanButFreshPlanPrepares() throws {
        let (project, root, paid) = try setup(wave())
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = try VoiceLabOutputPlanner.build(project, scope: .full)
        var changed = project
        changed.edits.corrections["w1"] = "Well"
        let fresh = try VoiceLabOutputPlanner.build(changed, scope: .full)
        #expect(stale.pieces == fresh.pieces)
        #expect(stale.captions != fresh.captions)
        #expect(fresh.captions.contains { $0.id == "w1" && $0.text == "Well" })
        #expect(throws: VoiceLabAssetError.invalidSelection("output plan")) {
            try VoiceLabAssets.prepare(project: changed, plan: stale, paidRoot: root)
        }
        let prepared = try VoiceLabAssets.prepare(project: changed, plan: fresh, paidRoot: root)
        let handle = try #require(prepared["vl-passage"])
        #expect(try Data(contentsOf: handle.url) == Data(contentsOf: paid))
    }

    @Test func namedPipePaidAssetIsRejectedBeforeRead() throws {
        let (project, root, paid) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(mkfifo(paid.path, 0o600) == 0)
        let asset = project.voiceLab.assets![0]
        #expect(throws: VoiceLabAssetError.unsafePath(asset.file)) {
            try VoiceLabAssets.prepare(asset: asset, audio: project.voiceLab.segments[0].audio,
                                       segmentId: "vl-passage", project: project, paidRoot: root)
        }
        #expect(FileManager.default.fileExists(atPath: paid.path))
    }

    @Test func missingHashRateDurationAndTrimFailBeforeRender() throws {
        let (project, root, paid) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = project.voiceLab.segments[0].audio
        let asset = project.voiceLab.assets![0]
        #expect(throws: VoiceLabAssetError.missing(asset.file)) {
            try VoiceLabAssets.prepare(asset: asset, audio: audio, segmentId: "vl-passage", project: project, paidRoot: root)
        }
        let bytes = wave()
        try bytes.write(to: paid)
        #expect(throws: VoiceLabAssetError.altered(asset.file)) {
            try VoiceLabAssets.prepare(asset: asset, audio: audio, segmentId: "vl-passage", project: project, paidRoot: root)
        }
        var changed = project
        changed.voiceLab.assets![0].sha256 = SpeechSHA256.hex(bytes)
        changed.voiceLab.assets![0].durationSeconds = 1.1
        #expect(throws: VoiceLabAssetError.durationMismatch(asset.file)) {
            try VoiceLabAssets.prepare(asset: changed.voiceLab.assets![0], audio: audio, segmentId: "vl-passage", project: changed, paidRoot: root)
        }
        changed.voiceLab.assets![0].durationSeconds = 1
        changed.voiceLab.assets![0].sampleRate = 44_100
        #expect(throws: VoiceLabAssetError.rateMismatch(asset.file)) {
            try VoiceLabAssets.prepare(asset: changed.voiceLab.assets![0], audio: audio, segmentId: "vl-passage", project: changed, paidRoot: root)
        }
        changed.voiceLab.assets![0].sampleRate = 24_000
        let short = wave(frames: 23_999)
        try short.write(to: paid)
        changed.voiceLab.assets![0].sha256 = SpeechSHA256.hex(short)
        #expect(throws: VoiceLabAssetError.invalidTrim(asset.file)) {
            try VoiceLabAssets.prepare(asset: changed.voiceLab.assets![0], audio: audio, segmentId: "vl-passage", project: changed, paidRoot: root)
        }
        try bytes.write(to: paid)
        changed.voiceLab.assets![0].sha256 = SpeechSHA256.hex(bytes)
        changed.voiceLab.segments[0].audio.trimStart = 0.00002
        changed.voiceLab.segments[0].audio.trimEnd = 1
        changed.voiceLab.segments[0].audio.stretch = 1 / (1 - 0.00002)
        // Core permits this trim; Media applies half-up frame rounding to the actual decoder grid.
        try VoiceLabProject.validate(changed)
        let handle = try VoiceLabAssets.prepare(asset: changed.voiceLab.assets![0], audio: changed.voiceLab.segments[0].audio,
                                               segmentId: "vl-passage", project: changed, paidRoot: root)
        #expect(handle.trimStartFrame == 0 && handle.trimEndFrame == 24_000)
    }

    @Test func symlinkAndMalformedAudioAreRejectedAndPaidFileSurvives() throws {
        let (project, root, paid) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-outside-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: outside) }
        try wave().write(to: outside)
        try FileManager.default.createSymbolicLink(at: paid, withDestinationURL: outside)
        let asset = project.voiceLab.assets![0]
        #expect(throws: VoiceLabAssetError.unsafePath(asset.file)) {
            try VoiceLabAssets.prepare(asset: asset, audio: project.voiceLab.segments[0].audio,
                                       segmentId: "vl-passage", project: project, paidRoot: root)
        }
        try FileManager.default.removeItem(at: paid)
        try Data("RIFFbad".utf8).write(to: paid)
        var changed = project; changed.voiceLab.assets![0].sha256 = SpeechSHA256.hex(try Data(contentsOf: paid))
        #expect(throws: VoiceLabAssetError.unsupportedFormat(asset.file)) {
            try VoiceLabAssets.prepare(asset: changed.voiceLab.assets![0], audio: changed.voiceLab.segments[0].audio,
                                       segmentId: "vl-passage", project: changed, paidRoot: root)
        }
        #expect(FileManager.default.fileExists(atPath: paid.path))
    }

    @Test func nativeFlacDecoderPreparesDeclaredAsset() throws {
        let (base, root, wav) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let flac = wav.deletingPathExtension().appendingPathExtension("flac")
        do {
            let encoder = try AVAudioFile(forWriting: flac, settings: [
                AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24
            ])
            let format = encoder.processingFormat
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
            buffer.frameLength = 24_000
            let samples = try #require(buffer.floatChannelData?[0])
            for index in 0..<24_000 { samples[index] = Float(sin(2 * Double.pi * 440 * Double(index) / 24_000) * 0.3) }
            try encoder.write(from: buffer)
        }
        var project = base
        project.voiceLab.assets![0].file = project.id + "/asset-one.flac"
        project.voiceLab.assets![0].sha256 = try SpeechSHA256.file(flac)
        let handle = try VoiceLabAssets.prepare(asset: project.voiceLab.assets![0], audio: project.voiceLab.segments[0].audio,
                                               segmentId: "vl-passage", project: project, paidRoot: root)
        #expect(handle.frameCount == 24_000)
        #expect(handle.url.pathExtension == "flac")
    }

    @Test func cancellationDoesNotDeletePaidAsset() async throws {
        let (project, root, paid) = try setup(wave())
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try VoiceLabAssets.prepare(project: project,
                                               plan: VoiceLabOutputPlanner.build(project, scope: .full), paidRoot: root)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        #expect(result)
        #expect(FileManager.default.fileExists(atPath: paid.path))
    }
}
