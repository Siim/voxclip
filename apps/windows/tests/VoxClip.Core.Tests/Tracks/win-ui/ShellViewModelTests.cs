#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>The ADR-R29 sidebar: design §2 and §3.4.</summary>
public sealed class ShellViewModelTests
{
    private static Project Fixture(string name)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, "shared", "fixtures", "projects", name);
            if (File.Exists(path)) return ProjectSerialization.Deserialize(File.ReadAllText(path));
        }
        throw new FileNotFoundException("Shared project fixture not found.", name);
    }

    /// <summary>The long-take fixture with its AI clip left unchecked: one kept manual clip and one suggestion.</summary>
    private static EditorViewModel WithSuggestion()
    {
        var project = Fixture("clip-from-long-take.voxclip");
        var clips = project.Edits.Clips.Select(clip => clip.Origin == ClipOrigin.Ai ? clip with { Selected = false } : clip).ToArray();
        return new EditorViewModel(project with { Edits = project.Edits with { Clips = clips, ActiveClipId = null } });
    }

    [Fact]
    public void EditorRowsFollowTheSharedOrder()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        Assert.Equal([SidebarKind.Home, SidebarKind.Separator, SidebarKind.Project, SidebarKind.FullTake, SidebarKind.Clip,
            SidebarKind.SuggestedHeader, SidebarKind.Suggestion, SidebarKind.Separator, SidebarKind.Action, SidebarKind.Action],
            shell.Rows.Select(row => row.Kind));
        var kept = shell.Rows.Single(row => row.Kind == SidebarKind.Clip);
        var suggestion = shell.Rows.Single(row => row.Kind == SidebarKind.Suggestion);
        Assert.Equal(("1", "Iga sõna asukoht"), (kept.Number, kept.Title));
        Assert.Equal(("2", "Miks sõnade kaupa on kiirem"), (suggestion.Number, suggestion.Title));
        Assert.StartsWith("Clip 1, Iga sõna asukoht, ", kept.AccessibleName);
        Assert.StartsWith("Suggested clip 2, Miks sõnade kaupa on kiirem, ", suggestion.AccessibleName);
        Assert.EndsWith(" · Suggested", suggestion.Meta);
        Assert.Equal("Suggested", shell.Rows.Single(row => row.Kind == SidebarKind.SuggestedHeader).Title);
        Assert.Equal("Sõnade kaupa lõikamine", shell.Rows.Single(row => row.Kind == SidebarKind.Project).Title);
        Assert.Equal("voxclip-demo.mp4", shell.Rows.Single(row => row.Kind == SidebarKind.Project).Detail);
        Assert.Equal(["New clip from selection", "Find clips with AI"], shell.Rows.Where(row => row.Kind == SidebarKind.Action).Select(row => row.Title));
        Assert.Equal(["Ctrl+K", "Ctrl+Shift+K"], shell.Rows.Where(row => row.Kind == SidebarKind.Action).Select(row => row.Detail));
    }

    [Fact]
    public void FullTakeNamesItsEditedLength()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        var full = shell.Rows.Single(row => row.Kind == SidebarKind.FullTake);
        Assert.Equal(EditorViewModel.Duration(editor.FullTakeDuration), full.Meta);
        Assert.Equal($"Full take, {ShellViewModel.Spoken(editor.FullTakeDuration)} after cuts", full.AccessibleName);
        Assert.InRange(editor.FullTakeDuration, 1, editor.Project.Media.Source.DurationSeconds);
    }

    [Theory]
    [InlineData(0, "0 seconds")]
    [InlineData(1, "1 second")]
    [InlineData(20.4, "20 seconds")]
    [InlineData(60, "1 minute")]
    [InlineData(130, "2 minutes 10 seconds")]
    [InlineData(61, "1 minute 1 second")]
    public void SpokenLengthsReadNaturally(double seconds, string expected) => Assert.Equal(expected, ShellViewModel.Spoken(seconds));

    [Fact]
    public void RowsKeepTheirInstancesAcrossRebuilds()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        var before = shell.Rows.ToArray();
        var changes = 0;
        shell.Rows.CollectionChanged += (_, _) => changes++;
        shell.Update(editor, false, [], null);
        Assert.Equal(before, shell.Rows);
        Assert.Equal(0, changes);
        editor.Select(0); editor.Select(2, true);
        Assert.NotNull(editor.MakeClip());
        shell.Update(editor, false, [], null);
        Assert.Equal(1, changes);
        Assert.All(before, row => Assert.Contains(row, shell.Rows));
        var numbers = shell.Rows.Where(row => row.Kind is SidebarKind.Clip or SidebarKind.Suggestion).Select(row => row.Number);
        Assert.Equal(["1", "2", "3"], numbers);
    }

    [Fact]
    public void ScopeRowFollowsTheActiveClipAndFallsBackToFullTake()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        Assert.Equal(SidebarKind.FullTake, shell.ScopeRow(null)!.Kind);
        var suggestion = editor.Clips.Single(ShellViewModel.IsSuggestion);
        Assert.True(editor.Apply(new EditOperation.SetActiveClip(suggestion.Id)));
        shell.Update(editor, false, [], null);
        var active = shell.ScopeRow(editor.State!.ActiveClipId)!;
        Assert.Equal((SidebarKind.Suggestion, suggestion.Id, true), (active.Kind, active.ClipId, active.IsActive));
        Assert.All(shell.Rows.Where(row => row.ClipId is not null && row != active), row => Assert.False(row.IsActive));
        Assert.Equal(SidebarKind.FullTake, shell.ScopeRow("missing")!.Kind);
    }

    [Fact]
    public void HomeKeepsTheProjectSectionWithoutActionsAndListsOtherRecents()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel();
        var recent = Enumerable.Range(0, 15).Select(index => new RecentProject($@"C:\Projects\take-{index}.voxclip", $"take-{index}")).ToArray();
        shell.Update(editor, true, recent, @"c:\projects\TAKE-0.voxclip");
        Assert.DoesNotContain(shell.Rows, row => row.Kind == SidebarKind.Action);
        Assert.Contains(shell.Rows, row => row.Kind == SidebarKind.FullTake);
        var recents = shell.Rows.Where(row => row.Kind == SidebarKind.Recent).ToArray();
        Assert.Equal(ShellViewModel.RecentLimit, recents.Length);
        Assert.DoesNotContain(recents, row => row.Recent!.Path.EndsWith("take-0.voxclip", StringComparison.Ordinal));
        Assert.Equal("take-1", recents[0].Title);
        Assert.Equal(SidebarKind.RecentHeader, shell.Rows[shell.Rows.IndexOf(recents[0]) - 1].Kind);
        shell.Update(null, true, recent, null);
        Assert.Equal([SidebarKind.Home, SidebarKind.Separator, SidebarKind.RecentHeader], shell.Rows.Take(3).Select(row => row.Kind));
        Assert.Equal("take-0", shell.Rows.First(row => row.Kind == SidebarKind.Recent).Title);
    }

    [Fact]
    public void ActionsFollowSelectionAndTranscript()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        Assert.False(shell.Rows.Single(row => row.Key == "action:make").IsEnabled);
        Assert.True(shell.Rows.Single(row => row.Key == "action:find").IsEnabled);
        editor.Select(3);
        shell.Update(editor, false, [], null);
        Assert.True(shell.Rows.Single(row => row.Key == "action:make").IsEnabled);
        editor.Busy = true;
        shell.Update(editor, false, [], null);
        Assert.All(shell.Rows.Where(row => row.Kind == SidebarKind.Action), row => Assert.False(row.IsEnabled));
    }
}
#endif
