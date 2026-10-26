using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Services.Project;

internal static class ProjectValidation
{
    private const string Id = "[A-Za-z0-9][A-Za-z0-9._:-]{0,63}";
    private const string Hash = "[0-9a-f]{64}";
    private const string Slug = "[a-z0-9]+(?:-[a-z0-9]+)*";

    internal static void Validate(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        RejectDuplicateKeys(root);
        Require(root.ValueKind == JsonValueKind.Object);
        if (root.TryGetProperty("schemaVersion", out var version) && version.ValueKind == JsonValueKind.Number && version.TryGetInt32(out var number) && number > 3)
            throw new VoxClipException(VoxClipErrorCode.ProjectTooNew, "This project was saved by a newer VoxClip. Update VoxClip to open it.");
        Object(root, "format schemaVersion id createdAt modifiedAt savedBy media transcript edits captions export share ai voiceLab", "title extensions");
        String(root.GetProperty("format"), "voxclip-project");
        Number(root.GetProperty("schemaVersion"), 1, 3, true);
        String(root.GetProperty("id"), "[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}");
        Timestamp(root.GetProperty("createdAt")); Timestamp(root.GetProperty("modifiedAt"));
        if (root.TryGetProperty("title", out var title)) Text(title, 0, 200);
        if (root.TryGetProperty("extensions", out var extensions)) Dictionary(extensions, key => Pattern(key, "[a-z0-9]+(?:\\.[a-z0-9-]+)+"), _ => { });
        var saved = root.GetProperty("savedBy");
        Object(saved, "app version platform"); String(saved.GetProperty("app"), "VoxClip");
        String(saved.GetProperty("version"), "[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?"); Choice(saved.GetProperty("platform"), "macos", "windows");
        var media = root.GetProperty("media"); Object(media, "source");
        var source = media.GetProperty("source"); Object(source, "absolutePath relativePath sizeBytes durationSeconds contentKey video audio");
        Text(source.GetProperty("absolutePath"), 1, 4096);
        Nullable(source.GetProperty("relativePath"), value => { Text(value, 1, 4096); Require(!value.GetString()!.Contains('\\')); });
        Number(source.GetProperty("sizeBytes"), 0, long.MaxValue, true); Number(source.GetProperty("durationSeconds"), 0); String(source.GetProperty("contentKey"), Hash);
        Nullable(source.GetProperty("video"), video =>
        {
            Object(video, "width height frameRate rotationDegrees"); Number(video.GetProperty("width"), 1, int.MaxValue, true); Number(video.GetProperty("height"), 1, int.MaxValue, true);
            Number(video.GetProperty("frameRate"), double.Epsilon); Require(video.GetProperty("rotationDegrees").TryGetInt32(out var rotation) && rotation is 0 or 90 or 180 or 270);
        });
        Nullable(source.GetProperty("audio"), audio =>
        {
            Object(audio, "sampleRate channels"); Number(audio.GetProperty("sampleRate"), 1, int.MaxValue, true); Number(audio.GetProperty("channels"), 1, int.MaxValue, true);
        });
        Nullable(root.GetProperty("transcript"), Transcript);
        var edits = root.GetProperty("edits"); Object(edits, "pauseThresholdSeconds pauseKeepSeconds cutWordIds cutPauseIds corrections clips activeClipId");
        Number(edits.GetProperty("pauseThresholdSeconds"), double.Epsilon, 10); Number(edits.GetProperty("pauseKeepSeconds"), 0, 1);
        UniqueStrings(edits.GetProperty("cutWordIds"), Id); UniqueStrings(edits.GetProperty("cutPauseIds"), "pause-after-" + Id);
        Dictionary(edits.GetProperty("corrections"), key => Pattern(key, Id), value => WordText(value));
        Array(edits.GetProperty("clips"), clip =>
        {
            Object(clip, "id startWordId endWordId title origin aiResultId aiClipIndex selected");
            foreach (var key in new[] { "id", "startWordId", "endWordId" }) String(clip.GetProperty(key), Id);
            Nullable(clip.GetProperty("title"), value => Text(value, 0, 120)); Choice(clip.GetProperty("origin"), "manual", "ai");
            Nullable(clip.GetProperty("aiResultId"), value => String(value, Id)); Nullable(clip.GetProperty("aiClipIndex"), value => Number(value, 0, int.MaxValue, true)); Boolean(clip.GetProperty("selected"));
        });
        UniqueIds(edits.GetProperty("clips").EnumerateArray().Select(clip => clip.GetProperty("id").GetString()!)); Nullable(edits.GetProperty("activeClipId"), value => String(value, Id));
        var captions = root.GetProperty("captions"); Object(captions, "styleId overrides position positionByAspect"); String(captions.GetProperty("styleId"), Slug);
        Require(captions.GetProperty("overrides").ValueKind == JsonValueKind.Object); Nullable(captions.GetProperty("position"), Position);
        Dictionary(captions.GetProperty("positionByAspect"), key => Require(key is "16:9" or "9:16" or "1:1"), Position);
        var export = root.GetProperty("export"); Object(export, "aspect quality srt folder"); Choice(export.GetProperty("aspect"), "source", "16:9", "9:16", "1:1");
        Choice(export.GetProperty("quality"), "standard", "high"); Boolean(export.GetProperty("srt")); Nullable(export.GetProperty("folder"), value => Text(value, 1, 4096));
        var share = root.GetProperty("share"); Object(share, "captions"); Dictionary(share.GetProperty("captions"), key => Pattern(key, "(?:full|" + Id + ")"), value => Text(value, 0, 3000));
        var ai = root.GetProperty("ai"); Object(ai, "results"); Array(ai.GetProperty("results"), result =>
        {
            Object(result, "id createdAt provider model preset instructions language inputSha256 clips"); String(result.GetProperty("id"), Id); Timestamp(result.GetProperty("createdAt"));
            String(result.GetProperty("provider"), Slug); Text(result.GetProperty("model"), 1, 128); Choice(result.GetProperty("preset"), "best", "hooks", "topics", "quotes", "custom");
            Nullable(result.GetProperty("instructions"), value => Text(value, 0, 500)); Nullable(result.GetProperty("language"), value => Text(value, 0, 35)); String(result.GetProperty("inputSha256"), Hash);
            Array(result.GetProperty("clips"), clip =>
            {
                Object(clip, "title reason score startWordId endWordId"); Text(clip.GetProperty("title"), 1, 120); Text(clip.GetProperty("reason"), 0, 300);
                Number(clip.GetProperty("score"), 1, 10, true); String(clip.GetProperty("startWordId"), Id); String(clip.GetProperty("endWordId"), Id);
            });
        });
        UniqueIds(ai.GetProperty("results").EnumerateArray().Select(result => result.GetProperty("id").GetString()!));
        var voice = root.GetProperty("voiceLab");
        var projectVersion = root.GetProperty("schemaVersion").GetInt32();
        if (projectVersion == 1)
        {
            Object(voice, "segments"); Require(voice.GetProperty("segments").ValueKind == JsonValueKind.Array && voice.GetProperty("segments").GetArrayLength() == 0);
        }
        else
        {
            Object(voice, projectVersion == 3 ? "assets segments cleanAudio voices videoAssets" : "assets segments");
            Array(voice.GetProperty("assets"), asset => Object(asset, "id kind file sha256 durationSeconds sampleRate createdAt"));
            Array(voice.GetProperty("segments"), segment =>
            {
                Object(segment, "id kind enabled replace outDuration audio text words provenance qa candidates selectedCandidateIndex" + (projectVersion == 3 ? " scope" : ""), projectVersion == 3 ? "groupId" : "");
                if (projectVersion == 3) { Choice(segment.GetProperty("scope"), "passage", "fullTake"); Choice(segment.GetProperty("kind"), "tts", "voiceChanger"); }
                Object(segment.GetProperty("replace"), "start end firstWordId lastWordId");
                Object(segment.GetProperty("audio"), "assetId trimStart trimEnd stretch gainDb");
                Nullable(segment.GetProperty("text"), text => Object(text, "original new"));
                Nullable(segment.GetProperty("words"), words => Array(words, word => Object(word, "text start end synthetic")));
                Object(segment.GetProperty("provenance"), "provider endpoint model voiceId consentRecordId requestId seed createdAt" + (projectVersion == 3 ? " region" : ""));
                Object(segment.GetProperty("qa"), "transcriptMatch lufsJumpLu peakDbfs speakerScore");
                Array(segment.GetProperty("candidates"), candidate =>
                {
                    Object(candidate, "assetId score rejected" + (projectVersion == 3 && candidate.GetProperty("rejected").ValueKind == JsonValueKind.Null ? " recipe" : ""), projectVersion == 3 ? "recipe" : "");
                    if (candidate.TryGetProperty("recipe", out var recipe)) RenderRecipe(recipe);
                });
            });
            if (projectVersion == 3)
            {
                Object(voice.GetProperty("cleanAudio"), "mode assetId mix");
                Choice(voice.GetProperty("cleanAudio").GetProperty("mode"), "off", "on");
                Array(voice.GetProperty("voices"), item => { Object(item, "id provider voiceId consentRecordId displayName status"); Choice(item.GetProperty("status"), "active", "deleted"); });
                Array(voice.GetProperty("videoAssets"), item => Object(item, "id file sha256 durationSeconds frameRate width height"));
            }
        }
    }

    private static void RenderRecipe(JsonElement recipe)
    {
        Object(recipe, "audio words outDuration seed chunks roomTone seams video qa provenance cost voiceSource voiceRefId consentVerifiedAt");
        Object(recipe.GetProperty("audio"), "assetId trimStart trimEnd stretch gainDb");
        Nullable(recipe.GetProperty("words"), words => Array(words, word => Object(word, "text start end synthetic")));
        Array(recipe.GetProperty("chunks"), item => Object(item, "sourceStartSample sourceEndSample requestId seed assetId assetSha256 assembledStartFrame assembledEndFrame"));
        Nullable(recipe.GetProperty("roomTone"), item => Object(item, "sourceStartSample sourceEndSample gainDb"));
        var seams = recipe.GetProperty("seams"); Object(seams, "in out");
        Object(seams.GetProperty("in"), "kind fadeSamples sourceHandleSamples assetHandleFrames");
        Object(seams.GetProperty("out"), "kind fadeSamples sourceHandleSamples assetHandleFrames");
        Choice(seams.GetProperty("in").GetProperty("kind"), "none", "gap", "hard", "synthToSynth");
        Choice(seams.GetProperty("out").GetProperty("kind"), "none", "gap", "hard", "synthToSynth");
        Object(recipe.GetProperty("video"), "mode sourceStartSample sourceEndSample outputSamples", "retimeFactor zoom faceX faceY assetId provider model requestId windowStartSample windowEndSample syncMode");
        Choice(recipe.GetProperty("video").GetProperty("mode"), "source", "retimed", "zoomCover", "lipsync");
        Choice(recipe.GetProperty("voiceSource"), "own", "stock");
        Object(recipe.GetProperty("qa"), "transcriptTokens transcriptExact transcriptMatch lufsJumpLu peakDbfs speakerScore speakerThreshold speakerModel speakerPassed");
        Object(recipe.GetProperty("provenance"), "provider endpoint model voiceId consentRecordId requestId seed createdAt region");
        Object(recipe.GetProperty("cost"), "quoteId usd");
    }

    private static void Transcript(JsonElement transcript)
    {
        Object(transcript, "schemaVersion words language languageProbability durationSeconds engine verbatim refined pipelineVersion rawKey createdAt");
        Number(transcript.GetProperty("schemaVersion"), 1, 1, true);
        Nullable(transcript.GetProperty("language"), value => String(value, "[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*")); Nullable(transcript.GetProperty("languageProbability"), value => Number(value, 0, 1));
        Number(transcript.GetProperty("durationSeconds"), 0); Boolean(transcript.GetProperty("verbatim")); Boolean(transcript.GetProperty("refined")); Number(transcript.GetProperty("pipelineVersion"), 1, int.MaxValue, true);
        String(transcript.GetProperty("rawKey"), Hash); Timestamp(transcript.GetProperty("createdAt"));
        var engine = transcript.GetProperty("engine"); Object(engine, "id modelId modelSha256 engineVersion locale"); Choice(engine.GetProperty("id"), "elevenlabs", "whispercpp", "apple-speech");
        Nullable(engine.GetProperty("modelId"), value => Text(value, 0, 128)); Nullable(engine.GetProperty("modelSha256"), value => String(value, Hash));
        Text(engine.GetProperty("engineVersion"), 1, 128); Nullable(engine.GetProperty("locale"), value => Text(value, 0, 35));
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var previousStart = double.NegativeInfinity;
        Array(transcript.GetProperty("words"), word =>
        {
            Object(word, "id text kind start end rawStart rawEnd conf speaker timing"); String(word.GetProperty("id"), Id); WordText(word.GetProperty("text")); Choice(word.GetProperty("kind"), "word", "event", "unlabeledSpeech");
            Number(word.GetProperty("start"), 0); Number(word.GetProperty("end"), 0);
            var start = word.GetProperty("start").GetDouble();
            Require(start >= previousStart && word.GetProperty("end").GetDouble() > start && ids.Add(word.GetProperty("id").GetString()!));
            previousStart = start;
            Nullable(word.GetProperty("rawStart"), value => Number(value, 0)); Nullable(word.GetProperty("rawEnd"), value => Number(value, 0)); Nullable(word.GetProperty("conf"), value => Number(value, 0, 1));
            Nullable(word.GetProperty("speaker"), value => Text(value, 0, 64)); Choice(word.GetProperty("timing"), "native", "dtw", "tokenGrouped", "runGrouped", "detected");
        });
    }

    private static void WordText(JsonElement value)
    {
        Text(value, 1, 200);
        var text = value.GetString()!;
        Require(text == EditingAlgorithms.JsTrim(text) && text.IsNormalized(NormalizationForm.FormC));
    }

    private static void Position(JsonElement position)
    {
        Object(position, "x y"); Number(position.GetProperty("x"), 0, 1); Number(position.GetProperty("y"), 0, 1);
    }

    private static void Timestamp(JsonElement value)
    {
        String(value, "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]{1,9})?Z");
        Require(DateTimeOffset.TryParse(value.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out _));
    }

    private static void Object(JsonElement value, string required, string optional = "")
    {
        Require(value.ValueKind == JsonValueKind.Object);
        var keys = required.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        foreach (var key in keys) Require(value.TryGetProperty(key, out _));
        var allowed = keys.Concat(optional.Split(' ', StringSplitOptions.RemoveEmptyEntries)).ToHashSet(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject()) Require(allowed.Contains(property.Name));
    }

    private static void Array(JsonElement value, Action<JsonElement> validate)
    {
        Require(value.ValueKind == JsonValueKind.Array);
        foreach (var item in value.EnumerateArray()) validate(item);
    }

    private static void Dictionary(JsonElement value, Action<string> key, Action<JsonElement> item)
    {
        Require(value.ValueKind == JsonValueKind.Object);
        foreach (var property in value.EnumerateObject()) { key(property.Name); item(property.Value); }
    }

    private static void UniqueStrings(JsonElement value, string pattern)
    {
        var found = new HashSet<string>(StringComparer.Ordinal);
        Array(value, item => { String(item, pattern); Require(found.Add(item.GetString()!)); });
    }

    private static void UniqueIds(IEnumerable<string> ids)
    {
        var found = new HashSet<string>(StringComparer.Ordinal);
        foreach (var id in ids) Require(found.Add(id));
    }

    private static void Nullable(JsonElement value, Action<JsonElement> validate) { if (value.ValueKind != JsonValueKind.Null) validate(value); }
    private static void Boolean(JsonElement value) => Require(value.ValueKind is JsonValueKind.True or JsonValueKind.False);
    private static void Text(JsonElement value, int minimum, int maximum)
    {
        Require(value.ValueKind == JsonValueKind.String);
        var length = value.GetString()!.EnumerateRunes().Count();
        Require(length >= minimum && length <= maximum);
    }
    private static void String(JsonElement value, string pattern) { Require(value.ValueKind == JsonValueKind.String); Pattern(value.GetString()!, pattern); }
    private static void Pattern(string value, string pattern) => Require(Regex.IsMatch(value, "\\A(?:" + pattern + ")\\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1)));
    private static void Choice(JsonElement value, params string[] choices) => Require(value.ValueKind == JsonValueKind.String && choices.Contains(value.GetString(), StringComparer.Ordinal));
    private static void Number(JsonElement value, double minimum, double maximum = double.MaxValue, bool integer = false)
    {
        Require(value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out _));
        var number = value.GetDouble();
        Require(double.IsFinite(number) && number >= minimum && number <= maximum && (!integer || Math.Truncate(number) == number));
    }
    private static void Require(bool condition) { if (!condition) throw new JsonException("Project schema validation failed."); }
    private static void RejectDuplicateKeys(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var keys = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in element.EnumerateObject()) { Require(keys.Add(property.Name)); RejectDuplicateKeys(property.Value); }
        }
        else if (element.ValueKind == JsonValueKind.Array) foreach (var item in element.EnumerateArray()) RejectDuplicateKeys(item);
    }
}
