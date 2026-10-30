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
        let segmentID: String?
        let assetID: String?
        init(_ piece: VoiceLabOutputPiece) {
            kind = piece.kind; sourceStart = piece.sourceStartSample; sourceEnd = piece.sourceEndSample
            outputStart = piece.outputStartSample; outputEnd = piece.outputEndSample; audio = piece.audio
            segmentID = piece.segmentId; assetID = piece.assetId
        }
    }
    private struct VoiceRecipe: Encodable {
        let piece: VoicePiece
        let audio: VoiceLabAudio
        let roomTone: VoiceLabRoomTone?
        let seams: VoiceLabSeams
        let video: RenderVideo
        let asset: RenderAsset?
    }
    private struct RenderVideo: Encodable {
        let mode: VoiceLabVideoMode
        let sourceStartSample: Int64
        let sourceEndSample: Int64
        let outputSamples: Int64
        let retimeFactor: Double?
        let zoom: Double?
        let faceX: Double?
        let faceY: Double?
    }
    private struct RenderAsset: Encodable {
        let sha256: String
        let sampleRate: Int
        let durationSeconds: Double
    }
    private struct Source: Encodable {
        let duration: Double
        let orientedSize: PixelSize
        let rotationDegrees: Int?
        let frameRate: Double?
        let sampleRate: Int?
        let channels: Int?
    }
    private struct Captions: Encodable {
        let styleId: String
        let overrides: [String: JSONValue]?
        let position: CaptionPosition?
    }
    private struct VoicePlan: Encodable {
        let sampleRate: Double
        let totalSourceSamples: Int64
        let pieces: [VoicePiece]
        let captions: [CaptionWord]?
        let scope: String
    }
    private struct VoiceInput: Encodable {
        let outputPlan: VoicePlan
        let disclosure: JSONValue
        let recipes: [VoiceRecipe]
    }
    private struct Input: Encodable {
        let version = 2
        let contentKey: String
        let source: Source
        let plan: EditPlan
        let words: [CaptionWord]?
        let language: String?
        let captions: Captions
        let output: OutputSpec
        let voiceLab: VoiceInput?
    }

    static func output(_ project: Project) -> OutputSpec {
        let video = project.media.source.video
        let oriented = video.map(OutputSizing.orientedSize) ?? PixelSize(width: 1920, height: 1080)
        let size = (try? OutputSizing.outputSize(source: oriented, aspect: project.export.aspect)) ?? PixelSize(width: 1920, height: 1080)
        let fps = (try? OutputSizing.outputFrameRate(nominal: video?.frameRate ?? 30)) ?? 30
        let bitrate = OutputSizing.videoBitrate(size: size, aspect: project.export.aspect, quality: project.export.quality, fps: fps)
        return OutputSpec(size: size, fps: fps, videoBitrate: bitrate, quality: project.export.quality)
    }

    static func value(_ project: Project, target: ExportTarget, labelPosition: VoiceLabLabelPosition = .topRight) throws -> String {
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
        let captionsOn = project.captions.styleId != "off"
        let captions = Captions(styleId: project.captions.styleId, overrides: captionsOn ? project.captions.overrides : nil, position: captionsOn ? position : nil)
        var words = captionCopy(segments, plan: plan)
        var voice: VoiceInput?
        if project.schemaVersion >= 3 {
            let prepared = try VoiceLabRenderContract.prepare(project, scope: clip.map { .clip($0.id) } ?? .full, labelPosition: labelPosition)
            words = prepared.outputPlan.captions
            let pieces = prepared.outputPlan.pieces.map(VoicePiece.init)
            let recipes = prepared.selectedSegmentRecipes.map { (selected: VoiceLabSelectedRecipe) -> VoiceRecipe in
                let recipe = selected.recipe
                let video = recipe.video
                let renderVideo = RenderVideo(mode: video.mode, sourceStartSample: video.sourceStartSample, sourceEndSample: video.sourceEndSample,
                    outputSamples: video.outputSamples, retimeFactor: video.retimeFactor, zoom: video.zoom, faceX: video.faceX, faceY: video.faceY)
                let asset = project.voiceLab.assets?.first { $0.id == recipe.audio.assetId }
                let renderAsset = asset.map { RenderAsset(sha256: $0.sha256, sampleRate: $0.sampleRate, durationSeconds: $0.durationSeconds) }
                return VoiceRecipe(piece: VoicePiece(selected.piece), audio: recipe.audio, roomTone: recipe.roomTone, seams: recipe.seams, video: renderVideo, asset: renderAsset)
            }
            let result = prepared.outputPlan
            let voicePlan = VoicePlan(sampleRate: result.sampleRate, totalSourceSamples: result.totalSourceSamples,
                pieces: pieces, captions: captionsOn ? result.captions : nil, scope: clip?.id ?? "full")
            let label = prepared.disclosure
            let intervals: [JSONValue] = label.intervals.map { .object(["start": .number($0.start), "end": .number($0.end)]) }
            let disclosure: JSONValue = .object(["required": .bool(label.required), "kinds": .array(label.kinds.map(JSONValue.string)),
                "outputAISeconds": .number(label.outputAISeconds), "persistent": .bool(label.persistent), "intervals": .array(intervals),
                "fadeSeconds": .number(label.fadeSeconds), "position": .string(label.position.rawValue), "postText": label.postText.map(JSONValue.string) ?? .null])
            voice = VoiceInput(outputPlan: voicePlan, disclosure: disclosure, recipes: recipes)
        }
        let media = project.media.source
        let oriented = media.video.map(OutputSizing.orientedSize) ?? PixelSize(width: 1920, height: 1080)
        let source = Source(duration: duration, orientedSize: oriented, rotationDegrees: media.video?.rotationDegrees,
            frameRate: media.video?.frameRate, sampleRate: media.audio?.sampleRate, channels: media.audio?.channels)
        let input = Input(contentKey: media.contentKey, source: source, plan: plan, words: captionsOn ? words : nil,
            language: captionsOn ? project.transcript?.language : nil, captions: captions, output: output, voiceLab: voice)
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
    func exportScopeLabel(_ scope: ExportScope, requestedIDs: [String] = []) -> String {
        switch scope {
        case .thisClip:
            let target = requestedIDs.first ?? activeClip?.id
            guard let clip = keptClips.first(where: { $0.id == target }) else { return "This clip" }
            return "This clip\nClip \(clipNumber(clip.id) ?? 1) · \(clip.title ?? "Untitled clip") · \(timecode(editedDuration(clip)))"
        case .allClips: return "All \(keptClips.count) clips"
        case .fullVideo: return "Full video · \(timecode(editedDuration(nil)))"
        }
    }
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
        exportRowStatus(target: .clip(id))
    }

    func exportRowStatus(target: ExportTarget) -> ClipExportStatus {
        let aspect = project.export.aspect
        let key = ExportLedger.key(target, aspect: aspect)
        if exporting, activeExportKey == key {
            let fraction: Double = (exportProgress?.fraction ?? 0).clamped(to: 0...1)
            let scaled: Double = fraction * 100
            let rounded: Double = scaled.rounded()
            let percent: Int = Int(rounded)
            return .exporting(percent)
        }
        if failedExports[key] != nil { return .failed }
        guard let entry = app.exportLedger.entry(projectID: project.id, targetID: ExportLedger.targetID(target), aspect: aspect) else { return .none }
        return entry.planFingerprint == (try? ExportFingerprint.value(project, target: target, labelPosition: app.voiceLabLabelPosition)) ? .exported : .changed
    }

    func retryExport(_ id: String) {
        retryExport(target: .clip(id))
    }

    func retryExport(target: ExportTarget) {
        guard let folder = failedExports[ExportLedger.key(target, aspect: project.export.aspect)], mediaExportable else { return }
        beginExport(targets: [target], folder: folder)
    }

    func exportDisclosure(_ targets: [ExportTarget]) -> String? {
        for target in targets {
            let scope: VoiceLabOutputScope
            switch target { case .fullEdit: scope = .full; case .clip(let id): scope = .clip(id) }
            let root = app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true)
            if let input = try? VoiceLabRenderPreflight.prepare(project: project, scope: scope, paidRoot: root, labelPosition: app.voiceLabLabelPosition), input.prepared.disclosure.required {
                return Self.exportSheetDisclosure(required: true)
            }
        }
        return nil
    }
    static func exportSheetDisclosure(required: Bool) -> String? {
        required ? "This video contains AI-modified speech. It will show AI MODIFIED." : nil
    }
}
