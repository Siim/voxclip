import SwiftUI
import VoxClipCore

@MainActor struct HomeView: View {
    let model: EditorModel
    @State private var dropTarget = false
    @State private var launchedDemo = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Start a project").font(.largeTitle.weight(.semibold))
                    Text("Import a video to make your first clip, or continue a project.")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Label(dropTarget ? "Drop video to import" : "Start with a video", systemImage: "film.stack")
                        .font(.title3.weight(.medium))
                    Text("MOV, MP4 or M4V · Media and edits stay on this Mac unless you choose a cloud service.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Import Video…") { chooseVideo() }.buttonStyle(.borderedProminent)
                        Button("Open Project…") { chooseProject() }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
                .padding(20)
                .background(DesignValues.color("bg.surface"), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(DesignValues.color(dropTarget ? "line.strong" : "overlay.dropZoneBorder"), style: StrokeStyle(lineWidth: dropTarget ? 2 : 1, dash: dropTarget ? [6, 4] : [])))
                .dropDestination(for: URL.self) { urls, _ in guard let url = urls.first else { return false }; open(url); return true } isTargeted: { dropTarget = $0 }
                if let progress = model.importProgress {
                    HStack { ProgressView().controlSize(.small); Text(progress); Button("Cancel") { model.importTask?.cancel() } }
                }
                if let error = model.importError { InlineNotice(text: error) }
                if let error = model.app.startupError { InlineNotice(text: UserMessages.message(error)) }
                if let notice = model.app.notice { InlineNotice(text: notice) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Projects").font(.headline).padding(.bottom, 6)
                    if model.app.recent.isEmpty {
                        Text("No recent projects yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.app.recent, id: \.self) { url in
                            Button { open(url) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                                    Text(url.deletingPathExtension().lastPathComponent)
                                    Spacer()
                                    Text("Open").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 9).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Open recent project \(url.deletingPathExtension().lastPathComponent)")
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    Button("Remove from list") {
                                        model.app.recent.removeAll { $0 == url }
                                        NSDocumentController.shared.clearRecentDocuments(nil)
                                        for remaining in model.app.recent.reversed() { NSDocumentController.shared.noteNewRecentDocumentURL(remaining) }
                                    }
                                }
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 40)
        .task {
            #if DEBUG
            if !AppModel.isTestSession, model.isHome, !launchedDemo,
               let index = CommandLine.arguments.firstIndex(of: "-demoProject"), index + 1 < CommandLine.arguments.count {
                launchedDemo = true
                do {
                    let project = try DemoEditing.loadFixture(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    let document = VoxClipDocument(project: project, demo: true)
                    NSDocumentController.shared.addDocument(document)
                    document.makeWindowControllers()
                    document.showWindows()
                    model.closeEmptyWindow()
                } catch { model.importError = await model.app.safeError(error) }
            }
            #endif
        }
        .background(DesignValues.color("bg.window"))
    }
    private func chooseVideo() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    private func chooseProject() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.voxclipProject]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    private func open(_ url: URL) {
        if url.pathExtension.lowercased() == "voxclip" { openFile(url, app: model.app) }
        else if model.isHome { model.importTask = Task { await model.importVideo(url) } }
        else { openFile(url, app: model.app) }
    }
}

@MainActor struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard shortcuts").font(.title2)
            Text("Select words in the transcript. Single-letter keys work in the editor, never while typing a correction or in a text field.").foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 8) {
                ForEach(["Space|Play / pause", "J / K / L|Back / stop / forward", "Delete / ⇧Delete|Cut / restore selection", "Return / C|Correct spelling", "⌘Z / ⇧⌘Z|Undo / redo", "← / →|Previous / next word", "⌥← / ⌥→|Previous / next sentence", "⇧← / ⇧→|Extend selection", "⌘K|Make clip from selection", "I / O|Set clip start / end", "[ / ]|Previous / next clip", "P|Preview this cut", "⌥⌘U / ⌥⌘P / ⌥⌘R|Cut fillers / tighten / restore", "⌘F / ⌘G / ⇧⌘G|Find / next / previous", "⌘1 / ⌘2 / ⌘3|Home / transcript / clips", "⌥⌘I|Toggle caption inspector", "⌘+ / ⌘− / ⌘0|Text size", "⌘E / ⌘O / ⌘,|Export / open / settings"], id: \.self) { line in
                    let parts = line.split(separator: "|")
                    GridRow { Text(parts[0]).font(DesignValues.mono()); Text(parts[1]) }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 580)
    }
}
