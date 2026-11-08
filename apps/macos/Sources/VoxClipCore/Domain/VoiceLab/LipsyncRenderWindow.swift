import Foundation

public struct LipsyncRenderWindow: Sendable, Equatable {
    public let source: LipsyncWindow
    public let outputStartSample: Int64
    public let outputEndSample: Int64
    public var syncMode: SyncMode {
        outputEndSample - outputStartSample == source.endSample - source.startSample ? .cutOff : .remap
    }
    public func seconds(sampleRate: Double) -> Double { Double(outputEndSample - outputStartSample) / sampleRate }

    public init(source: LipsyncWindow, plan: VoiceLabOutputPlan) throws {
        var start = Self.outputSample(source.startSample, plan: plan)
        var end = Self.outputSample(source.endSample, plan: plan)
        var source = source
        let minimum = Int64((3 * plan.sampleRate).rounded())
        if end - start < minimum, plan.outputSamples >= minimum {
            start = max(0, start - (minimum - (end - start) + 1) / 2)
            end = min(plan.outputSamples, start + minimum)
            start = end - minimum
            source = LipsyncWindow(startSample: Self.sourceSample(start, plan: plan),
                endSample: Self.sourceSample(end, plan: plan), phraseIDs: source.phraseIDs)
        }
        guard end > start, Double(end - start) >= 3 * plan.sampleRate,
              Double(end - start) <= 300 * plan.sampleRate else { throw LipsyncError.invalidInput }
        self.source = source; self.outputStartSample = start; self.outputEndSample = end
    }

    public static func jobs(windows: [LipsyncWindow], plan: VoiceLabOutputPlan) throws -> [LipsyncRenderWindow] {
        let expanded = try windows.map { try LipsyncRenderWindow(source: $0, plan: plan).source }
        return try LipsyncWindow.merge(expanded, sampleRate: Int(plan.sampleRate)).map {
            try LipsyncRenderWindow(source: $0, plan: plan)
        }
    }

    private static func sourceSample(_ sample: Int64, plan: VoiceLabOutputPlan) -> Int64 {
        for piece in plan.pieces where sample <= piece.outputEndSample {
            if let segment = piece.segmentId, let cuts = plan.videoCuts[segment], !cuts.isEmpty {
                let scale = VoiceLabOutputPlan.cutScale(piece, cuts: cuts)
                let offset: Int64 = max(0, sample - piece.outputStartSample)
                let kept: Int64 = scale.kept == scale.output ? offset
                    : Int64((Double(offset) * Double(scale.kept) / Double(scale.output)).rounded())
                var source = piece.sourceStartSample + kept
                for cut in cuts where source >= cut.startSample { source += cut.endSample - cut.startSample }
                return min(source, piece.sourceEndSample)
            }
            let ratio = Double(max(0, sample - piece.outputStartSample)) / Double(piece.outputEndSample - piece.outputStartSample)
            return piece.sourceStartSample + Int64((ratio * Double(piece.sourceEndSample - piece.sourceStartSample)).rounded())
        }
        return plan.pieces.last?.sourceEndSample ?? 0
    }

    public static func outputSample(_ sample: Int64, plan: VoiceLabOutputPlan) -> Int64 {
        Int64((plan.mapTime(Double(sample) / plan.sampleRate) * plan.sampleRate).rounded())
    }
}

extension VoiceLabVideoRecipe {
    public var lipsyncBase: VoiceLabVideoRecipe {
        var base = self
        base.mode = cuts?.isEmpty == false ? .cut : retimeFactor != nil ? .zoomCover : .source
        base.assetId = nil; base.provider = nil; base.model = nil; base.requestId = nil
        base.windowStartSample = nil; base.windowEndSample = nil; base.syncMode = nil
        return base
    }

    /// `model` is the fal model id the job ran: Rewrite's phrases use sync-3, a whole-clip revoice lipsync-2 or sync-3.
    public func addingLipsync(assetID: String, requestID: String, sourceWindow: LipsyncWindow, syncMode: SyncMode,
                              model: String = WholeClipRevoice.Lipsync.sync3.rawValue) -> VoiceLabVideoRecipe {
        var recipe = self
        recipe.mode = .lipsync; recipe.assetId = assetID; recipe.provider = "fal"
        recipe.model = model; recipe.requestId = requestID
        recipe.windowStartSample = sourceWindow.startSample; recipe.windowEndSample = sourceWindow.endSample
        recipe.syncMode = syncMode.rawValue
        return recipe
    }
}
