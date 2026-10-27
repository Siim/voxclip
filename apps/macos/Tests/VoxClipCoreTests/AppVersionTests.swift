import Foundation
import Testing
@testable import VoxClipCore

struct AppVersionTests {
    @Test func absentVersionIsUnknown() {
        for value in [nil, "", " \n", "\t\r\n", 123] as [Any?] {
            #expect(AppVersion.resolve(value) == "unknown")
            #expect(AppVersion.resolveProjectWriter(AppVersion.resolve(value)) == "0.0.0")
        }
    }

    @Test func explicitVersionIsPreserved() {
        #expect(AppVersion.resolve("9.8.7-beta.2") == "9.8.7-beta.2")
        let linked = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        #expect(AppVersion.current == AppVersion.resolve(linked))
        #expect(AppVersion.projectWriterVersion == AppVersion.resolveProjectWriter(AppVersion.current))
    }
}
