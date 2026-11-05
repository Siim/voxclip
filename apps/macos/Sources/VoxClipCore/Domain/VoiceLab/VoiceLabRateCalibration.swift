import Foundation

/// How real takes of one voice and model run against `VoiceLabPhraseTiming.estimate` (voice-lab §8.2.2, ADR-R41): the
/// measured ÷ estimated ratios, robust to the odd failed take, and the spread that gives an estimate its p80.
///
/// Two layers share these rules. A voice's calibration lives in the app's data folder and travels across projects
/// (`VoiceLab/calibration/<recordId>.json`, `VoiceLabRateCalibrationStore`); a project's own samples
/// (`voiceLab.speakingRateSamples`) refine it within that project. Ratios against an older prior sit under the model's
/// bare ID and are never read: they describe the 1.8 prior.
public enum VoiceLabRateCalibration {
    /// The ratio p80 ÷ p50 observed on 78 real Eleven v4 takes against the current prior, rounded.
    public static let priorSpread = 1.15
    /// A ratio outside these bounds is a failed measurement (a cut-off take, a whisper miss), never a voice's pace.
    public static let ratioBounds: ClosedRange<Double> = 0.25...4
    /// Spreads measured from five or more samples are kept within these bounds.
    public static let spreadBounds: ClosedRange<Double> = 1.05...1.6
    /// A voice keeps its last 30 ratios per model.
    public static let voiceSampleLimit = 30
    /// How many project samples it takes to outweigh the voice's calibration: the voice counts as this many samples.
    public static let voiceWeight = 3

    /// The `speakingRateSamples` key for samples measured against the current prior.
    public static func projectKey(_ modelID: String) -> String { "\(modelID)@prior\(VoiceLabPhraseTiming.priorVersion)" }

    /// The ratios a calibration reads: valid, within bounds, the last `limit`, then with outliers trimmed (more than
    /// three scaled median absolute deviations from the median, once there are five or more).
    public static func robustRatios(_ samples: [VoiceLabRateSample], limit: Int) -> [Double] {
        let recent = samples.map(\.ratio).filter { $0.isFinite && ratioBounds.contains($0) }.suffix(max(0, limit))
        let ratios = Array(recent)
        guard ratios.count >= 5 else { return ratios }
        let center = median(ratios)
        let deviation = median(ratios.map { abs($0 - center) }) * 1.4826
        guard deviation > 0 else { return ratios }
        return ratios.filter { abs($0 - center) <= 3 * deviation }
    }

    /// The median of the robust ratios; 1 below two samples.
    public static func multiplier(_ samples: [VoiceLabRateSample], limit: Int) -> Double {
        let ratios = robustRatios(samples, limit: limit)
        return ratios.count >= 2 ? median(ratios) : 1
    }

    /// p80 ÷ p50 of the robust ratios once there are five or more, within `spreadBounds`; the prior's spread before.
    public static func spread(_ samples: [VoiceLabRateSample], limit: Int = voiceSampleLimit) -> Double {
        let ratios = robustRatios(samples, limit: limit)
        guard ratios.count >= 5 else { return priorSpread }
        let center = median(ratios)
        guard center > 0 else { return priorSpread }
        return min(spreadBounds.upperBound, max(spreadBounds.lowerBound, quantile(ratios, 0.8) / center))
    }

    /// The samples `VoiceLabWordingFit.multiplier(_:)` reads for a phrase: the voice's calibration, weighted as
    /// `voiceWeight` samples of its median, then the project's own samples, newest last. A new project therefore starts
    /// from the voice; its own takes outweigh the voice once there are four of them.
    public static func samples(project: [VoiceLabRateSample], voice: [VoiceLabRateSample]) -> [VoiceLabRateSample] {
        let ratios = robustRatios(voice, limit: voiceSampleLimit)
        guard ratios.count >= 2 else { return project }
        let center = median(ratios)
        let seeded = (1...voiceWeight).map { VoiceLabRateSample(id: "voice-\($0)", ratio: center) }
        return seeded + project
    }

    /// A project's samples for `modelID` against the current prior, after its voice's calibration.
    public static func samples(project: Project, model modelID: String, voice: VoiceLabVoiceCalibration?) -> [VoiceLabRateSample] {
        samples(project: project.voiceLab.speakingRateSamples?[projectKey(modelID)] ?? [], voice: voice?.samples(modelID) ?? [])
    }

    /// The spread for a project's phrase with `modelID`.
    public static func spread(project: Project, model modelID: String, voice: VoiceLabVoiceCalibration?) -> Double {
        spread(project: project.voiceLab.speakingRateSamples?[projectKey(modelID)] ?? [], voice: voice?.samples(modelID) ?? [])
    }

    /// The spread for a phrase: the project's own once it has five samples, else the voice's, else the prior's.
    public static func spread(project: [VoiceLabRateSample], voice: [VoiceLabRateSample]) -> Double {
        robustRatios(project, limit: VoiceLabWordingFit.projectSampleLimit).count >= 5
            ? spread(project, limit: VoiceLabWordingFit.projectSampleLimit) : spread(voice)
    }

    /// The duration four takes in five stay within, from a median estimate.
    public static func p80(seconds: Double, spread: Double = priorSpread) -> Double { seconds * spread }

    static func median(_ values: [Double]) -> Double { quantile(values, 0.5) }

    /// Linear interpolation between order statistics (the "type 7" quantile).
    static func quantile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard let first = sorted.first else { return .nan }
        guard sorted.count > 1 else { return first }
        let position = Double(sorted.count - 1) * p
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}

/// One voice's calibration across projects: per model, its last 30 measured ÷ estimated ratios against the current
/// prior. Stored as `VoiceLab/calibration/<recordId>.json`; ratios against another prior are dropped when read.
public struct VoiceLabVoiceCalibration: Codable, Sendable, Equatable {
    public static let schema = "voxclip-voice-rate-calibration/1"
    public var schema: String
    public var recordId: String
    public var prior: Int
    public var models: [String: [VoiceLabRateSample]]
    /// Set once the takes the app already had were measured (or found to need no measuring).
    public var seeded: Bool

    public init(recordId: String, models: [String: [VoiceLabRateSample]] = [:], seeded: Bool = false) {
        self.schema = Self.schema; self.recordId = recordId; self.prior = VoiceLabPhraseTiming.priorVersion
        self.models = models; self.seeded = seeded
    }

    public func samples(_ modelID: String) -> [VoiceLabRateSample] { models[modelID] ?? [] }

    /// Adds one take's ratio for `modelID`. A take counts once; an invalid or out-of-bounds ratio is not kept.
    public func recording(_ modelID: String, id: String, measured: Double, estimated: Double) -> VoiceLabVoiceCalibration {
        guard !modelID.isEmpty, measured.isFinite, estimated.isFinite, measured > 0, estimated > 0 else { return self }
        let ratio = measured / estimated
        let previous = samples(modelID)
        guard ratio.isFinite, VoiceLabRateCalibration.ratioBounds.contains(ratio), !previous.contains(where: { $0.id == id }) else { return self }
        var next = self
        next.models[modelID] = Array((previous + [VoiceLabRateSample(id: id, ratio: ratio)]).suffix(VoiceLabRateCalibration.voiceSampleLimit))
        return next
    }

    /// A stored calibration as this build reads it: the right schema and record, and only ratios against this prior.
    public static func decode(_ data: Data, recordId: String) throws -> VoiceLabVoiceCalibration {
        let decoded = try JSONDecoder().decode(VoiceLabVoiceCalibration.self, from: data)
        guard decoded.schema == schema, decoded.recordId == recordId else { throw VoiceLabLengthBudgetError.invalidInput }
        guard decoded.prior == VoiceLabPhraseTiming.priorVersion else { return VoiceLabVoiceCalibration(recordId: recordId) }
        var clean = decoded
        clean.models = decoded.models.filter { !$0.key.isEmpty }.mapValues { samples in
            Array(samples.filter { !$0.id.isEmpty && $0.ratio.isFinite && VoiceLabRateCalibration.ratioBounds.contains($0.ratio) }
                .suffix(VoiceLabRateCalibration.voiceSampleLimit))
        }
        return clean
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
