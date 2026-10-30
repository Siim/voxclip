#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>Windows copy names the Windows Settings sections and the editor's words: AI keys and connectors live in "Providers &
/// Keys" (the Mac pane is "AI"), and the source's own frame is "Original" everywhere.</summary>
public sealed class WindowsSettingsCopyTests
{
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
