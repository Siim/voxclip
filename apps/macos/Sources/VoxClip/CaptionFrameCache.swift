import AVFoundation

actor CaptionFrameCache {
    static let shared = CaptionFrameCache()
    private struct Key: Hashable {
        let content: String
        let source: URL
        let time: Double
    }
    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var pending: [Key: Task<CGImage?, Never>] = [:]
    func frame(_ input: CaptionTileInput) async -> CGImage? {
        let key = Key(content: input.contentKey, source: input.sourceURL, time: input.sourceTime)
        if let image = images[key] { return image }
        if let task = pending[key] { return await task.value }
        let task = Task.detached(priority: .utility) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: key.source))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try? await generator.image(at: CMTime(seconds: key.time, preferredTimescale: 600)).image
        }
        pending[key] = task
        let image = await task.value
        pending[key] = nil
        if let image {
            images[key] = image; order.append(key)
            while order.count > 12 { images[order.removeFirst()] = nil }
        }
        return image
    }
}
