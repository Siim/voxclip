#if DEBUG
using System.Text.Json;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Services;

internal static class VoiceLabNativeProbe
{
    internal static async Task RunAsync(string output)
    {
        Directory.CreateDirectory(output);
        var report = Path.Combine(output, "voice-lab-native-result.json");
        try
        {
            if (App.Services.DebugVoiceLabHttpCalls != 0)
                throw new InvalidOperationException("The Voice Lab probe requires the zero-HTTP fixture backend.");
            var session = App.Services.VoiceLab;
            await session.RefreshEnabledStateAsync();
            if (!session.Enabled || session.VisibleRecords.Count < 2 || session.Operations.Count < 3)
                throw new InvalidOperationException("The enabled consent variants and unfinished operations were not seeded.");
            if (session.CreateBlockedReason != VoiceLabCopy.SpeakerUnavailable)
                throw new InvalidOperationException("The native speaker gate was opened.");
            session.Request(new(VoiceLabRequestKind.Subscription));
            await session.ApproveAsync(false);
            if (session.Subscription is not null) throw new InvalidOperationException("Cancel approved the account check.");
            App.OpenSettings("Voice Lab");
            await File.WriteAllTextAsync(report, JsonSerializer.Serialize(new
            {
                status = "passed", httpCalls = App.Services.DebugVoiceLabHttpCalls,
                records = session.VisibleRecords.Select(VoiceLabSession.CardName),
                operations = session.Operations.Select(operation => operation.DisplayState),
                createBlockedReason = session.CreateBlockedReason,
                owed = "UIA read-out, confirmation default/Esc, light/dark/high-contrast captures"
            }));
        }
        catch (Exception exception)
        {
            await File.WriteAllTextAsync(report, JsonSerializer.Serialize(new { status = "failed", error = exception.ToString() }));
            throw;
        }
    }
}
#endif
