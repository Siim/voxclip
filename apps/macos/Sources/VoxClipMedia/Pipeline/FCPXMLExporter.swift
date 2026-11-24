import Foundation
import VoxClipCore

public enum FCPXMLExporter {
    public static func write(name: String, render: RenderRequest, to output: URL, replacing: Bool) async throws -> URL {
        if let reason = FCPXML.unsupportedReason(render) { throw VoxClipError.exportFailed(reason) }
        let destination = output.standardizedFileURL.resolvingSymlinksInPath()
        let sources = [render.sourceURL, render.music?.assetURL].compactMap { $0 }.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard destination.pathExtension.lowercased() == "fcpxml", !sources.contains(destination) else {
            throw VoxClipError.exportFailed("Choose a separate .fcpxml file for the editable timeline")
        }
        let approved = try ExportSafety.approveDestinations([destination])
        guard replacing || approved[destination] == .absent else {
            throw VoxClipError.exportFailed("A file with that name already exists")
        }
        let probe = AVMediaProbe()
        let source = try await probe.probe(render.sourceURL)
        let musicAudio: MediaAudio?
        if let music = render.music { musicAudio = try await probe.probe(music.assetURL).audio }
        else { musicAudio = nil }
        let data = try FCPXML.document(name: name, render: render, source: source, musicAudio: musicAudio)
        let staging = try ScratchCleanup.createExportDirectory(in: destination.deletingLastPathComponent())
        defer { ScratchCleanup.discardExportDirectory(staging) }
        let partial = staging.url.appendingPathComponent(destination.lastPathComponent)
        try data.write(to: partial)
        try Task.checkCancellation()
        try ExportSafety.publish(partial, to: destination, approval: approved[destination])
        return destination
    }
}
