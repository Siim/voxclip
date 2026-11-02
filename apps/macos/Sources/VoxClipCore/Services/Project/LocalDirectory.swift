import Darwin
import Foundation

/// Descriptor-safe directory traversal. Foundation normalizes Darwin's fixed `/private`
/// aliases back to `/var`, `/tmp` and `/etc`, even after resolving symbolic links.
package enum LocalDirectory {
    package static func nativePath(_ url: URL) -> String {
        let path = url.path
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    package static func openNoFollow(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil,
              let decoded = url.absoluteString.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw POSIXError(.EINVAL)
        }
        let components = (nativePath(url) as NSString).pathComponents
        guard components.first == "/", !components.contains("."), !components.contains("..") else {
            throw POSIXError(.EINVAL)
        }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            for component in components.dropFirst() {
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }
}
