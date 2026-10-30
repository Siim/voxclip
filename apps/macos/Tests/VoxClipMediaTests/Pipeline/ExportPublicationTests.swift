import Darwin
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

extension HeavyMediaTests {
    @Test func publicationPreservesAFileAppearingAtAnAbsentDestination() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let output = try fixture.output("video.mp4")
        let user = Data("user file appeared during encoding".utf8)
        var reported: VoxClipError?
        do {
            try ExportSafety.publishAll([output], events: { phase, destination in
                if phase == .willPublish { try user.write(to: destination) }
            })
        } catch { reported = error as? VoxClipError }
        #expect(reported == .exportFailed(fixture.conflict(output.destination)))
        #expect(try Data(contentsOf: output.destination) == user)
        #expect(try fixture.names() == ["video.mp4"])
    }

    @Test func publicationUndoesASwapOfAnUnapprovedReplacement() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let output = try fixture.output("video.mp4", original: "approved original")
        let held = fixture.root.appendingPathComponent("approved-held")
        let user = Data("different user file".utf8)
        var reported: VoxClipError?
        do {
            try ExportSafety.publishAll([output], events: { phase, destination in
                if phase == .willPublish {
                    try FileManager.default.moveItem(at: destination, to: held)
                    try user.write(to: destination)
                }
            })
        } catch { reported = error as? VoxClipError }
        #expect(reported == .exportFailed(fixture.conflict(output.destination)))
        #expect(try Data(contentsOf: output.destination) == user)
        #expect(try Data(contentsOf: held) == Data("approved original".utf8))
        #expect(try fixture.names() == ["approved-held", "video.mp4"])
    }

    @Test(arguments: [false, true], [false, true])
    func publicationRollbackNeverReplacesAnUnrelatedFile(_ replacing: Bool, _ afterCheck: Bool) throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let video = try fixture.output("video.mp4", original: replacing ? "approved original" : nil)
        let srt = try fixture.output("video.srt")
        let held = fixture.root.appendingPathComponent("published-held")
        let user = Data("unrelated replacement during rollback".utf8)
        var failed = false
        do {
            try ExportSafety.publishAll([video, srt], events: { phase, destination in
                if phase == .willPublish && destination == srt.destination { throw POSIXError(.ENOSPC) }
                let replacePhase: ExportSafety.PublicationPhase = afterCheck ? .willRollbackMove : .willRollback
                if phase == replacePhase && destination == video.destination {
                    try FileManager.default.moveItem(at: destination, to: held)
                    try user.write(to: destination)
                }
            })
        } catch { failed = true }
        #expect(failed)
        #expect((try? Data(contentsOf: video.destination)) == user)
        #expect(try Data(contentsOf: held) == Data("new video.mp4".utf8))
        #expect(!FileManager.default.fileExists(atPath: srt.destination.path))
    }

    @Test(arguments: [false, true])
    func publicationHonorsTheApprovalCapturedBeforeEncoding(_ replacing: Bool) throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let output = try fixture.output("video.mp4", original: replacing ? "approved original" : nil)
        let approvals = try ExportSafety.approveDestinations([output.destination])
        if replacing {
            try FileManager.default.moveItem(at: output.destination, to: fixture.root.appendingPathComponent("approved-held"))
        }
        let user = Data("changed before final publication preflight".utf8)
        try user.write(to: output.destination)
        let identity = try ExportSafety.approveDestinations([output.destination])
        #expect(throws: VoxClipError.exportFailed(fixture.conflict(output.destination))) {
            try ExportSafety.publishAll([output], approvals: approvals)
        }
        #expect(try Data(contentsOf: output.destination) == user)
        #expect(try ExportSafety.approveDestinations([output.destination]) == identity)
    }

    @Test(arguments: [false, true])
    func publicationSidecarConflictRollsBackTheWholeVideoTransaction(_ replacing: Bool) throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let video = try fixture.output("video.mp4", original: replacing ? "approved video" : nil)
        let srt = try fixture.output("video.srt")
        let user = Data("user captions appeared".utf8)
        #expect(throws: VoxClipError.exportFailed(fixture.conflict(srt.destination))) {
            try ExportSafety.publishAll([video, srt], events: { phase, destination in
                if phase == .willPublish && destination == srt.destination { try user.write(to: destination) }
            })
        }
        #expect(try Data(contentsOf: srt.destination) == user)
        if replacing { #expect(try Data(contentsOf: video.destination) == Data("approved video".utf8)) }
        else { #expect(!FileManager.default.fileExists(atPath: video.destination.path)) }
        #expect(try fixture.names() == (replacing ? ["video.mp4", "video.srt"] : ["video.srt"]))
    }

    @Test(arguments: [false, true])
    func publicationCommitsVideoAndSidecarWithoutScratch(_ replacing: Bool) throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let video = try fixture.output("video.mp4", original: replacing ? "old video" : nil)
        let srt = try fixture.output("video.srt", original: replacing ? "old captions" : nil)
        try ExportSafety.publishAll([video, srt])
        #expect(try Data(contentsOf: video.destination) == Data("new video.mp4".utf8))
        #expect(try Data(contentsOf: srt.destination) == Data("new video.srt".utf8))
        #expect(try fixture.names() == ["video.mp4", "video.srt"])
    }

    @Test(arguments: [false, true])
    func publicationExporterRetainsApprovalAcrossEncoding(_ replacing: Bool) async throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("video.mp4")
        let original = fixture.root.appendingPathComponent("original-held")
        if replacing { try Data("approved video".utf8).write(to: destination) }
        let user = Data("user file appeared while video was encoding".utf8)
        let exporter = AVExporter(appendCheck: { pump, frame in
            if pump == 0 && frame == 0 {
                if replacing { try FileManager.default.moveItem(at: destination, to: original) }
                try user.write(to: destination)
            }
        })
        let source = try await NativeMediaFixtures.shared.file()
        let render = RenderRequest(sourceURL: source,
            plan: EditPlan(sampleRate: 48000, totalSamples: 48000, kept: [MediaInterval(startSample: 0, endSample: 48000)]),
            output: OutputSpec(size: PixelSize(width: 320, height: 180), fps: 30, videoBitrate: 2_000_000))
        await #expect(throws: VoxClipError.exportFailed(fixture.conflict(destination))) {
            _ = try await exporter.export(ExportJob(render: render, outputURL: destination)) { _ in }
        }
        #expect(try Data(contentsOf: destination) == user)
        #expect(try fixture.names() == (replacing ? ["original-held", "video.mp4"] : ["video.mp4"]))
    }
}

private struct PublicationFixture: Sendable {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-publication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func output(_ name: String, original: String? = nil) throws -> (partial: URL, destination: URL) {
        let destination = root.appendingPathComponent(name)
        if let original { try Data(original.utf8).write(to: destination) }
        let partial = try ExportSafety.preparePartial(for: destination)
        try Data("new \(name)".utf8).write(to: partial)
        return (partial, destination)
    }
    func conflict(_ destination: URL) -> String {
        "A file named \(destination.lastPathComponent) appeared in the export folder. Export again to replace it, or choose another name."
    }
    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
