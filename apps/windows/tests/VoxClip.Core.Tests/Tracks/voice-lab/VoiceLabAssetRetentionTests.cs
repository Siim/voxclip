using VoxClip.Core.Domain.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabAssetRetentionTests
{
    private const string ProjectId = "12345678-1234-1234-1234-123456789012";
    private static readonly DateTimeOffset Start = DateTimeOffset.FromUnixTimeSeconds(1800000000);
    private static readonly VoiceLabRetainedFile File = new(ProjectId + "/paid.wav", "volume:file-identity", 1000, 100);
    private static HashSet<string> References(params string[] paths) => new(paths, StringComparer.Ordinal);
    private static VoiceLabRetentionDecision Observe(VoiceLabRetentionLedger ledger, double wallDays, double monotonicDays, string session = "first",
        IReadOnlySet<string>? references = null, bool allowDeletion = true, bool preserve = false, VoiceLabRetainedFile? file = null) =>
        VoiceLabAssetRetention.Observe(ledger, ProjectId, [file ?? File], references ?? References(), Start.AddDays(wallDays), new(session, monotonicDays * 86400), allowDeletion, preserve);
    [Fact]
    public void SevenDaysStartAtFirstUnreferencedObservationNotFileTime()
    {
        var first = Observe(VoiceLabRetentionLedger.Empty, 0, 0);
        Assert.Empty(first.Eligible);
        Assert.Empty(Observe(first.Ledger, 7 - 0.00001, 7 - 0.00001).Eligible);
        var aged = Observe(first.Ledger, 7, 7);
        Assert.Equal(File, Assert.Single(aged.Eligible));
        Assert.True(aged.CanDelete(File, References()));
        Assert.False(aged.CanDelete(File, References(File.File)));
        Assert.False(aged.CanDelete(File with { Identity = "replacement" }, References()));
        var read = VoiceLabAssetRetention.Deserialize(VoiceLabAssetRetention.Serialize(first.Ledger));
        Assert.Single(Observe(read, 7, 7).Eligible);
        Assert.ThrowsAny<Exception>(() => VoiceLabAssetRetention.Deserialize("corrupt"));
        Assert.Throws<VoiceLabException>(() => VoiceLabAssetRetention.Deserialize("{\"schema\":\"future\",\"protected\":[],\"unreferenced\":{}}"));
    }
    [Theory]
    [InlineData(-1, 1, "first")]
    [InlineData(8, 1, "first")]
    [InlineData(8, 8, "restarted")]
    [InlineData(8, -1, "first")]
    public void ClockJumpsAndRestartsNeverShortenTheGrace(double wall, double monotonic, string session)
    {
        var first = Observe(VoiceLabRetentionLedger.Empty, 0, 1);
        var jumped = Observe(first.Ledger, wall, monotonic < 0 ? 0 : monotonic, session);
        Assert.Empty(jumped.Eligible);
        Assert.Equal(Start.AddDays(wall), jumped.Ledger.Unreferenced[File.File].Discovered);
        Assert.Empty(Observe(jumped.Ledger, wall + 6, (monotonic < 0 ? 0 : monotonic) + 6, session).Eligible);
    }
    [Fact]
    public void ReferencesAndStartupUnlistedFilesRemainProtected()
    {
        var protectedFile = Observe(VoiceLabRetentionLedger.Empty, 0, 0, references: References(File.File));
        Assert.Empty(Observe(protectedFile.Ledger, 100, 100).Eligible);
        var startup = Observe(VoiceLabRetentionLedger.Empty, 0, 0, preserve: true);
        Assert.Empty(Observe(startup.Ledger, 100, 100).Eligible);
        var first = Observe(VoiceLabRetentionLedger.Empty, 0, 0);
        Assert.Empty(Observe(first.Ledger, 8, 8, allowDeletion: false).Eligible);
        Assert.Empty(Observe(first.Ledger, 8, 8, references: References(File.File)).Eligible);
    }
    [Fact]
    public void ChangedIdentityRestartsGraceAndUnsafeInputFailsClosed()
    {
        var first = Observe(VoiceLabRetentionLedger.Empty, 0, 0);
        Assert.Empty(Observe(first.Ledger, 8, 8, file: File with { Identity = "new-file" }).Eligible);
        foreach (var name in new[] { "../paid.wav", ProjectId + "/../paid.wav", ProjectId + "/con.wav", ProjectId + "/paid.partial" })
            Assert.Throws<VoiceLabException>(() => Observe(first.Ledger, 8, 8, file: File with { File = name }));
        Assert.Throws<VoiceLabException>(() => Observe(first.Ledger, 8, double.NaN));
        var corrupt = first.Ledger with { Unreferenced = new Dictionary<string, VoiceLabRetentionEntry> { ["different.wav"] = first.Ledger.Unreferenced[File.File] } };
        Assert.Throws<VoiceLabException>(() => Observe(corrupt, 8, 8));
    }
}
