using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Replays shared/fixtures/voice-lab/training-spans.json (Voice Lab §6.5.1) exactly: integers, statuses and reasons equal,
/// snrDb equal in binary64, lists in order.</summary>
public sealed class VoiceTrainingSpansTests
{
    static readonly Lazy<JsonElement> Document = new(() =>
    {
        using var document = FixtureLoader.ReadJson("fixtures/voice-lab/training-spans.json");
        return document.RootElement.Clone();
    });

    public static TheoryData<string> Cases()
    {
        var data = new TheoryData<string>();
        foreach (var test in Document.Value.GetProperty("cases").EnumerateArray()) data.Add(test.GetProperty("id").GetString()!);
        return data;
    }

    [Fact]
    public void ConstantsMatchTheFixture()
    {
        var constants = Document.Value.GetProperty("constants");
        Assert.Equal("voxclip-voice-lab-training-spans/1", Document.Value.GetProperty("schema").GetString());
        Assert.Equal(VoiceTrainingSpans.MinConf, constants.GetProperty("minConf").GetDouble());
        Assert.Equal(VoiceTrainingSpans.MaxGapMs, constants.GetProperty("maxGapMs").GetInt64());
        Assert.Equal(VoiceTrainingSpans.SpanMinMs, constants.GetProperty("spanMinMs").GetInt64());
        Assert.Equal(VoiceTrainingSpans.SpanMaxMs, constants.GetProperty("spanMaxMs").GetInt64());
        Assert.Equal(VoiceTrainingSpans.VoicedDb, constants.GetProperty("voicedDb").GetDouble());
        Assert.Equal(VoiceTrainingSpans.MinSnrDb, constants.GetProperty("minSnrDb").GetDouble());
        Assert.Equal(VoiceTrainingSpans.TotalMinMs, constants.GetProperty("totalMinMs").GetInt64());
        Assert.Equal(VoiceTrainingSpans.TotalMaxMs, constants.GetProperty("totalMaxMs").GetInt64());
        Assert.Equal(12, Cases().Count);
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void FixtureCaseReplaysExactly(string id)
    {
        var test = Document.Value.GetProperty("cases").EnumerateArray().Single(test => test.GetProperty("id").GetString() == id);
        var items = test.GetProperty("items").EnumerateArray().Select(item => new VoiceTrainingItem(
            JsonSerializer.Deserialize<WordKind>(item.GetProperty("kind").GetRawText()), item.GetProperty("start").GetDouble(), item.GetProperty("end").GetDouble(),
            item.GetProperty("conf").ValueKind == JsonValueKind.Null ? null : item.GetProperty("conf").GetDouble(),
            item.GetProperty("speaker").GetString(), item.GetProperty("synthetic").GetBoolean())).ToArray();
        var excluded = test.GetProperty("excluded").EnumerateArray().Select(range => new VoiceTrainingRange(range[0].GetDouble(), range[1].GetDouble())).ToArray();
        var frames = test.GetProperty("frames").EnumerateArray().SelectMany(run => Enumerable.Repeat(run[1].GetDouble(), run[0].GetInt32())).ToArray();
        var actual = VoiceTrainingSpans.Select(items, excluded, frames, test.GetProperty("duration").GetDouble());
        var expected = test.GetProperty("expected");
        Assert.Equal(expected.GetProperty("status").GetString(), JsonSerializer.Serialize(actual.Status).Trim('"'));
        Assert.Equal(expected.GetProperty("availableMs").GetInt64(), actual.AvailableMs);
        Assert.Equal(expected.GetProperty("selectedMs").GetInt64(), actual.SelectedMs);
        Assert.Equal(Spans(expected.GetProperty("selected")), actual.Selected);
        Assert.Equal(Spans(expected.GetProperty("qualifying")), actual.Qualifying);
        Assert.Equal(expected.GetProperty("rejected").EnumerateArray().Select(rejection => (rejection.GetProperty("startMs").GetInt64(),
            rejection.GetProperty("endMs").GetInt64(), rejection.GetProperty("reason").GetString()!,
            rejection.GetProperty("snrDb").ValueKind == JsonValueKind.Null ? (double?)null : rejection.GetProperty("snrDb").GetDouble())),
            actual.Rejected.Select(rejection => (rejection.StartMs, rejection.EndMs, JsonSerializer.Serialize(rejection.Reason).Trim('"'), rejection.SnrDb)));
        Assert.Equal(actual.Selected.Sum(span => span.EndMs - span.StartMs), actual.SelectedMs);
    }

    static VoiceTrainingSpan[] Spans(JsonElement spans) => spans.EnumerateArray().Select(span => new VoiceTrainingSpan(span.GetProperty("startMs").GetInt64(),
        span.GetProperty("endMs").GetInt64(), span.GetProperty("snrDb").GetDouble())).ToArray();

    [Fact]
    public void NonFiniteNumbersReversedRangesAndNegativeDurationsAreRefused()
    {
        VoiceTrainingItem Word(double start = 1, double end = 6, double? conf = 0.9) => new(WordKind.Word, start, end, conf, null, false);
        void Refused(IReadOnlyList<VoiceTrainingItem> items, IReadOnlyList<VoiceTrainingRange> excluded, IReadOnlyList<double> frames, double duration) =>
            Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => VoiceTrainingSpans.Select(items, excluded, frames, duration)).Kind);
        foreach (var value in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity })
        {
            Refused([Word(start: value)], [], [], 10);
            Refused([Word(end: value)], [], [], 10);
            Refused([Word(conf: value)], [], [], 10);
            Refused([], [new(value, 2)], [], 10);
            Refused([], [new(1, value)], [], 10);
            Refused([], [], [-20, value], 10);
            Refused([], [], [], value);
        }
        Refused([], [new(2, 1)], [], 10);
        Refused([], [], [], -0.001);
        Refused([Word(end: 1e300)], [], [], 10);
        var empty = VoiceTrainingSpans.Select([], [new(1, 1)], [], 0);
        Assert.Equal(VoiceTrainingSpanStatus.BelowMinimum, empty.Status);
        Assert.Equal(0, empty.AvailableMs);
    }

    [Fact]
    public void ProjectInputsMarkEverySegmentsWordsSyntheticAndExcludeItsRangeEnabledOrNot()
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));
        var segment = Assert.Single(project.VoiceLab.Segments);
        foreach (var enabled in new[] { true, false })
        {
            var current = project with { VoiceLab = project.VoiceLab with { Segments = [segment with { Enabled = enabled }] } };
            var inputs = VoiceTrainingSpans.Inputs(current);
            var words = current.Transcript!.Words;
            Assert.Equal(words.Count, inputs.Items.Count);
            for (var index = 0; index < words.Count; index++)
            {
                var item = inputs.Items[index];
                Assert.Equal((words[index].Kind, words[index].Start, words[index].End, words[index].Conf, words[index].Speaker),
                    (item.Kind, item.Start, item.End, item.Conf, item.Speaker));
                Assert.Equal(words[index].Id is "w4" or "w5", item.Synthetic);
            }
            Assert.Equal(new VoiceTrainingRange(segment.Replace.Start, segment.Replace.End), Assert.Single(inputs.Excluded));
        }
        var none = VoiceTrainingSpans.Inputs(project with { Transcript = null, VoiceLab = project.VoiceLab with { Segments = [] } });
        Assert.Empty(none.Items); Assert.Empty(none.Excluded);
    }
}
