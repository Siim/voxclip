import Foundation

/// §8.7 item 3: the quietest `ROOM_TONE_MIN_RUN` of source audio, chosen on the 10 ms envelope.
public enum VoiceLabRoomToneSelection {
    /// `ROOM_TONE_MIN_RUN` in 10 ms frames.
    static let runFrames = 50

    public static func neighbouringPause(items: [TimedWord], envelope: AudioEnvelope, sampleRate: Double,
                                        totalSamples: Int64, seam: Int64) -> Range<Int64>? {
        let size = VoiceLabGeometry.frameSize(sampleRate), count = size * 10
        let lower = max(0, seam - Int64(3 * sampleRate)), upper = min(totalSamples - count, seam + Int64(3 * sampleRate))
        guard upper >= lower else { return nil }
        var best: Range<Int64>?, distance = Int64.max
        for start in stride(from: (lower + size - 1) / size * size, through: upper, by: Int(size)) {
            let end = start + count
            guard !items.contains(where: { $0.kind == .word && $0.end > Double(start) / sampleRate && $0.start < Double(end) / sampleRate }),
                  end / size <= envelope.levels.count else { continue }
            let quiet = (Int(start / size)..<Int(end / size)).allSatisfy { Double(envelope.levels[$0]) <= VoiceLabPatchConstants.VOICED_FRAME_LEVEL }
            let candidate = abs(start + count / 2 - seam)
            if quiet && candidate < distance { best = start..<end; distance = candidate }
        }
        return best
    }

    public static func excludeDigitalSilence(items: [TimedWord], envelope: AudioEnvelope, sampleRate: Double,
                                            totalSamples: Int64, window: VoiceLabWindow, hardJoinSmoothing: Bool) -> Bool {
        guard hardJoinSmoothing, window.leftSeam.kind == .hard || window.rightSeam.kind == .hard else { return false }
        let size = VoiceLabGeometry.frameSize(sampleRate)
        return [window.startSample, window.endSample].contains { seam in
            guard let pause = neighbouringPause(items: items, envelope: envelope, sampleRate: sampleRate, totalSamples: totalSamples, seam: seam) else { return false }
            return (Int(pause.lowerBound / size)..<Int(pause.upperBound / size)).contains { envelope.levels[$0] > 0 }
        }
    }

    /// The run of 50 whole frames with the lowest mean power (summed in frame order, in binary64) inside a gap of at least
    /// 0.5 s between transcript items of any kind; leading and trailing silence are gaps. Ties go to the earliest run.
    public static func select(items: [TimedWord], envelope: AudioEnvelope, sourceSampleRate: Double, totalSamples: Int64, excludeDigitalSilence: Bool = false) throws -> VoiceLabRoomTone {
        let rate = sourceSampleRate, total = totalSamples
        try VoiceLabGeometry.check(rate: rate, totalSamples: total, envelope: envelope, items: items)
        let size = VoiceLabGeometry.frameSize(rate), length = VoiceLabGeometry.samples(VoiceLabPatchConstants.ROOM_TONE_MIN_RUN, rate)
        let levels = envelope.levels, frames = Int64(runFrames)
        var bounds: [(start: Int64, end: Int64, order: Int)] = []
        for (order, item) in items.enumerated() {
            bounds.append((VoiceLabGeometry.samples(item.start, rate), VoiceLabGeometry.samples(item.end, rate), order))
        }
        bounds.sort { $0.start == $1.start ? $0.order < $1.order : $0.start < $1.start }
        var gaps: [(start: Int64, end: Int64)] = [], cursor: Int64 = 0
        for item in bounds {
            if min(item.start, total) > cursor { gaps.append((cursor, min(item.start, total))) }
            cursor = max(cursor, item.end)
        }
        if total > cursor { gaps.append((cursor, total)) }
        var best: (power: Double, start: Int64)?
        for gap in gaps where gap.end - gap.start >= length {
            var index = (gap.start + size - 1) / size
            while index + frames <= Int64(levels.count) {
                let begin = index * size
                if max(begin + frames * size, begin + length) > gap.end { break }
                var power = 0.0
                var containsDigitalSilence = false
                for frame in Int(index)..<Int(index + frames) {
                    let value = Double(levels[frame])
                    power += value * value
                    if value == 0 { containsDigitalSilence = true }
                }
                if (!excludeDigitalSilence || !containsDigitalSilence), best.map({ power < $0.power }) ?? true { best = (power, begin) }
                index += 1
            }
        }
        // No fallback run: v3 needs room tone for passage TTS with Clean audio off, so the UI offers Clean audio instead.
        guard let best else { throw VoiceLabGeometryError.roomToneUnavailable }
        return VoiceLabRoomTone(sourceStartSample: best.start, sourceEndSample: best.start + length, gainDb: 0)
    }
}
