using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

internal sealed class TestStorage : IDisposable
{
    private readonly DirectoryInfo directory = Directory.CreateTempSubdirectory("voxclip-win-editing-");
    internal string Root => directory.FullName;
    internal string PathFor(string name) => Path.Combine(Root, name);
    internal static string ProjectPath(string name = "clip-from-long-take.voxclip") => Path.Combine(FixtureLoader.SharedRoot, "fixtures", "projects", name);
    internal static Project ProjectFixture() => ProjectSerialization.Deserialize(File.ReadAllText(ProjectPath()));
    internal static JsonObject ProjectJson() => JsonNode.Parse(File.ReadAllText(ProjectPath()))!.AsObject();
    public void Dispose() => directory.Delete(true);
}
