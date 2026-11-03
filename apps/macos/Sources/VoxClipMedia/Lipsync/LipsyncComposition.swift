import AVFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO
import VoxClipCore

final class LipsyncVideoLease: @unchecked Sendable {
    let directory: URL
    init(scratchRoot: URL) throws {
        directory = scratchRoot.appendingPathComponent("lipsync-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func snapshot(_ asset: VoiceLabVideoAsset, projectID: String, paidRoot: URL) async throws -> URL {
        guard asset.file == (try VoiceLabAssetNaming.videoFile(projectId: projectID, assetId: asset.id)) else {
            throw LipsyncError.unsafeFile
        }
        let root = try LipsyncLocalPath.openDirectory(paidRoot)
        defer { Darwin.close(root) }
        let project = openat(root, projectID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard project >= 0 else { throw LipsyncError.unsafeFile }
        defer { Darwin.close(project) }
        let descriptor = openat(project, "\(asset.id).mp4", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw LipsyncError.unsafeFile }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, (12...Int64(LipsyncLimits.maximumVideoBytes)).contains(before.st_size) else { throw LipsyncError.unsafeFile }
        let destination = directory.appendingPathComponent("\(asset.id).mp4")
        let outputFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw LipsyncError.unsafeFile }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var hash = SHA256(), count: Int64 = 0
        while let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            count += Int64(data.count)
            guard count <= before.st_size else { throw LipsyncError.invalidMedia }
            hash.update(data: data); try output.write(contentsOf: data)
        }
        guard fstat(descriptor, &after) == 0, count == before.st_size, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else { throw LipsyncError.invalidMedia }
        try output.close()
        _ = try await LipsyncResultValidation.validate(file: destination, durationSeconds: asset.durationSeconds,
            fps: asset.frameRate, width: asset.width, height: asset.height)
        return destination
    }
}

struct LipsyncVideoLayer: Sendable {
    let trackID: CMPersistentTrackID
    let output: CMTimeRange
    let orientation: CGImagePropertyOrientation
    let lease: LipsyncVideoLease
}

enum LipsyncComposition {
    static func insert(_ request: RenderRequest, into composition: AVMutableComposition,
                       scratchRoot: URL, isolation: isolated (any Actor)? = #isolation) async throws -> [LipsyncVideoLayer] {
        guard let input = request.voiceLab else { return [] }
        let selected = input.prepared.selectedSegmentRecipes.filter { $0.recipe.video.mode == .lipsync }
        guard !selected.isEmpty else { return [] }
        let lease = try LipsyncVideoLease(scratchRoot: scratchRoot)
        let plan = input.prepared.outputPlan, rate = Int32(plan.sampleRate)
        var tracks: [String: (CMPersistentTrackID, CGImagePropertyOrientation)] = [:]
        var layers: [LipsyncVideoLayer] = []
        for item in selected {
            let video = item.recipe.video
            guard let assetID = video.assetId, let start = video.windowStartSample, let end = video.windowEndSample,
                  let record = input.project.voiceLab.videoAssets?.first(where: { $0.id == assetID }) else { throw LipsyncError.invalidInput }
            let outputStart = LipsyncRenderWindow.outputSample(start, plan: plan)
            let outputEnd = LipsyncRenderWindow.outputSample(end, plan: plan)
            if tracks[assetID] == nil {
                let file = try await lease.snapshot(record, projectID: input.project.id, paidRoot: input.paidRoot)
                let asset = AVURLAsset(url: file)
                guard let source = try await asset.loadTracks(withMediaType: .video).first,
                      let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw LipsyncError.invalidMedia
                }
                let transform = try await source.load(.preferredTransform)
                let range = CMTimeRange(start: .zero, duration: CMTime(value: outputEnd - outputStart, timescale: rate))
                guard abs(range.duration.seconds - record.durationSeconds) <= 1 / record.frameRate else { throw LipsyncError.invalidMedia }
                try withExtendedLifetime(asset) { try target.insertTimeRange(range, of: source, at: CMTime(value: outputStart, timescale: rate)) }
                tracks[assetID] = (target.trackID, MediaSupport.orientation(transform))
            }
            guard let track = tracks[assetID] else { throw LipsyncError.invalidMedia }
            let handle = Int64((plan.sampleRate * 0.2).rounded())
            let replacementStart = max(outputStart, item.piece.outputStartSample - handle)
            let replacementEnd = min(outputEnd, item.piece.outputEndSample + handle)
            let replacement = CMTimeRange(start: CMTime(value: replacementStart, timescale: rate),
                                          end: CMTime(value: replacementEnd, timescale: rate))
            layers.append(LipsyncVideoLayer(trackID: track.0, output: replacement, orientation: track.1, lease: lease))
        }
        return layers
    }
}
