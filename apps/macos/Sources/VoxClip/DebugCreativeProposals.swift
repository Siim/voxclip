#if DEBUG
import AppKit
import SwiftUI
import VoxClipCore

@MainActor enum DebugCreativeProposals {
    static let suggestedID = "proposal-scene-story"

    static func suggestedStory(in project: Project) throws -> Project {
        guard let words = project.transcript?.words, words.count > 38 else { throw CocoaError(.coderInvalidValue) }
        let sourceRanges = [29...38, 9...28, 0...8]
        let ranges = sourceRanges.map { ClipWordRange(startWordId: words[$0.lowerBound].id, endWordId: words[$0.upperBound].id) }
        let story = ProjectAIClip(title: "The steps that led to SuperScribe", reason: "The outcome first, then the steps that led to it.",
            score: 9, startWordId: words[0].id, endWordId: words[38].id, parts: ranges, notInTake: "You don't say “set me free”.")
        let resultID = "proposal-scene-find"
        let result = ProjectAIResult(id: resultID, createdAt: Date(timeIntervalSince1970: 0), provider: "claude-code", model: "fixture",
            preset: .custom, inputSha256: String(repeating: "0", count: 64), clips: [story])
        let parts = ranges.enumerated().map { index, range in
            ClipPart(id: "part-\(index + 1)", startWordId: range.startWordId, endWordId: range.endWordId)
        }
        let clip = ClipRange(id: suggestedID, startWordId: story.startWordId, endWordId: story.endWordId, title: story.title,
            origin: .ai, aiResultId: resultID, aiClipIndex: 0, selected: false, parts: parts, kind: .story)
        var next = project
        next.ai.results.append(result)
        try next.applyEditing(.addAIClips(resultId: resultID, clips: [clip]))
        return next
    }

    static func run(app: AppModel, directory: URL) async throws -> [DebugUISuite.Result] {
        guard let shared = app.shared else { throw VoxClipError.sharedResourcesMissing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = try DemoEditing.loadFixture(shared.root.appendingPathComponent("fixtures/projects/interview-take.voxclip"))
        let shell = WorkspaceShell(app: app)
        let project = try suggestedStory(in: original)
        await shell.attachForTesting(VoxClipDocument(project: project, demo: true))
        guard let editor = shell.editor, let clip = editor.suggestedClips.first(where: { $0.id == suggestedID }) else { throw CocoaError(.coderInvalidValue) }
        defer { editor.close() }
        editor.mediaResolved = true
        editor.refresh()
        let story = try result(editor, clip: clip, kind: .story, parts: [29...38, 9...28, 0...8], shared: shared)
        let reel = try result(editor, clip: clip, kind: .showreel, parts: [0...8, 9...18, 19...28, 29...38], shared: shared)
        let timeline = try HarnessTimeline.read(.object([
            "newClip": .object(["kind": .string("story"), "title": .string("The chain that led to SuperScribe")]),
            "reason": .string("Start on the payoff, then show what led to it."),
            "parts": .array([.object(["startWord": .number(29), "endWord": .number(38)]), .object(["startWord": .number(9), "endWord": .number(28)])]),
            "generateMusic": .string("Warm piano, 90 BPM")
        ]))
        let proposal = try HarnessProposal(timeline: timeline, project: project)
        let review = try proposal.review(project, shared: shared)
        let clipID = try proposal.clipID(at: 0)
        let reviewed = review.project.edits.clips.first { $0.id == clipID }
        let estimate = try? proposal.estimatedMusicPrice(in: review.project, shared: shared)
        let harness = editor.harnessCreativeData(timeline, clip: reviewed, result: review.project, operations: review.operations, estimate: estimate)
        let suggested = SuggestedClipCard(shell: shell, editor: editor, clip: clip, focused: true)
        let creative = HStack(alignment: .top, spacing: 12) {
            MakeItCreativeProposal(model: editor, run: story)
            MakeItCreativeProposal(model: editor, run: reel, startWithChange: true)
        }
        let terminal = HarnessCreativeProposal(data: harness, blocked: nil, keep: {}, undo: {})
        try await capture(suggested, frame: 1, name: "suggested", width: 380, height: 390, directory: directory)
        try await capture(creative, frame: 2, name: "creative", width: 860, height: 790, directory: directory)
        try await capture(terminal, frame: 6, name: "harness", width: 400, height: 490, directory: directory)
        return [1, 2, 6].map { .init(name: "Creative proposal frame \($0)", passed: true) }
    }

    private static func result(_ editor: EditorModel, clip: ClipRange, kind: ClipProposal.NewClip.Kind,
                               parts: [ClosedRange<Int>], shared: SharedResources) throws -> MakeItRun {
        let reel = kind == .showreel
        var plan = ClipAutopilotPlan(startWord: 0, endWord: 38,
            title: reel ? "From side project to first clients" : "Automating my job set me up for SuperScribe",
            hook: reel ? "" : "I have automated my job",
            captions: .init(styleId: "vox-bold", font: .init(family: "Roboto", weight: 900), textCase: .upper,
                            wordsPerCaption: 2, reason: "Make the claims easy to read on mute."),
            look: .init(id: .warm, reason: "Keep the take personal."),
            zooms: [.init(word: 29, untilWord: 31, scale: 1.2, reason: "Emphasize the payoff.")],
            postText: "", score: reel ? 8 : 9, verdict: reel ? .post : .postFirst)
        plan.orderedParts = parts.map { .init(startWord: $0.lowerBound, endWord: $0.upperBound) }
        plan.shape = kind
        let run = MakeItRun(clipID: clip.id, cap: 2)
        run.plan = plan
        run.phase = .ready
        run.seconds = reel ? 25 : 84
        run.proposalOperations = try ClipAutopilotMapping.operations(for: plan, clipID: clip.id, project: editor.project,
            fonts: ClipAutopilotFonts.load(shared: shared))
        let asset = MusicAsset(file: "scene/music.wav", sha256: String(repeating: "0", count: 64), durationSeconds: 30)
        run.proposalMusic = ProjectMusic(id: "scene-music", clipId: clip.id, asset: asset, source: reel ? .generated : .file,
            title: reel ? "Driving synth, 120 BPM" : "Upbeat, driven", license: reel ? .generated : .own,
            fadeInSeconds: 1, fadeOutSeconds: 2.5)
        if reel { run.spent = 0.35; run.assetPrices["music"] = 0.35 }
        return run
    }

    private static func capture(_ content: some View, frame: Int, name: String, width: CGFloat, height: CGFloat, directory: URL) async throws {
        let view = content.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        try await DebugUISuite.snapshot(view, name: "story-proposal-\(frame)-\(name)", size: NSSize(width: width, height: height),
                                        appearance: .darkAqua, directory: directory)
    }
}
#endif
