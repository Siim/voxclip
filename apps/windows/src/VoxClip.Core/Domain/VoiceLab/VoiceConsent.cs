using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Speech;
#pragma warning disable CS1591

namespace VoxClip.Core.Domain.VoiceLab;

public enum VoiceConsentError
{
    InvalidRecord, InvalidName, InvalidWords, AttestationsRequired, StatementMismatch, TooManyAttempts,
    SpeakerUnavailable, SpeakerMismatch, VoiceOwnerMismatch, Inactive, CreationPending
}

public sealed class VoiceConsentException(VoiceConsentError kind) : Exception(kind.ToString())
{
    public VoiceConsentError Kind { get; } = kind;
}

public sealed record VoiceConsentStatement(string Language, string Text, IReadOnlyList<string> Nonce);

public sealed record VoiceConsentText(string Schema, Dictionary<string, string> Templates, Dictionary<string, string[]> Months)
{
    public static string DisplayName(string value)
    {
        var name = value.Trim();
        if (name.EnumerateRunes().Count() is < 1 or > 60 || name.Any(char.IsControl))
            throw new VoiceConsentException(VoiceConsentError.InvalidName);
        return name;
    }

    public VoiceConsentStatement Statement(string name, string? language, DateOnly localDate, IReadOnlyList<string> words)
    {
        name = DisplayName(name);
        language = language == "et" ? "et" : "en";
        if (Schema != "voxclip-voice-statements/1" || !Templates.TryGetValue(language, out var template) ||
            !Months.TryGetValue(language, out var months) || months.Length != 12 || words.Count < 500 ||
            words.Distinct(StringComparer.Ordinal).Count() != words.Count ||
            words.Any(word => word.EnumerateRunes().Count() is < 4 or > 8 || !word.EnumerateRunes().All(Rune.IsLetter)))
            throw new VoiceConsentException(VoiceConsentError.InvalidWords);
        var available = words.ToList();
        var nonce = new string[4];
        for (var index = 0; index < nonce.Length; index++)
        {
            var position = RandomNumberGenerator.GetInt32(available.Count);
            nonce[index] = available[position];
            available.RemoveAt(position);
        }
        var date = localDate.Day.ToString(CultureInfo.InvariantCulture) + (language == "et" ? ". " : " ") +
            months[localDate.Month - 1] + " " + localDate.Year.ToString(CultureInfo.InvariantCulture);
        var text = template.Replace("{name}", name, StringComparison.Ordinal).Replace("{date}", date, StringComparison.Ordinal);
        for (var index = 0; index < nonce.Length; index++) text = text.Replace("{w" + (index + 1) + "}", nonce[index], StringComparison.Ordinal);
        return new(language, text, Array.AsReadOnly(nonce));
    }
}

public sealed record VoiceStatementMatch(double Wer, string TranscriptionId)
{
    public static VoiceStatementMatch Verify(RawTranscript transcript, VoiceConsentStatement statement)
    {
        static string[] Tokens(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Select(EditingAlgorithms.NormalizeForMatch).Where(word => word.Length != 0).ToArray();
        var expected = Tokens(statement.Text);
        var recognized = Tokens(string.Join(" ", transcript.Tokens.Select(token => token.Text)));
        if (expected.Length == 0 || recognized.Length > 1000) throw new VoiceConsentException(VoiceConsentError.StatementMismatch);
        var previous = Enumerable.Range(0, recognized.Length + 1).ToArray();
        for (var index = 0; index < expected.Length; index++)
        {
            var current = new int[recognized.Length + 1];
            current[0] = index + 1;
            for (var other = 0; other < recognized.Length; other++)
                current[other + 1] = Math.Min(Math.Min(current[other] + 1, previous[other + 1] + 1),
                    previous[other] + (expected[index] == recognized[other] ? 0 : 1));
            previous = current;
        }
        var wer = previous[^1] / (double)expected.Length;
        if (wer > 0.15 || statement.Nonce.Count != 4 || statement.Nonce.Distinct().Count() != 4 ||
            statement.Nonce.Any(word => !recognized.Contains(EditingAlgorithms.NormalizeForMatch(word))) || transcript.Language != statement.Language)
            throw new VoiceConsentException(VoiceConsentError.StatementMismatch);
        return new(wer, transcript.ProviderRequestId ?? "");
    }
}

[JsonConverter(typeof(JsonStringEnumConverter<VoiceConsentStatus>))]
public enum VoiceConsentStatus
{
    [JsonStringEnumMemberName("active")] Active,
    [JsonStringEnumMemberName("verificationRequired")] VerificationRequired,
    [JsonStringEnumMemberName("deleted")] Deleted
}
public sealed record VoiceConsentStatementRecord(string Language, string Text, string[] Nonce, string AudioFile, string AudioSha256, VoiceStatementMatch Stt);
public sealed record VoiceConsentAttestations(bool OwnVoice, bool Adult, bool OwnVideosOnly, DateTimeOffset AcceptedAt)
{
    [JsonIgnore] public bool Complete => OwnVoice && Adult && OwnVideosOnly;
}
public sealed record VoiceConsentSample(string Sha256, double Seconds, string Source, double SpeakerScore);
public sealed record VoiceConsentSpeaker(string Model, double Threshold, string Embedding);
public sealed record VoiceConsentApp(string Version, string Platform);
public sealed record VoiceConsentCreator(ElevenLabsRegion Region, string? KeyFingerprint)
{
    public static string Fingerprint(string key) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(key)))[..16];
    public void Validate()
    {
        if (!Enum.IsDefined(Region) || KeyFingerprint is { } hash && (hash.Length != 16 || hash.Any(character => !char.IsAsciiHexDigitLower(character))))
            throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
    }
}
public sealed class VoiceCreatorMismatchException() : Exception(Explanation)
{
    public const string Explanation = "This voice was created with a different ElevenLabs key or region. Use that key to delete it, or remove it from VoxClip only; the voice may stay in that ElevenLabs account.";
}
public sealed record VoiceConsentRecord(string Schema, string RecordId, string Provider, string Type, string VoiceId, string VoiceName,
    VoiceConsentStatus Status, DateTimeOffset CreatedAt, DateTimeOffset? DeletedAt, VoiceConsentStatementRecord Statement,
    VoiceConsentAttestations Attestations, VoiceConsentSample[] Samples, VoiceConsentSpeaker Speaker, VoiceConsentApp App,
    VoiceConsentCreator? Creator = null)
{
    public void Validate()
    {
        Creator?.Validate();
        if (Schema != "voxclip-consent/1" || !Guid.TryParseExact(RecordId, "D", out _) || Provider != "elevenlabs" || Type != "ivc" ||
            !SafeId(VoiceId) || VoiceName.EnumerateRunes().Count() is < 1 or > 70 || !Enum.IsDefined(Status) || !Attestations.Complete ||
            Statement.AudioFile != "statement.wav" || Statement.Language is not ("en" or "et") || Statement.Text.Length == 0 ||
            Statement.Nonce.Length != 4 || Statement.Nonce.Distinct().Count() != 4 || !double.IsFinite(Statement.Stt.Wer) ||
            Statement.Stt.Wer is < 0 or > 0.15 || !HashValid(Statement.AudioSha256) || Speaker.Model.Length == 0 ||
            !double.IsFinite(Speaker.Threshold) || Speaker.Threshold is < 0 or > 1 || DecodeEmbedding(Speaker.Embedding) is null ||
            Samples.Length is < 1 or > 24 || Samples.Any(sample => !HashValid(sample.Sha256) || !double.IsFinite(sample.Seconds) ||
                sample.Seconds is < 5 or > 30 || sample.Source is not ("project" or "readAloud") || !double.IsFinite(sample.SpeakerScore) ||
                sample.SpeakerScore < Speaker.Threshold || sample.SpeakerScore > 1.00001) ||
            App.Platform is not ("macos" or "windows") || App.Version.Length == 0 || (Status == VoiceConsentStatus.Deleted) != DeletedAt.HasValue)
            throw new VoiceConsentException(VoiceConsentError.InvalidRecord);
    }
    internal VoiceConsentRecord AssignVoice(string id, bool verification) => this with
    {
        VoiceId = id, Status = verification ? VoiceConsentStatus.VerificationRequired : VoiceConsentStatus.Active, DeletedAt = null
    };
    internal static bool SafeId(string value) => value.Length is >= 1 and <= 128 && value.All(character => char.IsAsciiLetterOrDigit(character) || character is '_' or '-');
    internal static bool HashValid(string value) => value.Length == 64 && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');
    public static string EncodeEmbedding(IReadOnlyList<float> values)
    {
        var bytes = new byte[values.Count * 4];
        for (var index = 0; index < values.Count; index++) BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(index * 4), values[index]);
        return Convert.ToBase64String(bytes);
    }
    public static float[]? DecodeEmbedding(string text)
    {
        byte[] bytes;
        try { bytes = Convert.FromBase64String(text); } catch (FormatException) { return null; }
        if (bytes.Length is 0 or > 65536 || bytes.Length % 4 != 0) return null;
        var result = new float[bytes.Length / 4];
        var norm = 0.0;
        for (var index = 0; index < result.Length; index++)
        {
            result[index] = BinaryPrimitives.ReadSingleLittleEndian(bytes.AsSpan(index * 4));
            if (!float.IsFinite(result[index])) return null;
            norm += (double)result[index] * result[index];
        }
        return Math.Abs(norm - 1) <= 0.01 ? result : null;
    }
}
