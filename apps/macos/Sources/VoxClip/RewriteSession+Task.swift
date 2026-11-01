import AppKit
import VoxClipCore

extension ProviderChoice {
    /// The AI's short name in the bar and the panel (design.md §6.3 "Vocabulary"); menus keep the label.
    var shortName: String { cliName ?? (id == "apple-foundation" ? "Apple on-device" : label) }
    /// The R0 row's name: the label, with "Apple on-device" for Apple's model.
    var choiceName: String { id == "apple-foundation" ? "Apple on-device" : label }
}

// The Rewrite job's states on the Director task (design.md §6.3.6, impl-plan V12m): R0
// chooses the AI, R1 runs with its four steps, R1x shows an error with its fix. The passage
// panel still shows the task while it waits to send and once a proposal arrives (V13, V15).
extension RewriteSession {
    /// The catalogue entry of the session's connector.
    var provider: ProviderChoice? { connector.flatMap { connector in editor.app.providers.first { $0.id == connector.connector.id.rawValue } } }
    /// The AI's short name: "Claude Code", "Ollama", "Anthropic" (`RewriteConnector.name`).
    var aiName: String { connector?.name ?? "" }
    /// A loopback local server or Apple on-device: the words never leave the Mac.
    var runsOnThisMac: Bool {
        guard let connector, connector.group == "local" else { return false }
        if connector.connector.id.rawValue == "apple-foundation" { return true }
        return provider.map { editor.app.localServerHost($0) == nil } ?? true
    }
    /// The send asks first: an API key, or a CLI signed in with one (C8).
    var sendAsksFirst: Bool {
        guard let connector else { return false }
        if connector.group == "cli" && editor.app.cliSignIn(connector.connector.id) == nil { return false }
        if case .confirm = editor.app.llmSendKind(connector.connector.id) { return true }
        return false
    }

    /// The context line: the AI, its model and the send's state. A CLI's state waits for its sign-in to be detected.
    func refreshContext(answered seconds: Double? = nil) {
        guard let connector else { task.setContext(nil); return }
        let asks = sendAsksFirst
        let state: DirectorContext.State?
        if let seconds { state = .answered(seconds: seconds) }
        else if connector.group == "cli" && editor.app.cliSignIn(connector.connector.id) == nil { state = nil }
        else { state = asks ? .billedToKey : .noExtraCost }
        let readiness: DirectorContext.Readiness = readiness.map { $0 == .ready ? (asks ? .asksFirst : .ready) : .unavailable } ?? (asks ? .asksFirst : .ready)
        let model = provider?.models.first { $0.id == connector.model }?.name ?? connector.model
        task.setContext(DirectorContext(name: connector.name, model: model, state: state, readiness: readiness))
    }

    // MARK: R0

    /// Detects the AIs this Mac can use now and shows them (R0). Rows listed before stay, with their fresh status.
    func showChooser() async {
        guard isOpen, connector == nil else { return }
        let listed = Set(choices.map(\.id))
        let rows = await Self.detectChoices(app: editor.app, keeping: listed)
        guard isOpen, connector == nil, !Task.isCancelled else { return }
        choices = rows
        if task.choice == nil || !rows.contains(where: { $0.id == task.choice }), let first = rows.first(where: \.isReady) ?? rows.first { task.choose(first.id) }
        task.chose = { [weak self] _ in self?.showChoices() }
        showChoices()
    }
    /// R0 with `choices`, or "No AI is set up yet" when nothing was detected. `problem` (a key that could not be
    /// saved) shows under the list and is announced.
    func showChoices(problem: String? = nil) {
        let checkAgain = PanelAction(id: "checkAgain", title: "Check Again") { [weak self] in
            guard let self else { return }
            actionTask?.cancel()
            actionTask = Task { await self.showChooser() }
        }
        guard !choices.isEmpty else {
            task.show(.choosingAI, headline: PanelHeadline(text: "No AI is set up yet"),
                      cards: [.text("Rewrite needs an AI: an installed Claude Code or Codex, a local model, Apple on-device, or an API key.")],
                      footer: PanelFooter(link: PanelAction(id: "aiSettings", title: "AI Settings…") { openVoxClipSettings(pane: "ai") }, primary: checkAgain))
            return
        }
        let chosen = choices.first { $0.id == task.choice } ?? choices[0]
        let saveKey = choices.contains(where: \.needsKey) ? PanelAction(id: "saveKey", title: "Save Key") { [weak self] in
            guard let self else { return }
            actionTask?.cancel()
            actionTask = Task { await self.saveChooserKey() }
        } : nil
        task.show(.choosingAI, headline: PanelHeadline(text: "Who should rewrite \(task.words.name)?"),
                  cards: [.chooser(choices, saveKey: saveKey)] + (problem.map { [.text($0)] } ?? []),
                  footer: PanelFooter(note: "Change it any time from the menu above the transcript.", link: checkAgain,
                                      primary: PanelAction(id: "use", title: "Use \(chosen.shortName)") { [weak editor] in editor?.useRewriteConnector(chosen.id) }))
        if let problem { editor.announce(problem) }
    }
    private func saveChooserKey() async {
        guard let row = choices.first(where: \.needsKey) else { return }
        let key = task.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { task.requestFocus(); return }
        do {
            try await editor.app.saveProviderKey(key, for: row.id)
            task.keyDraft = ""
            task.choose(row.id)
            await showChooser()
        } catch is CancellationError {} catch {
            let problem = await keyProblem(error)
            guard isOpen, connector == nil else { return }
            showChoices(problem: problem)
        }
    }
    /// A key the Keychain refused, in the app's words for it: "Couldn't save the key. Keychain access failed (-25293). …".
    func keyProblem(_ error: any Error) async -> String {
        "Couldn't save the key. " + (await editor.app.safeError(error))
    }

    /// The AIs to offer (design.md R0), CLIs first, then this Mac, then API keys: an installed CLI, a local server that
    /// answers, Apple on-device when it is ready, and an API-key connector with a key. Anthropic is offered whenever
    /// anything is, so its key can be pasted in place. `keeping` rows stay listed with their status now.
    static func detectChoices(app: AppModel, keeping: Set<String> = []) async -> [ConnectorChoice] {
        let providers = app.providers.filter { $0.platforms.contains("macos") && $0.enabled != false }
        // Each detection waits on its own connector, so they run side by side.
        let detections = providers.map { provider in (provider.id, Task { await choice(for: provider, app: app, keeping: keeping.contains(provider.id)) }) }
        var found: [String: ConnectorChoice] = [:]
        for (id, detection) in detections { found[id] = await detection.value }
        let rank = ["cli": 0, "local": 1, "apiKey": 2]
        var rows = providers.sorted { rank[$0.group, default: 3] < rank[$1.group, default: 3] }.compactMap { found[$0.id] }
        if rows.isEmpty { return [] }
        if let anthropic = providers.first(where: { $0.id == "anthropic" }), !rows.contains(where: { $0.id == anthropic.id }) {
            rows.append(ConnectorChoice(id: anthropic.id, name: anthropic.choiceName, shortName: anthropic.shortName,
                                        status: "your API key · asks before each send", isReady: false, needsKey: true))
        }
        return rows
    }
    private static func choice(for provider: ProviderChoice, app: AppModel, keeping: Bool) async -> ConnectorChoice? {
        func row(_ status: String, ready: Bool = true) -> ConnectorChoice {
            ConnectorChoice(id: provider.id, name: provider.choiceName, shortName: provider.shortName, status: status, isReady: ready, needsKey: false)
        }
        if provider.group == "apiKey" {
            guard await app.providerKeyStore.hasKey(for: provider.id) else { return nil }
            return row("your API key · asks before each send")
        }
        guard let status = await app.connectorStatus(provider) else { return nil }
        let name = provider.shortName
        if provider.group == "cli" {
            let plan = provider.id == "codex" ? "ChatGPT plan" : "Claude plan"
            switch status {
            case .ready:
                guard let id = ConnectorID(rawValue: provider.id) else { return nil }
                return app.cliSignIn(id) == .apiKey ? row("Signed in · billed to the API key \(name) uses") : row("Signed in · \(plan) · no extra cost")
            case .cliSignedOut:
                return row(provider.id == "codex" ? "Not signed in. Run `codex login` in Terminal." : "Not signed in. Run `claude` in Terminal and sign in.", ready: false)
            case .cliTooOld: return row("Too old for VoxClip. Update it, then choose Check Again.", ready: false)
            case .cliMissing: return nil
            default: return keeping ? row(FindClipsPopover.statusText(status), ready: false) : nil
            }
        }
        if provider.id == "apple-foundation" { return status == .ready ? row("free · English") : nil }
        let place = app.localServerHost(provider).map { "on \($0)" } ?? "on this Mac"
        switch status {
        case .ready:
            let model = app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "")
            return row(model.isEmpty ? "\(place.prefix(1).uppercased() + place.dropFirst()) · free" : "\(model) \(place) · free")
        case .noModels: return row("No model loaded. Load one, then choose Check Again.", ready: false)
        case .notRunning: return keeping ? row("Not running. Start \(name), then choose Check Again.", ready: false) : nil
        default: return nil
        }
    }

    // MARK: R1

    /// R1's steps; `reached` is the first step not done yet: 1 while the send waits for the consent and the cost sheet,
    /// so nothing shows as sent; 2 once it went, waiting for the answer; 3 while the reply is checked.
    func runSteps(reached: Int) -> [ActivityStep] {
        let words = task.words
        let count = words.wordCount == 1 ? "1 word" : "\(words.wordCount) words"
        let span: Double = (source.last?.end ?? 0) - (source.first?.start ?? 0)
        func status(_ index: Int) -> ActivityStep.Status { index < reached ? .done : index == reached && index > 1 ? .running : .waiting }
        let read = "Read \(words.name)"
        let sent = runsOnThisMac ? "Running on this Mac" : "Sent to \(aiName)"
        return [
            ActivityStep(id: "read", title: read, detail: "\(count) · \(durationLabel(span))", status: status(0), spoken: "\(read), \(count)"),
            ActivityStep(id: "send", title: sent, detail: runsOnThisMac ? "Nothing leaves it." : "Text only. No audio or video.", status: status(1), spoken: sent),
            ActivityStep(id: "wait", title: "Waiting for \(aiName)…", detail: "Changes appear in the transcript when it answers.", status: status(2), spoken: "Waiting for \(aiName)"),
            ActivityStep(id: "check", title: "Check that each change fits", detail: "", status: status(3), spoken: "Check that each change fits"),
        ]
    }
    /// R1 starts as the user sends: the quote of what was asked, the steps with nothing sent yet, Stop, and the send line
    /// as the note. The consent and the cost sheet ask over it; `sendRun` announces it once they pass.
    func beginRun() {
        let asked: PanelCard = instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .asked(preset: "Fix mistakes", text: "fix slips and repeats, keep my words, change as little as possible.")
            : .asked(preset: nil, text: "“\(instruction)”")
        let stop = PanelAction(id: "stop", title: "Stop") { [weak editor] in editor?.closeRewrite() }
        task.show(.running, headline: PanelHeadline(text: "Rewriting \(task.words.name)…", runningSince: Date(), stop: stop),
                  cards: [asked, .activity(runSteps(reached: 1))], footer: PanelFooter(note: sendLine))
    }
    /// The consent passed and the words go: R1 waits for the AI. Announced now, not while a sheet still asks.
    func sendRun() {
        guard task.state == .running else { return }
        task.update(runSteps(reached: 2))
        editor.announce("Rewriting \(task.words.name)")
    }
    func advanceRun(to reached: Int) {
        guard task.state == .running else { return }
        task.update(runSteps(reached: reached))
    }
    /// The reply is in: the proposal's changes, announced. The passage panel shows them until V15.
    func finishRun(seconds: Double) {
        // A reply the passage panel cannot review (over the word-diff limit) shows its problem there, unannounced.
        guard let hunks = review?.diff.hunks else { showReady(); return }
        let items = hunks.enumerated().map { index, hunk in
            ProposalItem(ordinal: index + 1, kind: hunk.kind == .cut ? .cut : hunk.kind == .textOnly ? .fix : .voice,
                         sourceWordIDs: hunk.sourceWordIds, newWords: hunk.newTokens)
        }
        let changes = ChangeSet(items: items)
        refreshContext(answered: seconds)
        task.show(.proposal(changes), headline: PanelHeadline(text: items.isEmpty ? "No changes needed" : items.count == 1 ? "1 change" : "\(items.count) changes"))
        editor.announce(items.isEmpty ? "No changes needed." : changes.announcement)
    }
    /// Back to the passage panel with nothing sent: a declined sheet, or a send that went stale.
    func showReady() {
        task.show(.ready, headline: PanelHeadline(text: task.words.title))
    }

    // MARK: R1x

    /// The error a failed send shows, nil for a cancelled one, which is silent.
    func panelError(_ error: any Error) async -> PanelError? {
        if let plan = error as? ScopeRewritePlanError, let size = PanelError(plan) { return size }
        guard let error = error as? LLMError else { return .message(await editor.app.safeError(error, context: "ai:\(aiName)")) }
        switch error {
        case .cancelled: return nil
        case .cliSignedOut: return .signedOut(cli: aiName, command: provider?.id == "codex" ? "codex login" : "claude")
        case .missingKey: return .noKey(provider: provider?.id ?? "", name: aiName)
        case .notRunning: return .notRunning(server: aiName)
        case .refused: return .refused
        default: return .message(await editor.app.log.redact(Self.proposalError(error, provider: connector?.name ?? aiName, model: connector?.model ?? "")))
        }
    }
    /// Shows a failed send's error (R1x), announced.
    func fail(_ error: any Error) async {
        guard let shown = await panelError(error), isOpen else { return }
        fail(shown)
    }
    /// `problem` adds a line under the fix and is announced instead of the headline: a key that could not be saved, or
    /// Try Again while another AI request holds the project.
    func fail(_ error: PanelError, problem: String? = nil) {
        let words = task.words
        let tryAgain = PanelAction(id: "tryAgain", title: sendAsksFirst ? "Try Again…" : "Try Again") { [weak self] in
            guard let self else { return }
            actionTask?.cancel()
            actionTask = Task { await self.tryAgain() }
        }
        var headline = PanelHeadline(text: "Couldn't rewrite \(words.name)")
        var cards: [PanelCard] = []
        var footer = PanelFooter(note: sendLine, primary: tryAgain)
        switch error {
        case .message(let text): cards = [.text(text)]
        case .signedOut(let cli, let command):
            cards = [.text("\(cli) isn't signed in. Run `\(command)` in Terminal and sign in, then choose Try Again.")]
        case .noKey(let provider, let name):
            cards = [.keyField(provider: provider, label: "\(name) API key")]
            footer.primary = PanelAction(id: "saveKeyAndTryAgain", title: "Save Key and Try Again") { [weak self] in
                guard let self else { return }
                actionTask?.cancel()
                actionTask = Task { await self.saveKeyAndTryAgain(provider) }
            }
        case .notRunning(let server): cards = [.text("\(server) isn't running. Start it, then choose Try Again.")]
        case .refused:
            cards = [.text("The model declined to rewrite this recording.")]
            footer = PanelFooter(primary: PanelAction(id: "askElse", title: "Ask for Something Else") { [weak self] in self?.askForSomethingElse() })
        case .tooManyEntries, .tooMuchText:
            let findClips = task.scope == .fullTake ? PanelAction(id: "findClips", title: "Find Clips") { [weak editor] in
                editor?.closeRewrite(returnFocus: false)
                editor?.requestFindClips(from: .overflow)
            } : nil
            (headline, cards, footer) = Self.tooLarge(error, words: words, findClips: findClips)
        }
        if let problem { cards.append(.text(problem)) }
        task.show(.error(error), headline: headline, cards: cards, footer: footer)
        if case .noKey = error { task.requestFocus() }
        editor.announce(problem ?? headline.text + ".")
    }
    /// Refused: back to the passage panel with its field focused (design.md R1x).
    func askForSomethingElse() {
        task.handOverKeyboard()
        showReady()
    }
    /// R1x for a scope over Rewrite's limits (voice-lab.md §8.1). Full take offers `findClips`;
    /// a clip has no primary, and Close closes.
    static func tooLarge(_ error: PanelError, words: DirectorScope, findClips: PanelAction?) -> (PanelHeadline, [PanelCard], PanelFooter) {
        let body: String
        if case .tooManyEntries(let count) = error {
            body = "Rewrite works on up to 3,000 words at a time. This \(words.noun) has \(count.formatted(.number.locale(Locale(identifier: "en_US")))). Choose a clip or select a passage."
        } else {
            body = "This \(words.noun) has more text than Rewrite can send at once. Choose a clip or select a passage."
        }
        return (PanelHeadline(text: words.tooLong), [.text(body)], PanelFooter(primary: findClips))
    }
    /// Sends again with a fresh quote. While another AI request holds the project (Find Clips, or a Rewrite in another
    /// window) it says so and keeps Try Again.
    func tryAgain() async {
        guard isOpen else { return }
        guard connector != nil else { await showChooser(); return }
        await prepareFreshQuote()
        guard isOpen, !Task.isCancelled else { return }
        if editor.llmRuns.isBusy, case .error(let error) = task.state {
            fail(error, problem: editor.finding ? "Find Clips is still running. Choose Try Again when it finishes."
                                                : "Another AI request on this project is still running. Choose Try Again when it finishes.")
            return
        }
        guard let quote else { showReady(); return }
        markEstimateShown(quote.id)
        await propose(quote)
    }
    private func saveKeyAndTryAgain(_ provider: String) async {
        let key = task.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { task.requestFocus(); return }
        do {
            try await editor.app.saveProviderKey(key, for: provider)
            task.keyDraft = ""
        } catch is CancellationError { return } catch {
            let problem = await keyProblem(error)
            guard isOpen else { return }
            fail(.noKey(provider: provider, name: aiName), problem: problem)
            return
        }
        await tryAgain()
    }
}
