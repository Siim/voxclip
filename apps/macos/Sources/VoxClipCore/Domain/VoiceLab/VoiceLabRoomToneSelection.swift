import Foundation

/// §8.7 item 3: the quietest `ROOM_TONE_MIN_RUN` of source audio, chosen on the 10 ms envelope.
public enum VoiceLabRoomToneSelection {
    /// `ROOM_TONE_MIN_RUN` in 10 ms frames.
    static let runFrames = 50

    /// The run of 50 whole frames with the lowest mean power (summed in frame order, in binary64) inside a gap of at least
    /// 0.5 s between transcript items of any kind; leading and trailing silence are gaps. Ties go to the earliest run.
    public static func select(items: [TimedWord], envelope: AudioEnvelope, sourceSampleRate: Double, totalSamples: Int64) throws -> VoiceLabRoomTone {
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
                for frame in Int(index)..<Int(index + frames) {
                    let value = Double(levels[frame])
                    power += value * value
                }
                if best.map({ power < $0.power }) ?? true { best = (power, begin) }
                index += 1
            }
        }
        // No fallback run: v3 needs room tone for passage TTS with Clean audio off, so the UI offers Clean audio instead.
        guard let best else { throw VoiceLabGeometryError.roomToneUnavailable }
        return VoiceLabRoomTone(sourceStartSample: best.start, sourceEndSample: best.start + length, gainDb: 0)
    }
}
