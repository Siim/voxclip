#if DEBUG
import AppKit
import AVFoundation
import CoreImage
import Foundation
import Darwin
import VoxClipCore
import VoxClipMedia

/// Exercises persisted recipes through the real document, editor, player and export queue.
@MainActor enum DebugVoiceRecipe {
    static func run(app: AppModel, destination: URL) async {
        var results: [DebugUISuite.Result] = []
        func check(_ name: String, _ passed: Bool) { results.append(.init(name: name, passed: passed)) }
        do {
            let url = destination.appendingPathComponent("caller.voxclip")
            let original = try JSONProjectStore.decode(Data(contentsOf: url))
            app.fileRouter.receive([url])
            var document: VoxClipDocument?
            for _ in 0..<200 {
                document = NSDocumentController.shared.documents.compactMap { $0 as? VoxClipDocument }.first { $0.fileURL == url }
                if document?.editorModel?.mediaResolved == true, document?.editorModel?.nativePreview?.player.currentItem != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let document, let model = document.editorModel, let window = model.window,
                  let player = model.nativePreview?.player else { throw VoxClipError.exportFailed("Saved recipe did not open in the native editor") }
            defer { model.close(); document.updateChangeCount(.changeCleared); document.close() }
            window.setContentSize(NSSize(width: 1280, height: 760))
            let saved = model.project
            let expected = try VoiceLabOutputPlanner.build(saved, scope: .full)
            check("saved v3 recipe opens with synthetic timeline", model.voiceLabPlan == expected && model.previewError == nil && player.currentItem != nil)
            check("saved recipe stays clean on open", !document.isDocumentEdited)
            let request = try await model.renderRequest()
            check("request binds canonical paid root and selected recipe", request.voiceLab?.paidRoot == app.locations.root.appendingPathComponent("VoiceLab", isDirectory: true) && request.voiceLab?.project == saved)
            check("caption layout uses replacement words and original settings", request.captionLayout?.input.words.map(\.text) == expected.captions.map(\.text) && request.captionLayout?.input.captions.positionByAspect == saved.captions.positionByAspect)
            let item = player.currentItem!
            let frames = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(frames)
            try await model.preview.seek(to: 2.65, exact: true)
            model.preview.play()
            for _ in 0..<100 {
                if model.playhead >= 2.95 { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            model.preview.pause()
            check("native player advances across replacement then pauses", model.playhead >= 2.95 && model.playhead < 4 && !model.preview.isPlaying)
            try await model.preview.seek(to: 2.95, exact: true)
            var frame: CVPixelBuffer?
            for _ in 0..<40 {
                frame = frames.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil)
                if frame != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            check("native player produces a composed replacement frame", frame != nil)
            if let frame {
                try CIContext().writePNGRepresentation(of: CIImage(cvPixelBuffer: frame), to: destination.appendingPathComponent("native-preview.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            try await DebugUISuite.capture(window: window, name: "native-window", directory: destination)
            try await Task.sleep(for: .milliseconds(200))
            let paused = model.playhead, nativePaused = player.currentTime().seconds
            try await Task.sleep(for: .milliseconds(200))
            let pauseEvidence = ["uiBefore": paused, "uiAfter": model.playhead, "playerBefore": nativePaused,
                                 "playerAfter": player.currentTime().seconds, "rate": Double(player.rate)]
            try JSONEncoder().encode(pauseEvidence).write(to: destination.appendingPathComponent("paused-times.json"))
            check("paused playhead remains stable", abs(model.playhead - paused) < 0.04 && abs(player.currentTime().seconds - nativePaused) < 0.001 && player.rate == 0)
            var outputs: [ExportResult] = []
            model.activate(model.project.edits.clips.first { $0.id == "included" })
            await model.updatePreview(load: false)
            let clip = try VoiceLabOutputPlanner.build(model.project, scope: .clip("included"))
            check("clip preview uses its own timeline", model.renderTimeline == .voiceLab(clip))
            let full = try await model.renderRequest(target: .fullEdit)
            check("full export ignores active clip", full.timeline.outputSamples == expected.outputSamples && full.voiceLab?.scope == .full)
            for target in [ExportTarget.fullEdit, .clip("included")] {
                model.beginExport(targets: [target], folder: destination)
                await model.exportTask?.value
                check("native export succeeds for \(target)", model.exportError == nil && model.exports.count == 1)
                outputs += model.exports
            }
            try JSONEncoder().encode(outputs).write(to: destination.appendingPathComponent("exports.json"))
            var off = saved; off.captions.styleId = "off"
            document.replaceProject(off); model.refresh(); await model.updatePreview(load: false)
            let offRequest = try await model.renderRequest()
            check("captions off retains mandatory disclosure", offRequest.captionLayout == nil && offRequest.voiceLab?.prepared.disclosure.required == true && model.previewError == nil)
            let paid = app.locations.root.appendingPathComponent("VoiceLab").appendingPathComponent(saved.voiceLab.assets![0].file)
            let paidBytes = try Data(contentsOf: paid)
            let hashes = try outputs.map { try SpeechSHA256.hex(Data(contentsOf: $0.outputURL)) }
            for altered in [false, true] {
                if altered { try Data("altered synthetic fixture".utf8).write(to: paid) }
                else { try FileManager.default.removeItem(at: paid) }
                model.preview.close()
                await model.updatePreview(load: true)
                check("\(altered ? "altered" : "missing") asset clears preview with actionable notice", player.currentItem == nil && model.previewError?.contains(altered ? "changed" : "missing") == true)
                model.beginExport(targets: [.fullEdit], folder: destination)
                await model.exportTask?.value
                check("\(altered ? "altered" : "missing") asset refuses App export", model.exports.isEmpty && model.exportError?.contains(altered ? "changed" : "missing") == true)
                try paidBytes.write(to: paid)
            }
            check("failed outputs preserve earlier published files", try outputs.map { try SpeechSHA256.hex(Data(contentsOf: $0.outputURL)) } == hashes)
            let persisted = try JSONProjectStore.decode(Data(contentsOf: url))
            check("paid bytes and saved source, transcript and recipe remain unchanged", try Data(contentsOf: paid) == paidBytes && persisted.media == original.media && persisted.transcript == original.transcript && persisted.voiceLab == original.voiceLab)
            document.replaceProject(saved); model.refresh(); await model.updatePreview(load: true)
            check("restored paid asset can preview again", model.previewError == nil && player.currentItem != nil)
            var fit = saved
            fit.voiceLab.segments[0].audio.stretch = 1 + 1e-9
            fit.voiceLab.segments[0].candidates[0].recipe!.audio.stretch = 1 + 1e-9
            document.replaceProject(fit); model.refresh(); await model.updatePreview(load: false)
            check("unsupported fit clears previous native player", player.currentItem == nil && model.previewError?.contains("stretched") == true)
            document.replaceProject(saved)
        } catch {
            results.append(.init(name: "native recipe audit: \(error)", passed: false))
        }
        do { try JSONEncoder().encode(results).write(to: destination.appendingPathComponent("voice-recipe-results.json")) }
        catch { try? Data(String(describing: error).utf8).write(to: destination.appendingPathComponent("failure.txt")) }
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }
}
#endif
