import Foundation

public enum VoiceLabLabelPosition: String, Codable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }
public struct VoiceLabLabelInterval: Sendable, Equatable {
    public let start: Double
    public let end: Double
}
public struct VoiceLabDisclosurePlan: Sendable, Equatable {
    public let required: Bool
    public let kinds: [String]
    public let outputAISeconds: Double
    public let persistent: Bool
    public let intervals: [VoiceLabLabelInterval]
    public let fadeSeconds: Double
    public let position: VoiceLabLabelPosition
    public let postText: String?
}
public struct VoiceLabSelectedRecipe: Sendable, Equatable {
    public let segmentId: String
    public let piece: VoiceLabOutputPiece
    public let recipe: VoiceLabRenderRecipe
}
public struct VoiceLabPreparedRender: Sendable {
    public let outputPlan: VoiceLabOutputPlan
    public let selectedSegmentRecipes: [VoiceLabSelectedRecipe]
    public let disclosure: VoiceLabDisclosurePlan
    private let projectSnapshot: Data
    public func verify(project: Project, scope: VoiceLabOutputScope, labelPosition: VoiceLabLabelPosition) throws {
        guard scope == outputPlan.scope, labelPosition == disclosure.position else { throw VoiceLabProjectError.staleRenderContract }
        do {
            guard try ProjectJSON.encode(project) == projectSnapshot,
                  try VoiceLabOutputPlanner.build(project, scope: scope) == outputPlan else { throw VoiceLabProjectError.staleRenderContract }
        } catch { throw VoiceLabProjectError.staleRenderContract }
    }
    fileprivate init(outputPlan: VoiceLabOutputPlan, selectedSegmentRecipes: [VoiceLabSelectedRecipe], disclosure: VoiceLabDisclosurePlan, projectSnapshot: Data) {
        self.outputPlan = outputPlan; self.selectedSegmentRecipes = selectedSegmentRecipes; self.disclosure = disclosure; self.projectSnapshot = projectSnapshot
    }
}

/// Pure request-bound preflight. The current app/CLI/Media consumers still reject active synthetic pieces.
public enum VoiceLabRenderContract {
    public static func prepare(_ project: Project, scope: VoiceLabOutputScope, labelPosition: VoiceLabLabelPosition) throws -> VoiceLabPreparedRender {
        let plan = try VoiceLabOutputPlanner.build(project, scope: scope)
        if project.schemaVersion < 3 && plan.requiresSyntheticRendering { throw VoiceLabProjectError.needsVoiceLabUpgrade }
        if project.schemaVersion == 3 && project.voiceLab.cleanAudio?.mode == .on { throw VoiceLabProjectError.cleanAudioUnsupported }
        var selected: [VoiceLabSelectedRecipe] = []
        for piece in plan.pieces where piece.kind == .synth {
            guard let segment = project.voiceLab.segments.first(where: { $0.id == piece.segmentId }),
                  let recipe = segment.candidates[segment.selectedCandidateIndex].recipe else { throw VoiceLabProjectError.missingRenderPolicy }
            if segment.kind == .tts && (!recipe.provenance.endpoint.hasPrefix("v1/text-to-speech/") ||
                !recipe.provenance.endpoint.hasSuffix("/with-timestamps") || recipe.provenance.model == "eleven_v4") {
                throw VoiceLabProjectError.endpointUnsupported
            }
            if recipe.video.mode == .retimed || (recipe.video.mode == .source &&
                piece.sourceEndSample - piece.sourceStartSample != piece.outputEndSample - piece.outputStartSample) {
                throw VoiceLabProjectError.videoModeUnsupported
            }
            guard let asset = project.voiceLab.assets?.first(where: { $0.id == recipe.audio.assetId }) else { throw VoiceLabProjectError.danglingAsset }
            #if os(Windows)
            if asset.file.hasSuffix(".flac") { throw VoiceLabProjectError.unsupportedAssetFormat }
            #else
            _ = asset
            #endif
            selected.append(VoiceLabSelectedRecipe(segmentId: segment.id, piece: piece, recipe: recipe))
        }
        try validateSelectedSeams(plan: plan, selected: selected)
        let disclosure = deriveDisclosure(project: project, plan: plan, selected: selected, position: labelPosition)
        return VoiceLabPreparedRender(outputPlan: plan, selectedSegmentRecipes: selected, disclosure: disclosure,
                                      projectSnapshot: try ProjectJSON.encode(project))
    }
    private static func validateSelectedSeams(plan: VoiceLabOutputPlan, selected: [VoiceLabSelectedRecipe]) throws {
        var windows: [(Int64, Int64)] = []
        for item in selected {
            guard let index = plan.pieces.firstIndex(where: { $0.segmentId == item.segmentId }) else { throw VoiceLabProjectError.staleRenderContract }
            let piece = item.piece
            let before = index > 0 ? plan.pieces[index - 1] : nil
            let after = index + 1 < plan.pieces.count ? plan.pieces[index + 1] : nil
            let incoming = item.recipe.seams.in, outgoing = item.recipe.seams.out
            if before == nil {
                guard incoming.kind == .none else { throw VoiceLabProjectError.invalidFadeHandles }
            } else if before?.kind == .synth {
                guard before?.sourceEndSample == piece.sourceStartSample,
                      incoming.kind == .synthToSynth,
                      let prior = selected.first(where: { $0.segmentId == before?.segmentId })?.recipe,
                      prior.seams.out.kind == .synthToSynth,
                      prior.seams.out.fadeSamples == incoming.fadeSamples else { throw VoiceLabProjectError.invalidFadeHandles }
            } else if incoming.kind == .none || incoming.kind == .synthToSynth { throw VoiceLabProjectError.invalidFadeHandles }
            if after == nil {
                guard outgoing.kind == .none else { throw VoiceLabProjectError.invalidFadeHandles }
            } else if after?.kind == .synth {
                guard piece.sourceEndSample == after?.sourceStartSample,
                      outgoing.kind == .synthToSynth,
                      let next = selected.first(where: { $0.segmentId == after?.segmentId })?.recipe,
                      next.seams.in.kind == .synthToSynth,
                      next.seams.in.fadeSamples == outgoing.fadeSamples else { throw VoiceLabProjectError.invalidFadeHandles }
            } else if outgoing.kind == .none || outgoing.kind == .synthToSynth { throw VoiceLabProjectError.invalidFadeHandles }
            func add(_ seam: VoiceLabSeam, at center: Int64) throws {
                guard seam.kind != .none else { return }
                let left = seam.fadeSamples / 2, right = seam.fadeSamples - left
                guard center >= left, right <= plan.outputSamples - center else { throw VoiceLabProjectError.invalidFadeHandles }
                windows.append((center - left, center + right))
            }
            try add(incoming, at: piece.outputStartSample)
            if after?.kind != .synth { try add(outgoing, at: piece.outputEndSample) }
        }
        windows.sort { $0.0 < $1.0 }
        if windows.count > 1 {
            for index in 1..<windows.count where windows[index].0 < windows[index-1].1 { throw VoiceLabProjectError.overlappingFades }
        }
        for item in selected {
            let index = plan.pieces.firstIndex(where: { $0.segmentId == item.segmentId })!
            let piece = item.piece
            let before = index > 0 ? plan.pieces[index-1] : nil
            let after = index+1 < plan.pieces.count ? plan.pieces[index+1] : nil
            let incoming = item.recipe.seams.in, outgoing = item.recipe.seams.out
            if incoming.kind != .none {
                let left = incoming.fadeSamples/2, right = incoming.fadeSamples-left
                guard before!.outputEndSample-before!.outputStartSample >= left,
                      piece.outputEndSample-piece.outputStartSample >= right else { throw VoiceLabProjectError.invalidFadeHandles }
            }
            if outgoing.kind != .none {
                let left = outgoing.fadeSamples/2, right = outgoing.fadeSamples-left
                guard piece.outputEndSample-piece.outputStartSample >= left,
                      after!.outputEndSample-after!.outputStartSample >= right else { throw VoiceLabProjectError.invalidFadeHandles }
            }
        }
    }
    private static func deriveDisclosure(project: Project, plan: VoiceLabOutputPlan, selected: [VoiceLabSelectedRecipe], position: VoiceLabLabelPosition) -> VoiceLabDisclosurePlan {
        let required = !selected.isEmpty
        let kinds = Set(selected.flatMap { item -> [String] in
            let kind = project.voiceLab.segments.first(where: { $0.id == item.segmentId })!.kind.rawValue
            return item.recipe.video.mode == .lipsync ? [kind, "lipsync"] : [kind]
        }).sorted()
        let aiSeconds = Double(selected.reduce(Int64(0)) { $0 + $1.piece.outputEndSample - $1.piece.outputStartSample }) / plan.sampleRate
        let voiceSeconds = Double(selected.filter { item in project.voiceLab.segments.first(where: { $0.id == item.segmentId })?.kind == .voiceChanger }
            .reduce(Int64(0)) { $0 + $1.piece.outputEndSample - $1.piece.outputStartSample }) / plan.sampleRate
        let persistent = required && (voiceSeconds >= plan.duration * 0.5 || aiSeconds > plan.duration * 0.3)
        var intervals: [VoiceLabLabelInterval] = []
        if required {
            if persistent { intervals = [VoiceLabLabelInterval(start: 0, end: plan.duration)] }
            else {
                intervals.append(VoiceLabLabelInterval(start: 0, end: min(3, plan.duration)))
                for item in selected {
                    intervals.append(VoiceLabLabelInterval(start: max(0, Double(item.piece.outputStartSample)/plan.sampleRate - 0.5),
                                                            end: min(plan.duration, Double(item.piece.outputEndSample)/plan.sampleRate + 0.5)))
                }
                intervals.sort { $0.start < $1.start }
                var merged: [VoiceLabLabelInterval] = []
                for interval in intervals {
                    if let last = merged.last, interval.start - last.end < 1 {
                        merged[merged.count-1] = VoiceLabLabelInterval(start: last.start, end: max(last.end, interval.end))
                    } else { merged.append(interval) }
                }
                intervals = merged
            }
        }
        let estonian = project.transcript?.language?.split(separator: "-", omittingEmptySubsequences: false).first?.lowercased() == "et"
        var lines: [String] = []
        if kinds.contains("tts") { lines.append(estonian ? "Mõned sõnad selles videos on loetud minu enda hääle tehisintellekti-koopiaga." : "Some words in this video were re-voiced with an AI copy of my own voice.") }
        if kinds.contains("voiceChanger") {
            let own = selected.contains { item in item.recipe.voiceSource == .own && project.voiceLab.segments.first(where: { $0.id == item.segmentId })?.kind == .voiceChanger }
            lines.append(estonian ? (own ? "Selle video hääl on tehisintellektiga muudetud minu enda hääle koopiaks." : "Selle video häält on muudetud tehisintellektiga.") : (own ? "The voice in this video was converted with AI into a copy of my own voice." : "The voice in this video was changed with AI."))
        }
        if kinds.contains("lipsync") { lines.append(estonian ? "Osa huulte liikumisest on loodud tehisintellektiga." : "Lip movements in parts of it were generated with AI.") }
        return VoiceLabDisclosurePlan(required: required, kinds: kinds, outputAISeconds: aiSeconds, persistent: persistent,
                                      intervals: intervals, fadeSeconds: 0.15, position: position, postText: lines.isEmpty ? nil : lines.joined(separator: " "))
    }
}
