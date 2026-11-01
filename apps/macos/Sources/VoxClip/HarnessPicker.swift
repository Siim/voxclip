import AppKit
import VoxClipCore

// The harness picker (design.md §3.2, doc/design.md §6.3.2, impl-plan V3b): the clip bar's AI
// menu. The button shows a status dot and the chosen AI's short name; its menu lists every AI by
// who pays, with the billing on the trailing side, then Model and AI Settings…. Choosing an entry
// writes `llm.connector`, the value Settings → AI shows. Detection runs only when the menu opens
// (ai.md §7.1 rule 5), and what it finds is this session's `HarnessStatus`, which the status bar
// reads (V11a).

/// The chosen AI as this app session knows it (impl-plan V3b, item 14). Readiness and billing come
/// only from detection in this session, when the picker opened or a send ran (`AppModel.connectorStatus`
/// records both), never from a stored value: a stale "no extra cost" is worse than none.
struct HarnessStatus: Equatable {
    enum Readiness: Equatable {
        /// Not detected in this session yet.
        case unknown
        case ready
        /// Asks before each send: an API key, or a CLI signed in with one (C8).
        case asksFirst
        /// Cannot send now; the reason in words, as VoiceOver reads it: "not signed in", "not running", "no key".
        case unavailable(String)
    }
    /// `llm.connector`; nil with no AI chosen.
    let connectorID: String?
    /// The short name the bar shows ("Claude Code", "Apple on-device"), or "Choose AI".
    let name: String
    /// The menu's name ("Claude Code (installed CLI)").
    let label: String
    /// The chosen model's name ("Sonnet (latest)"); empty when the AI has none set.
    let model: String
    let readiness: Readiness
    /// The billing on the menu's trailing side ("Sonnet (latest) · no extra cost", "asks before each send"), only once
    /// detection ran in this session.
    let billing: String?

    static let notChosen = HarnessStatus(connectorID: nil, name: "Choose AI", label: "Choose AI", model: "", readiness: .unknown, billing: nil)

    /// The dot's colour (design.md §3.1): ready, asks before each send, unavailable; nil with no AI chosen. Before
    /// detection the dot is a ring in the unavailable colour (`detected` false).
    var dotToken: String? {
        guard connectorID != nil else { return nil }
        switch readiness {
        case .ready: return "status.success"
        case .asksFirst: return "status.warning"
        case .unknown, .unavailable: return "text.tertiary"
        }
    }
    var detected: Bool { readiness != .unknown }
    /// The state in words for VoiceOver (design.md §10); nil before detection.
    var stateWords: String? {
        switch readiness {
        case .unknown: nil
        case .ready: "ready"
        case .asksFirst: "asks before each send"
        case .unavailable(let reason): reason
        }
    }
    /// "AI: Claude Code (installed CLI), Opus 5.5, ready" (design.md §10); "Choose AI" with none chosen.
    var accessibilityLabel: String {
        guard connectorID != nil else { return name }
        return "AI: " + ([label, model.isEmpty ? nil : model, stateWords].compactMap { $0 }.joined(separator: ", "))
    }
}

extension AppModel {
    /// The AIs the picker lists, grouped as the menu shows them: installed CLIs, this Mac, API keys.
    var harnessProviders: [ProviderChoice] {
        let rank = ["cli": 0, "local": 1, "apiKey": 2]
        return providers.filter { $0.platforms.contains("macos") && $0.enabled != false && rank[$0.group] != nil }
            .enumerated().sorted { (rank[$0.element.group]!, $0.offset) < (rank[$1.element.group]!, $1.offset) }.map(\.element)
    }
    /// The chosen AI now (impl-plan V3b): what the clip bar's picker and the status bar show.
    var harnessStatus: HarnessStatus {
        let id = string("llm.connector")
        guard let provider = providers.first(where: { $0.id == id }) else { return .notChosen }
        let readiness = harnessReadiness(provider)
        return HarnessStatus(connectorID: id, name: provider.shortName, label: provider.choiceName, model: harnessModelName(provider),
                             readiness: readiness, billing: readiness == .unknown ? nil : harnessBilling(provider, readiness: readiness))
    }
    /// What this session's detection found for `provider`. A CLI counts as detected only with a known sign-in at its
    /// current path.
    func harnessReadiness(_ provider: ProviderChoice) -> HarnessStatus.Readiness {
        guard let status = detectedConnectorStatus[provider.id] else { return .unknown }
        switch status {
        case .ready:
            guard let id = ConnectorID(rawValue: provider.id) else { return .ready }
            if provider.group == "cli" && cliSignIn(id) == nil { return .unknown }
            if case .confirm = llmSendKind(id) { return .asksFirst }
            return .ready
        case .needsKey: return .unavailable("no key")
        case .notRunning(let url): return .unavailable(UserMessages.localServerUnavailable(name: provider.shortName, url: url))
        case .noModels: return .unavailable("no model loaded")
        case .cliMissing: return .unavailable("not installed")
        case .cliSignedOut: return .unavailable("not signed in")
        case .cliTooOld: return .unavailable("needs an update")
        case .unavailable: return .unavailable("unavailable")
        }
    }
    /// The chosen model's display name for `provider`, from the catalogue, else its id.
    func harnessModelName(_ provider: ProviderChoice) -> String {
        let id = string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "")
        return provider.models.first { $0.id == id }?.name ?? id
    }
    /// The menu's trailing billing (doc/design.md §6.3.2): "{model} · no extra cost", "{model} · billed to its API key",
    /// "Not signed in", "{model} · free", "on {host} · free", "Not running", "free · English", "asks before each send",
    /// "Add Key…".
    func harnessBilling(_ provider: ProviderChoice, readiness: HarnessStatus.Readiness) -> String {
        let model = harnessModelName(provider)
        switch readiness {
        case .unknown: return ""
        case .unavailable(let reason):
            if provider.group == "apiKey" && detectedConnectorStatus[provider.id] == .needsKey { return "Add Key…" }
            return reason.prefix(1).uppercased() + reason.dropFirst()
        case .asksFirst: return provider.group == "cli" ? "\(model) · billed to its API key" : "asks before each send"
        case .ready:
            if provider.group == "cli" { return "\(model) · no extra cost" }
            if provider.id == "apple-foundation" { return "free · English" }
            if let host = localServerHost(provider) { return "on \(host) · free" }
            return model.isEmpty ? "free" : "\(model) · free"
        }
    }
}

/// The picker (notes.md `.harn`): a 6 pt status dot, the short name in 12 pt text.secondary and an up-down chevron,
/// 18 high with radius 4 inside a 24 pt target; the selected-row fill under the pointer. With no AI chosen it reads
/// "Choose AI". `compact` keeps the dot and the first word only, so it never truncates below them (design.md §3.1).
/// Its menu opens on a click, Space or VoiceOver's press, and detection starts as it opens.
@MainActor final class HarnessPicker: NSButton, NSMenuDelegate {
    let app: AppModel
    static let height: CGFloat = 24, chipHeight: CGFloat = 18
    private static let leading: CGFloat = 6, trailing: CGFloat = 4, gap: CGFloat = 5, dot: CGFloat = 6, chevron: CGFloat = 9
    /// The header line (doc/design.md §6.3.2): the AI is shared with what Hook and Find Clips send.
    static let header = "Used for Rewrite, Hook and Find Clips."
    var compact = false { didSet { if compact != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private(set) var status = HarnessStatus.notChosen
    /// The detection the open menu started; nil when none runs.
    private(set) var detection: Task<Void, Never>?
    /// Providers being detected now; their rows read "Checking…".
    private(set) var checking: Set<String> = []
    /// The menu while it is open, which detection updates in place.
    private(set) weak var openMenu: NSMenu?

    init(app: AppModel) {
        self.app = app
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: Self.height))
        identifier = NSUserInterfaceItemIdentifier("voxclip.clipBar.harness")
        isBordered = false
        setButtonType(.momentaryPushIn)
        title = ""
        target = self
        action = #selector(showMenu)
        setAccessibilityRole(.menuButton)
        render()
    }
    required init?(coder: NSCoder) { nil }

    /// Follows the chosen AI and this session's detection; the clip bar's observation calls it.
    func render() {
        let next = app.harnessStatus
        let renamed = next.name != status.name
        status = next
        setAccessibilityLabel(next.accessibilityLabel)
        toolTip = next.connectorID == nil ? "Choose the AI for Rewrite, Hook and Find Clips" : next.accessibilityLabel
        if renamed { invalidateIntrinsicContentSize() }
        needsDisplay = true
    }

    private var nameAttributes: [NSAttributedString.Key: Any] { [.font: VCType.callout.nsFont(), .foregroundColor: DesignValues.nsColor("text.secondary")] }
    /// The name drawn: the short name, or its first word when compact.
    var shownName: String { compact ? String(status.name.split(separator: " ").first ?? Substring(status.name)) : status.name }
    private func width(for name: String) -> CGFloat {
        let text = ceil((name as NSString).size(withAttributes: nameAttributes).width)
        let dot = status.dotToken == nil ? 0 : Self.dot + Self.gap
        return Self.leading + dot + text + Self.gap + Self.chevron + Self.trailing
    }
    /// The full width, and the width with the dot and the first word only.
    var fullWidth: CGFloat { width(for: status.name) }
    var compactWidth: CGFloat { width(for: String(status.name.split(separator: " ").first ?? Substring(status.name))) }
    override var intrinsicContentSize: NSSize { NSSize(width: width(for: shownName), height: Self.height) }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let chip = NSRect(x: 0, y: ((bounds.height - Self.chipHeight) / 2).rounded(), width: bounds.width, height: Self.chipHeight)
        if hovering || isHighlighted || openMenu != nil {
            DesignValues.nsColor("bg.selectedRow").setFill()
            NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        }
        var x = Self.leading
        if let token = status.dotToken {
            let dot = NSRect(x: x, y: chip.midY - Self.dot / 2, width: Self.dot, height: Self.dot)
            if status.detected {
                DesignValues.nsColor(token).setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                // Not detected yet: a ring, so the dot claims no state (impl-plan item 14).
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                DesignValues.nsColor(token).setStroke()
                ring.stroke()
            }
            x += Self.dot + Self.gap
        }
        let name = NSAttributedString(string: shownName, attributes: nameAttributes)
        let size = name.size()
        let nameWidth = max(0, bounds.width - x - Self.gap - Self.chevron - Self.trailing)
        name.draw(with: NSRect(x: x, y: (chip.midY - size.height / 2).rounded(), width: nameWidth, height: size.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        x += nameWidth + Self.gap
        if let symbol = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
            let image = ClipBarButton.tinted(symbol, DesignValues.nsColor("text.tertiary"))
            image.draw(in: NSRect(x: x + (Self.chevron - image.size.width) / 2, y: (chip.midY - image.size.height / 2).rounded(), width: image.size.width, height: image.size.height))
        }
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: NSRect(x: 0, y: ((bounds.height - Self.chipHeight) / 2).rounded(), width: bounds.width, height: Self.chipHeight), xRadius: 4, yRadius: 4).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // MARK: The menu

    static let modelItem = NSUserInterfaceItemIdentifier("voxclip.harness.model")
    /// An entry's name without its trailing billing.
    static func name(of item: NSMenuItem) -> String { item.title.components(separatedBy: "\t").first ?? item.title }

    @objc func showMenu() {
        let menu = makeMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 2), in: self)
    }

    /// The menu (doc/design.md §6.3.2): the header, the AIs by group with their billing trailing, then Model and AI
    /// Settings…. The chosen AI is checked.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "AI")
        menu.autoenablesItems = false
        menu.delegate = self
        let header = NSMenuItem(title: Self.header, action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(string: Self.header, attributes: [.font: VCType.small.nsFont(), .foregroundColor: DesignValues.nsColor("text.tertiary")])
        header.isEnabled = false
        menu.addItem(header)
        let chosen = app.string("llm.connector")
        for (group, title) in [("cli", "Installed apps · your own sign-in"), ("local", "On this Mac"), ("apiKey", "Your API key")] {
            let providers = app.harnessProviders.filter { $0.group == group }
            guard !providers.isEmpty else { continue }
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: title))
            for provider in providers {
                let item = NSMenuItem(title: provider.choiceName, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = provider.id
                item.state = provider.id == chosen ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        if let provider = app.providers.first(where: { $0.id == chosen }) {
            let models = modelChoices(provider)
            if models.count > 1 {
                let item = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
                item.identifier = Self.modelItem
                let submenu = NSMenu(title: "Model")
                let current = app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "")
                for model in models {
                    let choice = NSMenuItem(title: model.name, action: #selector(chooseModel(_:)), keyEquivalent: "")
                    choice.target = self
                    choice.representedObject = [provider.id, model.id]
                    choice.state = model.id == current ? .on : .off
                    submenu.addItem(choice)
                }
                item.submenu = submenu
                menu.addItem(item)
            }
        }
        let settings = NSMenuItem(title: "AI Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)
        refresh(menu)
        return menu
    }

    /// The models the Model submenu offers: the catalogue's, and the chosen one when it is not among them.
    private func modelChoices(_ provider: ProviderChoice) -> [ProviderChoice.Model] {
        let current = app.string("llm.model.\(provider.id)", fallback: provider.defaultModel ?? "")
        var models = provider.models
        if !current.isEmpty, !models.contains(where: { $0.id == current }) { models.append(.init(id: current, name: current, tier: nil)) }
        return models
    }

    /// Each AI's trailing billing as detected now, on a right tab stop past the widest name.
    func refresh(_ menu: NSMenu) {
        let entries = menu.items.filter { $0.representedObject is String }
        let nameFont = NSFont.menuFont(ofSize: 0), detailFont = VCType.callout.nsFont()
        // The item's title follows its attributed title, so the name comes from the catalogue each time.
        let labels = entries.map { item in app.providers.first { $0.id == item.representedObject as? String }?.choiceName ?? "" }
        let trailing = entries.map { billing(for: $0.representedObject as? String ?? "") }
        let names = labels.map { ceil(($0 as NSString).size(withAttributes: [.font: nameFont]).width) }.max() ?? 0
        let details = trailing.map { ceil(($0 as NSString).size(withAttributes: [.font: detailFont]).width) }.max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: names + 32 + details)]
        for (item, (label, detail)) in zip(entries, zip(labels, trailing)) {
            let title = NSMutableAttributedString(string: label, attributes: [.font: nameFont, .paragraphStyle: paragraph])
            if !detail.isEmpty {
                title.append(NSAttributedString(string: "\t" + detail, attributes: [.font: detailFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]))
            }
            item.attributedTitle = title
            item.toolTip = detail.isEmpty ? nil : detail
        }
        if let model = menu.items.first(where: { $0.identifier == Self.modelItem }), let provider = app.providers.first(where: { $0.id == app.string("llm.connector") }) {
            let name = app.harnessModelName(provider)
            let title = NSMutableAttributedString(string: "Model", attributes: [.font: nameFont, .paragraphStyle: paragraph])
            title.append(NSAttributedString(string: "\t" + name, attributes: [.font: detailFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]))
            model.attributedTitle = title
        }
        refreshInlineRows(menu)
    }
    /// The native menu keeps its keyboard navigation while these inline rows update after detection.
    private func refreshInlineRows(_ menu: NSMenu) {
        for item in menu.items where item.identifier?.rawValue.hasPrefix("voxclip.harness.inline.") == true { menu.removeItem(item) }
        var offset = menu.items.firstIndex { $0.identifier == Self.modelItem || $0.title == "AI Settings…" } ?? menu.items.count
        var serial = 0
        func append(_ item: NSMenuItem) {
            item.identifier = .init("voxclip.harness.inline.\(serial)"); serial += 1
            menu.insertItem(item, at: offset); offset += 1
        }
        let chosen = app.string("llm.connector")
        if let provider = app.providers.first(where: { $0.id == chosen }), provider.cli != nil,
           app.detectedConnectorStatus[chosen] == .cliSignedOut || app.harnessSignIn.providerID == chosen {
            append(.sectionHeader(title: app.harnessSignIn.completed ? "Signed in to " + provider.shortName : "Sign in to " + provider.shortName))
            let instructions = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let text = [app.harnessSignIn.completed ? nil : provider.cli?.signInHint, app.harnessSignIn.message(for: provider)].compactMap { $0 }.joined(separator: "\n")
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = VCType.small.nsFont()
            label.frame = NSRect(x: 0, y: 0, width: 340, height: app.harnessSignIn.message(for: provider) == nil ? 38 : 66)
            instructions.view = label; instructions.isEnabled = false
            instructions.identifier = .init("voxclip.harness.signIn.message")
            append(instructions)
            if !app.harnessSignIn.completed {
            for (title, action) in [("Sign In…", #selector(signIn)), ("Check Sign-In", #selector(checkSignIn))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.isEnabled = !app.harnessSignIn.checking
                append(item)
            }
            }
        }
        if let line = app.monthlySpendLine {
            let spend = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            spend.isEnabled = false; spend.identifier = .init("voxclip.harness.spend")
            append(spend)
        }
    }
    /// An AI's trailing text now: its billing once detected, "Checking…" while detection runs.
    func billing(for id: String) -> String {
        guard let provider = app.providers.first(where: { $0.id == id }) else { return "" }
        let readiness = app.harnessReadiness(provider)
        if readiness == .unknown { return checking.contains(id) ? "Checking…" : "" }
        return app.harnessBilling(provider, readiness: readiness)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu.title == "AI" else { return }
        openMenu = menu
        needsDisplay = true
        startDetection()
        Task { [weak self] in
            guard let self else { return }; await app.refreshMonthlySpend()
            if let openMenu { refresh(openMenu) }
        }
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === openMenu else { return }
        openMenu = nil
        needsDisplay = true
    }

    /// Detects every AI the menu lists, side by side, and updates the open menu as each answers (design.md §3.2:
    /// detection runs only when the menu opens). A detection still running is not started again.
    @discardableResult func startDetection() -> Task<Void, Never> {
        if let detection { return detection }
        let providers = app.harnessProviders
        checking = Set(providers.map(\.id))
        if let openMenu { refresh(openMenu) }
        let app = self.app
        let detections = providers.map { provider in
            Task { @MainActor [weak self] in
                _ = await app.connectorStatus(provider)
                guard let self else { return }
                checking.remove(provider.id)
                if let openMenu { refresh(openMenu) }
                render()
            }
        }
        let task = Task { @MainActor [weak self] in
            for detection in detections { await detection.value }
            self?.detection = nil
            self?.checking = []
        }
        detection = task
        return task
    }

    @objc func choose(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        app.set("llm.connector", .string(id))
        render()
    }
    @objc func chooseModel(_ item: NSMenuItem) {
        guard let pair = item.representedObject as? [String], pair.count == 2 else { return }
        app.set("llm.model.\(pair[0])", .string(pair[1]))
        render()
    }
    @objc private func signIn() {
        guard let provider = app.providers.first(where: { $0.id == app.string("llm.connector") }) else { return }
        Task { await app.harnessSignIn.signIn(provider) }
    }
    @objc private func checkSignIn() {
        guard let provider = app.providers.first(where: { $0.id == app.string("llm.connector") }) else { return }
        Task { await app.harnessSignIn.check(provider) }
    }
    @objc private func openSettings() { openVoxClipSettings(pane: "ai") }
}
