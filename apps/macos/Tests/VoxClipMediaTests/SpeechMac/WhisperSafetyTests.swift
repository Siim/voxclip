import Foundation
import Testing
import VoxClipCore
import whisper
@testable import VoxClipMedia

@Suite("Whisper byte and diagnostic safety", .serialized)
struct WhisperSafetyTests {
    @Test func strayContinuationDoesNotSwallowLaterWords() {
        let pieces = [Data(" Hello".utf8), Data([0x80]), Data(" world".utf8), Data(" again".utf8)].enumerated().map {
            WhisperTokenPiece(bytes: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.5, confidence: 1)
        }
        let tokens = WhisperTokenMapper.tokens(pieces, group: 0, offset: 0, duration: 5)
        #expect(tokens.map(\.text) == ["Hello", "\u{fffd}", "world", "again"])
    }

    @Test func malformedLeadFollowedByASCIIIsDecodedLossily() {
        let pieces = [Data([0xc3, 0x61]), Data(" word".utf8)].enumerated().map {
            WhisperTokenPiece(bytes: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.5, confidence: 1)
        }
        #expect(WhisperTokenMapper.tokens(pieces, group: 0, offset: 0, duration: 3).map(\.text) == ["\u{fffd}a", "word"])
    }

    @Test func incompleteLeadFollowedByASCIIEventuallyFlushes() {
        let pieces = [WhisperTokenPiece(bytes: Data([0xc3]), start: 0.1, end: 0.2, confidence: 1),
                      WhisperTokenPiece(bytes: Data(" word".utf8), start: 0.2, end: 0.8, confidence: 1),
                      WhisperTokenPiece(bytes: Data(" again".utf8), start: 1, end: 1.5, confidence: 1)]
        let tokens = WhisperTokenMapper.tokens(pieces, group: 0, offset: 0, duration: 2)
        #expect(tokens.map(\.text) == ["\u{fffd} word", "again"])
        #expect(tokens.first?.start == 0.1)
    }

    @Test func splitFourByteCharacterKeepsFirstTokenStart() {
        let pieces = [WhisperTokenPiece(bytes: Data([0x20, 0xf0, 0x9f]), start: 0.1, end: 0.2, confidence: 1),
                      WhisperTokenPiece(bytes: Data([0x98]), start: 0.2, end: 0.3, confidence: 1),
                      WhisperTokenPiece(bytes: Data([0x80]), start: 0.3, end: 0.4, confidence: 1)]
        let tokens = WhisperTokenMapper.tokens(pieces, group: 0, offset: 2, duration: 1)
        #expect(tokens.map(\.text) == ["😀"])
        #expect(tokens.first?.start == 2.1 && tokens.first?.end == 2.4)
    }

    @Test func nativeDiagnosticsUseInjectedRedactingSinkAtWarn() async {
        let logger = NativeSpeechTestLogger()
        await logger.register(secret: "synthetic-native-secret")
        WhisperDiagnosticLog.install(logger: logger)
        let task = WhisperDiagnosticLog.shared.forward(level: GGML_LOG_LEVEL_ERROR, message: "load failed synthetic-native-secret")
        await task?.value
        #expect(WhisperDiagnosticLog.shared.forward(level: GGML_LOG_LEVEL_DEBUG, message: "not logged") == nil)
        let entries = await logger.entries
        #expect(entries.count == 1)
        #expect(entries.first?.category == "transcribe" && entries.first?.level == .warn)
        #expect(entries.first?.message == "whisper: load failed [REDACTED]")
    }
}

private actor NativeSpeechTestLogger: Redacting {
    private var redactor = Redactor()
    private(set) var entries: [LogEntry] = []
    func register(secret: String) { redactor.register(secret: secret) }
    func redact(_ message: String) -> String { redactor.redact(message) }
    func write(_ entry: LogEntry) { entries.append(LogEntry(level: entry.level, category: entry.category, message: redactor.redact(entry.message))) }
}
