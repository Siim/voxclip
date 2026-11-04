import Foundation
import SwiftUI
import VoxClipCore
import VoxClipMedia

typealias VideoDurationRenderPreparer = @MainActor (Project, VoiceLabOutputScope) async throws -> RenderRequest

struct PreparedVideoDurationRender {
    let input: VoiceLabRenderInput
    private let graph: RenderGraph
    var prepared: VoiceLabPreparedRender { input.prepared }
    var labelPosition: VoiceLabLabelPosition { input.labelPosition }

    fileprivate init(input: VoiceLabRenderInput, graph: RenderGraph) {
        self.input = input; self.graph = graph
    }
}

struct VideoDurationChoiceAvailability: Equatable {
    let options: VoiceLabVideoDurationOptions?
    let unchangedReason: String?
    let changedReason: String?
    private let rendererReady: Bool

    init(row: VoiceLabTakeRow?, sourceSampleRate: Int, rendererReady: Bool) {
        self.rendererReady = rendererReady
        let options = row.map { VoiceLabVideoDurationOptions(row: $0, sourceSampleRate: sourceSampleRate) }
        self.options = options
        unchangedReason = options?.unchangedUnavailableReason ?? (row == nil ? "Choose a take that passed all speech checks first." : nil)
        changedReason = options?.changedUnavailableReason ?? (row == nil ? "Choose a take that passed all speech checks first." :
            rendererReady ? nil : "Matching source-video duration is not prepared in this build. You can still audition this take.")
    }

    func allows(_ choice: VoiceLabVideoMode) -> Bool {
        switch choice {
        case .source: unchangedReason == nil
        case .cut: rendererReady && options?.allows(.cut) == true
        case .retimed: changedReason == nil
        case .zoomCover, .lipsync: false
        }
    }
}

@MainActor enum VideoDurationRenderReadiness {
    static func prepare(_ project: Project, scope: VoiceLabOutputScope,
                        using prepare: VideoDurationRenderPreparer?) async throws -> PreparedVideoDurationRender {
        guard let prepare else { throw VoiceLabProjectError.videoModeUnsupported }
        _ = try VoiceLabRenderContract.prepare(project, scope: scope, labelPosition: .topRight)
        let request = try await prepare(project, scope)
        guard let input = request.voiceLab, input.project == project, input.scope == scope else { throw VoiceLabProjectError.staleRenderContract }
        try input.prepared.verify(project: project, scope: scope, labelPosition: input.labelPosition)
        guard input.prepared.selectedSegmentRecipes.allSatisfy({
            $0.recipe.audio.stretch == 1 && VoiceLabRenderInput.supportsVideoMode($0.recipe.video.mode)
        }) else { throw VoiceLabProjectError.videoModeUnsupported }
        let graph = try await CompositionBuilder().build(request)
        guard graph.voiceLabLease != nil else { throw VoiceLabProjectError.unsupportedRendering }
        return PreparedVideoDurationRender(input: input, graph: graph)
    }
}

struct VideoDurationChoiceView: View {
    let availability: VideoDurationChoiceAvailability
    let selection: VoiceLabVideoMode?
    let busy: Bool
    let choose: (VoiceLabVideoMode) -> Void

    /// Only the choices this take allows are shown, never a disabled one (design.md: a control that can't act is absent).
    /// A single valid choice is chosen for the user (`ClipTakePlan.autoChooseVideo`) and reads as one line.
    var valid: [VoiceLabVideoMode] { [VoiceLabVideoMode.source, .cut, .retimed].filter(availability.allows) }
    @State private var changing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let shown = selection ?? (valid.count == 1 ? valid.first : nil), !changing || busy || valid.count == 1 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Video: " + title(shown).prefix(1).lowercased() + title(shown).dropFirst())
                    if valid.count > 1, !busy {
                        Button("Change") { changing = true }.buttonStyle(.plain)
                            .foregroundStyle(DesignValues.color("text.secondary"))
                            .accessibilityLabel("Change video duration")
                    }
                }
                Text(detail(shown)).foregroundStyle(DesignValues.color("text.secondary"))
            } else if !busy, !valid.isEmpty {
                Text("Choose video duration for this passage")
                ForEach(valid, id: \.self) { choice in option(choice, title: title(choice), detail: detail(choice)) }
            }
        }
        .font(VCType.small.font())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video duration choices")
    }

    private var keepSourceDetail: String {
        let added = availability.options?.addedPauseSeconds ?? 0
        return added > 0 ? "Adds \(String(format: "%.1f", added)) s of natural pauses in your room's sound. Speech keeps its pace." :
            "Uses the verified silence-only fit. Speech is never stretched."
    }

    private func title(_ choice: VoiceLabVideoMode) -> String {
        switch choice {
        case .source: "Keep source video duration"
        case .cut: "Cut the video to this take"
        default: "Match video to this take's duration"
        }
    }
    private func detail(_ choice: VoiceLabVideoMode) -> String {
        switch choice {
        case .source: availability.unchangedReason ?? keepSourceDetail
        case .cut: "Removes \(String(format: "%.1f", availability.options?.removedVideoSeconds ?? 0)) s of video at a pause, like a vlog jump cut. Speech keeps its pace."
        default: availability.changedReason ?? "Keeps this take's natural speech timing, plays source video at \(String(format: "%.2f", availability.options?.retimeFactor ?? 1))× and crops in 1.12×. Nothing is sent."
        }
    }

    private func option(_ choice: VoiceLabVideoMode, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { choose(choice); changing = false } label: {
                Label(title, systemImage: selection == choice ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == choice ? [.isButton, .isSelected] : .isButton)
            Text(detail).foregroundStyle(DesignValues.color("text.secondary"))
        }
    }
}

@MainActor struct RewriteVideoDurationChoiceView: View {
    @Bindable var generation: RewriteGenerationSession
    let editor: EditorModel
    let localCommands: [EditCommand]

    var body: some View {
        VideoDurationChoiceView(availability: generation.videoAvailability, selection: generation.videoChoice,
            busy: generation.preparingVideo || generation.phase == .generating) { choice in
                guard generation.chooseVideo(choice) else { return }
                Task { await generation.prepareVideoChoice(into: editor, localCommands: localCommands) }
            }
    }
}
