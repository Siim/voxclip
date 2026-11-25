import SwiftUI
import VoxClipCore

// The right column under its title row (ux/v2 notes.md §1 and §7, impl-plan V4): the
// viewer, a 30 pt panel header, and one panel whose job changes. The header names the job
// and the open tab, and switches between the jobs that can act now.

/// A job of the right column's one panel (notes.md §7).
enum PanelJob: String, CaseIterable, Sendable {
    case captions, music, picture, rewrite, voice, takes, director, demo, motion, export, makeIt, askClaude, timelineEdit

    var title: String {
        switch self {
        case .export: "Export"
        case .captions: "Captions"
        case .music: "Music"
        case .picture: "Picture"
        case .rewrite: "Rewrite"
        case .voice: "Voice"
        case .takes: "Takes"
        case .director: "Director"
        case .demo: "Context demo"
        case .motion: "Motion"
        case .makeIt: "Make it postable"
        case .askClaude: "Ask Claude"
        case .timelineEdit: "Timeline edit"
        }
    }
    /// The switcher's glyph, in the mockup's order: captions, pencil, waveform, chat.
    var symbol: String {
        switch self {
        case .export: "square.and.arrow.up"
        case .captions: "captions.bubble"
        case .music: "music.note"
        case .picture: "camera.filters"
        case .rewrite: "pencil"
        case .voice: "waveform"
        case .takes: "square.stack"
        case .director: "bubble.left"
        case .demo: "record.circle"
        case .motion: "viewfinder"
        case .makeIt: "sparkles"
        case .askClaude: "sparkles"
        case .timelineEdit: "timeline.selection"
        }
    }

    /// The jobs that can act in `model` now, in switcher order (design: "a control that
    /// cannot act is not shown"). Captions always, the job of the task open on the active
    /// tab (Rewrite; Voice and Takes with V16–V18, Director with Phase 1), and Export while
    /// its job is open (VX), which a render keeps open on any tab.
    @MainActor static func available(in model: EditorModel) -> [PanelJob] {
        var jobs: [PanelJob] = [.captions, .music]
        if model.project.media.source.video != nil { jobs.append(.picture) }
        if let task = model.panelTask { jobs.append(task.job) }
        if (model.hasVoiceJob || model.currentVoiceFeedback != nil), !jobs.contains(.voice) { jobs.append(.voice) }
        if model.exportJob.isOpen { jobs.append(.export) }
        if model.capabilities.writable || model.contextDemoDocument != nil || model.contextDemoSession != nil { jobs.append(.demo) }
        if model.motionCueEditing != nil { jobs.append(.motion) }
        if model.makeIt.shown != nil { jobs.append(.makeIt) }
        if model.askClaude.isOpen { jobs.append(.askClaude) }
        if model.timelineEditor != nil { jobs.append(.timelineEdit) }
        return jobs
    }
}

/// The job picked in the switcher, beside the task and the turn that were open then. A task
/// opened later, or a new run of the same task, shows its job again (the job follows the task).
struct PanelJobChoice {
    let job: PanelJob
    weak var task: DirectorTask?
    let turn: Int
    var voiceTurn: Int = 0
}

extension EditorModel {
    /// The task the panel shows: the active tab's Rewrite session's. Text Rewrite needs no Voice Lab (impl-plan V13).
    var panelTask: DirectorTask? {
        guard let rewrite, rewrite.task.state != .running || rewrite.sendApproved else { return nil }
        return rewrite.task
    }
    var hasVoiceJob: Bool { voiceChange != nil || (app.voiceLabSession.showEnrollment && app.voiceLabSession.flow.owner === self) }
    func openVoiceJob() {
        guard capabilities.ai else { return }
        let session = app.voiceLabSession
        if session.showEnrollment, let owner = session.flow.owner, owner !== self {
            announce("Finish making your voice in the other project first."); return
        }
        session.flow.owner = self; session.flow.originTask = openRewrite?.task
        session.flow.originTurn = openRewrite?.task.turn ?? 0
        session.flow.turn += 1
        session.openEnrollment(project: VoiceLabSession.trainingProject(editor: self, name: app.shell.projectTitle), startAnalysis: false)
        // Opening first use itself does not decode media or download a model.
        if !app.speakerModelLibrary.installed || !session.enabled { session.analysis?.cancel(); session.projectAudio = .noProject }
        if app.shell.editor === self, !app.shell.viewerShown { app.shell.toggleViewer() }
        announce("Your voice. Step 1 of 2.")
    }
}

extension WorkspaceShell {
    func showRewriteFailure() {
        guard let editor, let session = editor.openRewrite, session.failureStatus != nil else { return }
        choose(session.project.edits.activeClipId.map(SidebarItem.clip) ?? .fullTake, byClick: false)
        if !viewerShown { toggleViewer() }
        choosePanelJob(.rewrite, for: editor)
        editor.focusedPane = .panel
        editor.paneFocusRequest += 1
        _ = chromeFocus?.focus(.panel)
    }

    /// The panel's job for `model` in this window: the open task's job while it asks a
    /// question (`PanelConfirm`), else the job picked in the switcher while it can act and
    /// either no task is open (a Rewrite closed under Export leaves Export showing) or the
    /// task and turn it was picked beside are still the open ones, else the open task's job,
    /// else Captions. A job that does not show keeps its own state: an export renders on
    /// behind Captions, Rewrite or its question. In memory only, per window: no undo step and
    /// no document change (impl-plan §3.3).
    func panelJob(for model: EditorModel) -> PanelJob {
        let jobs = PanelJob.available(in: model)
        let task = model.openRewrite?.task
        if let asking = model.panelTask, asking.confirm != nil { return asking.job }
        if model.timelineEditor != nil { return .timelineEdit }
        // Make it postable drives Rewrite's session itself while it runs: its progress stays in view.
        if model.makeIt.active != nil, jobs.contains(.makeIt), !model.sendConfirmation.isPresented { return .makeIt }
        // ✦ Ask Claude just opened (or answered) stays in view until another job is picked.
        if model.askClaude.inView, jobs.contains(.askClaude) { return .askClaude }
        let flow = model.app.voiceLabSession.flow
        let awaitingSend = model.openRewrite.map { $0.task.state == .running && !$0.sendApproved } == true
        if let choice = panelChoice, task == nil || choice.task === task && (choice.turn == (task?.turn ?? 0) || awaitingSend),
           choice.voiceTurn == flow.turn, jobs.contains(choice.job) { return choice.job }
        if model.hasVoiceJob, flow.originTask === task, flow.originTurn == (task?.turn ?? 0) { return .voice }
        if task == nil, model.currentVoiceFeedback != nil { return .voice }
        return model.panelTask?.job ?? .captions
    }
    /// The timeline can be the only visible pane. Reveal the inspector on the same window.
    func showMusic(for model: EditorModel) {
        if !viewerShown { toggleViewer() }
        choosePanelJob(.music, for: model)
    }
    func showPicture(for model: EditorModel) {
        guard model.project.media.source.video != nil else { return }
        if !viewerShown { toggleViewer() }
        choosePanelJob(.picture, for: model)
    }
    /// The switcher's pick. Picking Export records the job it was opened from for its Done.
    func choosePanelJob(_ job: PanelJob, for model: EditorModel) {
        guard PanelJob.available(in: model).contains(job) else { return }
        guard job != .timelineEdit else { return }
        if model.timelineEditor != nil { model.resetTimelineEditor() }
        let current = panelJob(for: model)
        model.askClaude.inView = job == .askClaude
        if current == .voice, job != .voice { model.app.voiceLabSession.leaveVoiceControls(owner: model) }
        if job == .export, current != .export { exportReturnJob = current }
        if current == .demo, job != .demo { model.contextDemoSession?.cancel() }
        if current == .motion, job != .motion { model.motionCueEditing = nil }
        if job == .demo, model.contextDemoSession == nil || model.contextDemoSession?.phase == .closed {
            model.contextDemoSession = ContextDemoSession(model: model)
        }
        let task = model.openRewrite?.task
        panelChoice = PanelJobChoice(job: job, task: task, turn: task?.turn ?? 0, voiceTurn: model.app.voiceLabSession.flow.turn)
    }
    /// The Export job's Done: back to the job it was opened from while that can act, else Captions.
    func leaveExportJob(for model: EditorModel) {
        choosePanelJob(PanelJob.available(in: model).contains(exportReturnJob) ? exportReturnJob : .captions, for: model)
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
        let showsTask = (job == .rewrite || job == .voice) && !(job == .voice && (model.hasVoiceJob || model.currentVoiceFeedback != nil))
        VStack(spacing: 0) {
            viewer
                .modifier(EditorPaneFocus(model: model, pane: .viewer))
            PanelHeader(model: model, shell: shell, job: job)
            Group {
                if let task = model.panelTask, task.confirm != nil { DirectorPanel(task: task, model: model) }
                else if job == .voice, let story = model.storyClip(for: nil), model.voiceChange == nil {
                    ScrollView { StoryVoiceOptions(model: model, clip: story).padding(14) }
                        .modifier(EditorPaneFocus(model: model, pane: .panel))
                }
                else if let task = model.panelTask, showsTask { DirectorPanel(task: task, model: model) }
                else if job == .voice, model.hasVoiceJob { DirectorVoiceSteps(session: model.app.voiceLabSession, model: model) }
                else if job == .voice, let feedback = model.currentVoiceFeedback { VoiceRewriteDone(model: model, feedback: feedback) }
                else if job == .picture {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if model.currentClipControls != nil { ClipPictureControls(model: model) }
                            else { pictureClipPicker }
                            Divider()
                            illustratePhrase
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .modifier(EditorPaneFocus(model: model, pane: .panel))
                }
                else if job == .music {
                    ScrollView { MusicSection(model: model).padding(.horizontal, 14).padding(.bottom, 12) }
                        .scrollBounceBehavior(.basedOnSize)
                        .modifier(EditorPaneFocus(model: model, pane: .panel))
                }
                else if job == .export { ExportJobView(model: model).modifier(EditorPaneFocus(model: model, pane: .panel)) }
                else if job == .demo, let session = model.contextDemoSession { ContextDemoPanel(session: session, model: model) }
                else if job == .motion, let editing = model.motionCueEditing { MotionCuePanel(model: model, editing: editing, shell: shell) }
                else if job == .timelineEdit, let route = model.timelineEditor {
                    TimelineEditorPanel(model: model, shell: shell, route: route).id(route)
                }
                else if job == .makeIt, let run = model.makeIt.shown { MakeItPanel(model: model, run: run).modifier(EditorPaneFocus(model: model, pane: .panel)) }
                else if job == .askClaude, model.askClaude.isOpen { AskClaudePanel(model: model).modifier(EditorPaneFocus(model: model, pane: .panel)) }
                else { CaptionsSection(model: model, fineTune: fineTune, width: width).modifier(EditorPaneFocus(model: model, pane: .panel)) }
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
    @ViewBuilder private var illustratePhrase: some View {
        switch IllustrativeCutawaySession(model: model).readiness {
        case .ready(let selection):
            Button { model.openGeneratedIllustrationReview() } label: {
                Label("Illustrate a phrase…", systemImage: "photo")
            }.help("Review an illustration for “\(selection.phrase)”.")
        case .unavailable(let reason):
            Label("Illustrate a phrase…", systemImage: "photo").foregroundStyle(.secondary)
            Text(reason).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
        }
    }
    private var pictureClipPicker: some View {
        let clips = model.project.edits.clips.filter { !model.isSuggestion($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Choose a clip to adjust its picture").font(VCType.body.font(.semibold))
            if clips.isEmpty {
                Text("Select words in the transcript and choose Make Clip from Selection to give that passage its own look.")
                    .font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.secondary"))
            }
            ForEach(clips, id: \.id) { clip in
                Button { shell.choose(.clip(clip.id), byClick: false); shell.showPicture(for: model) } label: {
                    Label(model.scopeName(clip.id), systemImage: "film")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
        let context = job == .export ? model.exportJobContext : model.scopeName(scope)
        HStack(spacing: 7) {
            if job != .music && job != .picture {
                Text(job.title).font(VCType.body.font(.semibold)).foregroundStyle(DesignValues.color("text.primary"))
                    .fixedSize().accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("voxclip.panel.title")
                    .columnLayoutEvidence("panel.title", text: job.title)
            }
            Text(context).font(VCType.callout.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(job == .music || job == .picture ? 1 : 0)
                .accessibilityAddTraits(job == .music || job == .picture ? .isHeader : [])
                .accessibilityIdentifier("voxclip.panel.context")
                .columnLayoutEvidence("panel.context", text: context)
            if job != .export, let speed = model.clipSpeedBadge {
                // The open clip plays at another speed (design.md §6.9).
                Text(speed).font(VCType.small.font(.semibold)).monospacedDigit().foregroundStyle(DesignValues.color("text.secondary"))
                    .fixedSize()
                    .accessibilityLabel("Speed \(speed)")
                    .accessibilityIdentifier("voxclip.panel.speed")
            }
            Spacer(minLength: 4)
            switcher(PanelJob.available(in: model))
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

    @ViewBuilder private func switcher(_ jobs: [PanelJob]) -> some View {
        if jobs.count <= 4 {
            jobButtons(jobs)
        } else {
            // Reserve two labelled entries and the currently open panel. Captions stays
            // one click away in More when a task such as Rewrite takes its slot.
            let third: PanelJob = job == .music || job == .picture ? .captions : job
            let pinned = jobs.filter { $0 == .music || $0 == .picture || $0 == third }
            ViewThatFits(in: .horizontal) {
                jobButtons(jobs).fixedSize()
                HStack(spacing: 2) {
                    jobButtons(pinned)
                    Menu {
                        ForEach(jobs.filter { !pinned.contains($0) }, id: \.self) { item in
                            Button { shell.choosePanelJob(item, for: model) } label: {
                                Label(item.title, systemImage: item == job ? "checkmark" : item.symbol)
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 26, height: 22) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("More panels").accessibilityLabel("More panels")
                    .columnLayoutEvidence("panel.more")
                }
            }
        }
    }

    private func jobButtons(_ jobs: [PanelJob]) -> some View {
        HStack(spacing: 1) {
            ForEach(jobs, id: \.self) { item in
                PanelJobButton(job: item, selected: item == job) { shell.choosePanelJob(item, for: model) }
            }
        }
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
            HStack(spacing: 3) {
                Image(systemName: job.symbol).font(.system(size: 13))
                if job == .music || job == .picture { Text(job.title).font(VCType.callout.font(.medium)) }
            }
                .foregroundStyle(DesignValues.color(selected ? "text.primary" : (job == .music || job == .picture) ? "text.secondary" : "text.tertiary"))
                .fixedSize()
                .frame(minWidth: job == .music ? 56 : job == .picture ? 66 : 26, minHeight: 22)
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
