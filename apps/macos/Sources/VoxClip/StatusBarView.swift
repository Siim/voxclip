import AppKit
import VoxClipCore

// The status bar (ux/v2 notes.md §1, the mockup's `.sbar`, impl-plan V11a): full width, 24 pt,
// `bg.statusBar` with a `line.default` hairline above. Leading: the AI's status dot and name, its
// billing once this session detected it (impl-plan item 14), and the running task. Trailing: the
// open tab's edit summary, the Frame (which opens View › Frame's choices) and the export state.
// Items are 11 pt `text.secondary`, dim ones `text.tertiary`; durations alone are SF Mono.

/// A run of a status item's text; durations alone are SF Mono (notes.md §2).
struct StatusText: Equatable {
    var string: String
    var mono = false
}

/// One item of the status bar, as it reads and draws.
struct StatusItem: Equatable {
    /// The items, in the bar's order: harness, billing and task lead; summary, frame and export trail.
    enum Kind: String, CaseIterable {
        case harness, billing, task, summary, frame, spend, export
        static let leading: [Kind] = [.harness, .billing, .task]
        static let trailing: [Kind] = [.summary, .frame, .spend, .export]
        /// What a narrow bar drops first. The summary never goes; it truncates last.
        static let dropOrder: [Kind] = [.billing, .spend, .frame, .export, .harness, .task]
    }
    /// What draws before the text: the AI's 6 pt dot (a ring before detection), a 13 pt symbol, or an 11 pt spinner.
    enum Lead: Equatable { case none, dot(token: String, filled: Bool), symbol(String), spinner }
    let kind: Kind
    var lead: Lead = .none
    var parts: [StatusText]
    /// `text.tertiary` rather than `text.secondary` (the mockup's `.si.dim`).
    var dim = false
    /// VoiceOver's value for the item: "Claude Code (installed CLI), Sonnet (latest), no extra cost on your plan".
    var spoken: String
    /// VoiceOver's help: the summary's detail (design §3.5).
    var help: String? = nil
    var text: String { parts.map(\.string).joined() }
}

/// What the status bar shows for a window: its items and, while a task runs, when it started.
struct StatusBarContent: Equatable {
    var items: [StatusItem.Kind: StatusItem] = [:]
    /// The running task's start; the bar ticks its elapsed time while it is set.
    var taskSince: Date?
    subscript(_ kind: StatusItem.Kind) -> StatusItem? { items[kind] }

    /// The items for `editor` in its window (none on Home), at `now`.
    @MainActor static func make(app: AppModel, editor: EditorModel?, now: Date) -> StatusBarContent {
        var content = StatusBarContent()
        if let spend = app.monthlySpendLine {
            content.items[.spend] = StatusItem(kind: .spend, lead: .symbol("waveform"), parts: [StatusText(string: spend)], spoken: spend, help: "Estimated spend, from the local ledger; not a provider invoice.")
        }
        guard let editor else { return content }
        for item in app.statusHarness { content.items[item.kind] = item }
        let task = editor.statusTask(now: now)
        content.items[.task] = task?.item ?? editor.statusReadOnly
        content.taskSince = task?.since
        content.items[.summary] = editor.statusSummary
        content.items[.frame] = editor.statusFrame
        content.items[.export] = editor.statusExport
        return content
    }
}

extension AppModel {
    /// The chosen AI's short name and model with its status dot, then its billing once this session detected it
    /// (impl-plan item 14: never a stored claim); nothing with no AI chosen. The billing reads "No extra cost on your
    /// plan" for a CLI on its plan (C8), "No extra cost" for a model on this Mac or a local server, "Billed to your
    /// key" when each send asks first, and the reason when the AI cannot send ("Not signed in").
    var statusHarness: [StatusItem] {
        let status = harnessStatus
        guard let id = status.connectorID, let token = status.dotToken else { return [] }
        let billing: String? = switch status.readiness {
        case .unknown: nil
        case .ready: providers.first { $0.id == id }?.group == "cli" ? "No extra cost on your plan" : "No extra cost"
        case .asksFirst: "Billed to your key"
        case .unavailable(let reason): reason.prefix(1).uppercased() + reason.dropFirst()
        }
        let name = [status.name, status.model].filter { !$0.isEmpty }.joined(separator: " · ")
        let spoken = [status.label, status.model.isEmpty ? nil : status.model, billing?.lowercased()].compactMap { $0 }.joined(separator: ", ")
        var items = [StatusItem(kind: .harness, lead: .dot(token: token, filled: status.detected), parts: [StatusText(string: name)], spoken: spoken)]
        if let billing { items.append(StatusItem(kind: .billing, parts: [StatusText(string: billing)], dim: true, spoken: billing)) }
        return items
    }
}

extension AspectRatio {
    /// The Frame's name, as View › Frame and the status bar read it: "9:16", "1:1", "16:9", "Original".
    var frameName: String { self == .source ? "Original" : rawValue }
}

extension EditorModel {
    /// The running task and when it started: transcription's progress, the open Rewrite's run (its task's headline,
    /// "Rewriting clip 1…", design.md R1) or a Find Clips run, Hook's included ("Finding clips… 0:12"). Rewrite and Find
    /// Clips share the project's AI lease, so one runs at a time.
    func statusTask(now: Date) -> (item: StatusItem, since: Date?)? {
        if let progress, !progress.isEmpty {
            return (StatusItem(kind: .task, lead: .spinner, parts: [StatusText(string: progress)], spoken: progress), nil)
        }
        let running: (text: String, since: Date?)?
        if let task = openRewrite?.task, task.state == .running {
            running = (task.headline.text, task.headline.runningSince)
        } else if finding {
            running = ("Finding clips…", findingSince)
        } else {
            running = nil
        }
        guard let running else { return nil }
        let words = running.text.hasSuffix("…") ? String(running.text.dropLast()) : running.text
        guard let since = running.since else {
            return (StatusItem(kind: .task, lead: .spinner, parts: [StatusText(string: running.text)], spoken: words), nil)
        }
        let elapsed = max(0, now.timeIntervalSince(since))
        return (StatusItem(kind: .task, lead: .spinner, parts: [StatusText(string: running.text + " "), StatusText(string: durationLabel(elapsed), mono: true)],
                           spoken: "\(words), \(SidebarStyle.spokenDuration(elapsed))"), since)
    }

    /// While the video is missing or a relink waits for Use It, the alert in the running task's place: "Read-only until
    /// you locate the video" (v5 f24c), "Read-only until you confirm the video" (f24). Nothing runs meanwhile.
    var statusReadOnly: StatusItem? {
        mediaReadOnlyNote.map { StatusItem(kind: .task, lead: .symbol("exclamationmark.triangle"), parts: [StatusText(string: $0)], spoken: $0) }
    }

    /// The open tab's edit summary (notes.md, f1): "Clip 1 · 0:43 · 8 cuts · 5 changes to review", the duration in
    /// SF Mono; "No cuts yet" with nothing cut, "Not transcribed" without a transcript. The changes are those of the
    /// transcript's proposal on this tab that wait for a review (V14: kept and undone ones never count). A state of
    /// design §3.5's busy list shows instead. VoiceOver reads the detail as its help.
    var statusSummary: StatusItem {
        let notice: String? = if !editingAvailable && !words.isEmpty {
            "Editing is not available in this build. Your video and edits are still here."
        } else if voiceLabPlan == nil && !summary.canExport && !words.isEmpty {
            "Keep at least one word before exporting."
        } else { nil }
        if let notice { return StatusItem(kind: .summary, parts: [StatusText(string: notice)], spoken: notice, help: summaryDetail) }
        let scope = scopeName(project.edits.activeClipId)
        var details: [String] = []
        if !transcribed { details.append("Not transcribed") } else {
            let cuts = cutCount
            details.append(cuts == 0 ? "No cuts yet" : cuts == 1 ? "1 cut" : "\(cuts) cuts")
        }
        let pending = unreviewedChanges(clipID: project.edits.activeClipId).count
        if pending > 0 { details.append(pending == 1 ? "1 change to review" : "\(pending) changes to review") }
        let tail = details.map { " · " + $0 }.joined()
        return StatusItem(kind: .summary, parts: [StatusText(string: scope + " · "), StatusText(string: durationLabel(duration), mono: true), StatusText(string: tail)],
                          spoken: ([scope, SidebarStyle.spokenDuration(duration)] + details.map { $0.prefix(1).lowercased() + $0.dropFirst() }).joined(separator: ", "), help: summaryDetail)
    }

    /// The export's frame (f1): "16:9 · 1080p30", the aspect with the output's short side and rate, or the aspect
    /// alone without video. It opens View › Frame's choices where those can act.
    var statusFrame: StatusItem {
        var text = project.export.aspect.frameName
        if project.media.source.video != nil {
            let output = ExportFingerprint.output(project)
            text += " · \(min(output.size.width, output.size.height))p\(Int(output.fps.rounded()))"
        }
        return StatusItem(kind: .frame, parts: [StatusText(string: text)], dim: true, spoken: text.replacingOccurrences(of: " · ", with: ", "))
    }
    /// The Frame can change: View › Frame's rule (tags 52–55).
    var canChangeFrame: Bool { capabilities.writable && capabilities.media }

    /// The open tab's export state (design §3.4's statuses, f1's "Not exported"): "Exporting 42%" (with "2 of 3" for
    /// several), "Export failed", "Edited since export", "Exported" or "Not exported", from the export ledger.
    var statusExport: StatusItem {
        if exporting {
            let percent = exportPercent
            let total = exportClipIDs.count
            let text = total > 1 ? "Exporting \(max(1, exportIndex)) of \(total) · \(percent)%" : "Exporting \(percent)%"
            return StatusItem(kind: .export, lead: .symbol("square.and.arrow.up"), parts: [StatusText(string: text)], spoken: text.replacingOccurrences(of: " · ", with: ", "))
        }
        let (symbol, text, dim): (String, String, Bool) = switch exportRowStatus(target: activeClip.map { .clip($0.id) } ?? .fullEdit) {
        case .none, .exporting: ("square.and.arrow.up", "Not exported", true)
        case .exported: ("checkmark.circle", "Exported", true)
        case .changed: ("exclamationmark.triangle", "Edited since export", false)
        case .failed: ("exclamationmark.triangle", "Export failed", false)
        }
        return StatusItem(kind: .export, lead: .symbol(symbol), parts: [StatusText(string: text)], dim: dim, spoken: text)
    }
}

/// The status bar's measurements (notes.md `.sbar`, `.si`): 8 pt in from the window's edges, 2 between items, each
/// item 7 in from its sides with 6 between its lead and its text, centred under the 1 pt hairline.
enum StatusBarMetrics {
    static let barPadding: CGFloat = 8, itemGap: CGFloat = 2, groupGap: CGFloat = 16
    static let padding: CGFloat = 7, leadGap: CGFloat = 6
    static let dot: CGFloat = 6, icon: CGFloat = 13, spinner: CGFloat = 11
    /// Half way down the 23 pt under the hairline.
    static let center: CGFloat = 12.5
    /// The Frame's hover and pressed fill, as the harness picker's chip.
    static let chipHeight: CGFloat = 18

    @MainActor static var motion: Bool { !EditorAccessibilityPolicy.system.reduceMotion }
    /// The lead's width; a spinner takes none under Reduce Motion, which shows the text alone.
    @MainActor static func leadWidth(_ lead: StatusItem.Lead) -> CGFloat {
        switch lead {
        case .none: 0
        case .dot: dot
        case .symbol: icon
        case .spinner: motion ? spinner : 0
        }
    }
    @MainActor static func attributed(_ item: StatusItem, emphasized: Bool = false) -> NSAttributedString {
        let color = DesignValues.nsColor(item.dim && !emphasized ? "text.tertiary" : "text.secondary")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString()
        for part in item.parts {
            text.append(NSAttributedString(string: part.string, attributes: [.font: part.mono ? VCType.small.nsMono() : VCType.small.nsFont(),
                                                                            .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        return text
    }
    /// The item's width with nothing truncated.
    @MainActor static func naturalWidth(_ item: StatusItem) -> CGFloat {
        let lead = leadWidth(item.lead)
        return padding + lead + (lead > 0 ? leadGap : 0) + ceil(attributed(item).size().width) + padding
    }
    /// Where the text starts in the item.
    @MainActor static func textX(_ item: StatusItem) -> CGFloat {
        let lead = leadWidth(item.lead)
        return padding + lead + (lead > 0 ? leadGap : 0)
    }
    /// Draws `item` in `bounds` (flipped): the lead, then the text, truncated at the tail when the item is narrow.
    @MainActor static func draw(_ item: StatusItem, in bounds: NSRect, emphasized: Bool = false) {
        switch item.lead {
        case .none, .spinner: break
        case .dot(let token, let filled):
            let dot = NSRect(x: padding, y: center - self.dot / 2, width: self.dot, height: self.dot)
            if filled {
                DesignValues.nsColor(token).setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                // Not detected yet: a ring, so the dot claims no state (impl-plan item 14), as the harness picker draws it.
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                DesignValues.nsColor(token).setStroke()
                ring.stroke()
            }
        case .symbol(let name):
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: icon - 2, weight: .regular)) {
                let image = ClipBarButton.tinted(symbol, DesignValues.nsColor("text.tertiary"))
                let size = image.size
                image.draw(in: NSRect(x: (padding + (icon - size.width) / 2).rounded(), y: (center - size.height / 2).rounded(), width: size.width, height: size.height))
            }
        }
        let text = attributed(item, emphasized: emphasized)
        let x = textX(item), height = ceil(text.size().height)
        text.draw(with: NSRect(x: x, y: (center - height / 2).rounded(), width: max(0, bounds.width - x - padding), height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// A status item that only reads: static text for VoiceOver with its kind's name and the item's value. The task's
/// spinner is a small `NSProgressIndicator` in the lead's place.
@MainActor final class StatusItemView: NSView {
    let kind: StatusItem.Kind
    private(set) var item: StatusItem
    let spinner = NSProgressIndicator()

    init(kind: StatusItem.Kind) {
        self.kind = kind
        item = StatusItem(kind: kind, parts: [], spoken: "")
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: ShellMetrics.statusBar))
        identifier = NSUserInterfaceItemIdentifier("voxclip.status.\(kind.rawValue)")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)
        addSubview(spinner)
        // The billing is read with the AI's item.
        setAccessibilityElement(kind != .billing)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(kind.name)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func show(_ item: StatusItem) {
        guard item != self.item else { return }
        self.item = item
        setAccessibilityValue(item.spoken)
        setAccessibilityHelp(item.help)
        toolTip = item.help
        let spins = item.lead == .spinner && StatusBarMetrics.motion && !isHidden
        if spins { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
        needsDisplay = true
    }
    override var isHidden: Bool {
        didSet {
            if !isHidden && item.lead == .spinner && StatusBarMetrics.motion { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
    }
    override func layout() {
        super.layout()
        let size = StatusBarMetrics.spinner
        spinner.frame = NSRect(x: StatusBarMetrics.padding, y: (StatusBarMetrics.center - size / 2).rounded(), width: size, height: size)
    }
    override func draw(_ dirtyRect: NSRect) { StatusBarMetrics.draw(item, in: bounds) }
}

/// The Frame item (f1's "16:9 · 1080p30"): a pop-up button whose menu is View › Frame's choices (9:16, 1:1, 16:9,
/// Original), the current one checked; a choice is `setAspect`'s one undo step, as the menu's. Where the Frame cannot
/// change (a Versions window, missing media) it only reads. The selected-row fill shows under the pointer and while
/// the menu is open, with the text lifted to `text.secondary` on it.
@MainActor final class StatusFrameButton: NSButton, NSMenuDelegate {
    private(set) var item = StatusItem(kind: .frame, parts: [], spoken: "")
    /// Sets the aspect the menu chose.
    var choose: ((AspectRatio) -> Void)?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private(set) weak var openMenu: NSMenu?
    private var current: AspectRatio = .source

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: ShellMetrics.statusBar))
        identifier = NSUserInterfaceItemIdentifier("voxclip.status.frame")
        isBordered = false
        setButtonType(.momentaryPushIn)
        title = ""
        target = self
        action = #selector(showMenu)
        setAccessibilityLabel(StatusItem.Kind.frame.name)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func show(_ item: StatusItem, aspect: AspectRatio, canChange: Bool) {
        current = aspect
        isEnabled = canChange
        setAccessibilityRole(canChange ? .popUpButton : .staticText)
        setAccessibilityValue(item.spoken)
        toolTip = canChange ? "Frame: \(item.text)" : nil
        guard item != self.item else { return }
        self.item = item
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let emphasized = isEnabled && (hovering || isHighlighted || openMenu != nil)
        if emphasized {
            DesignValues.nsColor("bg.selectedRow").setFill()
            NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        }
        StatusBarMetrics.draw(item, in: bounds, emphasized: emphasized)
    }
    private var chip: NSRect { NSRect(x: 0, y: (StatusBarMetrics.center - StatusBarMetrics.chipHeight / 2).rounded(), width: bounds.width, height: StatusBarMetrics.chipHeight) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// View › Frame's choices in its order (`AppDelegate.frameAspects`), the current one checked.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Frame")
        menu.autoenablesItems = false
        menu.delegate = self
        for (offset, aspect) in AppDelegate.frameAspects.enumerated() {
            let entry = NSMenuItem(title: aspect.frameName, action: #selector(chooseAspect(_:)), keyEquivalent: "")
            entry.tag = 52 + offset
            entry.target = self
            entry.representedObject = aspect.rawValue
            entry.state = aspect == current ? .on : .off
            menu.addItem(entry)
        }
        return menu
    }
    @objc func showMenu() {
        guard isEnabled else { return }
        let menu = makeMenu()
        // As a pop-up button: the current choice over the item.
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSPoint(x: 0, y: bounds.height - 3), in: self)
    }
    @objc func chooseAspect(_ entry: NSMenuItem) {
        guard isEnabled, let raw = entry.representedObject as? String, let aspect = AspectRatio(rawValue: raw) else { return }
        choose?(aspect)
    }
    func menuWillOpen(_ menu: NSMenu) { openMenu = menu; needsDisplay = true }
    func menuDidClose(_ menu: NSMenu) { openMenu = nil; needsDisplay = true }
}

/// The status bar: the shell's last row and F6's last stop, a VoiceOver group "Status" (EditorShellController) whose
/// items read with their values. Items lay out from both ends; a narrow bar drops the billing, then the Frame, the
/// export state, the AI and the task, and truncates the summary last.
@MainActor final class StatusBarView: NSView {
    private let shell: WorkspaceShell
    private var observation: ShellObservation?
    private var ticker: Timer?
    private var tickerSince: Date?
    private(set) var content = StatusBarContent()
    /// The items laid out now, in the bar's order.
    private(set) var shown: [StatusItem.Kind] = []
    private var views: [StatusItem.Kind: NSView] = [:]
    let frameButton = StatusFrameButton()
    /// The bar's clock; tests set it.
    var now: () -> Date = Date.init

    init(shell: WorkspaceShell) {
        self.shell = shell
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: ShellMetrics.statusBar))
        identifier = NSUserInterfaceItemIdentifier("voxclip.shell.statusBar")
        for kind in StatusItem.Kind.allCases {
            let view: NSView = kind == .frame ? frameButton : StatusItemView(kind: kind)
            view.isHidden = true
            views[kind] = view
            addSubview(view)
        }
        frameButton.choose = { [weak self] aspect in
            guard let editor = self?.editor, editor.canChangeFrame else { return }
            editor.setAspect(aspect)
        }
        observation = ShellObservation { [weak self] in self?.render() }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func tearDown() {
        observation?.cancel()
        ticker?.invalidate()
        ticker = nil
        tickerSince = nil
    }
    private var editor: EditorModel? { shell.showsHome ? nil : shell.editor }
    func view(_ kind: StatusItem.Kind) -> NSView? { views[kind] }
    /// The read-only view of `kind` (every item but the Frame).
    func itemView(_ kind: StatusItem.Kind) -> StatusItemView? { views[kind] as? StatusItemView }

    /// The status bar is F6's last stop (impl-plan §3.2): F6 gives it keyboard focus, with
    /// the focus ring inside its bounds; a click does not.
    @discardableResult func takeFocus() -> Bool {
        focusRequested = true
        defer { focusRequested = false }
        return window?.makeFirstResponder(self) ?? false
    }
    private var focusRequested = false
    override var acceptsFirstResponder: Bool { focusRequested || window?.firstResponder === self }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.insetBy(dx: 2, dy: 2).fill() }

    /// Reads the window's editor and the app; the observation runs it again when what it read changes.
    func render() {
        let editor = editor
        // The summary and the export state follow the project, which only projectRevision makes observable.
        _ = editor?.projectRevision
        show(StatusBarContent.make(app: shell.app, editor: editor, now: now()))
        frameButton.show(content[.frame] ?? StatusItem(kind: .frame, parts: [], spoken: ""), aspect: editor?.project.export.aspect ?? .source,
                         canChange: editor?.canChangeFrame ?? false)
    }
    /// The task's elapsed time, once a second while it runs; nothing else is read again.
    func tick() {
        guard let editor, let task = editor.statusTask(now: now()) else { return render() }
        var next = content
        next.items[.task] = task.item
        next.taskSince = task.since
        show(next)
    }
    private func show(_ next: StatusBarContent) {
        let resized = StatusItem.Kind.allCases.contains { next[$0].map(StatusBarMetrics.naturalWidth) != content[$0].map(StatusBarMetrics.naturalWidth) }
        content = next
        for (kind, view) in views {
            guard let item = next[kind] else { continue }
            (view as? StatusItemView)?.show(item)
        }
        schedule(next.taskSince)
        if resized { needsLayout = true }
    }
    /// A timer on the task's whole seconds while it runs and the bar is in a window.
    private func schedule(_ since: Date?) {
        guard let since, window != nil else {
            ticker?.invalidate()
            ticker = nil
            tickerSince = nil
            return
        }
        guard ticker == nil || tickerSince != since else { return }
        ticker?.invalidate()
        tickerSince = since
        let elapsed = max(0, now().timeIntervalSince(since))
        let timer = Timer(fire: since.addingTimeInterval(elapsed.rounded(.down) + 1), interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ticker?.invalidate(); ticker = nil; tickerSince = nil } else { schedule(content.taskSince) }
    }

    override func layout() {
        super.layout()
        layoutItems()
    }
    /// Places the items from both ends and hides what does not fit, in `dropOrder`.
    private func layoutItems() {
        let present = StatusItem.Kind.allCases.filter { content[$0] != nil }
        var visible = Set(present)
        let widths = Dictionary(uniqueKeysWithValues: present.map { ($0, StatusBarMetrics.naturalWidth(content[$0]!)) })
        func run(_ kinds: [StatusItem.Kind]) -> CGFloat {
            let shown = kinds.filter(visible.contains)
            return shown.reduce(0) { $0 + widths[$1]! } + CGFloat(max(0, shown.count - 1)) * StatusBarMetrics.itemGap
        }
        func total() -> CGFloat {
            let leading = run(StatusItem.Kind.leading), trailing = run(StatusItem.Kind.trailing)
            return leading + trailing + (leading > 0 && trailing > 0 ? StatusBarMetrics.groupGap : 0)
        }
        let room = bounds.width - 2 * StatusBarMetrics.barPadding
        for kind in StatusItem.Kind.dropOrder where total() > room { visible.remove(kind) }
        var x = StatusBarMetrics.barPadding
        for kind in StatusItem.Kind.leading where visible.contains(kind) {
            views[kind]?.frame = NSRect(x: x, y: 0, width: widths[kind]!, height: bounds.height)
            x += widths[kind]! + StatusBarMetrics.itemGap
        }
        // The summary may reach the bar's padding when nothing leads, as `total()` assumes.
        let anyLeading = StatusItem.Kind.leading.contains(where: visible.contains)
        let summaryStart = anyLeading ? x - StatusBarMetrics.itemGap + StatusBarMetrics.groupGap : StatusBarMetrics.barPadding
        var end = bounds.width - StatusBarMetrics.barPadding
        for kind in StatusItem.Kind.trailing.reversed() where visible.contains(kind) {
            var width = widths[kind]!
            // The summary takes what is left, truncated at its tail.
            if kind == .summary { width = max(0, min(width, end - summaryStart)) }
            views[kind]?.frame = NSRect(x: end - width, y: 0, width: width, height: bounds.height)
            end -= width + StatusBarMetrics.itemGap
        }
        for (kind, view) in views {
            let hidden = !visible.contains(kind)
            if view.isHidden != hidden { view.isHidden = hidden }
            view.needsDisplay = true
        }
        let next = (StatusItem.Kind.leading + StatusItem.Kind.trailing).filter(visible.contains)
        if next != shown {
            shown = next
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }

    /// VoiceOver reads the items in the bar's order; the billing is part of the AI's value.
    override func accessibilityChildren() -> [Any]? {
        shown.filter { $0 != .billing }.compactMap { views[$0] }
    }

    override func draw(_ dirtyRect: NSRect) {
        DesignValues.nsColor("bg.statusBar").setFill()
        dirtyRect.fill()
        DesignValues.nsColor("line.default").setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
