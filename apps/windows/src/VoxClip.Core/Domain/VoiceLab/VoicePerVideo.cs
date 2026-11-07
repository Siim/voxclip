using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>"A matching voice for each video" (voice-lab.md §6.13, ADR-R45; Mac <c>VoicePerVideo</c>): a clone made from one video's own
/// owner-verified speech, used for every Rewrite take of that video, with the consent voice (the anchor) as the fallback. Pure; the Media
/// finder supplies the speech, the attested creation sends it, and <c>VoicePerVideoStore</c> remembers it.
///
/// Clips of one video share its microphone, room and noise, so the voice is per video, never per clip: a 20–45 s clip is too little speech
/// for a clone.</summary>
public static class VoicePerVideo
{
    /// <summary>The cleanliness floor for a video's own speech. Creation then sets <c>remove_background_noise</c> (§6.5 step 5), and the tone
    /// match and room tone at render put the room back. Identity is unchanged: every piece is one hop at τ. Chosen from the measurement in
    /// ADR-R45.</summary>
    public const double MinimumSnrDb = 8.0;
    /// <summary>The video's own speech a voice needs, the anchor's clip not counted, so the clone is the video's and not the statement's.
    /// Below it the video keeps the anchor and says so once.</summary>
    public const long MinimumVideoMs = VoiceTrainingSpans.TotalMinMs;
    /// <summary>The setting the one-time opt-in writes: true, false, or unset (null). No default.</summary>
    public const string SettingKey = "voiceLab.matchEachVideo";
    /// <summary>The longest display name a voice takes (§6.7); " (VoxClip)" is added after it.</summary>
    public const int MaximumNameScalars = 60;

    /// <summary>The remembered answer to "Make a matching voice from this video?".</summary>
    public enum Mode
    {
        /// <summary>Unset: the first Rewrite, Make it postable or Claude-mode run on a video asks, inline.</summary>
        Ask,
        /// <summary>Each video gets its own voice; the previous video's is removed.</summary>
        Match,
        /// <summary>Every video uses the anchor.</summary>
        Anchor
    }

    /// <summary>The mode a stored setting means.</summary>
    public static Mode FromSetting(bool? setting) => setting switch { true => Mode.Match, false => Mode.Anchor, null => Mode.Ask };
    /// <summary>The setting a mode stores.</summary>
    public static bool? ToSetting(Mode mode) => mode switch { Mode.Match => true, Mode.Anchor => false, _ => null };

    /// <summary>Creation removes background noise when any of the video's pieces is under the §6.5.1 clean-speech floor.</summary>
    public static bool RemovesBackgroundNoise(VoiceRebuild.Plan plan) => plan.Pieces.Any(piece => piece.SnrDb < VoiceTrainingSpans.MinSnrDb);

    /// <summary>The video's own speech in a plan, the anchor's clip not counted.</summary>
    public static long VideoMs(VoiceRebuild.Plan plan) => plan.TotalMs - (plan.KeptMs ?? 0);

    /// <summary>"siim · DJI_0030": the anchor's display name, a middle dot and the video's title, within 60 scalars (the title is cut first,
    /// at a scalar). Control characters and line breaks in the title become spaces; an empty title keeps the anchor's name alone.</summary>
    public static string DisplayName(string owner, string title)
    {
        var clean = string.Concat(title.EnumerateRunes().Select(rune => Rune.GetUnicodeCategory(rune) == UnicodeCategory.Control ? " " : rune.ToString())).Trim();
        var ownerRunes = owner.EnumerateRunes().Take(MaximumNameScalars).ToArray();
        var ownerText = string.Concat(ownerRunes.Select(rune => rune.ToString()));
        if (clean.Length == 0 || ownerRunes.Length + 3 >= MaximumNameScalars) return ownerText;
        var room = MaximumNameScalars - ownerRunes.Length - 3;
        var cut = string.Concat(clean.EnumerateRunes().Take(room).Select(rune => rune.ToString())).Trim();
        return ownerText + " · " + cut;
    }

    /// <summary>A video's title: its media file's name without the extension.</summary>
    public static string Title(string mediaPath) => Path.GetFileNameWithoutExtension(mediaPath.Replace('\\', '/').Split('/')[^1]);

    /// <summary>Why the previous video's voice is kept for now.</summary>
    public enum Keep
    {
        /// <summary>The consent voice: never removed by this flow.</summary>
        Anchor,
        /// <summary>Its project still holds paid takes nobody used or discarded yet.</summary>
        PendingTakes,
        /// <summary>It is the voice being made or used now.</summary>
        Current
    }

    /// <summary>Why <paramref name="recordId"/>, the voice of a video before this one, is kept, or null when it may be removed now. Takes
    /// already rendered into a project never keep it: rendered assets stay playable after deletion (§6.10).</summary>
    public static Keep? Kept(string recordId, string anchorId, string currentId, IReadOnlySet<string> pendingTakes)
    {
        if (recordId == anchorId) return Keep.Anchor;
        if (recordId == currentId) return Keep.Current;
        if (pendingTakes.Contains(recordId)) return Keep.PendingTakes;
        return null;
    }

    /// <summary>Seeds a new video voice's length calibration from the anchor's (§8.2.2): its measured takes start the new voice's estimate,
    /// and the new voice's own takes then replace them as they arrive (the last N per model are kept).</summary>
    public static VoiceLabVoiceCalibration SeededCalibration(VoiceLabVoiceCalibration anchor, string recordId) =>
        new(recordId, anchor.Models, seeded: true);

    /// <summary>The most earlier takes the anchor's baseline reads (voice-lab §6.13), newest first.</summary>
    public const int MaximumBaselineTakes = 12;

    /// <summary>The anchor's earlier takes in a project, newest first (then by segment id): accepted (enabled) text-to-speech segments made
    /// with the voice <paramref name="anchorId"/>, each with its asset (Mac <c>anchorTakes</c>). A recorded take, a voice-changed one,
    /// another voice's take and a take the user turned off are not the anchor's.</summary>
    public static IReadOnlyList<(VoiceLabSegment Segment, VoiceLabAsset Asset)> AnchorTakes(Project project, string anchorId)
    {
        ArgumentNullException.ThrowIfNull(project);
        var assets = project.VoiceLab.Assets ?? [];
        return project.VoiceLab.Segments
            .Where(segment => segment.Kind == VoiceLabSegmentKind.Tts && segment.Enabled && segment.Provenance.ConsentRecordId == anchorId)
            .Select(segment => (Segment: segment, Asset: assets.FirstOrDefault(asset => asset.Id == segment.Audio.AssetId)))
            .Where(take => take.Asset is not null)
            .Select(take => (take.Segment, take.Asset!))
            .OrderByDescending(take => take.Item1.Provenance.CreatedAt).ThenBy(take => take.Item1.Id, StringComparer.Ordinal)
            .ToArray();
    }

    /// <summary>"Match this video · free": the creation price from the catalogue's <c>createClone</c> row; null when it has no price, which
    /// the opt-in then says instead of inventing one.</summary>
    public static string? PriceLabel(VoiceLabPriceCatalog? catalog)
    {
        if (catalog is null) return null;
        try
        {
            var estimate = VoiceLabPricing.Estimate(VoiceLabPricedOperation.ElevenLabsCreateClone, null, 1, 1, null, catalog);
            return estimate.Usd is not { } usd ? null : usd == 0 ? "free" : VoiceLabCostPresentation.Format(usd);
        }
        catch (VoiceLabException) { return null; }
    }
}

/// <summary>What Voice Lab remembers about per-video voices (Mac <c>VoicePerVideoBook</c>, schema <c>voxclip-voice-per-video/1</c>), in app
/// data (<c>&lt;data&gt;/VoiceLab/per-video.json</c>), never in a project file: which voice each video's content key uses, the removals still
/// owed, the videos already told they keep the anchor, and the "did matching help" diagnostics. Both apps read each other's file: sorted
/// keys, absent optionals omitted.</summary>
public sealed record VoicePerVideoBook
{
    /// <summary>The book's schema.</summary>
    public const string SchemaId = "voxclip-voice-per-video/1";
    /// <summary>Diagnostics kept, newest first.</summary>
    public const int MaximumMeasurements = 12;

    /// <summary>One video's own voice. <see cref="AnchorId"/> is the consent voice it was made from: its consent clip is the new voice's first
    /// file, so the new record's embedding is the anchor's own and the one-hop bound is unchanged; <see cref="AnchorReferenceSha256"/> is
    /// that clip's SHA-256, as sent first. <see cref="VideoSeconds"/> is the video's own speech in the voice, the anchor's clip not counted;
    /// <see cref="RemovesBackgroundNoise"/> says creation asked ElevenLabs to remove background noise (a piece was under 20 dB SNR).</summary>
    public sealed record Video(string ContentKey, string RecordId, string AnchorId, string AnchorReferenceSha256, string Title, string CreatedAt,
        double VideoSeconds, bool RemovesBackgroundNoise);

    /// <summary>A previous video's voice still to remove: kept for its pending takes, or a deletion that failed and retries.
    /// <see cref="LastError"/> is the last failure's one-line reason, null while it only waits for its takes.</summary>
    public sealed record Removal(string RecordId, string Title, int Attempts = 0, string? LastError = null, string? NextAttemptAt = null);

    /// <summary>"Did matching help": a take's speaker cosine against the original speech beside it, on this PC. <see cref="VideoVoice"/> is
    /// the first take with the video's own voice; <see cref="Anchor"/> the anchor's takes in this video, pooled.</summary>
    public sealed record Measurement(string ContentKey, string Title, double? VideoVoice, double? Anchor, string MeasuredAt);

    /// <summary>"Did matching help" before the first video's voice (voice-lab §6.13 item 9; Mac <c>AnchorBaseline</c>): the anchor's takes
    /// already accepted into the owner's projects, each scored against the original speech beside it, with the speaker model that scored
    /// them. <see cref="Score"/> is the mean over <see cref="Takes"/>; null when no earlier take could be read.</summary>
    public sealed record AnchorBaselineEntry(string AnchorId, string Model, double? Score, int Takes, string MeasuredAt);

    /// <summary>The stored schema; <see cref="Validate"/> requires <see cref="SchemaId"/>.</summary>
    public string Schema { get; init; } = SchemaId;
    /// <summary>The current video's voice (at most one: adding another makes the previous one a removal).</summary>
    public IReadOnlyList<Video> Videos { get; init; } = [];
    /// <summary>Previous videos' voices still to remove.</summary>
    public IReadOnlyList<Removal> Removals { get; init; } = [];
    /// <summary>Videos already told, once, that they keep the anchor (too little of their own speech).</summary>
    public IReadOnlyList<string> ShortNoted { get; init; } = [];
    /// <summary>The "did matching help" diagnostics, newest first.</summary>
    public IReadOnlyList<Measurement> Measurements { get; init; } = [];
    /// <summary>The anchor's baseline from its earlier takes; absent in an older book, which reads with none.</summary>
    public AnchorBaselineEntry? AnchorBaseline { get; init; }

    /// <summary>The stored baseline when it is <paramref name="anchorId"/>'s and was scored by <paramref name="model"/>; null otherwise, so it
    /// is measured again.</summary>
    public AnchorBaselineEntry? Baseline(string anchorId, string model)
        => AnchorBaseline is { } baseline && baseline.AnchorId == anchorId && baseline.Model == model ? baseline : null;

    /// <summary>The voice of the video with <paramref name="contentKey"/>, or null.</summary>
    public Video? VideoFor(string contentKey) => Videos.FirstOrDefault(video => video.ContentKey == contentKey);
    /// <summary>Whether <paramref name="recordId"/> is a video's voice, current or still to remove (never the anchor).</summary>
    public bool IsVideoVoice(string recordId) => Videos.Any(video => video.RecordId == recordId) || Removals.Any(removal => removal.RecordId == recordId);

    /// <summary>Adds <paramref name="video"/> as its content key's voice. Every other video's voice becomes a removal (the previous video's),
    /// and one this video had before too.</summary>
    public VoicePerVideoBook Adding(Video video)
    {
        var removals = Removals.ToList();
        foreach (var old in Videos)
            if (old.RecordId != video.RecordId && !removals.Any(removal => removal.RecordId == old.RecordId)) removals.Add(new(old.RecordId, old.Title));
        return this with { Videos = [video], Removals = removals, ShortNoted = ShortNoted.Where(key => key != video.ContentKey).ToArray() };
    }

    /// <summary>One measurement per video, the newest first, merged with what was there; at most <see cref="MaximumMeasurements"/>.</summary>
    public VoicePerVideoBook Measuring(Measurement measurement)
    {
        var merged = measurement;
        if (Measurements.FirstOrDefault(old => old.ContentKey == measurement.ContentKey) is { } previous)
            merged = measurement with { VideoVoice = measurement.VideoVoice ?? previous.VideoVoice, Anchor = measurement.Anchor ?? previous.Anchor };
        var rest = Measurements.Where(old => old.ContentKey != measurement.ContentKey);
        return this with { Measurements = rest.Prepend(merged).Take(MaximumMeasurements).ToArray() };
    }

    private static readonly Regex RecordPattern = new("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z", RegexOptions.CultureInvariant);
    private static bool IsRecord(string id) => RecordPattern.IsMatch(id);
    private static bool IsScore(double? value) => value is not { } score || double.IsFinite(score) && score is >= -1 and <= 1;
    private static int Scalars(string text) => text.EnumerateRunes().Count();

    /// <summary>Throws <see cref="VoiceLabException"/> (InvalidInput) unless the book is one both apps may store.</summary>
    public void Validate()
    {
        static void Require(bool condition) { if (!condition) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput); }
        Require(Schema == SchemaId);
        Require(Videos.Select(video => video.ContentKey).Distinct(StringComparer.Ordinal).Count() == Videos.Count &&
            Videos.Select(video => video.RecordId).Distinct(StringComparer.Ordinal).Count() == Videos.Count);
        foreach (var video in Videos)
        {
            Require(VoiceSpeakerReferences.ContentKeyValid(video.ContentKey) && IsRecord(video.RecordId) && IsRecord(video.AnchorId) && video.RecordId != video.AnchorId);
            Require(video.AnchorReferenceSha256.Length == 64 && video.AnchorReferenceSha256.All(char.IsAsciiHexDigit));
            Require(Scalars(video.Title) <= 200 && double.IsFinite(video.VideoSeconds) && video.VideoSeconds is >= 0 and <= 240);
        }
        Require(Removals.Select(removal => removal.RecordId).Distinct(StringComparer.Ordinal).Count() == Removals.Count && Removals.Count <= 64);
        foreach (var removal in Removals)
        {
            Require(IsRecord(removal.RecordId) && removal.Attempts >= 0 && Scalars(removal.Title) <= 200);
            Require(!Videos.Any(video => video.RecordId == removal.RecordId));
            Require(Scalars(removal.LastError ?? "") <= 300);
        }
        Require(ShortNoted.Count <= 256 && ShortNoted.All(VoiceSpeakerReferences.ContentKeyValid));
        Require(Measurements.Count <= MaximumMeasurements &&
            Measurements.Select(measurement => measurement.ContentKey).Distinct(StringComparer.Ordinal).Count() == Measurements.Count);
        foreach (var measurement in Measurements)
            Require(VoiceSpeakerReferences.ContentKeyValid(measurement.ContentKey) && IsScore(measurement.VideoVoice) && IsScore(measurement.Anchor) &&
                Scalars(measurement.Title) <= 200);
        if (AnchorBaseline is { } baseline)
        {
            Require(IsRecord(baseline.AnchorId) && baseline.Model.Length > 0 && Scalars(baseline.Model) <= 128);
            Require(baseline.Takes is >= 0 and <= VoicePerVideo.MaximumBaselineTakes && IsScore(baseline.Score));
            Require(baseline.Takes == 0 == baseline.Score is null);
        }
    }

    /// <summary>Value equality, lists included (Mac <c>VoicePerVideoBook</c> is Equatable).</summary>
    public bool Equals(VoicePerVideoBook? other) => other is not null && Schema == other.Schema && Videos.SequenceEqual(other.Videos) &&
        Removals.SequenceEqual(other.Removals) && ShortNoted.SequenceEqual(other.ShortNoted) && Measurements.SequenceEqual(other.Measurements) &&
        Equals(AnchorBaseline, other.AnchorBaseline);
    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(Schema, Videos.Count, Removals.Count, ShortNoted.Count, Measurements.Count);

    /// <summary>The stored form: sorted keys, indented, absent optionals omitted, as the Mac writes it.</summary>
    public string Encoded()
    {
        static JsonObject Sorted(params (string Key, JsonNode? Value)[] pairs)
        {
            var node = new JsonObject();
            foreach (var (key, value) in pairs.Where(pair => pair.Value is not null).OrderBy(pair => pair.Key, StringComparer.Ordinal)) node[key] = value;
            return node;
        }
        static JsonNode? Optional(string? text) => text is null ? null : JsonValue.Create(text);
        static JsonNode? Number(double? value) => value is { } number ? JsonValue.Create(number) : null;
        var root = Sorted(
            ("schema", JsonValue.Create(Schema)),
            ("videos", new JsonArray(Videos.Select(video => (JsonNode)Sorted(
                ("contentKey", JsonValue.Create(video.ContentKey)), ("recordId", JsonValue.Create(video.RecordId)),
                ("anchorId", JsonValue.Create(video.AnchorId)), ("anchorReferenceSha256", JsonValue.Create(video.AnchorReferenceSha256)),
                ("title", JsonValue.Create(video.Title)), ("createdAt", JsonValue.Create(video.CreatedAt)),
                ("videoSeconds", JsonValue.Create(video.VideoSeconds)), ("removesBackgroundNoise", JsonValue.Create(video.RemovesBackgroundNoise)))).ToArray())),
            ("removals", new JsonArray(Removals.Select(removal => (JsonNode)Sorted(
                ("recordId", JsonValue.Create(removal.RecordId)), ("title", JsonValue.Create(removal.Title)), ("attempts", JsonValue.Create(removal.Attempts)),
                ("lastError", Optional(removal.LastError)), ("nextAttemptAt", Optional(removal.NextAttemptAt)))).ToArray())),
            ("shortNoted", new JsonArray(ShortNoted.Select(key => (JsonNode)JsonValue.Create(key)).ToArray())),
            ("measurements", new JsonArray(Measurements.Select(measurement => (JsonNode)Sorted(
                ("contentKey", JsonValue.Create(measurement.ContentKey)), ("title", JsonValue.Create(measurement.Title)),
                ("videoVoice", Number(measurement.VideoVoice)), ("anchor", Number(measurement.Anchor)),
                ("measuredAt", JsonValue.Create(measurement.MeasuredAt)))).ToArray())),
            ("anchorBaseline", AnchorBaseline is { } baseline ? Sorted(
                ("anchorId", JsonValue.Create(baseline.AnchorId)), ("model", JsonValue.Create(baseline.Model)), ("score", Number(baseline.Score)),
                ("takes", JsonValue.Create(baseline.Takes)), ("measuredAt", JsonValue.Create(baseline.MeasuredAt))) : null));
        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    /// <summary>A stored book as this build reads it. Every key the Mac's decoder requires is required here too; a malformed document throws
    /// <see cref="VoiceLabException"/> (InvalidInput). The result is not yet validated.</summary>
    public static VoicePerVideoBook Decode(string json)
    {
        JsonObject root;
        try { root = JsonNode.Parse(json) as JsonObject ?? throw Invalid(); }
        catch (JsonException) { throw Invalid(); }
        try
        {
            return new VoicePerVideoBook
            {
                Schema = Text(root, "schema"),
                Videos = Rows(root, "videos").Select(row => new Video(Text(row, "contentKey"), Text(row, "recordId"), Text(row, "anchorId"),
                    Text(row, "anchorReferenceSha256"), Text(row, "title"), Text(row, "createdAt"), Value<double>(row, "videoSeconds"),
                    Value<bool>(row, "removesBackgroundNoise"))).ToArray(),
                Removals = Rows(root, "removals").Select(row => new Removal(Text(row, "recordId"), Text(row, "title"), Value<int>(row, "attempts"),
                    OptionalText(row, "lastError"), OptionalText(row, "nextAttemptAt"))).ToArray(),
                ShortNoted = (root["shortNoted"] as JsonArray ?? throw Invalid()).Select(node =>
                    node is JsonValue value && value.TryGetValue<string>(out var key) ? key : throw Invalid()).ToArray(),
                Measurements = Rows(root, "measurements").Select(row => new Measurement(Text(row, "contentKey"), Text(row, "title"),
                    OptionalNumber(row, "videoVoice"), OptionalNumber(row, "anchor"), Text(row, "measuredAt"))).ToArray(),
                AnchorBaseline = root["anchorBaseline"] switch
                {
                    null => null,
                    JsonObject row => new AnchorBaselineEntry(Text(row, "anchorId"), Text(row, "model"), OptionalNumber(row, "score"),
                        Value<int>(row, "takes"), Text(row, "measuredAt")),
                    _ => throw Invalid()
                }
            };
        }
        catch (InvalidOperationException) { throw Invalid(); }
    }

    private static IEnumerable<JsonObject> Rows(JsonObject root, string key) =>
        (root[key] as JsonArray ?? throw Invalid()).Select(node => node as JsonObject ?? throw Invalid());
    private static T Value<T>(JsonObject row, string key) => row[key] is JsonValue value && value.TryGetValue<T>(out var result) ? result : throw Invalid();
    private static string Text(JsonObject row, string key) => Value<string>(row, key);
    private static string? OptionalText(JsonObject row, string key) => row[key] is null ? null : Text(row, key);
    private static double? OptionalNumber(JsonObject row, string key) => row[key] is null ? null : Value<double>(row, key);
    private static VoiceLabException Invalid() => new(VoiceLabErrorKind.InvalidInput);
}
