#if WIN_UI_TESTS
using System.Text.Json.Nodes;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>Stored cut edges (editing §5.10) ride every edit the editor commits: an edit elsewhere keeps them, so the plan keeps its
/// seams and paid voice work made from them stays current. Seating and normalizing on commit is the CE5 hook.</summary>
public sealed class CutEdgeCarryTests
{
    [Fact]
    public void AnEditElsewhereKeepsTheStoredCutEdges()
    {
        var root = JsonNode.Parse(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "music", "music-project.voxclip")))!;
        root["schemaVersion"] = 8;
        root["edits"]!["cutWordIds"] = new JsonArray("w2");
        root["edits"]!["cutEdges"] = new JsonObject { ["w2"] = 0.66, ["w3"] = 1.04 };
        var model = new EditorViewModel(ProjectSerialization.Deserialize(root.ToJsonString()));
        Assert.True(model.ApplyBatch([new EditOperation.Toggle("w9")]));
        Assert.Equal(["w2", "w9"], model.Project.Edits.CutWordIds);
        var edges = Assert.IsAssignableFrom<IReadOnlyDictionary<string, double>>(model.Project.Edits.CutEdges);
        Assert.Equal(["w2", "w3"], edges.Keys.Order(StringComparer.Ordinal));
        Assert.Equal((0.66, 1.04), (edges["w2"], edges["w3"]));
        var saved = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(model.Project));
        Assert.Equal(8, saved.SchemaVersion);
        Assert.Equal(1.04, saved.Edits.CutEdges!["w3"]);
    }
}
#endif
