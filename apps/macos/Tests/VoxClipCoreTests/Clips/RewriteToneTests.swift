import Foundation
import Testing
@testable import VoxClipCore

/// Rewrite tones (design.md §6.3.1 and §6.6): the shared catalogue, the user's saved tones in settings `rewrite.myTones`,
/// and the clip style's `tone`, stored only when it is not Auto.
@Suite struct RewriteToneTests {
    static func shared() throws -> SharedResources { SharedResources(root: try FixtureLoader.sharedRoot()) }

    @Test func theCatalogueHasTheApprovedTonesWithSpeakableInstructions() throws {
        let catalog = try RewriteToneCatalog.load(shared: Self.shared())
        #expect(catalog.tones.map(\.chipTitle) == ["✦ Viral YouTuber", "Punchy Reel", "Storyteller", "Clear explainer", "LinkedIn pro", "Funny",
                                                   "Hype launch", "Calm & sincere"])
        #expect(catalog.auto == .init(label: "Auto", detail: "Claude picks per clip"))
        #expect(catalog.asSaid == .init(label: "As I said it", detail: "no tone change"))
        for tone in catalog.tones {
            #expect(tone.instruction.utf8.count <= catalog.maxInstructionBytes)
            #expect(tone.instruction.hasSuffix("Keep my facts, names, numbers and meaning, and keep my voice. Every line must be speakable as is: no emoji, hashtags, links or stage directions."))
            #expect(!tone.instruction.contains("#") && !tone.instruction.contains("[") && !tone.isSaved)
            // It fits Rewrite's instruction (PatchRewriteRequest.instruction, voice-lab.md §8.1).
            #expect(tone.instruction.utf8.count <= 1_000)
        }
        #expect(catalog.tone(matching: "  " + catalog.tones[2].instruction + "\n") == catalog.tones[2])
        #expect(catalog.tone(matching: catalog.tones[2].instruction + " Shorter.") == nil)
    }

    @Test func aBrokenCatalogueIsRefused() throws {
        let data = try Data(contentsOf: Self.shared().root.appendingPathComponent(RewriteToneCatalog.path))
        guard case .object(var document) = try JSONDecoder().decode(JSONValue.self, from: data), case .array(var tones) = document["tones"],
              case .object(var first) = tones[0] else { Issue.record("not an object"); return }
        for id in ["as-said", "my-viral", "Viral"] {
            first["id"] = .string(id); tones[0] = .object(first); document["tones"] = .array(tones)
            #expect(throws: VoxClipError.self) { try RewriteToneCatalog.parse(JSONEncoder().encode(JSONValue.object(document))) }
        }
    }

    @Test func savingRenamingAndDeletingTonesKeepIDsStable() throws {
        var (tones, tone) = try MyRewriteTones.saving("My pitch voice", instruction: " Sound like my pitch. ", to: [])
        #expect(tone == RewriteTone(id: "my-my-pitch-voice", title: "My pitch voice", instruction: "Sound like my pitch."))
        (tones, tone) = try MyRewriteTones.saving("Café talk!", instruction: "Relaxed.", to: tones)
        #expect(tone.id == "my-cafe-talk")
        (tones, tone) = try MyRewriteTones.saving("Café talk", instruction: "Relaxed again.", to: tones)
        #expect(tone.id == "my-cafe-talk-2")
        #expect(throws: VoiceLabError.self) { try MyRewriteTones.saving("  ", instruction: "x", to: tones) }
        #expect(throws: VoiceLabError.self) { try MyRewriteTones.saving("Long", instruction: String(repeating: "é", count: 501), to: tones) }
        #expect(throws: VoiceLabError.self) { try MyRewriteTones.saving("Full", instruction: "x", to: tones, limit: 3) }
        tones = try MyRewriteTones.renaming("my-cafe-talk", to: " Coffee chat ", in: tones)
        #expect(tones[1].id == "my-cafe-talk" && tones[1].title == "Coffee chat")
        #expect(throws: VoiceLabError.self) { try MyRewriteTones.renaming("my-nope", to: "X", in: tones) }
        tones = MyRewriteTones.deleting("my-my-pitch-voice", from: tones)
        #expect(tones.map(\.id) == ["my-cafe-talk", "my-cafe-talk-2"])
        // The settings value round-trips and passes settings validation; a broken entry is refused there and skipped on read.
        let value = MyRewriteTones.encode(tones)
        #expect(MyRewriteTones.decode(value) == tones)
        var settings = SettingsDocument()
        settings.values[RewriteToneCatalog.settingsKey] = value
        try settings.validate()
        #expect(SettingsDocument.isKnownKey(RewriteToneCatalog.settingsKey))
        let broken: JSONValue = .array([.object(["id": .string("viral"), "title": .string("V"), "instruction": .string("x")])])
        settings.values[RewriteToneCatalog.settingsKey] = broken
        #expect(throws: VoxClipError.self) { try settings.validate() }
        #expect(MyRewriteTones.decode(broken).isEmpty)
    }

    @Test func theClipStyleStoresAToneOnlyWhenItIsNotAuto() throws {
        let catalog = try ClipStyleCatalog.load(shared: Self.shared())
        let auto = catalog.preset(.auto).style
        #expect(auto.tone == .auto)
        let plain = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(auto))
        #expect(plain[ai: "tone"] == .null)
        for tone in [ClipTone.asSaid, .tone("viral-youtuber"), .tone("my-pitch-voice")] {
            var style = auto
            style.tone = tone
            let data = try JSONEncoder().encode(style)
            #expect(try JSONDecoder().decode(JSONValue.self, from: data)[ai: "tone"].aiString == tone.raw)
            #expect(try JSONDecoder().decode(ClipStyle.self, from: data) == style)
            #expect(style.settingsDefault.tone == tone)
        }
        // "auto" is never written, and a tone that is not a slug is refused.
        for bad in ["auto", "Viral YouTuber", ""] {
            guard case .object(var object) = plain else { return }
            object["tone"] = .string(bad)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ClipStyle.self, from: JSONEncoder().encode(JSONValue.object(object))) }
        }
        // Rewording Off keeps the words: the planner gets As I said it whatever the tone.
        var never = auto
        never.tone = .tone("funny"); never.rewording = .off
        #expect(never.effectiveTone == .asSaid)
        never.rewording = .tighten
        #expect(never.effectiveTone == .tone("funny"))
        // Resolving: a known id, a saved id, and an unknown one (which plans as Auto).
        let tones = try RewriteToneCatalog.load(shared: Self.shared())
        let saved = [RewriteTone(id: "my-pitch-voice", title: "My pitch voice", instruction: "Pitch.")]
        #expect(tones.resolve(.tone("funny"), saved: saved)?.title == "Funny")
        #expect(tones.resolve(.tone("my-pitch-voice"), saved: saved)?.title == "My pitch voice")
        #expect(tones.resolve(.tone("my-gone"), saved: saved) == nil && tones.resolve(.asSaid, saved: saved) == nil)
    }

    @Test func projectsAndSettingsValidateTheTone() throws {
        let catalog = try ClipStyleCatalog.load(shared: Self.shared())
        var style = catalog.preset(.calm).style
        style.tone = .tone("storyteller")
        let data = try JSONEncoder().encode(style)
        guard case .object(var object) = try JSONDecoder().decode(JSONValue.self, from: data) else { return }
        object["captionPicks"] = nil
        var settings = SettingsDocument()
        settings.values["clipStyle.default"] = .object(object)
        try settings.validate()
        object["mood"] = .string("warm")
        settings.values["clipStyle.default"] = .object(object)
        #expect(throws: VoxClipError.self) { try settings.validate() }
        // A project's clipStyle may carry the tone in any schema version.
        let raw = try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/projects/interview-take.voxclip"))
        guard case .object(var project) = raw else { return }
        project["clipStyle"] = try JSONDecoder().decode(JSONValue.self, from: data)
        try ProjectValidation.validate(.object(project))
    }
}
