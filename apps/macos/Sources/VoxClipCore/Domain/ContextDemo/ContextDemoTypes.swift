import Foundation

public enum ContextDemoTargetKind: String, Codable, Sendable, Equatable {
    case desktopApp, codeProject, webPage
}

public struct ContextDemoTarget: Codable, Sendable, Equatable {
    public let kind: ContextDemoTargetKind
    public let displayName: String
    public let locator: String

    public init(kind: ContextDemoTargetKind, displayName: String, locator: String) {
        self.kind = kind
        self.displayName = displayName
        self.locator = locator
    }
}

public struct ContextDemoWindowBinding: Codable, Sendable, Equatable {
    public let windowID: UInt32
    public let processID: Int32
    public let bundleID: String

    public init(windowID: UInt32, processID: Int32, bundleID: String) {
        self.windowID = windowID
        self.processID = processID
        self.bundleID = bundleID
    }
}

public struct ContextDemoReviewedAction: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let summary: String

    public init(id: String, summary: String) {
        self.id = id
        self.summary = summary
    }
}

public struct ContextDemoCaptureRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let planId: String
    public let revision: Int
    public let target: ContextDemoTarget
    public let durationSeconds: Double
    public let window: ContextDemoWindowBinding?
    public let actions: [ContextDemoReviewedAction]

    public init(id: String, planId: String, revision: Int, target: ContextDemoTarget,
                durationSeconds: Double, window: ContextDemoWindowBinding? = nil,
                actions: [ContextDemoReviewedAction] = []) {
        self.id = id
        self.planId = planId
        self.revision = revision
        self.target = target
        self.durationSeconds = durationSeconds
        self.window = window
        self.actions = actions
    }

    public func validate() throws {
        try ContextDemoValidation.captureRequest(self)
    }
}

public struct ContextDemoAsset: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let requestId: String
    public let target: ContextDemoTarget
    public let relativePath: String
    public let sha256: String
    public let durationSeconds: Double
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteSize: Int64
    public let createdAt: Date

    public init(id: String, requestId: String, target: ContextDemoTarget, relativePath: String,
                sha256: String, durationSeconds: Double, pixelWidth: Int, pixelHeight: Int,
                byteSize: Int64, createdAt: Date) {
        self.id = id
        self.requestId = requestId
        self.target = target
        self.relativePath = relativePath
        self.sha256 = sha256
        self.durationSeconds = durationSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteSize = byteSize
        self.createdAt = createdAt
    }

    public static func relativePath(projectId: String, assetId: String) throws -> String {
        guard VoiceLabAssetNaming.isSafeProjectID(projectId), ContextDemoValidation.fileID(assetId) else {
            throw ContextDemoError.unsafePath
        }
        return "context-demo/\(projectId)/\(assetId).mp4"
    }
}

public struct ContextDemoPlacement: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let assetId: String
    public let source: TimeRange
    public let editedStartSeconds: Double

    public init(id: String, assetId: String, source: TimeRange, editedStartSeconds: Double) {
        self.id = id
        self.assetId = assetId
        self.source = source
        self.editedStartSeconds = editedStartSeconds
    }

    public var editedEndSeconds: Double { editedStartSeconds + source.end - source.start }
}

public struct ContextDemoNarrationPiece: Codable, Sendable, Equatable {
    public let source: TimeRange
    public let output: TimeRange
    public let synthetic: Bool

    public init(source: TimeRange, output: TimeRange, synthetic: Bool) {
        self.source = source
        self.output = output
        self.synthetic = synthetic
    }
}

public struct ContextDemoNarrationSnapshot: Codable, Sendable, Equatable {
    public let sampleRate: Double
    public let outputSamples: Int64
    public let pieces: [ContextDemoNarrationPiece]

    public init(timeline: RenderTimeline) throws {
        guard timeline.sampleRate.isFinite, timeline.sampleRate > 0, timeline.sampleRate <= 384_000,
              timeline.outputSamples > 0, timeline.outputSamples <= 9_007_199_254_740_991 else {
            throw ContextDemoError.invalidNarration
        }
        self.sampleRate = timeline.sampleRate
        self.outputSamples = timeline.outputSamples
        self.pieces = TimelinePieces(timeline).pieces.map {
            ContextDemoNarrationPiece(source: TimeRange(start: $0.source.lowerBound, end: $0.source.upperBound),
                                      output: TimeRange(start: $0.edited.lowerBound, end: $0.edited.upperBound),
                                      synthetic: $0.kind == .ai)
        }
        try ContextDemoValidation.narration(self)
    }

    public var durationSeconds: Double { Double(outputSamples) / sampleRate }
}

public struct ContextDemoDocument: Codable, Sendable, Equatable {
    public let format: String
    public let version: Int
    public let projectId: String
    public let planId: String
    public let revision: Int
    public let narration: ContextDemoNarrationSnapshot
    public let sourceContentKey: String
    public let assets: [ContextDemoAsset]
    public let placements: [ContextDemoPlacement]

    public init(projectId: String, planId: String, revision: Int = 0,
                narration: ContextDemoNarrationSnapshot, assets: [ContextDemoAsset] = [],
                placements: [ContextDemoPlacement] = [], sourceContentKey: String) {
        self.format = "voxclip-context-demo"
        self.version = 1
        self.projectId = projectId
        self.planId = planId
        self.revision = revision
        self.narration = narration
        self.sourceContentKey = sourceContentKey
        self.assets = assets
        self.placements = placements
    }

    public func validate() throws {
        try ContextDemoValidation.document(self)
    }

    public init(project: Project, planId: String, timeline: RenderTimeline) throws {
        self.init(projectId: project.id, planId: planId, narration: try ContextDemoNarrationSnapshot(timeline: timeline),
                  sourceContentKey: project.media.source.contentKey)
        try validate()
    }

    public func isCurrent(project: Project, timeline: RenderTimeline) -> Bool {
        sourceContentKey == project.media.source.contentKey && isCurrent(projectId: project.id, timeline: timeline)
    }

    public func isCurrent(projectId: String, timeline: RenderTimeline) -> Bool {
        guard self.projectId == projectId, (try? validate()) != nil,
              let snapshot = try? ContextDemoNarrationSnapshot(timeline: timeline) else { return false }
        return narration == snapshot
    }
}

public typealias ContextDemoPlan = ContextDemoDocument

public enum ContextDemoError: Error, Sendable, Equatable {
    case unsupportedVersion, invalidTarget, invalidRequest, unsafePath, invalidAsset
    case invalidNarration, invalidPlacement, duplicateIdentity, missingAsset, overlappingPlacements
    case staleRevision, staleNarration, cancelled, unsupportedProjectPersistence
}

public struct ContextDemoNarrationMapping: Sendable, Equatable {
    public let source: TimeRange
    public let output: TimeRange
}

public struct ContextDemoPreparedPlacement: Sendable, Equatable, Identifiable {
    public let id: String
    public let assetId: String
    public let source: TimeRange
    public let output: TimeRange
    public let narrationMappings: [ContextDemoNarrationMapping]
}

public struct ContextDemoRenderInput: Sendable, Equatable {
    public let projectId: String
    public let planId: String
    public let revision: Int
    public let narration: ContextDemoNarrationSnapshot
    public let sourceContentKey: String
    public let scope: TimeRange
    public let placements: [ContextDemoPreparedPlacement]
    public let assets: [ContextDemoAsset]
    public var preservesNarration: Bool { true }
    public var captureAudioGain: Double { 0 }
}
