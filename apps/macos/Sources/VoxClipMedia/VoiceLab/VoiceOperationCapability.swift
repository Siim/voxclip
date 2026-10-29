import Foundation
import VoxClipCore

public typealias VoiceLabDispatchBoundary = @Sendable (@escaping @Sendable () throws -> Void) async throws -> Void

struct VoiceOperationDispatch: Sendable {
    let permit: VoiceDispatchPermit?
    let boundary: VoiceLabDispatchBoundary?
    func start(_ transport: @escaping @Sendable () throws -> Void) async throws {
        let guarded: @Sendable () throws -> Void = {
            try Task.checkCancellation()
            if let permit { try permit.start(transport) } else { try transport() }
        }
        if let boundary { try await boundary(guarded) } else { try guarded() }
    }
    func finish() { permit?.finish() }
}

actor VoiceOperationCapability: Equatable {
    private let quote: VoiceLabQuote
    private let validate: @Sendable () async throws -> Void
    private let reserve: (@Sendable () async throws -> VoiceDispatchPermit)?
    private var consumed = false
    private var boundary: VoiceLabDispatchBoundary?
    init(quote: VoiceLabQuote, reserve: (@Sendable () async throws -> VoiceDispatchPermit)? = nil, validate: @escaping @Sendable () async throws -> Void) {
        self.quote = quote; self.validate = validate; self.reserve = reserve
    }
    nonisolated static func == (left: VoiceOperationCapability, right: VoiceOperationCapability) -> Bool { left === right }
    func bindDispatch(_ boundary: @escaping VoiceLabDispatchBoundary) throws {
        guard !consumed, self.boundary == nil else { throw VoiceLabError.consentRequired }
        self.boundary = boundary
    }
    func consume(_ supplied: VoiceLabQuote) async throws -> VoiceOperationDispatch {
        guard !consumed, supplied == quote else { throw VoiceLabError.consentRequired }
        consumed = true
        try await validate()
        return VoiceOperationDispatch(permit: try await reserve?(), boundary: boundary)
    }
}
