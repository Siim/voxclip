import AppKit
import Foundation
import VoxClipCore
import VoxClipMedia

/// One video's own voice this run (voice-lab §6.13, ADR-R45; design.md R2 "A matching voice for this video").
@MainActor @Observable final class VideoVoiceState {
    enum Phase: Equatable {
        case idle
        /// Finding the video's speech (free, on this Mac), then making the voice in the user's ElevenLabs account.
        case making
        /// The video's own voice: Rewrite's takes in this video use it.
        case ready(String)
        /// Takes use the anchor: too little of the video's own speech, or no voice made from videos to match from.
        case anchor
        /// Making it failed; takes use the anchor. Try Again acts.
        case failed
    }
    let contentKey: String
    var phase = Phase.idle
    /// The Rewrite panel's line for this video.
    var line = ""
    /// The Rewrite run that showed the anchor note: it is said once.
    @ObservationIgnored var notedIn: ObjectIdentifier?
    @ObservationIgnored var task: Task<Void, Never>?
    init(contentKey: String) { self.contentKey = contentKey }
}

extension VoiceLabSession {
    static let videoVoiceQuestion = "Make a matching voice from this video? Your takes will sound like this recording. The previous video's voice is removed."

    /// The remembered answer: Settings › Voices shows and changes it; Claude mode only reads it.
    var videoVoiceMode: VoicePerVideo.Mode {
        if case .bool(let value) = app.settings.values[VoicePerVideo.settingKey] { return VoicePerVideo.Mode(setting: value) }
        return .ask
    }
    func setVideoVoiceMode(_ mode: VoicePerVideo.Mode) {
        app.set(VoicePerVideo.settingKey, mode.setting.map(JSONValue.bool) ?? .null)
    }

    /// "Match this video · free": the catalogue's creation price; nil (and the opt-in says so) when it has none.
    var videoVoicePrice: String? { VoicePerVideo.priceLabel(catalog: app.shared.flatMap { try? VoiceLabPriceCatalog.load(shared: $0) }) }

    func videoVoice(_ contentKey: String) -> VideoVoiceState {
        if let existing = videoVoices[contentKey] { return existing }
        let state = VideoVoiceState(contentKey: contentKey)
        videoVoices[contentKey] = state
        return state
    }

    /// The consent voice per-video voices are made from and fall back to: an active voice in the project's language that
    /// is not a video's own, Settings' "Use for Rewrite" choice first.
    func anchorVoice(language: String?) -> VoiceConsentRecord? {
        let primary = Self.statementLanguage(language) { _ in true }
        let anchors = records.filter { $0.status == .active && $0.language == primary && !perVideoBook.isVideoVoice($0.id) }
        let preferred = app.string(Self.rewriteVoiceKey)
        return anchors.first { $0.id == preferred } ?? anchors.first
    }

    /// The voice Rewrite starts with in a video: its own voice when matching is on and it has one, otherwise the anchor,
    /// never another video's voice.
    func rewriteVoicePreference(contentKey: String, language: String?) -> String? {
        if videoVoiceMode == .match, let video = perVideoBook.video(contentKey),
           records.contains(where: { $0.id == video.recordId && $0.status == .active }) { return video.recordId }
        return anchorVoice(language: language)?.id
    }

    /// The opt-in can be offered in this project: Voice Lab is on, the project is transcribed in a language with a
    /// calibrated check, and its anchor was made from videos (an attested `/2` voice, whose consent clip goes first).
    func offersVideoVoice(_ project: Project) -> Bool {
        guard enabled, project.transcript != nil, !project.media.source.contentKey.isEmpty,
              !voicesUnavailable(projectLanguage: project.transcript?.language) else { return false }
        return anchorVoice(language: project.transcript?.language)?.projectConsent != nil
    }

    func loadPerVideo() async {
        var book = await perVideoStore.load()
        // A voice deleted elsewhere (Settings, ElevenLabs) is no longer any video's.
        let gone = Set(records.filter { $0.status == .deleted }.map(\.id))
        let known = Set(records.map(\.id))
        let stale = book.videos.filter { gone.contains($0.recordId) || !known.contains($0.recordId) }
        let settled = book.removals.filter { gone.contains($0.recordId) || !known.contains($0.recordId) }
        if !records.isEmpty, !stale.isEmpty || !settled.isEmpty {
            book.videos.removeAll { video in stale.contains(video) }
            book.removals.removeAll { removal in settled.contains(removal) }
            let cleaned = book
            book = (try? await perVideoStore.update { _ in cleaned }) ?? cleaned
        }
        perVideoBook = book
        perVideoNote = Self.removalNote(book)
        if book.removals.contains(where: { $0.lastError != nil }) { scheduleRemovalRetry() }
    }

    /// Makes this video's own voice, or returns the state already making or holding one. Only with the stored answer
    /// "match": the opt-in's click is the approval for this and every later video.
    @discardableResult
    func makeVideoVoice(project: Project, media: URL) -> VideoVoiceState {
        let key = project.media.source.contentKey
        let state = videoVoice(key)
        guard state.task == nil, enabled, videoVoiceMode == .match else { return state }
        if case .making = state.phase { return state }
        if let video = perVideoBook.video(key), let record = records.first(where: { $0.id == video.recordId && $0.status == .active }) {
            state.phase = .ready(record.id)
            state.line = "Takes in this video use \(record.voiceName), made from this video."
            return state
        }
        if case .ready = state.phase { state.phase = .idle }
        let owner = anchorVoice(language: project.transcript?.language)
        if perVideoBook.shortNoted.contains(key), state.phase != .anchor {
            // Said once already, in an earlier run: no note again.
            state.phase = .anchor; state.line = ""
            return state
        }
        guard state.phase != .anchor else { return state }
        guard let anchor = owner, anchor.projectConsent != nil else {
            state.phase = .anchor
            state.line = owner.map { "Takes use \($0.voiceName): only a voice made from your videos can be matched to a video." } ?? ""
            return state
        }
        state.phase = .making
        state.line = "Finding your clearest speech in this video… Nothing is sent yet."
        state.task = Task { [weak self, weak state] in
            guard let self, let state else { return }
            await self.runVideoVoice(state, project: project, media: media, anchor: anchor)
            state.task = nil
        }
        return state
    }

    /// Too little of the video's own verified speech: the anchor, said once.
    static func shortLine(milliseconds: Int, anchor: String) -> String {
        "This video has only \(VoiceRebuild.amount(milliseconds)) of your own clear speech, so takes use \(anchor). A matching voice needs \(VoiceRebuild.amount(VoicePerVideo.minimumVideoMs))."
    }

    private func runVideoVoice(_ state: VideoVoiceState, project: Project, media: URL, anchor: VoiceConsentRecord) async {
        let key = project.media.source.contentKey
        let owner = Self.rebuildName(anchor.voiceName)
        do {
            let check = try await referenceSpeakerCheck(language: anchor.language)
            guard check.available else { throw VoiceConsentError.speakerUnavailable }
            let found = try await VoiceRebuildFinder(store: store, check: check)
                .find(recordID: anchor.id, sources: [.init(project: project, media: media)], rules: .perVideo)
            try Task.checkCancellation()
            guard !busy else { throw VoiceLabError.invalidInput }
            let (_, enrollment) = try services()
            try await enrollment.setSpeakerCheck(check)
            let title = VoicePerVideo.title(mediaPath: project.media.source.absolutePath)
            let removesNoise = VoicePerVideo.removesBackgroundNoise(found.plan)
            let videoMs = VoicePerVideo.videoMs(found.plan)
            // The anchor's attestations are the consent this voice is made under; its consent clip is the first file.
            let plan = try await enrollment.prepareProjectPlan(recordID: UUID().uuidString.lowercased(), language: anchor.language,
                attestations: anchor.attestations, displayName: VoicePerVideo.displayName(owner: owner, title: title),
                samples: found.samples, enabled: enabled, removeBackgroundNoise: removesNoise)
            state.line = "Making a matching voice from \(VoiceRebuild.amount(videoMs)) of this video in your ElevenLabs account…"
            busy = true
            let record: VoiceConsentRecord
            do { record = try await enrollment.execute(plan, approved: true, enabled: enabled, appVersion: AppModel.version) }
            catch { busy = false; throw error }
            busy = false
            _ = try? await store.carryReferences(from: anchor.id, to: record.id)
            app.seedRateCalibration(from: anchor.id, to: record.id)
            let video = VoicePerVideoBook.Video(contentKey: key, recordId: record.id, anchorId: anchor.id,
                anchorReferenceSha256: anchor.referenceAudioSHA256, title: String(title.unicodeScalars.prefix(200)),
                createdAt: VoiceConsentRecord.timestamp(Date()), videoSeconds: Double(videoMs) / 1_000, removesBackgroundNoise: removesNoise)
            perVideoBook = try await perVideoStore.update { $0.adding(video) }
            await load(recover: false)
            await Log(logger: app.log).write(.info, category: "voice-lab",
                message: "per-video voice made video=\(key.prefix(8)) speech_ms=\(videoMs) files=\(found.plan.fileCount) noise_removal=\(removesNoise)")
            guard record.status == .active else {
                state.phase = .failed
                state.line = "ElevenLabs needs to verify this video's voice before it can be used. Finish verification on elevenlabs.io. Takes use \(owner)."
                return
            }
            state.phase = .ready(record.id)
            state.line = "Takes in this video use \(record.voiceName), made from this video."
            await removePreviousVideoVoices()
        } catch VoiceRebuildFinder.Failure.notEnough(let milliseconds, _) {
            perVideoBook = (try? await perVideoStore.update { book in
                var next = book
                if !next.shortNoted.contains(key) { next.shortNoted.append(key) }
                next.shortNoted = Array(next.shortNoted.suffix(256))
                return next
            }) ?? perVideoBook
            state.phase = .anchor
            state.line = Self.shortLine(milliseconds: milliseconds, anchor: owner)
        } catch is CancellationError {
            state.phase = .idle; state.line = ""
        } catch let error as VoiceConsentSaveError {
            unsavedRecord = error.record
            await load(recover: false)
            state.phase = .failed
            state.line = "ElevenLabs made this video's voice, but its consent record couldn't be saved. Retry saving it in Settings › Voices. Takes use \(owner)."
        } catch {
            await load(recover: false)
            state.phase = .failed
            state.line = "Couldn't make this video's voice. \(await rebuildError(error)) Takes use \(owner)."
        }
    }

    /// Removes every previous video's voice the book owes, through the existing deletion (creator binding, journal,
    /// tombstone). Never the anchor or the current video's voice, and not yet one whose project still holds unused
    /// paid takes. A failure stays owed: a one-line note in Settings › Voices and a retry in the background.
    func removePreviousVideoVoices(now: Date = Date()) async {
        let book = perVideoBook
        guard !book.removals.isEmpty, enabled else { return }
        let pending = pendingTakeVoices()
        let current = Set(book.videos.map(\.recordId))
        let anchors = Set(records.filter { $0.status == .active && !book.isVideoVoice($0.id) }.map(\.id))
        var drop: Set<String> = []
        var replace: [String: VoicePerVideoBook.Removal] = [:]
        for removal in book.removals {
            guard let record = records.first(where: { $0.id == removal.recordId }), record.status != .deleted else {
                drop.insert(removal.recordId); continue
            }
            let anchorID = anchors.contains(record.id) ? record.id : (book.videos.first?.anchorId ?? "")
            let keep = VoicePerVideo.keep(record.id, anchorID: anchorID, currentID: current.contains(record.id) ? record.id : "", pendingTakes: pending)
            if keep == .anchor || keep == .current { drop.insert(removal.recordId); continue }
            if keep == .pendingTakes {
                var waiting = removal; waiting.lastError = nil; waiting.nextAttemptAt = nil
                replace[removal.recordId] = waiting; continue
            }
            do {
                let (_, enrollment) = try services()
                try await enrollment.delete(recordID: record.id, approved: true, enabled: enabled)
                drop.insert(removal.recordId)
                await Log(logger: app.log).write(.info, category: "voice-lab", message: "per-video voice removed attempts=\(removal.attempts + 1)")
            } catch {
                var failed = removal
                failed.attempts += 1
                failed.lastError = String((await rebuildError(error)).unicodeScalars.prefix(300))
                let delay = min(3_600, 30 * pow(2, Double(min(failed.attempts - 1, 7))))
                failed.nextAttemptAt = VoiceConsentRecord.timestamp(now.addingTimeInterval(delay))
                replace[removal.recordId] = failed
                await Log(logger: app.log).write(.warn, category: "voice-lab", message: "per-video voice removal failed attempts=\(failed.attempts)")
            }
        }
        let dropped = drop, replaced = replace
        perVideoBook = (try? await perVideoStore.update { book in
            var next = book
            next.removals = book.removals.compactMap { removal in dropped.contains(removal.recordId) ? nil : replaced[removal.recordId] ?? removal }
            return next
        }) ?? perVideoBook
        await load(recover: false)
    }

    /// Settings › Voices' one line while a removal is owed.
    static func removalNote(_ book: VoicePerVideoBook) -> String? {
        let failed = book.removals.filter { $0.lastError != nil }
        if let first = failed.first {
            let more = failed.count > 1 ? " and \(failed.count - 1) more" : ""
            return "Couldn't remove the voice for \(first.title)\(more) yet. VoxClip retries in the background."
        }
        if let waiting = book.removals.first {
            return "The voice for \(waiting.title) is removed once its unused takes are used or discarded."
        }
        return nil
    }

    /// Retries owed removals when the earliest is due: in the background, never in tests' way (no sleep in them).
    func scheduleRemovalRetry() {
        removalRetry?.cancel()
        let due = perVideoBook.removals.compactMap { $0.nextAttemptAt.flatMap { ISO8601DateFormatter().date(from: $0) } }.min()
        guard let due else { return }
        let delay = max(1, due.timeIntervalSinceNow)
        removalRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.removePreviousVideoVoices()
        }
    }

    /// The voices of open projects whose Rewrite holds paid takes not used or discarded yet.
    static func openPendingTakeVoices() -> Set<String> {
        var voices: Set<String> = []
        for case let document as VoxClipDocument in NSDocumentController.shared.documents {
            guard let rewrite = document.editorModel?.openRewrite, rewrite.isOpen, rewrite.hasPaidTakes,
                  let voice = rewrite.generation?.selectedVoiceID else { continue }
            voices.insert(voice)
        }
        return voices
    }

    /// "Did matching help": a take's speaker cosine against the original speech beside it, measured on this Mac. The
    /// first take with a video's own voice is kept for that video; the anchor's takes in the video are pooled (mean).
    func recordTakeMatch(contentKey: String, title: String, recordID: String, score: Double) async {
        guard score.isFinite, (-1...1).contains(score) else { return }
        let isVideoVoice = perVideoBook.video(contentKey)?.recordId == recordID
        let isAnchor = !perVideoBook.isVideoVoice(recordID)
        let old = perVideoBook.measurements.first { $0.contentKey == contentKey }
        if isVideoVoice, old?.videoVoice != nil { return }
        guard isVideoVoice || isAnchor else { return }
        let anchorScore: Double? = isAnchor ? (old?.anchor.map { ($0 + score) / 2 } ?? score) : nil
        let measurement = VoicePerVideoBook.Measurement(contentKey: contentKey, title: String(title.unicodeScalars.prefix(200)),
            videoVoice: isVideoVoice ? score : nil, anchor: anchorScore, measuredAt: VoiceConsentRecord.timestamp(Date()))
        perVideoBook = (try? await perVideoStore.update { $0.measuring(measurement) }) ?? perVideoBook.measuring(measurement)
        await Log(logger: app.log).write(.info, category: "voice-lab",
            message: "per-video take match video=\(contentKey.prefix(8)) voice=\(isVideoVoice ? "video" : "anchor") score=\(String(format: "%.3f", score))")
        guard isVideoVoice else { return }
        // The first take with the video's own voice: the anchor's earlier takes give it something to compare with.
        if let stored = perVideoBook.measurements.first(where: { $0.contentKey == contentKey }) { await logMatchComparison(stored, log: Log(logger: app.log)) }
        measureAnchorBaseline()
    }

    /// Settings › Voices' diagnostic for one video: "DJI_0030: its own voice 0.71 · siim 0.54".
    static func matchLine(_ measurement: VoicePerVideoBook.Measurement, anchor: String) -> String {
        func score(_ value: Double) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) }
        let parts = [measurement.videoVoice.map { "its own voice \(score($0))" }, measurement.anchor.map { "\(anchor) \(score($0))" }].compactMap { $0 }
        return "\(measurement.title): " + parts.joined(separator: " · ")
    }
}
