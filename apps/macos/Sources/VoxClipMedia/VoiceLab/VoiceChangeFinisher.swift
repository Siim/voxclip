import AVFoundation
import Foundation
import VoxClipCore

public enum VoiceChangeFinisher {
    public static let maximumUploadBytes = 49_999_999

    public enum Failure: Error, Equatable, Sendable {
        case stale, invalidInput, invalidOutput(UUID), missingHandles(UUID), outOfSync(UUID), qaRejected
    }

    public struct Request: Sendable {
        public let sourceRange: Range<Int64>
        public let audio: Data
        public let quote: VoiceLabQuote
        public init(sourceRange: Range<Int64>, audio: Data, quote: VoiceLabQuote) {
            self.sourceRange = sourceRange; self.audio = audio; self.quote = quote
        }
    }

    public struct Output: Sendable {
        public let requestID: UUID
        public let asset: VoiceLabAsset
        public let receipt: VoiceLabReceipt
        public init(requestID: UUID, asset: VoiceLabAsset, receipt: VoiceLabReceipt) {
            self.requestID = requestID; self.asset = asset; self.receipt = receipt
        }
    }

    public struct Payload: Sendable {
        public let segments: [VoiceLabSegment]
        public let assets: [VoiceLabAsset]
        public let voice: VoiceLabVoiceReference
    }

    private struct Working {
        let request: Request
        let output: Output
        let asset: VoiceLabAsset
        let snapshot: PreparedVoiceLabAsset
        let incoming: VoiceLabSeam
        let outgoing: VoiceLabSeam
        let lead: Int
        let frames: Int
    }

    public static func finish(project: Project, scope: VoiceLabOutputScope, window: VoiceLabWindow,
                              record: VoiceConsentRecord, modelID: String, seed: UInt32,
                              requests: [Request], outputs: [Output], paidRoot: URL, scratchRoot: URL,
                              isCurrent: @escaping @Sendable () async -> Bool) async throws -> Payload {
        try await checkpoint(isCurrent)
        try record.validate()
        guard record.status == .active, record.attestations.complete,
              let verifiedAt = ISO8601DateFormatter().date(from: record.attestations.acceptedAt),
              let transcript = project.transcript, let audio = project.media.source.audio,
              (8_000...96_000).contains(audio.sampleRate), project.voiceLab.cleanAudio?.mode != .on,
              (1...32).contains(requests.count), outputs.count == requests.count,
              Set(outputs.map(\.requestID)).count == outputs.count,
              Set(outputs.map { $0.asset.id }).count == outputs.count,
              Set(requests.map { $0.quote.requestID }).count == requests.count,
              Set(requests.map { $0.quote.id }).count == requests.count else { throw Failure.invalidInput }
        let rate = audio.sampleRate
        let source = URL(fileURLWithPath: project.media.source.absolutePath)
        try verifySource(project, source: source)
        let totalValue = EditingPrimitives.jsRound(project.media.source.durationSeconds * Double(rate))
        guard totalValue.isFinite, totalValue > 0, totalValue < 0x1p53,
              window.startSample >= 0, window.endSample <= Int64(totalValue), window.endSample > window.startSample,
              window.start == Double(window.startSample) / Double(rate), window.end == Double(window.endSample) / Double(rate)
        else { throw Failure.invalidInput }
        let total = Int64(totalValue)
        let byRequest = Dictionary(uniqueKeysWithValues: outputs.map { ($0.requestID, $0) })
        var cursor = window.startSample
        var working: [Working] = []
        defer { for item in working { item.snapshot.invalidate() } }
        for (index, request) in requests.enumerated() {
            try await checkpoint(isCurrent)
            let quote = request.quote
            guard request.sourceRange.lowerBound == cursor, request.sourceRange.upperBound <= window.endSample,
                  !request.sourceRange.isEmpty, quote.operation == .voiceChange, quote.region == record.recordedRegion,
                  quote.modelID == modelID, quote.endpoint == "v1/voice-changer/\(record.voiceId)",
                  quote.guardAudioHash == VoiceLabFingerprint.bytes(request.audio),
                  let output = byRequest[quote.requestID], output.receipt.requestID == quote.requestID,
                  output.receipt.provider == record.provider, output.receipt.voiceID == record.voiceId,
                  output.receipt.modelID == modelID, output.receipt.region == quote.region,
                  output.receipt.endpoint == quote.endpoint, output.asset.sampleRate == 24_000,
                  output.asset.createdAt >= verifiedAt else { throw Failure.invalidInput }
            let incoming = try seam(index == 0 ? window.leftSeam.kind : .synthToSynth,
                                    edge: request.sourceRange.lowerBound == 0, rate: rate, incoming: true)
            let outgoing = try seam(index == requests.count - 1 ? window.rightSeam.kind : .synthToSynth,
                                    edge: request.sourceRange.upperBound == total, rate: rate, incoming: false)
            if index == 0, incoming.fadeSamples != window.leftSeam.fadeSamples { throw Failure.invalidInput }
            if index == requests.count - 1, outgoing.fadeSamples != window.rightSeam.fadeSamples { throw Failure.invalidInput }
            let lead = Int(incoming.assetHandleFrames), tail = Int(outgoing.assetHandleFrames)
            let frames = Int(request.sourceRange.count)
            guard request.sourceRange.lowerBound >= Int64(lead), request.sourceRange.upperBound + Int64(tail) <= total else {
                throw Failure.missingHandles(quote.requestID)
            }
            let format = try ElevenLabsVoiceLab.validateWAV(request.audio, maxBytes: maximumUploadBytes)
            guard format.rate == rate, format.frames == frames + lead + tail,
                  format.frames <= rate * 290,
                  abs(quote.estimate.units - Double(format.frames) / Double(rate)) < 1e-9 else { throw Failure.invalidInput }
            let input = try monoWAV(request.audio)
            let paid = try VoiceLabAssets.preparePaid(asset: output.asset, projectId: project.id, paidRoot: paidRoot, scratchRoot: scratchRoot)
            defer { paid.invalidate() }
            guard paid.sampleRate == 24_000, paid.channels == 1 else { throw Failure.invalidOutput(output.requestID) }
            let decoded = try VoiceLabSourceAudio.decodeAsset(url: paid.url, targetSampleRate: Double(rate), expectedSha256: output.asset.sha256)
            let conformed = try conform(input: input, output: decoded, sampleRate: rate, incoming: lead, outgoing: tail, requestID: output.requestID)
            try await checkpoint(isCurrent)
            let asset = try VoiceLabAssetStore.writeDerived(samples: conformed, sampleRate: rate, projectId: project.id,
                assetId: UUID().uuidString.lowercased(), paidRoot: paidRoot, createdAt: output.asset.createdAt)
            let snapshot = try VoiceLabAssets.preparePaid(asset: asset, projectId: project.id, paidRoot: paidRoot, scratchRoot: scratchRoot)
            working.append(Working(request: request, output: output, asset: asset, snapshot: snapshot,
                                   incoming: incoming, outgoing: outgoing, lead: lead, frames: frames))
            cursor = request.sourceRange.upperBound
        }
        guard cursor == window.endSample else { throw Failure.invalidInput }
        let voice = VoiceLabVoiceReference(id: record.id, provider: record.provider, voiceId: record.voiceId,
            consentRecordId: record.id, displayName: record.voiceName, status: .active)
        let assets = working.flatMap { [$0.output.asset, $0.asset] }
        let fullTake = window.startSample == 0 && window.endSample == total
        let group = fullTake ? UUID().uuidString.lowercased() : nil
        var segments: [VoiceLabSegment] = []
        for (index, item) in working.enumerated() {
            try await checkpoint(isCurrent)
            let samples = try readMono(item.snapshot.url, start: item.lead, count: item.frames)
            let reach = Int64(EditingPrimitives.jsRound(0.4 * Double(rate)))
            let lower = item.request.sourceRange.lowerBound, upper = item.request.sourceRange.upperBound
            let before: [Float]
            if index > 0 {
                let prior = working[index - 1]
                let count = min(Int(reach), prior.frames)
                before = try readMono(prior.snapshot.url, start: prior.lead + prior.frames - count, count: count)
            } else {
                before = try await sourceContext(source, range: max(0, lower - reach)..<lower, rate: rate)
            }
            let after: [Float]
            if index + 1 < working.count {
                let next = working[index + 1]
                after = try readMono(next.snapshot.url, start: next.lead, count: min(Int(reach), next.frames))
            } else {
                after = try await sourceContext(source, range: upper..<min(total, upper + reach), rate: rate)
            }
            let dry = before + samples + after
            let positions: [Int] = (item.incoming.kind == .none ? [] : [before.count]) +
                (item.outgoing.kind == .none ? [] : [before.count + samples.count])
            let qa = try measurement(samples: dry, seams: positions, rate: rate)
            // The range's words on the source sample grid, as the Core validates them (voice-lab §10.1).
            let grid = VoiceLabSampleGrid(rate: Double(rate))
            let contained = transcript.words.filter { grid.sample($0.start) >= Double(lower) && grid.sample($0.end) <= Double(upper) }
            guard let first = contained.first, let last = contained.last else { throw Failure.invalidInput }
            let recipe = makeRecipe(item, record: record, modelID: modelID, seed: seed, rate: rate, verifiedAt: verifiedAt, qa: qa)
            var candidate = VoiceLabCandidate(assetId: item.asset.id, score: nil)
            candidate.recipe = recipe
            var segment = VoiceLabSegment(id: UUID().uuidString.lowercased(), kind: .voiceChanger, enabled: true,
                replace: VoiceLabReplacement(start: Double(lower) / Double(rate), end: Double(upper) / Double(rate),
                    firstWordId: first.id, lastWordId: last.id), outDuration: recipe.outDuration, audio: recipe.audio,
                text: nil, words: nil, provenance: recipe.provenance,
                qa: VoiceLabQA(transcriptMatch: nil, lufsJumpLu: qa.lufsJumpLu, peakDbfs: qa.peakDbfs, speakerScore: nil),
                candidates: [candidate], selectedCandidateIndex: 0)
            segment.scope = fullTake ? .fullTake : .passage; segment.groupId = group
            segments.append(segment)
        }
        let provisional = try VoiceLabEditCommand.acceptAll(segments: segments, assets: assets, voice: voice).applying(to: project, outputScope: scope)
        guard let input = try VoiceLabRenderPreflight.prepare(project: provisional, scope: scope, paidRoot: paidRoot) else { throw Failure.invalidInput }
        try await checkpoint(isCurrent)
        let lease = try await prepareAudition(input: input, source: source, scratchRoot: scratchRoot)
        for index in segments.indices {
            try await checkpoint(isCurrent)
            guard let selected = input.prepared.selectedSegmentRecipes.first(where: { $0.segmentId == segments[index].id }),
                  selected.piece.sourceStartSample == working[index].request.sourceRange.lowerBound,
                  selected.piece.sourceEndSample == working[index].request.sourceRange.upperBound else { throw Failure.invalidInput }
            let piece = selected.piece
            let positions = (selected.recipe.seams.in.kind == .none ? [] : [piece.outputStartSample]) +
                (selected.recipe.seams.out.kind == .none ? [] : [piece.outputEndSample])
            let qa = try measureMixed(lease.mixedAudioURL, range: piece.outputStartSample..<piece.outputEndSample,
                                      seams: positions, rate: rate)
            var recipe = selected.recipe
            recipe.qa = qa
            segments[index].candidates[0].recipe = recipe
            segments[index].qa = VoiceLabQA(transcriptMatch: nil, lufsJumpLu: qa.lufsJumpLu, peakDbfs: qa.peakDbfs, speakerScore: nil)
        }
        try await checkpoint(isCurrent)
        try verifySource(project, source: source)
        let final = try VoiceLabEditCommand.acceptAll(segments: segments, assets: assets, voice: voice).applying(to: project, outputScope: scope)
        _ = try VoiceLabRenderPreflight.prepare(project: final, scope: scope, paidRoot: paidRoot)
        for item in working {
            for asset in [item.output.asset, item.asset] {
                let checked = try VoiceLabAssets.preparePaid(asset: asset, projectId: project.id, paidRoot: paidRoot, scratchRoot: scratchRoot)
                checked.invalidate()
            }
        }
        try await checkpoint(isCurrent)
        return Payload(segments: segments, assets: assets, voice: voice)
    }

    public static func prepareAudition(input: VoiceLabRenderInput, source: URL, scratchRoot: URL) async throws -> VoiceLabRenderLease {
        let project = input.project
        guard let transcript = project.transcript else { throw Failure.invalidInput }
        let edits = project.edits
        let state = EditState(transcript: transcript, pauses: try detectPauses(transcript.words, thresholdSeconds: edits.pauseThresholdSeconds),
            pauseThresholdSeconds: edits.pauseThresholdSeconds, pauseKeepSeconds: edits.pauseKeepSeconds,
            cutWordIds: Set(edits.cutWordIds), cutPauseIds: Set(edits.cutPauseIds), corrections: edits.corrections,
            clips: edits.clips, activeClipId: nil)
        let clip: ClipRange?
        switch input.scope {
        case .full: clip = nil
        case .clip(let id):
            guard let selected = edits.clips.first(where: { $0.id == id }) else { throw Failure.invalidInput }
            clip = selected
        }
        let rate = input.prepared.outputPlan.sampleRate
        let plan = try EditPlan.build(transcript: transcript, editState: state, activeClip: clip,
            duration: project.media.source.durationSeconds, sampleRate: rate)
        let request = RenderRequest(sourceURL: source, plan: plan,
            output: OutputSpec(size: PixelSize(width: 2, height: 2), fps: 30, videoBitrate: 1_000_000,
                               audioSampleRate: Int(rate)), forPreview: true, voiceLab: input)
        return try await VoiceLabAudioRenderer.stage(request: request, scratchRoot: scratchRoot)
    }

    static func conform(input: [Float], output: [Float], sampleRate: Int, incoming: Int, outgoing: Int, requestID: UUID) throws -> [Float] {
        guard !input.isEmpty, !output.isEmpty, input.allSatisfy(\.isFinite), output.allSatisfy(\.isFinite) else {
            throw Failure.invalidOutput(requestID)
        }
        let decision = try VoiceLabConform.decide(inputEnvelope: VoiceLabSourceAudio.envelope(samples: input, sampleRate: sampleRate),
            outputEnvelope: VoiceLabSourceAudio.envelope(samples: output, sampleRate: sampleRate),
            inputSamples: input.count, outputSamples: output.count, sampleRate: sampleRate,
            searchSeconds: VoiceLabConform.voiceChangerSearchSeconds)
        let lag: Int
        switch decision {
        case .trimOrPad: lag = 0
        case .shift(let samples, _): lag = samples
        case .outOfSync: throw Failure.outOfSync(requestID)
        }
        guard !(incoming > 0 && lag < 0), !(outgoing > 0 && output.count - lag < input.count) else {
            throw Failure.missingHandles(requestID)
        }
        var result = [Float](repeating: 0, count: input.count)
        for index in result.indices {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            let source = index + lag
            if output.indices.contains(source) { result[index] = output[source] }
        }
        return result
    }

    private static func seam(_ kind: VoiceLabSeamKind, edge: Bool, rate: Int, incoming: Bool) throws -> VoiceLabSeam {
        guard edge ? kind == .none : kind != .none else { throw Failure.invalidInput }
        let fade = kind == .none ? 0 : Int64(EditingPrimitives.jsRound((kind == .hard ? 0.012 : 0.020) * Double(rate)))
        let inner = incoming ? fade / 2 : fade - fade / 2
        return VoiceLabSeam(kind: kind, fadeSamples: fade,
            sourceHandleSamples: kind == .synthToSynth ? 0 : fade - inner, assetHandleFrames: inner)
    }

    private static func makeRecipe(_ item: Working, record: VoiceConsentRecord, modelID: String, seed: UInt32, rate: Int,
                                   verifiedAt: Date, qa: VoiceLabRenderQA) -> VoiceLabRenderRecipe {
        let range = item.request.sourceRange
        let audio = VoiceLabAudio(assetId: item.asset.id, trimStart: Double(item.lead) / Double(rate),
            trimEnd: Double(item.lead + item.frames) / Double(rate))
        var provenance = VoiceLabProvenance(provider: record.provider, endpoint: item.output.receipt.endpoint, model: modelID,
            voiceId: record.voiceId, consentRecordId: record.id, requestId: item.output.requestID.uuidString,
            seed: seed, createdAt: item.output.asset.createdAt)
        provenance.region = item.output.receipt.region.rawValue
        let video = VoiceLabVideoRecipe(mode: .source, sourceStartSample: range.lowerBound, sourceEndSample: range.upperBound,
            outputSamples: Int64(item.frames), retimeFactor: nil, zoom: nil, faceX: nil, faceY: nil, assetId: nil,
            provider: nil, model: nil, requestId: nil, windowStartSample: nil, windowEndSample: nil, syncMode: nil)
        return VoiceLabRenderRecipe(audio: audio, words: nil, outDuration: Double(item.frames) / Double(rate), seed: seed,
            chunks: [VoiceLabChunk(sourceStartSample: range.lowerBound, sourceEndSample: range.upperBound,
                requestId: item.output.requestID.uuidString, seed: seed, assetId: item.output.asset.id,
                assetSha256: item.output.asset.sha256, assembledStartFrame: Int64(item.lead), assembledEndFrame: Int64(item.lead + item.frames))],
            roomTone: nil, seams: VoiceLabSeams(in: item.incoming, out: item.outgoing), video: video, qa: qa,
            provenance: provenance, cost: VoiceLabCost(quoteId: item.request.quote.id.uuidString,
                usd: item.request.quote.estimate.usd.map { NSDecimalNumber(decimal: $0).doubleValue }),
            voiceSource: .own, voiceRefId: record.id, consentVerifiedAt: verifiedAt)
    }

    private static func checkpoint(_ isCurrent: @Sendable () async -> Bool) async throws {
        try Task.checkCancellation()
        guard await isCurrent() else { throw Failure.stale }
        try Task.checkCancellation()
    }

    private static func verifySource(_ project: Project, source: URL) throws {
        let info = try FileManager.default.attributesOfItem(atPath: source.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
              (info[.size] as? NSNumber)?.int64Value == project.media.source.sizeBytes,
              try JSONProjectStore.contentKey(for: source) == project.media.source.contentKey else { throw Failure.stale }
    }

    private static func monoWAV(_ bytes: Data) throws -> [Float] {
        let wave = try VoiceLabWavePCM(bytes)
        guard wave.channels == 1, wave.frames <= Int64(Int.max) else { throw Failure.invalidInput }
        return (0..<Int(wave.frames)).map { Float(wave.sample(frame: Int64($0), channel: 0)) }
    }

    private static func sourceContext(_ source: URL, range: Range<Int64>, rate: Int) async throws -> [Float] {
        guard !range.isEmpty else { return [] }
        guard range.count >= (rate + 49) / 50 else { throw VoiceLabAudioMathError.insufficientContext }
        return try monoWAV(await VoiceLabSourceAudio.conversionInput(source: source, startSample: range.lowerBound,
            endSample: range.upperBound, sourceSampleRate: Double(rate)))
    }

    private static func readMono(_ url: URL, start: Int, count: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.channelCount == 1 else { throw Failure.invalidInput }
        return try read(file, start: Int64(start), count: count)[0]
    }

    private static func read(_ file: AVAudioFile, start: Int64, count: Int) throws -> [[Float]] {
        guard start >= 0, count >= 0, start + Int64(count) <= file.length else { throw Failure.invalidInput }
        file.framePosition = start
        var output = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(4096, remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw Failure.invalidInput }
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw Failure.invalidInput }
            for channel in output.indices {
                let values = UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength))
                guard values.allSatisfy(\.isFinite) else { throw Failure.qaRejected }
                output[channel].append(contentsOf: values)
            }
            remaining -= Int(buffer.frameLength)
        }
        return output
    }

    private static func measurement(samples: [Float], seams: [Int], rate: Int) throws -> VoiceLabRenderQA {
        let jump = try VoiceLabLoudness.lufsJumpLu(samples, sampleRate: rate, seamSamples: seams)
        let peak = try VoiceLabLoudness.samplePeakDbfs(samples)
        return try qa(jump: jump, peak: peak)
    }

    static func measureMixed(_ url: URL, range: Range<Int64>, seams: [Int64], rate: Int) throws -> VoiceLabRenderQA {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == Double(rate), (1...2).contains(file.processingFormat.channelCount),
              !range.isEmpty, range.lowerBound >= 0, range.upperBound <= file.length else { throw Failure.invalidInput }
        let reach = Int64(EditingPrimitives.jsRound(0.4 * Double(rate)))
        let lower = max(0, range.lowerBound - reach), upper = min(file.length, range.upperBound + reach)
        var peak = -Double.infinity
        var cursor = lower
        while cursor < upper {
            let count = Int(min(4096, upper - cursor))
            for channel in try read(file, start: cursor, count: count) {
                peak = max(peak, try VoiceLabLoudness.samplePeakDbfs(channel))
            }
            cursor += Int64(count)
        }
        var jump = 0.0
        for seam in seams {
            let start = max(0, seam - reach), end = min(file.length, seam + reach)
            for channel in try read(file, start: start, count: Int(end - start)) {
                jump = max(jump, try VoiceLabLoudness.seamJumpLu(channel, sampleRate: rate, seamSample: Int(seam - start)))
            }
        }
        return try qa(jump: jump, peak: peak)
    }

    private static func qa(jump: Double, peak: Double) throws -> VoiceLabRenderQA {
        guard jump.isFinite, jump <= 2, peak.isFinite, peak < 0 else { throw Failure.qaRejected }
        return VoiceLabRenderQA(transcriptTokens: nil, transcriptExact: nil, transcriptMatch: nil,
            lufsJumpLu: jump, peakDbfs: peak, speakerScore: nil, speakerThreshold: nil, speakerModel: nil, speakerPassed: nil)
    }
}
