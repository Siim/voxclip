import Foundation

/// `<data>/VoiceLab/per-video.json` (`voxclip-voice-per-video/1`, voice-lab §6.13): which voice each video uses. App
/// data, private (0700), written atomically; never inside a project file. A missing or unreadable file reads as empty,
/// so a damaged book only forgets which voices were per-video (they stay listed and removable in Settings › Voices).
public actor VoicePerVideoStore {
    public nonisolated let url: URL

    public init(locations: DataLocations) {
        url = locations.root.appendingPathComponent("VoiceLab/per-video.json")
    }

    public init(url: URL) { self.url = url }

    public func load() -> VoicePerVideoBook {
        guard let data = try? Data(contentsOf: url), let book = try? JSONDecoder().decode(VoicePerVideoBook.self, from: data),
              (try? book.validate()) != nil else { return VoicePerVideoBook() }
        return book
    }

    public func save(_ book: VoicePerVideoBook) throws {
        try book.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(book).write(to: url, options: [.atomic])
    }

    /// Loads, changes and saves in one step on the actor, so two changes never overwrite each other.
    @discardableResult
    public func update(_ change: @Sendable (VoicePerVideoBook) -> VoicePerVideoBook) throws -> VoicePerVideoBook {
        let next = change(load())
        try save(next)
        return next
    }
}
