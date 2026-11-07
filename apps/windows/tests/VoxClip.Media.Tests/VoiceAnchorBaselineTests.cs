using System.Security.Cryptography;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>The anchor's baseline from its earlier takes (voice-lab.md §6.13 item 9; Mac <c>VoiceAnchorBaseline</c> and the
/// <c>VideoVoiceFlowTests</c> baseline cases): the newest 12 of the anchor's accepted takes across the owner's projects, read only, one project
/// open at a time, each paid file through a hash-checked snapshot. Portable: the takes are synthetic WAVs in a temporary paid store, the
/// source's guard speech is a stub, and the speaker check is a stub that names each take by its length.</summary>
public sealed class VoiceAnchorBaselineTests : IDisposable
{
    private const string Anchor = "6f0c2c1e-8a0e-4c5e-9d1f-0b9d4a7f2e11";
    private const string Other = "7a1d3d2f-9b1f-4d6f-8e2a-1c0e5b8f3f22";
    private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-anchor-baseline-" + Guid.NewGuid().ToString("N"));
    private string PaidRoot => Path.Combine(root, "VoiceLab");
    private string Scratch => Path.Combine(root, "scratch");

    public VoiceAnchorBaselineTests() { Directory.CreateDirectory(PaidRoot); Directory.CreateDirectory(Scratch); }
    public void Dispose() { try { Directory.Delete(root, true); } catch (DirectoryNotFoundException) { } }

    private static Project Template() => ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));

    /// <summary>A take of <paramref name="frames"/> 16 kHz frames (its length names it), accepted on <paramref name="day"/>.</summary>
    private sealed record Take(string Id, int Frames, int Day, string Voice = Anchor, VoiceLabSegmentKind Kind = VoiceLabSegmentKind.Tts,
        bool Enabled = true, bool PaidFile = true);

    private (Project Project, string Media) Make(string name, bool media, params Take[] takes)
    {
        var template = Template();
        var id = Guid.NewGuid().ToString("D");
        var segments = new List<VoiceLabSegment>();
        var assets = new List<VoiceLabAsset>();
        var model = template.VoiceLab.Segments[0];
        foreach (var take in takes)
        {
            var assetId = "asset-" + take.Id;
            var wav = Wave(take.Frames + 1_600);
            var file = id + "/" + assetId + ".wav";
            if (take.PaidFile)
            {
                Directory.CreateDirectory(Path.Combine(PaidRoot, id));
                File.WriteAllBytes(Path.Combine(PaidRoot, file), wav);
            }
            assets.Add(new(assetId, "audio", file, Convert.ToHexStringLower(SHA256.HashData(wav)), (take.Frames + 1_600) / 16_000.0, 16_000,
                DateTimeOffset.UnixEpoch));
            segments.Add(model with
            {
                Id = take.Id, Kind = take.Kind, Enabled = take.Enabled,
                Audio = new(assetId, 0.05, 0.05 + take.Frames / 16_000.0, 1, 0),
                Provenance = model.Provenance with { ConsentRecordId = take.Voice, CreatedAt = new DateTimeOffset(2026, 10, 1, 0, 0, 0, TimeSpan.Zero).AddDays(take.Day) }
            });
        }
        var path = Path.Combine(root, name + ".mp4");
        if (media) File.WriteAllBytes(path, [0, 0, 0, 8, (byte)'f', (byte)'r', (byte)'e', (byte)'e']);
        return (template with { Id = id, VoiceLab = template.VoiceLab with { Segments = segments, Assets = assets } }, path);
    }

    private static byte[] Wave(int frames)
    {
        var bytes = new byte[44 + frames * 2];
        "RIFF"u8.CopyTo(bytes); BitConverter.GetBytes(36 + frames * 2).CopyTo(bytes, 4); "WAVEfmt "u8.CopyTo(bytes.AsSpan(8));
        BitConverter.GetBytes(16).CopyTo(bytes, 16); BitConverter.GetBytes((short)1).CopyTo(bytes, 20); BitConverter.GetBytes((short)1).CopyTo(bytes, 22);
        BitConverter.GetBytes(16_000).CopyTo(bytes, 24); BitConverter.GetBytes(32_000).CopyTo(bytes, 28); BitConverter.GetBytes((short)2).CopyTo(bytes, 32);
        BitConverter.GetBytes((short)16).CopyTo(bytes, 34); "data"u8.CopyTo(bytes.AsSpan(36)); BitConverter.GetBytes(frames * 2).CopyTo(bytes, 40);
        for (var frame = 0; frame < frames; frame++) BitConverter.GetBytes((short)(8_000 * Math.Sin(frame * 0.05))).CopyTo(bytes, 44 + frame * 2);
        return bytes;
    }

    /// <summary>A speaker check that names each take by its length and scores every pair 1.</summary>
    private static VoiceSpeakerProbe Probe(List<int> embedded) => new("speaker-model-1", 0.5, "en", (samples, _) =>
    {
        lock (embedded) embedded.Add(samples.Length);
        return Task.FromResult(new float[] { 1, 0 });
    }, (_, _) => throw new InvalidOperationException());

    /// <summary>The source's guard speech: one second, recognisable by its length.</summary>
    private static Task<float[]> Original(string media, long frames, int rate, VoiceLabGuardSpeech selection, CancellationToken ct)
        => Task.FromResult(new float[16_000]);

    private Dictionary<string, (string Hash, DateTime Written)> Files() => Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
        .ToDictionary(path => path, path => (Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path))), File.GetLastWriteTimeUtc(path)));

    [Fact]
    public async Task TheNewestTwelveOfTheAnchorsTakesAreReadOnlyOneProjectAtATimeAndNothingIsWritten()
    {
        var older = Make("older", true,
            [.. Enumerable.Range(1, 6).Select(day => new Take("a" + day, 100 * day, day)),
             new Take("other-voice", 9_001, 30, Voice: Other), new Take("recorded", 9_002, 30, Kind: VoiceLabSegmentKind.Recorded),
             new Take("turned-off", 9_003, 30, Enabled: false), new Take("unpaid", 9_004, 30, PaidFile: false)]);
        var newer = Make("newer", true, [.. Enumerable.Range(7, 8).Select(day => new Take("b" + day, 100 * day, day))]);
        var gone = Make("gone", false, new Take("c1", 9_005, 40), new Take("c2", 9_006, 41));
        var projects = new Dictionary<string, (Project Project, string Media)> { ["/p/older"] = older, ["/p/newer"] = newer, ["/p/gone"] = gone };
        var before = Files();
        var opened = new List<string>();
        var open = 0; var most = 0;
        var embedded = new List<int>();
        var result = await VoiceAnchorBaseline.MeasureAsync(["/p/older", "/p/newer", "/p/gone"], Anchor, PaidRoot, Probe(embedded), async (path, ct) =>
        {
            var now = Interlocked.Increment(ref open);
            most = Math.Max(most, now);
            opened.Add(path);
            await Task.Yield();
            Interlocked.Decrement(ref open);
            var (project, media) = projects[path];
            return new VoiceAnchorBaseline.Opened(project, media);
        }, Original, scratchRoot: Scratch, ct: TestContext.Current.CancellationToken);
        // 14 of the anchor's takes can be read; the two oldest fall outside the bound. Another voice's, a recorded, a turned-off and an
        // unpaid take, and a project whose video is gone, are never read.
        Assert.Equal(12, result.Scores.Count);
        Assert.Equal(1.0, result.Mean);
        var takes = embedded.Where(length => length != 16_000).Order().ToArray();
        Assert.Equal(Enumerable.Range(3, 12).Select(day => 100 * day), takes);
        // One project open at a time; each listed once, and only the ones holding kept takes reopened.
        Assert.Equal(1, most);
        Assert.Equal(["/p/older", "/p/newer", "/p/gone", "/p/older", "/p/newer"], opened);
        // Read only: every project file, video and paid file is as it was; the private snapshots are gone.
        Assert.Equal(before, Files());
        Assert.Empty(Directory.EnumerateFileSystemEntries(Scratch));
    }

    [Fact]
    public async Task TheBoundAndAnAlteredPaidFile()
    {
        var project = Make("one", true, [.. Enumerable.Range(1, 5).Select(day => new Take("t" + day, 100 * day, day))]);
        // An altered paid file fails its hash check and is skipped silently.
        var altered = project.Project.VoiceLab.Assets!.Single(asset => asset.Id == "asset-t5");
        File.WriteAllBytes(Path.Combine(PaidRoot, altered.File), Wave(10));
        var embedded = new List<int>();
        var result = await VoiceAnchorBaseline.MeasureAsync(["/p/one"], Anchor, PaidRoot, Probe(embedded),
            (_, _) => Task.FromResult<VoiceAnchorBaseline.Opened?>(new(project.Project, project.Media)), Original, maximum: 3, scratchRoot: Scratch,
            ct: TestContext.Current.CancellationToken);
        Assert.Equal([400, 300], embedded.Where(length => length != 16_000));
        Assert.Equal(2, result.Scores.Count);
    }

    [Fact]
    public async Task WithoutASpeakerCheckNothingIsRead()
    {
        var reads = 0;
        var result = await VoiceAnchorBaseline.MeasureAsync(["/p/any"], Anchor, PaidRoot, null, (_, _) =>
        {
            reads++;
            return Task.FromResult<VoiceAnchorBaseline.Opened?>(null);
        }, ct: TestContext.Current.CancellationToken);
        Assert.Empty(result.Scores);
        Assert.Null(result.Mean);
        Assert.Equal(0, reads);
    }
}
