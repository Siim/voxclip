import Foundation

/// Framework-free pixel dimensions; architecture §4.1.
public struct PixelSize: Codable, Sendable, Equatable {
    /// width; Framework-free pixel dimensions; architecture §4.1.
    public var width: Int
    /// height; Framework-free pixel dimensions; architecture §4.1.
    public var height: Int

    /// Creates an explicit value without I/O or generated identifiers.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.width = try values.decode(Int.self, forKey: .width)
        self.height = try values.decode(Int.self, forKey: .height)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.width, forKey: .width)
        try values.encode(self.height, forKey: .height)
    }

}

/// Resolved export encoding description; architecture §4.1 and §5.6.
public struct OutputSpec: Codable, Sendable, Equatable {
    /// size; Resolved export encoding description; architecture §4.1 and §5.6.
    public var size: PixelSize
    /// fps; Resolved export encoding description; architecture §4.1 and §5.6.
    public var fps: Double
    /// videoBitrate; Resolved export encoding description; architecture §4.1 and §5.6.
    public var videoBitrate: Int
    /// audioSampleRate; Resolved export encoding description; architecture §4.1 and §5.6.
    public var audioSampleRate: Int
    /// audioChannels; Resolved export encoding description; architecture §4.1 and §5.6.
    public var audioChannels: Int
    /// audioBitrate; Resolved export encoding description; architecture §4.1 and §5.6.
    public var audioBitrate: Int
    /// quality; Resolved export encoding description; architecture §4.1 and §5.6.
    public var quality: ExportQuality

    /// Creates an explicit value without I/O or generated identifiers.
    public init(size: PixelSize, fps: Double, videoBitrate: Int, audioSampleRate: Int = 48_000, audioChannels: Int = 2, audioBitrate: Int = 160_000, quality: ExportQuality = .standard) {
        self.size = size
        self.fps = fps
        self.videoBitrate = videoBitrate
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.audioBitrate = audioBitrate
        self.quality = quality
    }

    private enum CodingKeys: String, CodingKey {
        case size
        case fps
        case videoBitrate
        case audioSampleRate
        case audioChannels
        case audioBitrate
        case quality
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.size = try values.decode(PixelSize.self, forKey: .size)
        self.fps = try values.decode(Double.self, forKey: .fps)
        self.videoBitrate = try values.decode(Int.self, forKey: .videoBitrate)
        self.audioSampleRate = try values.decodeIfPresent(Int.self, forKey: .audioSampleRate) ?? 48_000
        self.audioChannels = try values.decodeIfPresent(Int.self, forKey: .audioChannels) ?? 2
        self.audioBitrate = try values.decodeIfPresent(Int.self, forKey: .audioBitrate) ?? 160_000
        self.quality = try values.decodeIfPresent(ExportQuality.self, forKey: .quality) ?? .standard
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.size, forKey: .size)
        try values.encode(self.fps, forKey: .fps)
        try values.encode(self.videoBitrate, forKey: .videoBitrate)
        try values.encode(self.audioSampleRate, forKey: .audioSampleRate)
        try values.encode(self.audioChannels, forKey: .audioChannels)
        try values.encode(self.audioBitrate, forKey: .audioBitrate)
        try values.encode(self.quality, forKey: .quality)
    }

}

/// Loaded source facts, never an AVAsset; architecture §4.1 and §5.1.
public struct MediaProbeResult: Codable, Sendable, Equatable {
    /// durationSeconds; Loaded source facts, never an AVAsset; architecture §4.1 and §5.1.
    public var durationSeconds: Double
    /// video; Loaded source facts, never an AVAsset; architecture §4.1 and §5.1.
    public var video: MediaVideo?
    /// audio; Loaded source facts, never an AVAsset; architecture §4.1 and §5.1.
    public var audio: MediaAudio?
    /// orientedSize; Loaded source facts, never an AVAsset; architecture §4.1 and §5.1.
    public var orientedSize: PixelSize?
    /// videoCodec; Loaded source facts, never an AVAsset; architecture §4.1 and §5.1.
    public var videoCodec: String?
    /// isHDR; Loaded source facts, never an AVAsset; architecture §4.1 and §5.1.
    public var isHDR: Bool
    /// isPlayable; Loaded source facts, never an AVAsset; architecture §4.1 and §5.1.
    public var isPlayable: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(durationSeconds: Double, video: MediaVideo? = nil, audio: MediaAudio? = nil, orientedSize: PixelSize? = nil, videoCodec: String? = nil, isHDR: Bool = false, isPlayable: Bool) {
        self.durationSeconds = durationSeconds
        self.video = video
        self.audio = audio
        self.orientedSize = orientedSize
        self.videoCodec = videoCodec
        self.isHDR = isHDR
        self.isPlayable = isPlayable
    }

    private enum CodingKeys: String, CodingKey {
        case durationSeconds
        case video
        case audio
        case orientedSize
        case videoCodec
        case isHDR
        case isPlayable
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
        self.video = try values.decodeIfPresent(MediaVideo.self, forKey: .video) ?? nil
        self.audio = try values.decodeIfPresent(MediaAudio.self, forKey: .audio) ?? nil
        self.orientedSize = try values.decodeIfPresent(PixelSize.self, forKey: .orientedSize) ?? nil
        self.videoCodec = try values.decodeIfPresent(String.self, forKey: .videoCodec) ?? nil
        self.isHDR = try values.decodeIfPresent(Bool.self, forKey: .isHDR) ?? false
        self.isPlayable = try values.decode(Bool.self, forKey: .isPlayable)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.durationSeconds, forKey: .durationSeconds)
        try values.encode(self.video, forKey: .video)
        try values.encode(self.audio, forKey: .audio)
        try values.encode(self.orientedSize, forKey: .orientedSize)
        try values.encode(self.videoCodec, forKey: .videoCodec)
        try values.encode(self.isHDR, forKey: .isHDR)
        try values.encode(self.isPlayable, forKey: .isPlayable)
    }

}

/// Audio extraction input; architecture §4.2 and §5.1.
public struct AudioExtractionRequest: Codable, Sendable, Equatable {
    /// sourceURL; Audio extraction input; architecture §4.2 and §5.1.
    public var sourceURL: URL
    /// contentKey; Audio extraction input; architecture §4.2 and §5.1.
    public var contentKey: String
    /// durationSeconds; Audio extraction input; architecture §4.2 and §5.1.
    public var durationSeconds: Double
    /// audioTrackIndex; Audio extraction input; architecture §4.2 and §5.1.
    public var audioTrackIndex: Int
    /// cacheDirectory; Audio extraction input; architecture §4.2 and §5.1.
    public var cacheDirectory: URL

    /// Creates an explicit value without I/O or generated identifiers.
    public init(sourceURL: URL, contentKey: String, durationSeconds: Double, audioTrackIndex: Int = 0, cacheDirectory: URL) {
        self.sourceURL = sourceURL
        self.contentKey = contentKey
        self.durationSeconds = durationSeconds
        self.audioTrackIndex = audioTrackIndex
        self.cacheDirectory = cacheDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case sourceURL
        case contentKey
        case durationSeconds
        case audioTrackIndex
        case cacheDirectory
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceURL = try values.decode(URL.self, forKey: .sourceURL)
        self.contentKey = try values.decode(String.self, forKey: .contentKey)
        self.durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
        self.audioTrackIndex = try values.decodeIfPresent(Int.self, forKey: .audioTrackIndex) ?? 0
        self.cacheDirectory = try values.decode(URL.self, forKey: .cacheDirectory)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.sourceURL, forKey: .sourceURL)
        try values.encode(self.contentKey, forKey: .contentKey)
        try values.encode(self.durationSeconds, forKey: .durationSeconds)
        try values.encode(self.audioTrackIndex, forKey: .audioTrackIndex)
        try values.encode(self.cacheDirectory, forKey: .cacheDirectory)
    }

}

/// One pass produces transcription WAV plus source-rate envelope; architecture §4.2.
public struct AudioExtractionResult: Sendable, Equatable {
    public var audio: ExtractedAudio
    public var envelope: AudioEnvelope
    public init(audio: ExtractedAudio, envelope: AudioEnvelope) { self.audio = audio; self.envelope = envelope }
}
/// Probe abstraction implemented in Media; architecture §2.1, §5.1.
public protocol MediaProbe: Sendable { func probe(_ source: URL) async throws -> MediaProbeResult }
/// Streaming audio extraction abstraction; architecture §2.1, §5.1.
public protocol AudioExtractor: Sendable {
    func extract(_ request: AudioExtractionRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> AudioExtractionResult
}
/// Shared rendering input, no AVFoundation ownership crosses actors; architecture §7.1.
public struct RenderRequest: Sendable, Equatable {
    public var sourceURL: URL
    public var plan: EditPlan
    public var captions: CaptionTrack
    public var style: CaptionStyle?
    public var placement: CaptionPosition?
    public var output: OutputSpec
    public var forPreview: Bool
    public var captionLayout: CaptionLayoutResult?
    public init(sourceURL: URL, plan: EditPlan, captions: CaptionTrack = CaptionTrack(), style: CaptionStyle? = nil, placement: CaptionPosition? = nil, output: OutputSpec, forPreview: Bool = false, captionLayout: CaptionLayoutResult? = nil) {
        self.sourceURL = sourceURL; self.plan = plan; self.captions = captions; self.style = style; self.placement = placement; self.output = output; self.forPreview = forPreview
        self.captionLayout = captionLayout
    }
}
/// Export selection, never a rewrite of global cuts; architecture §4.9.
public enum ExportTarget: Codable, Sendable, Equatable { case fullEdit; case clip(String) }
/// Sequential export job; architecture §4.9, §5.6 and §7.1.
public struct ExportJob: Sendable, Equatable {
    public var target: ExportTarget
    public var render: RenderRequest
    public var aspect: AspectRatio
    public var quality: ExportQuality
    public var outputURL: URL
    public var writeSRT: Bool
    public var srtURL: URL?
    public init(target: ExportTarget = .fullEdit, render: RenderRequest, aspect: AspectRatio = .source, quality: ExportQuality = .standard, outputURL: URL, writeSRT: Bool = false, srtURL: URL? = nil) {
        self.target = target; self.render = render; self.aspect = aspect; self.quality = quality; self.outputURL = outputURL; self.writeSRT = writeSRT; self.srtURL = srtURL
    }
}

/// Export phases; architecture §5.6.
public enum ExportPhase: String, Codable, Sendable, Hashable, CaseIterable {
    case preparing
    case encoding
    case finalizing
}

/// Progress is coalesced to at most 10 Hz; architecture §7.1.
public struct ExportProgress: Codable, Sendable, Equatable {
    /// phase; Progress is coalesced to at most 10 Hz; architecture §7.1.
    public var phase: ExportPhase
    /// fraction; Progress is coalesced to at most 10 Hz; architecture §7.1.
    public var fraction: Double?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(phase: ExportPhase, fraction: Double? = nil) {
        self.phase = phase
        self.fraction = fraction
    }

    private enum CodingKeys: String, CodingKey {
        case phase
        case fraction
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.phase = try values.decode(ExportPhase.self, forKey: .phase)
        self.fraction = try values.decodeIfPresent(Double.self, forKey: .fraction) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.phase, forKey: .phase)
        try values.encode(self.fraction, forKey: .fraction)
    }

}

/// Headless export facts; architecture §9.3.
public struct ExportResult: Codable, Sendable, Equatable {
    /// outputURL; Headless export facts; architecture §9.3.
    public var outputURL: URL
    /// srtURL; Headless export facts; architecture §9.3.
    public var srtURL: URL?
    /// durationSeconds; Headless export facts; architecture §9.3.
    public var durationSeconds: Double
    /// width; Headless export facts; architecture §9.3.
    public var width: Int
    /// height; Headless export facts; architecture §9.3.
    public var height: Int
    /// fps; Headless export facts; architecture §9.3.
    public var fps: Double
    /// frames; Headless export facts; architecture §9.3.
    public var frames: Int64
    /// audioSampleRate; Headless export facts; architecture §9.3.
    public var audioSampleRate: Int
    /// audioSamples; Headless export facts; architecture §9.3.
    public var audioSamples: Int64
    /// videoCodec; Headless export facts; architecture §9.3.
    public var videoCodec: String
    /// encoder; Headless export facts; architecture §9.3.
    public var encoder: String
    /// elapsedSeconds; Headless export facts; architecture §9.3.
    public var elapsedSeconds: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(outputURL: URL, srtURL: URL? = nil, durationSeconds: Double, width: Int, height: Int, fps: Double, frames: Int64, audioSampleRate: Int, audioSamples: Int64, videoCodec: String, encoder: String, elapsedSeconds: Double) {
        self.outputURL = outputURL
        self.srtURL = srtURL
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.fps = fps
        self.frames = frames
        self.audioSampleRate = audioSampleRate
        self.audioSamples = audioSamples
        self.videoCodec = videoCodec
        self.encoder = encoder
        self.elapsedSeconds = elapsedSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case outputURL
        case srtURL
        case durationSeconds
        case width
        case height
        case fps
        case frames
        case audioSampleRate
        case audioSamples
        case videoCodec
        case encoder
        case elapsedSeconds
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.outputURL = try values.decode(URL.self, forKey: .outputURL)
        self.srtURL = try values.decodeIfPresent(URL.self, forKey: .srtURL) ?? nil
        self.durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
        self.width = try values.decode(Int.self, forKey: .width)
        self.height = try values.decode(Int.self, forKey: .height)
        self.fps = try values.decode(Double.self, forKey: .fps)
        self.frames = try values.decode(Int64.self, forKey: .frames)
        self.audioSampleRate = try values.decode(Int.self, forKey: .audioSampleRate)
        self.audioSamples = try values.decode(Int64.self, forKey: .audioSamples)
        self.videoCodec = try values.decode(String.self, forKey: .videoCodec)
        self.encoder = try values.decode(String.self, forKey: .encoder)
        self.elapsedSeconds = try values.decode(Double.self, forKey: .elapsedSeconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.outputURL, forKey: .outputURL)
        try values.encode(self.srtURL, forKey: .srtURL)
        try values.encode(self.durationSeconds, forKey: .durationSeconds)
        try values.encode(self.width, forKey: .width)
        try values.encode(self.height, forKey: .height)
        try values.encode(self.fps, forKey: .fps)
        try values.encode(self.frames, forKey: .frames)
        try values.encode(self.audioSampleRate, forKey: .audioSampleRate)
        try values.encode(self.audioSamples, forKey: .audioSamples)
        try values.encode(self.videoCodec, forKey: .videoCodec)
        try values.encode(self.encoder, forKey: .encoder)
        try values.encode(self.elapsedSeconds, forKey: .elapsedSeconds)
    }

}

/// One exporter for the app and CLI; architecture §2.1, §5.6.
public protocol Exporter: Sendable {
    func export(_ job: ExportJob, progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult
}
/// UI-facing preview clock and frames; architecture §5.5 and §7.1.
public enum PreviewEvent: Sendable, Equatable {
    case time(edited: Double, source: Double)
    case playing(Bool)
    case frame(PreviewFrame)
    case failed(VoxClipError)
}
/// Optional transport for software frames; native AVPlayer stays in Media on MainActor; architecture §7.1.
public struct PreviewFrame: Sendable, Equatable {
    public var size: PixelSize
    public var rgba: Data
    public var time: Double
    public init(size: PixelSize, rgba: Data, time: Double) { self.size = size; self.rgba = rgba; self.time = time }
}
/// Main-actor preview graph never escapes to another actor; architecture §5.5, §7.1.
@MainActor public protocol PreviewEngine: AnyObject, Sendable {
    var events: AsyncStream<PreviewEvent> { get }
    var isPlaying: Bool { get }
    var editedTime: Double { get }
    func load(_ request: RenderRequest) async throws
    func update(_ request: RenderRequest) async throws
    func seek(to editedTime: Double, exact: Bool) async throws
    func play()
    func pause()
    func close()
}
