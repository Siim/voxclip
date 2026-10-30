using System.Globalization;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.ViewModels;

internal static class VoiceLabActionNames
{
    internal static string Created(string name, DateTimeOffset date)
    {
        string[] months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
        return string.Create(CultureInfo.InvariantCulture, $"{name}, created {date.Day} {months[date.Month - 1]} {date.Year}");
    }

    internal static string ForRecord(string action, VoiceConsentRecord record, IReadOnlyList<VoiceConsentRecord> peers)
    {
        var label = Created(record.VoiceName, record.CreatedAt);
        var suffix = peers.Count(peer => Created(peer.VoiceName, peer.CreatedAt) == label) > 1
            ? ", voice ID ending " + Ending(record.VoiceId) : "";
        return action + " " + label + suffix;
    }

    internal static string ForOperation(string action, VoiceOperation operation, IReadOnlyList<VoiceOperation> peers,
        IReadOnlyList<VoiceConsentRecord> records)
    {
        string Label(VoiceOperation value)
        {
            var record = records.FirstOrDefault(record => record.RecordId == value.RecordId);
            return Created(record?.VoiceName ?? (value.Kind == VoiceOperationKind.Create ? "Voice creation" : "Voice removal"), record?.CreatedAt ?? value.StartedAt);
        }
        var label = Label(operation);
        var suffix = "";
        if (peers.Count(peer => Label(peer) == label) > 1)
        {
            var voiceId = operation.RemoteVoiceId ?? records.FirstOrDefault(record => record.RecordId == operation.RecordId)?.VoiceId;
            suffix = voiceId is not null and not "pending" ? ", voice ID ending " + Ending(voiceId)
                : ", attempt " + (peers.ToList().FindIndex(peer => peer.Id == operation.Id) + 1).ToString(CultureInfo.InvariantCulture);
        }
        return action + " " + label + suffix;
    }

    private static string Ending(string value) => value.Length <= 6 ? value : value[^6..];
}
