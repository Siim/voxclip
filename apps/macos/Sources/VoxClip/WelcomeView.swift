import SwiftUI
import VoxClipCore

@MainActor public struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openDocument) private var openDocument
    @Environment(\.newDocument) private var newDocument
    @State private var dropTarget = false
    @State private var launchedDemo = false
    public init() {}
    public var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cut video by its words.").font(.system(size: 28, weight: .semibold))
                Text("Drop a talking-head video. VoxClip transcribes it so you can cut text.").foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                Label(dropTarget ? "Drop to transcribe" : "Drop a video here", systemImage: "arrow.down.doc").font(.title3)
                Text(".mov  .mp4  .m4v").font(DesignValues.mono()).foregroundStyle(.secondary)
                Button("Choose file…  ⌘O") { chooseFile(app: app, open: openDocument, create: newDocument) }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(DesignValues.color(dropTarget ? "line.strong" : "overlay.dropZoneBorder"), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
            .dropDestination(for: URL.self) { urls, _ in guard let url = urls.first else { return false }; openFile(url, app: app, open: openDocument, create: newDocument); return true } isTargeted: { dropTarget = $0 }
            HStack { Text("Recent").font(.headline); Spacer(); Button("Open project…") { chooseFile(app: app, open: openDocument, create: newDocument, projectsOnly: true) } }
            if app.recent.isEmpty { Text("No recent projects. Your first take starts here.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(app.recent, id: \.self) { url in
                            Button { openFile(url, app: app, open: openDocument, create: newDocument) } label: {
                                HStack { Image(systemName: "doc.text"); Text(url.deletingPathExtension().lastPathComponent); Spacer(); Text("Open").font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain).contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Button("Remove from list") {
                                    app.recent.removeAll { $0 == url }
                                    NSDocumentController.shared.clearRecentDocuments(nil)
                                    for remaining in app.recent.reversed() { NSDocumentController.shared.noteNewRecentDocumentURL(remaining) }
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 100)
            }
            Spacer(minLength: 0)
            if let error = app.startupError { InlineNotice(text: UserMessages.message(error)) }
            if let notice = app.notice { InlineNotice(text: notice) }
            HStack {
                Text("Transcription status unavailable in this build").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let update = app.update { Text("VoxClip \(update.version) is available.").font(.caption); Button("Download") { if update.htmlURL.host == "github.com" { NSWorkspace.shared.open(update.htmlURL) } } }
                else { SettingsLink { Text("Settings…") }.font(.caption) }
            }
        }
        .padding(32).frame(minWidth: 640, minHeight: 440)
        .sheet(isPresented: $app.showTour) { OnboardingView() }
        .task {
            #if DEBUG
            if AppModel.isTestSession { return }
            if let position = CommandLine.arguments.firstIndex(of: "-demoProject"), position + 1 < CommandLine.arguments.count, !launchedDemo {
                launchedDemo = true
                do {
                    let project = try DemoEditing.loadFixture(URL(fileURLWithPath: CommandLine.arguments[position + 1]))
                    newDocument { VoxClipDocument(project: project, demo: true) }
                } catch { app.notice = await app.safeError(error) }
            }
            #endif
        }
    }
}

@MainActor struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard shortcuts").font(.title2)
            Text("Select words in the transcript. Single-letter keys work in the editor, never while typing a correction or in a text field.").foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 8) {
                ForEach(["Space|Play / pause", "J / K / L|Back / stop / forward", "Delete / ⇧Delete|Cut / restore selection", "Return / C|Correct spelling", "⌘Z / ⇧⌘Z|Undo / redo", "← / →|Previous / next word", "⌥← / ⌥→|Previous / next sentence", "⇧← / ⇧→|Extend selection", "⌘K|Make clip from selection", "I / O|Set clip start / end", "[ / ]|Previous / next clip", "P|Preview this cut", "⌥⌘U / ⌥⌘P / ⌥⌘R|Cut fillers / tighten / restore", "⌘F / ⌘G / ⇧⌘G|Find / next / previous", "⌘1 / ⌘2|Captions / clips", "⌥⌘I|Toggle inspector", "⌘+ / ⌘− / ⌘0|Text size", "⌘E / ⌘O / ⌘,|Export / open / settings"], id: \.self) { line in
                    let parts = line.split(separator: "|")
                    GridRow { Text(parts[0]).font(DesignValues.mono()); Text(parts[1]) }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 580)
    }
}
