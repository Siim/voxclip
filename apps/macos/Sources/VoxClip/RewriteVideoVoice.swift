import Foundation
import VoxClipCore
import VoxClipMedia

/// A matching voice for each video in Rewrite (voice-lab §6.13, ADR-R45; design.md R2 "A matching voice for this
/// video"): the one-time inline question, the video's own voice made before any take is priced, and the take-match
/// diagnostic. ✦ Make it postable and ✦ Claude does it all reach it through `prepareTakes`; they never answer the
/// question, and with the stored answer "match" they make the voice like a manual run.
extension RewriteSession {
    /// The voice Rewrite starts with here: this video's own when it has one, otherwise the anchor.
    var preferredVoiceForVideo: String? {
        editor.app.voiceLabSession.rewriteVoicePreference(contentKey: project.media.source.contentKey, language: project.transcript?.language)
    }

    /// Before a price: with the stored answer "match", this video's voice is made (or the one being made is awaited)
    /// and chosen, so every take of every clip in the video uses it. A run with paid takes keeps its voice.
    func ensureVideoVoice() async {
        let voiceLab = editor.app.voiceLabSession
        guard voiceLab.videoVoiceMode == .match, voiceLab.offersVideoVoice(project), generation != nil, !hasPaidTakes else { return }
        let state = voiceLab.makeVideoVoice(project: project, media: editor.sourceURL)
        if let making = state.task {
            if isOpen, case .proposal = task.state { showProposal() }
            await making.value
        }
        guard current, !hasPaidTakes, let generation, case .ready(let id) = state.phase, generation.selectedVoiceID != id else { return }
        if !generation.voices.contains(where: { $0.id == id }) { await generation.discover(language: project.transcript?.language ?? "en") }
        generation.chooseVoice(id)
    }

    /// The panel's card for this video's voice, or nil: the question while the answer is unset, then what the video's
    /// voice is doing. Every chip acts; nothing here is disabled.
    func videoVoiceSteps() -> NextSteps? {
        let voiceLab = editor.app.voiceLabSession
        guard showsVoiceLab, voiceLab.offersVideoVoice(project), let anchor = voiceLab.anchorVoice(language: project.transcript?.language) else { return nil }
        let name = VoiceLabSession.rebuildName(anchor.voiceName)
        switch voiceLab.videoVoiceMode {
        case .anchor:
            return nil
        case .ask:
            guard !hasPaidTakes else { return nil }
            let price = voiceLab.videoVoicePrice
            let match = PanelAction(id: "videoVoiceMatch", title: "Match this video · " + (price ?? "price unknown")) { [weak self] in self?.matchThisVideo() }
            let keep = PanelAction(id: "videoVoiceAnchor", title: "Use \(name)") { [weak self] in self?.useAnchorForVideos() }
            let unknown = price == nil ? " VoxClip's price list has no price for making a voice." : ""
            return NextSteps(id: "videoVoice", line: VoiceLabSession.videoVoiceQuestion
                + " Only your clearest speech from this video is sent to ElevenLabs; no video." + unknown, chips: [match, keep].map { NextStepChip(action: $0) })
        case .match:
            guard let state = voiceLab.videoVoices[project.media.source.contentKey], !state.line.isEmpty else { return nil }
            switch state.phase {
            case .making:
                return NextSteps(id: "videoVoice", line: state.line)
            case .anchor:
                // Said once: in the first Rewrite run that found too little of the video's own speech.
                let run = ObjectIdentifier(self)
                guard state.notedIn == nil || state.notedIn == run else { return nil }
                state.notedIn = run
                return NextSteps(id: "videoVoice", line: state.line)
            case .failed:
                guard !hasPaidTakes else { return NextSteps(id: "videoVoice", line: state.line) }
                let retry = PanelAction(id: "videoVoiceRetry", title: "Try Again") { [weak self] in
                    state.phase = .idle; state.line = ""
                    self?.startVideoVoice()
                }
                return NextSteps(id: "videoVoice", line: state.line, chips: [NextStepChip(action: retry)])
            case .idle, .ready:
                return nil
            }
        }
    }

    /// "Match this video · price": the one-time opt-in, remembered; the video's voice is made now.
    func matchThisVideo() {
        editor.app.voiceLabSession.setVideoVoiceMode(.match)
        editor.announce("Matching voice on. Making a voice from this video.")
        startVideoVoice()
    }

    /// "Use siim": every video keeps the anchor, remembered; Settings › Voices can change it.
    func useAnchorForVideos() {
        editor.app.voiceLabSession.setVideoVoiceMode(.anchor)
        if isOpen, case .proposal = task.state { showProposal() }
    }

    private func startVideoVoice() {
        let previous = takesTask
        takesTask = Task { [weak self] in
            await previous?.value
            guard let self, current else { return }
            await ensureVideoVoice()
            if isOpen, case .proposal = task.state { showProposal() }
        }
        if isOpen, case .proposal = task.state { showProposal() }
    }

    /// The take-match diagnostic: the first take with this video's own voice, and the anchor's takes here, each
    /// against the original speech beside it. On this Mac, in the background, once per take.
    func measureVideoVoiceMatch(_ plan: ClipTakePlan) {
        let voiceLab = editor.app.voiceLabSession
        guard voiceLab.offersVideoVoice(project) else { return }
        let key = project.media.source.contentKey
        let title = VoicePerVideo.title(mediaPath: project.media.source.absolutePath)
        let language = project.transcript?.language ?? "en"
        var work: [(VoiceLabTakeAudio, VoiceLabTakeInput)] = []
        for phrase in plan.phrases {
            for take in phrase.takes where take.source == .clonedVoice && !videoVoiceMeasured.contains(take.id) {
                guard let audio = take.row.audio, let input = plan.measuredInput(take: take.id) else { continue }
                videoVoiceMeasured.insert(take.id)
                work.append((audio, input))
            }
        }
        guard !work.isEmpty else { return }
        let app = editor.app
        Task { [weak voiceLab] in
            guard let check = try? await app.speakerModelLibrary.check(language: language) else { return }
            for (audio, input) in work {
                guard let score = await VoicePerVideoMatch.score(take: audio, input: input, check: check) else { continue }
                await voiceLab?.recordTakeMatch(contentKey: key, title: title, recordID: input.recordID, score: score)
            }
        }
    }
}
