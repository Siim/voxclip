import Darwin
import Foundation
import Testing
@testable import VoxClipCore

@Suite struct LocalDirectoryTests {
    @Test(arguments: ["/tmp", "/var", "/etc"])
    func systemAliasesOpenTheSameDirectoryAsTheirNativePath(path: String) throws {
        let alias = URL(fileURLWithPath: path, isDirectory: true)
        let native = URL(fileURLWithPath: "/private" + path, isDirectory: true)
        let first = try LocalDirectory.openNoFollow(alias)
        defer { close(first) }
        let second = try LocalDirectory.openNoFollow(native)
        defer { close(second) }
        var lhs = stat(), rhs = stat()
        #expect(fstat(first, &lhs) == 0 && fstat(second, &rhs) == 0)
        #expect(lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino)
    }

    @Test func userSymlinksRemainRefusedAtEveryDepth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-no-follow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual/child", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual.deletingLastPathComponent())
        for directory in [linked, linked.appendingPathComponent("child")] {
            #expect(throws: POSIXError.self) { try LocalDirectory.openNoFollow(directory) }
        }
        let descriptor = try LocalDirectory.openNoFollow(actual)
        close(descriptor)
    }

    @Test(arguments: ["file:///tmp/project%00name", "https://example.test/tmp", "file://remote/tmp"])
    func invalidAuthoritiesAndEncodedControlNeverOpen(text: String) throws {
        #expect(throws: POSIXError.self) { try LocalDirectory.openNoFollow(#require(URL(string: text))) }
    }
}
