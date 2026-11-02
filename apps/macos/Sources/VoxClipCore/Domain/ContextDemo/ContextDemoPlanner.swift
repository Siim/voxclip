import Foundation

extension ContextDemoDocument {
    private func next(assets: [ContextDemoAsset], placements: [ContextDemoPlacement], expectedRevision: Int) throws -> Self {
        try validate()
        guard revision == expectedRevision, revision < Int(Int32.max) else { throw ContextDemoError.staleRevision }
        let ordered = placements.sorted {
            $0.editedStartSeconds == $1.editedStartSeconds ? $0.id < $1.id : $0.editedStartSeconds < $1.editedStartSeconds
        }
        let next = Self(projectId: projectId, planId: planId, revision: revision + 1,
                        narration: narration, assets: assets.sorted { $0.id < $1.id }, placements: ordered,
                        sourceContentKey: sourceContentKey)
        try next.validate()
        return next
    }

    public func replacingPlacement(_ placement: ContextDemoPlacement, expectedRevision: Int) throws -> Self {
        var placements = placements
        if let index = placements.firstIndex(where: { $0.id == placement.id }) { placements[index] = placement }
        else { placements.append(placement) }
        return try next(assets: assets, placements: placements, expectedRevision: expectedRevision)
    }

    public func removingPlacement(id: String, expectedRevision: Int) throws -> Self {
        guard placements.contains(where: { $0.id == id }) else { throw ContextDemoError.invalidPlacement }
        return try next(assets: assets, placements: placements.filter { $0.id != id }, expectedRevision: expectedRevision)
    }

    public func addingAsset(_ asset: ContextDemoAsset, expectedRevision: Int) throws -> Self {
        guard !assets.contains(where: { $0.id == asset.id }) else { throw ContextDemoError.duplicateIdentity }
        return try next(assets: assets + [asset], placements: placements, expectedRevision: expectedRevision)
    }

    public func replacingAsset(id: String, with asset: ContextDemoAsset, expectedRevision: Int) throws -> Self {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { throw ContextDemoError.missingAsset }
        guard asset.id == id else { throw ContextDemoError.invalidAsset }
        var assets = assets
        assets[index] = asset
        return try next(assets: assets, placements: placements, expectedRevision: expectedRevision)
    }

    public func placing(asset: ContextDemoAsset, placement: ContextDemoPlacement, expectedRevision: Int) throws -> Self {
        guard placement.assetId == asset.id else { throw ContextDemoError.missingAsset }
        var assets = assets
        if let existing = assets.first(where: { $0.id == asset.id }) {
            guard existing == asset else { throw ContextDemoError.duplicateIdentity }
        } else { assets.append(asset) }
        var placements = placements
        if let index = placements.firstIndex(where: { $0.id == placement.id }) { placements[index] = placement }
        else { placements.append(placement) }
        return try next(assets: assets, placements: placements, expectedRevision: expectedRevision)
    }
}

public enum ContextDemoPlanner {
    public static func prepare(document: ContextDemoDocument, project: Project, timeline: RenderTimeline,
                               scope: TimeRange? = nil, expectedRevision: Int? = nil,
                               isCancelled: @Sendable () -> Bool = { false }) throws -> ContextDemoRenderInput {
        guard document.sourceContentKey == project.media.source.contentKey else { throw ContextDemoError.staleNarration }
        return try prepare(document: document, projectId: project.id, timeline: timeline, scope: scope,
                           expectedRevision: expectedRevision, isCancelled: isCancelled)
    }

    public static func prepare(document: ContextDemoDocument, projectId: String, timeline: RenderTimeline,
                               scope: TimeRange? = nil, expectedRevision: Int? = nil,
                               isCancelled: @Sendable () -> Bool = { false }) throws -> ContextDemoRenderInput {
        guard !isCancelled() else { throw ContextDemoError.cancelled }
        try document.validate()
        if let expectedRevision, expectedRevision != document.revision { throw ContextDemoError.staleRevision }
        guard document.isCurrent(projectId: projectId, timeline: timeline) else { throw ContextDemoError.staleNarration }
        let scope = scope ?? TimeRange(start: 0, end: document.narration.durationSeconds)
        guard ContextDemoValidation.range(scope), scope.end <= document.narration.durationSeconds,
              ContextDemoValidation.hasSamples(scope, sampleRate: timeline.sampleRate),
              ContextDemoValidation.onGrid(scope.start, sampleRate: timeline.sampleRate),
              ContextDemoValidation.onGrid(scope.end, sampleRate: timeline.sampleRate) else {
            throw ContextDemoError.invalidPlacement
        }
        var prepared: [ContextDemoPreparedPlacement] = []
        var usedAssets = Set<String>()
        for placement in document.placements {
            guard !isCancelled() else { throw ContextDemoError.cancelled }
            let start = max(scope.start, placement.editedStartSeconds)
            let end = min(scope.end, placement.editedEndSeconds)
            guard start < end else { continue }
            var mappings: [ContextDemoNarrationMapping] = []
            for piece in document.narration.pieces {
                guard !isCancelled() else { throw ContextDemoError.cancelled }
                let intersectionStart = max(start, piece.output.start)
                let intersectionEnd = min(end, piece.output.end)
                guard intersectionStart < intersectionEnd else { continue }
                let sourceScale = (piece.source.end - piece.source.start) / (piece.output.end - piece.output.start)
                mappings.append(ContextDemoNarrationMapping(
                    source: TimeRange(start: piece.source.start + (intersectionStart - piece.output.start) * sourceScale,
                                      end: piece.source.start + (intersectionEnd - piece.output.start) * sourceScale),
                    output: TimeRange(start: intersectionStart - scope.start, end: intersectionEnd - scope.start)))
            }
            prepared.append(ContextDemoPreparedPlacement(id: placement.id, assetId: placement.assetId,
                source: TimeRange(start: placement.source.start + start - placement.editedStartSeconds,
                                  end: placement.source.start + end - placement.editedStartSeconds),
                output: TimeRange(start: start - scope.start, end: end - scope.start), narrationMappings: mappings))
            usedAssets.insert(placement.assetId)
        }
        guard !isCancelled() else { throw ContextDemoError.cancelled }
        return ContextDemoRenderInput(projectId: projectId, planId: document.planId, revision: document.revision,
                                      narration: document.narration, sourceContentKey: document.sourceContentKey,
                                      scope: scope, placements: prepared,
                                      assets: document.assets.filter { usedAssets.contains($0.id) }.sorted { $0.id < $1.id })
    }
}

extension ContextDemoRenderInput {
    public func verify(projectId: String, sourceContentKey: String, timeline: RenderTimeline) throws {
        guard self.sourceContentKey == sourceContentKey else { throw ContextDemoError.staleNarration }
        try verify(projectId: projectId, timeline: timeline)
    }

    public func verify(projectId: String, timeline: RenderTimeline) throws {
        guard self.projectId == projectId,
              narration == (try ContextDemoNarrationSnapshot(timeline: timeline)) else {
            throw ContextDemoError.staleNarration
        }
    }

    public func verifyRenderedTimeline(_ timeline: RenderTimeline) throws {
        let actual = try ContextDemoNarrationSnapshot(timeline: timeline)
        guard actual.sampleRate == narration.sampleRate,
              abs(actual.durationSeconds - (scope.end - scope.start)) * actual.sampleRate <= 0.000_001 else {
            throw ContextDemoError.staleNarration
        }
        let expected = narration.pieces.compactMap { piece -> ContextDemoNarrationPiece? in
            let start = max(scope.start, piece.output.start), end = min(scope.end, piece.output.end)
            guard start < end else { return nil }
            let scale = (piece.source.end - piece.source.start) / (piece.output.end - piece.output.start)
            return ContextDemoNarrationPiece(
                source: TimeRange(start: piece.source.start + (start - piece.output.start) * scale,
                                  end: piece.source.start + (end - piece.output.start) * scale),
                output: TimeRange(start: start - scope.start, end: end - scope.start), synthetic: piece.synthetic)
        }
        guard expected.count == actual.pieces.count else { throw ContextDemoError.staleNarration }
        for (expectedPiece, actualPiece) in zip(expected, actual.pieces) {
            let differences = [expectedPiece.source.start - actualPiece.source.start,
                               expectedPiece.source.end - actualPiece.source.end,
                               expectedPiece.output.start - actualPiece.output.start,
                               expectedPiece.output.end - actualPiece.output.end]
            guard expectedPiece.synthetic == actualPiece.synthetic,
                  differences.allSatisfy({ abs($0) * actual.sampleRate <= 0.000_001 }) else {
                throw ContextDemoError.staleNarration
            }
        }
    }
}
