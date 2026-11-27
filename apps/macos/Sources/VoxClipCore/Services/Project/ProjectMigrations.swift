import Foundation

enum ProjectMigrations {
    static func forWriting(_ project: Project) throws -> Project {
        try StoryClips.forWriting(TimelineEditFields.promoting(project))
    }

    static func checkVersion(_ value: JSONValue, maximumSupportedVersion: Int = TimelineEditFields.version) throws {
        guard case .object(let object) = value else { try ProjectValidation.fail("expected object") }
        for key in ["format", "schemaVersion"] where object[key] == nil { try ProjectValidation.fail("missing required field", at: key) }
        guard object["format"] == .string("voxclip-project") else { try ProjectValidation.fail("invalid value", at: "format") }
        guard case .number(let version) = object["schemaVersion"], version.isFinite, version.rounded(.towardZero) == version else {
            try ProjectValidation.fail("expected an integer", at: "schemaVersion")
        }
        if version > Double(maximumSupportedVersion) { throw VoxClipError.projectTooNew }
        switch version {
        case 1, 2, 3, 4, 5, 6: return
        default: try ProjectValidation.fail("no migration exists before schema version 1", at: "schemaVersion")
        }
    }
}
