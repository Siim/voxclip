#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>Windows copy names the Windows Settings sections and the editor's words: AI keys and connectors live in "Providers &
/// Keys" (the Mac pane is "AI"), and the source's own frame is "Original" everywhere.</summary>
public sealed class WindowsSettingsCopyTests
{
    [Theory]
    [InlineData("Open project", "project-open")]
    [InlineData("Save project", "project-save")]
    [InlineData("Locate media", "relink")]
    [InlineData("Export", "export")]
    [InlineData("Share", "share")]
    [InlineData("Rewrite", "rewrite")]
    [InlineData("Settings", "settings")]
    [InlineData("Open video", "import")]
    [InlineData("Transcribe", "transcribe")]
    [InlineData("Local models", "models")]
    [InlineData("Preview", "preview")]
    [InlineData("Preview card", "preview-card")]
    [InlineData("Waveform", "waveform")]
    [InlineData("Find clips", "llm")]
    [InlineData("Ask Claude", "ask-claude")]
    [InlineData("Make it postable", "make-it")]
    [InlineData("Voice Lab", "voice-lab")]
    [InlineData("Captions", "captions")]
    [InlineData("Editing", "editing")]
    [InlineData("Music", "music")]
    [InlineData("Startup", "startup")]
    [InlineData("Update", "update")]
    [InlineData("/private/Interview.mp4", "ui")]
    public async Task AVisibleFailureLogsTheActionAndErrorKindButNoInput(string action, string category)
    {
        var directory = Directory.CreateTempSubdirectory();
        try
        {
            await using var log = new Log(directory.FullName);
            var error = new VoxClipException(VoxClipErrorCode.ProviderError, "Private interview at /private/Interview.mp4");
            Assert.Contains("Private interview", UiError.Message(error, action, log));
            var line = Assert.Single(await log.ReadRecentAsync(10, CancellationToken.None));
            Assert.EndsWith($"error [{category}] type=VoxClipException case=providerError", line);
        }
        finally { directory.Delete(recursive: true); }
    }

    [Fact]
    public async Task CancellationDoesNotLogAndProviderRepliesNeverAppearInDiagnostics()
    {
        var directory = Directory.CreateTempSubdirectory();
        try
        {
            await using var log = new Log(directory.FullName);
            Assert.Empty(UiError.Message(new OperationCanceledException(), "Export", log));
            Assert.Empty(UiError.Message(new VoxClipException(VoxClipErrorCode.Cancelled, "Private interview"), "Rewrite", log));
            var error = new LlmException(new(LlmErrorKind.Unauthorized, VoxClipErrorCode.KeyRejected, "Private interview reply"));
            Assert.Contains("Private interview", UiError.Message(error, "Connection test", log));
            var line = Assert.Single(await log.ReadRecentAsync(10, CancellationToken.None));
            Assert.EndsWith("error [settings] type=LlmException case=Unauthorized", line);
        }
        finally { directory.Delete(recursive: true); }
    }

    private static string AppRoot => Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps/windows/src/VoxClip.App");

    [Fact]
    public void AiMessagesPointAtProvidersAndKeys()
    {
        var settings = System.Xml.Linq.XDocument.Load(Path.Combine(AppRoot, "SettingsWindow.xaml"));
        Assert.Contains(settings.Descendants().Select(element => (string?)element.Attribute("Tag")), tag => tag == SettingsSections.ProvidersAndKeys);
        Assert.DoesNotContain(settings.Descendants().Select(element => (string?)element.Attribute("Tag")), tag => tag == "AI");
        Assert.Equal("Add your Anthropic API key in Settings › Providers & Keys. Your edits are saved.",
            ClipCallouts.NotReady(ConnectorId.Anthropic, "Anthropic", new ConnectorStatus.NeedsKey(), null, null).Message);
        // Core's shared AI errors name the Mac pane; the Windows boundary renames it.
        Assert.Equal("Add your OpenAI API key in Settings › Providers & Keys. Your edits are saved.", UiError.Message(new LlmException(
            new(LlmErrorKind.MissingKey, VoxClipErrorCode.KeyMissing, "Add your OpenAI API key in Settings › AI. Your edits are saved.")), "Find clips"));
        Assert.Equal("OpenAI rejected the API key. Check it in Settings › Providers & Keys. Your edits are saved.", UiError.Message(new LlmException(
            new(LlmErrorKind.Unauthorized, VoxClipErrorCode.KeyRejected, "OpenAI rejected the API key. Check it in Settings › AI. Your edits are saved.")), "Rewrite"));
        // Only the renaming helper itself may spell the Mac pane.
        foreach (var file in Directory.EnumerateFiles(AppRoot, "*.cs", SearchOption.AllDirectories)
                     .Where(path => !path.Contains("/obj/") && !path.Contains("/bin/") && Path.GetFileName(path) != "SettingsSections.cs"))
        {
            var text = File.ReadAllText(file);
            Assert.DoesNotContain("Settings › AI", text);
            Assert.DoesNotContain("Settings → AI", text);
        }
    }

    [Fact]
    public void ExportSettingsSayOriginalLikeTheEditor()
    {
        var settings = File.ReadAllText(Path.Combine(AppRoot, "SettingsWindow.xaml.cs"));
        Assert.Contains("Ui.Choice(\"Default aspect\", [\"Original\", \"16:9\", \"9:16\", \"1:1\"]", settings);
        Assert.Contains("var aspects = new[] { \"source\", \"16:9\", \"9:16\", \"1:1\" };", settings);
        Assert.Contains("Content=\"Original\"", File.ReadAllText(Path.Combine(AppRoot, "Pages/EditorPage.xaml")));
        Assert.Contains("\"Original\"]", File.ReadAllText(Path.Combine(AppRoot, "Controls/ExportDialog.cs")));
    }
}
#endif
