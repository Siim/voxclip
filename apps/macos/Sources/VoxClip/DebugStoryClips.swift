#if DEBUG
import SwiftUI
import VoxClipCore

@MainActor enum DebugStoryClips {
    static func run(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        guard let shared = app.shared else { throw VoxClipError.sharedResourcesMissing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        let savedSettings = app.settings
        defer { app.settings = savedSettings }
        app.settings.values[ClipsMode.key] = .string(ClipsMode.pick.rawValue)
        var project = try storyProject(original)
        let styles = try ClipStyleCatalog.load(shared: shared)
        project.clipStyle = styles.initial(saved: nil)
        let shell = WorkspaceShell(app: app)
        shell.windowWidth = 1280
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true), selection: .clip("story"))
        guard let editor = shell.editor, let clip = editor.activeClip else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true
        editor.refresh()
        editor.selectedStoryPartID = "second"
        guard shell.outlineEntries.count == 6, !editor.showsClipsModeCard, !editor.showsClipStyleCard else {
            throw CocoaError(.coderInvalidValue)
        }

        func capture(_ name: String, width: CGFloat, height: CGFloat, @ViewBuilder content: () -> some View) async throws -> DebugUISuite.Result {
            try await DebugUISuite.snapshot(content().environment(app), name: name, size: NSSize(width: width, height: height),
                                            appearance: .darkAqua, directory: directory, active: true, orderOffscreen: false)
            return .init(name: name, passed: true)
        }
        var results: [DebugUISuite.Result] = []
        results.append(try await capture("story-clips-frame-3-outline", width: 440, height: 510) {
            ExplorerView(shell: shell)
        })
        results.append(try await capture("story-clips-frame-4-timeline", width: 1056, height: 275) {
            TimelinePanel(model: editor, shell: shell)
        })
        editor.showsCuts = true
        results.append(try await capture("story-clips-frame-4-show-cuts", width: 1056, height: 275) {
            TimelinePanel(model: editor, shell: shell)
        })
        editor.showsCuts = false
        results.append(try await capture("story-clips-frame-5-voice", width: 465, height: 340) {
            VStack(alignment: .leading, spacing: 12) {
                let length = StoryClipPresentation.metadata(clip, editedDuration: editor.editedDuration(clip)).length
                Text("Voice   Clip 2 · \(length) · \(clip.playParts.count) parts").font(VCType.callout.font(.semibold))
                StoryVoiceOptions(model: editor, clip: clip)
            }.padding(14).frame(maxHeight: .infinity, alignment: .top)
        })
        return results
    }

    private static func storyProject(_ original: Project) throws -> Project {
        var project = original
        let entries: [(id: String, start: Double, end: Double, line: String)] = [
            ("fourth", 160, 177, "SuperScribe is for business clients"),
            ("fifth", 272, 307, "The first client, a local telecom"),
            ("second", 484, 520, "I have automated my job with SuperScribe"),
            ("third", 627, 641, "If I can automate one job, I can do it with others"),
            ("opening", 853, 885, "This thing failed, but one thing leads to another"),
            ("sixth", 886, 892, "SuperScribe in turn opens me many opportunities")
        ]
        var words = [TimedWord(id: "intro", text: "One thing leads to another.", start: 120, end: 155)]
        var parts: [String: ClipPart] = [:]
        var cuts: [String] = []
        for entry in entries {
            let tokens = entry.line.split(separator: " ")
            let length = (entry.end - entry.start) / Double(tokens.count)
            for (index, token) in tokens.enumerated() {
                let id = "\(entry.id)-\(index)", start = entry.start + Double(index) * length
                words.append(TimedWord(id: id, text: String(token), start: start, end: index == tokens.count - 1 ? entry.end : start + length * 0.95))
                if index > 0, index < tokens.count - 1, index.isMultiple(of: 3) { cuts.append(id) }
            }
            parts[entry.id] = ClipPart(id: entry.id, startWordId: "\(entry.id)-0", endWordId: "\(entry.id)-\(tokens.count - 1)")
        }
        let order = ["opening", "second", "third", "fourth", "fifth", "sixth"].compactMap { parts[$0] }
        project.media.source.durationSeconds = 941
        project.transcript?.durationSeconds = 941
        project.transcript?.words = words
        project.edits = ProjectEdits(cutWordIds: cuts, clips: [ClipRange(id: "intro", startWordId: "intro", endWordId: "intro", title: "One thing leads to another")])
        try project.applyEditing(.addClip(ClipRange(id: "story", startWordId: "fourth-0", endWordId: "sixth-6",
                                                   title: "x11.social led to VoxConvo…", parts: order, kind: .story)))
        let reel = [ClipPart(id: "reel1", startWordId: "fifth-0", endWordId: "fifth-2"), ClipPart(id: "reel2", startWordId: "sixth-3", endWordId: "sixth-6")]
        try project.applyEditing(.addClip(ClipRange(id: "reel", startWordId: "fifth-0", endWordId: "sixth-6",
                                                   title: "From side project to first clients", parts: reel, kind: .showreel)))
        return project
    }
}
#endif
