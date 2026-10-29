import Foundation
import VoxClipCore

actor VoiceOperationCapability: Equatable {
    private let quote: VoiceLabQuote
    private let validate: @Sendable () async throws -> Void
    private let reserve: (@Sendable () async throws -> VoiceDispatchPermit)?
    private var consumed = false
    init(quote: VoiceLabQuote, reserve: (@Sendable () async throws -> VoiceDispatchPermit)? = nil, validate: @escaping @Sendable () async throws -> Void) {
        self.quote = quote; self.validate = validate; self.reserve = reserve
    }
    nonisolated static func == (left: VoiceOperationCapability, right: VoiceOperationCapability) -> Bool { left === right }
    func consume(_ supplied: VoiceLabQuote) async throws -> VoiceDispatchPermit? {
        guard !consumed, supplied == quote else { throw VoiceLabError.consentRequired }
        consumed = true
        try await validate()
        return try await reserve?()
    }
}
