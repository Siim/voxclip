import Foundation
import Security
import LocalAuthentication
import VoxClipCore

actor SecretStore: KeyProvider {
    private let log: any Redacting
    private let service = "com.voxconvo.voxclip"
    init(log: any Redacting) { self.log = log }

    static func account(for provider: String) -> String {
        if provider == "elevenlabs" { return "elevenlabs-api-key" }
        if provider.hasPrefix("llm-api-key-") || provider == "elevenlabs-api-key" { return provider }
        return "llm-api-key-\(provider)"
    }

    func hasKey(for provider: String) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["VOXCLIP_NO_KEYCHAIN"] == "1" {
            let name = provider.replacingOccurrences(of: "llm-api-key-", with: "").replacingOccurrences(of: "-api-key", with: "")
            return !(ProcessInfo.processInfo.environment["VOXCLIP_\(name.uppercased())_API_KEY"] ?? "").isEmpty
        }
        #endif
        var query = baseQuery(provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func key(for provider: String) async throws -> String? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["VOXCLIP_NO_KEYCHAIN"] == "1" {
            let provider = provider.replacingOccurrences(of: "llm-api-key-", with: "").replacingOccurrences(of: "-api-key", with: "")
            let key = ProcessInfo.processInfo.environment["VOXCLIP_\(provider.uppercased())_API_KEY"]
            if let key { await log.register(secret: key) }
            return key
        }
        #endif
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw SecretError.status(status) }
        await log.register(secret: key)
        return key
    }

    func save(_ value: String, for provider: String) async throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        if ProcessInfo.processInfo.environment["VOXCLIP_NO_KEYCHAIN"] == "1" { throw SecretError.disabled }
        #endif
        let query = baseQuery(provider)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretError.status(status) }
            return
        }
        await log.register(secret: key)
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretError.status(status) }
    }

    private func baseQuery(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: Self.account(for: provider)]
    }
}

enum SecretError: LocalizedError {
    case status(OSStatus), disabled
    var errorDescription: String? {
        switch self {
        case .status(let status): "Keychain access failed (\(status))."
        case .disabled: "Keychain is disabled for this debug session. Use VoxClip-specific environment variables."
        }
    }
}

enum KeyedNetwork {
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }
    static let session = URLSession(configuration: configuration())
}
