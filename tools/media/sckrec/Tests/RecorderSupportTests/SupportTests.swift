import Foundation
import Testing
@testable import RecorderSupport

@Test func arguments() throws {
    let args = try Arguments(["--app", "Finder", "--title", "Downloads", "--out", "/tmp/voxclip-sol-launch-tooling/finder.mp4"])
    #expect(args.codec == "hevc")
    #expect(args.title == "Downloads")
    #expect(args.output?.lastPathComponent == "finder.mp4")
    #expect(try Arguments(["--list"]).list)
    #expect(try Arguments(["--app", "Finder", "--title", "Test", "--out", "clip.mov", "--codec", "h264", "--seconds", "3"]).seconds == 3)
}

@Test(arguments: [[], ["--app"], ["--list", "--list"], ["--list", "--codec", "vp9"],
                   ["--list", "--seconds", "nan"], ["--list", "--seconds", "-1"],
                   ["--app", "Finder", "--title", "Test", "--out", "clip.png"], ["--list", "--bad", "x"]])
func invalidArguments(_ args: [String]) {
    #expect(throws: ArgumentError.self) { try Arguments(args) }
}

@Test func sidecar() throws {
    var sidecar = Sidecar(startedAt: Date(timeIntervalSince1970: 1_800_000_000), uptime: 42,
                          app: "Finder", title: "Test", windowID: 7, width: 1440, height: 900, codec: "h264")
    sidecar.durationSeconds = 3
    let data = try sidecar.data()
    let repeated = try sidecar.data()
    #expect(data == repeated)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(Sidecar.self, from: data) == sidecar)
    let root = URL(fileURLWithPath: "/tmp/voxclip-sol-launch-tooling", isDirectory: true)
        .appendingPathComponent("sidecar-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("capture.mp4.json")
    defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: root) }
    try sidecar.write(to: file)
    #expect(try Data(contentsOf: file) == data)
    #expect(sidecar.fps == 60)
    #expect(!sidecar.cursorVisible)
}
