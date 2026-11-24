using System.Globalization;
using System.Text;
using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

public sealed record SavedWholeClipVoice(Project Draft, IReadOnlyList<string> SegmentIds, decimal Spent)
{
    public WholeClipVoiceRecovery? Recovery { get; init; }
    public VoiceLabEditCommand.AcceptAll Voice(string recordId)
    {
        var segments = SegmentIds.Select(id => Draft.VoiceLab.Segments.Single(segment => segment.Id == id)).ToArray();
        var ids = segments.SelectMany(segment => segment.Candidates).Select(candidate => candidate.AssetId).ToHashSet(StringComparer.Ordinal);
        var assets = Draft.VoiceLab.Assets!.Where(asset => ids.Contains(asset.Id)).ToArray();
        var voice = Draft.VoiceLab.Voices!.Single(voice => voice.ConsentRecordId == recordId);
        return new(segments, assets, voice);
    }
}

public sealed record WholeClipVoiceRecovery(string BaseKey, string Identity, string ClipId, string RecordId, string Script);

public static class WholeClipVoiceCheckpoint
{
    private const int Limit = 32 * 1024 * 1024;

    public static SavedWholeClipVoice? Read(string paidRoot, string projectId, string baseKey, string identity)
    {
        var path = Path.Combine(Folder(paidRoot, projectId, baseKey, false), Key(identity) + ".draft");
        if (!File.Exists(path)) return null;
        if ((File.GetAttributes(path) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0 || new FileInfo(path).Length > Limit)
            throw Invalid();
        using var reader = new StreamReader(path);
        var header = reader.ReadLine();
        var price = reader.ReadLine();
        var ids = reader.ReadLine()?.Split(' ');
        var recovery = reader.ReadLine();
        if (header != "voxclip-windows-whole-clip-voice/1" || recovery is null || ids is not { Length: > 0 } ||
            ids.Length > VoiceLabTakeBatch.MaximumRunPhrases || !ids.All(id => Guid.TryParseExact(id, "D", out _)) ||
            ids.Distinct(StringComparer.Ordinal).Count() != ids.Length ||
            !decimal.TryParse(price, NumberStyles.Number, CultureInfo.InvariantCulture, out var spent) || spent < 0) throw Invalid();
        var draft = ProjectSerialization.Deserialize(reader.ReadToEnd());
        if (draft.Id != projectId || ids.Any(id => !draft.VoiceLab.Segments.Any(segment => segment.Id == id && segment.Enabled && segment.Kind == VoiceLabSegmentKind.Tts)))
            throw Invalid();
        var info = JsonSerializer.Deserialize<WholeClipVoiceRecovery>(recovery);
        if (info is null || info.BaseKey != baseKey || info.Identity != identity || info.Script.Length is < 1 or > 100_000 ||
            !Guid.TryParseExact(info.RecordId, "D", out _) || !draft.Edits.Clips.Any(clip => clip.Id == info.ClipId)) throw Invalid();
        return new(draft, ids, spent) { Recovery = info };
    }

    public static SavedWholeClipVoice? ReadLatest(string paidRoot, string projectId, string baseKey)
    {
        var folder = Folder(paidRoot, projectId, baseKey, false);
        if (!Directory.Exists(folder)) return null;
        var draft = new DirectoryInfo(folder).EnumerateFiles("*.draft").MaxBy(file => file.LastWriteTimeUtc);
        return draft is null ? null : Read(paidRoot, projectId, baseKey, Path.GetFileNameWithoutExtension(draft.Name));
    }

    public static void Keep(string paidRoot, SavedWholeClipVoice saved)
    {
        var info = saved.Recovery ?? throw Invalid();
        var path = Path.Combine(Folder(paidRoot, saved.Draft.Id, info.BaseKey, true), Key(info.Identity) + ".draft");
        var contents = Encoding.UTF8.GetBytes("voxclip-windows-whole-clip-voice/1\n" + saved.Spent.ToString(CultureInfo.InvariantCulture) +
            "\n" + string.Join(' ', saved.SegmentIds) + "\n" + JsonSerializer.Serialize(saved.Recovery) + "\n" + ProjectSerialization.Serialize(saved.Draft));
        if (contents.Length > Limit) throw Invalid();
        Write(path, contents);
    }

    private static void Write(string path, byte[] contents)
    {
        var partial = path + "." + Guid.NewGuid().ToString("N") + ".part";
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Options = FileOptions.WriteThrough };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        try
        {
            using (var file = new FileStream(partial, options)) { file.Write(contents); file.Flush(true); }
            File.Move(partial, path);
        }
        finally { File.Delete(partial); }
    }

    private static string Key(string value) => value.Length == 64 && value.All(Uri.IsHexDigit) ? value : throw Invalid();

    private static string Folder(string paidRoot, string projectId, string baseKey, bool create)
    {
        _ = VoiceLabAssetNaming.File(projectId, "whole-clip", "wav");
        var root = Path.GetFullPath(paidRoot);
        var project = Path.Combine(root, projectId);
        var folder = Path.Combine(project, "whole-clip-voice");
        if (create || Directory.Exists(folder))
        {
            VoiceLabAssetStore.RequireDirectory(root, "whole-clip", create);
            VoiceLabAssetStore.RequireDirectory(project, "whole-clip", create);
            if (create && !Directory.Exists(folder)) VoiceConsentPrivacy.CreateDirectory(folder);
            VoiceLabAssetStore.RequireDirectory(folder, "whole-clip", false);
            VoiceConsentPrivacy.Validate(folder, true);
        }
        var bucket = Path.Combine(folder, Key(baseKey));
        if (create && !Directory.Exists(bucket)) VoiceConsentPrivacy.CreateDirectory(bucket);
        if (Directory.Exists(bucket))
        {
            VoiceLabAssetStore.RequireDirectory(bucket, "whole-clip", false);
            VoiceConsentPrivacy.Validate(bucket, true);
        }
        return bucket;
    }

    private static IOException Invalid() => new("The saved whole-clip voice couldn't be verified. No new job was sent.");
}
