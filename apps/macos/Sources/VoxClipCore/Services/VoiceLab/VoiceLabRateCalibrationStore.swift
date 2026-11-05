import Foundation

/// Each voice's speaking-rate calibration across projects (ADR-R43): one JSON file per consent record in
/// `VoiceLab/calibration/`, beside the consent records and never inside a project. A missing or unreadable file reads as
/// an empty calibration; the next measured take writes a clean one.
public actor VoiceLabRateCalibrationStore {
    public nonisolated let root: URL

    public init(locations: DataLocations) {
        root = locations.root.appendingPathComponent("VoiceLab/calibration", isDirectory: true)
    }

    public init(root: URL) { self.root = root }

    /// A consent record ID is a file name here: letters, digits, `-` and `_`, 1 to 128 of them.
    public nonisolated static func isValid(recordId: String) -> Bool {
        !recordId.isEmpty && recordId.count <= 128 && recordId.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    public func load(_ recordId: String) -> VoiceLabVoiceCalibration {
        guard Self.isValid(recordId: recordId), let data = try? Data(contentsOf: url(recordId)),
              let decoded = try? VoiceLabVoiceCalibration.decode(data, recordId: recordId) else {
            return VoiceLabVoiceCalibration(recordId: recordId)
        }
        return decoded
    }

    /// Every stored voice's calibration, keyed by consent record ID.
    public func all() -> [String: VoiceLabVoiceCalibration] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var result: [String: VoiceLabVoiceCalibration] = [:]
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard Self.isValid(recordId: id) else { continue }
            result[id] = load(id)
        }
        return result
    }

    /// Adds one measured take; returns the voice's calibration as stored.
    @discardableResult
    public func record(_ recordId: String, model: String, take: String, measured: Double, estimated: Double) throws -> VoiceLabVoiceCalibration {
        let current = load(recordId)
        let next = current.recording(model, id: take, measured: measured, estimated: estimated)
        if next != current { try save(next) }
        return next
    }

    public func save(_ calibration: VoiceLabVoiceCalibration) throws {
        guard Self.isValid(recordId: calibration.recordId) else { throw VoiceLabLengthBudgetError.invalidInput }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try calibration.encoded().write(to: url(calibration.recordId), options: [.atomic])
    }

    private func url(_ recordId: String) -> URL { root.appendingPathComponent("\(recordId).json") }
}
