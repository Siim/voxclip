import Foundation

public enum SpeechRuntimeVersion {
    public static var macOS: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }
}
