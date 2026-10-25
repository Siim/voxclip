import Foundation

enum ProjectMigrations {
    static func checkVersion(_ value: JSONValue) throws {
        guard case .object(let object) = value, object["format"] == .string("voxclip-project"),
              case .number(let version) = object["schemaVersion"], version.isFinite, version.rounded(.towardZero) == version else {
            throw VoxClipError.projectUnreadable("Invalid project version")
        }
        switch version {
        case 1: return
        case let newer where newer > 1: throw VoxClipError.projectTooNew
        default: throw VoxClipError.projectUnreadable("No migration exists before schema version 1")
        }
    }
}
