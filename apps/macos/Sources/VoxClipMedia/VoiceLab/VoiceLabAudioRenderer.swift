import AVFoundation
import Darwin
import Foundation
import VoxClipCore

/// Owns every decoded snapshot and staged CAF until the last graph reader is gone.
public final class VoiceLabRenderLease: @unchecked Sendable {
    public let mixedAudioURL: URL
    private let scratch: URL
    private let preparedAssets: [String: PreparedVoiceLabAsset]

    init(mixedAudioURL: URL, scratch: URL, preparedAssets: [String: PreparedVoiceLabAsset]) {
        self.mixedAudioURL = mixedAudioURL
        self.scratch = scratch
        self.preparedAssets = preparedAssets
    }

    deinit { try? FileManager.default.removeItem(at: scratch) }
}

/// Produces one exact-length source-grid stream for player, MP4 and edited WAV readers.
/// Every file read and write is limited to a 4096-frame buffer, except the stored 0.5 s room run.
enum VoiceLabAudioRenderer {
    private static let block = 4096

    static func stage(request: RenderRequest, isolation: isolated (any Actor)? = #isolation) async throws -> VoiceLabRenderLease {
        try VoiceLabRenderPreflight.validate(request)
        guard let input = request.voiceLab else { throw VoiceLabAssetError.invalidSelection("render input") }
        try input.prepared.verify(project: input.project, scope: input.scope, labelPosition: input.labelPosition)
        let plan = input.prepared.outputPlan
        guard plan.requiresSyntheticRendering, plan.outputSamples > 0,
              plan.sampleRate.isFinite, plan.sampleRate.rounded() == plan.sampleRate,
              plan.sampleRate >= 8_000, plan.sampleRate <= 192_000 else {
            throw VoiceLabAssetError.invalidSelection("output plan")
        }
        let estimate = try scratchEstimate(input: input)
        let temporaryRoot = FileManager.default.temporaryDirectory
        try reserveDisk(temporaryRoot, frames: estimate.frames, additionalBytes: estimate.snapshots)
        let prepared = try VoiceLabAssets.prepare(project: input.project, plan: plan, paidRoot: input.paidRoot)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-mix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        do {
            let sourceURL = scratch.appendingPathComponent("source.caf")
            let mixedURL = scratch.appendingPathComponent("mixed.caf")
            let fitURLs = Dictionary(uniqueKeysWithValues: input.prepared.selectedSegmentRecipes.map {
                ($0.segmentId, scratch.appendingPathComponent("fit-\($0.segmentId).caf"))
            })
            let sourceFrames = try await stageSource(request.sourceURL, to: sourceURL, rate: plan.sampleRate,
                                                     totalFrames: plan.totalSourceSamples)
            var remainingFit = estimate.fitFrames
            let items = input.prepared.selectedSegmentRecipes
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                let remainingConformed = items[index...].reduce(Int64(0)) { current, selected in
                    guard let asset = input.project.voiceLab.assets?.first(where: { $0.id == selected.recipe.audio.assetId }) else { return current }
                    return max(current, Int64(ceil((asset.durationSeconds + 1) * plan.sampleRate)))
                }
                try reserveDisk(scratch, frames: plan.outputSamples + remainingFit + remainingConformed)
                guard let asset = prepared[item.segmentId], let url = fitURLs[item.segmentId] else {
                    throw VoiceLabAssetError.invalidSelection(item.segmentId)
                }
                try stageFit(asset, recipe: item.recipe, outputFrames: item.piece.outputEndSample - item.piece.outputStartSample,
                             rate: plan.sampleRate, to: url, scratch: scratch)
                let (handles, overflow) = item.recipe.seams.in.fadeSamples.addingReportingOverflow(item.recipe.seams.out.fadeSamples)
                guard !overflow else { throw VoxClipError.diskFull(scratch.path) }
                remainingFit -= item.piece.outputEndSample - item.piece.outputStartSample + handles
                try reserveDisk(scratch, frames: plan.outputSamples + remainingFit)
            }
            try mix(plan: plan, selected: input.prepared.selectedSegmentRecipes, prepared: prepared,
                    sourceURL: sourceURL, sourceFrames: sourceFrames, fitURLs: fitURLs, to: mixedURL)
            try Task.checkCancellation()
            return VoiceLabRenderLease(mixedAudioURL: mixedURL, scratch: scratch, preparedAssets: prepared)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    static func scratchBytes(input: VoiceLabRenderInput) throws -> Int64 {
        let estimate = try scratchEstimate(input: input)
        return try DiskCapacity.checkedAdd(
            DiskCapacity.checkedMultiply(estimate.frames, 8, at: input.paidRoot),
            estimate.snapshots, at: input.paidRoot)
    }

    private static func scratchEstimate(input: VoiceLabRenderInput) throws -> (frames: Int64, fitFrames: Int64, snapshots: Int64) {
        let plan = input.prepared.outputPlan
        var estimatedFit: Int64 = 0
        var largestConformed: Int64 = 0
        var snapshotBytes: Int64 = 0
        for item in input.prepared.selectedSegmentRecipes {
            let seam = item.recipe.seams
            let (handles, overflowSeams) = seam.in.fadeSamples.addingReportingOverflow(seam.out.fadeSamples)
            let (withBody, overflowBody) = estimatedFit.addingReportingOverflow(item.piece.outputEndSample - item.piece.outputStartSample)
            let (withHandles, overflowHandles) = withBody.addingReportingOverflow(handles)
            guard !overflowSeams, !overflowBody, !overflowHandles,
                  let asset = input.project.voiceLab.assets?.first(where: { $0.id == item.recipe.audio.assetId }) else {
                throw VoxClipError.diskFull(input.paidRoot.path)
            }
            estimatedFit = withHandles
            let conformed = (asset.durationSeconds + 1) * plan.sampleRate
            guard conformed.isFinite, conformed >= 0, conformed < Double(Int64.max) else {
                throw VoxClipError.diskFull(input.paidRoot.path)
            }
            largestConformed = max(largestConformed, Int64(ceil(conformed)))
            var info = stat()
            if lstat(input.paidRoot.appendingPathComponent(asset.file).path, &info) == 0, info.st_size > 0 {
                let (bytes, overflow) = snapshotBytes.addingReportingOverflow(info.st_size)
                guard !overflow else { throw VoxClipError.diskFull(input.paidRoot.path) }
                snapshotBytes = bytes
            }
        }
        let (first, overflowFirst) = plan.totalSourceSamples.addingReportingOverflow(plan.outputSamples)
        let (withFit, overflowFit) = first.addingReportingOverflow(estimatedFit)
        let (scratchFrames, overflowTotal) = withFit.addingReportingOverflow(largestConformed)
        guard !overflowFirst, !overflowFit, !overflowTotal else { throw VoxClipError.diskFull(input.paidRoot.path) }
        return (scratchFrames, estimatedFit, snapshotBytes)
    }

    private static func reserveDisk(_ url: URL, frames: Int64, additionalBytes: Int64 = 0) throws {
        let bytes = try DiskCapacity.checkedAdd(DiskCapacity.checkedMultiply(frames, 8, at: url), additionalBytes, at: url)
        try DiskCapacity.check([.init(directory: url, bytes: bytes)])
    }

    private static func format(_ rate: Double) throws -> AVAudioFormat {
        guard let result = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true) else {
            throw VoxClipError.decodeFailed("Invalid Voice Lab PCM format")
        }
        return result
    }

    private static func stageSource(_ source: URL, to url: URL, rate: Double, totalFrames: Int64,
                                    isolation: isolated (any Actor)? = #isolation) async throws -> Int64 {
        let reader = try AVAssetReader(asset: AVURLAsset(url: source))
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: totalFrames, timescale: Int32(rate)))
        guard let ownTrack = try await MediaSupport.audioTrack(in: reader.asset) else { throw VoxClipError.noAudioTrack }
        let output = AVAssetReaderTrackOutput(track: ownTrack, outputSettings: MediaSupport.pcm(rate: rate, channels: 2))
        output.alwaysCopiesSampleData = false
        let provider = reader.outputProvider(for: output)
        let pcm = try format(rate)
        let file = try AVAudioFile(forWriting: url, settings: pcm.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(block)),
              let destination = buffer.audioBufferList.pointee.mBuffers.mData else { throw VoxClipError.decodeFailed("Cannot allocate source PCM") }
        guard reader.startReading() else { throw VoxClipError.decodeFailed("Cannot decode Voice Lab source") }
        var written: Int64 = 0
        do {
            while let sample = try await MediaSupport.nextSample(provider) {
                try Task.checkCancellation()
                let count = Int(sample.sampleCount)
                let exactPTS = sample.presentationTimeStamp.seconds * rate
                guard count > 0, exactPTS.isFinite, exactPTS >= 0, exactPTS < Double(Int64.max),
                      count <= totalFrames - written,
                      Int64((exactPTS + 0.5).rounded(.down)) == written else {
                    throw VoxClipError.decodeFailed("Voice Lab source PCM has an unsupported presentation offset, gap or tail")
                }
                try sample.withUnsafeSampleBuffer { raw in
                    guard let data = CMSampleBufferGetDataBuffer(raw),
                          CMBlockBufferGetDataLength(data) == count * 2 * MemoryLayout<Float>.size else {
                        throw VoxClipError.decodeFailed("Source PCM has an unsupported layout")
                    }
                    var offset = 0
                    while offset < count {
                        let frames = min(block, count - offset)
                        let bytes = frames * 2 * MemoryLayout<Float>.size
                        guard CMBlockBufferCopyDataBytes(data, atOffset: offset * 8, dataLength: bytes, destination: destination) == noErr else {
                            throw VoxClipError.decodeFailed("Cannot read source PCM")
                        }
                        buffer.frameLength = AVAudioFrameCount(frames)
                        try file.write(from: buffer)
                        offset += frames
                    }
                }
                written += Int64(count)
            }
            guard reader.status == .completed, written > 0 else { throw VoxClipError.decodeFailed("Source audio did not finish") }
            return written
        } catch {
            reader.cancelReading()
            throw error
        }
    }

    /// Direct native diagnostic path. Production reaches this only after the
    /// capability preflight; tests can measure TimePitch without authorizing it.
    static func stageFit(_ asset: PreparedVoiceLabAsset, recipe: VoiceLabRenderRecipe,
                                 outputFrames: Int64, rate: Double, to url: URL, scratch: URL) throws {
        let incoming = recipe.seams.in.fadeSamples / 2
        let outgoing = recipe.seams.out.fadeSamples - recipe.seams.out.fadeSamples / 2
        func requiredRawFrames(_ output: Int64) throws -> Int64 {
            let exact = Double(output) * Double(asset.sampleRate) / (rate * asset.stretch)
            guard exact.isFinite, exact >= 0, exact < Double(Int64.max) else {
                throw VoiceLabProjectError.invalidFadeHandles
            }
            let nearest = exact.rounded()
            return Int64(abs(exact - nearest) <= 4 * exact.ulp ? nearest : ceil(exact))
        }
        let neededPre = try requiredRawFrames(incoming)
        let neededPost = try requiredRawFrames(outgoing)
        // JSON may round an exact ratio by one ULP; a real fit, however small,
        // must still pass through TimePitch.
        let unity = abs(asset.stretch - 1) <= 4 * Double.ulpOfOne
        // Keep available declared lead audio as TimePitch preroll, then remove only the
        // corresponding fitted output. This lets the unit settle before the visible seam.
        let rawPre = unity ? neededPre : min(asset.trimStartFrame, recipe.seams.in.assetHandleFrames)
        let rawPost = unity ? neededPost : min(asset.frameCount - asset.trimEndFrame, recipe.seams.out.assetHandleFrames)
        let exactPreroll = Double(rawPre - neededPre) * rate * asset.stretch / Double(asset.sampleRate)
        guard exactPreroll.isFinite, exactPreroll >= 0, exactPreroll < Double(Int64.max) else {
            throw VoiceLabProjectError.invalidFadeHandles
        }
        let prerollFrames = unity ? Int64(0) : Int64(EditingPrimitives.jsRound(exactPreroll))
        guard neededPre <= asset.trimStartFrame, neededPost <= asset.frameCount - asset.trimEndFrame,
              neededPre <= recipe.seams.in.assetHandleFrames, neededPost <= recipe.seams.out.assetHandleFrames,
              prerollFrames >= 0,
              outputFrames > 0, outputFrames <= Int64.max - incoming - outgoing else {
            throw VoiceLabProjectError.invalidFadeHandles
        }
        let conformedURL = scratch.appendingPathComponent("conformed-\(asset.segmentId).caf")
        try conform(asset: asset, start: asset.trimStartFrame - rawPre,
                    frames: asset.trimEndFrame - asset.trimStartFrame + rawPre + rawPost,
                    rate: rate, to: conformedURL)
        let sourceFile = try AVAudioFile(forReading: conformedURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard sourceFile.length > 0 else { throw VoxClipError.decodeFailed("Fitted asset has no samples") }
        defer { try? FileManager.default.removeItem(at: conformedURL) }
        if unity {
            let expected = outputFrames + incoming + outgoing
            guard sourceFile.length == expected else {
                throw VoxClipError.decodeFailed("Conformed generated audio changed its trim grid")
            }
            try FileManager.default.copyItem(at: conformedURL, to: url)
            return
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = Float(Double(asset.trimEndFrame - asset.trimStartFrame) / Double(asset.sampleRate) /
                           (Double(outputFrames) / rate))
        pitch.pitch = 0
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: sourceFile.processingFormat)
        engine.connect(pitch, to: engine.mainMixerNode, format: sourceFile.processingFormat)
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw VoxClipError.decodeFailed("Cannot configure pitch-preserving fit")
        }
        try engine.enableManualRenderingMode(.offline, format: pcm, maximumFrameCount: AVAudioFrameCount(block))
        try engine.start()
        defer { player.stop(); engine.stop(); engine.disableManualRenderingMode() }
        player.scheduleFile(sourceFile, at: nil)
        player.play()
        do {
            let file = try AVAudioFile(forWriting: url, settings: pcm.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(block)) else {
                throw VoxClipError.decodeFailed("Cannot allocate fitted audio")
            }
            var remaining = outputFrames + incoming + outgoing
            var skip = prerollFrames
            while remaining > 0 {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(Int64(block), skip > 0 ? skip : remaining))
                let status = try engine.renderOffline(count, to: buffer)
                guard status == .success, buffer.frameLength > 0 else {
                    throw VoxClipError.decodeFailed("Pitch-preserving fit did not produce the planned audio")
                }
                if skip > 0 { skip -= Int64(buffer.frameLength) }
                else {
                    try file.write(from: buffer)
                    remaining -= Int64(buffer.frameLength)
                }
            }
            guard file.length == outputFrames + incoming + outgoing else {
                throw VoxClipError.decodeFailed("Pitch-preserving fit changed the output count")
            }
        }
    }

    private static func conform(asset: PreparedVoiceLabAsset, start: Int64, frames: Int64,
                                rate: Double, to url: URL) throws {
        let source = try AVAudioFile(forReading: asset.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard start >= 0, frames > 0, start <= source.length, frames <= source.length - start,
              let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let converter = AVAudioConverter(from: source.processingFormat, to: target),
              let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(block)) else {
            throw VoiceLabProjectError.invalidFadeHandles
        }
        source.framePosition = start
        let input = VoiceLabConversionInput(file: source, remaining: frames)
        let output = try AVAudioFile(forWriting: url, settings: target.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        var noProgress = 0
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { packets, inputStatus in
                input.next(packets: packets, status: inputStatus)
            }
            if let error = input.error ?? conversionError { throw error }
            if buffer.frameLength > 0 { try output.write(from: buffer) }
            if status == .endOfStream { break }
            if status == .error { throw VoxClipError.decodeFailed("Cannot conform generated audio") }
            noProgress = buffer.frameLength == 0 ? noProgress + 1 : 0
            if noProgress > 3 { throw VoxClipError.decodeFailed("Generated audio conversion made no progress") }
        }
    }

    private struct SeamWindow {
        let start: Int64
        let samples: [Float]
        var end: Int64 { start + Int64(samples.count / 2) }
    }

    private static func mix(plan: VoiceLabOutputPlan, selected: [VoiceLabSelectedRecipe],
                            prepared: [String: PreparedVoiceLabAsset], sourceURL: URL, sourceFrames: Int64,
                            fitURLs: [String: URL], to url: URL) throws {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: plan.sampleRate, channels: 2) else {
            throw VoxClipError.decodeFailed("Cannot configure mixed audio")
        }
        let source = try AVAudioFile(forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let recipes = Dictionary(uniqueKeysWithValues: selected.map { ($0.segmentId, $0.recipe) })
        let output = try AVAudioFile(forWriting: url, settings: pcm.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(block)),
              let channels = buffer.floatChannelData else { throw VoxClipError.decodeFailed("Cannot allocate mixed audio") }
        for (index, piece) in plan.pieces.enumerated() {
            try Task.checkCancellation()
            let windows = try [index > 0 ? makeSeam(left: plan.pieces[index - 1], right: piece, plan: plan,
                                                    source: source, sourceFrames: sourceFrames, fitURLs: fitURLs, recipes: recipes) : nil,
                               index + 1 < plan.pieces.count ? makeSeam(left: piece, right: plan.pieces[index + 1], plan: plan,
                                                                          source: source, sourceFrames: sourceFrames, fitURLs: fitURLs, recipes: recipes) : nil].compactMap { $0 }
            let length = piece.outputEndSample - piece.outputStartSample
            let audio: AVAudioFile
            let offset: Int64
            if piece.kind == .source {
                guard piece.sourceEndSample <= sourceFrames else { throw VoxClipError.decodeFailed("Source audio ends before selected range") }
                audio = source; offset = piece.sourceStartSample
            } else {
                guard let id = piece.segmentId, let url = fitURLs[id], let recipe = recipes[id], prepared[id] != nil else {
                    throw VoiceLabAssetError.invalidSelection(piece.segmentId ?? "segment")
                }
                audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                offset = recipe.seams.in.fadeSamples / 2
            }
            let tone: [Float]?
            let toneGain: Float
            if piece.kind == .synth, let id = piece.segmentId, let room = recipes[id]?.roomTone {
                tone = try read(source, start: room.sourceStartSample, count: Int(room.sourceEndSample - room.sourceStartSample))
                toneGain = Float(pow(10, room.gainDb / 20))
            } else { tone = nil; toneGain = 0 }
            let synthGain: Float = piece.kind == .synth ? Float(pow(10, (recipes[piece.segmentId ?? ""]?.audio.gainDb ?? 0) / 20)) : 1
            let generatedBefore = index > 0 && plan.pieces[index - 1].kind == .synth
            let generatedAfter = index + 1 < plan.pieces.count && plan.pieces[index + 1].kind == .synth
            var position: Int64 = 0
            while position < length {
                try Task.checkCancellation()
                let count = Int(min(Int64(block), length - position))
                audio.framePosition = offset + position
                try audio.read(into: buffer, frameCount: AVAudioFrameCount(count))
                guard buffer.frameLength == count else { throw VoxClipError.decodeFailed("Selected audio ended before its planned span") }
                for frame in 0..<count {
                    let absolute = piece.outputStartSample + position + Int64(frame)
                    var gain = synthGain
                    if piece.kind == .source {
                        gain = ordinarySourceGain(local: position + Int64(frame), length: length, rate: plan.sampleRate,
                                                 fadeIn: !generatedBefore && piece.sourceStartSample > 0,
                                                 fadeOut: !generatedAfter && piece.sourceEndSample < plan.totalSourceSamples)
                    }
                    for channel in 0..<2 {
                        channels[channel][frame] *= gain
                        if let tone { channels[channel][frame] += toneSample(tone, at: position + Int64(frame), channel: channel, rate: plan.sampleRate) * toneGain }
                    }
                    if let seam = windows.first(where: { absolute >= $0.start && absolute < $0.end }) {
                        let slot = Int(absolute - seam.start) * 2
                        channels[0][frame] = seam.samples[slot]
                        channels[1][frame] = seam.samples[slot + 1]
                    }
                }
                try output.write(from: buffer)
                position += Int64(count)
            }
        }
        guard output.length == plan.outputSamples else { throw VoxClipError.decodeFailed("Voice Lab mix has the wrong sample count") }
    }

    private static func toneSample(_ tone: [Float], at frame: Int64, channel: Int, rate: Double) -> Float {
        let total = tone.count / 2
        let fade = min(total / 2, Int(EditingPrimitives.jsRound(0.05 * rate)))
        let period = total - fade
        if frame >= 0 && frame < Int64(period) { return tone[Int(frame) * 2 + channel] }
        let index = Int(((frame % Int64(period)) + Int64(period)) % Int64(period))
        guard index < fade else { return tone[index * 2 + channel] }
        let u = Double(index) / Double(max(1, fade - 1))
        return tone[(period + index) * 2 + channel] * Float(cos(.pi * u / 2)) +
            tone[index * 2 + channel] * Float(sin(.pi * u / 2))
    }

    /// Editing §7.7 applies independently to every retained source run, including clip edges.
    /// A generated seam replaces only the fade on the boundary it covers.
    static func ordinarySourceGain(local: Int64, length: Int64, rate: Double,
                                   fadeIn: Bool, fadeOut: Bool) -> Float {
        let fade = min(Int64(EditingPrimitives.jsRound(0.005 * rate)), length / 2)
        guard fade > 0 else { return 1 }
        var gain: Float = 1
        if fadeIn && local < fade { gain *= Float(local) / Float(fade) }
        let remaining = length - 1 - local
        if fadeOut && remaining < fade { gain *= Float(remaining) / Float(fade) }
        return gain
    }

    private static func read(_ file: AVAudioFile, start: Int64, count: Int) throws -> [Float] {
        guard start >= 0, count >= 0, start + Int64(count) <= file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else {
            throw VoiceLabProjectError.invalidFadeHandles
        }
        file.framePosition = start
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard buffer.frameLength == count, let data = buffer.floatChannelData else {
            throw VoxClipError.decodeFailed("Cannot read seam handle")
        }
        var samples = [Float](repeating: 0, count: count * 2)
        for frame in 0..<count {
            samples[frame * 2] = data[0][frame]
            samples[frame * 2 + 1] = data[1][frame]
        }
        return samples
    }

    private static func makeSeam(left: VoiceLabOutputPiece, right: VoiceLabOutputPiece, plan: VoiceLabOutputPlan,
                                 source: AVAudioFile, sourceFrames: Int64, fitURLs: [String: URL],
                                 recipes: [String: VoiceLabRenderRecipe]) throws -> SeamWindow? {
        guard left.kind == .synth || right.kind == .synth else { return nil }
        try Task.checkCancellation()
        let recipe = right.kind == .synth ? recipes[right.segmentId ?? ""] : recipes[left.segmentId ?? ""]
        guard let recipe else { throw VoiceLabProjectError.invalidFadeHandles }
        let seam = right.kind == .synth ? recipe.seams.in : recipe.seams.out
        guard seam.kind != .none else { return nil }
        let n = Int(seam.fadeSamples), half = n / 2, after = n - half
        guard n >= 2, left.outputEndSample == right.outputStartSample else { throw VoiceLabProjectError.invalidFadeHandles }
        func sourceHandle() throws -> [Float] {
            guard left.sourceEndSample >= Int64(half), right.sourceStartSample + Int64(after) <= sourceFrames else {
                throw VoiceLabProjectError.invalidFadeHandles
            }
            return try read(source, start: left.sourceEndSample - Int64(half), count: half) +
                read(source, start: right.sourceStartSample, count: after)
        }
        func fittedHandle(_ piece: VoiceLabOutputPiece, incoming: Bool) throws -> [Float] {
            guard let id = piece.segmentId, let url = fitURLs[id], let recipe = recipes[id] else {
                throw VoiceLabProjectError.invalidFadeHandles
            }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let start: Int64
            let bodyOffset: Int64
            if incoming {
                start = 0
                bodyOffset = -Int64(half)
            } else {
                let post = recipe.seams.out.fadeSamples - recipe.seams.out.fadeSamples / 2
                start = file.length - post - Int64(half)
                bodyOffset = piece.outputEndSample - piece.outputStartSample - Int64(half)
            }
            return try synthSignal(read(file, start: start, count: n), recipe: recipe,
                                   bodyOffset: bodyOffset, source: source, rate: plan.sampleRate)
        }
        let lhs = left.kind == .synth ? try fittedHandle(left, incoming: false) : try sourceHandle()
        let rhs = right.kind == .synth ? try fittedHandle(right, incoming: true) : try sourceHandle()
        return SeamWindow(start: right.outputStartSample - Int64(half), samples: crossfade(lhs, rhs, n: n))
    }

    private static func synthSignal(_ samples: [Float], recipe: VoiceLabRenderRecipe, bodyOffset: Int64,
                                    source: AVAudioFile, rate: Double) throws -> [Float] {
        var output = samples
        let gain = Float(pow(10, recipe.audio.gainDb / 20))
        let tone = try recipe.roomTone.map { try read(source, start: $0.sourceStartSample,
                                                      count: Int($0.sourceEndSample - $0.sourceStartSample)) }
        let toneGain = Float(pow(10, (recipe.roomTone?.gainDb ?? 0) / 20))
        for frame in 0..<(samples.count / 2) {
            try Task.checkCancellation()
            for channel in 0..<2 {
                let slot = frame * 2 + channel
                output[slot] *= gain
                if let tone {
                    output[slot] += toneSample(tone, at: bodyOffset + Int64(frame), channel: channel,
                                               rate: rate) * toneGain
                }
            }
        }
        return output
    }

    private static func crossfade(_ left: [Float], _ right: [Float], n: Int) -> [Float] {
        var result = [Float](repeating: 0, count: n * 2)
        for frame in 0..<n {
            let u = Double(frame) / Double(n - 1)
            let a = Float(cos(.pi * u / 2)), b = Float(sin(.pi * u / 2))
            for channel in 0..<2 { result[frame * 2 + channel] = left[frame * 2 + channel] * a + right[frame * 2 + channel] * b }
        }
        return result
    }
}

private final class VoiceLabConversionInput: @unchecked Sendable {
    private let lock = NSLock()
    private let file: AVAudioFile
    private var remaining: Int64
    private var failure: (any Error)?
    init(file: AVAudioFile, remaining: Int64) { self.file = file; self.remaining = remaining }
    var error: (any Error)? { lock.lock(); defer { lock.unlock() }; return failure }
    func next(packets: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock(); defer { lock.unlock() }
        if Task<Never, Never>.isCancelled {
            failure = CancellationError(); status.pointee = .endOfStream; return nil
        }
        guard failure == nil, remaining > 0 else { status.pointee = .endOfStream; return nil }
        let count = AVAudioFrameCount(min(Int64(packets), 4096, remaining))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
            failure = VoxClipError.decodeFailed("Cannot allocate generated audio block")
            status.pointee = .endOfStream; return nil
        }
        do {
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { throw VoxClipError.decodeFailed("Generated audio ended before its trim") }
            remaining -= Int64(buffer.frameLength)
            status.pointee = .haveData
            return buffer
        } catch {
            failure = error; status.pointee = .endOfStream; return nil
        }
    }
}
