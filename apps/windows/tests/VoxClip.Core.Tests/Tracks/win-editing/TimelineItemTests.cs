using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class TimelineItemTests
{
    private static readonly JsonObject Edits = Load("edit-cases");
    private static readonly JsonObject Layouts = Load("layout-cases");
    private static readonly HashSet<string> TimeFields = ["start", "end", "sourceStart", "sourceEnd", "t", "anchorSeconds",
        "lengthSeconds", "songFromSeconds", "mediaOffsetSeconds", "fadeInSeconds", "fadeOutSeconds"];

    public static TheoryData<string> EditNames => Names(Edits);
    public static TheoryData<string> LayoutNames => Names(Layouts);

    [Fact]
    public void HarnessVolumeEditsKeepTheLastWordInsideTheDip()
    {
        var project = ProjectSerialization.Deserialize(Edits["bases"]!["music"]!.ToJsonString());
        using var wire = JsonDocument.Parse("""
            [{"op":"setTrackGain","track":"music-main","db":-10},
             {"op":"dipGain","item":"music","startWord":5,"endWord":5,"byDb":-6}]
            """);
        var quieter = new TimelineEditRequest(wire.RootElement[0]).Apply(project, "clip-main");
        var dipped = new TimelineEditRequest(wire.RootElement[1]).Apply(quieter.Project, "clip-main");
        var track = Assert.Single(dipped.Project.Music);
        Assert.Equal(-10, track.GainDb);
        Assert.Equal([0.25, 0.5, 0.55, 0.95, 1], Assert.Single(track.Segments!).GainPoints!.Select(point => point.T));
    }

    [Theory]
    [MemberData(nameof(EditNames))]
    public void ReplayTimelineEdit(string name)
    {
        var row = Case(Edits, name);
        var basis = Edits["bases"]![Text(row, "base")]!;
        var project = ProjectSerialization.Deserialize(basis.ToJsonString());
        var command = Command(row["edit"]!);
        var plan = Plan(row["plan"]!, Number(Edits, "sampleRate"));
        var scope = row["scope"]?.GetValue<string>();
        var result = TimelineEdits.Apply(command, project, plan, scope);
        if (row["refusal"] is { } refusal)
        {
            Assert.Equal(refusal.GetValue<string>(), Assert.IsType<TimelineEditResult.Refused>(result).Refusal.Copy);
            return;
        }
        var applied = Assert.IsType<TimelineEditResult.Applied>(result);
        Assert.Equal(Text(row, "undo"), applied.UndoName);
        var snapshot = basis.DeepClone().AsObject();
        var changes = row["expected"]!.AsObject();
        foreach (var (key, change) in changes)
            if (change is null) snapshot.Remove(key); else snapshot[key] = change.DeepClone();
        using var expected = JsonDocument.Parse(ProjectSerialization.Serialize(ProjectSerialization.Deserialize(snapshot.ToJsonString())));
        using var actual = JsonDocument.Parse(ProjectSerialization.Serialize(applied.Project));
        foreach (var field in expected.RootElement.EnumerateObject())
            Assert.True(actual.RootElement.TryGetProperty(field.Name, out var value) && JsonElement.DeepEquals(field.Value, value),
                $"{name}: {field.Name}");
        Assert.Equal(expected.RootElement.EnumerateObject().Count(), actual.RootElement.EnumerateObject().Count());
        var replay = Assert.IsType<TimelineEditResult.Applied>(TimelineEdits.Apply(command, project, plan, scope));
        Assert.Equal(applied.UndoName, replay.UndoName);
        Assert.Equal(actual.RootElement.GetRawText(), ProjectSerialization.Serialize(replay.Project).TrimEnd());

        foreach (var key in new[] { "clipEffects", "motionCues", "music", "media" }.Where(changes.ContainsKey))
        {
            var field = snapshot[key];
            var times = key == "music" ? (field?.AsArray() ?? []).SelectMany(track => GridTimes(track?["segments"])) :
                GridTimes(key == "media" ? field?["footage"] : field);
            Assert.All(times, time => Assert.InRange(Math.Abs(time * plan.SampleRate - Math.Round(time * plan.SampleRate)), 0, 1e-7));
        }
    }

    [Theory]
    [MemberData(nameof(LayoutNames))]
    public void ReplayTimelineLayout(string name)
    {
        var row = Case(Layouts, name);
        var project = ProjectSerialization.Deserialize(Layouts["bases"]![Text(row, "base")]!.ToJsonString());
        var axis = Enum.Parse<TimelineAxis>(Text(row, "axis"), true);
        var plan = Plan(row["plan"]!, Number(Layouts, "sampleRate"));
        var layout = TimelineItems.Layout(project, plan, row["scope"]?.GetValue<string>(), axis, row["playhead"]?.GetValue<double>());
        if (row["drop"] is { } drop)
        {
            var time = Number(drop, "time");
            Assert.Equal(Number(drop, "anchor"), TimelineItems.SourceAnchor(time, axis, plan));
            Assert.Equal(drop["hint"]?.GetValue<string>(), TimelineItems.DropHint(time, axis, plan));
        }
        foreach (var expected in row["items"]!.AsArray())
        {
            var item = Assert.Single(layout.Items, item => item.Id == Identity(expected!["id"]!));
            Assert.Equal(Text(expected!, "kind"), item.Kind);
            Assert.Equal(Text(expected!, "lane"), item.Lane.ToString());
            Assert.Equal(expected!["row"]!.GetValue<int>(), item.Row);
            Assert.Equal(expected["part"]?.GetValue<string>(), item.PartId);
            Assert.Equal(Number(expected, "anchor"), item.SourceAnchor);
            Assert.Equal(Intervals(expected["edited"]!), item.EditedIntervals);
            Assert.Equal(Intervals(expected["axis"]!), item.AxisIntervals);
            Assert.Equal(expected["hidden"]!.GetValue<bool>(), item.Hidden);
            Assert.Equal(expected["marker"]?.GetValue<double>(), item.Marker);
            Assert.Equal(expected["reason"]?.GetValue<string>(), item.Reason);
            Assert.Equal(expected["notches"]!.AsArray().Select(value => value!.GetValue<double>()), item.SeamNotches);
        }
        if (row["allItems"]!.GetValue<bool>()) Assert.Equal(row["items"]!.AsArray().Count, layout.Items.Count);
        foreach (var (lane, count) in row["rows"]!.AsObject())
            Assert.Equal(count!.GetValue<int>(), layout.RowCounts[Enum.Parse<TimelineLane>(lane)]);
        foreach (var (key, present) in new[] { ("snaps", true), ("missing", false) })
            foreach (var target in row[key]!.AsArray())
            {
                var snap = new TimelineSnapTarget(target![0]!.GetValue<double>(), Enum.Parse<TimelineSnapKind>(target[1]!.GetValue<string>(), true),
                    target[2] is { } item ? Identity(item) : null);
                Assert.Equal(present, layout.SnapTargets.Contains(snap));
            }
    }

    private static JsonObject Load(string name) => JsonNode.Parse(FixtureLoader.ReadText($"fixtures/timeline-edits/{name}.json"))!.AsObject();
    private static JsonNode Case(JsonObject root, string name) => root["cases"]!.AsArray().Single(row => Text(row!, "name") == name)!;
    private static TheoryData<string> Names(JsonObject fixture)
    {
        var result = new TheoryData<string>();
        foreach (var row in fixture["cases"]!.AsArray()) result.Add(Text(row!, "name"));
        return result;
    }

    private static string Text(JsonNode obj, string key) => obj[key]!.GetValue<string>();
    private static double Number(JsonNode obj, string key) => obj[key]!.GetValue<double>();
    private static TimelineItemId Identity(JsonNode item) => new(Enum.Parse<TimelineItemType>(item[0]!.GetValue<string>(), true), item[1]!.GetValue<string>());
    private static EditPlan Plan(JsonNode row, double rate)
    {
        var kept = row["kept"]!.AsArray().Select(pair => new MediaInterval(pair![0]!.GetValue<long>(), pair[1]!.GetValue<long>())).ToArray();
        var total = row["total"]!.GetValue<long>();
        var cuts = new List<MediaInterval>();
        long cursor = 0;
        foreach (var span in kept.OrderBy(span => span.StartSample))
        {
            if (span.StartSample > cursor) cuts.Add(new(cursor, span.StartSample));
            cursor = span.EndSample;
        }
        if (cursor < total) cuts.Add(new(cursor, total));
        return new(rate, total, cuts, kept, kept.Sum(span => span.EndSample - span.StartSample), [])
        {
            PartSeams = row["seams"]!.AsArray().Select(value => value!.GetValue<long>()).ToArray()
        };
    }

    private static IEnumerable<TimeRange> Intervals(JsonNode value) => value.AsArray().Select(pair => new TimeRange(pair![0]!.GetValue<double>(), pair[1]!.GetValue<double>()));
    private static IEnumerable<double> GridTimes(JsonNode? value) => value switch
    {
        JsonArray list => list.SelectMany(GridTimes),
        JsonObject fields => fields.SelectMany(pair => TimeFields.Contains(pair.Key) ? [pair.Value!.GetValue<double>()] : GridTimes(pair.Value)),
        _ => []
    };

    private static TimelineEdit Command(JsonNode row)
    {
        TimelineItemId Item() => Identity(row["item"]!);
        var items = row["items"]?.AsArray().Select(value => Identity(value!)).ToArray() ?? [];
        var source = row["source"]?.GetValue<double>() ?? 0;
        var db = row["db"]?.GetValue<double>() ?? 0;
        var old = row["old"]?.GetValue<double>() ?? 0;
        var edge = row["edge"] is { } e ? Enum.Parse<TimelineEdge>(e.GetValue<string>(), true) : TimelineEdge.Start;
        return Text(row, "op") switch
        {
            "move" => new TimelineEdit.Move(items, source),
            "nudge" => new TimelineEdit.Nudge(items, Enum.Parse<TimelineNudge>(Text(row, "unit"), true), row["count"]!.GetValue<int>()),
            "trim" => new TimelineEdit.Trim(Item(), edge, source),
            "split" => new TimelineEdit.Split(items, source),
            "splitAll" => new TimelineEdit.SplitAll(source),
            "fade" => new TimelineEdit.Fade(Item(), edge, Number(row, "seconds")),
            "setGain" => new TimelineEdit.SetGain(Item(), db),
            "setTrackGain" => new TimelineEdit.SetTrackGain(Text(row, "track"), db),
            "dipGain" => new TimelineEdit.DipGain(Item(), Number(row, "fromSource"), Number(row, "toSource"), Number(row, "byDb")),
            "addGainPoint" => new TimelineEdit.AddGainPoint(Item(), source, db),
            "moveGainPoint" => new TimelineEdit.MoveGainPoint(Item(), old, source, db),
            "removeGainPoint" => new TimelineEdit.RemoveGainPoint(Item(), old),
            "slip" => new TimelineEdit.Slip(Item(), Number(row, "seconds")),
            "setLoop" => new TimelineEdit.SetLoop(Item(), row["enabled"]!.GetValue<bool>()),
            "setDuck" => new TimelineEdit.SetDuck(Text(row, "track"), db),
            "duplicate" => new TimelineEdit.Duplicate(items, row["source"]?.GetValue<double>()),
            "delete" => new TimelineEdit.Delete(items),
            _ => throw new InvalidOperationException("Unknown vector command")
        };
    }
}
