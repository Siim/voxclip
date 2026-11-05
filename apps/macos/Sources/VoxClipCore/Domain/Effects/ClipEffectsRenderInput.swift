import Foundation

/// The effects a preview or export draws and mixes (ai.md §18.5): the scope's effects (`ClipEffects.rendered`) and the
/// file each sound effect plays. Nil on a request keeps the render exactly as before.
public struct ClipEffectsRenderInput: Sendable, Equatable {
    public let effects: [ClipEffect]
    /// The audio file of each `sound` effect, by effect id: `shared/data/sfx/<id>.wav` or the library clip in the data folder.
    public let soundURLs: [String: URL]

    public init(effects: [ClipEffect], soundURLs: [String: URL]) { self.effects = effects; self.soundURLs = soundURLs }

    /// `<data folder>/SFX`, holding one folder per project id.
    public static func soundRoot(dataRoot: URL) -> URL { dataRoot.appendingPathComponent("SFX", isDirectory: true) }

    public static func bundledSoundURL(_ id: String, shared: SharedResources) -> URL {
        shared.root.appendingPathComponent("data/sfx/\(id).wav", isDirectory: false)
    }

    /// The input for a clip's render (nil: the full video's), or nil when nothing renders there.
    public static func resolve(project: Project, clipID: String?, dataRoot: URL, shared: SharedResources?) -> ClipEffectsRenderInput? {
        let effects = ClipEffects.rendered(in: project, clipID: clipID)
        guard !effects.isEmpty else { return nil }
        var urls: [String: URL] = [:]
        for effect in effects where effect.kind == .sound {
            guard let sound = effect.sound else { continue }
            switch sound.source {
            case .bundled: if let shared, let id = sound.id { urls[effect.id] = bundledSoundURL(id, shared: shared) }
            case .library: if let file = sound.file { urls[effect.id] = soundRoot(dataRoot: dataRoot).appendingPathComponent(file, isDirectory: false) }
            }
        }
        return ClipEffectsRenderInput(effects: effects, soundURLs: urls)
    }

    /// Picture effects: everything but bleeps, mutes and sounds.
    public var picture: [ClipEffect] { effects.filter { ![.bleep, .mute, .sound].contains($0.kind) } }
    /// Audio effects: bleeps, mutes and sounds.
    public var audio: [ClipEffect] { effects.filter { [.bleep, .mute, .sound].contains($0.kind) } }
    public var freezes: [ClipEffect] { effects.filter { $0.kind == .freeze } }

    /// The same input without its sound effects, for renders that read the voice alone (the edited-audio export, duration
    /// probes). Bleeps and mutes stay: they silence the voice itself, so the edited audio is censored like the video.
    public var withoutAudio: ClipEffectsRenderInput? {
        let kept = effects.filter { $0.kind != .sound }
        return kept.isEmpty ? nil : ClipEffectsRenderInput(effects: kept, soundURLs: [:])
    }

    /// The source time the picture shows at source time `time`: a freeze's start while it holds, else `time`.
    public func pictureTime(_ time: Double) -> Double {
        freezes.first { time >= $0.start && time < $0.end }?.start ?? time
    }
}
