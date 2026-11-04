import CryptoKit
import Darwin
import Foundation
import Synchronization
import VoxClipCore

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

/// Stores a used track in `<data folder>/Music/<projectId>/music-<slug>-<hash>.<ext>`; doc/spec/music.md §2.
/// The name carries the content hash, so the same track is stored once and an existing file is never overwritten.
public enum MusicAssetStore {
    public static let maximumBytes = 200 * 1_024 * 1_024

    public static func store(_ data: Data, title: String, fileExtension: String, projectId: String, dataRoot: URL) throws -> MusicAsset.Stored {
        guard !data.isEmpty, data.count <= maximumBytes, MusicAsset.extensions.contains(fileExtension) else {
            throw VoxClipError.decodeFailed("The music file is empty, too large or of an unknown type")
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = "music-" + slug(title) + "-" + hash.prefix(8) + "." + fileExtension
        let file = projectId + "/" + name
        let folder = MusicRenderInput.root(dataRoot: dataRoot).appendingPathComponent(projectId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(name)
        if let existing = try? Data(contentsOf: url) {
            guard SHA256.hash(data: existing).map({ String(format: "%02x", $0) }).joined() == hash else {
                throw VoxClipError.exportFailed("A different music file already has this name; it was kept")
            }
            return MusicAsset.Stored(file: file, sha256: hash, url: url)
        }
        let partial = folder.appendingPathComponent("." + name + "." + UUID().uuidString.lowercased() + ".partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw VoxClipError.diskFull(folder.path)
        }
        defer { try? FileManager.default.removeItem(at: partial) }
        guard partial.path.withCString({ source in url.path.withCString { renamex_np(source, $0, UInt32(RENAME_EXCL)) } }) == 0 else {
            if errno == EEXIST { return try store(data, title: title, fileExtension: fileExtension, projectId: projectId, dataRoot: dataRoot) }
            throw VoxClipError.exportFailed("The music file could not be saved")
        }
        return MusicAsset.Stored(file: file, sha256: hash, url: url)
    }

    /// The canonical part of a stored name: lower-case letters, digits and dashes, at most 40 characters.
    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var result = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) { result.unicodeScalars.append(scalar) }
            else if !result.isEmpty, !result.hasSuffix("-") { result += "-" }
            if result.count >= 40 { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "track" : result
    }

    /// The project entry for a stored candidate, with the default level, ducking and fades.
    public static func entry(for candidate: MusicCandidate, stored: MusicAsset.Stored, durationSeconds: Double, clipId: String?) throws -> ProjectMusic {
        guard durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= ProjectMusic.maximumDuration else {
            throw VoxClipError.decodeFailed("The music file is longer than 30 minutes or has no length")
        }
        let identifier = "music-" + stored.sha256.prefix(12)
        return ProjectMusic(id: identifier, clipId: clipId, asset: MusicAsset(file: stored.file, sha256: stored.sha256, durationSeconds: durationSeconds),
                            source: candidate.source, title: candidate.title, creator: candidate.creator, license: candidate.license,
                            attribution: candidate.attribution, sourceUrl: candidate.sourceUrl,
                            prompt: candidate.source == .generated ? candidate.prompt : nil)
    }

    /// Stores the bytes, measures their length and builds the entry; the file must decode.
    public static func importing(_ data: Data, candidate: MusicCandidate, projectId: String, clipId: String?, dataRoot: URL) async throws -> ProjectMusic {
        let stored = try store(data, title: candidate.title, fileExtension: candidate.fileExtension, projectId: projectId, dataRoot: dataRoot)
        let seconds = try await MusicBedRenderer.durationSeconds(stored.url)
        return try entry(for: candidate, stored: stored, durationSeconds: seconds, clipId: clipId)
    }
}

extension MusicAsset {
    /// A stored file before its length is known.
    public struct Stored: Sendable, Equatable {
        public let file: String
        public let sha256: String
        public let url: URL
    }
}

/// Claude's best three across sources for one brief (doc/spec/music.md §3.4): one free library match, one Eleven Music
/// track priced but not yet made, and the user's own file when one fits by name. A source that cannot answer adds a
/// note and never hides the others. The autopilot planner calls it through `MusicSuggesting`.
public final class MusicSuggestionService: MusicSuggesting {
    private let library: OpenverseMusicClient?
    private let eleven: ElevenMusicClient?
    private let hasElevenKey: @Sendable () async -> Bool
    private let folder: @Sendable () -> URL?
    private let quotes = Mutex<[String: MusicQuote]>([:])

    public init(library: OpenverseMusicClient?, eleven: ElevenMusicClient?, hasElevenKey: @escaping @Sendable () async -> Bool,
                folder: @escaping @Sendable () -> URL?) {
        self.library = library; self.eleven = eleven; self.hasElevenKey = hasElevenKey; self.folder = folder
    }

    public func candidates(for brief: MusicBrief, clipSeconds: Double) async -> MusicSuggestionResult {
        var result = MusicSuggestionResult()
        if let library {
            do {
                if var match = try await library.search(brief.searchText, keywords: brief.keywords, clipSeconds: clipSeconds).first {
                    match.reason = brief.reason ?? (match.tags.isEmpty ? nil : match.tags.prefix(3).joined(separator: ", "))
                    result.candidates.append(match)
                } else {
                    result.notes[.library] = "No free track matched \u{201C}\(brief.searchText)\u{201D}. Search other words."
                }
            } catch {
                result.notes[.library] = Self.note(error)
            }
        }
        if let eleven {
            if await hasElevenKey() {
                do {
                    let quote = try eleven.quote(prompt: brief.compositionPrompt, clipSeconds: clipSeconds)
                    let title = brief.mood.trimmingCharacters(in: .whitespacesAndNewlines)
                    let candidate = MusicCandidate(id: "eleven-" + quote.id.uuidString.lowercased(), source: .generated,
                                                   title: String((title.isEmpty ? "Made for this clip" : title.prefix(1).uppercased() + title.dropFirst()).prefix(200)),
                                                   license: .generated, fileExtension: "mp3", prompt: quote.prompt,
                                                   durationSeconds: Double(quote.lengthSeconds), estimate: quote.estimate,
                                                   reason: brief.reason ?? "Made to the clip's length")
                    quotes.withLock { $0[candidate.id] = quote }
                    result.candidates.append(candidate)
                } catch {
                    result.notes[.generated] = Self.note(error)
                }
            } else {
                result.notes[.generated] = "Add an ElevenLabs key in Settings to make music for this clip."
            }
        }
        if let own = MusicLibraryFolder.best(MusicLibraryFolder.files(in: folder()), keywords: brief.keywords) {
            var match = own
            match.reason = "From your Music folder"
            result.candidates.append(match)
        }
        return result
    }

    /// The approved quote behind a generated candidate, used once.
    public func quote(for candidate: MusicCandidate) -> MusicQuote? {
        quotes.withLock { $0.removeValue(forKey: candidate.id) }
    }

    static func note(_ error: any Error) -> String {
        switch error as? VoxClipError {
        case .offline: "You're offline, so only your own files are shown."
        case .rateLimited: "The free library asked VoxClip to wait. Try again in a minute."
        default: (error as? LocalizedError)?.errorDescription ?? "This source is not available right now."
        }
    }
}
