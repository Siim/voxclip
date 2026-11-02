import Foundation
import Synchronization
import VoxClipCore

extension ElevenLabsVoiceLab {
    public func approveConversionBatch(id: UUID, quotes: [VoiceLabQuote]) throws {
        guard (1...32).contains(quotes.count), Set(quotes.map(\.id)).count == quotes.count,
              Set(quotes.map(\.requestID)).count == quotes.count,
              quotes.allSatisfy({ $0.operation == .voiceChange && $0.region == region }),
              Set(quotes.map(\.modelID)).count == 1,
              Set(quotes.map(\.endpoint)).count == 1 else { throw VoiceLabError.consentRequired }
        try approveRun(id, quotes: quotes)
    }

    public func discardConversionBatch(id: UUID, quotes: [VoiceLabQuote]) {
        discardRun(id, quotes: quotes)
    }
}

final class VoiceChangeDispatch: Sendable {
    private struct State { var started = false; var closed = false }
    private let state = Mutex(State())
    func start(_ resume: @Sendable () throws -> Void) throws {
        try state.withLock { state in
            guard !state.started, !state.closed else { throw VoiceLabError.consentRequired }
            state.started = true
            try resume()
        }
    }
    func close() { state.withLock { $0.closed = true } }
}
