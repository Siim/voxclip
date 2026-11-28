import Foundation

enum ProjectMigrations {
    static let spokenSourcesVersion = 7
    /// The v8 frame (editing §10.1): cut edges (§5.10), the agent thread (ADR-R55) and clip colour grades (looks spec §8.4)
    /// share it.
    static let frameVersion = 8
    static let agentThreadVersion = frameVersion
    static let colorGradeVersion = frameVersion
    static let currentVersion = frameVersion

    /// The version the fields present need: 8 with cut edges, an agent thread or a clip's colour grade, 7 with spoken
    /// recordings, otherwise none (1); story parts and timeline edit fields promote on their own.
    static func requiredVersion(_ project: Project) -> Int {
        if project.agentThread != nil || !project.edits.cutEdges.isEmpty || project.clipControls.contains(where: { $0.colorGrade != nil }) {
            return frameVersion
        }
        return project.media.spokenSources != nil ? spokenSourcesVersion : 1
    }

    /// The version written: raised to `requiredVersion`, and lowered from 7 or 8 once those fields are gone, to 7 with
    /// spoken recordings and otherwise to 6, the timeline edit version every v7 or v8 project already meets.
    static func writtenVersion(_ project: Project) -> Int {
        let required = requiredVersion(project)
        if (1..<required).contains(project.schemaVersion) { return required }
        if project.schemaVersion >= spokenSourcesVersion, project.schemaVersion > required { return max(required, TimelineEditFields.version) }
        return project.schemaVersion
    }

    /// The project at `writtenVersion`, upgraded to the v4 shape when it rises past 3.
    static func framed(_ project: Project) throws -> Project {
        let version = writtenVersion(project)
        guard version != project.schemaVersion else { return project }
        var result = project.schemaVersion < 4 ? try ContextDemoProject.upgradeToV4(project) : project
        result.schemaVersion = version
        return result
    }

    static func forWriting(_ project: Project) throws -> Project {
        try StoryClips.forWriting(TimelineEditFields.promoting(framed(project)))
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
