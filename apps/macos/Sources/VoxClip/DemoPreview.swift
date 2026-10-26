#if DEBUG
import SwiftUI
import VoxClipCore

enum DemoEditing {
    static func loadFixture(_ url: URL) throws -> Project {
        let root = try SharedResources.locate().root.appendingPathComponent("fixtures/projects").resolvingSymlinksInPath().standardizedFileURL
        let path = url.resolvingSymlinksInPath().standardizedFileURL
        guard path.path.hasPrefix(root.path + "/"), path.pathExtension == "voxclip" else { throw CocoaError(.fileReadNoPermission) }
        return try JSONProjectStore.decode(Data(contentsOf: path))
    }
}

@MainActor final class DemoPreviewEngine: PreviewEngine {
    let events: AsyncStream<PreviewEvent>
    private let continuation: AsyncStream<PreviewEvent>.Continuation
    private var plan = EditorModel.uncutPlan(duration: 0)
    private var timer: Task<Void, Never>?
    private(set) var isPlaying = false
    private(set) var editedTime = 0.0
    init() { (events, continuation) = AsyncStream.makeStream() }
    func load(_ request: RenderRequest) async throws { plan = request.plan; editedTime = 0; emitTime() }
    func update(_ request: RenderRequest) async throws { plan = request.plan; editedTime = min(editedTime, plan.duration); emitTime() }
    func seek(to editedTime: Double, exact: Bool) async throws { self.editedTime = min(plan.duration, max(0, editedTime)); emitTime() }
    func play() {
        guard !isPlaying else { return }
        if editedTime >= plan.duration { editedTime = 0 }
        isPlaying = true; continuation.yield(.playing(true))
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self else { return }
                editedTime = min(plan.duration, editedTime + 0.05); emitTime()
                if editedTime >= plan.duration { pause(); return }
            }
        }
    }
    func emitTime() { continuation.yield(.time(edited: editedTime, source: plan.sourceTime(editedTime))) }
    func pause() { timer?.cancel(); timer = nil; isPlaying = false; continuation.yield(.playing(false)) }
    func close() { pause(); continuation.finish() }
}

struct DemoFrame: View {
    let model: EditorModel
    var body: some View {
        ZStack {
            VStack(spacing: 18) {
                Image(systemName: "person.crop.rectangle").font(.system(size: 70, weight: .ultraLight)).foregroundStyle(DesignValues.color("overlay.foreground").opacity(0.6))
                Text("Synthetic preview").font(.title3).foregroundStyle(DesignValues.color("overlay.foreground"))
                Text("No source video is loaded").font(.caption).foregroundStyle(DesignValues.color("overlay.foreground").opacity(0.7))
                Text(timecode(model.sourceTime)).font(DesignValues.mono()).foregroundStyle(DesignValues.color("overlay.foreground").opacity(0.7))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity) // fill the stage, so the bottom-aligned parent keeps it centred
        .accessibilityLabel("Synthetic in-memory preview, \(timecode(model.sourceTime))")
    }
}
#endif
