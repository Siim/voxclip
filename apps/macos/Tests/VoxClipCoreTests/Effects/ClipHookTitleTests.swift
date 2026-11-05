import Foundation
import Testing
@testable import VoxClipCore

/// The hook's title card (design.md §6.7): an Ask Claude title over the clip's first ~2 s as it renders.
struct ClipHookTitleTests {
    /// Clip `c1` from "the" (0.6 s) to the end, with "um" cut before it, "is" (3.7 s) and "uh" (4.4 s) cut inside it and the
    /// 1.2 s pause after "simple." (1.9–3.1 s) tightened: the card's first 2 s cross the tightened pause.
    static func project() throws -> Project {
        var project = try ClipAutopilotTests.project(clips: [ClipRange(id: "c1", startWordId: "w2", endWordId: "w29", title: "Coffee")],
                                                     cut: ["w1", "w9", "w11"])
        project.edits.cutPauseIds = ["pause-after-w6"]
        return project
    }

    @Test func theCardCoversTheFirstTwoRenderedSecondsAndShowsWholeOnTheFirstFrame() throws {
        let project = try Self.project()
        let card = try #require(ClipHookTitle.effect(hook: "Sleep beats coffee", clipID: "c1", in: project))
        #expect(card.kind == .title && card.clipId == "c1" && card.text == "Sleep beats coffee" && card.position == .top)
        #expect(card.id == "fx-hook-1" && ClipHookTitle.isHook(card))
        // One overlay fade before the clip's first frame, so that frame (the thumbnail) shows the card whole.
        let timeline = try RenderCallerInputs.timeline(project: project, clipID: "c1")
        let first = timeline.sourceTime(0)
        #expect(first <= 0.6 && abs(card.start - (first - ClipEffect.overlayFadeSeconds)) < 1e-9)
        #expect(card.opacity(at: first) > 0.999)
        #expect(abs(timeline.mapTime(card.end) - 2) < 0.001, "two edited seconds from the clip's start")
        #expect(card.end > 3.1, "the tightened pause is skipped, so the card runs on past it in source time")
        try ClipEffects.validate(card, projectId: project.id)
    }

    @Test func aFasterClipShowsItForTwoRenderedSecondsAndARunReplacesItsCard() throws {
        var project = try ClipControlsProject.settingSpeed(1.25, clipId: "c1", in: try Self.project())
        let card = try #require(ClipHookTitle.effect(hook: "Sleep beats coffee", clipID: "c1", in: project))
        let timeline = try RenderCallerInputs.timeline(project: project, clipID: "c1")
        #expect(abs(timeline.mapTime(card.end) - 2.5) < 0.001, "2.5 edited seconds play in 2 rendered seconds at 1.25×")
        project = try ClipEffects.adding([card], to: project)
        let again = try #require(ClipHookTitle.effect(hook: "  Coffee\nis a loan  ", clipID: "c1", in: project))
        #expect(again.id == card.id && again.text == "Coffee is a loan")
        #expect(ClipHookTitle.effect(hook: " \n ", clipID: "c1", in: project) == nil)
        #expect(ClipHookTitle.effect(hook: "Hook", clipID: "missing", in: project) == nil)
        #expect(ClipHookTitle.text(String(repeating: "a", count: 100))?.unicodeScalars.count == ClipEffect.maximumTitleScalars)
    }

    @Test func aClipShorterThanTwoSecondsShowsItToItsEnd() throws {
        let project = try ClipAutopilotTests.project(clips: [ClipRange(id: "c2", startWordId: "w2", endWordId: "w4", title: "Short")])
        let card = try #require(ClipHookTitle.effect(hook: "Short", clipID: "c2", in: project))
        #expect(abs(card.end - 1.3) < 1e-9, "the clip's last word ends at 1.3 s")
    }
}
