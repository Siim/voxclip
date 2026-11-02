#if DEBUG
import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia

private struct VoiceChangeFinishFixture {
    let root: URL
    let paidRoot: URL
    let scratchRoot: URL
    let project: Project
    let window: VoiceLabWindow
    let record: VoiceConsentRecord
    let requests: [VoiceChangeFinisher.Request]
    let outputs: [VoiceChangeFinisher.Output]
    let rate = 24_000
    let model = "eleven_multilingual_sts_v2"

    static func make(passage: Bool, split: Bool = false, generatedGain: Double = 1) throws -> Self {
        let root = try VoiceChangeTestFiles.directory()
        let paidRoot = root.appendingPathComponent("paid"), scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        let shared = try SharedResources.locate()
        var project = try JSONProjectStore.decode(Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/passage-render-v3.voxclip")))
        let record = try VoiceChangeTestFiles.record()
        let rate = 24_000, total = rate * 7
        let createdAt = Date(timeIntervalSince1970: 1_793_577_600)
        let source = VoiceChangeTestFiles.samples(frames: total, rate: rate)
        let sourceURL = root.appendingPathComponent("source.wav")
        let sourceBytes = try VoiceLabTakeWAV.encode(source, rate: rate)
        try sourceBytes.write(to: sourceURL)
        project.media.source.absolutePath = sourceURL.path
        project.media.source.relativePath = nil
        project.media.source.sizeBytes = Int64(sourceBytes.count)
        project.media.source.contentKey = try JSONProjectStore.contentKey(for: sourceURL)
        project.media.source.audio = MediaAudio(sampleRate: rate, channels: 1)
        project.voiceLab.segments = []
        project.voiceLab.assets = []
        project.voiceLab.voices = []
        project.voiceLab.videoAssets = []
        project.voiceLab.cleanAudio = VoiceLabCleanAudio(mode: .off)
        project.edits = ProjectEdits(pauseThresholdSeconds: 10)
        let start = passage ? Int64(rate * 5 / 2) : 0
        let end = passage ? Int64(rate * 16 / 5) : Int64(total)
        let hardFade = Int64(EditingPrimitives.jsRound(0.012 * Double(rate)))
        let left = VoiceLabSeamPlacement(kind: passage ? .hard : .none, time: Double(start) / Double(rate), sample: start,
                                         fadeSamples: passage ? hardFade : 0)
        let right = VoiceLabSeamPlacement(kind: passage ? .hard : .none, time: Double(end) / Double(rate), sample: end,
                                          fadeSamples: passage ? hardFade : 0)
        let window = VoiceLabWindow(firstWordId: passage ? "w4" : "w1", lastWordId: passage ? "w5" : "w9",
            leftBridgeWordIds: [], rightBridgeWordIds: [], start: Double(start) / Double(rate), end: Double(end) / Double(rate),
            startSample: start, endSample: end, leftSeam: left, rightSeam: right)
        let ranges: [Range<Int64>] = split ? [start..<Int64(rate * 2), Int64(rate * 2)..<end] : [start..<end]
        var requests: [VoiceChangeFinisher.Request] = [], outputs: [VoiceChangeFinisher.Output] = []
        for (index, range) in ranges.enumerated() {
            let incoming = range.lowerBound == 0 ? 0 : index == 0 ? Int(hardFade / 2) : rate / 100
            let outgoing = range.upperBound == Int64(total) ? 0 : index == ranges.count - 1 ? Int(hardFade - hardFade / 2) : rate / 100
            let uploadStart = Int(range.lowerBound) - incoming, uploadEnd = Int(range.upperBound) + outgoing
            let input = try VoiceLabTakeWAV.encode(Array(source[uploadStart..<uploadEnd]), rate: rate)
            let outputSamples = source[uploadStart..<uploadEnd].map { $0 * Float(generatedGain) }
            let outputBytes = try VoiceLabTakeWAV.encode(outputSamples, rate: rate)
            let id = UUID()
            let quote = VoiceLabQuote(id: UUID(), operation: .voiceChange, requestID: id,
                estimate: CostEstimate(provider: "elevenlabs", operation: "voice-change", units: Double(uploadEnd - uploadStart) / Double(rate),
                    unit: "second", usd: Decimal(string: "0.01"), basis: "offline fixture"), region: .default,
                endpoint: "v1/voice-changer/\(record.voiceId)", languageMode: .autoDetected(expected: "en"),
                fingerprint: "offline", guardAudioHash: VoiceLabFingerprint.bytes(input), preparedAt: createdAt,
                modelID: "eleven_multilingual_sts_v2")
            let asset = try VoiceLabAssetStore.write(pcm16: Data(outputBytes.dropFirst(44)), sampleRate: rate,
                projectId: project.id, assetId: UUID().uuidString.lowercased(), paidRoot: paidRoot, createdAt: createdAt)
            let receipt = VoiceLabReceipt(provider: record.provider, region: .default, endpoint: quote.endpoint,
                modelID: quote.modelID, voiceID: record.voiceId, requestID: id, providerRequestID: "offline", spendWarning: nil)
            requests.append(.init(sourceRange: range, audio: input, quote: quote))
            outputs.append(.init(requestID: id, asset: asset, receipt: receipt))
        }
        return Self(root: root, paidRoot: paidRoot, scratchRoot: scratch, project: project, window: window,
            record: record, requests: requests, outputs: outputs)
    }
    func finish(outputs supplied: [VoiceChangeFinisher.Output]? = nil,
                requests planned: [VoiceChangeFinisher.Request]? = nil,
                isCurrent: @escaping @Sendable () async -> Bool = { true }) async throws -> VoiceChangeFinisher.Payload {
        try await VoiceChangeFinisher.finish(project: project, scope: .full, window: window, record: record,
            modelID: model, seed: 7, requests: planned ?? requests, outputs: supplied ?? outputs,
            paidRoot: paidRoot, scratchRoot: scratchRoot, isCurrent: isCurrent)
    }
    func paidBytes() throws -> [Data] { try outputs.map { try Data(contentsOf: paidRoot.appendingPathComponent($0.asset.file)) } }
}

@Suite("Voice changer local canonical finisher", .timeLimit(.minutes(2)), .offlineFixtures)
struct VoiceChangeFinisherTests {
    @Test(arguments: [false, true])
    func realRecipesRoundTripAndAuditionMatchesMeasuredMix(passage: Bool) async throws {
        let fixture = try VoiceChangeFinishFixture.make(passage: passage)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalBytes = try fixture.paidBytes()
        let payload = try await fixture.finish()
        #expect(payload.segments.count == 1 && payload.assets.count == 2)
        let segment = try #require(payload.segments.first)
        let recipe = try #require(segment.candidates.first?.recipe)
        #expect(segment.kind == .voiceChanger && segment.words == nil && segment.text == nil)
        #expect(recipe.audio.stretch == 1 && recipe.voiceSource == .own && recipe.voiceRefId == fixture.record.id)
        #expect(recipe.qa.transcriptMatch == nil && recipe.qa.transcriptTokens == nil && recipe.qa.transcriptExact == nil)
        #expect(recipe.qa.speakerScore == nil && recipe.qa.speakerModel == nil && recipe.qa.speakerPassed == nil)
        #expect(recipe.chunks.first?.assetSha256 == fixture.outputs[0].asset.sha256)
        #expect(recipe.chunks.first?.requestId == fixture.outputs[0].requestID.uuidString)
        #expect(recipe.audio.trimStart == (passage ? 0.006 : 0))
        let changed = try VoiceLabEditCommand.acceptAll(segments: payload.segments, assets: payload.assets, voice: payload.voice)
            .applying(to: fixture.project)
        #expect(changed.transcript == fixture.project.transcript && changed.edits == fixture.project.edits)
        #expect(try JSONProjectStore.decode(ProjectJSON.encode(changed)) == changed)
        let preparedMedia = try VoiceLabRenderPreflight.prepare(project: changed, scope: .full, paidRoot: fixture.paidRoot)
        let media = try #require(preparedMedia)
        let lease = try await VoiceChangeFinisher.prepareAudition(input: media,
            source: URL(fileURLWithPath: changed.media.source.absolutePath), scratchRoot: fixture.scratchRoot)
        let piece = try #require(media.prepared.selectedSegmentRecipes.first?.piece)
        let seams: [Int64] = passage ? [piece.outputStartSample, piece.outputEndSample] : []
        let measured = try VoiceChangeFinisher.measureMixed(lease.mixedAudioURL,
            range: piece.outputStartSample..<piece.outputEndSample, seams: seams, rate: fixture.rate)
        #expect(measured == recipe.qa)
        #expect(try fixture.paidBytes() == originalBytes)
        let mixed = try AVAudioFile(forReading: lease.mixedAudioURL)
        #expect(mixed.length == 7 * Int64(fixture.rate))
    }

    @Test func touchingChunksKeepOriginalRequestsAndUseCanonicalSynthHandles() async throws {
        let fixture = try VoiceChangeFinishFixture.make(passage: false, split: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let payload = try await fixture.finish()
        #expect(payload.segments.count == 2 && payload.assets.count == 4)
        #expect(Set(payload.segments.compactMap(\.groupId)).count == 1)
        #expect(payload.segments.allSatisfy { $0.scope == .fullTake })
        let first = try #require(payload.segments[0].candidates[0].recipe)
        let second = try #require(payload.segments[1].candidates[0].recipe)
        #expect(first.seams.out.kind == .synthToSynth && second.seams.in.kind == .synthToSynth)
        #expect(first.seams.out.fadeSamples == 480 && second.seams.in.assetHandleFrames == 240)
        #expect(first.seams.out.sourceHandleSamples == 0 && second.seams.in.sourceHandleSamples == 0)
        #expect(first.qa.lufsJumpLu <= 2 && second.qa.peakDbfs < 0)
        #expect(Set(payload.segments.flatMap { $0.candidates.compactMap(\.recipe).flatMap(\.chunks).map(\.requestId) }) ==
            Set(fixture.outputs.map { $0.requestID.uuidString }))
    }

    @Test(arguments: ["hash", "receipt", "missing", "no-handles", "stale", "late-stale"])
    func failedLocalFinishNeverDiscardsPaidEvidence(mode: String) async throws {
        let fixture = try VoiceChangeFinishFixture.make(passage: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try fixture.paidBytes()
        let output = fixture.outputs[0]
        var outputs = fixture.outputs, requests = fixture.requests
        if mode == "hash" {
            var asset = output.asset
            asset.sha256 = String(repeating: "0", count: 64)
            outputs = [.init(requestID: output.requestID, asset: asset, receipt: output.receipt)]
        }
        if mode == "receipt" { outputs = [.init(requestID: UUID(), asset: output.asset, receipt: output.receipt)] }
        if mode == "missing" { outputs = [] }
        if mode == "no-handles" {
            let request = requests[0]
            let wave = try VoiceLabWavePCM(request.audio)
            let body = (144..<(Int(wave.frames) - 144)).map { Float(wave.sample(frame: Int64($0), channel: 0)) }
            requests = [.init(sourceRange: request.sourceRange, audio: try VoiceLabTakeWAV.encode(body, rate: fixture.rate), quote: request.quote)]
        }
        let checks = Mutex(0)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.finish(outputs: outputs, requests: requests, isCurrent: {
                checks.withLock { count in
                    count += 1
                    return mode != "stale" && (mode != "late-stale" || count < 6)
                }
            })
        }
        #expect(try fixture.paidBytes() == original)
    }

    @Test func localQARefusesBadLevelWithoutPurchasingAnything() async throws {
        let fixture = try VoiceChangeFinishFixture.make(passage: true, generatedGain: 3)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try fixture.paidBytes()
        await #expect(throws: VoiceChangeFinisher.Failure.qaRejected) { _ = try await fixture.finish() }
        #expect(try fixture.paidBytes() == original)
    }

    @Test func conformUses300msCorrelationWithoutStretchOrInventedHandles() throws {
        let rate = 24_000
        let input: [Float] = (0..<(rate * 3)).map { index in
            let envelope = Double((index / 240 * 17) % 29 + 1) / 40
            return Float(envelope * sin(2 * Double.pi * 220 * Double(index) / Double(rate)))
        }
        let lag = rate / 10, id = UUID()
        let late = [Float](repeating: 0, count: lag) + input
        let aligned = try VoiceChangeFinisher.conform(input: input, output: late, sampleRate: rate, incoming: 144, outgoing: 144, requestID: id)
        #expect(aligned == input)
        let short = Array(input.dropLast())
        #expect(throws: VoiceChangeFinisher.Failure.missingHandles(id)) {
            try VoiceChangeFinisher.conform(input: input, output: short, sampleRate: rate, incoming: 144, outgoing: 144, requestID: id)
        }
        let padded = try VoiceChangeFinisher.conform(input: input, output: short, sampleRate: rate, incoming: 0, outgoing: 0, requestID: id)
        #expect(padded.count == input.count && padded.dropLast().elementsEqual(short) && padded.last == 0)
        #expect(throws: VoiceChangeFinisher.Failure.outOfSync(id)) {
            try VoiceChangeFinisher.conform(input: input, output: [Float](repeating: 0.1, count: input.count + rate / 2),
                sampleRate: rate, incoming: 0, outgoing: 0, requestID: id)
        }
    }

    @Test func mixedQAInspectsBothChannelsInsteadOfHidingClippingInDownmix() throws {
        let root = try VoiceChangeTestFiles.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rate = 24_000, frames = 24_000
        let url = root.appendingPathComponent("clipped.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let channels = try #require(buffer.floatChannelData)
            for index in 0..<frames { channels[0][index] = -1.1; channels[1][index] = 1.1 }
            try file.write(from: buffer)
        }
        #expect(throws: VoiceChangeFinisher.Failure.qaRejected) {
            try VoiceChangeFinisher.measureMixed(url, range: 0..<Int64(frames), seams: [], rate: rate)
        }
    }
}
#endif
