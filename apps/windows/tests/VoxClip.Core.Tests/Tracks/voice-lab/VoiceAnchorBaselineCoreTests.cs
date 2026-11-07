using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>The anchor's baseline in Core (voice-lab.md §6.13 item 9; Mac <c>VoicePerVideoTests</c>' three baseline cases): which takes are the
/// anchor's, the book's stored baseline with its model, its rules and its wire, and the take's guard speech with its fallback.</summary>
public sealed class VoiceAnchorBaselineCoreTests
{
    private const string AnchorId = "6f0c2c1e-8a0e-4c5e-9d1f-0b9d4a7f2e11";
    private const string One = "11111111-1111-4111-8111-111111111111";
    private const string Two = "22222222-2222-4222-8222-222222222222";

    [Fact]
    public void TheAnchorsEarlierTakesAreItsOwnAcceptedTextToSpeechTakesNewestFirst()
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-project.voxclip"));
        var template = project.VoiceLab.Segments[0];
        VoiceLabSegment Take(string id, double minutes, VoiceLabSegmentKind kind = VoiceLabSegmentKind.Tts, string? voice = AnchorId, bool enabled = true,
            string? asset = null) => template with
        {
            Id = id, Kind = kind, Enabled = enabled, Audio = template.Audio with { AssetId = asset ?? template.Audio.AssetId },
            Provenance = template.Provenance with { ConsentRecordId = voice, CreatedAt = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000).AddMinutes(minutes) }
        };
        project = project with { VoiceLab = project.VoiceLab with { Segments =
        [
            Take("old", 1), Take("new", 9), Take("other-voice", 5, voice: One), Take("recorded", 6, kind: VoiceLabSegmentKind.Recorded),
            Take("changed", 7, kind: VoiceLabSegmentKind.VoiceChanger), Take("off", 8, enabled: false), Take("no-asset", 4, asset: "gone"),
            Take("unlinked", 3, voice: null), Take("middle", 5)
        ] } };
        var takes = VoicePerVideo.AnchorTakes(project, AnchorId);
        Assert.Equal(["new", "middle", "old"], takes.Select(take => take.Segment.Id));
        Assert.All(takes, take => Assert.Equal(take.Segment.Audio.AssetId, take.Asset.Id));
        Assert.Empty(VoicePerVideo.AnchorTakes(project, Two));
        Assert.Equal(12, VoicePerVideo.MaximumBaselineTakes);
    }

    [Fact]
    public void TheAnchorsBaselineIsKeptWithItsModelAndReadAsMissingForAnotherModelOrVoice()
    {
        var book = new VoicePerVideoBook();
        Assert.Null(book.Baseline(AnchorId, "wespeaker-resnet34"));
        book = book with { AnchorBaseline = new(AnchorId, "wespeaker-resnet34", 0.54, 8, "2026-11-06T10:00:00Z") };
        book.Validate();
        Assert.Equal(0.54, book.Baseline(AnchorId, "wespeaker-resnet34")?.Score);
        Assert.Null(book.Baseline(AnchorId, "ecapa-tdnn"));
        Assert.Null(book.Baseline(One, "wespeaker-resnet34"));
        // The Mac's sorted keys; no score is left out, as the Mac's encoder leaves out a nil optional.
        var encoded = book.Encoded();
        Assert.Contains("\"anchorBaseline\": {\n    \"anchorId\": \"" + AnchorId + "\",\n    \"measuredAt\": \"2026-11-06T10:00:00Z\",\n    \"model\": \"wespeaker-resnet34\",\n    \"score\": 0.54,\n    \"takes\": 8\n  }",
            encoded.Replace("\r\n", "\n"), StringComparison.Ordinal);
        Assert.Equal(book, VoicePerVideoBook.Decode(encoded));
        // A book written before the baseline existed still reads, and saves without it.
        var legacy = VoicePerVideoBook.Decode("{\"schema\":\"voxclip-voice-per-video/1\",\"videos\":[],\"removals\":[],\"shortNoted\":[],\"measurements\":[]}");
        Assert.Null(legacy.AnchorBaseline);
        legacy.Validate();
        Assert.DoesNotContain("anchorBaseline", legacy.Encoded(), StringComparison.Ordinal);
        var none = book with { AnchorBaseline = new(AnchorId, "m", null, 0, "2026-11-06T10:00:00Z") };
        none.Validate();
        Assert.DoesNotContain("\"score\"", none.Encoded(), StringComparison.Ordinal);
        Assert.Equal(none, VoicePerVideoBook.Decode(none.Encoded()));
        Assert.NotEqual(book, none);
        foreach (var broken in new VoicePerVideoBook.AnchorBaselineEntry[]
        {
            new(AnchorId, "m", 0.5, 13, ""), new(AnchorId, "m", null, 3, ""), new(AnchorId, "m", 0.5, 0, ""), new(AnchorId, "", 0.5, 2, ""),
            new("not-a-record", "m", 0.5, 2, ""), new(AnchorId, "m", 1.5, 2, ""), new(AnchorId, new string('m', 129), 0.5, 2, ""), new(AnchorId, "m", 0.5, -1, "")
        })
            Assert.Throws<VoiceLabException>(() => (book with { AnchorBaseline = broken }).Validate());
        Assert.Throws<VoiceLabException>(() => VoicePerVideoBook.Decode(encoded.Replace("\"takes\": 8", "\"takes\": \"8\"", StringComparison.Ordinal)));
    }

    [Fact]
    public void ATakesGuardSpeechFallsBackToTenSecondsAroundItsWindow()
    {
        var none = VoiceLabGuardSpeech.ForTake([], 20, 22, 320_000, 352_000, 16_000, 960_000);
        Assert.Equal([(256_000L, 416_000L)], none.Ranges);
        Assert.Null(none.Speaker);
        var word = new TimedWord("w1", "hi", WordKind.Word, 21, 21.5, null, null, null, null, TimingSource.Native);
        var spoken = VoiceLabGuardSpeech.ForTake([word], 20, 22, 320_000, 352_000, 16_000, 960_000);
        var selected = VoiceLabGuardSpeech.Select([word], 20, 22, 16_000, 960_000);
        Assert.Equal(selected.Ranges, spoken.Ranges);
        Assert.Equal(selected.Speaker, spoken.Speaker);
        // Near the start, the ten seconds start at the source's first frame.
        Assert.Equal([(0L, 160_000L)], VoiceLabGuardSpeech.ForTake([], 1, 2, 16_000, 32_000, 16_000, 960_000).Ranges);
    }
}
