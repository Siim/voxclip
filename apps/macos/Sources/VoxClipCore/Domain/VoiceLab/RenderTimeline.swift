/// Tagged timeline for a later native Media consumer. Existing Media requests still use EditPlan.
public enum RenderTimeline: Sendable, Equatable {
    case legacy(EditPlan)
    case voiceLab(VoiceLabOutputPlan)

    public var outputSamples: Int64 {
        switch self { case .legacy(let plan): plan.outputSamples; case .voiceLab(let plan): plan.outputSamples }
    }
    public var sampleRate: Double {
        switch self { case .legacy(let plan): plan.sampleRate; case .voiceLab(let plan): plan.sampleRate }
    }
    public var duration: Double { Double(outputSamples) / sampleRate }
    public func sourceTime(_ edited: Double) -> Double {
        switch self { case .legacy(let plan): plan.sourceTime(edited); case .voiceLab(let plan): plan.sourceTime(edited) }
    }
    public func mapTime(_ source: Double) -> Double {
        switch self { case .legacy(let plan): plan.mapTime(source); case .voiceLab(let plan): plan.mapTime(source) }
    }
}
