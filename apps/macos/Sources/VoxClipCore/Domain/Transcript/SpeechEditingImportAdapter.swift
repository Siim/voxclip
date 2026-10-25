import Foundation

/// The speech service's view of the editing import pipeline (editing.md §5); mac-editing owns the algorithms.
enum SpeechEditingImportAdapter {
    static func cleanWords(_ words: [RawWord], timing: TimingSource) -> [TimedWord] {
        EditingImport.cleanWords(words, timing: timing)
    }

    static func tightenIntoSound(_ words: [TimedWord], envelope: AudioEnvelope, timing: TimingSource) -> [TimedWord] {
        EditingImport.tightenIntoSound(words, envelope: envelope, timing: timing)
    }

    static func findUnlabeledSpeech(_ words: [TimedWord], envelope: AudioEnvelope, duration: Double? = nil) -> [TimedWord] {
        EditingImport.findUnlabeledSpeech(words, envelope: envelope, duration: duration)
    }

    static func pipeline(_ words: [RawWord], envelope: AudioEnvelope?, timing: TimingSource, verbatim: Bool, duration: Double? = nil) throws -> (words: [TimedWord], refined: Bool) {
        let result = try EditingImport.pipeline(words, envelope: envelope, timing: timing, verbatim: verbatim, duration: duration)
        return (result.words, envelope != nil)
    }
}
