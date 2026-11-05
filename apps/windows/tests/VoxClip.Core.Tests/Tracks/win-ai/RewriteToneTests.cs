using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Settings;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>Rewrite tones (design §6.3.1, §6.6): shared/data/rewrite-tones.json, the clip style's optional tone in projects and
/// settings, and the saved tones in settings rewrite.myTones, so Windows opens, validates and saves what the Mac writes. The twin
/// of the Swift RewriteToneTests; the Windows tone UI and planner are owed.</summary>
public sealed class RewriteToneTests
{
    private static string Root => FixtureLoader.SharedRoot;


    private static void Validate(string key, string json)
    {
        using var document = JsonDocument.Parse(json);
        SettingsValidation.Validate(new AppSettings("voxclip-settings/1") { Values = new() { [key] = document.RootElement.Clone() } });
    }

    [Fact]
    public void TheCatalogueLoadsTheApprovedTonesInChipOrder()
    {
        var catalog = RewriteToneCatalog.Load(Root);
        Assert.Equal(["✦ Viral YouTuber", "Punchy Reel", "Storyteller", "Clear explainer", "LinkedIn pro", "Funny", "Hype launch", "Calm & sincere"],
            catalog.Tones.Select(tone => tone.ChipTitle));
        Assert.Equal(new RewriteToneCatalog.Choice("Auto", "Claude picks per clip"), catalog.Auto);
        Assert.Equal(new RewriteToneCatalog.Choice("As I said it", "no tone change"), catalog.AsSaid);
        Assert.All(catalog.Tones, tone =>
        {
            Assert.True(System.Text.Encoding.UTF8.GetByteCount(tone.Instruction) <= catalog.MaxInstructionBytes);
            Assert.EndsWith("Keep my facts, names, numbers and meaning, and keep my voice. Every line must be speakable as is: no emoji, hashtags, links or stage directions.",
                tone.Instruction, StringComparison.Ordinal);
            Assert.False(tone.IsSaved);
        });
        var saved = new[] { new RewriteTone("my-pitch-voice", "My pitch voice", "", "Pitch.") };
        Assert.Equal("Funny", catalog.Resolve("funny", saved)?.Title);
        Assert.Equal("My pitch voice", catalog.Resolve("my-pitch-voice", saved)?.Title);
        Assert.Null(catalog.Resolve("my-gone", saved));
        Assert.Null(catalog.Resolve("as-said", saved));
        Assert.Null(catalog.Resolve(null, saved));
    }

    [Fact]
    public void ABrokenCatalogueIsRefused()
    {
        var json = File.ReadAllText(Path.Combine(Root, "data", "rewrite-tones.json"));
        foreach (var id in new[] { "as-said", "my-viral", "Viral" })
        {
            var root = JsonNode.Parse(json)!.AsObject();
            root["tones"]![0]!["id"] = id;
            Assert.Throws<VoxClipException>(() => RewriteToneCatalog.Parse(root.ToJsonString()));
        }
    }

    [Fact]
    public void AProjectsToneRoundTripsAndIsOmittedAtAuto()
    {
        var json = File.ReadAllText(Path.Combine(Root, "fixtures", "projects", "interview-take.voxclip"));
        var project = ProjectSerialization.Deserialize(json);
        var styles = ClipStyleCatalog.Load(Root);
        var auto = styles.Find("auto").Style;
        Assert.Null(auto.Tone);
        Assert.DoesNotContain("\"tone\"", ProjectSerialization.Serialize(project with { ClipStyle = auto }), StringComparison.Ordinal);
        foreach (var tone in new[] { "as-said", "viral-youtuber", "my-pitch-voice" })
        {
            var style = auto with { Tone = tone };
            var saved = ProjectSerialization.Serialize(project with { ClipStyle = style });
            Assert.Contains($"\"tone\": \"{tone}\"", saved, StringComparison.Ordinal);
            var reopened = ProjectSerialization.Deserialize(saved);
            Assert.True(style.SameAs(reopened.ClipStyle));
            Assert.Equal(tone, reopened.ClipStyle!.SettingsDefault.Tone);
        }
        foreach (var bad in new[] { "auto", "Viral YouTuber", "" })
        {
            var root = JsonNode.Parse(ProjectSerialization.Serialize(project with { ClipStyle = auto }))!.AsObject();
            root["clipStyle"]!["tone"] = bad;
            Assert.ThrowsAny<Exception>(() => ProjectSerialization.Deserialize(root.ToJsonString()));
        }
        // Rewording Off keeps the words: the planner gets As I said it whatever the tone.
        Assert.Equal("as-said", (auto with { Tone = "funny", Rewording = "off" }).EffectiveTone);
        Assert.Equal("funny", (auto with { Tone = "funny", Rewording = "tighten" }).EffectiveTone);
    }

    [Fact]
    public void SettingsAcceptTheDefaultsToneAndTheSavedTones()
    {
        Validate("clipStyle.default", "{\"preset\":\"mine\",\"captions\":\"glow\",\"music\":\"auto\",\"maxLengthSec\":90,\"shapes\":[\"16:9\"],\"rewording\":\"fix-only\",\"tone\":\"storyteller\"}");
        Assert.ThrowsAny<JsonException>(() => Validate("clipStyle.default", "{\"preset\":\"mine\",\"captions\":\"glow\",\"music\":\"auto\",\"maxLengthSec\":90,\"shapes\":[\"16:9\"],\"rewording\":\"fix-only\",\"tone\":\"auto\"}"));
        Assert.True(SettingsValidation.KnownKey(RewriteToneCatalog.SettingsKey));
        const string saved = "[{\"id\":\"my-pitch-voice\",\"title\":\"My pitch voice\",\"instruction\":\"Sound like my pitch.\"},{\"id\":\"my-cafe-talk\",\"title\":\"Coffee chat\",\"instruction\":\"Relaxed.\"}]";
        Validate(RewriteToneCatalog.SettingsKey, saved);
        using (var document = JsonDocument.Parse(saved))
            Assert.Equal(["my-pitch-voice", "my-cafe-talk"], MyRewriteTones.Decode(document.RootElement).Select(tone => tone.Id));
        foreach (var bad in new[] {
            "[{\"id\":\"viral\",\"title\":\"V\",\"instruction\":\"x\"}]",
            "[{\"id\":\"my-a\",\"title\":\"\",\"instruction\":\"x\"}]",
            "[{\"id\":\"my-a\",\"title\":\"A\",\"instruction\":\"x\"},{\"id\":\"my-a\",\"title\":\"B\",\"instruction\":\"y\"}]",
            "[{\"id\":\"my-a\",\"title\":\"A\",\"instruction\":\"x\",\"extra\":1}]",
            "[{\"id\":\"my-a\",\"title\":\"A\",\"instruction\":\"" + new string('x', 1001) + "\"}]" })
            Assert.ThrowsAny<JsonException>(() => Validate(RewriteToneCatalog.SettingsKey, bad));
        using var broken = JsonDocument.Parse("[{\"id\":\"viral\",\"title\":\"V\",\"instruction\":\"x\"}]");
        Assert.Empty(MyRewriteTones.Decode(broken.RootElement));
    }

    /// <summary>"+ Save as my tone", rename and delete (twin of the Mac <c>MyRewriteTones.saving</c>, <c>renaming</c>, <c>deleting</c>): the id
    /// is "my-" and a folded slug of the title, made unique; a rename keeps the id; the settings value round-trips and validates.</summary>
    [Fact]
    public void SavedTonesAreMadeRenamedAndDeletedAsTheMacDoes()
    {
        var (one, first) = MyRewriteTones.Saving("  Café Pitch!  ", "  Short, warm, confident. ", []);
        Assert.Equal(("my-cafe-pitch", "Café Pitch!", "Short, warm, confident."), (first.Id, first.Title, first.Instruction));
        var (two, second) = MyRewriteTones.Saving("Café pitch", "Another way.", one);
        Assert.Equal("my-cafe-pitch-2", second.Id);
        var (_, empty) = MyRewriteTones.Saving("✦✦", "Only symbols.", []);
        Assert.Equal("my-tone", empty.Id);
        var renamed = MyRewriteTones.Renaming("my-cafe-pitch", "Pitch voice", two);
        Assert.Equal(("my-cafe-pitch", "Pitch voice"), (renamed[0].Id, renamed[0].Title));
        var encoded = MyRewriteTones.Encode(renamed);
        Assert.True(MyRewriteTones.Validates(encoded));
        Assert.Equal(renamed, MyRewriteTones.Decode(encoded));
        Assert.Equal(["my-cafe-pitch-2"], MyRewriteTones.Deleting("my-cafe-pitch", renamed).Select(tone => tone.Id));
        Assert.ThrowsAny<Exception>(() => MyRewriteTones.Saving("", "text", []));
        Assert.ThrowsAny<Exception>(() => MyRewriteTones.Saving(new string('a', 33), "text", []));
        Assert.ThrowsAny<Exception>(() => MyRewriteTones.Saving("Full", "text", two, limit: 2));
        Assert.ThrowsAny<Exception>(() => MyRewriteTones.Renaming("my-missing", "Name", two));
    }
}
