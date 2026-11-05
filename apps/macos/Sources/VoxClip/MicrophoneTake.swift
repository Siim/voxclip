import AppKit
import AVFoundation
import CoreAudio
import Observation
import SwiftUI
import VoxClipCore
import VoxClipMedia

/// The microphone a phrase's own take records from: `VoiceMicrophoneRecorder`, or a stand-in in tests and the smoke.
@MainActor protocol PhraseMicrophone: AnyObject {
    var recording: Bool { get }
    var seconds: Double { get }
    var level: Double { get }
    var samples: [Float] { get }
    var failure: MicrophoneError? { get }
    func start(maximumSeconds: Int) async throws
    func stop()
    func discard()
}
extension VoiceMicrophoneRecorder: PhraseMicrophone {}

/// Whether the Mac can record: a microphone exists, and VoxClip may use it.
enum MicrophoneAccess: Equatable { case allowed, notDetermined, denied, noMicrophone }

/// What plays before recording starts so the user matches the clip: the clip's audio before the phrase through
/// headphones, or a short count-in through speakers, so the clip doesn't bleed into the take.
enum PhraseTakeCue: Equatable {
    case leadIn(samples: [Float], sampleRate: Int)
    case countIn
}
@MainActor protocol PhraseCuePlayer: AnyObject {
    func play(_ cue: PhraseTakeCue) async
    func stop()
}

/// "● Say it myself" for one phrase at a time (design.md §6.3): record, stop at the gap plus 1.5 s or on [Stop], then
/// check the take on this Mac and list it beside the phrase's other takes. Nothing is uploaded and nothing is paid.
@MainActor @Observable final class PhraseMicrophoneTake {
    enum State: Equatable { case idle, cueing, recording, checking }
    static let extraSeconds = 1.5
    private(set) var state: State = .idle
    private(set) var phrase: Int?
    /// The level history the waveform draws while recording, newest last.
    private(set) var levels: [Double] = []
    private(set) var problem = ""
    /// The take the last recording made, for Record again.
    private(set) var lastTake: [Int: UUID] = [:]
    @ObservationIgnored var microphone: any PhraseMicrophone = VoiceMicrophoneRecorder()
    @ObservationIgnored var cue: any PhraseCuePlayer = PhraseCueSpeaker()
    @ObservationIgnored var transcriber: (any MicrophoneTakeTranscribing)?
    @ObservationIgnored var access: @MainActor () -> MicrophoneAccess = PhraseMicrophoneTake.systemAccess
    @ObservationIgnored var headphones: @MainActor () -> Bool = PhraseMicrophoneTake.systemHeadphones
    /// The meter's pace while recording; tests drive `tick()` themselves.
    @ObservationIgnored var meters = true
    @ObservationIgnored private var limit = 0.0
    @ObservationIgnored private var turn = UUID()
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private weak var plan: ClipTakePlan?

    var recording: Bool { state == .recording }
    var seconds: Double { microphone.seconds }

    /// The seconds the take may run before it stops by itself: the phrase's gap plus 1.5 s.
    static func limit(for phrase: ClipTakePlan.Phrase) -> Double { phrase.originalLength + extraSeconds }

    func record(phrase index: Int, plan: ClipTakePlan) async {
        guard state == .idle, plan.stillCurrent, plan.phrases.indices.contains(index), plan.inputs.indices.contains(index) else { return }
        switch access() {
        case .noMicrophone: problem = PhraseMicrophoneCopy.noMicrophone; return
        case .denied: problem = PhraseMicrophoneCopy.denied; return
        case .allowed, .notDetermined: break
        }
        guard transcriber != nil else { problem = PhraseMicrophoneCopy.noTranscriber; return }
        let id = UUID(); turn = id
        self.plan = plan; phrase = index; problem = ""; levels = []
        limit = Self.limit(for: plan.phrases[index])
        plan.stopAudition()
        state = .cueing
        await cue.play(headphones() ? Self.leadIn(plan.inputs[index]) : .countIn)
        guard turn == id, state == .cueing else { return }
        state = .recording
        do {
            try await microphone.start(maximumSeconds: limit <= 30 ? 30 : 90)
        } catch {
            guard turn == id else { return }
            state = .idle
            problem = (error as? MicrophoneError) == .permission ? PhraseMicrophoneCopy.denied : PhraseMicrophoneCopy.copy(error)
            return
        }
        guard turn == id, state == .recording else { microphone.discard(); return }
        if meters {
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, !Task.isCancelled else { return }
                    if await self.tick() { return }
                }
            }
        }
    }

    /// One meter reading: draws the level, and stops at the limit or when the microphone stopped. true once it stopped.
    @discardableResult func tick() async -> Bool {
        guard state == .recording else { return true }
        levels.append(microphone.level)
        if levels.count > 120 { levels.removeFirst(levels.count - 120) }
        if !microphone.recording || microphone.seconds >= limit {
            await stop()
            return true
        }
        return false
    }

    /// [Stop]: the recording ends and its checks run on this Mac; the take is listed once they finish.
    func stop() async {
        guard state == .recording, let plan, let index = phrase else { return }
        meter?.cancel(); meter = nil
        if microphone.recording { microphone.stop() }
        let samples = microphone.samples, failure = microphone.failure
        microphone.discard()
        guard failure == nil, !samples.isEmpty else {
            state = .idle; problem = PhraseMicrophoneCopy.copy(failure ?? MicrophoneError.deviceLost)
            return
        }
        guard let transcriber, let storage = plan.microphoneStorage, plan.inputs.indices.contains(index) else {
            state = .idle; problem = PhraseMicrophoneCopy.noTranscriber; return
        }
        state = .checking
        let id = turn, input = plan.inputs[index]
        do {
            let take = try await MicrophoneTakeMaker.make(samples: samples, input: input, transcriber: transcriber, storage: storage)
            guard turn == id else { await take.scratch.invalidate(); return }
            if plan.addMicrophoneTake(take, phrase: index, replacing: lastTake[index]) { lastTake[index] = take.row.id }
            state = .idle
        } catch {
            guard turn == id else { return }
            state = .idle; problem = PhraseMicrophoneCopy.copy(error)
        }
    }

    /// Leaving Say it myself, or the plan changing: a recording in progress is dropped, its takes are kept.
    func cancel() {
        turn = UUID(); meter?.cancel(); meter = nil
        cue.stop()
        if state == .recording || state == .cueing { microphone.discard() }
        state = .idle; levels = []
    }

    /// Up to 2 s of the clip before the phrase, as the input holds it.
    static func leadIn(_ input: VoiceLabTakeInput) -> PhraseTakeCue {
        let rate = input.sourceSampleRate, start = Int(input.window.startSample)
        for seconds in [2.0, 1.0, 0.5] {
            let count = Int(seconds * Double(rate))
            if start - count >= 0, let run = input.source.samples((start - count)..<start) { return .leadIn(samples: Array(run), sampleRate: rate) }
        }
        return .countIn
    }

    static func systemAccess() -> MicrophoneAccess {
        guard AVCaptureDevice.default(for: .audio) != nil else { return .noMicrophone }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Headphones are the default output's headphone jack, or a Bluetooth output (AirPods and the like).
    static func systemHeadphones() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
           transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        var source = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDataSource; address.mScope = kAudioDevicePropertyScopeOutput
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr else { return false }
        return source == 0x6864_706E // 'hdpn'
    }
}

enum PhraseMicrophoneCopy {
    static let noMicrophone = "No microphone is connected. Connect one to say it yourself."
    static let denied = "Microphone access is off for VoxClip. Allow it in System Settings → Privacy & Security → Microphone, then record."
    static let noTranscriber = "On-device transcription isn't ready. Choose a transcription engine in Settings → Transcription."
    static func copy(_ error: any Error) -> String {
        switch error {
        case MicrophoneTakeError.noSpeech: "No words were heard in this take. Record again, closer to the microphone."
        case MicrophoneTakeError.transcriptionUnavailable:
            "On-device transcription isn't ready for this language. Install Apple's speech model in Settings → Transcription."
        case MicrophoneError.permission: denied
        case let error as MicrophoneError: error.errorDescription ?? "The microphone stopped. Record again."
        default: "This take couldn't be checked: \(RewriteSession.refusal(error)) Record again."
        }
    }
    static func seconds(_ value: Double) -> String { String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), value) }
}

/// Plays a cue through the default output and waits for it to finish.
@MainActor final class PhraseCueSpeaker: PhraseCuePlayer {
    private var engine: AVAudioEngine?
    func play(_ cue: PhraseTakeCue) async {
        let rate: Int, samples: [Float]
        switch cue {
        case .leadIn(let run, let sampleRate): rate = sampleRate; samples = run
        case .countIn: rate = 48_000; samples = Self.countIn(rate: rate)
        }
        guard rate > 0, !samples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices { channel[index] = samples[index] }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        self.engine = engine
        player.play()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in continuation.resume() }
        }
        if self.engine === engine { stop() }
    }
    func stop() { engine?.stop(); engine = nil }
    /// Three short beeps half a second apart, the last a little higher: recording starts after it.
    static func countIn(rate: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: rate * 3 / 2)
        let beep = rate * 8 / 100
        for (offset, frequency) in [(0, 880.0), (rate / 2, 880.0), (rate, 1_320.0)] {
            for index in 0..<beep {
                let time: Double = Double(index) / Double(rate)
                let fade: Double = min(1, Double(min(index, beep - index)) / (Double(rate) * 0.005))
                samples[offset + index] = Float(0.2 * fade * sin(2 * Double.pi * frequency * time))
            }
        }
        return samples
    }
}

/// The Say it myself segment of a phrase card.
@MainActor struct PhraseMicrophoneRow: View {
    @Bindable var session: RewriteSession
    @Bindable var microphone: PhraseMicrophoneTake
    @Bindable var plan: ClipTakePlan
    let phrase: ClipTakePlan.Phrase
    var body: some View {
        let active = microphone.phrase == phrase.id
        let access = microphone.access()
        VStack(alignment: .leading, spacing: VCTokens.spacingRowGap) {
            if active, microphone.state == .recording || microphone.state == .cueing {
                recordingRow
            } else if active, microphone.state == .checking {
                ProgressView("Checking your take on this Mac…").controlSize(.small)
            } else if access == .noMicrophone {
                Text(PhraseMicrophoneCopy.noMicrophone).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.secondary"))
            } else if access == .denied {
                Text(PhraseMicrophoneCopy.denied).font(VCType.small.font()).foregroundStyle(DesignValues.color("status.warning"))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Microphone Settings") { NSWorkspace.shared.open(MicrophoneError.privacySettingsURL) }
                    .buttonStyle(.plain).modifier(PanelButtonEvidence(id: "microphone.settings.\(phrase.id)", title: "Open Microphone Settings"))
            } else if plan.inputs.indices.contains(phrase.id), !session.takesBusy, microphone.state == .idle {
                let again = microphone.lastTake[phrase.id].flatMap { id in phrase.takes.first { $0.id == id } } != nil
                Button(again ? "Record again" : "● Record") {
                    session.focusedTakePhrase = phrase.id
                    Task { await microphone.record(phrase: phrase.id, plan: plan) }
                }
                .buttonStyle(.plain).help("Say the phrase in your own voice. It stops by itself at \(PhraseMicrophoneCopy.seconds(PhraseMicrophoneTake.limit(for: phrase))).")
                .modifier(PanelButtonEvidence(id: "microphone.record.\(phrase.id)", title: again ? "Record again" : "● Record"))
                Text("Say: “\(phrase.text)”").font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
            }
            if active, !microphone.problem.isEmpty {
                Text(microphone.problem).font(VCType.small.font()).foregroundStyle(DesignValues.color("status.warning"))
                    .fixedSize(horizontal: false, vertical: true)
                    .columnLayoutEvidence("voice.phrase.\(phrase.id).microphone.problem.line", text: microphone.problem)
            }
            Text(PhraseOwnWordsCopy.microphoneFooter).font(VCType.small.font()).foregroundStyle(DesignValues.color("text.tertiary"))
                .columnLayoutEvidence("voice.phrase.\(phrase.id).microphone.next.line", text: PhraseOwnWordsCopy.microphoneFooter)
        }
    }

    private var recordingRow: some View {
        HStack(spacing: 8) {
            Circle().fill(DesignValues.color("status.error")).frame(width: 8, height: 8).accessibilityHidden(true)
            Canvas { context, size in
                let levels = microphone.levels.suffix(60)
                let step = size.width / 60
                for (offset, level) in levels.enumerated() {
                    let height = max(1, CGFloat(level) * size.height)
                    let x = CGFloat(offset) * step
                    context.fill(Path(CGRect(x: x, y: (size.height - height) / 2, width: max(1, step - 1), height: height)),
                        with: .color(DesignValues.color("text.secondary")))
                }
            }.frame(width: 120, height: 18).accessibilityHidden(true)
            Text(microphone.state == .cueing ? "Get ready…" :
                "\(PhraseMicrophoneCopy.seconds(microphone.seconds)) / gap \(PhraseMicrophoneCopy.seconds(phrase.originalLength))")
                .font(VCType.small.font()).monospacedDigit()
            // Stop shows once recording starts; during the count-in or lead-in it could not act yet.
            if microphone.state == .recording {
                Button("Stop") { Task { await microphone.stop() } }
                    .buttonStyle(.plain).modifier(PanelButtonEvidence(id: "microphone.stop.\(phrase.id)", title: "Stop"))
            }
        }
        .accessibilityElement(children: .combine).accessibilityLabel("Recording phrase \(phrase.id + 1)")
    }

    /// `fits`: its length fits with the source video or a cut; `carried`: some video duration can carry it.
    static func line(_ take: ClipTakePlan.Take, words: String, slot: Double, fits: Bool, carried: Bool) -> String {
        let length = take.length.map(PhraseMicrophoneCopy.seconds) ?? "no length"
        guard take.row.selectable else {
            return "Your take · “\(words)” · \(TakeFailurePresentation.reason(for: take.row) ?? "didn't pass the checks.") Record again."
        }
        let difference = (take.length ?? slot) - slot
        if !carried {
            return "Your take · “\(words)” · runs \(length) for a \(PhraseMicrophoneCopy.seconds(slot)) gap, too \(difference < 0 ? "short" : "long") to fit. Record again."
        }
        let join = take.row.hasJoinAdvisory ? " · join may sound slightly louder" : ""
        if take.fits { return "Your take · “\(words)” · fits \(length) ✓\(join) · free" }
        let verdict = fits ? "\(PhraseMicrophoneCopy.seconds(abs(difference))) \(difference < 0 ? "shorter" : "longer"), the video is cut to it"
            : "\(PhraseMicrophoneCopy.seconds(abs(difference))) \(difference < 0 ? "shorter" : "longer"), the video is matched to it"
        return "Your take · “\(words)” · \(verdict)\(join) · free"
    }
}

/// One of the user's own takes in the phrase's take list, with Play, Use your take (or Use anyway) and Record again.
@MainActor struct OwnTakeRow: View {
    @Bindable var session: RewriteSession
    @Bindable var microphone: PhraseMicrophoneTake
    @Bindable var plan: ClipTakePlan
    let phrase: ClipTakePlan.Phrase
    let take: ClipTakePlan.Take
    /// "Your take · “recognized words” · fits 1.4 s ✓ · free", with [Use your take] and [Record again], or the misfit's
    /// measured length with Record again and, where a video duration can carry it, Use anyway.
    var body: some View {
        let words = plan.microphoneTake(take.id)?.text ?? ""
        let used = phrase.selectedID == take.id
        let line = PhraseMicrophoneRow.line(take, words: words, slot: phrase.originalLength, fits: plan.lengthFits(take: take),
            carried: plan.durationAvailable(take: take))
        VStack(alignment: .leading, spacing: VCTokens.spacingLabelGap) {

            Text(line).font(VCType.callout.font())
                .foregroundStyle(DesignValues.color(take.row.selectable && plan.durationAvailable(take: take) ? "text.primary" : "status.warning"))
                .fixedSize(horizontal: false, vertical: true)
                .columnLayoutEvidence("voice.phrase.\(phrase.id).microphone.take.\(take.number).line", text: line)
            if !session.takesBusy, microphone.state == .idle {
                HStack(spacing: 8) {
                    let playing = plan.audition.isPlaying && plan.audition.takeId == take.id
                    Button(playing ? "Pause" : "Play") { Task { await session.playTake(take.id, phrase: phrase.id) } }
                        .buttonStyle(.plain).modifier(PanelButtonEvidence(id: "microphone.play.\(phrase.id).\(take.number)", title: playing ? "Pause" : "Play"))
                    if !used, take.row.selectable, plan.durationAvailable(take: take) {
                        // Use anyway only where the choice needs the user: the take changes the video's duration (ADR-R39).
                        let title = plan.lengthFits(take: take) ? "Use your take" : "Use anyway"
                        Button(title) {
                            session.focusedTakePhrase = phrase.id
                            session.mutateLipsync(phrase: phrase.id) { _ = plan.select(take: take.id, phrase: phrase.id) }
                        }
                        .buttonStyle(.plain).modifier(PanelButtonEvidence(id: "microphone.use.\(phrase.id).\(take.number)", title: title))
                    }
                    if [.allowed, .notDetermined].contains(microphone.access()), plan.inputs.indices.contains(phrase.id) {
                        Button("Record again") {
                            session.chooseWording(.microphone, phrase: phrase.id)
                            Task { await microphone.record(phrase: phrase.id, plan: plan) }
                        }
                        .buttonStyle(.plain).modifier(PanelButtonEvidence(id: "microphone.again.\(phrase.id).\(take.number)", title: "Record again"))
                    }
                }.font(VCType.callout.font())
            }
        }
    }
}
