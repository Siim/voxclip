import Foundation

public enum AppVersion {
    public static var current: String {
        resolve(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
    }

    public static var projectWriterVersion: String { resolveProjectWriter(current) }

    static func resolveProjectWriter(_ value: String?) -> String {
        guard let version = value,
              version.range(of: #"\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-beta\.(?:0|[1-9][0-9]*))?\z"#,
                            options: .regularExpression) != nil else { return "0.0.0" }
        return version
    }

    static func resolve(_ value: Any?) -> String {
        guard let version = value as? String,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "unknown" }
        return version
    }
}
