import AVFoundation
import Foundation
import VoxClipCore
import VoxClipMedia

/// "Rebuild from my videos" in Settings › Voices (voice-lab §6.12, ADR-R44; design.md Settings › Voices, the rebuild
/// row). Free and local until the one priced click: the owner-verified speech across the user's videos is found and
/// shown first ("2 min from 9 videos", ▶ for a few pieces), the three attestations are ticked inline, and **Rebuild ·
/// price** goes through the existing attested creation route (checkbox consent, journal, creator binding). Afterwards
/// the row offers **Use the new voice for Rewrite** and **Remove the old voice** (the existing deletion), inline.
/// Only a click in Settings starts it; ✦ Claude does it all and Make it postable never do.
@MainActor @Observable final class VoiceRebuildState {
    enum Phase: Equatable {
        /// Nothing found yet: the row offers Rebuild from my videos.
        case idle
        case finding
        /// Found; waiting for the three attestations, then the local quote.
        case found
        case preparing
        /// Quoted: Rebuild · price can act.
        case ready
        case creating
        /// The new voice exists; the switch and the removal are offered.
        case created(String)
        case failed
    }
    let oldID: String
    var phase = Phase.idle
    /// The row's footer: always the next step.
    var line = ""
    var summary = ""
    var found: VoiceRebuildFinder.Found?
    var plan: VoiceEnrollmentPlan?
    var ownVoice = false { didSet { attestationsChanged(oldValue != ownVoice) } }
    var adult = false { didSet { attestationsChanged(oldValue != adult) } }
    var ownVideosOnly = false { didSet { attestationsChanged(oldValue != ownVideosOnly) } }
    var usedForRewrite = false
    var confirmingRemoval = false
    var removed = false
    @ObservationIgnored var acceptedAt = Date()
    @ObservationIgnored var recordID = UUID().uuidString.lowercased()
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored weak var session: VoiceLabSession?
    init(oldID: String, session: VoiceLabSession) { self.oldID = oldID; self.session = session }
    var attested: Bool { ownVoice && adult && ownVideosOnly }
    private func attestationsChanged(_ changed: Bool) {
        guard changed else { return }
        if attested { acceptedAt = Date() }
        session?.rebuildAttestationsChanged(self)
    }
}

extension VoiceLabSession {
    /// The setting "Use the new voice for Rewrite" writes: the consent record Rewrite starts with.
    static let rewriteVoiceKey = "voiceLab.rewriteVoice"
    static let rebuildIntro = "Makes a new copy of your voice from your clearest speech across your videos, checked against your consent recording. Finding it is free and stays on this Mac."

    func rebuild(for recordID: String) -> VoiceRebuildState {
        if let existing = rebuilds[recordID] { return existing }
        let state = VoiceRebuildState(oldID: recordID, session: self)
        rebuilds[recordID] = state
        return state
    }

    /// Finds the rebuild set across `projects` (default: recent projects and the export folder), on this Mac.
    func findRebuild(recordID: String, projects: [URL]? = nil) {
        let state = rebuild(for: recordID)
        guard ![.finding, .creating, .preparing].contains(state.phase),
              let record = records.first(where: { $0.id == recordID }), record.status == .active else { return }
        let urls = projects ?? learningProjects()
        state.found = nil; state.plan = nil; state.summary = ""; state.usedForRewrite = false; state.confirmingRemoval = false
        guard !urls.isEmpty else {
            state.phase = .failed; state.line = "Open or export a video first. VoxClip rebuilds your voice from your projects on this Mac."
            return
        }
        state.phase = .finding
        state.line = "Finding your clearest speech in video 1 of \(urls.count)… Nothing is sent."
        let previous = state.task
        state.task = Task { [weak self, weak state] in
            await previous?.value
            guard let self, let state else { return }
            guard let check = try? await referenceSpeakerCheck(language: record.language), check.available else {
                state.phase = .failed; state.line = "The speaker check isn't ready. Download it in Voice Lab, then try again."
                return
            }
            let sources = await rebuildSources(urls)
            let finder = VoiceRebuildFinder(store: store, check: check)
            do {
                let found = try await finder.find(recordID: recordID, sources: sources) { index, count in
                    await MainActor.run { state.line = "Finding your clearest speech in video \(index) of \(count)… Nothing is sent." }
                }
                state.found = found
                state.summary = VoiceRebuild.summary(found.plan)
                state.phase = .found
                rebuildAttestationsChanged(state)
            } catch VoiceRebuildFinder.Failure.notEnough(let milliseconds, let noisy) {
                state.phase = .failed
                state.line = Self.notEnoughLine(milliseconds: milliseconds, noisy: noisy, videos: urls.count)
            } catch is CancellationError {
                state.phase = .idle; state.line = ""
            } catch {
                state.phase = .failed; state.line = "Couldn't read your videos for a rebuild. Nothing was sent. Try again."
            }
        }
    }

    /// The three attestations changed: with all three, prepare the local creation quote; otherwise drop it. Every
    /// enrollment call runs on the one task chain, after the step before it, so a stale draft is never cancelled late.
    func rebuildAttestationsChanged(_ state: VoiceRebuildState) {
        guard [.found, .ready, .preparing].contains(state.phase), let found = state.found else { return }
        let previous = state.task
        previous?.cancel()
        let draft = state.recordID, drafted = state.plan != nil || state.phase == .preparing
        state.plan = nil
        guard state.attested else {
            state.phase = .found
            state.line = "Tick the three boxes to rebuild. Only this speech is sent to ElevenLabs; no video."
            guard drafted else { return }
            state.task = Task { [weak self] in
                await previous?.value
                guard let enrollment = try? self?.services().1 else { return }
                try? await enrollment.cancel(recordID: draft)
            }
            return
        }
        guard let record = records.first(where: { $0.id == state.oldID }) else { return }
        state.phase = .preparing
        state.line = "Preparing the price… Nothing is sent."
        let attestations = VoiceConsentRecord.Attestations(ownVoice: true, adult: true, ownVideosOnly: true, acceptedAt: state.acceptedAt)
        let name = Self.rebuildName(record.voiceName)
        state.task = Task { [weak self, weak state] in
            await previous?.value
            guard let self, let state, !Task.isCancelled else { return }
            do {
                let (_, enrollment) = try services()
                try await enrollment.setSpeakerCheck(try await referenceSpeakerCheck(language: record.language))
                if drafted { try await enrollment.cancel(recordID: draft) }
                let id = UUID().uuidString.lowercased()
                state.recordID = id
                let plan = try await enrollment.prepareProjectPlan(recordID: id, language: record.language, attestations: attestations,
                    displayName: name, samples: found.samples, enabled: enabled)
                guard !Task.isCancelled else { try? await enrollment.cancel(recordID: id); return }
                state.plan = plan
                state.phase = .ready
                state.line = "Sends \(VoiceRebuild.amount(Int(plan.trainingSeconds * 1_000))) of your speech to ElevenLabs to make a new voice, with your checkbox consent. No video is sent. Your current voice stays until you remove it."
            } catch is CancellationError {
            } catch {
                state.phase = .found
                state.line = await rebuildError(error)
            }
        }
    }

    /// Too little clean speech that's clearly the owner's: how much, why, and the next step.
    static func notEnoughLine(milliseconds: Int, noisy: Int, videos: Int) -> String {
        let found = "Only \(VoiceRebuild.amount(milliseconds)) of clean speech that's clearly yours in \(videos) \(videos == 1 ? "video" : "videos")"
        let why = noisy > 0 ? ", and \(noisy) \(noisy == 1 ? "stretch was" : "stretches were") too noisy to train a voice" : ""
        return found + why + ". A rebuild needs 30 s. Transcribe a video recorded somewhere quiet, then try again."
    }

    /// "siim (VoxClip)" → "siim": the display name the new voice keeps.
    static func rebuildName(_ voiceName: String) -> String {
        voiceName.hasSuffix(" (VoxClip)") ? String(voiceName.dropLast(" (VoxClip)".count)) : voiceName
    }

    /// Rebuild · price: the only paid click. The consent, journal and creator binding are the attested creation's own.
    func rebuildTitle(_ state: VoiceRebuildState) -> String {
        guard let plan = state.plan else { return "Rebuild" }
        guard let usd = plan.quote.estimate.usd else { return "Rebuild · Cost unknown" }
        return "Rebuild · " + (usd == 0 ? "$0" : VoiceLabCostPresentation.format(usd))
    }

    func approveRebuild(_ state: VoiceRebuildState) async {
        guard state.phase == .ready, let plan = state.plan, !busy, enabled else { return }
        busy = true; state.phase = .creating
        state.line = "Making your new voice in your ElevenLabs account…"
        defer { busy = false }
        app.set("voiceLab.providerConsent.elevenlabs", .bool(true))
        do {
            let (_, enrollment) = try services()
            let record = try await enrollment.execute(plan, approved: true, enabled: enabled, appVersion: AppModel.version)
            state.plan = nil; state.found = nil
            let carried = (try? await store.carryReferences(from: state.oldID, to: record.id)) ?? 0
            await load()
            state.phase = .created(record.id)
            let learned = carried == 0 ? "" : " It keeps what VoxClip learned from \(carried) of your videos."
            state.line = record.status == .verificationRequired
                ? "ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back."
                : "Your rebuilt voice is ready.\(learned) Next: use it for Rewrite, then remove the old voice."
        } catch let error as VoiceConsentSaveError {
            unsavedRecord = error.record
            state.phase = .failed
            state.line = "ElevenLabs made the new voice, but its consent record couldn't be saved. Retry saving below. Don't rebuild again."
            await load(recover: false)
        } catch {
            let reason = await rebuildError(error)
            state.ownVoice = false
            state.phase = .found; state.plan = nil
            state.line = reason + " Tick the first box again for a fresh price."
            await load(recover: false)
        }
    }

    /// Use the new voice for Rewrite: Rewrite starts with it wherever it is listed.
    func useRebuiltVoice(_ state: VoiceRebuildState) {
        guard case .created(let id) = state.phase, records.contains(where: { $0.id == id && $0.status == .active }) else { return }
        app.set(Self.rewriteVoiceKey, .string(id))
        state.usedForRewrite = true
        state.line = state.removed ? "Rewrite uses your rebuilt voice." : "Rewrite uses your rebuilt voice. Next: remove the old voice."
    }

    /// Remove the old voice, after its inline confirmation: the existing deletion (creator binding, journal, tombstone).
    func removeOldVoice(_ state: VoiceRebuildState) async {
        guard case .created(let id) = state.phase, state.confirmingRemoval, !busy, enabled else { return }
        busy = true; state.confirmingRemoval = false
        defer { busy = false }
        do {
            let (_, enrollment) = try services()
            try await enrollment.delete(recordID: state.oldID, approved: true, enabled: enabled)
            if app.string(Self.rewriteVoiceKey) == state.oldID || app.string(Self.rewriteVoiceKey).isEmpty {
                app.set(Self.rewriteVoiceKey, .string(id)); state.usedForRewrite = true
            }
            state.removed = true
            await load()
            state.line = "Removed the old voice. Rewrite uses your rebuilt voice. Existing takes stay playable and labelled."
        } catch {
            await load(recover: false)
            state.line = await rebuildError(error) + " The old voice is still here; Remove the old voice again to retry."
        }
    }

    /// Plays one of the found pieces.
    func playRebuildPiece(_ state: VoiceRebuildState, index: Int) {
        guard let samples = state.found?.samples, samples.indices.contains(index), !recorder.recording else { return }
        do { rebuildPlayer = try AVAudioPlayer(data: samples[index].wav); rebuildPlayer?.play() }
        catch { state.line = "This piece couldn't be played. Nothing changed." }
    }

    private func rebuildSources(_ urls: [URL]) async -> [VoiceRebuildFinder.Source] {
        var sources: [VoiceRebuildFinder.Source] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url), let project = try? JSONProjectStore.decode(data),
                  let media = try? await app.projectStore.resolveSource(for: project, projectURL: url) else { continue }
            sources.append(.init(project: project, media: media))
        }
        return sources
    }

    private func rebuildError(_ error: any Error) async -> String {
        if let error = error as? VoiceConsentError, error == .speakerMismatch {
            return "Some of this speech doesn't sound like your consent recording, and too little is left. Nothing was sent."
        }
        if let error = error as? VoiceLabError {
            switch error {
            case .noVoiceSlots: return "Your ElevenLabs account has no free voice slot. Free one on elevenlabs.io, then try again."
            case .planUnavailable: return "Instant voice cloning needs an ElevenLabs Starter plan or higher."
            case .missingKey: return "Add your ElevenLabs key above, then try again."
            default: break
            }
        }
        let text = await errorMessage(error)
        return text.isEmpty ? "Couldn't finish. Nothing more was sent." : text
    }
}
