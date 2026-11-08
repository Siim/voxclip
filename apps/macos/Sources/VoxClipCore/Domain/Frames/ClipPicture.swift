import Foundation

/// The picture decisions of a clip's plan (ADR-R48, design.md §6.7.1, ai.md §19.6): the opening, the face-follow crop,
/// the blurred screens and the cover. Each is one project edit that keeps what it replaced, so it can be taken back on
/// its own. Make it postable's four review rows and the headless `voxclip-cli autopilot` both apply them through here, in
/// this order, so a project the CLI saves holds exactly what the app's rows apply.
public enum ClipPicture {
    public static let openingRowID = "frames-opening"
    public static let cropRowID = "frames-face"
    public static let coverRowID = "frames-cover"
    public static func blurRowID(_ candidate: String) -> String { "frames-blur-\(candidate)" }

    /// The effect id of a screen candidate's blur in a clip.
    public static func blurEffectID(clipID: String, candidate: String) -> String {
        String("fx-screen-\(candidate.lowercased())-\(clipID)".prefix(64))
    }

    // MARK: The opening

    /// "Opens on a clear look at you": the clip's start moved back into the pause before its first word.
    public struct Opening: Sendable, Equatable {
        /// The clip's lead-in now, seconds before its first word.
        public var leadIn: Double
        /// The lead-in it replaced (the row's Undo).
        public var previousLeadIn: Double?
        /// How much earlier the clip starts, seconds.
        public var earlier: Double
        /// The clip's new start, source seconds (▶).
        public var start: Double
        /// The chosen frame's source second.
        public var chosen: Double
        /// The opening scan's frame at the old start.
        public var current: FrameObservation?
        /// Why the old first frame was not a clear look (measured on this Mac).
        public var reason: String
    }

    /// The clip as its opening scan sees it: nil when the clip is gone or its first item is cut.
    public static func openingClip(_ project: Project, clipID: String) -> FrameClip? {
        guard let transcript = project.transcript, let range = project.edits.clips.first(where: { $0.id == clipID }),
              let first = transcript.words.firstIndex(where: { $0.id == range.startWordId }),
              let clip = FrameClip(transcript: transcript, clip: range, cutWordIds: Set(project.edits.cutWordIds)),
              clip.kept.first == first else { return nil }
        return clip
    }

    /// The start moves back (`OpeningFrame.choose`, never across a word) when the first frame of `scan` is not a clear
    /// look and one in the pause before it is. Nil when the start stays: the frame is clear, no frame there is better, or
    /// the move is under a frame. Facing is judged against `pitchBaseline`, the recording's typical pitch.
    public static func opening(_ project: Project, clipID: String, scan: [FrameObservation]?,
                               pitchBaseline: Double?) -> (project: Project, opening: Opening)? {
        guard let scan, let clip = openingClip(project, clipID: clipID),
              let choice = OpeningFrame.choose(clip, scan: scan, pitchBaseline: pitchBaseline), choice.shift < 0,
              let range = project.edits.clips.first(where: { $0.id == clipID }) else { return nil }
        let words = clip.words
        let first = clip.first, last = clip.last
        let lead = min(FrameSampling.openingSpan, ((clip.start - choice.time) * 1000).rounded() / 1000)
        guard lead > 0, let before = try? clipTimes(words, startIndex: first, endIndex: last, leadIn: range.leadInSeconds),
              let after = try? clipTimes(words, startIndex: first, endIndex: last, leadIn: lead),
              before.start - after.start >= 1.0 / 30, let next = settingLeadIn(lead, clipID: clipID, in: project) else { return nil }
        let current = scan.min { abs($0.time - clip.start) < abs($1.time - clip.start) }
        let opening = Opening(leadIn: lead, previousLeadIn: range.leadInSeconds, earlier: before.start - after.start, start: after.start,
                              chosen: choice.time, current: current,
                              reason: openingReason(current, pitchBaseline: pitchBaseline))
        return (next, opening)
    }

    /// Why the frame at the clip's start is not a clear look.
    public static func openingReason(_ frame: FrameObservation?, pitchBaseline: Double?) -> String {
        guard let face = frame?.face else { return "Your face wasn't in the first frame" }
        if face.eyes == .closed { return "Your eyes were shut on the first frame" }
        if face.facesCamera(pitchBaseline: pitchBaseline) == false { return "You were looking away on the first frame" }
        return "The first frame was blurred"
    }

    // MARK: The crop

    /// "9:16 follows your face": one static crop centre for 9:16 and 1:1.
    public struct Crop: Sendable, Equatable {
        public var centerX: Double
        public var centerY: Double
        /// The crop it replaced (the row's Undo).
        public var previous: ReframeSettings?
        /// The shape the row names: 9:16 when it is exported, else 1:1.
        public var shape: AspectRatio
    }

    /// The crop centred on the median measured face (`FaceFollowCrop`). Nil without a face in `sentences` or without a
    /// 9:16 or 1:1 shape among `shapes`.
    public static func crop(_ project: Project, clipID: String, sentences: [FrameObservation], shapes: [AspectRatio]) -> (project: Project, crop: Crop)? {
        guard shapes.contains(.portrait) || shapes.contains(.square), sentences.contains(where: { $0.face != nil }),
              let plan = FaceFollowCrop.plan(sentences.map { (time: $0.time, face: $0.face?.rect) },
                                             sourceAspect: sourceAspect(project.media.source.video), targetAspect: 9.0 / 16.0),
              let controls = ClipControlsProject.controls(for: clipID, in: project) else { return nil }
        let x = (plan.centerX * 1000).rounded() / 1000, y = (plan.centerY * 1000).rounded() / 1000
        guard let next = settingControls(clipID, in: project, { $0.reframe = .face(x: x, y: y) }) else { return nil }
        return (next, Crop(centerX: x, centerY: y, previous: controls.reframe, shape: shapes.contains(.portrait) ? .portrait : .square))
    }

    // MARK: The screens

    /// One detected screen: blurred, or left sharp.
    public struct Blur: Sendable, Equatable {
        public var candidate: ClipAutopilotFrames.BlurCandidate
        public var effectID: String
        /// The screen is blurred in the project now.
        public var blurred: Bool
        /// This apply added the blur (the row's Undo removes it).
        public var applied: Bool
        /// What the reply decided for it; nil when it named nothing for this screen.
        public var decision: ClipAutopilotPlan.FrameChoices.Blur?
        /// Claude's reason, nil when empty.
        public var reason: String? { decision.flatMap { $0.reason.isEmpty ? nil : $0.reason } }
    }

    /// The existing blur effect over a screen candidate, held still over its span and box.
    public static func blurEffect(_ candidate: ClipAutopilotFrames.BlurCandidate, clipID: String) -> ClipEffect {
        ClipEffect(id: blurEffectID(clipID: clipID, candidate: candidate.id), clipId: clipID, kind: .blur,
                   start: candidate.start, end: min(candidate.end, candidate.start + ClipEffect.maximumSeconds), rect: candidate.rect,
                   tracking: ClipEffect.Tracking.none)
    }

    /// Every screen of `frames`. With `applying`, a screen the reply chose to blur is blurred, but only when the frames
    /// went as images: an AI that got text only could not see it.
    public static func blurs(_ project: Project, clipID: String, frames: ClipAutopilotFrames, plan: ClipAutopilotPlan?,
                             applying: Bool) -> (project: Project, blurs: [Blur]) {
        var project = project
        var result: [Blur] = []
        for candidate in frames.blur {
            let decision = plan?.frames?.blur.first { $0.id == candidate.id }
            let id = blurEffectID(clipID: clipID, candidate: candidate.id)
            var applied = false
            if applying, frames.sendsImages, decision?.blur == true, !project.clipEffects.contains(where: { $0.id == id }),
               let next = try? ClipEffects.adding([blurEffect(candidate, clipID: clipID)], to: project) {
                project = next
                applied = true
            }
            result.append(Blur(candidate: candidate, effectID: id, blurred: project.clipEffects.contains { $0.id == id }, applied: applied,
                               decision: decision))
        }
        return (project, result)
    }

    /// "phone screen" for a framed screen taller than wide, "screen" for a wider one.
    public static func screenName(_ rect: ClipEffect.Rect, video: MediaVideo?) -> String {
        rect.width * sourceAspect(video) < rect.height ? "phone screen" : "screen"
    }

    // MARK: The cover

    /// "Cover frame chosen".
    public struct Cover: Sendable, Equatable {
        public var candidate: ClipAutopilotFrames.CoverCandidate
        /// The reply named this candidate; false when the local best was taken.
        public var named: Bool
        /// Claude's reason; nil when it named none or fell back.
        public var reason: String?
        /// The cover it replaced (the row's Undo).
        public var previous: Double?
    }

    /// The reply's pick among the cover candidates, or the best measured one when it named none. Nil without candidates.
    public static func cover(_ project: Project, clipID: String, frames: ClipAutopilotFrames, plan: ClipAutopilotPlan) -> (project: Project, cover: Cover)? {
        let named = plan.frames?.cover.flatMap { frames.coverCandidate($0.id) }
        guard let candidate = named ?? frames.cover.first, let controls = ClipControlsProject.controls(for: clipID, in: project),
              let next = settingControls(clipID, in: project, { $0.coverSeconds = candidate.time }) else { return nil }
        let reason = named == nil ? nil : plan.frames?.cover.flatMap { $0.fallback || $0.reason.isEmpty ? nil : $0.reason }
        return (next, Cover(candidate: candidate, named: named != nil, reason: reason, previous: controls.coverSeconds))
    }

    // MARK: All four

    /// What a clip's plan request carried of the picture, for the apply.
    public struct Inputs: Sendable {
        /// The frames as sent: with images, or the text summary only.
        public var frames: ClipAutopilotFrames
        /// The clip's sentence frames (the faces the crop follows).
        public var sentences: [FrameObservation]
        /// The opening scan of the clip as the plan leaves it (`openingClip`); nil when it could not be read.
        public var opening: [FrameObservation]?
        /// The shapes the clip exports in.
        public var shapes: [AspectRatio]
        /// The recording's typical pitch (`FrameFace.pitchBaseline` over the whole video's pass) the opening judges facing by.
        public var pitchBaseline: Double?
        public init(frames: ClipAutopilotFrames, sentences: [FrameObservation], opening: [FrameObservation]?, shapes: [AspectRatio],
                    pitchBaseline: Double?) {
            self.frames = frames; self.sentences = sentences; self.opening = opening; self.shapes = shapes
            self.pitchBaseline = pitchBaseline
        }
    }

    /// The four decisions as applied.
    public struct Decisions: Sendable, Equatable {
        public var opening: Opening?
        public var crop: Crop?
        public var blurs: [Blur]
        public var cover: Cover?
    }

    /// The opening, the crop, the screens and the cover applied in turn, each on the project the one before left.
    public static func apply(_ plan: ClipAutopilotPlan, clipID: String, to project: Project, inputs: Inputs) -> (project: Project, decisions: Decisions) {
        var next = project
        let opening = Self.opening(next, clipID: clipID, scan: inputs.opening, pitchBaseline: inputs.pitchBaseline)
        if let opening { next = opening.project }
        let crop = Self.crop(next, clipID: clipID, sentences: inputs.sentences, shapes: inputs.shapes)
        if let crop { next = crop.project }
        let screens = blurs(next, clipID: clipID, frames: inputs.frames, plan: plan, applying: true)
        next = screens.project
        let cover = Self.cover(next, clipID: clipID, frames: inputs.frames, plan: plan)
        if let cover { next = cover.project }
        return (next, Decisions(opening: opening?.opening, crop: crop?.crop, blurs: screens.blurs, cover: cover?.cover))
    }

    // MARK: Project edits

    /// `project` with the clip's opening lead-in set (nil removes it); a lead-in promotes the project to v4.
    public static func settingLeadIn(_ lead: Double?, clipID: String, in project: Project) -> Project? {
        guard let index = project.edits.clips.firstIndex(where: { $0.id == clipID }) else { return nil }
        var next = lead == nil ? project : ((try? ContextDemoProject.upgradeToV4(project)) ?? project)
        guard lead == nil || next.schemaVersion >= 4 else { return nil }
        next.edits.clips[index].leadInSeconds = lead
        return next
    }

    /// `project` with one clip's controls changed by `change`, the others kept.
    public static func settingControls(_ clipID: String, in project: Project, _ change: (inout ProjectClipControls) -> Void) -> Project? {
        guard var controls = ClipControlsProject.controls(for: clipID, in: project) else { return nil }
        change(&controls)
        return try? ClipControlsProject.setting(controls, in: project)
    }

    /// The source picture's display width over height (after its rotation); 16:9 without video facts.
    public static func sourceAspect(_ video: MediaVideo?) -> Double {
        guard let video, video.width > 0, video.height > 0 else { return 16.0 / 9.0 }
        let width = Double(video.width), height = Double(video.height)
        return video.rotationDegrees % 180 == 0 ? width / height : height / width
    }
}
