import Foundation

/// One of the looks in `shared/looks/clip-looks.json` (looks spec §4.1): a base `ClipLook` with adjustments and a grade.
/// A preset never sets the Fix. Its values are frozen once shipped; a retune ships under a new ID and the old entry stays
/// `hidden`, so a clip whose `preset` names it still shows its name.
public struct ClipLookPreset: Sendable, Equatable, Identifiable {
    public enum Strength: String, Sendable { case light, medium, strong }

    public let id: String
    public let label: String
    public let category: String
    /// Planner guidance: how far the look moves a picture.
    public let strength: Strength
    /// The one-line look, for help, VoiceOver and the planner prompt.
    public let line: String
    /// When the planner picks it, and the amount it starts at on a face; a hand pick starts at 100.
    public let pickWhen: String
    public let plannerAmount: Int
    /// One of the eight looks projects already used before the library (their values never move).
    public let classic: Bool
    public let hidden: Bool
    public let base: ClipLook
    /// Nil when neutral, as `ProjectClipControls.colorAdjustments` stores it.
    public let adjustments: ClipColorAdjustments?
    /// The look's own grade values: no Fix, no preset, full amount.
    public let grade: ClipColorGrade
}

public struct ClipLookCategory: Sendable, Equatable {
    public let id: String
    public let label: String
}

/// How a clip's colour state reads against the library (spec §8.3): a look applied as it is, or edited from it.
public enum ClipLookMatch: Sendable, Equatable {
    case applied(ClipLookPreset)
    case edited(ClipLookPreset)

    public var look: ClipLookPreset {
        switch self {
        case .applied(let look), .edited(let look): look
        }
    }
}

/// `shared/looks/clip-looks.json` (`voxclip-clip-looks/1`), read whole and checked: the looks in display order, their
/// categories, and the shared light and Auto thresholds (`measure`). A broken file is `sharedResourcesMissing`.
public struct ClipLookLibrary: Sendable, Equatable {
    public static let path = "looks/clip-looks.json"
    public static let format = "voxclip-clip-looks/1"

    public let categories: [ClipLookCategory]
    /// Every look in display order, hidden ones included.
    public let looks: [ClipLookPreset]
    /// The shared numbers for Auto and the planner's light notes.
    public let measure: ClipColorMeasure

    /// The looks a picker offers.
    public var visible: [ClipLookPreset] { looks.filter { !$0.hidden } }

    public func look(_ id: String) -> ClipLookPreset? { looks.first { $0.id == id } }

    public static func load(shared: SharedResources) throws -> ClipLookLibrary {
        // The literal path lets the release test see that bundle.sh ships shared/looks.
        try parse(Data(contentsOf: shared.root.appendingPathComponent("looks/clip-looks.json")))
    }

    public static func parse(_ data: Data) throws -> ClipLookLibrary {
        guard let document = try? JSONDecoder().decode(JSONValue.self, from: data), let library = read(document) else {
            throw VoxClipError.sharedResourcesMissing
        }
        return library
    }

    /// The label/ID rule: for every look but As filmed, the label with case and non-letters dropped is the ID with case
    /// dropped ("Teal & Amber" is `tealAmber`), the key the planner validator compares names by.
    static func key(_ text: String) -> String { text.lowercased().filter(\.isLetter) }

    private static func read(_ document: JSONValue) -> ClipLookLibrary? {
        guard case .object(let root) = document, Set(root.keys) == ["format", "categories", "measure", "looks"],
              root["format"] == .string(format) else { return nil }
        var categories: [ClipLookCategory] = []
        for item in root["categories"]?.aiArray ?? [] {
            guard case .object(let fields) = item, Set(fields.keys) == ["id", "label"], let id = fields["id"]?.aiString, !id.isEmpty,
                  let label = fields["label"]?.aiString, !label.isEmpty, !categories.contains(where: { $0.id == id }) else { return nil }
            categories.append(ClipLookCategory(id: id, label: label))
        }
        var numbersByGroup: [String: [String: Double]] = [:]
        guard !categories.isEmpty, case .object(let groups) = root["measure"], Set(groups.keys) == ["auto", "light"] else { return nil }
        for (name, group) in groups {
            guard case .object(let values) = group, !values.isEmpty else { return nil }
            var numbers: [String: Double] = [:]
            for (key, value) in values {
                guard case .number(let number) = value, number.isFinite else { return nil }
                numbers[key] = number
            }
            numbersByGroup[name] = numbers
        }
        guard let measure = ClipColorMeasure(numbersByGroup) else { return nil }
        let required: Set<String> = ["id", "label", "category", "strength", "line", "planner", "classic", "base", "adjustments", "grade"]
        var looks: [ClipLookPreset] = []
        for item in root["looks"]?.aiArray ?? [] {
            guard case .object(let fields) = item, Set(fields.keys).subtracting(["hidden"]) == required,
                  let id = fields["id"]?.aiString, ClipColorGrade.isPresetID(id), !looks.contains(where: { $0.id == id }),
                  let label = fields["label"]?.aiString, !label.isEmpty, id == ClipLook.original.rawValue || key(label) == id.lowercased(),
                  let category = fields["category"]?.aiString, categories.contains(where: { $0.id == category }),
                  let strength = fields["strength"]?.aiString.flatMap(ClipLookPreset.Strength.init(rawValue:)),
                  let line = fields["line"]?.aiString, !line.isEmpty,
                  case .object(let planner) = fields["planner"], Set(planner.keys) == ["pickWhen", "amount"],
                  let pickWhen = planner["pickWhen"]?.aiString, !pickWhen.isEmpty,
                  case .number(let amount) = planner["amount"], amount.rounded() == amount, (0...100).contains(amount),
                  case .bool(let classic) = fields["classic"],
                  let base = fields["base"]?.aiString.flatMap(ClipLook.init(rawValue:)),
                  let adjustments = adjustments(fields["adjustments"]),
                  let grade = fields["grade"].flatMap({ ClipColorGrade.read($0, look: true) }) else { return nil }
            var hidden = false
            if let flag = fields["hidden"] {
                guard case .bool(let value) = flag else { return nil }
                hidden = value
            }
            looks.append(ClipLookPreset(id: id, label: label, category: category, strength: strength, line: line, pickWhen: pickWhen,
                                        plannerAmount: Int(amount), classic: classic, hidden: hidden, base: base,
                                        adjustments: adjustments == .neutral ? nil : adjustments, grade: grade))
        }
        guard !looks.isEmpty, looks.contains(where: { $0.id == ClipLook.original.rawValue && !$0.hidden }) else { return nil }
        return ClipLookLibrary(categories: categories, looks: looks, measure: measure)
    }

    /// A look's `adjustments`: today's four keys, a missing one meaning 0.
    private static func adjustments(_ value: JSONValue?) -> ClipColorAdjustments? {
        guard case .object(let fields) = value,
              Set(fields.keys).isSubset(of: Set(ClipColorAdjustments.Control.allCases.map(\.rawValue))) else { return nil }
        var adjustments = ClipColorAdjustments.neutral
        for control in ClipColorAdjustments.Control.allCases {
            guard let raw = fields[control.rawValue] else { continue }
            guard case .number(let point) = raw, point.rounded() == point,
                  (Double(ClipColorAdjustments.range.lowerBound)...Double(ClipColorAdjustments.range.upperBound)).contains(point) else { return nil }
            adjustments[control] = Int(point)
        }
        return adjustments
    }

    /// The tile a clip's colour state shows as applied or edited (spec §8.3). A look is applied when the clip's `look`,
    /// `colorAdjustments` and `colorGrade` equal its base, adjustments and grade, leaving out the amount, the preset and
    /// the Fix. A clip whose `preset` names a look with other values has that look edited; a preset this build doesn't
    /// know, or values no look has, is nil ("Custom").
    public func match(_ controls: ProjectClipControls) -> ClipLookMatch? {
        let values = controls.colorGrade?.lookValues ?? .neutral
        func holds(_ look: ClipLookPreset) -> Bool {
            look.base == controls.look && look.adjustments == controls.colorAdjustments && look.grade == values
        }
        if let named = controls.colorGrade?.preset {
            guard let look = look(named) else { return nil }
            return holds(look) ? .applied(look) : .edited(look)
        }
        return looks.first(where: holds).map(ClipLookMatch.applied)
    }

    /// "Warm Print", "Warm Print, edited" or "Custom".
    public func name(for controls: ProjectClipControls) -> String {
        switch match(controls) {
        case .applied(let look): look.label
        case .edited(let look): "\(look.label), edited"
        case nil: "Custom"
        }
    }
}
