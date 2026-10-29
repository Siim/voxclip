import Foundation
import VoxClipCore

actor VoiceOperationCapability: Equatable {
    private let quote: VoiceLabQuote
    private let validate: @Sendable () async throws -> Void
    private var consumed = false
    init(quote: VoiceLabQuote, validate: @escaping @Sendable () async throws -> Void) {
        self.quote = quote; self.validate = validate
    }
    nonisolated static func == (left: VoiceOperationCapability, right: VoiceOperationCapability) -> Bool { left === right }
    func consume(_ supplied: VoiceLabQuote) async throws {
        guard !consumed, supplied == quote else { throw VoiceLabError.consentRequired }
        consumed = true
        try await validate()
    }
}
