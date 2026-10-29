import Foundation

public enum LocalServerAddress {
    public static func remoteHost(_ base: String) -> String? {
        let text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard var host = URLComponents(string: text)?.host, !host.isEmpty else { return text }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return isLoopback(host) ? nil : host
    }

    static func isLoopback(_ host: String) -> Bool {
        if host.lowercased() == "localhost" { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return withUnsafeBytes(of: v4) { $0[0] } == 127 }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }
}
