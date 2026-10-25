import Foundation

/// doc/architecture.md §3; shared/schemas/project.schema.json
public enum ProjectPlatform: String, Codable, Sendable, Hashable, CaseIterable {
    case macos
    case windows
}

/// Clip range provenance; editing §2.5.
public enum ClipOrigin: String, Codable, Sendable, Hashable, CaseIterable {
    case manual
    case ai
}

/// Persisted output aspect; architecture §4.1 and project schema `$defs.export`.
public enum AspectRatio: String, Codable, Sendable, Hashable, CaseIterable {
    case source
    case landscape = "16:9"
    case portrait = "9:16"
    case square = "1:1"
}

/// Output codec capability; architecture §4.1. M1 exports only H.264.
public enum VideoCodec: String, Codable, Sendable, Hashable, CaseIterable {
    case h264
    case hevc
}

/// Export bitrate multiplier; architecture §4.1.
public enum ExportQuality: String, Codable, Sendable, Hashable, CaseIterable {
    case standard
    case high
}

/// Runtime frame rate selection; architecture §4.1. Never stored in ProjectExport.
public enum ExportFrameRate: Codable, Sendable, Equatable {
    case source
    case fixed(Double)
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self), text == "source" { self = .source }
        else { self = .fixed(try value.decode(Double.self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self { case .source: try value.encode("source"); case .fixed(let fps): try value.encode(fps) }
    }
}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct ProjectWriter: Codable, Sendable, Equatable {
    /// app; doc/architecture.md §3; shared/schemas/project.schema.json
    public var app: String
    /// version; doc/architecture.md §3; shared/schemas/project.schema.json
    public var version: String
    /// platform; doc/architecture.md §3; shared/schemas/project.schema.json
    public var platform: ProjectPlatform

    /// Creates an explicit value without I/O or generated identifiers.
    public init(app: String = "VoxClip", version: String = "0.1.0", platform: ProjectPlatform = .macos) {
        self.app = app
        self.version = version
        self.platform = platform
    }

    private enum CodingKeys: String, CodingKey {
        case app
        case version
        case platform
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.app = try values.decode(String.self, forKey: .app)
        self.version = try values.decode(String.self, forKey: .version)
        self.platform = try values.decode(ProjectPlatform.self, forKey: .platform)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.app, forKey: .app)
        try values.encode(self.version, forKey: .version)
        try values.encode(self.platform, forKey: .platform)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct MediaVideo: Codable, Sendable, Equatable {
    /// width; doc/architecture.md §3; shared/schemas/project.schema.json
    public var width: Int
    /// height; doc/architecture.md §3; shared/schemas/project.schema.json
    public var height: Int
    /// frameRate; doc/architecture.md §3; shared/schemas/project.schema.json
    public var frameRate: Double
    /// rotationDegrees; doc/architecture.md §3; shared/schemas/project.schema.json
    public var rotationDegrees: Int

    /// Creates an explicit value without I/O or generated identifiers.
    public init(width: Int, height: Int, frameRate: Double, rotationDegrees: Int = 0) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.rotationDegrees = rotationDegrees
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case frameRate
        case rotationDegrees
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.width = try values.decode(Int.self, forKey: .width)
        self.height = try values.decode(Int.self, forKey: .height)
        self.frameRate = try values.decode(Double.self, forKey: .frameRate)
        self.rotationDegrees = try values.decode(Int.self, forKey: .rotationDegrees)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.width, forKey: .width)
        try values.encode(self.height, forKey: .height)
        try values.encode(self.frameRate, forKey: .frameRate)
        try values.encode(self.rotationDegrees, forKey: .rotationDegrees)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct MediaAudio: Codable, Sendable, Equatable {
    /// sampleRate; doc/architecture.md §3; shared/schemas/project.schema.json
    public var sampleRate: Int
    /// channels; doc/architecture.md §3; shared/schemas/project.schema.json
    public var channels: Int

    /// Creates an explicit value without I/O or generated identifiers.
    public init(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    private enum CodingKeys: String, CodingKey {
        case sampleRate
        case channels
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.sampleRate = try values.decode(Int.self, forKey: .sampleRate)
        self.channels = try values.decode(Int.self, forKey: .channels)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.sampleRate, forKey: .sampleRate)
        try values.encode(self.channels, forKey: .channels)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct MediaReference: Codable, Sendable, Equatable {
    /// absolutePath; doc/architecture.md §3; shared/schemas/project.schema.json
    public var absolutePath: String
    /// relativePath; doc/architecture.md §3; shared/schemas/project.schema.json
    public var relativePath: String?
    /// sizeBytes; doc/architecture.md §3; shared/schemas/project.schema.json
    public var sizeBytes: Int64
    /// durationSeconds; doc/architecture.md §3; shared/schemas/project.schema.json
    public var durationSeconds: Double
    /// contentKey; doc/architecture.md §3; shared/schemas/project.schema.json
    public var contentKey: String
    /// video; doc/architecture.md §3; shared/schemas/project.schema.json
    public var video: MediaVideo?
    /// audio; doc/architecture.md §3; shared/schemas/project.schema.json
    public var audio: MediaAudio?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(absolutePath: String, relativePath: String? = nil, sizeBytes: Int64, durationSeconds: Double, contentKey: String, video: MediaVideo? = nil, audio: MediaAudio? = nil) {
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.contentKey = contentKey
        self.video = video
        self.audio = audio
    }

    private enum CodingKeys: String, CodingKey {
        case absolutePath
        case relativePath
        case sizeBytes
        case durationSeconds
        case contentKey
        case video
        case audio
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.absolutePath = try values.decode(String.self, forKey: .absolutePath)
        self.relativePath = try values.decode(Optional<String>.self, forKey: .relativePath)
        self.sizeBytes = try values.decode(Int64.self, forKey: .sizeBytes)
        self.durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
        self.contentKey = try values.decode(String.self, forKey: .contentKey)
        self.video = try values.decode(Optional<MediaVideo>.self, forKey: .video)
        self.audio = try values.decode(Optional<MediaAudio>.self, forKey: .audio)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.absolutePath, forKey: .absolutePath)
        try values.encode(self.relativePath, forKey: .relativePath)
        try values.encode(self.sizeBytes, forKey: .sizeBytes)
        try values.encode(self.durationSeconds, forKey: .durationSeconds)
        try values.encode(self.contentKey, forKey: .contentKey)
        try values.encode(self.video, forKey: .video)
        try values.encode(self.audio, forKey: .audio)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct ProjectMedia: Codable, Sendable, Equatable {
    /// source; doc/architecture.md §3; shared/schemas/project.schema.json
    public var source: MediaReference

    /// Creates an explicit value without I/O or generated identifiers.
    public init(source: MediaReference) {
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case source
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try values.decode(MediaReference.self, forKey: .source)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.source, forKey: .source)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct ClipRange: Codable, Sendable, Equatable {
    /// id; doc/architecture.md §3; shared/schemas/project.schema.json
    public var id: String
    /// startWordId; doc/architecture.md §3; shared/schemas/project.schema.json
    public var startWordId: String
    /// endWordId; doc/architecture.md §3; shared/schemas/project.schema.json
    public var endWordId: String
    /// title; doc/architecture.md §3; shared/schemas/project.schema.json
    public var title: String?
    /// origin; doc/architecture.md §3; shared/schemas/project.schema.json
    public var origin: ClipOrigin
    /// aiResultId; doc/architecture.md §3; shared/schemas/project.schema.json
    public var aiResultId: String?
    /// aiClipIndex; doc/architecture.md §3; shared/schemas/project.schema.json
    public var aiClipIndex: Int?
    /// Export-list checkbox; editing §2.4 and project schema. New clips start selected.
    public var selected: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(id: String, startWordId: String, endWordId: String, title: String? = nil, origin: ClipOrigin = .manual, aiResultId: String? = nil, aiClipIndex: Int? = nil, selected: Bool = true) {
        self.id = id
        self.startWordId = startWordId
        self.endWordId = endWordId
        self.title = title
        self.origin = origin
        self.aiResultId = aiResultId
        self.aiClipIndex = aiClipIndex
        self.selected = selected
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case startWordId
        case endWordId
        case title
        case origin
        case aiResultId
        case aiClipIndex
        case selected
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.startWordId = try values.decode(String.self, forKey: .startWordId)
        self.endWordId = try values.decode(String.self, forKey: .endWordId)
        self.title = try values.decode(Optional<String>.self, forKey: .title)
        self.origin = try values.decode(ClipOrigin.self, forKey: .origin)
        self.aiResultId = try values.decode(Optional<String>.self, forKey: .aiResultId)
        self.aiClipIndex = try values.decode(Optional<Int>.self, forKey: .aiClipIndex)
        self.selected = try values.decode(Bool.self, forKey: .selected)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.id, forKey: .id)
        try values.encode(self.startWordId, forKey: .startWordId)
        try values.encode(self.endWordId, forKey: .endWordId)
        try values.encode(self.title, forKey: .title)
        try values.encode(self.origin, forKey: .origin)
        try values.encode(self.aiResultId, forKey: .aiResultId)
        try values.encode(self.aiClipIndex, forKey: .aiClipIndex)
        try values.encode(self.selected, forKey: .selected)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct ProjectEdits: Codable, Sendable, Equatable {
    /// pauseThresholdSeconds; doc/architecture.md §3; shared/schemas/project.schema.json
    public var pauseThresholdSeconds: Double
    /// pauseKeepSeconds; doc/architecture.md §3; shared/schemas/project.schema.json
    public var pauseKeepSeconds: Double
    /// cutWordIds; doc/architecture.md §3; shared/schemas/project.schema.json
    public var cutWordIds: [String]
    /// cutPauseIds; doc/architecture.md §3; shared/schemas/project.schema.json
    public var cutPauseIds: [String]
    /// corrections; doc/architecture.md §3; shared/schemas/project.schema.json
    public var corrections: [String: String]
    /// clips; doc/architecture.md §3; shared/schemas/project.schema.json
    public var clips: [ClipRange]
    /// activeClipId; doc/architecture.md §3; shared/schemas/project.schema.json
    public var activeClipId: String?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(pauseThresholdSeconds: Double = 1.0, pauseKeepSeconds: Double = 0.15, cutWordIds: [String] = [], cutPauseIds: [String] = [], corrections: [String: String] = [:], clips: [ClipRange] = [], activeClipId: String? = nil) {
        self.pauseThresholdSeconds = pauseThresholdSeconds
        self.pauseKeepSeconds = pauseKeepSeconds
        self.cutWordIds = cutWordIds
        self.cutPauseIds = cutPauseIds
        self.corrections = corrections
        self.clips = clips
        self.activeClipId = activeClipId
    }

    private enum CodingKeys: String, CodingKey {
        case pauseThresholdSeconds
        case pauseKeepSeconds
        case cutWordIds
        case cutPauseIds
        case corrections
        case clips
        case activeClipId
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.pauseThresholdSeconds = try values.decode(Double.self, forKey: .pauseThresholdSeconds)
        self.pauseKeepSeconds = try values.decode(Double.self, forKey: .pauseKeepSeconds)
        self.cutWordIds = try values.decode([String].self, forKey: .cutWordIds)
        self.cutPauseIds = try values.decode([String].self, forKey: .cutPauseIds)
        self.corrections = try values.decode([String: String].self, forKey: .corrections)
        self.clips = try values.decode([ClipRange].self, forKey: .clips)
        self.activeClipId = try values.decode(Optional<String>.self, forKey: .activeClipId)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.pauseThresholdSeconds, forKey: .pauseThresholdSeconds)
        try values.encode(self.pauseKeepSeconds, forKey: .pauseKeepSeconds)
        try values.encode(self.cutWordIds, forKey: .cutWordIds)
        try values.encode(self.cutPauseIds, forKey: .cutPauseIds)
        try values.encode(self.corrections, forKey: .corrections)
        try values.encode(self.clips, forKey: .clips)
        try values.encode(self.activeClipId, forKey: .activeClipId)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct CaptionPosition: Codable, Sendable, Equatable {
    /// x; doc/architecture.md §3; shared/schemas/project.schema.json
    public var x: Double
    /// y; doc/architecture.md §3; shared/schemas/project.schema.json
    public var y: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.x = try values.decode(Double.self, forKey: .x)
        self.y = try values.decode(Double.self, forKey: .y)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.x, forKey: .x)
        try values.encode(self.y, forKey: .y)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct CaptionSettings: Codable, Sendable, Equatable {
    /// styleId; doc/architecture.md §3; shared/schemas/project.schema.json
    public var styleId: String
    /// overrides; doc/architecture.md §3; shared/schemas/project.schema.json
    public var overrides: [String: JSONValue]
    /// position; doc/architecture.md §3; shared/schemas/project.schema.json
    public var position: CaptionPosition?
    /// positionByAspect; doc/architecture.md §3; shared/schemas/project.schema.json
    public var positionByAspect: [String: CaptionPosition]

    /// Creates an explicit value without I/O or generated identifiers.
    public init(styleId: String = "off", overrides: [String: JSONValue] = [:], position: CaptionPosition? = nil, positionByAspect: [String: CaptionPosition] = [:]) {
        self.styleId = styleId
        self.overrides = overrides
        self.position = position
        self.positionByAspect = positionByAspect
    }

    private enum CodingKeys: String, CodingKey {
        case styleId
        case overrides
        case position
        case positionByAspect
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.styleId = try values.decode(String.self, forKey: .styleId)
        self.overrides = try values.decode([String: JSONValue].self, forKey: .overrides)
        self.position = try values.decode(Optional<CaptionPosition>.self, forKey: .position)
        self.positionByAspect = try values.decode([String: CaptionPosition].self, forKey: .positionByAspect)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.styleId, forKey: .styleId)
        try values.encode(self.overrides, forKey: .overrides)
        try values.encode(self.position, forKey: .position)
        try values.encode(self.positionByAspect, forKey: .positionByAspect)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct ReframeSettings: Codable, Sendable, Equatable {
    /// mode; doc/architecture.md §3; shared/schemas/project.schema.json
    public var mode: String
    /// zoom; doc/architecture.md §3; shared/schemas/project.schema.json
    public var zoom: Double

    /// Creates an explicit value without I/O or generated identifiers.
    public init(mode: String = "center", zoom: Double = 1) {
        self.mode = mode
        self.zoom = zoom
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case zoom
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try values.decode(String.self, forKey: .mode)
        self.zoom = try values.decode(Double.self, forKey: .zoom)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.mode, forKey: .mode)
        try values.encode(self.zoom, forKey: .zoom)
    }

}

/// Derived export configuration; architecture §4.1. Runtime only, not a ProjectExport field.
public struct ExportPreset: Codable, Sendable, Equatable {
    /// id; doc/architecture.md §3; shared/schemas/project.schema.json
    public var id: String
    /// name; doc/architecture.md §3; shared/schemas/project.schema.json
    public var name: String
    /// aspect; doc/architecture.md §3; shared/schemas/project.schema.json
    public var aspect: AspectRatio
    /// width; doc/architecture.md §3; shared/schemas/project.schema.json
    public var width: Int
    /// height; doc/architecture.md §3; shared/schemas/project.schema.json
    public var height: Int
    /// frameRate; doc/architecture.md §3; shared/schemas/project.schema.json
    public var frameRate: ExportFrameRate
    /// videoCodec; doc/architecture.md §3; shared/schemas/project.schema.json
    public var videoCodec: VideoCodec
    /// videoBitrate; doc/architecture.md §3; shared/schemas/project.schema.json
    public var videoBitrate: Int
    /// audioBitrate; doc/architecture.md §3; shared/schemas/project.schema.json
    public var audioBitrate: Int
    /// reframe; doc/architecture.md §3; shared/schemas/project.schema.json
    public var reframe: ReframeSettings
    /// burnCaptions; doc/architecture.md §3; shared/schemas/project.schema.json
    public var burnCaptions: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(id: String, name: String, aspect: AspectRatio, width: Int, height: Int, frameRate: ExportFrameRate = .source, videoCodec: VideoCodec = .h264, videoBitrate: Int = 8_000_000, audioBitrate: Int = 160_000, reframe: ReframeSettings = ReframeSettings(), burnCaptions: Bool = true) {
        self.id = id
        self.name = name
        self.aspect = aspect
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoCodec = videoCodec
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.reframe = reframe
        self.burnCaptions = burnCaptions
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case aspect
        case width
        case height
        case frameRate
        case videoCodec
        case videoBitrate
        case audioBitrate
        case reframe
        case burnCaptions
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.name = try values.decode(String.self, forKey: .name)
        self.aspect = try values.decode(AspectRatio.self, forKey: .aspect)
        self.width = try values.decode(Int.self, forKey: .width)
        self.height = try values.decode(Int.self, forKey: .height)
        self.frameRate = try values.decode(ExportFrameRate.self, forKey: .frameRate)
        self.videoCodec = try values.decode(VideoCodec.self, forKey: .videoCodec)
        self.videoBitrate = try values.decode(Int.self, forKey: .videoBitrate)
        self.audioBitrate = try values.decode(Int.self, forKey: .audioBitrate)
        self.reframe = try values.decode(ReframeSettings.self, forKey: .reframe)
        self.burnCaptions = try values.decode(Bool.self, forKey: .burnCaptions)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.id, forKey: .id)
        try values.encode(self.name, forKey: .name)
        try values.encode(self.aspect, forKey: .aspect)
        try values.encode(self.width, forKey: .width)
        try values.encode(self.height, forKey: .height)
        try values.encode(self.frameRate, forKey: .frameRate)
        try values.encode(self.videoCodec, forKey: .videoCodec)
        try values.encode(self.videoBitrate, forKey: .videoBitrate)
        try values.encode(self.audioBitrate, forKey: .audioBitrate)
        try values.encode(self.reframe, forKey: .reframe)
        try values.encode(self.burnCaptions, forKey: .burnCaptions)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct ProjectExport: Codable, Sendable, Equatable {
    /// Requested aspect; dimensions are derived from the source at export time.
    public var aspect: AspectRatio
    /// Bitrate quality; architecture §4.1.
    public var quality: ExportQuality
    /// Whether to write a subtitle sidecar next to each exported video.
    public var srt: Bool
    /// Last native export folder, or null to use Settings and platform defaults.
    public var folder: String?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(aspect: AspectRatio = .source, quality: ExportQuality = .standard, srt: Bool = false, folder: String? = nil) {
        self.aspect = aspect
        self.quality = quality
        self.srt = srt
        self.folder = folder
    }

    private enum CodingKeys: String, CodingKey {
        case aspect
        case quality
        case srt
        case folder
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.aspect = try values.decode(AspectRatio.self, forKey: .aspect)
        self.quality = try values.decode(ExportQuality.self, forKey: .quality)
        self.srt = try values.decode(Bool.self, forKey: .srt)
        self.folder = try values.decode(Optional<String>.self, forKey: .folder)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.aspect, forKey: .aspect)
        try values.encode(self.quality, forKey: .quality)
        try values.encode(self.srt, forKey: .srt)
        try values.encode(self.folder, forKey: .folder)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct ProjectAIClip: Codable, Sendable, Equatable {
    /// title; doc/architecture.md §3; shared/schemas/project.schema.json
    public var title: String
    /// reason; doc/architecture.md §3; shared/schemas/project.schema.json
    public var reason: String
    /// score; doc/architecture.md §3; shared/schemas/project.schema.json
    public var score: Int
    /// startWordId; doc/architecture.md §3; shared/schemas/project.schema.json
    public var startWordId: String
    /// endWordId; doc/architecture.md §3; shared/schemas/project.schema.json
    public var endWordId: String

    /// Creates an explicit value without I/O or generated identifiers.
    public init(title: String, reason: String, score: Int, startWordId: String, endWordId: String) {
        self.title = title
        self.reason = reason
        self.score = score
        self.startWordId = startWordId
        self.endWordId = endWordId
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case reason
        case score
        case startWordId
        case endWordId
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try values.decode(String.self, forKey: .title)
        self.reason = try values.decode(String.self, forKey: .reason)
        self.score = try values.decode(Int.self, forKey: .score)
        self.startWordId = try values.decode(String.self, forKey: .startWordId)
        self.endWordId = try values.decode(String.self, forKey: .endWordId)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.title, forKey: .title)
        try values.encode(self.reason, forKey: .reason)
        try values.encode(self.score, forKey: .score)
        try values.encode(self.startWordId, forKey: .startWordId)
        try values.encode(self.endWordId, forKey: .endWordId)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct ProjectAIResult: Codable, Sendable, Equatable {
    /// id; doc/architecture.md §3; shared/schemas/project.schema.json
    public var id: String
    /// createdAt; doc/architecture.md §3; shared/schemas/project.schema.json
    public var createdAt: Date
    /// provider; doc/architecture.md §3; shared/schemas/project.schema.json
    public var provider: String
    /// model; doc/architecture.md §3; shared/schemas/project.schema.json
    public var model: String
    /// preset; doc/architecture.md §3; shared/schemas/project.schema.json
    public var preset: ClipPresetID
    /// instructions; doc/architecture.md §3; shared/schemas/project.schema.json
    public var instructions: String?
    /// language; doc/architecture.md §3; shared/schemas/project.schema.json
    public var language: String?
    /// inputSha256; doc/architecture.md §3; shared/schemas/project.schema.json
    public var inputSha256: String
    /// clips; doc/architecture.md §3; shared/schemas/project.schema.json
    public var clips: [ProjectAIClip]

    /// Creates an explicit value without I/O or generated identifiers.
    public init(id: String, createdAt: Date, provider: String, model: String, preset: ClipPresetID, instructions: String? = nil, language: String? = nil, inputSha256: String, clips: [ProjectAIClip] = []) {
        self.id = id
        self.createdAt = createdAt
        self.provider = provider
        self.model = model
        self.preset = preset
        self.instructions = instructions
        self.language = language
        self.inputSha256 = inputSha256
        self.clips = clips
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case provider
        case model
        case preset
        case instructions
        case language
        case inputSha256
        case clips
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
        self.provider = try values.decode(String.self, forKey: .provider)
        self.model = try values.decode(String.self, forKey: .model)
        self.preset = try values.decode(ClipPresetID.self, forKey: .preset)
        self.instructions = try values.decode(Optional<String>.self, forKey: .instructions)
        self.language = try values.decode(Optional<String>.self, forKey: .language)
        self.inputSha256 = try values.decode(String.self, forKey: .inputSha256)
        self.clips = try values.decode([ProjectAIClip].self, forKey: .clips)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.id, forKey: .id)
        try values.encode(self.createdAt, forKey: .createdAt)
        try values.encode(self.provider, forKey: .provider)
        try values.encode(self.model, forKey: .model)
        try values.encode(self.preset, forKey: .preset)
        try values.encode(self.instructions, forKey: .instructions)
        try values.encode(self.language, forKey: .language)
        try values.encode(self.inputSha256, forKey: .inputSha256)
        try values.encode(self.clips, forKey: .clips)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct ProjectAI: Codable, Sendable, Equatable {
    /// results; doc/architecture.md §3; shared/schemas/project.schema.json
    public var results: [ProjectAIResult]

    /// Creates an explicit value without I/O or generated identifiers.
    public init(results: [ProjectAIResult] = []) {
        self.results = results
    }

    private enum CodingKeys: String, CodingKey {
        case results
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.results = try values.decode([ProjectAIResult].self, forKey: .results)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.results, forKey: .results)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct ProjectVoiceLab: Codable, Sendable, Equatable {
    /// segments; doc/architecture.md §3; shared/schemas/project.schema.json
    public var segments: [VoiceLabSegment]
    /// Absent in v1; present in v2, even when empty.
    public var assets: [VoiceLabAsset]?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(segments: [VoiceLabSegment] = [], assets: [VoiceLabAsset]? = nil) {
        self.segments = segments
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case segments
        case assets
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.segments = try values.decode([VoiceLabSegment].self, forKey: .segments)
        self.assets = try values.decodeIfPresent([VoiceLabAsset].self, forKey: .assets)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.segments, forKey: .segments)
        try values.encodeIfPresent(self.assets, forKey: .assets)
    }

}

/// Share-helper captions by export target; publishing §2.1 and project schema `$defs.share`.
public struct ProjectShare: Codable, Sendable, Equatable {
    /// Edited share text keyed by "full" or a clip id. Loading prunes removed clip ids.
    public var captions: [String: String]

    /// Creates share state without publishing, network calls, or filesystem access.
    public init(captions: [String: String] = [:]) {
        self.captions = captions
    }
}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct Project: Codable, Sendable, Equatable {
    /// format; doc/architecture.md §3; shared/schemas/project.schema.json
    public var format: String
    /// schemaVersion; doc/architecture.md §3; shared/schemas/project.schema.json
    public var schemaVersion: Int
    /// id; doc/architecture.md §3; shared/schemas/project.schema.json
    public var id: String
    /// title; doc/architecture.md §3; shared/schemas/project.schema.json
    public var title: String?
    /// createdAt; doc/architecture.md §3; shared/schemas/project.schema.json
    public var createdAt: Date
    /// modifiedAt; doc/architecture.md §3; shared/schemas/project.schema.json
    public var modifiedAt: Date
    /// savedBy; doc/architecture.md §3; shared/schemas/project.schema.json
    public var savedBy: ProjectWriter
    /// media; doc/architecture.md §3; shared/schemas/project.schema.json
    public var media: ProjectMedia
    /// transcript; doc/architecture.md §3; shared/schemas/project.schema.json
    public var transcript: Transcript?
    /// edits; doc/architecture.md §3; shared/schemas/project.schema.json
    public var edits: ProjectEdits
    /// captions; doc/architecture.md §3; shared/schemas/project.schema.json
    public var captions: CaptionSettings
    /// export; doc/architecture.md §3; shared/schemas/project.schema.json
    public var export: ProjectExport
    /// Share-helper state; publishing §2.1 and project schema.
    public var share: ProjectShare
    /// ai; doc/architecture.md §3; shared/schemas/project.schema.json
    public var ai: ProjectAI
    /// voiceLab; doc/architecture.md §3; shared/schemas/project.schema.json
    public var voiceLab: ProjectVoiceLab
    /// extensions; doc/architecture.md §3; shared/schemas/project.schema.json
    public var extensions: [String: JSONValue]?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(format: String = "voxclip-project", schemaVersion: Int = 1, id: String, title: String? = nil, createdAt: Date, modifiedAt: Date, savedBy: ProjectWriter = ProjectWriter(), media: ProjectMedia, transcript: Transcript? = nil, edits: ProjectEdits = ProjectEdits(), captions: CaptionSettings = CaptionSettings(), export: ProjectExport = ProjectExport(), share: ProjectShare = ProjectShare(), ai: ProjectAI = ProjectAI(), voiceLab: ProjectVoiceLab = ProjectVoiceLab(), extensions: [String: JSONValue]? = nil) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.savedBy = savedBy
        self.media = media
        self.transcript = transcript
        self.edits = edits
        self.captions = captions
        self.export = export
        self.share = share
        self.ai = ai
        self.voiceLab = voiceLab
        self.extensions = extensions
    }

    private enum CodingKeys: String, CodingKey {
        case format
        case schemaVersion
        case id
        case title
        case createdAt
        case modifiedAt
        case savedBy
        case media
        case transcript
        case edits
        case captions
        case export
        case share
        case ai
        case voiceLab
        case extensions
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.format = try values.decode(String.self, forKey: .format)
        self.schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        self.id = try values.decode(String.self, forKey: .id)
        self.title = try values.decodeIfPresent(String.self, forKey: .title) ?? nil
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
        self.modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        self.savedBy = try values.decode(ProjectWriter.self, forKey: .savedBy)
        self.media = try values.decode(ProjectMedia.self, forKey: .media)
        self.transcript = try values.decode(Optional<Transcript>.self, forKey: .transcript)
        self.edits = try values.decode(ProjectEdits.self, forKey: .edits)
        self.captions = try values.decode(CaptionSettings.self, forKey: .captions)
        self.export = try values.decode(ProjectExport.self, forKey: .export)
        self.share = try values.decode(ProjectShare.self, forKey: .share)
        self.ai = try values.decode(ProjectAI.self, forKey: .ai)
        self.voiceLab = try values.decode(ProjectVoiceLab.self, forKey: .voiceLab)
        self.extensions = try values.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.format, forKey: .format)
        try values.encode(self.schemaVersion, forKey: .schemaVersion)
        try values.encode(self.id, forKey: .id)
        try values.encodeIfPresent(self.title, forKey: .title)
        try values.encode(self.createdAt, forKey: .createdAt)
        try values.encode(self.modifiedAt, forKey: .modifiedAt)
        try values.encode(self.savedBy, forKey: .savedBy)
        try values.encode(self.media, forKey: .media)
        try values.encode(self.transcript, forKey: .transcript)
        try values.encode(self.edits, forKey: .edits)
        try values.encode(self.captions, forKey: .captions)
        try values.encode(self.export, forKey: .export)
        try values.encode(self.share, forKey: .share)
        try values.encode(self.ai, forKey: .ai)
        try values.encode(self.voiceLab, forKey: .voiceLab)
        try values.encodeIfPresent(self.extensions, forKey: .extensions)
    }

}
