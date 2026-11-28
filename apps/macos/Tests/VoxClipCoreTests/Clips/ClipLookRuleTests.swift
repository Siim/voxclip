import Foundation
import Testing
@testable import VoxClipCore

/// Replays shared/fixtures/looks/look-cases.json (looks spec §8.3 and §9.6); the C# twin `ClipLookRuleTests` replays the
/// same file.
@Suite(.offlineFixtures) struct ClipLookRuleTests {
    static func cases() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/looks/look-cases.json")) }
    static func controls(_ value: JSONValue) throws -> ProjectClipControls {
        try ProjectJSON.decoder().decode(ProjectClipControls.self, from: JSONEncoder().encode(value))
    }

    @Test func aClipsColorStateMatchesItsLookAppliedOrEdited() throws {
        let looks = try ClipLookLibraryTests.library()
        let corpus = try Self.cases()
        #expect(corpus[ai: "format"] == .string("voxclip-look-cases/1"))
        let cases = corpus[ai: "match"].aiArray
        #expect(cases.count == 18)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            let controls = try Self.controls(item[ai: "controls"])
            let match = looks.match(controls)
            #expect(match?.look.id == item[ai: "look"].aiString, "\(id)")
            switch match {
            case .applied: #expect(item[ai: "state"] == .string("applied"), "\(id)")
            case .edited: #expect(item[ai: "state"] == .string("edited"), "\(id)")
            case nil: #expect(item[ai: "state"] == .null, "\(id)")
            }
            #expect(looks.name(for: controls) == item[ai: "name"].aiString, "\(id)")
        }
    }

    @Test func settingALookWritesItsExpandedValuesAsOneChange() throws {
        let looks = try ClipLookLibraryTests.library()
        let base = try ProjectJSON.decode(FixtureLoader.data(ClipControlsProjectWireTests.fixture))
        let cases = try Self.cases()[ai: "setLookPreset"].aiArray
        #expect(cases.count == 14)
        for item in cases {
            let id = item[ai: "id"].aiString ?? ""
            var project = base
            project.clipControls = []
            if item[ai: "before"] != .null { project = try ClipControlsProject.setting(Self.controls(item[ai: "before"]), in: project) }
            let fix = item[ai: "fix"] == .null ? nil : ClipColorFix(exposure: item[ai: "fix"][ai: "exposure"].aiInt ?? 0,
                                                                     temperature: item[ai: "fix"][ai: "temperature"].aiInt ?? 0,
                                                                     tint: item[ai: "fix"][ai: "tint"].aiInt ?? 0)
            func run() throws -> Project {
                try ClipControlsProject.settingLookPreset(id: item[ai: "look"].aiString ?? "", amount: item[ai: "amount"].aiInt ?? 100, fix: fix,
                                                          clipId: "clip-main", in: project, looks: looks)
            }
            if item[ai: "refused"] == .bool(true) {
                #expect(throws: ClipControlsProjectError.unknownLook, "\(id)") { try run() }
                continue
            }
            let result = try run()
            let expected = item[ai: "after"] == .null ? nil : try Self.controls(item[ai: "after"])
            #expect(result.clipControls.first { $0.clipId == "clip-main" } == expected, "\(id)")
            #expect(result.schemaVersion == item[ai: "schemaVersion"].aiInt, "\(id)")
            let saved = try JSONDecoder().decode(JSONValue.self, from: ProjectJSON.encode(result))
            let entry = saved[ai: "clipControls"].aiArray.first ?? .null
            #expect(entry == item[ai: "after"], "\(id): written as the vector writes it")
        }
    }
}
