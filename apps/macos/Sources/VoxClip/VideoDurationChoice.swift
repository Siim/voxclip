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

    init(row: VoiceLabTakeRow?, sourceSampleRate: Int, rendererReady: Bool) {
        let options = row.map { VoiceLabVideoDurationOptions(row: $0, sourceSampleRate: sourceSampleRate) }
        self.options = options
        unchangedReason = options?.unchangedUnavailableReason ?? (row == nil ? "Choose a take that passed all speech checks first." : nil)
        changedReason = options?.changedUnavailableReason ?? (row == nil ? "Choose a take that passed all speech checks first." :
            rendererReady ? nil : "Matching source-video duration is not prepared in this build. You can still audition this take.")
    }

    func allows(_ choice: VoiceLabVideoMode) -> Bool {
        switch choice {
        case .source: unchangedReason == nil
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose video duration for this passage")
            option(.source, title: "Keep source video duration", detail:
                availability.unchangedReason ?? "Uses the verified silence-only fit. Speech is never stretched.")
            option(.retimed, title: "Match video to this take's duration", detail:
                availability.changedReason ?? "Keeps this take's natural speech timing, retimes source video and crops in 1.12×. Nothing is sent.")
            if selection == nil { Text("Choose anew for each passage and selected take.").foregroundStyle(DesignValues.color("text.tertiary")) }
        }
        .font(VCType.small.font())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video duration choices")
    }

    private func option(_ choice: VoiceLabVideoMode, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { choose(choice) } label: {
                Label(title, systemImage: selection == choice ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.plain)
            .disabled(busy || !availability.allows(choice))
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
