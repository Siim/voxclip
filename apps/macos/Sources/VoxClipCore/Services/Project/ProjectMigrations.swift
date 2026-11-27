import Foundation

enum ProjectMigrations {
    static let spokenSourcesVersion = 7
    static let agentThreadVersion = 8
    static let currentVersion = agentThreadVersion

    static func forWriting(_ project: Project) throws -> Project {
        let featureVersion = project.agentThread != nil ? agentThreadVersion : project.media.spokenSources != nil ? spokenSourcesVersion : 1
        if (1..<featureVersion).contains(project.schemaVersion) {
            var result = project.schemaVersion < 4 ? try ContextDemoProject.upgradeToV4(project) : project
            result.schemaVersion = featureVersion
            return result
        }
        return try StoryClips.forWriting(TimelineEditFields.promoting(project))
    }

    static func checkVersion(_ value: JSONValue, maximumSupportedVersion: Int = currentVersion) throws {
        guard case .object(let object) = value else { try ProjectValidation.fail("expected object") }
        for key in ["format", "schemaVersion"] where object[key] == nil { try ProjectValidation.fail("missing required field", at: key) }
        guard object["format"] == .string("voxclip-project") else { try ProjectValidation.fail("invalid value", at: "format") }
        guard case .number(let version) = object["schemaVersion"], version.isFinite, version.rounded(.towardZero) == version else {
            try ProjectValidation.fail("expected an integer", at: "schemaVersion")
        }
        if version > Double(maximumSupportedVersion) { throw VoxClipError.projectTooNew }
        switch version {
        case 1, 2, 3, 4, 5, 6, 7, 8: return
        default: try ProjectValidation.fail("no migration exists before schema version 1", at: "schemaVersion")
        }
    }
}
