import AVKit
import SwiftUI
import UniformTypeIdentifiers
import VoxClipCore

@MainActor struct ContextDemoPanel: View {
    @Bindable var session: ContextDemoSession
    let model: EditorModel
    @State private var choosingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Demonstrate the real thing").font(VCType.body.font(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 4)
                        Button("Close", systemImage: "xmark") { model.closeContextDemoJob() }
                            .labelStyle(.iconOnly).buttonStyle(.plain)
                            .accessibilityIdentifier("voxclip.demo.close")
                    }
                    Text("Record a webpage or one app window beside your narration. Your source voice continues underneath. Nothing is recorded or run until you review and start.")
                        .foregroundStyle(DesignValues.color("text.secondary"))
                    if !session.busy { sourceFields }
                    if let request = session.request {
                        ContextDemoReviewView(request: request, allowsPageScripts: session.allowsPageScripts)
                    }
                    if session.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(session.phase == .recording ? "Recording the reviewed window…" : "Preparing a local capture review…")
                        }.accessibilityElement(children: .combine)
                    }
                    if let asset = session.selectedAsset, let url = session.previewURL {
                        ContextDemoResultPreview(url: url, trim: TimeRange(start: session.trimStart, end: session.trimEnd))
                            .id(asset.id)
                        ContextDemoTrimFields(session: session, asset: asset)
                    }
                    if let document = session.document, !document.placements.isEmpty {
                        ContextDemoPlacementList(document: document, selected: session.selectedPlacementID,
                            select: session.selectPlacement)
                    }
                    if let message = session.message, !message.isEmpty {
                        Text(message).foregroundStyle(DesignValues.color("text.secondary"))
                            .accessibilityIdentifier("voxclip.demo.message")
                    }
                }
                .font(VCType.callout.font())
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .background(DesignValues.color("bg.window"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context demonstration")
        .accessibilityIdentifier("voxclip.demo")
        .modifier(EditorPaneFocus(model: model, pane: .panel))
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { session.chooseProject(url) }
        }
        .onChange(of: model.projectRevision) { _, _ in session.followEditor() }
        .onChange(of: model.selectedWordIDs) { _, _ in session.followEditor() }
        .onChange(of: model.selectedPauseIDs) { _, _ in session.followEditor() }
        .onChange(of: model.mediaResolved) { _, _ in session.followEditor() }
        .onChange(of: model.mediaUnreadable) { _, _ in session.followEditor() }
        .onChange(of: model.exporting) { _, _ in session.followEditor() }
        .onExitCommand {
            if session.busy { session.cancel() } else { model.closeContextDemoJob() }
        }
        .onDisappear { if session.busy { session.cancel() } }
    }

    private var sourceFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Starting point", selection: Binding(get: { session.targetKind.rawValue }, set: {
                if let kind = ContextDemoTargetKind(rawValue: $0) { session.chooseKind(kind) }
            })) {
                Text("Webpage URL").tag(ContextDemoTargetKind.webPage.rawValue)
                Text("Code project folder").tag(ContextDemoTargetKind.codeProject.rawValue)
                Text("Running app window").tag(ContextDemoTargetKind.desktopApp.rawValue)
            }
            .accessibilityIdentifier("voxclip.demo.targetKind")
            if session.targetKind == .webPage {
                TextField("https://example.com", text: Binding(get: { session.urlText }, set: session.setURL))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Demonstration webpage URL")
                    .accessibilityIdentifier("voxclip.demo.url")
                ContextDemoWebActionSetupView(session: session)
            }
            if session.targetKind == .codeProject {
                Button(session.projectURL == nil ? "Choose Project Folder…" : "Change Project Folder…") { choosingFolder = true }
                    .accessibilityIdentifier("voxclip.demo.chooseProject")
                if let url = session.projectURL { Text(url.path).textSelection(.enabled) }
                if session.projectURL != nil {
                    ContextDemoProjectSetupView(launch: session.projectLaunch, usePreviewURL: session.useProjectPreviewURL)
                }
            }
            if session.targetKind != .webPage {
                windowPicker
                ContextDemoDesktopReviewView(session: session)
            }
            Stepper(value: Binding(get: { session.captureSeconds }, set: session.setCaptureSeconds), in: 1...30, step: 1) {
                Text("Capture up to \(Int(session.captureSeconds)) seconds")
            }
            .accessibilityIdentifier("voxclip.demo.duration")
        }
    }

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.windows.isEmpty {
                Picker("Capture window", selection: Binding(get: { session.selectedWindowID ?? 0 }, set: {
                    session.chooseWindow($0 == 0 ? nil : $0)
                })) {
                    Text("Choose an exact window").tag(UInt32(0))
                    ForEach(session.windows) { window in
                        Text("\(window.applicationName) — \(window.windowTitle) (\(window.id))").tag(window.id)
                    }
                }
                .accessibilityIdentifier("voxclip.demo.window")
            }
            if session.loadingWindows {
                Text("Reading available app windows…")
            } else {
                Button("Refresh App Windows", action: session.refreshWindows)
                    .accessibilityIdentifier("voxclip.demo.refreshWindows")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = session.unavailableReason {
                Text(reason).foregroundStyle(DesignValues.color("text.secondary"))
                    .accessibilityIdentifier("voxclip.demo.unavailable")
            } else if let reason = session.placementReason {
                Text(reason).foregroundStyle(DesignValues.color("text.secondary"))
                    .accessibilityIdentifier("voxclip.demo.invalidPlacement")
            } else if !session.busy, !session.canReview, session.request == nil, session.selectedAsset == nil, let reason = session.inputReason {
                Text(reason).foregroundStyle(DesignValues.color("text.secondary"))
            }
            if !session.busy {
                Button("Check Screen Recording Access", action: session.checkCaptureAccess)
                    .accessibilityHint("Checks the current grant only. Does not request permission, open another app or start recording.")
                    .accessibilityIdentifier("voxclip.demo.checkCaptureAccess")
            }
            VStack(alignment: .leading, spacing: 8) {
                if session.busy {
                    HStack(spacing: 8) {
                    Button("Cancel", action: session.cancel).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("voxclip.demo.cancel")
                    if session.phase == .recording {
                        Button("Finish Recording", action: session.finishRecording)
                            .accessibilityIdentifier("voxclip.demo.finish")
                    }
                    }
                } else {
                    HStack(spacing: 8) {
                    if session.selectedPlacementID != nil {
                        Menu("Demonstration") {
                            Button("Record Replacement…", action: session.replaceSelected)
                            Button("Remove from Narration", role: .destructive) { session.removeSelected() }
                        }
                        .accessibilityIdentifier("voxclip.demo.placementActions")
                    }
                    if session.selectedAsset != nil {
                        Button("New Capture", action: session.newCapture)
                            .accessibilityIdentifier("voxclip.demo.newCapture")
                    }
                    }
                    if session.canStart {
                        Button("Start Recording", action: session.start).buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("voxclip.demo.start")
                    } else if session.canApply {
                        Button(session.recordedAsset == nil ? "Apply Trim" : session.selectedPlacementID == nil ? "Place Beside Narration" : "Replace Demonstration") {
                            session.apply()
                        }.buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: [.command])
                            .accessibilityIdentifier("voxclip.demo.apply")
                    } else if session.canReview {
                        Button("Review Capture", action: session.review)
                            .accessibilityIdentifier("voxclip.demo.review")
                    }
                }
            }
        }
        .font(VCType.callout.font())
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(DesignValues.color("line.default")).frame(height: 1) }
    }
}

private struct ContextDemoReviewView: View {
    let request: ContextDemoCaptureRequest
    let allowsPageScripts: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review actual capture and actions").font(VCType.body.font(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(request.target.displayName).textSelection(.enabled)
            Text(request.target.locator).foregroundStyle(DesignValues.color("text.secondary")).textSelection(.enabled)
            if request.target.kind == .webPage {
                Text(ContextDemoBrowserSession.pageScriptNotice(allowsPageScripts: allowsPageScripts))
                    .foregroundStyle(DesignValues.color("text.secondary"))
            }
            ForEach(request.actions) { action in
                Label(action.summary, systemImage: "checklist")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Local video only · up to 30 fps · no capture audio · review before placement")
                .foregroundStyle(DesignValues.color("text.tertiary"))
        }
        .accessibilityIdentifier("voxclip.demo.captureReview")
    }
}

@MainActor private struct ContextDemoTrimFields: View {
    @Bindable var session: ContextDemoSession
    let asset: ContextDemoAsset
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review and trim recorded result").font(VCType.body.font(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("\(asset.pixelWidth) × \(asset.pixelHeight) · \(asset.durationSeconds.formatted(.number.precision(.fractionLength(2)))) seconds · capture audio muted")
            field("Capture in (seconds)", value: session.trimStart) { session.setTrim(start: $0, end: session.trimEnd, editedStart: session.editedStart) }
            field("Capture out (seconds)", value: session.trimEnd) { session.setTrim(start: session.trimStart, end: $0, editedStart: session.editedStart) }
            field("Narration position (edited seconds)", value: session.editedStart) { session.setTrim(start: session.trimStart, end: session.trimEnd, editedStart: $0) }
            Text("Trim changes are a draft until Apply and snap to the narration sample grid. Placement never cuts or replaces your source narration. Undo restores the entire change.")
                .foregroundStyle(DesignValues.color("text.secondary"))
        }
    }
    private func field(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextField(title, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
}

private struct ContextDemoPlacementList: View {
    let document: ContextDemoDocument
    let selected: String?
    let select: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Placed demonstrations").font(VCType.body.font(.semibold)).accessibilityAddTraits(.isHeader)
            ForEach(document.placements) { placement in
                Button { select(placement.id) } label: {
                    Label("\(placement.editedStartSeconds.formatted(.number.precision(.fractionLength(2))))–\(placement.editedEndSeconds.formatted(.number.precision(.fractionLength(2)))) seconds",
                        systemImage: placement.id == selected ? "checkmark.circle.fill" : "play.rectangle")
                }
                .accessibilityLabel("Preview and trim demonstration at \(placement.editedStartSeconds.formatted()) edited seconds")
            }
        }
    }
}

@MainActor private struct ContextDemoResultPreview: View {
    let url: URL
    let trim: TimeRange
    @State private var player = AVPlayer()
    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(16 / 9, contentMode: .fit)
            .accessibilityLabel("Recorded demonstration preview, capture audio muted")
            .onAppear {
                player.isMuted = true
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                updateTrim()
            }
            .onChange(of: trim) { _, _ in player.pause(); updateTrim() }
            .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
    }
    private func updateTrim() {
        guard trim.start.isFinite, trim.end.isFinite, trim.start >= 0, trim.end > trim.start else { return }
        let start = CMTime(seconds: trim.start, preferredTimescale: 48_000)
        player.currentItem?.reversePlaybackEndTime = start
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: trim.end, preferredTimescale: 48_000)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
