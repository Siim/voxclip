import SwiftUI
import VoxClipCore

@MainActor struct ContextDemoProjectSetupView: View {
    @Bindable var launch: ContextDemoProjectLaunchSession
    let usePreviewURL: @MainActor @Sendable (String) -> Void
    @State private var previewURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1. Inspect, then optionally run reviewed commands").font(VCType.body.font(.semibold))
            Text("Selecting a folder runs nothing. Inspect reads only bounded top-level manifests and README facts; repository text is untrusted. Dependencies must already be installed.")
                .foregroundStyle(DesignValues.color("text.secondary"))
            Button("Inspect Project Facts", action: launch.inspect).disabled(!launch.canInspect)
                .accessibilityIdentifier("voxclip.demo.project.inspect")
            if let facts = launch.facts {
                ForEach(facts.files, id: \.name) { fact in
                    Text("\(fact.name) · \(fact.byteCount) bytes · SHA-256 \(fact.sha256)").textSelection(.enabled)
                }
                ForEach(facts.reviewNotes, id: \.self) { Text($0) }
                ForEach(launch.commands) { command in
                    commandFields(command, scripts: facts.packageScriptNames)
                }
                HStack {
                    Button("Add Command", action: launch.addCommand).disabled(launch.commands.count >= 3 || launch.busy)
                    Button("Review Commands", action: launch.reviewCommands).disabled(!launch.canReview)
                        .accessibilityIdentifier("voxclip.demo.project.review")
                }
            }
            if let plan = launch.plan {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Exact command review").font(VCType.body.font(.semibold))
                    Text("Working directory: \(plan.snapshot.directory.path)").textSelection(.enabled)
                    Text("Environment: PATH=/usr/bin:/bin only. No inherited credentials. No shell. Output is bounded and discarded.")
                    ForEach(Array(plan.commands.enumerated()), id: \.offset) { index, command in
                        Text("\(index + 1). \(command.reviewDescription) · timeout \(command.timeoutSeconds) seconds")
                            .textSelection(.enabled)
                    }
                    Text(plan.reviewWarning).foregroundStyle(DesignValues.color("text.secondary"))
                    Text("At most 3 commands, 60 seconds each and 90 seconds total. Long-running previews stop at the reviewed timeout; this is not a background server launcher.")
                    Button("Approve and Start Commands", action: launch.start).disabled(!launch.canStart)
                        .accessibilityIdentifier("voxclip.demo.project.start")
                }
            }
            if launch.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(launch.phase == .stopping ? "Stopping and draining commands…" : launch.phase == .inspecting ? "Inspecting bounded project facts…" : "Running only the reviewed commands…")
                    Button("Stop", action: launch.stop).disabled(launch.phase == .stopping)
                        .accessibilityIdentifier("voxclip.demo.project.stop")
                }
            }
            if let message = launch.message { Text(message).foregroundStyle(DesignValues.color("text.secondary")) }
            Text("2. Review the running app example").font(VCType.body.font(.semibold))
            TextField("Exact preview URL, for example http://localhost:3000", text: $previewURL)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Running project preview URL")
            Button("Use Preview URL") { usePreviewURL(previewURL) }
                .disabled(launch.busy || (try? ContextDemoURLPolicy.validate(previewURL)) == nil)
            Text("Or choose the exact running app window below. Command approval never authorizes recording or page actions.")
                .foregroundStyle(DesignValues.color("text.tertiary"))
        }
        .accessibilityIdentifier("voxclip.demo.project.setup")
    }

    private func commandFields(_ command: ContextDemoProjectLaunchSession.CommandDraft, scripts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Absolute executable path", text: Binding(get: { command.executablePath }, set: {
                launch.setCommand(command.id, executablePath: $0, argumentsJSON: command.argumentsJSON, timeoutSeconds: command.timeoutSeconds)
            }))
            .accessibilityLabel("Absolute project command executable path")
            TextField("Arguments as a JSON string array", text: Binding(get: { command.argumentsJSON }, set: {
                launch.setCommand(command.id, executablePath: command.executablePath, argumentsJSON: $0, timeoutSeconds: command.timeoutSeconds)
            }))
            .accessibilityLabel("Exact project command argument array, JSON")
            Text("Arguments are a JSON array, not shell text. Example: [\"run\",\"build\"]. Enter only commands you trust; do not enter credentials.")
                .foregroundStyle(DesignValues.color("text.tertiary"))
            if !scripts.isEmpty {
                Menu("Use Inspected Package Script…") {
                    ForEach(scripts, id: \.self) { name in
                        Button(name) { launch.chooseScript(name, commandID: command.id) }
                    }
                }
                Text("Choosing a script fills [\"run\", script name] only. Choose the package-manager executable yourself and review all arguments.")
            }
            Stepper("Timeout: \(command.timeoutSeconds) seconds", value: Binding(get: { command.timeoutSeconds }, set: {
                launch.setCommand(command.id, executablePath: command.executablePath, argumentsJSON: command.argumentsJSON, timeoutSeconds: $0)
            }), in: 1...60)
            if launch.commands.count > 1 { Button("Remove Command") { launch.removeCommand(command.id) } }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(launch.busy)
    }
}

@MainActor struct ContextDemoWebActionSetupView: View {
    @Bindable var session: ContextDemoSession
    @State private var actionKind = "scroll"
    @State private var pixels = 500
    @State private var milliseconds = 500
    @State private var linkID = ""
    @State private var destination = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Allow this page’s standard JavaScript", isOn: Binding(get: { session.allowsPageScripts }, set: { session.setAllowsPageScripts($0) }))
                .accessibilityIdentifier("voxclip.demo.web.pageScripts")
            Text(ContextDemoBrowserSession.pageScriptNotice(allowsPageScripts: session.allowsPageScripts))
                .foregroundStyle(DesignValues.color("text.tertiary"))
            Text("After recording starts: open the exact URL, then perform these reviewed actions in order.")
            ForEach(Array(session.webActions.enumerated()), id: \.offset) { index, action in
                HStack(alignment: .top) {
                    Text("\(index + 1). \(action.reviewDescription)").textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("Remove") { session.removeWebAction(at: index) }
                        .accessibilityLabel("Remove webpage action \(index + 1)")
                }
            }
            Picker("Add webpage action", selection: $actionKind) {
                Text("Scroll").tag("scroll")
                Text("Ordinary link").tag("link")
                Text("Pause").tag("pause")
            }
            if actionKind == "scroll" {
                Stepper("Vertical pixels: \(pixels)", value: $pixels, in: -3000...3000, step: 100)
            } else if actionKind == "pause" {
                Stepper("Pause: \(milliseconds) ms", value: $milliseconds, in: 100...5000, step: 100)
            } else {
                TextField("Exact link element ID", text: $linkID).accessibilityLabel("Reviewed link element ID")
                TextField("Exact link destination URL", text: $destination).accessibilityLabel("Reviewed link destination URL")
                Text("Only a visible ordinary link with this exact ID and destination may be followed. No forms, downloads or new windows.")
            }
            Button("Add Reviewed Action") { addAction() }
                .disabled(session.webActions.count >= 11 || actionKind == "scroll" && pixels == 0)
                .accessibilityIdentifier("voxclip.demo.web.addAction")
            Text("Up to 11 optional actions; scroll ±3000 pixels, pause up to 5 seconds. The whole plan must fit the reviewed capture duration. Changing any choice requires a new capture review.")
                .foregroundStyle(DesignValues.color("text.tertiary"))
        }
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("voxclip.demo.web.actions")
    }

    private func addAction() {
        if actionKind == "scroll" { session.appendWebAction(.scroll(verticalPixels: pixels)) }
        else if actionKind == "pause" { session.appendWebAction(.pause(milliseconds: milliseconds)) }
        else { session.appendWebLink(elementID: linkID, destination: destination) }
    }
}
