import Foundation
import Testing
@testable import VoxClipMedia

@Suite("native-disk-capacity")
struct DiskCapacityTests {
    @Test func combinesNeedsOnSameVolumeAndAcceptsLessThanFifteenGiB() throws {
        let temp = URL(fileURLWithPath: "/tmp")
        let output = URL(fileURLWithPath: "/output")
        let needs = [DiskCapacity.Need(directory: temp, bytes: 600_000_000),
                     .init(directory: output, bytes: 500_000_000)]
        let same: DiskCapacity.Provider = { _ in .init(id: 1, freeBytes: 1_000_000_000) }
        #expect(throws: (any Error).self) { try DiskCapacity.check(needs, provider: same) }
        let enough: DiskCapacity.Provider = { _ in .init(id: 1, freeBytes: 1_100_000_000) }
        try DiskCapacity.check(needs, provider: enough)
        let different: DiskCapacity.Provider = { url in
            .init(id: url == temp ? 1 : 2, freeBytes: 600_000_000)
        }
        try DiskCapacity.check(needs, provider: different)
    }

    @Test func rejectsOverflowAndInsufficientSpaceOnEitherVolume() throws {
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b")
        let provider: DiskCapacity.Provider = { url in
            .init(id: url == a ? 1 : 2, freeBytes: url == a ? 100 : 50)
        }
        #expect(throws: (any Error).self) {
            try DiskCapacity.check([.init(directory: a, bytes: 80), .init(directory: b, bytes: 51)], provider: provider)
        }
        #expect(throws: (any Error).self) {
            try DiskCapacity.check([.init(directory: a, bytes: Int64.max), .init(directory: a, bytes: 1)], provider: provider)
        }
        #expect(throws: (any Error).self) { _ = try DiskCapacity.checkedMultiply(Int64.max, 8, at: a) }
    }

    @Test func explicitVersionIsUsedAndUnknownVersionIsRejected() throws {
        #expect(try AVExporter.resolvedAppVersion(explicit: "2.4.6") == "2.4.6")
        #expect(throws: (any Error).self) { _ = try AVExporter.resolvedAppVersion(explicit: "") }
        #expect(throws: (any Error).self) { _ = try AVExporter.resolvedAppVersion(explicit: "0.0.0") }
    }
}
