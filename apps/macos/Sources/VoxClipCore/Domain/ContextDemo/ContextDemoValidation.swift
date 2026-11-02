import Foundation

enum ContextDemoValidation {
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }

    static func identifier(_ value: String) -> Bool {
        matches(value, "[A-Za-z0-9][A-Za-z0-9._:-]{0,63}")
    }

    static func fileID(_ value: String) -> Bool {
        matches(value, "[a-z0-9][a-z0-9_-]{0,63}") &&
            !matches(value, "con|prn|aux|nul|com[1-9]|lpt[1-9]")
    }

    static func text(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximum &&
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func target(_ value: ContextDemoTarget) throws {
        guard text(value.displayName, maximum: 256), text(value.locator, maximum: 4096) else {
            throw ContextDemoError.invalidTarget
        }
        switch value.kind {
        case .desktopApp:
            guard matches(value.locator, "[A-Za-z0-9][A-Za-z0-9._!-]{0,255}") else {
                throw ContextDemoError.invalidTarget
            }
        case .codeProject:
            guard let decoded = value.locator.removingPercentEncoding,
                  !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !decoded.split(separator: "/").contains(".."),
                  let url = URLComponents(string: value.locator), url.scheme == "file",
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.hasPrefix("/"), !url.path.split(separator: "/").contains(".."),
                  !url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ContextDemoError.invalidTarget
            }
        case .webPage:
            guard let url = URLComponents(string: value.locator),
                  url.scheme == "https" || url.scheme == "http", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { throw ContextDemoError.invalidTarget }
        }
    }

    static func captureRequest(_ value: ContextDemoCaptureRequest) throws {
        try target(value.target)
        guard identifier(value.id), identifier(value.planId), (0...Int(Int32.max)).contains(value.revision),
              value.durationSeconds.isFinite, value.durationSeconds > 0, value.durationSeconds <= 30,
              value.actions.count <= 64 else { throw ContextDemoError.invalidRequest }
        var identities = Set<String>()
        for action in value.actions {
            guard identifier(action.id), text(action.summary, maximum: 1024) else {
                throw ContextDemoError.invalidRequest
            }
            guard identities.insert(action.id).inserted else { throw ContextDemoError.duplicateIdentity }
        }
        if let window = value.window {
            guard window.windowID > 0, window.processID > 0,
                  matches(window.bundleID, "[A-Za-z0-9][A-Za-z0-9._-]{0,255}"),
                  value.target.kind != .desktopApp || window.bundleID == value.target.locator else {
                throw ContextDemoError.invalidRequest
            }
        }
    }

    static func asset(_ value: ContextDemoAsset, projectId: String) throws {
        try target(value.target)
        guard fileID(value.id), identifier(value.requestId),
              value.relativePath == (try ContextDemoAsset.relativePath(projectId: projectId, assetId: value.id)) else {
            throw ContextDemoError.unsafePath
        }
        guard matches(value.sha256, "[0-9a-f]{64}"),
              value.durationSeconds.isFinite, value.durationSeconds > 0, value.durationSeconds <= 30,
              (2...1920).contains(value.pixelWidth), value.pixelWidth.isMultiple(of: 2),
              (2...1080).contains(value.pixelHeight), value.pixelHeight.isMultiple(of: 2),
              value.byteSize > 0, value.byteSize <= 64 * 1024 * 1024,
              UTCTimestamp.string(from: value.createdAt) != nil else { throw ContextDemoError.invalidAsset }
    }

    static func range(_ value: TimeRange, allowPoint: Bool = false) -> Bool {
        value.start.isFinite && value.end.isFinite && value.start >= 0 &&
            (allowPoint ? value.end >= value.start : value.end > value.start)
    }

    static func onGrid(_ seconds: Double, sampleRate: Double) -> Bool {
        let samples = seconds * sampleRate
        return samples.isFinite && samples >= 0 && samples <= 9_007_199_254_740_991 &&
            abs(samples - samples.rounded()) <= 0.000_001
    }

    static func hasSamples(_ range: TimeRange, sampleRate: Double) -> Bool {
        (range.end * sampleRate).rounded() > (range.start * sampleRate).rounded()
    }

    static func narration(_ value: ContextDemoNarrationSnapshot) throws {
        guard value.sampleRate.isFinite, value.sampleRate >= 1, value.sampleRate <= 384_000,
              value.sampleRate.rounded() == value.sampleRate, value.outputSamples > 0,
              value.outputSamples <= 9_007_199_254_740_991,
              !value.pieces.isEmpty, value.pieces.count <= 100_000 else { throw ContextDemoError.invalidNarration }
        var outputEnd = 0.0
        var sourceEnd = 0.0
        for piece in value.pieces {
            guard range(piece.source, allowPoint: piece.synthetic), range(piece.output),
                  hasSamples(piece.output, sampleRate: value.sampleRate),
                  piece.synthetic || hasSamples(piece.source, sampleRate: value.sampleRate),
                  onGrid(piece.source.start, sampleRate: value.sampleRate),
                  onGrid(piece.source.end, sampleRate: value.sampleRate),
                  onGrid(piece.output.start, sampleRate: value.sampleRate),
                  onGrid(piece.output.end, sampleRate: value.sampleRate),
                  abs(piece.output.start - outputEnd) * value.sampleRate <= 0.000_001,
                  piece.source.start >= sourceEnd else { throw ContextDemoError.invalidNarration }
            sourceEnd = piece.source.end
            outputEnd = piece.output.end
        }
        guard abs(outputEnd * value.sampleRate - Double(value.outputSamples)) <= 0.000_001 else {
            throw ContextDemoError.invalidNarration
        }
    }

    static func document(_ value: ContextDemoDocument) throws {
        guard value.format == "voxclip-context-demo", value.version == 1 else {
            throw ContextDemoError.unsupportedVersion
        }
        guard VoiceLabAssetNaming.isSafeProjectID(value.projectId), identifier(value.planId),
              matches(value.sourceContentKey, "[0-9a-f]{64}"),
              (0...Int(Int32.max)).contains(value.revision), value.assets.count <= 64, value.placements.count <= 64 else {
            throw ContextDemoError.invalidRequest
        }
        try narration(value.narration)
        var assets: [String: ContextDemoAsset] = [:]
        for asset in value.assets {
            try self.asset(asset, projectId: value.projectId)
            guard assets.updateValue(asset, forKey: asset.id) == nil else { throw ContextDemoError.duplicateIdentity }
        }
        var identities = Set<String>()
        var editedEnd = 0.0
        for placement in value.placements {
            guard identifier(placement.id), identities.insert(placement.id).inserted else {
                throw ContextDemoError.duplicateIdentity
            }
            guard let asset = assets[placement.assetId] else { throw ContextDemoError.missingAsset }
            guard range(placement.source), placement.source.end <= asset.durationSeconds,
                  hasSamples(placement.source, sampleRate: value.narration.sampleRate),
                  placement.editedStartSeconds.isFinite, placement.editedStartSeconds >= 0,
                  placement.editedEndSeconds.isFinite,
                  placement.editedEndSeconds <= value.narration.durationSeconds,
                  onGrid(placement.source.start, sampleRate: value.narration.sampleRate),
                  onGrid(placement.source.end, sampleRate: value.narration.sampleRate),
                  onGrid(placement.editedStartSeconds, sampleRate: value.narration.sampleRate),
                  onGrid(placement.editedEndSeconds, sampleRate: value.narration.sampleRate) else {
                throw ContextDemoError.invalidPlacement
            }
            guard placement.editedStartSeconds >= editedEnd else { throw ContextDemoError.overlappingPlacements }
            editedEnd = placement.editedEndSeconds
        }
    }
}
