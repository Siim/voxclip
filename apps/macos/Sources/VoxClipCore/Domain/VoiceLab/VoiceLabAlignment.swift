import Foundation

/// §8.8 character alignment to synthetic words, §8.7 item 1 TTS trim and §8.8 step 3 relative word times.
/// The forced-alignment and Scribe fallbacks belong to the later QA pass; a missing alignment is a typed refusal here.
public enum VoiceLabAlignment {
    /// Unicode White_Space, not JS_WHITESPACE (editing §4.5): U+0085 separates words and U+FEFF does not.
    static func isWhiteSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000: true
        default: false
        }
    }
    /// Noncharacters U+FDD0-U+FDEF and U+xFFFE/U+xFFFF. All three implementations refuse them before NFC.
    static func isNoncharacter(_ scalar: Unicode.Scalar) -> Bool { (0xfdd0...0xfdef).contains(scalar.value) || scalar.value & 0xfffe == 0xfffe }

    /// The §8.8 loop over the provider's `alignment` arrays. Times stay on the asset's clock and every word is synthetic.
    public static func words(characters: [String]?, starts: [Double]?, ends: [Double]?, expectedText: String) throws -> [VoiceLabWord] {
        guard let characters, let starts, let ends, !characters.isEmpty, characters.count == starts.count,
              starts.count == ends.count, !characters.contains("") else { throw VoiceLabGeometryError.alignmentUnavailable }
        var words: [VoiceLabWord] = [], buffer = "", start: Double?, end = 0.0
        for index in characters.indices {
            if characters[index].unicodeScalars.allSatisfy(isWhiteSpace) {
                if let first = start, !buffer.isEmpty { words.append(VoiceLabWord(text: buffer, start: first, end: end, synthetic: true)) }
                buffer = ""; start = nil
            } else {
                if start == nil { start = starts[index] }
                buffer += characters[index]; end = ends[index]
            }
        }
        if let first = start, !buffer.isEmpty { words.append(VoiceLabWord(text: buffer, start: first, end: end, synthetic: true)) }
        // editing §4.7 tokens are defined on NFC text, and the provider and the user may send either form.
        // A noncharacter makes the alignment mismatch, as on Windows, where NFC would otherwise throw for U+FFFE.
        func folded(_ token: String) throws -> String {
            guard !token.unicodeScalars.contains(where: isNoncharacter) else { throw VoiceLabGeometryError.alignmentMismatch }
            return EditingPrimitives.normalizeForMatch(EditingPrimitives.nfc(token))
        }
        let derived = try words.map { try folded($0.text) }
        let expected = try expectedText.unicodeScalars.split(whereSeparator: isWhiteSpace).map { try folded(String($0)) }
        // Ordinal comparison, as on Windows; Swift String equality would also accept canonically equivalent scalars.
        guard derived.count == expected.count, zip(derived, expected).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else {
            throw VoiceLabGeometryError.alignmentMismatch
        }
        guard !words.isEmpty else { throw VoiceLabGeometryError.alignmentUnavailable }
        return words
    }

    /// `[max(0, firstStart − TTS_TRIM_LEAD), min(assetDuration, lastEnd + TTS_TRIM_TAIL)]` in asset seconds.
    public static func trim(words: [VoiceLabWord], assetDuration: Double) throws -> (start: Double, end: Double) {
        guard assetDuration.isFinite, assetDuration > 0 else { throw VoiceLabGeometryError.invalidInput() }
        guard let first = words.first?.start, let last = words.last?.end else { throw VoiceLabGeometryError.alignmentUnavailable }
        guard first.isFinite, last.isFinite else { throw VoiceLabGeometryError.invalidWordTiming }
        let start = max(0, first - VoiceLabPatchConstants.TTS_TRIM_LEAD)
        let end = min(assetDuration, last + VoiceLabPatchConstants.TTS_TRIM_TAIL)
        guard end > start else { throw VoiceLabGeometryError.invalidWordTiming }
        return (start, end)
    }

    /// Without alignment: the first to the end of the last 10 ms frame above `VOICED_FRAME` on the TTS envelope, widened by
    /// `TTS_TRIM_LEAD` and `TTS_TRIM_TAIL` and clamped to the asset as with alignment.
    public static func trim(envelope: AudioEnvelope, assetDuration: Double) throws -> (start: Double, end: Double) {
        let rate = envelope.sampleRate
        guard assetDuration.isFinite, assetDuration > 0, rate.isFinite, rate > 0,
              envelope.levels.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw VoiceLabGeometryError.invalidInput() }
        let voiced = { (level: Float) in Double(level) > VoiceLabPatchConstants.VOICED_FRAME_LEVEL }
        guard let first = envelope.levels.firstIndex(where: voiced), let last = envelope.levels.lastIndex(where: voiced) else {
            throw VoiceLabGeometryError.noVoicedAudio
        }
        let size = VoiceLabGeometry.frameSize(rate)
        let start = max(0, Double(Int64(first) * size) / rate - VoiceLabPatchConstants.TTS_TRIM_LEAD)
        let end = min(assetDuration, Double(Int64(last + 1) * size) / rate + VoiceLabPatchConstants.TTS_TRIM_TAIL)
        guard end > start else { throw VoiceLabGeometryError.invalidInput() }
        return (start, end)
    }

    /// Recipe words: `(t − trimStart) × stretch`, checked exactly as the v3 render validator checks them.
    public static func relativeWords(words: [VoiceLabWord], trimStart: Double, stretch: Double, outDuration: Double,
                                     sourceSampleRate: Double) throws -> [VoiceLabWord] {
        let rate = sourceSampleRate
        guard trimStart.isFinite, stretch.isFinite, stretch > 0, outDuration.isFinite, outDuration > 0, rate.isFinite, rate > 0,
              outDuration * rate < VoiceLabGeometry.sampleLimit else { throw VoiceLabGeometryError.invalidInput() }
        guard !words.isEmpty else { throw VoiceLabGeometryError.alignmentUnavailable }
        let output = VoiceLabGeometry.samples(outDuration, rate)
        var cursor = 0.0
        return try words.map { word in
            let start = (word.start - trimStart) * stretch, end = (word.end - trimStart) * stretch
            guard !word.text.isEmpty, start.isFinite, end.isFinite, start >= cursor, end > start, end <= outDuration,
                  VoiceLabGeometry.samples(end, rate) > VoiceLabGeometry.samples(start, rate),
                  VoiceLabGeometry.samples(end, rate) <= output else { throw VoiceLabGeometryError.invalidWordTiming }
            cursor = end
            return VoiceLabWord(text: word.text, start: start, end: end, synthetic: true)
        }
    }
}
