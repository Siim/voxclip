using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

/// <summary>Learn from my videos (ADR-R41, voice-lab.md §6.9; Mac <c>VoiceSpeakerReferencesTests</c> "the learner"): up to six 6–10 s
/// stretches around evenly spaced words, each embedded and checked one hop against the record's own embedding; the best that passes becomes
/// the project's reference. AI-modified media never teaches, and with no speaker check (the closed parity gate) nothing is read. A
/// scripted embedder stands in for the speaker model; nothing is sent anywhere.</summary>
public sealed class VoiceReferenceLearnerTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-learner-" + Guid.NewGuid().ToString("N"));
    private readonly VoiceConsentStore store;
    private readonly VoiceConsentRecord record;

    public VoiceReferenceLearnerTests()
    {
        Directory.CreateDirectory(root);
        store = new(new DataLocations(root, Path.Combine(root, "settings.json"), Path.Combine(root, "Models"), Path.Combine(root, "Cache"),
            Path.Combine(root, "Autosave"), Path.Combine(root, "Secrets"), Path.Combine(root, "Logs")));
        var wav = VoiceTrainingAudio.Wav(Enumerable.Range(0, 48000 * 6).Select(index => (float)(0.1 * Math.Sin(2 * Math.PI * 100 * index / 48000))).ToArray());
        record = JsonSerializer.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/consent-record.json"), VoiceConsentJson.Default.VoiceConsentRecord)!;
        record = record with { RecordId = Guid.NewGuid().ToString("D"), Speaker = record.Speaker with { Embedding = VoiceConsentRecord.EncodeEmbedding([1f, 0f, 0f]), Threshold = 0.45 },
            Statement = record.Statement! with { AudioSha256 = VoiceConsentStore.Hash(wav) } };
        store.SaveStatement(wav, record.RecordId); store.Save(record);
    }

    public void Dispose() => Directory.Delete(root, true);

    private static Project Project(int words = 60, string? language = "en")
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/interview-take.voxclip"));
        var timed = Enumerable.Range(0, words).Select(index => new TimedWord("w" + index, "word" + index, WordKind.Word, index * 2.0, index * 2.0 + 1.8,
            null, null, 1, null, TimingSource.Native)).ToArray();
        return project with
        {
            Transcript = project.Transcript! with { Words = timed, Language = language },
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = words * 2.0, Audio = new(16000, 1), ContentKey = "video-a" } }
        };
    }

    private VoiceSpeakerProbe Probe(Func<float[], float[]> embed) =>
        new(record.Speaker.Model, record.Speaker.Threshold, record.Language, (pcm, _) => Task.FromResult(embed(pcm)), (_, _) => throw new InvalidOperationException());

    /// <summary>Each selection's speech is a constant equal to its first frame, so the scripted embedder knows which stretch it hears.</summary>
    private static Task<float[]> Decode(string media, long frames, int rate, VoiceLabGuardSpeech selection, CancellationToken ct) =>
        Task.FromResult(Enumerable.Repeat((float)selection.Ranges[0].Start, 16000).ToArray());

    [Fact]
    public void SixStretchesAroundEvenlySpacedWordsOfAtLeastSixSeconds()
    {
        var project = Project();
        var selections = VoiceReferenceLearner.Selections(project.Transcript!.Words, 16000, 120 * 16000);
        Assert.Equal(VoiceReferenceLearner.Candidates, selections.Count);
        Assert.All(selections, selection => Assert.InRange(selection.Frames, 6 * 16000, 10 * 16000));
        Assert.Equal(selections.Count, selections.Distinct().Count());
        Assert.True(selections.Zip(selections.Skip(1)).All(pair => pair.First.Ranges[0].Start < pair.Second.Ranges[0].Start));
        // Too little speech: no selection reaches 6 s.
        Assert.Empty(VoiceReferenceLearner.Selections(Project(words: 2).Transcript!.Words, 16000, 4 * 16000));
    }

    [Fact]
    public async Task TheBestStretchThatPassesOneHopBecomesTheProjectsReference()
    {
        var calls = 0;
        // The third stretch is the owner's (0.8), the others another voice (0.1).
        var learner = new VoiceReferenceLearner(store, Probe(pcm => ++calls == 3 ? [0.8f, 0.6f, 0f] : [0.1f, 0f, 1f]), Decode, _ => false);
        var learned = await learner.LearnAsync(Project(), "/media/a.mp4", record.RecordId, TestContext.Current.CancellationToken);
        Assert.Equal(VoiceReferenceLearnerOutcome.Learned, learned.Outcome);
        Assert.Equal(0.8, learned.Score!.Value, 6);
        var saved = store.Load(record.RecordId);
        var reference = Assert.Single(saved.Speaker.References!);
        Assert.Equal("video-a", reference.ContentKey);
        Assert.Equal(1, VoiceSpeakerReferences.LearnedCount(saved.Speaker));
        // The same project again: it already holds a reference at least as good.
        calls = 0;
        Assert.Equal(VoiceReferenceLearnerOutcome.Kept, (await learner.LearnAsync(Project(), "/media/a.mp4", record.RecordId, TestContext.Current.CancellationToken)).Outcome);
    }

    [Fact]
    public async Task AnotherVoiceAiModifiedMediaAndNoSpeechTeachNothing()
    {
        var other = new VoiceReferenceLearner(store, Probe(_ => [0.1f, 0f, 1f]), Decode, _ => false);
        Assert.Equal(VoiceReferenceLearnerOutcome.NotTheOwner, (await other.LearnAsync(Project(), "/m.mp4", record.RecordId, TestContext.Current.CancellationToken)).Outcome);
        var generated = new VoiceReferenceLearner(store, Probe(_ => [1f, 0f, 0f]), Decode, _ => true);
        Assert.Equal(VoiceReferenceLearnerOutcome.Generated, (await generated.LearnAsync(Project(), "/m.mp4", record.RecordId, TestContext.Current.CancellationToken)).Outcome);
        var owner = new VoiceReferenceLearner(store, Probe(_ => [1f, 0f, 0f]), Decode, _ => false);
        Assert.Equal(VoiceReferenceLearnerOutcome.NoSpeech, (await owner.LearnAsync(Project(words: 2), "/m.mp4", record.RecordId, TestContext.Current.CancellationToken)).Outcome);
        Assert.Equal(VoiceReferenceLearnerOutcome.Unavailable, (await owner.LearnAsync(Project(language: "de"), "/m.mp4", record.RecordId, TestContext.Current.CancellationToken)).Outcome);
        Assert.Null(store.Load(record.RecordId).Speaker.References);
    }

    /// <summary>The closed parity gate: the App has no available speaker check, so there is no probe and nothing is decoded or learned.</summary>
    [Fact]
    public async Task WithoutASpeakerCheckNothingIsReadOrLearned()
    {
        Assert.Null(VoiceSpeakerProbe.From(VoiceSpeakerCheck.Unavailable));
        var decoded = 0;
        var learner = new VoiceReferenceLearner(store, null, (_, _, _, _, _) => { decoded++; return Task.FromResult(new float[16000]); }, _ => false);
        Assert.Equal(VoiceReferenceLearnerOutcome.Unavailable, (await learner.LearnAsync(Project(), "/m.mp4", record.RecordId, TestContext.Current.CancellationToken)).Outcome);
        Assert.Equal(0, decoded);
    }

    /// <summary>Mac <c>VoiceLabDisclosureWriter.isLabelled</c>: the XMP UUID box this writer adds, or a QuickTime <c>moov/udta/XMP_</c> box, with a
    /// trained-algorithmic DigitalSourceType; anything else, or an unreadable file, has no label.</summary>
    [Fact]
    public void AiModifiedMediaIsRecognisedByItsXmpLabel()
    {
        static byte[] Box(string type, params byte[][] body)
        {
            var content = body.SelectMany(part => part).ToArray();
            var box = new byte[8 + content.Length];
            BinaryPrimitives.WriteUInt32BigEndian(box, (uint)box.Length);
            Encoding.ASCII.GetBytes(type).CopyTo(box, 4);
            content.CopyTo(box, 8);
            return box;
        }
        var packet = VoiceLabDisclosureWriter.XmpPacket();
        var uuid = Convert.FromHexString("BE7ACFCB97A942E89C71999491E3AFAC");
        var labelled = Path.Combine(root, "labelled.mp4");
        File.WriteAllBytes(labelled, [.. Box("ftyp", "isom"u8.ToArray()), .. Box("uuid", uuid, packet)]);
        Assert.True(VoiceLabDisclosureWriter.IsLabelled(labelled));
        var quickTime = Path.Combine(root, "quicktime.mov");
        File.WriteAllBytes(quickTime, [.. Box("ftyp", "qt  "u8.ToArray()), .. Box("moov", Box("udta", Box("XMP_", Encoding.UTF8.GetBytes("digitalsourcetype/trainedAlgorithmicMedia"))))]);
        Assert.True(VoiceLabDisclosureWriter.IsLabelled(quickTime));
        var plain = Path.Combine(root, "plain.mp4");
        File.WriteAllBytes(plain, [.. Box("ftyp", "isom"u8.ToArray()), .. Box("uuid", new byte[16], packet), .. Box("mdat", new byte[32])]);
        Assert.False(VoiceLabDisclosureWriter.IsLabelled(plain));
        Assert.False(VoiceLabDisclosureWriter.IsLabelled(Path.Combine(root, "missing.mp4")));
    }
}
