import ArgumentParser
import AVFoundation
import CryptoKit
import Foundation
import VoxClipCore
import VoxClipMedia

enum CLIMusic {
    static func saved(_ trackID: String, in project: Project, dataRoot: URL) throws -> MusicRenderInput {
        guard let entry = project.music.first(where: { $0.id == trackID }) else {
            throw ValidationError("The requested music track does not exist in the project.")
        }
        let url = MusicRenderInput.url(for: entry.asset, dataRoot: dataRoot)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw ValidationError("The requested music track's file is missing.")
        }
        return MusicRenderInput(entry: entry, assetURL: url)
    }

    static func local(_ path: String) async throws -> MusicRenderInput {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard MusicAsset.extensions.contains(url.pathExtension.lowercased()), values?.isRegularFile == true,
              let size = values?.fileSize, (1...MusicAssetStore.maximumBytes).contains(size) else {
            throw ValidationError("--music-file needs a local MP3, M4A, WAV, AIFF or FLAC audio file up to 200 MB.")
        }
        let asset = AVURLAsset(url: url)
        let track = try? await asset.loadTracks(withMediaType: .audio).first
        let duration = try? await track?.load(.timeRange).duration.seconds
        guard let duration, duration.isFinite, duration > 0, duration <= ProjectMusic.maximumDuration else {
            throw ValidationError("--music-file needs a playable audio track up to 30 minutes long.")
        }
        let hash = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        let entry = ProjectMusic(id: "file-" + hash.prefix(16), clipId: nil,
            asset: MusicAsset(file: url.lastPathComponent, sha256: hash, durationSeconds: duration),
            source: .file, title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, license: .own)
        return MusicRenderInput(entry: entry, assetURL: url)
    }

    static func json(_ entry: ProjectMusic?) -> JSONValue {
        guard let entry else { return .null }
        return .object(["trackId": .string(entry.id), "title": .string(entry.title),
                        "gainDb": .number(entry.gainDb), "ducking": .bool(entry.ducking)])
    }

    static func autopilotTrack(for plan: ClipAutopilotPlan, clipID: String, in project: Project, saved: [ProjectMusic],
                               dataRoot: URL) -> ProjectMusic? {
        guard let picked = plan.pickedMusic, project.music.count < ProjectMusic.maximumEntries else { return nil }
        let available = saved.filter { entry in
            let url = MusicRenderInput.url(for: entry.asset, dataRoot: dataRoot)
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        for cue in [picked] + plan.music.filter({ $0 != picked }) {
            let title = words(cue.title)
            let mood = Set(words(cue.mood).filter { $0.count >= 3 })
            let match = available.first { !title.isEmpty && words($0.title) == title } ?? available.first {
                !mood.isEmpty && mood.isSubset(of: Set(words($0.title + " " + ($0.prompt ?? ""))))
            }
            if var entry = match {
                let originalID = entry.id
                entry.clipId = clipID
                let taken = Set(project.music.map(\.id))
                var index = 2
                while taken.contains(entry.id) {
                    let suffix = "-\(index)"
                    entry.id = String(originalID.prefix(64 - suffix.count)) + suffix
                    index += 1
                }
                return entry
            }
        }
        return nil
    }

    private static func words(_ text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }
    }
}
