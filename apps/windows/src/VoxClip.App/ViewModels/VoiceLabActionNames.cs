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
        var matching = peers.Where(peer => Created(peer.VoiceName, peer.CreatedAt) == label).ToArray();
        var suffix = matching.Length > 1
            ? matching.Count(peer => Ending(peer.VoiceId) == Ending(record.VoiceId)) > 1
                ? ", voice ID " + record.VoiceId : ", voice ID ending " + Ending(record.VoiceId)
            : "";
        return action + " " + label + suffix;
    }

    internal static string ForOperation(string action, VoiceOperation operation, IReadOnlyList<VoiceOperation> peers,
        IReadOnlyList<VoiceConsentRecord> records)
    {
        string Label(VoiceOperation value)
        {
            if (value.Kind == VoiceOperationKind.Create && value.ExpectedVoiceName is { } name) return Created(name, value.StartedAt);
            var record = records.FirstOrDefault(record => record.RecordId == value.RecordId);
            return Created(record?.VoiceName ?? (value.Kind == VoiceOperationKind.Create ? "Voice creation" : "Voice removal"), record?.CreatedAt ?? value.StartedAt);
        }
        string? VoiceId(VoiceOperation value)
        {
            var voiceId = value.RemoteVoiceId ?? records.FirstOrDefault(record => record.RecordId == value.RecordId)?.VoiceId;
            return voiceId is not null and not "pending" ? voiceId : null;
        }
        var label = Label(operation);
        var suffix = "";
        var matching = peers.Where(peer => Label(peer) == label).ToArray();
        if (matching.Length > 1)
        {
            var voiceId = VoiceId(operation);
            suffix = voiceId is not null
                ? matching.Count(peer => VoiceId(peer) is { } peerId && Ending(peerId) == Ending(voiceId)) > 1
                    ? ", voice ID " + voiceId : ", voice ID ending " + Ending(voiceId)
                : ", attempt " + (peers.ToList().FindIndex(peer => peer.Id == operation.Id) + 1).ToString(CultureInfo.InvariantCulture);
        }
        return action + " " + label + suffix;
    }

    private static string Ending(string value) => value.Length <= 6 ? value : value[^6..];
}
