import Foundation

enum ProjectMigrations {
    static func forWriting(_ project: Project) throws -> Project {
        try StoryClips.forWriting(TimelineEditFields.promoting(project))
    }

    static func checkVersion(_ value: JSONValue, maximumSupportedVersion: Int = TimelineEditFields.version) throws {
        guard case .object(let object) = value, object["format"] == .string("voxclip-project"),
              case .number(let version) = object["schemaVersion"], version.isFinite, version.rounded(.towardZero) == version else {
            throw VoxClipError.projectUnreadable("Invalid project version")
        }
        if version > Double(maximumSupportedVersion) { throw VoxClipError.projectTooNew }
        switch version {
        case 1, 2, 3, 4, 5, 6: return
        default: throw VoxClipError.projectUnreadable("No migration exists before schema version 1")
        }
    }
}
