import Foundation

public struct LLMEnvironmentKeyProvider: KeyProvider {
    private let accounts: [String: String]
    public init(catalog: LLMCatalog) {
        self.init(catalog: catalog, environment: ProcessInfo.processInfo.environment)
    }

    init(catalog: LLMCatalog, environment: [String: String]) {
        var accounts: [String: String] = [:]
        for (id, destination) in LLMKeyDestination.pinned {
            let auth = catalog.connector(id)[ai: "auth"]
            guard destination.matches(auth), auth[ai: "debugEnvVar"].aiString == destination.environmentVariable else { continue }
            accounts[destination.account] = environment[destination.environmentVariable]
        }
        self.accounts = accounts
    }
    public func key(for provider: String) async throws -> String? {
        guard let value = accounts[provider] else { return nil }
        let trimmed = AIText.trim(value)
        return trimmed.isEmpty ? nil : trimmed
    }
}
