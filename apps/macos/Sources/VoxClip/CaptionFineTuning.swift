import Foundation
import VoxClipCore

enum CaptionFineTuning {
    static func value(_ settings: CaptionSettings, group: String, key: String) -> JSONValue? {
        guard case .object(let object) = settings.overrides[group] else { return nil }
        return object[key]
    }

    static func set(_ settings: inout CaptionSettings, group: String, key: String, value: JSONValue?) {
        var object: [String: JSONValue] = [:]
        if case .object(let existing) = settings.overrides[group] { object = existing }
        object[key] = value
        settings.overrides[group] = object.isEmpty ? nil : .object(object)
    }

    static func size(_ settings: inout CaptionSettings, scale: Double) {
        set(&settings, group: "font", key: "sizeScale", value: scale == 1 ? nil : .number(scale))
    }

    static func words(_ settings: inout CaptionSettings, count: Int) {
        set(&settings, group: "layout", key: "maxWords", value: count == 0 ? nil : .number(Double(count)))
        set(&settings, group: "layout", key: "maxLines", value: count == 0 ? nil : .number(1))
    }

    static func position(_ settings: inout CaptionSettings, aspect: AspectRatio, point: CaptionPosition?) {
        if aspect == .source { settings.position = point }
        else { settings.positionByAspect[aspect.rawValue] = point }
    }

    static func reset(_ settings: inout CaptionSettings) {
        settings.overrides = [:]
        settings.position = nil
        settings.positionByAspect = [:]
    }
}
