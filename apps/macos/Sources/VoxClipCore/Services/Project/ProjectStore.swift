import Foundation

/// Atomic document I/O and source relinking; editing §10 and architecture §2.5, §7.1.
public protocol ProjectStore: Sendable {
    func load(from url: URL) async throws -> Project
    func save(_ project: Project, to url: URL) async throws
    func resolveSource(for project: Project, projectURL: URL) async throws -> URL
}

public actor JSONProjectStore: ProjectStore {
    public private(set) var loadWarnings: [String] = []
    private let logger: any Logger
    public init() { logger = RedactingLogger(homeDirectory: NSHomeDirectory()) }
    public init(logger: any Logger) { self.logger = logger }
    public func load(from url: URL) async throws -> Project {
        try await loadReportingWarnings(from: url).0
    }

    public func loadReportingWarnings(from url: URL) async throws -> (Project, [String]) {
        do {
            let data = try Data(contentsOf: url)
            let (project, warnings) = try Self.decodeReportingWarnings(data)
            loadWarnings = warnings
            for warning in warnings { await logger.write(LogEntry(level: .warn, category: "import", message: warning)) }
            return (project, warnings)
        } catch let error as VoxClipError { throw error }
        catch let error as VoiceLabProjectError { throw error }
        catch { throw VoxClipError.projectUnreadable("Invalid project document") }
    }

    public func save(_ project: Project, to url: URL) async throws {
        var snapshot = Self.cleanReferences(project).project
        if let resolved = try? await resolveSource(for: snapshot, projectURL: url) { snapshot.media.source.absolutePath = resolved.path }
        snapshot.modifiedAt = Date()
        snapshot.savedBy = ProjectWriter()
        snapshot.media.source.relativePath = Self.relativePath(source: URL(fileURLWithPath: snapshot.media.source.absolutePath), projectURL: url)
        let data = try Self.encode(snapshot)
        do { try AtomicJSON.write(data, to: url) }
        catch { throw VoxClipError.projectUnreadable("Could not save project; existing edits are safe") }
    }

    public static func decode(_ data: Data) throws -> Project {
        try decodeReportingWarnings(data).0
    }

    public static func decodeReportingWarnings(_ data: Data) throws -> (Project, [String]) {
        do {
            let raw = try JSONDecoder().decode(JSONValue.self, from: data)
            try ProjectMigrations.checkVersion(raw)
            try ProjectValidation.validate(raw)
            var project = try ProjectJSON.decode(data)
            if project.transcript != nil {
                for index in project.transcript!.words.indices {
                    project.transcript!.words[index].text = EditingPrimitives.nfc(project.transcript!.words[index].text)
                }
            }
            project.edits.corrections = project.edits.corrections.mapValues(EditingPrimitives.nfc)
            try ProjectValidation.validateModel(project)
            let cleaned = cleanReferences(project)
            return (cleaned.project, cleaned.warnings)
        } catch let error as VoxClipError { throw error }
        catch let error as VoiceLabProjectError { throw error }
        catch { throw VoxClipError.projectUnreadable("Invalid project document") }
    }

    public static func encode(_ project: Project) throws -> Data {
        var snapshot = pruneAIResults(cleanReferences(project).project)
        let words = snapshot.transcript?.words ?? []
        let pauses = try detectPauses(words, thresholdSeconds: snapshot.edits.pauseThresholdSeconds)
        let cutWords = Set(snapshot.edits.cutWordIds), cutPauses = Set(snapshot.edits.cutPauseIds)
        snapshot.edits.cutWordIds = words.map(\.id).filter { cutWords.contains($0) }
        snapshot.edits.cutPauseIds = pauses.map(\.id).filter { cutPauses.contains($0) }
        var encoded = try ProjectJSON.encode(snapshot)
        let raw = try JSONDecoder().decode(JSONValue.self, from: encoded)
        try ProjectValidation.validate(raw)
        try ProjectValidation.validateModel(snapshot)
        encoded.append(10)
        return try orderCorrections(encoded, ids: words.map(\.id))
    }

    public static func pruneAIResults(_ project: Project) -> Project {
        var snapshot = project
        let referenced = Set(snapshot.edits.clips.compactMap(\.aiResultId))
        let newest = snapshot.ai.results.enumerated().sorted {
            $0.element.createdAt == $1.element.createdAt ? $0.offset > $1.offset : $0.element.createdAt > $1.element.createdAt
        }
        let retained = Set(newest.prefix(10).map { $0.element.id }).union(referenced)
        snapshot.ai.results.removeAll { !retained.contains($0.id) }
        return snapshot
    }

    static func orderCorrections(_ data: Data, ids: [String]) throws -> Data {
        guard let text = String(data: data, encoding: .utf8), let edits = text.range(of: "\n  \"edits\" : {"),
              let key = text[edits.upperBound...].range(of: "\n    \"corrections\" : {") else { return data }
        let corrections = try ProjectJSON.decoder().decode(Project.self, from: data).edits.corrections
        if corrections.isEmpty { return data }
        let end = text[key.upperBound...].range(of: "\n    }")
        guard let end else { return data }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let ordered = ids.filter { corrections[$0] != nil } + corrections.keys.filter { !ids.contains($0) }.sorted()
        let lines = try ordered.map { id in
            "      " + String(decoding: try encoder.encode(id), as: UTF8.self) + " : " + String(decoding: try encoder.encode(corrections[id]!), as: UTF8.self)
        }
        var result = text
        result.replaceSubrange(key.upperBound..<end.lowerBound, with: "\n" + lines.joined(separator: ",\n"))
        return Data(result.utf8)
    }

    public func resolveSource(for project: Project, projectURL: URL) async throws -> URL {
        let source = project.media.source
        var candidates = [URL(fileURLWithPath: source.absolutePath)]
        if let relative = source.relativePath { candidates.append(projectURL.deletingLastPathComponent().appendingPathComponent(relative).standardizedFileURL) }
        for candidate in candidates {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
               (attributes[.size] as? NSNumber)?.int64Value == source.sizeBytes,
               (try? Self.contentKey(for: candidate)) == source.contentKey { return candidate }
        }
        throw VoxClipError.mediaMissing(URL(fileURLWithPath: source.absolutePath).lastPathComponent)
    }

    public func relink(_ project: Project, to sourceURL: URL, probe: MediaProbeResult, confirmedDifferent: Bool = false) async throws -> Project {
        let key = try Self.contentKey(for: sourceURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else { throw VoxClipError.mediaMissing(sourceURL.lastPathComponent) }
        let matches = size == project.media.source.sizeBytes && key == project.media.source.contentKey
        guard matches || (confirmedDifferent && probe.durationSeconds.isFinite && abs(probe.durationSeconds - project.media.source.durationSeconds) <= 0.05) else {
            throw VoxClipError.mediaMissing(sourceURL.lastPathComponent)
        }
        var result = project
        result.media.source.absolutePath = sourceURL.path
        if !matches {
            result.media.source.sizeBytes = size
            result.media.source.contentKey = key
            result.media.source.video = probe.video
            result.media.source.audio = probe.audio
        }
        return result
    }

    public static func contentKey(for url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 0 else { throw VoxClipError.mediaMissing(url.lastPathComponent) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = size < 2_097_152 ? Int(size) : 1_048_576
        let head = try handle.read(upToCount: length) ?? Data()
        var tail = Data()
        if size >= 2_097_152 {
            try handle.seek(toOffset: UInt64(size - 1_048_576))
            tail = try handle.read(upToCount: 1_048_576) ?? Data()
        }
        guard head.count == length, size < 2_097_152 || tail.count == 1_048_576 else { throw VoxClipError.mediaMissing(url.lastPathComponent) }
        return SourceContentKey.hash(sizeBytes: size, head: head, tail: tail)
    }

    public static func relativePath(source: URL, projectURL: URL) -> String? {
        let source = source.standardizedFileURL, folder = projectURL.deletingLastPathComponent().standardizedFileURL
        if source.path.contains("\\") || source.pathComponents.contains(where: { ProjectValidation.matches($0, "[A-Za-z]:") }) { return nil }
        if let sourceVolume = try? source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
           let folderVolume = try? folder.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
           !sourceVolume.isEqual(folderVolume) { return nil }
        let sourceParts = source.pathComponents, folderParts = folder.pathComponents
        let sharedCount = zip(sourceParts, folderParts).prefix { $0 == $1 }.count
        let parts = Array(repeating: "..", count: folderParts.count - sharedCount) + sourceParts.dropFirst(sharedCount)
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    public static func cleanReferences(_ project: Project) -> (project: Project, warnings: [String]) {
        var result = project
        var warnings: [String] = []
        let words = project.transcript?.words ?? []
        let wordIDs = Set(words.map(\.id))
        let pauses = (try? detectPauses(words, thresholdSeconds: project.edits.pauseThresholdSeconds)) ?? []
        let pauseIDs = Set(pauses.map(\.id))
        func warn(_ category: String, _ count: Int) { if count > 0 { warnings.append("Dropped \(count) invalid \(category) reference(s)") } }
        result.edits.cutWordIds = project.edits.cutWordIds.filter(wordIDs.contains)
        result.edits.cutPauseIds = project.edits.cutPauseIds.filter(pauseIDs.contains)
        warn("cut word", project.edits.cutWordIds.count - result.edits.cutWordIds.count)
        warn("cut pause", project.edits.cutPauseIds.count - result.edits.cutPauseIds.count)
        result.edits.corrections = project.edits.corrections.filter { id, text in words.contains { $0.id == id && $0.kind == .word && $0.text != text } }
        warn("correction", project.edits.corrections.count - result.edits.corrections.count)
        result.edits.clips = project.edits.clips.filter { clipIndices($0, words: words) != nil }
        warn("clip", project.edits.clips.count - result.edits.clips.count)
        let clipIDs = Set(result.edits.clips.map(\.id)), aiIDs = Set(project.ai.results.map(\.id))
        if let active = result.edits.activeClipId, !clipIDs.contains(active) { result.edits.activeClipId = nil; warn("active clip", 1) }
        for index in result.edits.clips.indices {
            if let id = result.edits.clips[index].aiResultId, !aiIDs.contains(id) {
                result.edits.clips[index].aiResultId = nil; result.edits.clips[index].aiClipIndex = nil; warn("AI result", 1)
            }
        }
        result.share.captions = project.share.captions.filter { $0.key == "full" || clipIDs.contains($0.key) }
        warn("share caption", project.share.captions.count - result.share.captions.count)
        return (result, warnings)
    }
}
