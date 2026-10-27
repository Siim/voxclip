import Foundation

public struct Arguments: Equatable, Sendable {
    public var app: String
    public var title: String
    public var output: URL?
    public var codec: String
    public var list: Bool
    public var seconds: Double?

    public static let usage = "sckrec --app <name or bundle ID> --title <substring> --out <file.mp4|file.mov> [--codec hevc|h264] [--seconds N]; sckrec --list [--app <name or bundle ID>]"

    public init(_ args: [String]) throws {
        var values: [String: String] = [:]
        var list = false
        var index = 0
        let options: Set<String> = ["--app", "--title", "--out", "--codec", "--seconds"]
        while index < args.count {
            let option = args[index]
            if option == "--list", !list { list = true; index += 1; continue }
            guard options.contains(option), values[option] == nil, index + 1 < args.count,
                  !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else {
                throw ArgumentError.invalid("Invalid or duplicate option: \(option). \(Self.usage)")
            }
            values[option] = args[index + 1]
            index += 2
        }
        let app = values["--app"] ?? ""
        let title = values["--title"] ?? ""
        let codec = values["--codec"] ?? "hevc"
        guard ["hevc", "h264"].contains(codec) else { throw ArgumentError.invalid("codec must be hevc or h264") }
        let output = values["--out"].map { URL(fileURLWithPath: $0) }
        if !list {
            guard !app.isEmpty, values["--title"] != nil, let output,
                  ["mp4", "mov"].contains(output.pathExtension.lowercased()) else {
                throw ArgumentError.invalid(Self.usage)
            }
        }
        let seconds = values["--seconds"].flatMap(Double.init)
        if values["--seconds"] != nil {
            guard let seconds, seconds.isFinite, seconds > 0 else { throw ArgumentError.invalid("seconds must be finite and positive") }
        }
        self.app = app; self.title = title; self.output = output
        self.codec = codec; self.list = list; self.seconds = seconds
    }
}

public enum ArgumentError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): message } }
}
