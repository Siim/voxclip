import Foundation
import VoxClipCore

/// The Fine-tune groups (looks spec 2026-11-28, section 3.5): Fix corrects the camera and stays when the look changes; Light,
/// Color and Effects are the look's own values.
enum ClipLookGroup: String, CaseIterable, Sendable {
    case fix, light, color, effects

    var title: String { rawValue.capitalized }
    /// The heading's note; only the Fix has one.
    var note: String? { self == .fix ? "stays when you change look" : nil }
    var accessibilityLabel: String { note.map { "\(title), \($0)" } ?? title }
    var sliders: [ClipLookSlider] { ClipLookSlider.allCases.filter { $0.group == self } }
    /// "Reset fix", "Reset light", "Reset color", "Reset effects".
    var resetName: String { "Reset \(rawValue)" }
}

/// The thirteen Fine-tune sliders in panel order (spec section 5.1): each is a `colorGrade` control or one of the four
/// `colorAdjustments`, in whole points.
enum ClipLookSlider: String, CaseIterable, Sendable {
    case exposure, temperature, tint, brightness, contrast, highlights, shadows, vibrance, saturation, warmth, fade, vignette, grain

    var group: ClipLookGroup {
        switch self {
        case .exposure, .temperature, .tint: .fix
        case .brightness, .contrast, .highlights, .shadows: .light
        case .vibrance, .saturation, .warmth: .color
        case .fade, .vignette, .grain: .effects
        }
    }
    var label: String { rawValue.capitalized }
    var grade: ClipColorGrade.Control? { ClipColorGrade.Control(rawValue: rawValue) }
    var adjustment: ClipColorAdjustments.Control? { ClipColorAdjustments.Control(rawValue: rawValue) }
    var range: ClosedRange<Int> { grade?.range ?? ClipColorAdjustments.range }
    /// "Change exposure" … "Change grain".
    var undoName: String { "Change \(rawValue)" }
    /// Vibrance and Saturation do nothing on a black-and-white base.
    var mutedByMono: Bool { self == .vibrance || self == .saturation }

    func value(_ controls: ProjectClipControls) -> Int {
        if let grade { return controls.colorGrade?[grade] ?? 0 }
        return adjustment.map { (controls.colorAdjustments ?? .neutral)[$0] } ?? 0
    }

    /// The look's own value, which the track's tick marks: 0 for the Fix and with no look.
    func value(of look: ClipLookPreset?) -> Int {
        guard let look, group != .fix else { return 0 }
        if let grade { return look.grade[grade] }
        return adjustment.map { (look.adjustments ?? .neutral)[$0] } ?? 0
    }

    /// `controls` with this slider at `value` (clamped); a neutral grade or adjustment is removed.
    func set(_ value: Int, in controls: inout ProjectClipControls) {
        let point = value.clamped(to: range)
        if let grade {
            var values = controls.colorGrade ?? ClipColorGrade()
            values[grade] = point
            controls.colorGrade = values.isNeutral ? nil : values
        } else if let adjustment {
            var values = controls.colorAdjustments ?? .neutral
            values[adjustment] = point
            controls.colorAdjustments = values == .neutral ? nil : values
        }
    }

    /// "+0.40 EV" for Exposure (points ÷ 50), else "+20", "−15" or "0".
    func text(_ value: Int) -> String {
        if self == .exposure {
            let ev = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(abs(value)) / 50)
            return (value < 0 ? "\u{2212}" : value > 0 ? "+" : "") + ev + " EV"
        }
        return value == 0 ? "0" : value > 0 ? "+\(value)" : "\u{2212}\(-value)"
    }

    /// "plus 20", "minus 15" or "0"; Exposure in EV, "plus 0.4".
    func spoken(_ value: Int) -> String {
        let magnitude = self == .exposure ? Self.decimal(Double(abs(value)) / 50) : "\(abs(value))"
        return value == 0 ? "0" : (value > 0 ? "plus " : "minus ") + magnitude
    }

    /// A typed value: "+20", "−15", "-15" or "20"; Exposure takes EV ("+0.4", "0.40 EV"). Nil when it isn't a number; the
    /// result is clamped to the slider's range.
    func parse(_ text: String) -> Int? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{2212}", with: "-")
        if self == .exposure, trimmed.uppercased().hasSuffix("EV") { trimmed = String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        if trimmed.hasPrefix("+") { trimmed.removeFirst() }
        guard let number = Double(trimmed), number.isFinite else { return nil }
        let points = self == .exposure ? number * 50 : number
        return Int(points.rounded()).clamped(to: range)
    }

    /// 0.4, 1, 1.25: at most two decimals, no trailing zeros.
    static func decimal(_ value: Double) -> String {
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Claude's look for a clip this session (looks spec section 9.6): the plan's look and the Fix it measured, if any. It is
/// held by the Make it postable run, not the project.
struct ClipLookPick: Equatable {
    let look: ClipAutopilotPlan.Look
    let fix: ClipColorFix?
}

/// What the look controls show for one clip (looks spec 2026-11-28, sections 3 and 10): the Look row's name and amount, the
/// tiles and their states, Suggested, the ticks, and every disabled control's reason. Pure: the editor's commands act, this
/// only reads the clip's controls against the looks file.
struct ClipLookPanel {
    static let suggested = "suggested", all = "all"
    /// Suggested's starters, after As filmed, Claude's looks and the current look.
    static let starters = ["naturalBoost", "softSkin", "warm", "goldenHour", "warmPrint", "softBW", "cleanPop"]
    static let suggestedLimit = 8
    static let original = ClipLook.original.rawValue

    let library: ClipLookLibrary
    let controls: ProjectClipControls
    var pick: ClipLookPick?

    var match: ClipLookMatch? { library.match(controls) }
    /// The look the values come from, for the ticks, the resets and Back to: nil for As filmed and Custom.
    var origin: ClipLookPreset? {
        guard let look = match?.look, look.id != Self.original else { return nil }
        return look
    }
    var amount: Int { controls.colorGrade?.amount ?? 100 }
    var fix: ClipColorFix { controls.colorGrade?.fix ?? .neutral }

    /// No base look, adjustments or look values: As filmed, with or without a Fix.
    static func lookPartNeutral(_ controls: ProjectClipControls) -> Bool {
        controls.look == .original && controls.colorAdjustments == nil && (controls.colorGrade?.lookValues ?? .neutral) == .neutral
    }
    var lookPartNeutral: Bool { Self.lookPartNeutral(controls) }

    /// "As filmed", "Warm Print", "Warm Print, edited" or "Custom".
    var lookName: String {
        if lookPartNeutral { return library.look(Self.original)?.label ?? "As filmed" }
        return library.name(for: controls)
    }
    /// The Look row: the name, then "· 70%" under 100.
    var lookValue: String { lookPartNeutral || amount == 100 ? lookName : "\(lookName) \u{00B7} \(amount)%" }
    /// The Clip section's summary part: "Warm Print 70%".
    var summary: String { lookPartNeutral || amount == 100 ? lookName : "\(lookName) \(amount)%" }

    enum TileState: Equatable { case none, applied, edited }
    func state(of look: ClipLookPreset) -> TileState {
        switch match {
        case .applied(let applied) where applied.id == look.id: .applied
        case .edited(let edited) where edited.id == look.id: .edited
        default: .none
        }
    }
    /// Claude's pick or one of its alternatives: ✦ at the tile's corner.
    func isClaudes(_ look: ClipLookPreset) -> Bool {
        guard let pick else { return false }
        return pick.look.id.rawValue == look.id || pick.look.alternatives.contains { $0.rawValue == look.id }
    }

    /// The category chips: Suggested, All, then the file's categories.
    var categories: [(id: String, label: String)] {
        [(Self.suggested, "Suggested"), (Self.all, "All")] + library.categories.map { ($0.id, $0.label) }
    }
    func categoryLabel(_ id: String) -> String { categories.first { $0.id == id }?.label ?? "Suggested" }

    /// Suggested (spec section 3.2): As filmed, Claude's pick and its alternatives, the current look, then the starters;
    /// duplicates dropped, at most 8.
    var suggestedLooks: [ClipLookPreset] {
        var ids = [Self.original]
        if let pick { ids += [pick.look.id.rawValue] + pick.look.alternatives.map(\.rawValue) }
        if let current = match?.look.id { ids.append(current) }
        ids += Self.starters
        var seen: Set<String> = [], looks: [ClipLookPreset] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            // A hidden look shows only while the clip uses it.
            guard let look = library.look(id), !look.hidden || look.id == match?.look.id else { continue }
            looks.append(look)
        }
        return Array(looks.prefix(Self.suggestedLimit))
    }

    func looks(in category: String) -> [ClipLookPreset] {
        switch category {
        case Self.suggested: suggestedLooks
        case Self.all: library.visible
        default: library.visible.filter { $0.category == category }
        }
    }

    /// "Warm Print, Film look" (spec section 3.9).
    func tileLabel(_ look: ClipLookPreset) -> String {
        "\(look.label), \(library.categories.first { $0.id == look.category }?.label ?? look.category) look"
    }
    /// "Selected, amount 70 percent", "Selected, edited", "Claude's pick" or nothing.
    func tileValue(_ look: ClipLookPreset) -> String {
        var parts: [String] = []
        switch state(of: look) {
        case .applied: parts.append(amount < 100 && !lookPartNeutral ? "Selected, amount \(amount) percent" : "Selected")
        case .edited: parts.append("Selected, edited")
        case .none: break
        }
        if let pick, pick.look.id.rawValue == look.id { parts.append("Claude's pick") }
        else if isClaudes(look) { parts.append("Claude's alternative") }
        return parts.joined(separator: ", ")
    }

    // MARK: Disabled reasons (spec section 10)

    var amountReason: String? { lookPartNeutral ? "As filmed has no look to blend" : nil }
    var compareReason: String? { lookPartNeutral && fix == .neutral ? "Nothing to compare: the clip is as filmed" : nil }
    func reason(_ slider: ClipLookSlider) -> String? { slider.mutedByMono && controls.look == .bw ? "No effect on black and white" : nil }
    func tick(_ slider: ClipLookSlider) -> Int { slider.value(of: origin) }
    func resetReason(_ group: ClipLookGroup) -> String? {
        group.sliders.allSatisfy { $0.value(controls) == tick($0) } ? "Nothing to reset" : nil
    }
    /// Back to {look} shows while the clip has a look to go back to.
    var backToLabel: String? { origin.map { "Back to \($0.label)" } }
    var backToReason: String? {
        guard case .applied(let look) = match, look.id != Self.original else { return nil }
        return "Matches \(look.label)"
    }
    var clearReason: String? {
        controls.look == .original && controls.colorAdjustments == nil && controls.colorGrade == nil ? "Nothing to clear" : nil
    }
    /// The look's data-only curve or split tone, which the toning row keeps visible and removable.
    var hasToning: Bool { controls.colorGrade?.curve != nil || controls.colorGrade?.splitTone != nil }
    var toningText: String {
        let parts = [controls.colorGrade?.curve != nil ? "curve" : nil, controls.colorGrade?.splitTone != nil ? "split tone" : nil].compactMap { $0 }
        let from = origin.map { "Toning from \($0.label)" } ?? "Toning"
        return "\(from) \u{00B7} \(parts.joined(separator: " and "))"
    }
    /// Fine-tune opens by itself for Custom and edited looks.
    var opensFineTune: Bool {
        if lookPartNeutral { return false }
        if case .applied = match { return false }
        return true
    }

    // MARK: Claude

    /// The clip's colour with Claude's look as Claude applied it: at its amount, with its Fix when it measured one.
    func claudesState() -> ClipColorState? {
        guard let pick, let look = library.look(pick.look.id.rawValue) else { return nil }
        var expected = controls
        expected.applyLook(look, amount: pick.look.amount, fix: pick.fix)
        return expected.colorState
    }
    /// The Claude line (spec section 9.6): "Claude chose Warm Print · 70% · {reason}" while the clip shows it, else
    /// "Claude's pick: Warm Print · 70%" with Use it.
    var claudeLine: (text: String, useIt: Bool)? {
        guard let pick, let look = library.look(pick.look.id.rawValue), let expected = claudesState() else { return nil }
        let name = pick.look.amount < 100 && look.id != Self.original ? "\(look.label) \u{00B7} \(pick.look.amount)%" : look.label
        if expected == controls.colorState {
            var text = "Claude chose \(name)"
            if !pick.look.reason.isEmpty { text += " \u{00B7} \(pick.look.reason)" }
            if let fix = pick.fix, fix != .neutral { text += (text.hasSuffix(".") ? " " : ". ") + "Fix: \(fix.summary)." }
            return (text, false)
        }
        return ("Claude's pick: \(name)", true)
    }
}

extension ClipLookLibrary {
    /// The app's looks, shared/looks/clip-looks.json; nil when the shared files are missing, which launch reports.
    static let app: ClipLookLibrary? = (try? SharedResources.locate()).flatMap { try? ClipLookLibrary.load(shared: $0) }
}
