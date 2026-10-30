#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class EditorVoiceLabPresentationTests
{
    private static string Shared => Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!;
    private static Project Fixture(string name) => ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(Shared, "fixtures", "voice-lab", name + ".voxclip")));
    private static string Source(string file) => File.ReadAllText(Path.Combine(Path.GetDirectoryName(Shared)!, "apps/windows/src/VoxClip.App", file));

    [Theory]
    [InlineData("passage-render-v3")]
    [InlineData("full-take-render-v3")]
    public void AcceptedSpeechProjectsIntoTheTranscriptWithoutMutatingSource(string fixture)
    {
        var project = Fixture(fixture);
        var before = ProjectSerialization.Serialize(project);
        var editor = new EditorViewModel(project);
        var segment = project.VoiceLab.Segments.First(segment => segment.Enabled && segment.Words is { Count: > 0 });
        var first = editor.Index(segment.Replace.FirstWordId);
        var last = editor.Index(segment.Replace.LastWordId);
        var speech = editor.PresentedWord(first);
        Assert.True(speech.StartsSegment);
        Assert.True(speech.AiModified);
        Assert.True(speech.Visible);
        Assert.Equal(string.Join(" ", segment.Words!.Select(word => word.Text)), speech.Text);
        Assert.Equal(last, speech.LastSourceIndex);
        Assert.EndsWith(", AI modified", editor.AccessibleWord(first, false));
        foreach (var index in Enumerable.Range(first + 1, last - first)) Assert.False(editor.PresentedWord(index).Visible);
        Assert.Equal(before, ProjectSerialization.Serialize(editor.Project));
        Assert.Equal(project.Transcript!.Words, editor.Words);
        var disabled = VoiceLabProject.SetEnabled(project, segment.Id, false);
        var source = new EditorViewModel(disabled);
        foreach (var index in Enumerable.Range(first, last - first + 1))
        {
            Assert.True(source.PresentedWord(index).Visible);
            Assert.False(source.PresentedWord(index).AiModified);
            Assert.Equal(source.DisplayText(source.Words[index]), source.PresentedWord(index).Text);
            Assert.DoesNotContain(", AI modified", source.AccessibleWord(index, false));
        }
    }

    [Theory]
    [InlineData("passage-render-v3")]
    [InlineData("full-take-render-v3")]
    public void OnePredicateDrivesScopeDisclosureAndSidebarMeta(string fixture)
    {
        var project = Fixture(fixture);
        var editor = new EditorViewModel(project);
        Assert.True(editor.ContainsAiSpeech());
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        var full = shell.Rows.Single(row => row.Kind == SidebarKind.FullTake);
        Assert.Contains("AI modified", full.MetaStatus);
        Assert.EndsWith(", AI modified", full.AccessibleName);
        foreach (var clip in editor.Clips)
        {
            var expected = editor.ContainsAiSpeech(clip.Id);
            var row = shell.Rows.Single(row => row.ClipId == clip.Id);
            Assert.Equal(expected, row.MetaStatus.Contains("AI modified", StringComparison.Ordinal));
        }
        var page = Source("Pages/EditorPage.xaml.cs");
        Assert.Contains("AiModified.Visibility = ViewModel.ContainsAiSpeech(ViewModel.State?.ActiveClipId)", page);
        Assert.Contains("EditorMediaPresentation.Accessible(mediaState, clip?.Number, ViewModel.ContainsAiSpeech", page);
        Assert.Contains("VoiceLabDisclosure.AccessibleName(label, ViewModel.ContainsAiSpeech", page);
        Assert.Contains("Targets().Any(item => model.ContainsAiSpeech", Source("Controls/ExportDialog.cs"));
        Assert.DoesNotContain("ScopeHasAiSpeech", page);
        Assert.DoesNotContain("IsAiWord", Source("ViewModels/EditorViewModel.cs"));
        Assert.DoesNotContain("VoiceLabRenderContract.Prepare", Source("Controls/ExportDialog.cs"));
        Assert.Equal("Export clip…, contains AI-modified speech", VoiceLabDisclosure.AccessibleName("Export clip…", true));
    }

    [Fact]
    public void EvaluationFailuresAndMissingMediaDiscloseInsteadOfHidingTheWarning()
    {
        Assert.True(VoiceLabDisclosure.Contains(() => throw new InvalidOperationException("unavailable snapshot"), null));
        var project = Fixture("passage-render-v3");
        Assert.True(VoiceLabDisclosure.Contains(() => project, "missing-clip"));
        var disabled = project with { VoiceLab = project.VoiceLab with { Segments = project.VoiceLab.Segments.Select(segment => segment with { Enabled = false }).ToArray() } };
        var editor = new EditorViewModel(disabled);
        Assert.False(editor.ContainsAiSpeech());
        editor.SetMediaUnavailable(true);
        Assert.True(editor.ContainsAiSpeech());
        Assert.Contains(", contains AI-modified speech", EditorMediaPresentation.Accessible(EditorMediaState.Missing, null, editor.ContainsAiSpeech()));
        editor.SetMediaUnavailable(false);
        Assert.False(editor.ContainsAiSpeech());
    }

    [Fact]
    public void DisabledLegacySegmentsDoNotClaimAcceptedSpeech()
    {
        var project = Fixture("passage-project");
        var disabled = project with { VoiceLab = project.VoiceLab with { Segments = project.VoiceLab.Segments.Select(segment => segment with { Enabled = false }).ToArray() } };
        Assert.False(VoiceLabDisclosure.Contains(() => disabled, null));
    }

    [Fact]
    public void ChipAndSyntheticUnderlineMatchTheDesignSourceContract()
    {
        var transcript = Source("Controls/TranscriptView.cs");
        var start = transcript.IndexOf("if (speech.StartsSegment)", StringComparison.Ordinal);
        var chip = transcript[start..transcript.IndexOf("var word = model.Words[index]", start, StringComparison.Ordinal)];
        Assert.Contains("BorderBrush = Brush(\"VcAccentTextBrush\")", chip);
        Assert.Contains("BorderThickness = new Thickness(1)", chip);
        Assert.Contains("CornerRadius = new CornerRadius(4)", chip);
        Assert.Contains("FontSize = 10", chip);
        Assert.Contains("FontWeights.SemiBold", chip);
        Assert.Contains("VcMonoFontFamily", chip);
        Assert.Contains("VcAccentSoftBrush", chip);
        Assert.Contains("speech.Text + \" \"", transcript);
        Assert.Contains("if (!speech.Visible) continue", transcript);
        Assert.Contains("if (ai) Pattern(rect.X, rect.Y + rect.Height - 1, rect.Width, \"VcAccentTextBrush\", 5, 9, 1)", Source("Controls/TranscriptOverlay.cs"));
    }
}
#endif
