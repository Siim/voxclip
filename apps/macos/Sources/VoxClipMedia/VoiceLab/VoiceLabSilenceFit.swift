import CryptoKit
import Foundation
import VoxClipCore

public struct VoiceLabFittedPublication: Sendable {
    public let assets: [VoiceLabAsset]
    public let audio: VoiceLabAudio
    public let outDuration: Double
    public let words: [VoiceLabWord]
    public let chunks: [VoiceLabChunk]
    public let sourceStartSample: Int64
    public let sourceEndSample: Int64
    public func applying(to recipe: VoiceLabRenderRecipe) -> VoiceLabRenderRecipe {
        var result = recipe
        result.audio = audio; result.outDuration = outDuration; result.words = words; result.chunks = chunks
        return result
    }
}

public struct VoiceLabFittedAudio: Sendable {
    public let paidAsset: VoiceLabAsset
    public let snapshot: PreparedVoiceLabAsset
    public let fit: VoiceLabFitResult
    public let incomingHandleFrames: Int64
    public let outgoingHandleFrames: Int64
    public let trimStartFrame: Int64
    public let trimEndFrame: Int64
    public let isDerived: Bool
    let wave: VoiceLabWavePCM
    public var outDuration: Double {
        let window = fit.plan.windowEnd - fit.plan.windowStart
        if case .changedDuration(_, _, let residual) = fit { return window + residual }
        return window
    }
    public func publish(projectId: String, assetId: String, paidRoot: URL, createdAt: Date,
                        requestId: String, seed: UInt32, gainDb: Double) throws -> VoiceLabFittedPublication {
        guard !requestId.isEmpty, gainDb.isFinite, outDuration.isFinite, outDuration > 0,
              try VoiceLabAssetNaming.file(projectId: projectId, assetId: paidAsset.id, extension: "wav") == paidAsset.file else { throw VoiceLabError.invalidInput }
        let asset: VoiceLabAsset
        if isDerived {
            asset = try VoiceLabAssetStore.writeWave(pcm: wave.pcm, sampleRate: wave.rate, channels: wave.channels,
                bits: wave.bits, floating: wave.floating, projectId: projectId, assetId: assetId, paidRoot: paidRoot, createdAt: createdAt)
        } else { asset = paidAsset }
        let audio = VoiceLabAudio(assetId: asset.id, trimStart: Double(trimStartFrame) / Double(wave.rate),
            trimEnd: Double(trimEndFrame) / Double(wave.rate), stretch: 1, gainDb: gainDb)
        guard Int64(EditingPrimitives.jsRound(audio.trimEnd * Double(wave.rate))) -
                Int64(EditingPrimitives.jsRound(audio.trimStart * Double(wave.rate))) == fit.plan.outputFrames else { throw VoiceLabError.invalidAudio }
        let chunk = VoiceLabChunk(sourceStartSample: fit.plan.windowStartSample, sourceEndSample: fit.plan.windowEndSample,
            requestId: requestId, seed: seed, assetId: paidAsset.id, assetSha256: paidAsset.sha256,
            assembledStartFrame: trimStartFrame, assembledEndFrame: trimEndFrame)
        return VoiceLabFittedPublication(assets: isDerived ? [paidAsset, asset] : [paidAsset], audio: audio,
            outDuration: outDuration, words: fit.plan.words, chunks: [chunk], sourceStartSample: fit.plan.windowStartSample,
            sourceEndSample: fit.plan.windowEndSample)
    }
}

public enum VoiceLabSilenceFit {
    public static func prepare(snapshot: PreparedVoiceLabAsset, paidAsset: VoiceLabAsset, fit: VoiceLabFitResult,
                               window: VoiceLabWindow, sourceSampleRate: Int) throws -> VoiceLabFittedAudio {
        guard snapshot.assetId == paidAsset.id, snapshot.sha256 == paidAsset.sha256,
              snapshot.sampleRate == paidAsset.sampleRate, (8_000...192_000).contains(sourceSampleRate) else { throw VoiceLabError.invalidAudio }
        guard snapshot.frameCount <= Int64(snapshot.sampleRate) * 290,
              try snapshot.url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map({ $0 <= 256 * 1_024 * 1_024 }) == true else { throw VoiceLabAssetError.tooLarge(paidAsset.id) }
        let bytes = try Data(contentsOf: snapshot.url)
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == snapshot.sha256 else { throw VoiceLabAssetError.altered(paidAsset.id) }
        let original = try VoiceLabWavePCM(bytes)
        let plan = fit.plan
        guard original.rate == snapshot.sampleRate, original.channels == snapshot.channels,
              original.frames == snapshot.frameCount, plan.trimStartFrame >= 0, plan.trimEndFrame <= original.frames,
              plan.windowStart.isFinite, plan.windowEnd.isFinite, plan.windowStart >= 0, plan.windowEnd > plan.windowStart,
              plan.windowStartSample >= 0, plan.windowEndSample > plan.windowStartSample,
              plan.trimEndFrame > plan.trimStartFrame, plan.incoming.padFrames >= 0, plan.outgoing.padFrames >= 0,
              plan.incoming.padFrames <= plan.outputFrames, plan.outgoing.padFrames <= plan.outputFrames,
              plan.outputFrames > 0, plan.outputFrames <= Int64(original.rate) * 290 else { throw VoiceLabError.invalidAudio }
        func handle(_ seam: VoiceLabSeamPlacement, incoming: Bool) throws -> Int64 {
            guard seam.fadeSamples >= 0, seam.fadeSamples <= Int64(sourceSampleRate) else { throw VoiceLabError.invalidAudio }
            if seam.kind == .none {
                guard seam.fadeSamples == 0 else { throw VoiceLabError.invalidAudio }
                return 0
            }
            let half = incoming ? seam.fadeSamples / 2 : seam.fadeSamples - seam.fadeSamples / 2
            return Int64(ceil(Double(half) * Double(original.rate) / Double(sourceSampleRate)))
        }
        let incoming = try handle(window.leftSeam, incoming: true), outgoing = try handle(window.rightSeam, incoming: false)
        guard (incoming + plan.outputFrames + outgoing) * Int64(original.stride) <= 256 * 1_024 * 1_024 else { throw VoiceLabAssetError.tooLarge(paidAsset.id) }
        let derived = !plan.edits.isEmpty || plan.incoming.padFrames > 0 || plan.outgoing.padFrames > 0
        if !derived {
            guard plan.trimStartFrame >= incoming, plan.trimEndFrame + outgoing <= original.frames,
                  plan.trimEndFrame - plan.trimStartFrame == plan.outputFrames else { throw VoiceLabError.invalidAudio }
            return VoiceLabFittedAudio(paidAsset: paidAsset, snapshot: snapshot, fit: fit, incomingHandleFrames: incoming,
                outgoingHandleFrames: outgoing, trimStartFrame: plan.trimStartFrame, trimEndFrame: plan.trimEndFrame,
                isDerived: false, wave: original)
        }
        var pcm = Data()
        func copy(_ start: Int64, _ end: Int64) throws {
            guard start >= 0, end >= start, end <= original.frames else { throw VoiceLabError.invalidAudio }
            pcm.append(original.pcm[Int(start) * original.stride..<Int(end) * original.stride])
        }
        func silence(_ frames: Int64) { pcm.append(Data(count: Int(frames) * original.stride)) }
        if plan.incoming.padFrames > 0 { silence(incoming) }
        else { try copy(plan.trimStartFrame - incoming, plan.trimStartFrame) }
        silence(plan.incoming.padFrames)
        var cursor = plan.trimStartFrame
        var joins: [(output: Int64, left: Int64, right: Int64)] = []
        let fade = Int64(EditingPrimitives.jsRound(VoiceLabPatchConstants.SEAM_FADE * Double(original.rate)))
        var previousEnd = plan.trimStartFrame
        for edit in plan.edits {
            try Task.checkCancellation()
            guard edit.start >= cursor, edit.start <= plan.trimEndFrame,
                  edit.count > 0, edit.count <= plan.trimEndFrame - edit.start else { throw VoiceLabError.invalidAudio }
            let end = edit.start + edit.count
            guard edit.count > 0, edit.start - fade / 2 >= previousEnd,
                  end + fade - fade / 2 <= plan.trimEndFrame else { throw VoiceLabGeometryError.fitTouchesVoice }
            try copy(cursor, edit.start)
            if edit.kind == .insert { try copy(edit.start, end) }
            joins.append((Int64(pcm.count / original.stride), edit.kind == .insert ? end : edit.start,
                          edit.kind == .insert ? edit.start : end))
            if edit.kind == .insert { try copy(edit.start, end) }
            cursor = end
            previousEnd = end + fade - fade / 2
        }
        try copy(cursor, plan.trimEndFrame)
        silence(plan.outgoing.padFrames)
        guard pcm.count / original.stride == incoming + plan.outputFrames else { throw VoiceLabError.invalidAudio }
        if plan.outgoing.padFrames > 0 { silence(outgoing) }
        else { try copy(plan.trimEndFrame, plan.trimEndFrame + outgoing) }
        var wave = VoiceLabWavePCM(rate: original.rate, channels: original.channels, bits: original.bits, floating: original.floating, pcm: pcm)
        for join in joins {
            for offset in 0..<fade {
                let local = offset - fade / 2
                let phase = Double(offset) / Double(fade - 1)
                for channel in 0..<original.channels {
                    let left = original.sample(frame: join.left + local, channel: channel) * cos(.pi * phase / 2)
                    let right = original.sample(frame: join.right + local, channel: channel) * sin(.pi * phase / 2)
                    let mixed = left + right
                    guard mixed.isFinite, !original.floating || original.bits != 32 || Float(mixed).isFinite else { throw VoiceLabError.invalidAudio }
                    wave.setSample(mixed, frame: join.output + local, channel: channel)
                }
            }
        }
        return VoiceLabFittedAudio(paidAsset: paidAsset, snapshot: snapshot, fit: fit, incomingHandleFrames: incoming,
            outgoingHandleFrames: outgoing, trimStartFrame: incoming, trimEndFrame: incoming + plan.outputFrames,
            isDerived: true, wave: wave)
    }
}

struct VoiceLabWavePCM: Sendable {
    let rate: Int
    let channels: Int
    let bits: Int
    let floating: Bool
    var pcm: Data
    var stride: Int { channels * (bits / 8) }
    var frames: Int64 { Int64(pcm.count / stride) }
    var bytes: Data {
        VoiceLabAssetStore.wavHeader(frames: Int(frames), sampleRate: rate, channels: channels, bits: bits, floating: floating) + pcm + Data(count: pcm.count % 2)
    }
    init(rate: Int, channels: Int, bits: Int, floating: Bool, pcm: Data) {
        self.rate = rate; self.channels = channels; self.bits = bits; self.floating = floating; self.pcm = pcm
    }
    init(_ data: Data) throws {
        func u16(_ offset: Int) -> Int { data.withUnsafeBytes { Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))) } }
        func u32(_ offset: Int) -> Int { data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) } }
        guard data.count >= 44, data.count <= 256 * 1_024 * 1_024, data.prefix(4) == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8), u32(4) == data.count - 8 else { throw VoiceLabError.invalidAudio }
        var format: (rate: Int, channels: Int, bits: Int, floating: Bool)?
        var content: Data?
        var offset = 12
        while offset + 8 <= data.count {
            let size = u32(offset + 4), start = offset + 8
            guard size <= data.count - start else { throw VoiceLabError.invalidAudio }
            let tag = data[offset..<(offset + 4)]
            if tag == Data("fmt ".utf8) {
                guard format == nil, size == 16 || (size == 18 && u16(start + 16) == 0),
                      [1, 3].contains(u16(start)) else { throw VoiceLabError.invalidAudio }
                let channels = u16(start + 2), rate = u32(start + 4), bits = u16(start + 14), floating = u16(start) == 3
                guard (1...8).contains(channels), (8_000...192_000).contains(rate),
                      (floating ? [32, 64] : [16, 24, 32]).contains(bits), u16(start + 12) == channels * (bits / 8),
                      u32(start + 8) == rate * channels * (bits / 8) else { throw VoiceLabError.invalidAudio }
                format = (rate, channels, bits, floating)
            } else if tag == Data("data".utf8) {
                guard content == nil else { throw VoiceLabError.invalidAudio }
                content = data.subdata(in: start..<(start + size))
            }
            offset = start + size + size % 2
        }
        guard offset == data.count, let format, let content, !content.isEmpty,
              content.count.isMultiple(of: format.channels * (format.bits / 8)) else { throw VoiceLabError.invalidAudio }
        self.init(rate: format.rate, channels: format.channels, bits: format.bits, floating: format.floating, pcm: content)
    }
    func sample(frame: Int64, channel: Int) -> Double {
        let offset = Int(frame) * stride + channel * (bits / 8)
        return pcm.withUnsafeBytes { raw in
            if floating {
                if bits == 32 { return Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))) }
                return Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
            }
            var value: Int64 = 0
            for byte in 0..<(bits / 8) { value |= Int64(raw[offset + byte]) << (byte * 8) }
            if value & (1 << (bits - 1)) != 0 { value -= 1 << bits }
            return Double(value) / pow(2, Double(bits - 1))
        }
    }
    mutating func setSample(_ value: Double, frame: Int64, channel: Int) {
        let offset = Int(frame) * stride + channel * (bits / 8)
        let encoded: UInt64
        if floating { encoded = bits == 32 ? UInt64(Float(value).bitPattern) : value.bitPattern }
        else {
            let scale = pow(2, Double(bits - 1))
            encoded = UInt64(bitPattern: Int64(max(-scale, min(scale - 1, (value * scale).rounded(.toNearestOrEven)))))
        }
        for byte in 0..<(bits / 8) { pcm[offset + byte] = UInt8(truncatingIfNeeded: encoded >> (byte * 8)) }
    }
}
