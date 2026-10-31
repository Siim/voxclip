import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import VoxClipCore

/// What a surface has for its stand-in (design §5.4.1): the scope's frame once decoded,
/// the card VoxClipCore made for it and the style it was made in, and that card drawn
/// for the surface. A card without words is drawn as the style's backdrop alone.
struct StandInSources: Equatable {
    var frame: CGImage?
    var card: CaptionCardText = .none
    var styleId = ""
    var cardImage: CGImage?
}

extension MediaStatus {
    /// The state in a surface's "{title}, {state}" name (§5.4.9); nil when normal.
    var spokenState: String? {
        switch self {
        case .none: nil
        case .loading: "loading"
        case .missing: "video not found"
        case .unreadable: "video can't be read"
        case .demo: "demo project, no video"
        case .audioOnly: "audio only"
        case .transcribing(let fraction, _): fraction.map { "transcribing \(Int($0 * 100)) percent" } ?? "transcribing"
        }
    }
}

extension MediaTranscriptionStage {
    /// The chip's words for the stage (§5.4.8 and §13); transcribing adds its percentage.
    var chipText: String {
        switch self {
        case .readingVideo: "Reading video…"
        case .extractingAudio: "Extracting audio…"
        case .transcribing: "Transcribing"
        case .aligning: "Aligning words…"
        }
    }
}

/// The chip.media* values proposed in design §5.4.8, which tokens.json doesn't have
/// yet; each becomes its token path when they land. Media chips sit on video, so they
/// are the same in both appearances.
@MainActor enum MediaChipTokens {
    static let background = Color(nsColor: DesignValues.parse("#0000009E"))
    static let stroke = Color(nsColor: DesignValues.parse("#FFFFFF2E"))
    static let backgroundOpaque = Color(nsColor: DesignValues.parse("#1A1A1C"))
    static let strokeOpaque = Color(nsColor: DesignValues.parse("#FFFFFF66"))
    static let foreground = Color(nsColor: DesignValues.parse("#FFFFFF"))
    static let warningGlyph = Color(nsColor: DesignValues.parse("#E3B25C"))
}

/// Every media stand-in: Home tiles and sidebar thumbnails (the stage joins in round 2).
/// VoxClipCore's `MediaStandIn.resolve` picks what it draws; this view runs the §5.4.5
/// ladder around it: 300 ms of stage black, where a frame that arrives cuts in with no
/// fade; then the sheen while the project file is unread, or the card while the frame
/// is pending; then a 150 ms crossfade to the frame. Tiles carry the status chip and
/// duration chip; rows carry only the progress line and dots.
@MainActor struct MediaThumbnail: View {
    enum Surface { case tile, row }
    var status: MediaStatus = .none
    let sources: StandInSources
    var surface: Surface = .tile
    /// Home only: the project file is still unread, so the ladder sweeps the sheen.
    var unread = false
    /// The tile's duration chip.
    var duration: Double?
    var cornerRadius: CGFloat = VCTokens.radiusPane

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var holding = true

    private var standIn: MediaStandIn {
        MediaStandIn.resolve(status: status, hasFrame: sources.frame != nil, card: sources.card, styleId: sources.styleId, holding: holding)
    }

    var body: some View {
        let standIn = standIn
        Rectangle().fill(DesignValues.color("stage"))
            .overlay { picture(standIn).animation(holding || reduceMotion ? nil : .easeOut(duration: VCTokens.motionDurationBase / 1000), value: layer(standIn)) }
            .overlay { if !holding, unread, !reduceMotion { MediaSheen() } }
            .overlay { if showsDots(standIn) { MediaDots(size: surface == .tile ? 7 : 3) } }
            .overlay(alignment: .bottom) {
                if case .transcribing(let fraction, _) = status, fraction != nil || !reduceMotion { MediaProgressLine(fraction: fraction) }
            }
            .overlay(alignment: .topLeading) { if surface == .tile { statusChip.padding(6) } }
            .overlay(alignment: .bottomTrailing) {
                if surface == .tile, let duration { MediaChip(number: durationLabel(duration)).padding(6) }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(MediaChipTokens.foreground.opacity(surface == .row ? 0.12 : 0.10), lineWidth: 1) }
            .task { try? await Task.sleep(for: .milliseconds(300)); holding = false }
            .accessibilityHidden(true)
    }

    @ViewBuilder private func picture(_ standIn: MediaStandIn) -> some View {
        switch standIn {
        case .frame: if let frame = sources.frame { Image(decorative: frame, scale: 1).resizable().scaledToFill().transition(.opacity) }
        case .card: if let image = sources.cardImage { Image(decorative: image, scale: 1).resizable().scaledToFill().transition(.opacity) }
        case .black: Color.clear
        }
    }
    private func layer(_ standIn: MediaStandIn) -> Int {
        switch standIn { case .black: 0; case .card: 1; case .frame: 2 }
    }

    /// A take transcribing with no frame yet shows three dots (§5.4.4 d).
    private func showsDots(_ standIn: MediaStandIn) -> Bool {
        guard !holding, case .transcribing = status else { return false }
        return standIn != .frame
    }

    @ViewBuilder private var statusChip: some View {
        switch status {
        case .missing: MediaChip(icon: "video.slash", tint: MediaChipTokens.warningGlyph)
        case .unreadable: MediaChip(icon: "exclamationmark.triangle", tint: MediaChipTokens.warningGlyph)
        case .demo: MediaChip(text: "Demo")
        case .audioOnly: MediaChip(text: "Audio only", icon: "waveform")
        case .transcribing(let fraction, let stage):
            if stage == .transcribing, let fraction { MediaChip(text: "Transcribing · ", number: "\(Int(fraction * 100))%") }
            else { MediaChip(text: stage.chipText) }
        case .none, .loading: EmptyView()
        }
    }
}

/// A media chip (§5.4.8): 20 high, SF 11/14 semibold, numbers in SF Mono; icon-only
/// chips are 22×22 with a 14 px glyph. Opaque under Reduce Transparency or Increase
/// Contrast, with a white edge under Increase Contrast.
struct MediaChip: View {
    var text: String?
    var number: String?
    var icon: String?
    var tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let iconOnly = text == nil && number == nil
        let opaque = reduceTransparency || contrast == .increased
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: iconOnly ? 14 : 11, weight: .semibold)).foregroundStyle(tint ?? MediaChipTokens.foreground) }
            if let text { Text(text) }
            if let number { Text(number).font(.system(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit() }
        }
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(MediaChipTokens.foreground)
        .padding(.horizontal, iconOnly ? 0 : 7)
        .frame(width: iconOnly ? 22 : nil, height: iconOnly ? 22 : 20)
        .background(opaque ? MediaChipTokens.backgroundOpaque : MediaChipTokens.background, in: .rect(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4).strokeBorder(contrast == .increased ? MediaChipTokens.foreground : opaque ? MediaChipTokens.strokeOpaque : MediaChipTokens.stroke, lineWidth: 1)
        }
    }
}

/// The 2 px progress line (§5.4.8): the overlay foreground on black 55%, opaque under
/// Reduce Transparency or Increase Contrast. With no fraction a 30% segment slides
/// across every 1.6 s; the caller hides it under Reduce Motion.
private struct MediaProgressLine: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let opaque = reduceTransparency || contrast == .increased
        let fill = opaque ? MediaChipTokens.foreground : DesignValues.color("overlay.foreground")
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(DesignValues.color("stage").opacity(opaque ? 1 : 0.55))
                if let fraction {
                    Rectangle().fill(fill).frame(width: geometry.size.width * fraction.clamped(to: 0...1))
                } else {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        Rectangle().fill(fill).frame(width: geometry.size.width * 0.3).offset(x: geometry.size.width * (1.3 * phase - 0.3))
                    }
                }
            }
        }
        .frame(height: 2)
    }
}

/// Three dots while a take transcribes with no frame yet: white 100/55/28%, stepping
/// unless Reduce Motion is on.
private struct MediaDots: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion { dots(step: 0) }
        else { TimelineView(.periodic(from: .now, by: 0.4)) { context in dots(step: Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3) } }
    }
    private func dots(step: Int) -> some View {
        HStack(spacing: size * 0.8) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(MediaChipTokens.foreground.opacity([1, 0.55, 0.28][(index + 3 - step) % 3])).frame(width: size, height: size)
            }
        }
    }
}

/// The sheen over a Home tile whose project file is still unread: one white 7.5% band
/// at 105°, 40% of the width, sweeping in 2.4 s ease-in-out with a 0.6 s rest.
private struct MediaSheen: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            GeometryReader { geometry in
                let t = min(1, context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 2.4)
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(2 - 2 * t, 2) / 2
                let band = geometry.size.width * 0.4
                LinearGradient(colors: [.clear, MediaChipTokens.foreground.opacity(0.075), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: band, height: geometry.size.height * 1.6)
                    .rotationEffect(.degrees(15))
                    .position(x: -band / 2 + (geometry.size.width + band) * eased, y: geometry.size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Frames for every stand-in (design §5.4.7), decoded off the main actor by
/// AVAssetImageGenerator. A black frame (mean luma under 0.06 with a deviation under
/// 0.02 at 32×18) retries at +1 s, +3 s and 10% into the scope. Frames are kept by
/// content key, time to 0.1 s and pixel size: in memory, and as a poster JPEG in the
/// content key's cache entry, which cache eviction counts and strips in its first pass.
actor ThumbnailCache {
    enum Result: Sendable { case frame(CGImage), black, unreadable }
    static let shared = ThumbnailCache()
    private struct Key: Hashable { let contentKey: String; let tenths: Int; let width: Int; let height: Int }
    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private let limit = 256

    /// A frame near `time` that fills `size` points at 2x whatever the source aspect;
    /// nil when the task was cancelled.
    func frame(of url: URL, contentKey: String, at time: Double, scope: ClosedRange<Double>, filling size: CGSize, cache: URL?) async -> Result? {
        let time = time.isFinite ? max(0, time) : 0
        let box = CGSize(width: (2 * max(size.width, size.height * 16 / 9)).rounded(), height: (2 * max(size.height, size.width * 16 / 9)).rounded())
        let key = Key(contentKey: contentKey, tenths: Int((time * 10).rounded()), width: Int(box.width), height: Int(box.height))
        if let cached = images[key] { return .frame(cached) }
        // Home's recent projects are not open, so the poster's entry is leased while it is read or written (architecture §8.2).
        var lease: CacheKeyLease?
        if let cache { lease = await CacheKeyRegistry.shared(cache: cache).lease(contentKey) }
        defer { lease?.release() }
        let poster = Self.posterFolder(in: cache, contentKey: key.contentKey, create: false).map { Self.posterURL(in: $0, for: key) }
        if let poster, let image = Self.readPoster(poster) {
            remember(image, for: key)
            return .frame(image)
        }
        let request = FrameRequest(url: url)
        let result = await withTaskCancellationHandler {
            await request.choose(at: time, scope: scope, maximumSize: box)
        } onCancel: {
            request.cancel()
        }
        guard !Task.isCancelled else { return nil }
        if case .frame(let image) = result {
            remember(image, for: key)
            if let folder = Self.posterFolder(in: cache, contentKey: key.contentKey, create: true) { Self.writePoster(image, to: Self.posterURL(in: folder, for: key)) }
        }
        return result
    }

    private func remember(_ image: CGImage, for key: Key) {
        if images.updateValue(image, forKey: key) == nil { order.append(key) }
        if order.count > limit { images[order.removeFirst()] = nil }
    }

    /// `Cache/<contentKey>/thumbs/`, for well-formed keys and only through real folders.
    /// An entry or `thumbs` folder that is a link or a file skips the disk cache, as
    /// CacheStore refuses such entries (architecture §8.2). `create` makes a missing
    /// folder one level at a time, never through a link.
    static func posterFolder(in cache: URL?, contentKey: String, create: Bool) -> URL? {
        guard let cache, contentKey.count == 64, contentKey.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        // The cache root is the app's own folder, made on first use.
        if (try? FileManager.default.attributesOfItem(atPath: cache.path)) == nil {
            guard create, (try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)) != nil else { return nil }
        }
        let entry = cache.appendingPathComponent(contentKey, isDirectory: true)
        for folder in [entry, entry.appendingPathComponent("thumbs", isDirectory: true)] where !CacheStore.isRealDirectory(folder) {
            guard create, (try? FileManager.default.attributesOfItem(atPath: folder.path)) == nil,
                  (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil, CacheStore.isRealDirectory(folder) else { return nil }
        }
        return entry.appendingPathComponent("thumbs", isDirectory: true)
    }
    /// `poster-<tenths>-<w>x<h>.jpg` in the poster folder.
    private static func posterURL(in folder: URL, for key: Key) -> URL {
        folder.appendingPathComponent("poster-\(key.tenths)-\(key.width)x\(key.height).jpg")
    }
    /// A poster that is a regular file, never a link.
    static func readPoster(_ url: URL) -> CGImage? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    private static func writePoster(_ image: CGImage, to url: URL) {
        let folder = url.deletingLastPathComponent()
        // Never replace a link or a folder that sits where the poster goes.
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile != true || values.isSymbolicLink == true { return }
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), (try? FileManager.default.replaceItemAt(url, withItemAt: temporary)) != nil else {
            try? FileManager.default.removeItem(at: temporary)
            return
        }
    }
}

/// One frame choice. Its generators serve only this request, and
/// cancelAllCGImageGeneration is safe to call from the cancellation handler.
private final class FrameRequest: @unchecked Sendable {
    private let asset: AVURLAsset
    private let lock = NSLock()
    private var generators: [AVAssetImageGenerator] = []

    init(url: URL) { asset = AVURLAsset(url: url) }

    /// The first non-black frame of `time`, +1 s, +3 s and 10% into `scope`, clamped to
    /// the take; `.black` when all are black and `.unreadable` when none decodes.
    func choose(at time: Double, scope: ClosedRange<Double>, maximumSize: CGSize) async -> ThumbnailCache.Result {
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else { return .unreadable }
        let last = max(0, duration.seconds - 0.1)
        let probe = generator(maximumSize: CGSize(width: 32, height: 18))
        var decoded = false
        for candidate in [time, time + 1, time + 3, scope.lowerBound + 0.1 * (scope.upperBound - scope.lowerBound)] {
            guard !Task.isCancelled else { return .black }
            let at = CMTime(seconds: min(last, max(0, candidate)), preferredTimescale: 600)
            guard let small = try? await probe.image(at: at).image else { continue }
            decoded = true
            if ThumbnailCache.isBlack(small) { continue }
            guard let image = try? await generator(maximumSize: maximumSize).image(at: at).image else { return .unreadable }
            return .frame(image)
        }
        return decoded ? .black : .unreadable
    }

    func cancel() { lock.withLock { generators }.forEach { $0.cancelAllCGImageGeneration() } }

    private func generator(maximumSize: CGSize) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        lock.withLock { generators.append(generator) }
        return generator
    }
}

extension ThumbnailCache {
    /// Mean luma under 0.06 with a standard deviation under 0.02, drawn at 32×18.
    nonisolated static func isBlack(_ image: CGImage) -> Bool {
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        var sum = 0.0, squares = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let luma = (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255
            sum += luma
            squares += luma * luma
        }
        let count = Double(width * height), mean = sum / count
        return mean < 0.06 && max(0, squares / count - mean * mean).squareRoot() < 0.02
    }
}
