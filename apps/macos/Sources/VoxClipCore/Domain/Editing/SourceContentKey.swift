import CryptoKit
import Foundation

public enum SourceContentKey {
    public static func hash(sizeBytes: Int64, head: Data, tail: Data = Data()) -> String {
        var payload = Data("voxclip-source-v1\n\(sizeBytes)\n".utf8)
        payload.append(head)
        if sizeBytes >= 2_097_152 { payload.append(tail) }
        return sha256(payload)
    }

    /// Lowercase hex SHA-256. Every render preflight keys the source this way (up to 2 MiB), so it uses the system
    /// implementation rather than Swift arithmetic, which is slow in debug builds.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
