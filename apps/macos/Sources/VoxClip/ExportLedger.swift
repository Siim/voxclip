import Foundation
import Observation
import CryptoKit
import VoxClipCore
import VoxClipMedia

struct ExportRecord: Codable, Equatable {
    let projectID: String
    let targetID: String
    let exportedAt: Date
    let planFingerprint: String
    let styleId: String
    let aspect: AspectRatio
    let outputPath: String
}

@MainActor @Observable final class ExportLedger {
    let file: URL
    private(set) var records: [ExportRecord]

    init(file: URL) {
        self.file = file
        records = (try? ProjectJSON.decoder().decode([ExportRecord].self, from: Data(contentsOf: file))) ?? []
    }

    func record(_ entry: ExportRecord) throws {
        var next = records.filter { $0.projectID != entry.projectID || $0.targetID != entry.targetID || $0.aspect != entry.aspect }
        next.append(entry)
        next.sort { ($0.projectID, $0.targetID, $0.aspect.rawValue) < ($1.projectID, $1.targetID, $1.aspect.rawValue) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProjectJSON.encoder().encode(next).write(to: file, options: .atomic)
        records = next
    }

    func entry(projectID: String, targetID: String, aspect: AspectRatio) -> ExportRecord? {
        records.first { $0.projectID == projectID && $0.targetID == targetID && $0.aspect == aspect }
    }

    static func targetID(_ target: ExportTarget) -> String {
        switch target { case .fullEdit: return "full"; case .clip(let id): return id }
    }

    static func key(_ target: ExportTarget, aspect: AspectRatio) -> String { targetID(target) + "|" + aspect.rawValue }
}

@MainActor enum ExportFingerprint {
    private struct VoicePiece: Encodable {
        let kind: VoiceLabOutputPieceKind
        let sourceStart: Int64
        let sourceEnd: Int64
        let outputStart: Int64
        let outputEnd: Int64
        let audio: VoiceLabAudio?
        let assetHash: String?
    }
    private struct VoiceRecipe: Encodable {
        let audio: VoiceLabAudio
        let chunks: [VoiceLabChunk]
        let roomTone: VoiceLabRoomTone?
        let seams: VoiceLabSeams
        let video: VoiceLabVideoRecipe
        let seed: UInt32
    }
    private struct Input: Encodable {
        let contentKey: String
        let plan: EditPlan
        let words: [CaptionWord]
        let language: String?
        let captions: CaptionSettings
        let aspect: AspectRatio
        let output: OutputSpec
        let srt: Bool
        let pieces: [VoicePiece]
        let recipes: [VoiceRecipe]
    }

    static func output(_ project: Project) -> OutputSpec {
        let video = project.media.source.video
        let oriented = video.map(OutputSizing.orientedSize) ?? PixelSize(width: 1920, height: 1080)
        let size = (try? OutputSizing.outputSize(source: oriented, aspect: project.export.aspect)) ?? PixelSize(width: 1920, height: 1080)
        let fps = (try? OutputSizing.outputFrameRate(nominal: video?.frameRate ?? 30)) ?? 30
        let bitrate = OutputSizing.videoBitrate(size: size, aspect: project.export.aspect, quality: project.export.quality, fps: fps)
        return OutputSpec(size: size, fps: fps, videoBitrate: bitrate, quality: project.export.quality)
    }

    static func value(_ project: Project, target: ExportTarget) throws -> String {
        let clip: ClipRange?
        switch target {
        case .fullEdit: clip = nil
        case .clip(let id):
            guard let selected = project.edits.clips.first(where: { $0.id == id }) else { throw VoxClipError.exportFailed("Clip no longer exists") }
            clip = selected
        }
        var segments: [EditSegment] = []
        let duration = project.media.source.durationSeconds
        var plan = EditorModel.uncutPlan(duration: duration)
        if let transcript = project.transcript {
            let edits = project.edits
            let pauses = try detectPauses(transcript.words, thresholdSeconds: edits.pauseThresholdSeconds)
            let state = EditState(transcript: transcript, pauses: pauses, pauseThresholdSeconds: edits.pauseThresholdSeconds,
                                  pauseKeepSeconds: edits.pauseKeepSeconds, cutWordIds: Set(edits.cutWordIds),
                                  cutPauseIds: Set(edits.cutPauseIds), corrections: edits.corrections, clips: edits.clips)
            segments = try buildSegments(state, activeClip: clip)
            let rate: Double = Double(project.media.source.audio?.sampleRate ?? 48_000)
            plan = try buildEditPlan(segments, duration: duration, sampleRate: rate, pauseKeepSeconds: edits.pauseKeepSeconds)
        }
        let output = output(project)
        let preset = CaptionStyleResolver.preset(width: output.size.width, height: output.size.height)
        let position = preset.flatMap { project.captions.positionByAspect[$0] } ?? project.captions.position
        let captions = CaptionSettings(styleId: project.captions.styleId, overrides: project.captions.overrides, position: position)
        var words = captionCopy(segments, plan: plan)
        var pieces: [VoicePiece] = []
        var recipes: [VoiceRecipe] = []
        if project.schemaVersion >= 3 {
            let prepared = try VoiceLabRenderContract.prepare(project, scope: clip.map { .clip($0.id) } ?? .full, labelPosition: .topRight)
            words = prepared.outputPlan.captions
            pieces = prepared.outputPlan.pieces.map { (piece: VoiceLabOutputPiece) -> VoicePiece in
                let asset = project.voiceLab.assets?.first { $0.id == piece.assetId }
                return VoicePiece(kind: piece.kind, sourceStart: piece.sourceStartSample, sourceEnd: piece.sourceEndSample,
                                  outputStart: piece.outputStartSample, outputEnd: piece.outputEndSample, audio: piece.audio, assetHash: asset?.sha256)
            }
            recipes = prepared.selectedSegmentRecipes.map { (selected: VoiceLabSelectedRecipe) -> VoiceRecipe in
                let recipe = selected.recipe
                return VoiceRecipe(audio: recipe.audio, chunks: recipe.chunks, roomTone: recipe.roomTone, seams: recipe.seams, video: recipe.video, seed: recipe.seed)
            }
        }
        let input = Input(contentKey: project.media.source.contentKey, plan: plan, words: words, language: project.transcript?.language,
                          captions: captions, aspect: project.export.aspect, output: output, srt: project.export.srt, pieces: pieces, recipes: recipes)
        let encoder = ProjectJSON.encoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(input)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ClipExportStatus: Equatable {
    case none, exported, changed, exporting(Int), failed
    var label: String {
        switch self {
        case .none: return ""
        case .exported: return "✓ Exported"
        case .changed: return "⚠ Edited since export"
        case .exporting(let percent): return "Exporting \(percent)%"
        case .failed: return "⚠ Export failed"
        }
    }
    var secondLine: Bool { self == .changed || self == .failed }
}

enum ExportScope: Hashable {
    case thisClip, allClips, fullVideo
}

extension EditorModel {
    func exportTargets(_ scope: ExportScope, requestedIDs: [String] = []) -> [ExportTarget] {
        switch scope {
        case .thisClip:
            let ids = requestedIDs.isEmpty ? activeClip.map { [$0.id] } ?? [] : requestedIDs
            return ids.filter { id in keptClips.contains { $0.id == id } }.map { .clip($0) }
        case .allClips: return keptClips.map { .clip($0.id) }
        case .fullVideo: return [.fullEdit]
        }
    }

    func exportRowStatus(_ id: String) -> ClipExportStatus {
        let target = ExportTarget.clip(id)
        let aspect = project.export.aspect
        let key = ExportLedger.key(target, aspect: aspect)
        if exporting, activeExportKey == key {
            let fraction: Double = (exportProgress?.fraction ?? 0).clamped(to: 0...1)
            let percent: Int = Int((fraction * 100).rounded())
            return .exporting(percent)
        }
        if failedExports[key] != nil { return .failed }
        guard let entry = app.exportLedger.entry(projectID: project.id, targetID: id, aspect: aspect) else { return .none }
        return entry.planFingerprint == (try? ExportFingerprint.value(project, target: target)) ? .exported : .changed
    }

    func retryExport(_ id: String) {
        let target = ExportTarget.clip(id)
        guard let folder = failedExports[ExportLedger.key(target, aspect: project.export.aspect)], mediaExportable else { return }
        beginExport(targets: [target], folder: folder)
    }

    func exportDisclosure(_ targets: [ExportTarget]) -> String? {
        for target in targets {
            let scope: VoiceLabOutputScope
            switch target { case .fullEdit: scope = .full; case .clip(let id): scope = .clip(id) }
            let root = app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true)
            if let input = try? VoiceLabRenderPreflight.prepare(project: project, scope: scope, paidRoot: root), input.prepared.disclosure.required {
                return input.prepared.disclosure.postText ?? "Contains AI-modified speech."
            }
        }
        return nil
    }
}
