import Foundation

enum ProjectMigrations {
    static let currentVersion = 7

    static func forWriting(_ project: Project) throws -> Project {
        if project.media.spokenSources != nil, (1..<currentVersion).contains(project.schemaVersion) {
            var result = project.schemaVersion < 4 ? try ContextDemoProject.upgradeToV4(project) : project
            result.schemaVersion = currentVersion
            return result
        }
        return try StoryClips.forWriting(TimelineEditFields.promoting(project))
    }

    static func checkVersion(_ value: JSONValue, maximumSupportedVersion: Int = currentVersion) throws {
        guard case .object(let object) = value, object["format"] == .string("voxclip-project"),
              case .number(let version) = object["schemaVersion"], version.isFinite, version.rounded(.towardZero) == version else {
            throw VoxClipError.projectUnreadable("Invalid project version")
        }
        if version > Double(maximumSupportedVersion) { throw VoxClipError.projectTooNew }
        switch version {
        case 1, 2, 3, 4, 5, 6, 7: return
        default: throw VoxClipError.projectUnreadable("No migration exists before schema version 1")
        }
    }
}
