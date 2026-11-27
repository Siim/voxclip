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

    package static func cachedTranscript(_ key: String, cache: URL) -> Transcript? {
        guard let transcript = RecordingTranscriptCache.read(key, cache: cache), transcript.engine.id != .elevenlabs else { return nil }
        return transcript
    }
}

package enum RecordingTranscriptCache {
    static func validKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func entry(_ key: String, in cache: URL) -> URL? {
        guard validKey(key) else { return nil }
        return cache.appendingPathComponent(key).appendingPathComponent("transcripts/confirmed-v1.json")
    }

    package static func read(_ key: String, cache: URL, recent: [URL] = []) -> Transcript? {
        if let file = entry(key, in: cache), let data = try? Data(contentsOf: file),
           let transcript = (try? JSONDecoder().decode(Transcript.self, from: data)) ??
                (try? ProjectJSON.decoder().decode(Transcript.self, from: data)) { return transcript }
        return recent.lazy.compactMap { file -> Transcript? in
            guard let data = try? Data(contentsOf: file), let project = try? JSONProjectStore.decode(data) else { return nil }
            if project.media.source.contentKey == key { return project.transcript }
            return project.media.spokenSources?.first { $0.sourceKey == key }?.transcript
        }.first
    }

    package static func write(_ transcript: Transcript, key: String, cache: URL) {
        guard let file = entry(key, in: cache), let data = try? JSONEncoder().encode(transcript) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
