import Foundation
import VoxClipCore
import VoxClipMedia

// "Claude sees the picture" in Make it postable (ADR-R48, design.md §6.7.1, ai.md §19.6). The whole video's sentence frames
// are looked at as soon as the transcript exists, while Find Clips runs. Each clip's plan request takes its frames from that
// pass just before it is sent, with the sheet's summary always and the 320 px frames when the AI takes images and the run
// may pay for them; its opening scan runs beside the request. The review then shows four applied decisions, each with ▶ and
// Undo: the opening, the face-follow crop, blurred screens and the cover. No new question and no pop-up: Claude mode decides
// as it does every other row.

/// Who the frames go to: the AI's name, whether it takes images, and who pays for them.
struct MakeItFrameAI: Equatable {
    enum Billing: Equatable {
        /// A CLI on the creator's plan: "on your Claude plan".
        case plan(String)
        /// An API key: the images are priced before the send and the run's cap covers them.
        case key(ConnectorID, model: String)
        /// A local server or Apple on-device: nothing to pay.
        case free
    }
    var name: String
    var images: Bool
    var billing: Billing
}

/// What a clip's plan request carried of the picture.
struct MakeItFrameRecord {
    var ai: MakeItFrameAI
    /// The frames as sent: with images, or the text summary only.
    var sent: ClipAutopilotFrames
    /// The clip's sentence frames (the faces the crop follows).
    var sentences: [FrameObservation]
    /// What the images were priced at, for an API key.
    var usd: Decimal?
}

/// A small frame a review row or the strip shows.
struct MakeItRowFrame: Equatable, Identifiable {
    var id: String
    var jpeg: Data
    /// Source seconds: ▶ or a click seeks here.
    var time: Double
    /// "eyes shut" on the opening's first frame.
    var tag: String?
    var picked = false
}

extension EditorModel {
    static let makeItScreensID = "frames-screens"
    static let makeItCoverID = ClipPicture.coverRowID

    // MARK: The pass

    /// Starts the whole video's frame pass when the transcript exists (and again for a new transcript); the pass is
    /// cached, so a reopened video costs little. Find Clips is never waited for or delayed by it.
    @discardableResult func startFramePass() -> VideoFramePass? {
        guard let transcript = project.transcript else { return nil }
        let key = project.media.source.contentKey + ":" + transcript.rawKey + ":\(transcript.words.count)"
        if makeIt.framePassKey == key, let pass = makeIt.framePass { return pass }
        makeIt.framePass.map { pass in Task { await pass.cancel() } }
        let services = makeIt.services ?? .live
        let pass = services.framePass(self)
        makeIt.framePass = pass
        makeIt.framePassKey = pass == nil ? nil : key
        let clock = claudeMode.clock
        if let pass { Task { await pass.start(clock: clock) } }
        return pass
    }

    /// The app's own pass: Apple Vision on this Mac, cached under the video's content key.
    func liveFramePass() -> VideoFramePass? {
        guard capabilities.ai, !document.demo, mediaResolved, !mediaUnreadable, project.media.source.video != nil,
              let words = project.transcript?.words, words.contains(where: { $0.kind == .word }) else { return nil }
        let log = app.log
        return VideoFramePass(analyzer: FrameAnalyzer(cache: FrameAnalysisCache(locations: app.locations)), source: sourceURL,
                              contentKey: project.media.source.contentKey, words: words) { line in
            Task { await log.write(LogEntry(level: .info, category: "frames", message: line)) }
        }
    }

    /// The AI the plan goes to, as the frames see it.
    func liveFrameAI() async -> MakeItFrameAI? {
        guard let provider = app.providers.first(where: { $0.id == app.string("llm.connector") }),
              let id = ConnectorID(rawValue: provider.id), let kind = app.llmSendKind(id) else { return nil }
        let name: String = switch id {
        case .claudeCode, .anthropic: "Claude"
        case .codex, .openai: "ChatGPT"
        case .gemini: "Gemini"
        case .xai: "Grok"
        default: provider.label
        }
        let images = await app.connector(provider.id).supportsImages()
        let billing: MakeItFrameAI.Billing
        if case .inline = kind {
            billing = provider.cliName == nil ? .free : .plan(id == .claudeCode ? "Claude" : "ChatGPT")
        } else {
            billing = .key(id, model: app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? ""))
        }
        return MakeItFrameAI(name: name, images: images, billing: billing)
    }

    /// What an API key would pay for a full frame sheet (24 frames of 320 × 180), for the click's cap; nil for a plan or a
    /// free AI, or when the connector is not priced (its frames then go as text).
    func makeItImageEstimate() -> Decimal? {
        guard let shared = app.shared, let provider = app.providers.first(where: { $0.id == app.string("llm.connector") }),
              let id = ConnectorID(rawValue: provider.id), case .confirm = app.llmSendKind(id) else { return nil }
        let model = app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "")
        let tokens = FrameSheet.maximumFrames * FrameSheet.imageTokens(width: FrameSheet.frameEdge, height: FrameSheet.frameEdge * 9 / 16)
        return (try? ClipAutopilotImagePrices(shared: shared))?.usd(tokens: tokens, connector: id, model: model)
    }

    // MARK: The request

    /// The frame source of a plan for the runs of `clipIDs` (in span order).
    func makeItFrameSource(_ clipIDs: [String]) -> ClipAutopilotFrameSource {
        { [weak self] index, span in await self?.makeItFrames(clipIDs: clipIDs, index: index, span: span) }
    }

    /// One clip's frames as its plan is sent: from the pass (waiting for it if it still runs), with its opening scan
    /// started beside the request. Images go only to an AI that takes them, and on an API key only when their price fits
    /// what the run may still spend; it is charged before the send, so plans in flight at once never pass the cap together.
    /// Nil sends the clip as text only.
    func makeItFrames(clipIDs: [String], index: Int, span: ClosedRange<Int>) async -> ClipAutopilotFrames? {
        guard clipIDs.indices.contains(index), let run = makeIt.run(for: clipIDs[index]), let transcript = project.transcript,
              let clip = FrameClip(words: transcript.words, first: span.lowerBound, last: span.upperBound,
                                   cutWordIds: Set(project.edits.cutWordIds)),
              let pass = startFramePass() else { return nil }
        let services = makeIt.services ?? .live
        guard let ai = await services.frameAI(self), let found = await pass.frames(for: clip) else { return nil }
        // The opening scan runs beside the plan request; the apply waits for it.
        await pass.startOpening(for: clip)
        var frames = ClipAutopilotFrames(sheet: found.sheet, clipStart: clip.start, clipEnd: clip.end, images: ai.images)
        var usd: Decimal?
        if frames.sendsImages, case .key(let connector, let model) = ai.billing {
            let price = app.shared.flatMap { try? ClipAutopilotImagePrices(shared: $0) }?
                .usd(tokens: frames.estimatedImageTokens, connector: connector, model: model)
            if let price, run.budget?.paidAllowed != false, let remaining = run.remaining, price <= remaining {
                run.charge(price)
                usd = price
            } else {
                frames = frames.textOnly
            }
        }
        run.frames = MakeItFrameRecord(ai: ai, sent: frames, sentences: found.sentences, usd: usd)
        return frames
    }

    // MARK: The send line

    /// "Claude read the clip's words and 24 small frames (one per sentence, 320 px) on your Claude plan. Faces were measured
    /// on this Mac." The bold part is `emphasis`.
    func makeItSendLine(_ run: MakeItRun) -> (lead: String, emphasis: String, tail: String)? {
        guard let record = run.frames, !record.sent.frames.isEmpty else { return nil }
        let count = record.sent.frames.count
        let faces = " Faces were measured on this Mac."
        guard record.sent.sendsImages else {
            return ("\(record.ai.name) read the clip's words and ", "a text summary of \(count) \(count == 1 ? "frame" : "frames")", "." + faces)
        }
        let billing: String = switch record.ai.billing {
        case .plan(let plan): " on your \(plan) plan"
        case .key: " billed to your key"
        case .free: ""
        }
        return ("\(record.ai.name) read the clip's words and ", "\(count) small \(count == 1 ? "frame" : "frames")",
                " (one per sentence, \(FrameSheet.frameEdge) px)\(billing)." + faces)
    }

    /// Up to five of the sent frames with their times; a click seeks the preview.
    func makeItFrameStrip(_ run: MakeItRun) -> [MakeItRowFrame] {
        guard let frames = run.frames?.sent.frames, !frames.isEmpty else { return [] }
        let chosen = FrameStripPick.spread(frames, limit: 5)
        return chosen.map { MakeItRowFrame(id: "strip-\($0.index)", jpeg: $0.image.data, time: $0.observation.time,
                                           tag: $0.observation.face?.eyes == .closed ? "eyes shut" : nil) }
    }

    /// m:ss of a source second on the clip as it renders.
    func makeItClipTime(_ source: Double, clipID: String) -> String {
        guard let timeline = try? RenderCallerInputs.timeline(project: project, clipID: clipID) else { return AIText.formatTime(source) }
        let speed = ClipControlsProject.controls(for: clipID, in: project)?.speed ?? 1
        return AIText.formatTime(ClipSpeedTiming(speed: speed).rendered(timeline.mapTime(source)))
    }

    // MARK: The rows

    /// The four picture decisions, applied to the project in the run's step through `ClipPicture` (the CLI autopilot applies
    /// the same): the opening, the face-follow crop, the blurred screens and the cover. Empty when the request carried no
    /// frames.
    func makeItPictureRows(_ plan: ClipAutopilotPlan, run: MakeItRun) async -> [MakeItRow] {
        guard let record = run.frames, let pass = makeIt.framePass else { return [] }
        var rows: [MakeItRow] = []
        if let row = await makeItOpeningRow(run: run, pass: pass) { rows.append(row) }
        if let row = makeItFaceRow(record, run: run) { rows.append(row) }
        rows += makeItScreenRows(record, plan: plan, run: run, applying: true)
        if let row = makeItCoverRow(record, plan: plan, run: run) { rows.append(row) }
        return rows
    }

    /// "Opens on a clear look at you": the start moves back into the pause before the first word (never across a word) when
    /// the first frame is not a clear look and one there is. No row when the start stays.
    private func makeItOpeningRow(run: MakeItRun, pass: VideoFramePass) async -> MakeItRow? {
        guard let clip = ClipPicture.openingClip(project, clipID: run.clipID),
              let (next, opening) = ClipPicture.opening(project, clipID: run.clipID, scan: await pass.opening(for: clip)) else { return nil }
        run.inverses[ClipPicture.openingRowID] = .leadIn(clipID: run.clipID, previous: opening.previousLeadIn)
        replace(next, name: "Make it postable")
        let earlier = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), opening.earlier)
        let currentTime = opening.current?.time ?? clip.start
        let thumbs = await pass.thumbnails([currentTime, opening.chosen])
        var frames: [MakeItRowFrame] = []
        if thumbs.count == 2 {
            frames = [MakeItRowFrame(id: "opening-before", jpeg: thumbs[0], time: currentTime,
                                     tag: opening.current?.face?.eyes == .closed ? "eyes shut" : nil),
                      MakeItRowFrame(id: "opening-after", jpeg: thumbs[1], time: opening.chosen, picked: true)]
        }
        return MakeItRow(id: ClipPicture.openingRowID, text: "Opens on a clear look at you",
                         detail: "\(opening.reason), so the clip starts in the pause \(earlier) s earlier",
                         play: opening.start, undoable: true, frames: frames)
    }

    /// "9:16 follows your face": the crop centred on the median measured face, one static centre for 9:16 and 1:1. No row
    /// without a face or without a portrait or square shape to export.
    private func makeItFaceRow(_ record: MakeItFrameRecord, run: MakeItRun) -> MakeItRow? {
        guard let (next, crop) = ClipPicture.crop(project, clipID: run.clipID, sentences: record.sentences, shapes: makeItStyle.shapes) else { return nil }
        run.inverses[ClipPicture.cropRowID] = .reframe(clipID: run.clipID, previous: crop.previous)
        replace(next, name: "Make it postable")
        return MakeItRow(id: ClipPicture.cropRowID, text: "\(crop.shape.rawValue) follows your face",
                         detail: "The crop is centred on your measured face position, not the middle of the frame",
                         play: clipPlay(run.clipID, in: project), undoable: true)
    }

    /// One row per detected screen: "Blurred the phone screen at 0:12–0:16" when Claude saw it and judged it private (the
    /// existing blur effect over its span and box), else "Phone screen at 0:12–0:16 left sharp" with an inline Blur. An AI
    /// without images never blurs on its own: it could not see the screen.
    func makeItScreenRows(_ record: MakeItFrameRecord, plan: ClipAutopilotPlan?, run: MakeItRun, applying: Bool) -> [MakeItRow] {
        let (next, screens) = ClipPicture.blurs(project, clipID: run.clipID, frames: record.sent, plan: plan, applying: applying)
        if next != project { replace(next, name: "Make it postable") }
        return screens.map { screen in
            let candidate = screen.candidate
            let rowID = ClipPicture.blurRowID(candidate.id)
            if screen.applied { run.inverses[rowID] = .effect(id: screen.effectID, previous: nil) }
            let name = ClipPicture.screenName(candidate.rect, video: project.media.source.video)
            let span = makeItClipTime(candidate.start, clipID: run.clipID) + "–" + makeItClipTime(candidate.end, clipID: run.clipID)
            var row = MakeItRow(id: rowID, kind: .choice, text: "", play: max(0, candidate.start - 0.5))
            if screen.blurred {
                row.text = "Blurred the \(name) at \(span)"
                row.detail = screen.reason ?? "The action you tap stays sharp"
                row.undoable = run.inverses[rowID] != nil
                row.change = .screens
            } else {
                row.text = "\(name.prefix(1).uppercased() + name.dropFirst()) at \(span) left sharp"
                row.detail = !record.sent.sendsImages ? "\(record.ai.name) takes text only, so it couldn't see this screen."
                    : screen.reason ?? "Nothing private showed on it."
                row.change = .screen(candidate.id)
                row.actionTitle = "Blur"
            }
            return row
        }
    }

    /// A Blur on a sharp screen, or a toggle in the screens list: blurs or unblurs it as its own undo step.
    func makeItToggleScreen(_ candidateID: String, run: MakeItRun) {
        guard !run.running, let record = run.frames, let candidate = record.sent.blurCandidate(candidateID) else { return }
        let id = ClipPicture.blurEffectID(clipID: run.clipID, candidate: candidateID)
        let blurred = project.clipEffects.contains { $0.id == id }
        let next = blurred ? try? ClipEffects.removing([id], from: project)
                           : try? ClipEffects.adding([ClipPicture.blurEffect(candidate, clipID: run.clipID)], to: project)
        guard let next else { return }
        replace(next, name: blurred ? "Unblur screen" : "Blur screen")
        let rowID = ClipPicture.blurRowID(candidateID)
        // A blur Claude made can still be taken back by its row's Undo; one the creator added is undone with ⌘Z.
        if blurred { run.inverses[rowID] = nil }
        let fresh = makeItScreenRows(record, plan: run.plan, run: run, applying: false)
        for row in fresh { if let index = run.rows.firstIndex(where: { $0.id == row.id }) { run.rows[index] = row } }
        announce(blurred ? "Screen left sharp." : "Screen blurred.")
    }

    /// Whether the screen candidate is blurred now (the Change list's toggles).
    func makeItScreenBlurred(_ candidateID: String, run: MakeItRun) -> Bool {
        project.clipEffects.contains { $0.id == ClipPicture.blurEffectID(clipID: run.clipID, candidate: candidateID) }
    }

    /// "Cover frame chosen": Claude's pick among the three best measured frames, or the best when it named none.
    private func makeItCoverRow(_ record: MakeItFrameRecord, plan: ClipAutopilotPlan, run: MakeItRun) -> MakeItRow? {
        guard let (next, cover) = ClipPicture.cover(project, clipID: run.clipID, frames: record.sent, plan: plan) else { return nil }
        run.inverses[Self.makeItCoverID] = .cover(clipID: run.clipID, previous: cover.previous)
        replace(next, name: "Make it postable")
        let detail = cover.reason ?? "Eyes open, the clearest look measured on this Mac"
        return MakeItRow(id: Self.makeItCoverID, text: "Cover frame chosen", detail: detail + " · saved next to the export as a cover image",
                         play: cover.candidate.time, undoable: true, change: .cover, frames: makeItCoverFrames(record, picked: cover.candidate.time))
    }

    /// The cover candidates as small frames, the picked one marked.
    func makeItCoverFrames(_ record: MakeItFrameRecord, picked: Double?) -> [MakeItRowFrame] {
        record.sent.cover.compactMap { candidate in
            record.sent.frames.first { $0.index == candidate.frame }.map {
                MakeItRowFrame(id: "cover-\(candidate.id)", jpeg: $0.image.data, time: candidate.time,
                               picked: picked.map { abs($0 - candidate.time) < 1e-6 } ?? false)
            }
        }
    }

    /// A cover candidate picked in the row's Change: the clip's cover, as one undo step.
    func makeItChooseCover(_ time: Double, run: MakeItRun) {
        guard !run.running, let record = run.frames, let index = run.rows.firstIndex(where: { $0.id == Self.makeItCoverID }),
              let next = ClipPicture.settingControls(run.clipID, in: project, { $0.coverSeconds = time }) else { return }
        if next != project { replace(next, name: "Change cover") }
        run.rows[index].frames = makeItCoverFrames(record, picked: time)
        run.rows[index].detail = "You chose the frame at \(makeItClipTime(time, clipID: run.clipID)) · saved next to the export as a cover image"
        run.rows[index].play = time
        run.openChoice = nil
    }
}

/// At most `limit` items evenly spread, the first and last kept.
enum FrameStripPick {
    static func spread<Item>(_ items: [Item], limit: Int) -> [Item] {
        guard items.count > limit, limit > 1 else { return Array(items.prefix(max(0, limit))) }
        let span = Double(items.count - 1), steps = Double(limit - 1)
        return (0..<limit).map { items[Int((Double($0) * span / steps).rounded())] }
    }
}
