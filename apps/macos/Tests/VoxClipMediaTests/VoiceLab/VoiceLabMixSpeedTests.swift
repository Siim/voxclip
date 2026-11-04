import AVFoundation
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// `VoiceLabAudioRenderer.mix` walks each piece block by block. These tests hold it to the per-frame mix it replaced,
/// sample for sample: `LegacyVoiceLabMix` below is that implementation, kept here only as the reference.
@Suite("voice-lab-mix-speed", .offlineFixtures)
struct VoiceLabMixSpeedTests {
    /// Seeded random plans: cuts, clip-edge fades, touching takes, crossfades, hard joins with micro-pauses and edge
    /// gain, flat and ramped beds, overlapping seam windows, and samples that include ±0, ±1 and subnormals.
    @Test(.timeLimit(.minutes(3))) func blockMixMatchesThePerFrameMixBitForBit() throws {
        let root = try Self.scratch("random")
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try Self.template()
        var compared = 0, synth = 0, windows = 0
        for seed in UInt64(1)...48 {
            let scenario = try MixScenario.random(seed: seed, template: template, root: root)
            let (legacy, current) = try scenario.render(in: root)
            #expect(legacy.count == current.count && legacy.count == Int(scenario.plan.outputSamples) * 2, "seed \(seed)")
            let mismatch = Self.firstDifference(legacy, current)
            #expect(mismatch == nil, "seed \(seed): first differing sample \(mismatch ?? -1)")
            compared += legacy.count
            synth += scenario.selected.count
            windows += scenario.seamCount
            try scenario.discard()
        }
        print("voicelab-mix-random: \(compared) samples, \(synth) voiced pieces, \(windows) seams")
        #expect(compared > 5_000_000 && synth > 48 && windows > 60)
    }

    /// A realistic Rewrite plan: 60 s of 48 kHz source, five voiced phrases (two of them touching), hard joins with
    /// micro-pauses and edge gain, crossfades, two cuts and room-tone beds, one of them ramped. The output must match the
    /// reference exactly; with VOXCLIP_MIX_BENCHMARK=1 both are timed and the timings printed.
    @Test(.timeLimit(.minutes(5))) func realisticRewritePlanMatchesAndIsTimed() throws {
        let root = try Self.scratch("realistic")
        defer { try? FileManager.default.removeItem(at: root) }
        let scenario = try MixScenario.realistic(template: Self.template(), root: root)
        let (legacy, current) = try scenario.render(in: root)
        #expect(legacy.count == current.count && legacy.count == Int(scenario.plan.outputSamples) * 2)
        let mismatch = Self.firstDifference(legacy, current)
        #expect(mismatch == nil, "first differing sample \(mismatch ?? -1)")
        guard ProcessInfo.processInfo.environment["VOXCLIP_MIX_BENCHMARK"] == "1" else { return }
        func time(_ legacy: Bool) throws -> [Double] {
            try (0..<5).map { run in
                let url = root.appendingPathComponent("timed-\(legacy)-\(run).caf")
                defer { try? FileManager.default.removeItem(at: url) }
                let start = ContinuousClock.now
                try scenario.mix(legacy: legacy, to: url)
                let elapsed = ContinuousClock.now - start
                return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            }.sorted()
        }
        let old = try time(true), new = try time(false)
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let seconds = Double(scenario.plan.outputSamples) / scenario.plan.sampleRate
        print(String(format: "voicelab-mix-benchmark %@: %.1f s output, %d pieces; per-frame min %.4f s median %.4f s; block min %.4f s median %.4f s; %.1fx",
                     configuration, seconds, scenario.plan.pieces.count, old[0], old[2], new[0], new[2], old[2] / new[2]))
    }

    private static func firstDifference(_ lhs: [Float], _ rhs: [Float]) -> Int? {
        lhs.indices.first { $0 >= rhs.count || lhs[$0].bitPattern != rhs[$0].bitPattern }
    }

    private static func scratch(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-mix-speed-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private static func template() throws -> VoiceLabRenderRecipe {
        let project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-render-v3.voxclip"))
        return try #require(project.voiceLab.segments.first?.candidates.first?.recipe)
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct MixScenario {
    let plan: VoiceLabOutputPlan
    let selected: [VoiceLabSelectedRecipe]
    let sourceURL: URL
    let sourceFrames: Int64
    let fitURLs: [String: URL]
    let seamCount: Int

    func mix(legacy: Bool, to url: URL) throws {
        let prepared = Set(selected.map(\.segmentId))
        if legacy {
            try LegacyVoiceLabMix.mix(plan: plan, selected: selected, prepared: prepared, sourceURL: sourceURL,
                                      sourceFrames: sourceFrames, fitURLs: fitURLs, to: url)
        } else {
            try VoiceLabAudioRenderer.mix(plan: plan, selected: selected, prepared: prepared, sourceURL: sourceURL,
                                          sourceFrames: sourceFrames, fitURLs: fitURLs, to: url)
        }
    }

    /// Interleaved output of the reference and of the current mix.
    func render(in root: URL) throws -> (legacy: [Float], current: [Float]) {
        let legacyURL = root.appendingPathComponent("legacy.caf"), currentURL = root.appendingPathComponent("current.caf")
        defer { try? FileManager.default.removeItem(at: legacyURL); try? FileManager.default.removeItem(at: currentURL) }
        try mix(legacy: true, to: legacyURL)
        try mix(legacy: false, to: currentURL)
        return (try Self.samples(legacyURL), try Self.samples(currentURL))
    }

    func discard() throws {
        try FileManager.default.removeItem(at: sourceURL)
        for url in fitURLs.values { try FileManager.default.removeItem(at: url) }
    }

    static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = AVAudioFrameCount(file.length)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: max(1, count)))
        try file.read(into: buffer, frameCount: count)
        let data = try #require(buffer.floatChannelData)
        var result = [Float](repeating: 0, count: Int(count) * 2)
        for frame in 0..<Int(count) { result[frame * 2] = data[0][frame]; result[frame * 2 + 1] = data[1][frame] }
        return result
    }

    static func write(_ url: URL, frames: Int, rate: Double, rng: inout SplitMix64, tone: Bool = false) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        let data = try #require(buffer.floatChannelData)
        var written = 0, phase = Double.random(in: 0..<1, using: &rng)
        let hz = Double.random(in: 90...900, using: &rng)
        while written < frames {
            let count = min(4096, frames - written)
            for frame in 0..<count {
                for channel in 0..<2 {
                    let roll = Int.random(in: 0..<200, using: &rng)
                    let value: Float
                    switch roll {
                    case 0: value = 0
                    case 1: value = -0.0
                    case 2: value = Float.leastNonzeroMagnitude * Float(Int.random(in: 1...4096, using: &rng))
                    case 3: value = -Float.leastNormalMagnitude / 3
                    case 4: value = 1
                    case 5: value = -1
                    default:
                        let wave = Float(sin(2 * .pi * phase)) * (tone ? 0.02 : 0.5)
                        value = wave + Float.random(in: -0.25...0.25, using: &rng) * (tone ? 0.05 : 1)
                    }
                    data[channel][frame] = value
                }
                phase += hz / rate
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            written += count
        }
    }

    private enum Join { case none, crossfade, pause }

    /// One synthetic phrase: its source span and output length, and the join chosen on each side.
    private struct Phrase {
        var sourceStart: Int64, sourceEnd: Int64, outputLength: Int64
        var incoming: Join, outgoing: Join
        var touchesNext = false
    }

    static func random(seed: UInt64, template: VoiceLabRenderRecipe, root: URL) throws -> MixScenario {
        var rng = SplitMix64(state: seed &* 0xA24B_AED4_963E_E407)
        let rate: Double = seed.isMultiple(of: 3) ? 44_100 : 48_000
        func frames(_ low: Double, _ high: Double) -> Int64 { Int64(Double.random(in: low...high, using: &rng) * rate) }
        let total = frames(3, 6)
        var pieces: [(kind: VoiceLabOutputPieceKind, start: Int64, end: Int64, length: Int64, phrase: Phrase?)] = []
        var cursor: Int64 = Bool.random(using: &rng) ? 0 : frames(0.05, 0.3)
        let count = Int.random(in: 1...4, using: &rng)
        var phrase = 0
        while phrase < count {
            let run = frames(0.12, 0.6)
            guard cursor + run + frames(0.6, 0.6) < total else { break }
            pieces.append((.source, cursor, cursor + run, run, nil)); cursor += run
            if Int.random(in: 0..<4, using: &rng) == 0 {
                cursor += frames(0.02, 0.2)
                let next = frames(0.12, 0.3)
                guard cursor + next + frames(0.6, 0.6) < total else { break }
                pieces.append((.source, cursor, cursor + next, next, nil)); cursor += next
            }
            let touching = phrase + 1 < count && Int.random(in: 0..<3, using: &rng) == 0
            for part in 0..<(touching ? 2 : 1) {
                let span = frames(0.15, 0.5)
                guard cursor + span < total else { break }
                let pick: () -> Join = { [.none, .crossfade, .pause][Int.random(in: 0..<3, using: &rng)] }
                let incoming: Join = part == 1 ? .crossfade : pick()
                let outgoing: Join = touching && part == 0 ? .crossfade : pick()
                pieces.append((.synth, cursor, cursor + span, frames(0.15, 0.9),
                               Phrase(sourceStart: cursor, sourceEnd: cursor + span, outputLength: 0,
                                      incoming: incoming, outgoing: outgoing, touchesNext: touching && part == 0)))
                cursor += span
                phrase += 1
            }
        }
        if cursor < total {
            let end = Bool.random(using: &rng) ? total : min(total, cursor + frames(0.12, 0.5))
            pieces.append((.source, cursor, end, end - cursor, nil))
        }
        return try build(pieces: pieces, rate: rate, total: total, template: template, root: root, name: "seed-\(seed)", rng: &rng)
    }

    static func realistic(template: VoiceLabRenderRecipe, root: URL) throws -> MixScenario {
        var rng = SplitMix64(state: 60)
        let rate = 48_000.0
        func at(_ seconds: Double) -> Int64 { Int64(seconds * rate) }
        typealias Piece = (kind: VoiceLabOutputPieceKind, start: Int64, end: Int64, length: Int64, phrase: Phrase?)
        func source(_ from: Double, _ to: Double) -> Piece { (.source, at(from), at(to), at(to) - at(from), nil) }
        func voiced(_ from: Double, _ to: Double, out: Double, _ incoming: Join, _ outgoing: Join, touches: Bool = false) -> Piece {
            (.synth, at(from), at(to), at(out),
             Phrase(sourceStart: at(from), sourceEnd: at(to), outputLength: 0, incoming: incoming, outgoing: outgoing, touchesNext: touches))
        }
        let pieces: [Piece] = [
            source(0, 6.2), voiced(6.2, 8.9, out: 2.6, .pause, .pause),
            source(8.9, 15.4), source(15.9, 21), voiced(21, 23.2, out: 2.45, .crossfade, .crossfade),
            source(23.2, 32.5), voiced(32.5, 34.8, out: 2.3, .crossfade, .pause),
            source(34.8, 41), source(41.6, 46.3), voiced(46.3, 48.1, out: 1.9, .pause, .crossfade, touches: true),
            voiced(48.1, 50.6, out: 2.7, .crossfade, .crossfade), source(50.6, 60),
        ]
        return try build(pieces: pieces, rate: rate, total: at(60), template: template, root: root, name: "realistic", rng: &rng,
                         realistic: true)
    }

    private static func build(pieces: [(kind: VoiceLabOutputPieceKind, start: Int64, end: Int64, length: Int64, phrase: Phrase?)],
                              rate: Double, total: Int64, template: VoiceLabRenderRecipe, root: URL, name: String,
                              rng: inout SplitMix64, realistic: Bool = false) throws -> MixScenario {
        let sourceURL = root.appendingPathComponent("\(name)-source.caf")
        try write(sourceURL, frames: Int(total), rate: rate, rng: &rng)
        var output: Int64 = 0
        var planned: [VoiceLabOutputPiece] = []
        for (index, piece) in pieces.enumerated() {
            let id = piece.kind == .synth ? "\(name)-segment-\(index)" : nil
            planned.append(VoiceLabOutputPiece(kind: piece.kind, sourceStartSample: piece.start, sourceEndSample: piece.end,
                                               outputStartSample: output, outputEndSample: output + piece.length,
                                               segmentId: id, assetId: id, audio: nil))
            output += piece.length
        }
        let plan = VoiceLabOutputPlan(sampleRate: rate, totalSourceSamples: total, pieces: planned, captions: [], scope: .full)
        // Each touching pair shares one crossfade length, as the planner does.
        var shared: [Int: Int64] = [:]
        for (index, piece) in pieces.enumerated() where piece.phrase?.touchesNext == true {
            shared[index] = realistic ? 1_152 : Int64.random(in: 2...1_400, using: &rng)
        }
        var selected: [VoiceLabSelectedRecipe] = []
        var fitURLs: [String: URL] = [:]
        var seamCount = 0
        for (index, piece) in planned.enumerated() where piece.kind == .synth {
            guard let phrase = pieces[index].phrase, let id = piece.segmentId else { continue }
            let length = piece.outputEndSample - piece.outputStartSample
            let duration = Double(length) / rate * (realistic || Bool.random(using: &rng) ? 1 : Double.random(in: 0.97...1.03, using: &rng))
            let before = index > 0 ? planned[index - 1] : nil
            let after = index + 1 < planned.count ? planned[index + 1] : nil
            func seam(_ join: Join, incoming: Bool) -> VoiceLabSeam {
                let neighbour = incoming ? before : after
                let synthNeighbour = neighbour?.kind == .synth
                if synthNeighbour {
                    let fade = incoming ? shared[index - 1]! : shared[index]!
                    return .init(kind: .synthToSynth, fadeSamples: fade, sourceHandleSamples: fade / 2, assetHandleFrames: 0)
                }
                switch join {
                case .none:
                    return .init(kind: .none, fadeSamples: realistic ? 0 : Int64.random(in: 0...64, using: &rng), sourceHandleSamples: 0, assetHandleFrames: 0)
                case .crossfade:
                    let fade = realistic ? 1_440 : Int64.random(in: 2...1_500, using: &rng)
                    return .init(kind: .gap, fadeSamples: fade, sourceHandleSamples: fade / 2, assetHandleFrames: 0)
                case .pause:
                    let pause: VoiceLabMicroPause
                    if incoming {
                        let start = realistic ? 0.14 : Double.random(in: 0.01...(duration * 0.4), using: &rng)
                        pause = .init(wordStartSeconds: start, wordEndSeconds: start + (realistic ? 0.3 : Double.random(in: 0.01...(duration * 0.4), using: &rng)))
                    } else {
                        let end = realistic ? -0.14 : -Double.random(in: 0.01...(duration * 0.4), using: &rng)
                        pause = .init(wordStartSeconds: end - (realistic ? 0.3 : Double.random(in: 0.01...(duration * 0.4), using: &rng)), wordEndSeconds: end)
                    }
                    return .init(kind: .hard, fadeSamples: 576, sourceHandleSamples: 288, assetHandleFrames: 240, microPause: pause)
                }
            }
            var recipe = template
            recipe.outDuration = duration
            recipe.audio.gainDb = realistic ? -1.5 : Double.random(in: -12...6, using: &rng)
            recipe.words = [.init(text: "we", start: 0.1, end: duration / 2, synthetic: true),
                            .init(text: "ship", start: duration / 2, end: duration - 0.1, synthetic: true)]
            recipe.seams = .init(in: seam(phrase.incoming, incoming: true), out: seam(phrase.outgoing, incoming: false))
            let roll = realistic ? index % 3 : Int.random(in: 0..<3, using: &rng)
            if roll > 0 {
                let toneLength = realistic ? at(0.5, rate) : Int64.random(in: at(0.11, rate)...at(0.5, rate), using: &rng)
                let toneStart = Int64.random(in: 0...(total - toneLength), using: &rng)
                recipe.roomTone = .init(sourceStartSample: toneStart, sourceEndSample: toneStart + toneLength,
                                        gainDb: realistic ? -8 : Double.random(in: -30...6, using: &rng),
                                        endGainDb: roll == 2 ? (realistic ? -3 : Double.random(in: -30...6, using: &rng)) : nil)
            } else {
                recipe.roomTone = nil
            }
            let inPause = recipe.seams.in.microPause, outPause = recipe.seams.out.microPause
            if (inPause != nil || outPause != nil) && (realistic || Bool.random(using: &rng)) {
                recipe.edgeGain = .init(in: inPause.map { .init(gainDb: realistic ? 2 : Double.random(in: 0...6, using: &rng), wordSeconds: $0) },
                                        out: outPause.map { .init(gainDb: realistic ? 3.5 : Double.random(in: 0...6, using: &rng), wordSeconds: $0) })
            } else {
                recipe.edgeGain = nil
            }
            let fitURL = root.appendingPathComponent("\(id).caf")
            let fitFrames = recipe.seams.in.fadeSamples / 2 + length + recipe.seams.out.fadeSamples - recipe.seams.out.fadeSamples / 2
            try write(fitURL, frames: Int(fitFrames), rate: rate, rng: &rng)
            fitURLs[id] = fitURL
            selected.append(VoiceLabSelectedRecipe(segmentId: id, piece: piece, recipe: recipe))
        }
        let recipes = Dictionary(uniqueKeysWithValues: selected.map { ($0.segmentId, $0.recipe) })
        for (left, right) in zip(planned, planned.dropFirst()) {
            if let id = right.segmentId, let recipe = recipes[id] { seamCount += recipe.seams.in.kind == .none ? 0 : 1 }
            else if let id = left.segmentId, let recipe = recipes[id] { seamCount += recipe.seams.out.kind == .none ? 0 : 1 }
        }
        return MixScenario(plan: plan, selected: selected, sourceURL: sourceURL, sourceFrames: total, fitURLs: fitURLs, seamCount: seamCount)
    }

    private static func at(_ seconds: Double, _ rate: Double) -> Int64 { Int64(seconds * rate) }
}

/// The per-frame mix as it stood before the block walk, verbatim, as the bit-exact reference.
private enum LegacyVoiceLabMix {
    private static let block = 4096

    private struct SeamWindow {
        let start: Int64
        let samples: [Float]
        var end: Int64 { start + Int64(samples.count / 2) }
    }

    static func mix(plan: VoiceLabOutputPlan, selected: [VoiceLabSelectedRecipe],
                    prepared: Set<String>, sourceURL: URL, sourceFrames: Int64,
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
                guard let id = piece.segmentId, let url = fitURLs[id], let recipe = recipes[id], prepared.contains(id) else {
                    throw VoiceLabAssetError.invalidSelection(piece.segmentId ?? "segment")
                }
                audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                offset = recipe.seams.in.fadeSamples / 2
            }
            let tone: [Float]?
            let toneGain: Float
            var toneRamp: (VoiceLabRoomTone, Double)?
            if piece.kind == .synth, let id = piece.segmentId, let room = recipes[id]?.roomTone {
                if room.endGainDb != nil, let recipe = recipes[id] { toneRamp = (room, recipe.outDuration * plan.sampleRate) }
                tone = try read(source, start: room.sourceStartSample, count: Int(room.sourceEndSample - room.sourceStartSample))
                toneGain = Float(pow(10, room.gainDb / 20))
            } else { tone = nil; toneGain = 0 }
            let synthGain: Float = piece.kind == .synth ? Float(pow(10, (recipes[piece.segmentId ?? ""]?.audio.gainDb ?? 0) / 20)) : 1
            let generatedBefore = index > 0 && plan.pieces[index - 1].kind == .synth
            let generatedAfter = index + 1 < plan.pieces.count && plan.pieces[index + 1].kind == .synth
            let recipe = piece.kind == .synth ? recipes[piece.segmentId ?? ""] : nil
            let smooth = recipe.map { $0.seams.in.microPause != nil || $0.seams.out.microPause != nil } ?? false
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
                    let seconds = Double(position + Int64(frame)) / plan.sampleRate
                    let voice = smooth ? VoiceLabHardJoin.generatedWeight(seconds: seconds, duration: recipe!.outDuration, incoming: recipe!.seams.in.microPause, outgoing: recipe!.seams.out.microPause) : 1
                    let boost = recipe?.edgeGain.map { pow(10, VoiceLabHardJoin.edgeGainDb(seconds: seconds, duration: recipe!.outDuration, edgeGain: $0) / 20) } ?? 1
                    let bed = toneRamp.map { Float(pow(10, $0.gainDb(atFrame: Double(position + Int64(frame)), of: $1) / 20)) } ?? toneGain
                    let weight = smooth ? VoiceLabHardJoin.bedWeight(seconds: seconds, duration: recipe!.outDuration, words: recipe!.words ?? [], incoming: recipe!.seams.in.microPause, outgoing: recipe!.seams.out.microPause) : 1
                    for channel in 0..<2 {
                        channels[channel][frame] *= gain * Float(voice * boost)
                        if let tone {
                            channels[channel][frame] += toneSample(tone, at: position + Int64(frame), channel: channel, rate: plan.sampleRate) * bed * Float(weight)
                        }
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
        if seam.microPause != nil {
            let incoming = right.kind == .synth
            guard incoming ? left.kind == .source : right.kind == .source else { throw VoiceLabProjectError.invalidFadeHandles }
            let available = incoming ? left.outputEndSample - left.outputStartSample : right.outputEndSample - right.outputStartSample
            let count = Int(VoiceLabHardJoin.sourceFadeFrames(sampleRate: plan.sampleRate, availableSourceSamples: available))
            guard count >= Int(ceil(0.002 * plan.sampleRate)), Int64(count) <= available else { throw VoiceLabProjectError.invalidFadeHandles }
            let sourceStart = incoming ? left.sourceEndSample - Int64(count) : right.sourceStartSample
            var samples = try read(source, start: sourceStart, count: count)
            let tone = try recipe.roomTone.map { try read(source, start: $0.sourceStartSample, count: Int($0.sourceEndSample - $0.sourceStartSample)) }
            for frame in 0..<count {
                let local = incoming ? frame - count : frame
                let relative = incoming ? Int64(local) : left.outputEndSample - left.outputStartSample + Int64(local)
                let weight = VoiceLabHardJoin.sourceWeight(secondsFromJoin: Double(local) / plan.sampleRate, incoming: incoming, fadeSeconds: Double(count) / plan.sampleRate)
                let bed = recipe.roomTone.map { Float(pow(10, $0.gainDb(atFrame: Double(relative), of: recipe.outDuration * plan.sampleRate) / 20)) } ?? 0
                for channel in 0..<2 {
                    let background = tone.map { toneSample($0, at: relative, channel: channel, rate: plan.sampleRate) * bed } ?? 0
                    samples[frame * 2 + channel] = samples[frame * 2 + channel] * Float(weight) + background * Float(sqrt(max(0, 1 - weight * weight)))
                }
            }
            return SeamWindow(start: right.outputStartSample - (incoming ? Int64(count) : 0), samples: samples)
        }
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
            // A seam handle lies just outside the window, where a ramped bed keeps that side's level.
            let bed = recipe.roomTone.flatMap { room in room.endGainDb.map { _ in
                Float(pow(10, room.gainDb(atFrame: Double(bodyOffset + Int64(frame)), of: recipe.outDuration * rate) / 20)) } } ?? toneGain
            for channel in 0..<2 {
                let slot = frame * 2 + channel
                let seconds = Double(bodyOffset + Int64(frame)) / rate
                let smooth = recipe.seams.in.microPause != nil || recipe.seams.out.microPause != nil
                let voice = smooth ? VoiceLabHardJoin.generatedWeight(seconds: seconds, duration: recipe.outDuration, incoming: recipe.seams.in.microPause, outgoing: recipe.seams.out.microPause) : 1
                let boost = pow(10, VoiceLabHardJoin.edgeGainDb(seconds: seconds, duration: recipe.outDuration, edgeGain: recipe.edgeGain) / 20)
                output[slot] *= gain * Float(voice * boost)
                if let tone {
                    let weight = smooth ? VoiceLabHardJoin.bedWeight(seconds: seconds, duration: recipe.outDuration, words: recipe.words ?? [], incoming: recipe.seams.in.microPause, outgoing: recipe.seams.out.microPause) : 1
                    output[slot] += toneSample(tone, at: bodyOffset + Int64(frame), channel: channel,
                                               rate: rate) * bed * Float(weight)
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
