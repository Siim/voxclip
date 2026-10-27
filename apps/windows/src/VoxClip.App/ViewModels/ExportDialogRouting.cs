using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal sealed class ExportDialogRouting
{
    internal static IReadOnlyList<ExportScopeKind> Scopes(string? selectedClip) => selectedClip is null
        ? [ExportScopeKind.AllClips, ExportScopeKind.FullVideo] : [ExportScopeKind.ThisClip, ExportScopeKind.AllClips, ExportScopeKind.FullVideo];
    internal static IReadOnlyList<ExportTarget> SelectedTargets(EditorViewModel model, string? selectedClip, int scopeIndex)
        => ExportSelection.Targets(Scopes(selectedClip)[scopeIndex], selectedClip, model.KeptClips.Select(clip => clip.Id).ToArray());
    internal Project Project { get; }
    internal IReadOnlyList<ExportTarget> Targets { get; }
    private readonly EditState? state;
    private readonly IReadOnlyDictionary<string, string> titles;
    private readonly string pattern;

    internal ExportDialogRouting(EditorViewModel model, string? selectedClip, int scopeIndex, int aspectIndex, int qualityIndex,
        bool srt, string folder, string pattern)
    {
        if (!Path.IsPathFullyQualified(folder)) throw new ArgumentException("Choose an absolute destination folder.", nameof(folder));
        if (qualityIndex is < 0 or > 1) throw new ArgumentOutOfRangeException(nameof(qualityIndex));
        Project = model.Project with { Export = new(EditorLayout.Frames[aspectIndex], (ExportQuality)qualityIndex, srt, folder) };
        Targets = SelectedTargets(model, selectedClip, scopeIndex);
        state = model.State;
        titles = model.Clips.ToDictionary(clip => clip.Id, clip => clip.Title, StringComparer.Ordinal);
        this.pattern = pattern;
    }
    internal EditState? State(ExportTarget target) => ExportSelection.Scope(state, target);
    internal (string Mp4, string? Srt) Paths(ExportTarget target) => ExportSelection.Paths(Project.Title ?? "Untitled take",
        target is ExportTarget.Clip clip ? titles[clip.Id] : null, Project.Export.Aspect, Project.Export.Srt, Project.Export.Folder!, pattern);
    internal async Task<ExportJob> JobAsync(ExportTarget target, Func<Project, EditState?, CancellationToken, Task<ComposeSnapshot>> snapshot, CancellationToken ct)
    {
        if (!Targets.Contains(target)) throw new ArgumentException("Choose a routed target.", nameof(target));
        var scoped = State(target);
        var project = ExportRenderInput.ScopedProject(Project, scoped);
        var compose = await snapshot(project, scoped, ct);
        var paths = Paths(target);
        return new(compose, target, Project.Export.Aspect, Project.Export.Quality, paths.Mp4, paths.Srt);
    }
}
