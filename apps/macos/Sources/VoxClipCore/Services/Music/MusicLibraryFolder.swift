import Foundation

/// The user's own music: the Music folder setting (default ~/Music/VoxClip when it exists) and "Add a file…";
/// doc/spec/music.md §3.3. Only MP3, M4A, WAV and AIFF files are offered.
public enum MusicLibraryFolder {
    public static let extensions: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff"]
    public static let maximumFiles = 200

    /// ~/Music/VoxClip when that folder exists, else nil.
    public static func defaultFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let folder = home.appendingPathComponent("Music/VoxClip", isDirectory: true)
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory) && directory.boolValue ? folder : nil
    }

    /// The folder's music files (not its subfolders), by name, at most 200.
    public static func files(in folder: URL?) -> [MusicCandidate] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                                  options: [.skipsHiddenFiles]) else { return [] }
        return names.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .compactMap(candidate(for:))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .prefix(maximumFiles).map { $0 }
    }

    /// A candidate for one of the user's files, or nil for another type.
    public static func candidate(for url: URL) -> MusicCandidate? {
        let fileExtension = url.pathExtension.lowercased()
        guard extensions.contains(fileExtension) else { return nil }
        let title = String(url.deletingPathExtension().lastPathComponent.prefix(200))
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return MusicCandidate(id: "file-" + url.path, source: .file, title: title.isEmpty ? "Untitled" : title, license: .own,
                              audioURL: url, fileExtension: fileExtension == "aif" ? "aiff" : fileExtension, tags: words)
    }

    /// The file whose name shares the most words with the brief; nil when none shares any.
    public static func best(_ files: [MusicCandidate], keywords: Set<String>) -> MusicCandidate? {
        let scored = files.map { file in (file, Set(file.tags).intersection(keywords).count) }.filter { $0.1 > 0 }
        return scored.max { $0.1 < $1.1 }?.0
    }
}
