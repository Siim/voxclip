/// The ElevenLabs Scribe model every new request sends; transcription §8.
/// It must equal `shared/catalog/transcription-models.json` (elevenlabs `modelId`) and the speechToText `model`
/// in `shared/catalog/voice-lab.json`; `ElevenLabsScribeModelTests` fails when they drift.
public enum ElevenLabsScribe {
    public static let modelID = "scribe_v3"
    /// Models older projects, caches and remembered plans may name. They are read as recorded, never sent again.
    public static let legacyModelIDs: Set<String> = ["scribe_v2"]
    /// Plans that name no model, the current one or a legacy one all run on the current model.
    public static func accepts(_ model: String?) -> Bool { model.map { $0 == modelID || legacyModelIDs.contains($0) } ?? true }
    public static let modelRequiredMessage = "ElevenLabs requires the \(modelID) model"
}
