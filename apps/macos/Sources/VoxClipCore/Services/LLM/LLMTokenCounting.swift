import Foundation

public protocol LLMTokenCounting: Sendable {
    func tokenCount(for text: String) async throws -> Int
}
