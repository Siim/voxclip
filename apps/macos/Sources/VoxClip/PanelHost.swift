import SwiftUI
import VoxClipCore

// The right column under its title row (ux/v2 notes.md §1 and §7, impl-plan V4): the
// viewer, a 30 pt panel header, and one panel whose job changes. The header names the job
// and the open tab, and switches between the jobs that can act now.

/// A job of the right column's one panel (notes.md §7).
enum PanelJob: String, CaseIterable, Sendable {
    case captions, rewrite, voice, takes, director

    var title: String {
        switch self {
        case .captions: "Captions"
        case .rewrite: "Rewrite"
        case .voice: "Voice"
        case .takes: "Takes"
        case .director: "Director"
        }
    }
    /// The switcher's glyph, in the mockup's order: captions, pencil, waveform, chat.
    var symbol: String {
        switch self {
        case .captions: "captions.bubble"
        case .rewrite: "pencil"
        case .voice: "waveform"
        case .takes: "square.stack"
        case .director: "bubble.left"
        }
    }

    /// The jobs that can act in `model` now, in switcher order (design: "a control that
    /// cannot act is not shown"). Captions always, and the job of the task open on the
    /// active tab (Rewrite; Voice and Takes with V16–V18, Director with Phase 1).
    @MainActor static func available(in model: EditorModel) -> [PanelJob] {
        guard let task = model.panelTask else { return [.captions] }
        return [.captions, task.job]
    }
}

/// The job picked in the switcher, beside the task and the turn that were open then. A task
/// opened later, or a new run of the same task, shows its job again (the job follows the task).
struct PanelJobChoice {
    let job: PanelJob
    weak var task: DirectorTask?
    let turn: Int
}

extension EditorModel {
    /// The Rewrite session the panel shows: the one on the active tab. Text Rewrite needs
    /// no Voice Lab (impl-plan V13); a build without Rewrite never opens one.
    var panelRewrite: RewriteSession? { RewriteEntryPolicy.buildEnabled ? rewrite : nil }
    /// The task the panel shows: the active tab's Rewrite session's.
    var panelTask: DirectorTask? { panelRewrite?.task }
}

extension WorkspaceShell {
    /// The panel's job for `model` in this window: the job picked in the switcher while it
    /// can act and the task and turn it was picked beside are still the open ones, else the
    /// open task's job, else Captions. In memory only, per window: no undo step and no
    /// document change (impl-plan §3.3).
    func panelJob(for model: EditorModel) -> PanelJob {
        let jobs = PanelJob.available(in: model)
        let task = model.openRewrite?.task
        if let choice = panelChoice, choice.task === task, choice.turn == task?.turn, jobs.contains(choice.job) { return choice.job }
        return model.panelTask?.job ?? .captions
    }
    /// The switcher's pick.
    func choosePanelJob(_ job: PanelJob, for model: EditorModel) {
        guard PanelJob.available(in: model).contains(job) else { return }
        let task = model.openRewrite?.task
        panelChoice = PanelJobChoice(job: job, task: task, turn: task?.turn ?? 0)
    }
}

/// The right column under its title row (former `RightColumnContents`), `width` × `height`:
/// the viewer, the panel header and the panel body, on the chrome.
@MainActor struct PanelHost: View {
    @Bindable var model: EditorModel
    let shell: WorkspaceShell
    let width: CGFloat
    let height: CGFloat
    var fineTune = false
    #if DEBUG
    /// Harnesses start the pointer over the viewer, to show the hover transport.
    var hovering = false
    #endif

    /// notes.md §1: a 30 pt header (1 pt hairlines above and below its 28 pt row).
    static let headerHeight: CGFloat = 30
    /// The panel body keeps at least this much below the header, so its job stays usable in
    /// the shortest column: at the 960 × 600 window minimum (324 × 322), Captions keeps its
    /// STYLE row, a 77 pt gallery that shows its first row of tiles whole, and two property
    /// rows (V5), and a resting Rewrite a 99 pt scroll. It is no more than the 1280 × 700 body
    /// (165), so the box stays 16:9 at 1280 × 700 and above.
    static let bodyMinimum: CGFloat = 160
    /// The viewer's height in a column `width` × `height`: 16:9 of the width (227 at 404),
    /// unless that would leave the panel body under `bodyMinimum`; then the box gives way
    /// (132 at 960 × 600) and the frame inside it is fitted to what is left.
    static func viewerHeight(width: CGFloat, height: CGFloat) -> CGFloat {
        min(ViewerSection.boxHeight(forWidth: width), max(0, height - headerHeight - bodyMinimum))
    }

    var body: some View {
        let job = shell.panelJob(for: model)
        VStack(spacing: 0) {
            viewer
                .modifier(EditorPaneFocus(model: model, pane: .viewer))
            PanelHeader(model: model, shell: shell, job: job)
            Group {
                if job == .rewrite, let session = model.panelRewrite {
                    // The task's panel, or the passage panel while it waits for an instruction or shows a proposal (until V3b and V15).
                    switch session.task.state {
                    case .ready, .proposal: RewritePanel(session: session)
                    case .choosingAI, .running, .error, .changed: DirectorPanel(task: session.task, model: model)
                    }
                } else { CaptionsSection(model: model, fineTune: fineTune, width: width).modifier(EditorPaneFocus(model: model, pane: .panel)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .controlSize(.small)
            .columnLayoutEvidence("panel.body")
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(DesignValues.color("bg.window"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voxclip.editor.right")
    }
    private var viewer: ViewerSection {
        #if DEBUG
        ViewerSection(model: model, columnWidth: width, boxHeight: Self.viewerHeight(width: width, height: height), timelineVisible: shell.layout.timelineVisible, hovering: hovering)
        #else
        ViewerSection(model: model, columnWidth: width, boxHeight: Self.viewerHeight(width: width, height: height), timelineVisible: shell.layout.timelineVisible)
        #endif
    }
}

/// The panel header (notes.md `.phd`): the job's title (13 semibold) and the open tab's name
/// (12, text.tertiary), then the switcher, 26 × 22 icons 1 apart at the trailing edge.
@MainActor struct PanelHeader: View {
    let model: EditorModel
    let shell: WorkspaceShell
    let job: PanelJob
    var body: some View {
        // The tab's name follows the scope and the clips' numbering, which only these make observable.
        let scope = model.renderedActiveClipID, _ = model.projectRevision
        let context = model.scopeName(scope)
        HStack(spacing: 7) {
            Text(job.title).font(VCType.body.font(.semibold)).foregroundStyle(DesignValues.color("text.primary"))
                .fixedSize().accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("voxclip.panel.title")
                .columnLayoutEvidence("panel.title", text: job.title)
            Text(context).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                .lineLimit(1).truncationMode(.tail)
                .accessibilityIdentifier("voxclip.panel.context")
                .columnLayoutEvidence("panel.context", text: context)
            Spacer(minLength: 4)
            HStack(spacing: 1) {
                ForEach(PanelJob.available(in: model), id: \.self) { candidate in
                    PanelJobButton(job: candidate, selected: candidate == job) { shell.choosePanelJob(candidate, for: model) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Panel")
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .frame(height: PanelHost.headerHeight - 2)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity)
        .background(DesignValues.color("bg.window"))
        .overlay(alignment: .top) { Rectangle().fill(DesignValues.color("line.default")).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(DesignValues.color("line.default")).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voxclip.panel.header")
        .columnLayoutEvidence("panel.header")
    }
}

/// A switcher icon (notes.md `.icb`): text.tertiary, or text.primary on bg.selectedRow
/// (radius 5) for the job that shows. VoiceOver reads it as a tab of the panel.
@MainActor private struct PanelJobButton: View {
    let job: PanelJob
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: job.symbol).font(.system(size: 13))
                .foregroundStyle(DesignValues.color(selected ? "text.primary" : "text.tertiary"))
                .frame(width: 26, height: 22)
                .background(selected ? DesignValues.color("bg.selectedRow") : .clear, in: .rect(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(job.title)
        .accessibilityLabel(job.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("voxclip.panel.job.\(job.rawValue)")
        .columnLayoutEvidence("panel.job.\(job.rawValue)")
    }
}
