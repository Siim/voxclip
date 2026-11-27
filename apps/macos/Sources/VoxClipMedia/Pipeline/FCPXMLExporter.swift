import CoreMedia
import Foundation
import VoxClipCore

public enum FCPXMLExporter {
    public final class Prepared: Sendable {
        public let destination: URL
        fileprivate let staging: ScratchCleanup.ExportDirectory
        fileprivate let outputs: [(partial: URL, destination: URL)]
        fileprivate let approvals: [URL: ExportSafety.DestinationApproval]

        fileprivate init(destination: URL, staging: ScratchCleanup.ExportDirectory, outputs: [(URL, URL)],
                         approvals: [URL: ExportSafety.DestinationApproval]) {
            self.destination = destination; self.staging = staging; self.outputs = outputs; self.approvals = approvals
        }

        deinit { ScratchCleanup.discardExportDirectory(staging) }
    }

    public static func write(name: String, render: RenderRequest, to output: URL, replacing: Bool, cleanupRegistry: URL? = nil) async throws -> URL {
        let prepared = try await prepare(name: name, render: render, to: output, replacing: replacing, cleanupRegistry: cleanupRegistry)
        return try await publish([prepared])[0]
    }

    public static func prepare(name: String, render: RenderRequest, to output: URL, replacing: Bool,
                               cleanupRegistry: URL? = nil) async throws -> Prepared {
        if let reason = FCPXML.unsupportedReason(render) { throw VoxClipError.exportFailed(reason) }
        let destination = output.standardizedFileURL.resolvingSymlinksInPath()
        let sources = ([render.sourceURL, render.music?.assetURL].compactMap { $0 } + render.recordings.map(\.url))
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard destination.pathExtension.lowercased() == "fcpxml", !sources.contains(destination) else {
            throw VoxClipError.exportFailed("Choose a separate .fcpxml file for the editable timeline")
        }
        var parent = destination.deletingLastPathComponent()
        var directory: ObjCBool = false
        while !FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), parent.path != "/" {
            parent.deleteLastPathComponent()
        }
        guard directory.boolValue, FileManager.default.isWritableFile(atPath: parent.path) else {
            throw VoxClipError.exportFailed("Choose a folder this Mac can write the editable timeline to")
        }
        let probe = AVMediaProbe()
        let source = try await probe.probe(render.sourceURL)
        let musicAudio: MediaAudio?
        if let music = render.music { musicAudio = try await probe.probe(music.assetURL).audio }
        else { musicAudio = nil }
        let staging = try ScratchCleanup.createExportDirectory(in: parent, registry: cleanupRegistry)
        do {
            var outputs: [(partial: URL, destination: URL)] = []
            let nonce = UUID().uuidString.lowercased()
            func companion(_ staged: URL, suffix: String) throws -> URL {
                let file = "\(destination.deletingPathExtension().lastPathComponent)-\(nonce)-\(suffix)"
                let partial = staging.url.appendingPathComponent(file)
                try FileManager.default.copyItem(at: staged, to: partial)
                let target = destination.deletingLastPathComponent().appendingPathComponent(file)
                outputs.append((partial, target))
                return target
            }
            var voice: FCPXML.Media?
            var pictures: [String: FCPXML.Media] = [:]
            var spans: [FCPXML.PictureSpan]?
            let pictureIDs = Dictionary(uniqueKeysWithValues: render.recordings.map { ($0.key, FCPXML.pictureID(for: $0)) })
            for recording in render.recordings where !recording.region.prefix.isEmpty {
                guard let id = pictureIDs[recording.key] else { continue }
                guard FileManager.default.fileExists(atPath: recording.url.path) else { throw VoxClipError.recordingMissing(recording.region.label) }
                pictures[id] = FCPXML.Media(url: recording.url, probe: try await probe.probe(recording.url))
            }
            if let input = render.voiceLab, input.prepared.outputPlan.requiresSyntheticRendering {
                let rendered = try await VoiceLabAudioRenderer.stage(request: render, scratchRoot: staging.url)
                let voiceProbe = try await probe.probe(rendered.mixedAudioURL)
                voice = try withExtendedLifetime(rendered) {
                    FCPXML.Media(url: try companion(rendered.mixedAudioURL, suffix: "voice.caf"), probe: voiceProbe)
                }
                var base = try CompositionVideoSpan.build(render).map {
                    FCPXML.PictureSpan(assetID: $0.recordingKey.flatMap { pictureIDs[$0] } ?? "picture",
                                       source: $0.localSource.start.seconds..<$0.localSource.end.seconds,
                                       edited: $0.output.start.seconds..<$0.output.end.seconds)
                }
                let plan = input.prepared.outputPlan
                let selected = input.prepared.selectedSegmentRecipes.filter { $0.recipe.video.mode == .lipsync }
                if !selected.isEmpty {
                    let lease = try LipsyncVideoLease(scratchRoot: staging.url)
                    for item in selected {
                        let recipe = item.recipe.video
                        guard let assetID = recipe.assetId, let start = recipe.windowStartSample, let end = recipe.windowEndSample,
                              let record = input.project.voiceLab.videoAssets?.first(where: { $0.id == assetID }) else {
                            throw LipsyncError.invalidInput
                        }
                        guard let window = try LipsyncComposition.placement(start: start, end: end, piece: item.piece, input: input) else { continue }
                        let first = Double(window.replacement.lowerBound) / plan.sampleRate
                        let last = Double(window.replacement.upperBound) / plan.sampleRate
                        let origin = Double(window.origin) / plan.sampleRate
                        let ref = "lip-\(assetID)"
                        if pictures[ref] == nil {
                            let file = try await lease.snapshot(record, projectID: input.project.id, paidRoot: input.paidRoot)
                            let pictureProbe = try await probe.probe(file)
                            pictures[ref] = FCPXML.Media(url: try companion(file, suffix: "\(ref).mp4"), probe: pictureProbe)
                        }
                        guard last > first else { throw LipsyncError.invalidInput }
                        let replacement = FCPXML.PictureSpan(assetID: ref, source: (first - origin)..<(last - origin), edited: first..<last)
                        base = replacingPicture(range: replacement.edited, in: base, with: replacement)
                    }
                }
                spans = base
            }
            let data = try FCPXML.document(name: name, render: render, source: source, musicAudio: musicAudio,
                                           renderedVoice: voice, pictureSpans: spans, replacementPictures: pictures)
            let partial = staging.url.appendingPathComponent(destination.lastPathComponent)
            try data.write(to: partial)
            outputs.append((partial, destination))
            let approvals = try ExportSafety.approveDestinations(outputs.map(\.destination))
            guard approvals.allSatisfy({ $0.value == .absent || (replacing && $0.key == destination) }) else {
                throw VoxClipError.exportFailed("A file with that name already exists")
            }
            try Task.checkCancellation()
            return Prepared(destination: destination, staging: staging, outputs: outputs, approvals: approvals)
        } catch {
            ScratchCleanup.discardExportDirectory(staging)
            throw error
        }
    }

    @concurrent public static func publish(_ preparations: [Prepared]) async throws -> [URL] {
        var outputs: [(partial: URL, destination: URL)] = []
        var approvals: [URL: ExportSafety.DestinationApproval] = [:]
        for prepared in preparations {
            let parent = prepared.destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            outputs.append(contentsOf: prepared.outputs)
            approvals.merge(prepared.approvals) { first, _ in first }
        }
        try ExportSafety.publishAll(outputs, approvals: approvals)
        return preparations.map(\.destination)
    }

    private static func replacingPicture(range: Range<Double>, in spans: [FCPXML.PictureSpan],
                                         with replacement: FCPXML.PictureSpan) -> [FCPXML.PictureSpan] {
        var result: [FCPXML.PictureSpan] = [replacement]
        for span in spans {
            for part in [span.edited.lowerBound..<max(span.edited.lowerBound, min(range.lowerBound, span.edited.upperBound)),
                         min(span.edited.upperBound, max(range.upperBound, span.edited.lowerBound))..<span.edited.upperBound] where !part.isEmpty {
                let rate = (span.source.upperBound - span.source.lowerBound) / (span.edited.upperBound - span.edited.lowerBound)
                func source(_ time: Double) -> Double { span.source.lowerBound + (time - span.edited.lowerBound) * rate }
                result.append(FCPXML.PictureSpan(assetID: span.assetID, source: source(part.lowerBound)..<source(part.upperBound), edited: part))
            }
        }
        return result.sorted { $0.edited.lowerBound < $1.edited.lowerBound }
    }
}
