@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import VoxClipCore

public struct ClipIllustrationQuote: Decodable, Sendable {
    public let endpoint: URL
    public let size: Int
    public let usdPerImage: Decimal

    public static func load(shared: SharedResources) throws -> Self {
        let url = shared.root.appendingPathComponent("data/clip-illustration.json")
        let quote = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard quote.endpoint.absoluteString == "https://fal.run/fal-ai/flux/schnell", quote.size == 768,
              quote.usdPerImage > 0, quote.usdPerImage <= Decimal(string: "0.01")! else { throw ClipEffectError.invalidEntry("illustration quote") }
        return quote
    }
}

public struct ClipPlanAssets: Sendable {
    private let http: any MusicHTTP
    private let openverse: OpenverseMusicClient

    public init(http: any MusicHTTP = URLSessionMusicHTTP()) {
        self.http = http; openverse = OpenverseMusicClient(http: http)
    }

    public func sound(_ request: ClipPlanAsset, projectID: String, root: URL) async throws -> ClipEffect? {
        let length = request.end - request.start
        let offset = request.soundFrom ?? 0
        let results = try await openverse.searchPage(request.text, sound: true).candidates
        guard let candidate = results.first(where: {
            guard let duration = $0.durationSeconds else { return false }
            return duration <= min(length + offset, ClipEffect.maximumSoundSeconds) && duration - offset >= 0.05
        }) else { return nil }
        let ext = candidate.fileExtension
        let bytes = try await openverse.download(candidate)
        guard bytes.count <= 16 * 1024 * 1024 else { return nil }
        let hash = Self.hash(bytes)
        let relative = "\(projectID)/sfx-\(hash.prefix(48)).\(ext)"
        let file = try Self.save(bytes, relative: relative, projectID: projectID, root: ClipEffectsRenderInput.soundRoot(dataRoot: root))
        let asset = AVURLAsset(url: file)
        guard let track = try await MediaSupport.audioTrack(in: asset) else { return nil }
        let actual = try await track.load(.timeRange).duration.seconds
        guard actual.isFinite, actual - offset >= 0.05, actual <= min(length + offset + 1e-9, ClipEffect.maximumSoundSeconds) else { return nil }
        let sound = ClipEffect.Sound(source: .library, file: relative, sha256: hash, durationSeconds: actual, title: candidate.title,
                                    creator: candidate.creator, license: candidate.license.rawValue, attribution: candidate.attribution,
                                    sourceUrl: candidate.sourceUrl)
        let shaped = request.soundFrom != nil || request.shape != ItemShape()
        let end = shaped ? min(request.end, request.start + actual - offset) : request.end
        return ClipEffect(id: request.id, clipId: request.clipID, kind: .sound, start: request.start, end: end, sound: sound,
                          gainDb: request.gainDb ?? -15, fadeInSeconds: request.shape.fadeInSeconds, fadeOutSeconds: request.shape.fadeOutSeconds,
                          mediaOffsetSeconds: request.soundFrom, gainPoints: request.shape.gainPoints)
    }

    public func savedIllustration(_ request: ClipPlanAsset, projectID: String, root: URL, quote: ClipIllustrationQuote) -> ClipEffect? {
        let path = Self.illustrationPath(request, quote: quote, projectID: projectID)
        let url = ClipEffectsRenderInput.imageRoot(dataRoot: root).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Self.picture(request, path: path)
    }

    public func illustration(_ request: ClipPlanAsset, projectID: String, root: URL, quote: ClipIllustrationQuote, key: String) async throws -> ClipEffect {
        let path = Self.illustrationPath(request, quote: quote, projectID: projectID)
        var call = URLRequest(url: quote.endpoint)
        call.httpMethod = "POST"
        call.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": request.text, "image_size": ["width": quote.size, "height": quote.size],
            "num_images": 1, "enable_safety_checker": true, "output_format": "png", "sync_mode": true])
        struct Reply: Decodable {
            struct Image: Decodable { let url: String }
            let images: [Image]
        }
        let (data, response) = try await http.send(call)
        guard (200..<300).contains(response.statusCode), data.count <= 16 * 1024 * 1024 else {
            throw VoxClipError.providerError("Illustration generation did not finish", provider: "fal", status: response.statusCode)
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let prefix = "data:image/png;base64,"
        guard reply.images.count == 1, let image = reply.images.first, image.url.hasPrefix(prefix),
              let bytes = Data(base64Encoded: String(image.url.dropFirst(prefix.count))),
              bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw VoxClipError.providerError("Illustration generation did not return a PNG", provider: "fal")
        }
        _ = try Self.save(bytes, relative: path, projectID: projectID, root: ClipEffectsRenderInput.imageRoot(dataRoot: root))
        return Self.picture(request, path: path)
    }

    private static func illustrationPath(_ request: ClipPlanAsset, quote: ClipIllustrationQuote, projectID: String) -> String {
        let digest = hash(Data("\(quote.endpoint.absoluteString)\n\(quote.size)\n\(request.text)".utf8))
        return "\(projectID)/illustration-\(digest).png"
    }

    private static func picture(_ request: ClipPlanAsset, path: String) -> ClipEffect {
        ClipEffect(id: request.id, clipId: request.clipID, kind: .illustration, start: request.start, end: request.end, imageFile: path,
                   fadeInSeconds: request.shape.fadeInSeconds, fadeOutSeconds: request.shape.fadeOutSeconds)
    }

    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    private static func save(_ bytes: Data, relative: String, projectID: String, root: URL) throws -> URL {
        guard UUID(uuidString: projectID) != nil else { throw ClipEffectError.invalidEntry("asset project") }
        let file = root.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(root.lastPathComponent)
            .appendingPathComponent(relative).standardizedFileURL
        let folder = file.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard folder.resolvingSymlinksInPath().path == folder.path, file.resolvingSymlinksInPath().path == file.path else { throw ClipEffectError.invalidEntry("asset path") }
        if !manager.fileExists(atPath: file.path) { try bytes.write(to: file, options: .atomic) }
        return file
    }
}
