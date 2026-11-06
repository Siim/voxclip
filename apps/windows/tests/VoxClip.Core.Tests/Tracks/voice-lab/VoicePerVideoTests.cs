using System.Text;
using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>A matching voice for each video (voice-lab.md §6.13, ADR-R45; Mac <c>VoicePerVideoTests</c>): the remembered answer, one video's
/// pieces at the lower cleanliness floor with identity still one hop, the book in app data, and what may be removed. Pure; nothing is
/// sent, and the App does not use any of it yet (the speaker parity gate is closed).</summary>
public sealed class VoicePerVideoTests
{
    private const string One = "11111111-1111-4111-8111-111111111111";
    private const string Two = "22222222-2222-4222-8222-222222222222";
    private const string AnchorId = "6f0c2c1e-8a0e-4c5e-9d1f-0b9d4a7f2e11";

    private static VoiceRebuild.Candidate Piece(string video, int start, int seconds = 15, double snr = 25, double score = 0.9) =>
        new(video, start * 1_000L, (start + seconds) * 1_000L, snr, score, [1, 0]);

    private static VoicePerVideoBook.Video Video(string key, string record) =>
        new(key, record, AnchorId, new string('a', 64), key, "2026-11-06T10:00:00Z", 41, true);

    private static void Validate(string key, string json)
    {
        var settings = new AppSettings("voxclip-settings/1");
        using var value = JsonDocument.Parse(json);
        settings.Values[key] = value.RootElement.Clone();
        SettingsValidation.Validate(settings);
    }

    [Fact]
    public void TheAnswerIsUnsetUntilChosenAndOnlyABooleanOrNullIsStored()
    {
        Assert.Equal(VoicePerVideo.Mode.Ask, VoicePerVideo.FromSetting(null));
        Assert.Equal(VoicePerVideo.Mode.Match, VoicePerVideo.FromSetting(true));
        Assert.Equal(VoicePerVideo.Mode.Anchor, VoicePerVideo.FromSetting(false));
        foreach (var mode in Enum.GetValues<VoicePerVideo.Mode>()) Assert.Equal(mode, VoicePerVideo.FromSetting(VoicePerVideo.ToSetting(mode)));
        Assert.False(AppSettings.Defaults.ContainsKey(VoicePerVideo.SettingKey));
        Assert.True(SettingsValidation.KnownKey(VoicePerVideo.SettingKey));
        foreach (var json in new[] { "true", "false", "null" }) Validate(VoicePerVideo.SettingKey, json);
        Assert.ThrowsAny<JsonException>(() => Validate(VoicePerVideo.SettingKey, "\"yes\""));
        // The rebuild's preference (ADR-R44): a lowercase record UUID or null.
        Assert.True(SettingsValidation.KnownKey(VoiceRebuild.RewriteVoiceKey));
        Validate(VoiceRebuild.RewriteVoiceKey, "\"" + One + "\"");
        Validate(VoiceRebuild.RewriteVoiceKey, "null");
        Assert.ThrowsAny<JsonException>(() => Validate(VoiceRebuild.RewriteVoiceKey, "\"" + AnchorId.ToUpperInvariant() + "\""));
    }

    [Fact]
    public void OneVideosNoisyPiecesCountAtTheLowerFloorButIdentityIsStillOneHop()
    {
        // The DJI car video's shape (ADR-R45): nothing at 20 dB, owner pieces at 8.8–11.3 dB, a noisier owner piece, and a clean-enough
        // piece that isn't the owner one hop from the consent embedding.
        VoiceRebuild.Candidate[] candidates =
        [
            Piece("car", 72, 10, 8.83, 0.47), Piece("car", 83, 17, 8.84, 0.48), Piece("car", 101, 15, 11.31, 0.49),
            Piece("car", 172, 12, 6.70, 0.45), Piece("car", 117, 20, 15.43, 0.40)
        ];
        var clean = VoiceRebuild.Pick(candidates, 0.45, 27_720);
        Assert.True(clean.Pieces.Count == 0 && !clean.Enough, "the rebuild's own 20 dB floor finds nothing");
        var plan = VoiceRebuild.Pick(candidates, 0.45, 27_720, VoicePerVideo.MinimumSnrDb);
        Assert.Equal([72_000L, 83_000, 101_000], plan.Pieces.Select(piece => piece.StartMs).Order());
        Assert.Equal(new Dictionary<VoiceRebuild.Rejection, int> { [VoiceRebuild.Rejection.NotTheOwner] = 1, [VoiceRebuild.Rejection.Noisy] = 1 },
            plan.Rejected.Where(pair => pair.Value > 0).ToDictionary());
        Assert.Equal(42_000, VoicePerVideo.VideoMs(plan));
        Assert.True(VoicePerVideo.VideoMs(plan) >= VoicePerVideo.MinimumVideoMs);
        Assert.True(VoicePerVideo.RemovesBackgroundNoise(plan), "under 20 dB, creation asks ElevenLabs to remove the noise");
        var quiet = VoiceRebuild.Pick([Piece("room", 0, 30, 25), Piece("room", 40, 10, 30)], 0.45, 6_000, VoicePerVideo.MinimumSnrDb);
        Assert.False(VoicePerVideo.RemovesBackgroundNoise(quiet), "clean speech keeps remove_background_noise false (§6.5 step 5)");
        // Too little of the video's own speech: the kept clip alone never makes a video's voice.
        var little = VoiceRebuild.Pick([Piece("car", 0, 12, 9)], 0.45, 27_720, VoicePerVideo.MinimumSnrDb);
        Assert.True(little.Enough);
        Assert.Equal(12_000, VoicePerVideo.VideoMs(little));
        Assert.True(VoicePerVideo.VideoMs(little) < VoicePerVideo.MinimumVideoMs);
    }

    [Fact]
    public void ANewVideosVoiceMakesThePreviousOneARemovalAndTheBookValidates()
    {
        var book = new VoicePerVideoBook().Adding(Video("dji30", One));
        Assert.Equal(One, book.VideoFor("dji30")?.RecordId);
        Assert.Empty(book.Removals);
        book = (book with { ShortNoted = ["kitchen", "dji75"] }).Adding(Video("dji75", Two));
        Assert.Equal(["dji75"], book.Videos.Select(video => video.ContentKey));
        Assert.Equal([One], book.Removals.Select(removal => removal.RecordId));
        Assert.Equal(["kitchen"], book.ShortNoted);
        Assert.True(book.IsVideoVoice(One) && book.IsVideoVoice(Two) && !book.IsVideoVoice(AnchorId));
        book.Validate();
        // The same video again keeps one entry; a removal is never also a current voice.
        Assert.Equal([One], book.Adding(Video("dji75", Two)).Removals.Select(removal => removal.RecordId));
        Assert.Throws<VoiceLabException>(() => (book with { Videos = [book.Videos[0] with { AnchorId = Two }] }).Validate());
        Assert.Throws<VoiceLabException>(() => (book with { Removals = [.. book.Removals, new(Two, "x")] }).Validate());
        Assert.Throws<VoiceLabException>(() => (book with { Videos = [book.Videos[0] with { ContentKey = "../escape" }] }).Validate());
        Assert.Throws<VoiceLabException>(() => (book with { Schema = "other" }).Validate());
        // Diagnostics: one per video, the newest first, merged with what was there.
        var first = book.Measuring(new("dji30", "DJI 30", null, 0.54, "2026-11-06T10:00:00Z"));
        var merged = first.Measuring(new("dji30", "DJI 30", 0.71, null, "2026-11-06T10:05:00Z"));
        var only = Assert.Single(merged.Measurements);
        Assert.Equal((0.71, 0.54), (only.VideoVoice, only.Anchor));
        var many = merged;
        for (var index = 0; index < 20; index++) many = many.Measuring(new("v" + index, "v", 0.5, null, "2026-11-06T10:00:00Z"));
        Assert.Equal(VoicePerVideoBook.MaximumMeasurements, many.Measurements.Count);
        Assert.Equal("v19", many.Measurements[0].ContentKey);
        many.Validate();
    }

    [Fact]
    public async Task TheStoreKeepsTheBookInAppDataAndADamagedFileReadsAsEmpty()
    {
        var root = Directory.CreateTempSubdirectory("voxclip-per-video-").FullName;
        try { await StoreRoundTrip(root); }
        finally { Directory.Delete(root, recursive: true); }
    }

    private static async Task StoreRoundTrip(string data)
    {
        var store = new VoicePerVideoStore(new DataLocations(data, "", "", "", "", "", ""));
        Assert.EndsWith(Path.Combine("VoiceLab", "per-video.json"), store.FilePath, StringComparison.Ordinal);
        Assert.Equal(new VoicePerVideoBook(), await store.LoadAsync());
        var saved = await store.UpdateAsync(book => book.Adding(Video("dji30", One))
            .Measuring(new("dji30", "DJI 30", null, 0.54, "2026-11-06T10:00:00Z")) with { Removals = [new(Two, "old", 2, "Network", "2026-11-06T11:00:00Z")] });
        Assert.Equal(saved, await store.LoadAsync());
        var text = await File.ReadAllTextAsync(store.FilePath);
        // The Mac's encoder: sorted keys at every level, absent optionals omitted.
        using (var document = JsonDocument.Parse(text))
        {
            var root = document.RootElement;
            Assert.Equal(["measurements", "removals", "schema", "shortNoted", "videos"], root.EnumerateObject().Select(property => property.Name));
            Assert.Equal(["anchorId", "anchorReferenceSha256", "contentKey", "createdAt", "recordId", "removesBackgroundNoise", "title", "videoSeconds"],
                root.GetProperty("videos")[0].EnumerateObject().Select(property => property.Name));
            Assert.Equal(["anchor", "contentKey", "measuredAt", "title"], root.GetProperty("measurements")[0].EnumerateObject().Select(property => property.Name));
            Assert.Equal(["attempts", "lastError", "nextAttemptAt", "recordId", "title"], root.GetProperty("removals")[0].EnumerateObject().Select(property => property.Name));
        }
        Assert.DoesNotContain("absolutePath", text, StringComparison.Ordinal);
        if (!OperatingSystem.IsWindows())
        {
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute, File.GetUnixFileMode(Path.GetDirectoryName(store.FilePath)!));
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(store.FilePath));
        }
        // The Mac writes the same document with escaped slashes; it reads back the same.
        await File.WriteAllTextAsync(store.FilePath, text.Replace("voxclip-voice-per-video/1", "voxclip-voice-per-video\\/1", StringComparison.Ordinal), Encoding.UTF8);
        Assert.Equal(saved, await store.LoadAsync());
        await File.WriteAllTextAsync(store.FilePath, "{\"schema\":\"other\"}");
        Assert.Equal(new VoicePerVideoBook(), await store.LoadAsync());
        await File.WriteAllTextAsync(store.FilePath, "{\"schema\":\"voxclip-voice-per-video/1\",\"videos\":[]}");
        Assert.Equal(new VoicePerVideoBook(), await store.LoadAsync());
        await Assert.ThrowsAsync<VoiceLabException>(() => store.SaveAsync(new VoicePerVideoBook { ShortNoted = ["no spaces allowed"] }));
    }

    [Fact]
    public void NeverTheAnchorTheCurrentVoiceOrOneWithPendingTakes()
    {
        Assert.Equal(VoicePerVideo.Keep.Anchor, VoicePerVideo.Kept(AnchorId, AnchorId, Two, new HashSet<string>()));
        Assert.Equal(VoicePerVideo.Keep.Current, VoicePerVideo.Kept(Two, AnchorId, Two, new HashSet<string>()));
        Assert.Equal(VoicePerVideo.Keep.PendingTakes, VoicePerVideo.Kept(One, AnchorId, Two, new HashSet<string> { One }));
        Assert.Null(VoicePerVideo.Kept(One, AnchorId, Two, new HashSet<string> { Two }));
    }

    [Fact]
    public void TheNameThePriceAndTheSeededCalibration()
    {
        Assert.Equal("siim · DJI_20261014184458_0030_D_1080p", VoicePerVideo.DisplayName("siim", "DJI_20261014184458_0030_D_1080p"));
        var longName = VoicePerVideo.DisplayName("siim", new string('õ', 80) + "\n");
        Assert.Equal(VoicePerVideo.MaximumNameScalars, longName.EnumerateRunes().Count());
        Assert.Equal(longName, VoiceConsentText.DisplayName(longName));
        Assert.Equal("siim · a b", VoicePerVideo.DisplayName("siim", "a\u0007b"));
        Assert.Equal("siim", VoicePerVideo.DisplayName("siim", "  "));
        Assert.Equal("siim · 😀x", VoicePerVideo.DisplayName("siim", "😀x"));
        Assert.Equal("DJI_0030", VoicePerVideo.Title("/Users/x/Desktop/DJI_0030.MP4"));
        Assert.Equal("DJI_0030", VoicePerVideo.Title("C:\\Users\\x\\Videos\\DJI_0030.MP4"));
        var catalog = VoiceLabPriceCatalog.Parse(Encoding.UTF8.GetBytes(FixtureLoader.ReadText("catalog/voice-lab.json")));
        Assert.Equal("free", VoicePerVideo.PriceLabel(catalog));
        Assert.Null(VoicePerVideo.PriceLabel(null));
        var anchor = new VoiceLabVoiceCalibration(AnchorId, new Dictionary<string, IReadOnlyList<VoiceLabRateSample>>
        {
            ["eleven_v4"] = [new("t1", 1.4), new("t2", 1.5)]
        }, seeded: true);
        var seeded = VoicePerVideo.SeededCalibration(anchor, One);
        Assert.Equal(One, seeded.RecordId);
        Assert.True(seeded.Seeded);
        Assert.Equal(anchor.Samples("eleven_v4"), seeded.Samples("eleven_v4"));
        var learned = seeded.Recording("eleven_v4", "t3", 2.0, 1.0);
        Assert.Equal(["t1", "t2", "t3"], learned.Samples("eleven_v4").Select(sample => sample.Id));
    }
}
