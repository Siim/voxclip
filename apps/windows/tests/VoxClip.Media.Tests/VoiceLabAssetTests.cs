using System.Security.Cryptography;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class VoiceLabAssetTests
{
    private static Project Project() => ProjectSerialization.Deserialize(File.ReadAllText(
        System.IO.Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "passage-project.voxclip")));

    // The Swift test uses the same 24 kHz, mono PCM16, 440 Hz construction.
    private static byte[] Wave(int frames = 24_000, int rate = 24_000)
    {
        using var stream = new MemoryStream(); using var writer = new BinaryWriter(stream);
        writer.Write("RIFF"u8); writer.Write(36 + frames * 2); writer.Write("WAVEfmt "u8); writer.Write(16);
        writer.Write((short)1); writer.Write((short)1); writer.Write(rate); writer.Write(rate * 2);
        writer.Write((short)2); writer.Write((short)16); writer.Write("data"u8); writer.Write(frames * 2);
        for (var index = 0; index < frames; index++)
            writer.Write((short)Math.Round(Math.Sin(2 * Math.PI * 440 * index / rate) * 10_000,
                MidpointRounding.AwayFromZero));
        return stream.ToArray();
    }

    private static (Project project, string root, string file) Setup(byte[]? bytes)
    {
        var project = Project();
        var root = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "voxclip-voice-test-" + Guid.NewGuid().ToString("N"));
        var directory = Directory.CreateDirectory(System.IO.Path.Combine(root, project.Id));
        var file = System.IO.Path.Combine(directory.FullName, "asset-one.wav");
        if (bytes is not null)
        {
            File.WriteAllBytes(file, bytes);
            var assets = project.VoiceLab.Assets!.ToArray();
            assets[0] = assets[0] with { Sha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)) };
            project = project with { VoiceLab = project.VoiceLab with { Assets = assets } };
        }
        return (project, root, file);
    }

    private static async Task<VoiceLabAssetException> Error(VoiceLabAssetErrorCode code, Func<Task> work)
    {
        var failure = await Assert.ThrowsAsync<VoiceLabAssetException>(work);
        Assert.Equal(code, failure.Code);
        return failure;
    }

    [Fact]
    public async Task ResolvesAndKeepsSnapshotAfterPaidFileChanges()
    {
        Assert.Equal("f1b99f5f6d48cdb22577ab3c7aede2aff313f64afbba6897b6352d7868e11981",
            Convert.ToHexStringLower(SHA256.HashData(Wave())));
        var (project, root, file) = Setup(Wave());
        try
        {
            var plan = VoiceLabOutputPlanner.Build(project, VoiceLabOutputScope.Full);
            var disabled = VoiceLabProject.SetEnabled(project, "vl-passage", false);
            Assert.Empty(await VoiceLabAssets.PrepareAsync(disabled,
                VoiceLabOutputPlanner.Build(disabled, VoiceLabOutputScope.Full), root, TestContext.Current.CancellationToken));
            var selected = VoiceLabProject.SelectCandidate(project, "vl-passage", 1);
            await Error(VoiceLabAssetErrorCode.InvalidSelection, () => VoiceLabAssets.PrepareAsync(selected, plan, root));
            var prepared = await VoiceLabAssets.PrepareAsync(project, plan, root, TestContext.Current.CancellationToken);
            using var handle = prepared["vl-passage"];
            Assert.Equal("asset-one", handle.AssetId);
            Assert.Equal(24_000, handle.FrameCount);
            Assert.Equal(24_000, handle.SampleRate);
            Assert.Equal(1, handle.Channels);
            Assert.Equal(0, handle.TrimStartFrame);
            Assert.Equal(24_000, handle.TrimEndFrame);
            Assert.Equal(File.ReadAllBytes(file), File.ReadAllBytes(handle.Path));
            File.WriteAllText(file, "changed");
            Assert.Equal(Wave(), File.ReadAllBytes(handle.Path));
            Assert.True(File.Exists(file));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task ChangedCaptionCorrectionRejectsStalePlanButFreshPlanPrepares()
    {
        var (project, root, file) = Setup(Wave());
        try
        {
            var stale = VoiceLabOutputPlanner.Build(project, VoiceLabOutputScope.Full);
            var corrections = new Dictionary<string, string>(project.Edits.Corrections, StringComparer.Ordinal)
            { ["w1"] = "Well" };
            var changed = project with { Edits = project.Edits with { Corrections = corrections } };
            var fresh = VoiceLabOutputPlanner.Build(changed, VoiceLabOutputScope.Full);
            Assert.Equal(stale.Pieces.ToArray(), fresh.Pieces.ToArray());
            Assert.False(stale.Captions.SequenceEqual(fresh.Captions));
            Assert.Contains(fresh.Captions, caption => caption.Id == "w1" && caption.Text == "Well");
            await Error(VoiceLabAssetErrorCode.InvalidSelection, () => VoiceLabAssets.PrepareAsync(changed, stale, root));
            var prepared = await VoiceLabAssets.PrepareAsync(changed, fresh, root, TestContext.Current.CancellationToken);
            using var handle = prepared["vl-passage"];
            Assert.Equal(File.ReadAllBytes(file), File.ReadAllBytes(handle.Path));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task MissingHashRateDurationAndTrimAreChecked()
    {
        var (project, root, file) = Setup(null);
        try
        {
            var asset = project.VoiceLab.Assets![0]; var audio = project.VoiceLab.Segments[0].Audio;
            await Error(VoiceLabAssetErrorCode.Missing, () => VoiceLabAssets.PrepareAsync(project, asset, audio, "vl-passage", root));
            var bytes = Wave(); File.WriteAllBytes(file, bytes);
            await Error(VoiceLabAssetErrorCode.Altered, () => VoiceLabAssets.PrepareAsync(project, asset, audio, "vl-passage", root));
            var assets = project.VoiceLab.Assets.ToArray();
            assets[0] = asset with { Sha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)), DurationSeconds = 1.1 };
            var changed = project with { VoiceLab = project.VoiceLab with { Assets = assets } };
            await Error(VoiceLabAssetErrorCode.DurationMismatch, () => VoiceLabAssets.PrepareAsync(changed, assets[0], audio, "vl-passage", root));
            assets[0] = assets[0] with { DurationSeconds = 1, SampleRate = 44_100 };
            changed = project with { VoiceLab = project.VoiceLab with { Assets = assets } };
            await Error(VoiceLabAssetErrorCode.RateMismatch, () => VoiceLabAssets.PrepareAsync(changed, assets[0], audio, "vl-passage", root));
            assets[0] = assets[0] with { SampleRate = 24_000 };
            var shortWave = Wave(23_999); File.WriteAllBytes(file, shortWave);
            assets[0] = assets[0] with { Sha256 = Convert.ToHexStringLower(SHA256.HashData(shortWave)) };
            changed = project with { VoiceLab = project.VoiceLab with { Assets = assets } };
            await Error(VoiceLabAssetErrorCode.InvalidTrim, () => VoiceLabAssets.PrepareAsync(changed, assets[0], audio, "vl-passage", root));
            File.WriteAllBytes(file, bytes);
            assets[0] = assets[0] with { Sha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)) };
            var segment = project.VoiceLab.Segments[0];
            var trim = segment.Audio with { TrimStart = 0.00002, Stretch = 1 / (1 - 0.00002) };
            segment = segment with { Audio = trim };
            changed = project with { VoiceLab = project.VoiceLab with { Assets = assets, Segments = [segment] } };
            using var handle = await VoiceLabAssets.PrepareAsync(changed, assets[0], trim, "vl-passage", root, TestContext.Current.CancellationToken);
            Assert.Equal(0, handle.TrimStartFrame);
            Assert.Equal(24_000, handle.TrimEndFrame);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task SymlinkAndUnsupportedAudioAreRejectedWithoutDeletion()
    {
        var (project, root, file) = Setup(null);
        var outside = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "voxclip-outside-" + Guid.NewGuid().ToString("N") + ".wav");
        try
        {
            File.WriteAllBytes(outside, Wave());
            File.CreateSymbolicLink(file, outside);
            var asset = project.VoiceLab.Assets![0]; var audio = project.VoiceLab.Segments[0].Audio;
            await Error(VoiceLabAssetErrorCode.UnsafePath, () => VoiceLabAssets.PrepareAsync(project, asset, audio, "vl-passage", root));
            File.Delete(file); File.WriteAllText(file, "RIFFbad");
            var assets = project.VoiceLab.Assets.ToArray();
            assets[0] = asset with { Sha256 = Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(file))) };
            var changed = project with { VoiceLab = project.VoiceLab with { Assets = assets } };
            await Error(VoiceLabAssetErrorCode.InvalidAudio, () => VoiceLabAssets.PrepareAsync(changed, assets[0], audio, "vl-passage", root));
            Assert.True(File.Exists(file));
        }
        finally { Directory.Delete(root, true); File.Delete(outside); }
    }

    [Fact]
    public async Task FlacHasTypedShippingCodecBoundaryAndCancellationKeepsPaidFile()
    {
        var (project, root, file) = Setup(Wave());
        try
        {
            var asset = project.VoiceLab.Assets![0];
            var flac = asset with { File = project.Id + "/asset-one.flac" };
            var flacFile = System.IO.Path.Combine(root, project.Id, "asset-one.flac");
            File.WriteAllBytes(flacFile, Wave());
            var assets = project.VoiceLab.Assets.ToArray(); assets[0] = flac;
            var changed = project with { VoiceLab = project.VoiceLab with { Assets = assets } };
            await Error(VoiceLabAssetErrorCode.UnsupportedFormat, () => VoiceLabAssets.PrepareAsync(changed, flac,
                changed.VoiceLab.Segments[0].Audio, "vl-passage", root));
            using var cancel = new CancellationTokenSource(); cancel.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => VoiceLabAssets.PrepareAsync(project,
                VoiceLabOutputPlanner.Build(project, VoiceLabOutputScope.Full), root, cancel.Token));
            Assert.True(File.Exists(file));
        }
        finally { Directory.Delete(root, true); }
    }
}
