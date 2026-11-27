import Foundation

public enum HarnessRecording {
    package static func localTranscription(in project: Project) -> Transcript? {
        if let primary = project.transcript, primary.engine.id != .elevenlabs { return primary }
        return project.media.spokenSources?.first { $0.transcript.engine.id != .elevenlabs }?.transcript
    }

    public static func source(_ key: String, in project: Project) throws -> MediaReference {
        guard let source = project.media.additionalSources.first(where: { $0.contentKey == key }),
              source.video != nil, source.audio != nil, key != project.media.source.contentKey,
              project.media.spokenSources?.contains(where: { $0.sourceKey == key }) != true else {
            throw HarnessError.invalid("Choose a companion that isn't already a spoken recording.")
        }
        guard project.transcript != nil, localTranscription(in: project) != nil else { throw refusal(source) }
        guard (project.media.spokenSources?.count ?? 0) < 5 else {
            throw HarnessError.invalid("A project can have up to six spoken recordings.")
        }
        return source
    }

    public static func refusal(_ source: MediaReference) -> HarnessError {
        .invalid("Transcribe \(ProjectClock.label(source)) in VoxClip first.")
    }

    public static func add(_ key: String, transcript: Transcript, to project: Project) throws -> Project {
        let source = try source(key, in: project)
        guard transcript.engine.id != .elevenlabs else { throw refusal(source) }
        return try RecordingEdits.apply(.addSpokenSource(key: key, transcript: transcript), project: project).get().project
    }

    package static func cachedTranscript(_ key: String, cache: URL, recent: [URL] = []) -> Transcript? {
        RecordingTranscriptCache.read(key, cache: cache, recent: recent, localOnly: true)
    }
}

package enum RecordingTranscriptCache {
    static func validKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func directory(_ key: String, in cache: URL) -> URL? {
        guard validKey(key) else { return nil }
        return cache.appendingPathComponent(key).appendingPathComponent("transcripts", isDirectory: true)
    }

    package static func read(_ key: String, cache: URL, recent: [URL] = [], localOnly: Bool = false) -> Transcript? {
        guard let directory = directory(key, in: cache) else { return nil }
        func readEntry(_ name: String) -> Transcript? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let transcript = (try? ProjectJSON.decoder().decode(Transcript.self, from: data)) ??
                    (try? JSONDecoder().decode(Transcript.self, from: data)),
                  (try? ProjectValidation.validateTranscript(transcript, normalizeWordText: true)) != nil else { return nil }
            return transcript
        }
        if let local = readEntry("confirmed-local-v1.json"), local.engine.id != .elevenlabs { return local }
        let legacy = readEntry("confirmed-v1.json")
        if let legacy, legacy.engine.id != .elevenlabs { return legacy }
        if !localOnly, let cloud = readEntry("confirmed-cloud-v1.json") ?? legacy { return cloud }
        return recent.lazy.compactMap { file -> Transcript? in
            guard let data = try? Data(contentsOf: file), let project = try? JSONProjectStore.decode(data) else { return nil }
            let transcript = project.media.source.contentKey == key ? project.transcript :
                project.media.spokenSources?.first { $0.sourceKey == key }?.transcript
            guard let transcript, !localOnly || transcript.engine.id != .elevenlabs else { return nil }
            return transcript
        }.first
    }

    package static func write(_ transcript: Transcript, key: String, cache: URL) {
        guard let directory = directory(key, in: cache), let data = try? ProjectJSON.encoder().encode(transcript) else { return }
        let name = transcript.engine.id == .elevenlabs ? "confirmed-cloud-v1.json" : "confirmed-local-v1.json"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
