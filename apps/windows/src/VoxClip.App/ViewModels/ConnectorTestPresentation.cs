using System.Globalization;
using VoxClip.Core.Services.LLM;

namespace VoxClip.App.ViewModels;

internal static class ConnectorTestPresentation
{
    internal static string Text(LlmConnectionTestResult result) => !result.Passed
        ? "The model answered, but not as expected. It may not follow instructions well."
        : result.UsedFallback ? $"Works · answered by {result.Model}"
        : $"Works · {result.Model} · {result.Seconds.ToString("0.0", CultureInfo.InvariantCulture)} s";
    internal static string Failure(Exception error) => "Failed: " + UiError.Message(error, "Connection test");
}
