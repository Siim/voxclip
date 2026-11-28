using System.Text.Json;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Services.Project;

internal static class ProjectValidation
{
    private const string Id = "[A-Za-z0-9][A-Za-z0-9._:-]{0,63}";
    private const string Hash = "[0-9a-f]{64}";
    private const string Slug = "[a-z0-9]+(?:-[a-z0-9]+)*";

    internal static void Validate(string json, bool normalizeWordText = false)
    {
        using var document = JsonDocument.Parse(json);
        Validate(document.RootElement, normalizeWordText);
    }

    internal static void Validate(JsonElement root, bool normalizeWordText)
    {
        RejectDuplicateKeys(root);
        if (root.ValueKind != JsonValueKind.Object) throw Problem("/", "expected object");
        if (root.TryGetProperty("schemaVersion", out var version) && version.ValueKind == JsonValueKind.Number && version.TryGetInt32(out var number) && number > ProjectSerialization.CurrentVersion)
            throw new VoxClipException(VoxClipErrorCode.ProjectTooNew, "This project was saved by a newer VoxClip. Update VoxClip to open it.");
        var schemaVersion = version.ValueKind == JsonValueKind.Number && version.TryGetInt32(out var supported) ? supported : 0;
        var supportsContext = schemaVersion >= 4;
        var supportsStories = schemaVersion >= 5;
        var supportsTimelineEdits = schemaVersion >= TimelineEditFields.Version;
        var supportsFrame = schemaVersion >= ProjectSerialization.FrameVersion;
        var supportsSpokenSources = schemaVersion == ProjectSerialization.SpokenSourcesVersion ||
            (supportsFrame && root.TryGetProperty("media", out var mediaFields) && mediaFields.ValueKind == JsonValueKind.Object && mediaFields.TryGetProperty("spokenSources", out _));
        Object(root, "format schemaVersion id createdAt modifiedAt savedBy media transcript edits captions export share ai voiceLab", "title extensions clipStyle" + (supportsContext ? " contextDemo motionCues music clipEffects clipControls captionTranslations" : "") + (supportsFrame ? " agentThread" : ""), path: "/");
        if (root.TryGetProperty("agentThread", out var thread)) ExpectObject(thread, "agentThread");
        if (root.GetProperty("format").ValueKind != JsonValueKind.String || root.GetProperty("format").GetString() != "voxclip-project")
            throw Problem("format", "invalid value");
        if (schemaVersion < 1) throw Problem("schemaVersion", "expected a supported integer schema version");
        String(root.GetProperty("id"), "[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}");
        Timestamp(root.GetProperty("createdAt")); Timestamp(root.GetProperty("modifiedAt"));
        if (root.TryGetProperty("title", out var title)) Text(title, 0, 200);
        if (root.TryGetProperty("extensions", out var extensions)) Dictionary(extensions, "extensions", (_, _, _) => { }, "[a-z0-9]+(?:\\.[a-z0-9-]+)+");
        var saved = root.GetProperty("savedBy");
        Object(saved, "app version platform", path: "savedBy"); String(saved.GetProperty("app"), "VoxClip");
        String(saved.GetProperty("version"), "[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?"); Choice(saved.GetProperty("platform"), "macos", "windows");
        var media = root.GetProperty("media"); Object(media, supportsSpokenSources ? "source spokenSources" : "source", supportsContext ? "additionalSources footage" : "", path: "media");
        if (supportsSpokenSources)
        {
            var spoken = media.GetProperty("spokenSources");
            Array(spoken, "media/spokenSources", (item, path) =>
            {
                Object(item, "sourceKey offsetSeconds wordIdPrefix transcript", "gainDb label", path: path);
                String(item.GetProperty("sourceKey"), Hash);
                Number(item.GetProperty("offsetSeconds"), 1, int.MaxValue, true);
                if (item.TryGetProperty("label", out var label)) Text(label, 0, 24);
                if (item.TryGetProperty("gainDb", out var gain)) Number(gain, -12, 12);
                Transcript(item.GetProperty("transcript"), normalizeWordText, path + "/transcript");
            });
            if (spoken.GetArrayLength() is < 1 or > 5) throw Problem("media/spokenSources", "expected one to five companion spoken recordings");
        }
        var source = media.GetProperty("source");
        ValidateSource(source, "media/source");
        var sourceKeys = new HashSet<string>(StringComparer.Ordinal) { FootageKey(source) };
        var companionDurations = new Dictionary<string, double>(StringComparer.Ordinal);
        var clockEnd = source.GetProperty("durationSeconds").GetDouble();
        if (media.TryGetProperty("additionalSources", out var additionalSources))
        {
            Array(additionalSources, "media/additionalSources", (reference, path) =>
            {
                ValidateSource(reference, path);
                var key = FootageKey(reference);
                Require(sourceKeys.Add(key));
                if (reference.GetProperty("video").ValueKind == JsonValueKind.Object)
                    companionDurations.Add(key, reference.GetProperty("durationSeconds").GetDouble());
            });
            Require(additionalSources.GetArrayLength() > 0);
            if (supportsSpokenSources)
            {
                var last = media.GetProperty("spokenSources").EnumerateArray().Last();
                var lastKey = last.GetProperty("sourceKey").GetString();
                foreach (var reference in additionalSources.EnumerateArray())
                    if (reference.GetProperty("contentKey").GetString() == lastKey)
                        clockEnd = last.GetProperty("offsetSeconds").GetDouble() + reference.GetProperty("durationSeconds").GetDouble();
            }
        }
        var placements = new List<ProjectFootage>();
        var placementIds = new HashSet<string>(StringComparer.Ordinal);
        if (media.TryGetProperty("footage", out var footage))
        {
            Array(footage, "media/footage", (placement, path) =>
            {
                Object(placement, "id clipID kind start end footage", supportsTimelineEdits ? "fadeInSeconds fadeOutSeconds" : "", path: path);
                String(placement.GetProperty("id"), Id); String(placement.GetProperty("clipID"), Id);
                Choice(placement.GetProperty("kind"), "bRoll", "screenshot", "videoStack");
                Number(placement.GetProperty("start"), 0); Number(placement.GetProperty("end"), 0);
                var selected = placement.GetProperty("footage"); Object(selected, "sourceKey start", path: $"{path}/footage");
                String(selected.GetProperty("sourceKey"), Hash); Number(selected.GetProperty("start"), 0);
                double? Fade(string key)
                {
                    if (!placement.TryGetProperty(key, out var fade)) return null;
                    Number(fade, 0, 2);
                    return fade.GetDouble();
                }
                var entry = new ProjectFootage(placement.GetProperty("id").GetString()!, placement.GetProperty("clipID").GetString()!,
                    placement.GetProperty("kind").GetString()!, placement.GetProperty("start").GetDouble(), placement.GetProperty("end").GetDouble(),
                    new FootageSelection(selected.GetProperty("sourceKey").GetString()!, selected.GetProperty("start").GetDouble()),
                    Fade("fadeInSeconds"), Fade("fadeOutSeconds"));
                Require(placementIds.Add(entry.Id) && entry.End <= clockEnd &&
                    companionDurations.TryGetValue(entry.Footage.SourceKey, out var duration) &&
                    (supportsTimelineEdits ? entry.HasPlayableSource(duration) : entry.Fits(duration)) &&
                    !placements.Any(other => other.ClipId == entry.ClipId && other.Start < entry.End && entry.Start < other.End));
                placements.Add(entry);
            });
            Require(placements.Count > 0);
        }
        static string FootageKey(JsonElement reference) => (reference.TryGetProperty("recordingHash", out var hash) ? hash : reference.GetProperty("contentKey")).GetString()!;
        void ValidateSource(JsonElement reference, string path)
        {
            Object(reference, "absolutePath relativePath sizeBytes durationSeconds contentKey video audio", supportsContext ? "recordingHash" : "", path: path);
            if (reference.TryGetProperty("recordingHash", out var hash)) String(hash, Hash);
            Text(reference.GetProperty("absolutePath"), 1, 4096);
            Nullable(reference.GetProperty("relativePath"), value => { Text(value, 1, 4096); Require(!value.GetString()!.Contains('\\')); });
            Number(reference.GetProperty("sizeBytes"), 0, long.MaxValue, true); Number(reference.GetProperty("durationSeconds"), 0); String(reference.GetProperty("contentKey"), Hash);
            Nullable(reference.GetProperty("video"), video =>
            {
                Object(video, "width height frameRate rotationDegrees", path: path + "/video"); Number(video.GetProperty("width"), 1, int.MaxValue, true); Number(video.GetProperty("height"), 1, int.MaxValue, true);
                Number(video.GetProperty("frameRate"), double.Epsilon); Require(video.GetProperty("rotationDegrees").TryGetInt32(out var rotation) && rotation is 0 or 90 or 180 or 270);
            });
            Nullable(reference.GetProperty("audio"), audio =>
            {
                Object(audio, "sampleRate channels", path: path + "/audio"); Number(audio.GetProperty("sampleRate"), 1, int.MaxValue, true); Number(audio.GetProperty("channels"), 1, int.MaxValue, true);
            });
        }
        Nullable(root.GetProperty("transcript"), value => Transcript(value, normalizeWordText, "transcript"));
        var edits = root.GetProperty("edits"); Object(edits, "pauseThresholdSeconds pauseKeepSeconds cutWordIds cutPauseIds corrections clips activeClipId", supportsFrame ? "cutEdges" : "", path: "edits");
        if (edits.TryGetProperty("cutEdges", out var cutEdges)) Dictionary(cutEdges, "edits/cutEdges", (_, value, _) => Number(value, 0), Id);
        Number(edits.GetProperty("pauseThresholdSeconds"), double.Epsilon, 10); Number(edits.GetProperty("pauseKeepSeconds"), 0, 1);
        UniqueStrings(edits.GetProperty("cutWordIds"), Id, "edits/cutWordIds"); UniqueStrings(edits.GetProperty("cutPauseIds"), "pause-after-" + Id, "edits/cutPauseIds");
        Dictionary(edits.GetProperty("corrections"), "edits/corrections", (_, value, _) => WordText(value, normalizeWordText), Id);
        Array(edits.GetProperty("clips"), "edits/clips", (clip, path) =>
        {
            // leadInSeconds: schema v4 only, above 0 and at most the 0.6 s opening scan (ADR-R48 part 2).
            if (!supportsStories && clip.ValueKind == JsonValueKind.Object && (clip.TryGetProperty("kind", out _) || clip.TryGetProperty("parts", out _)))
                throw Problem(path, "story clip needs schemaVersion 5");
            var optional = supportsStories ? "leadInSeconds parts kind" : supportsContext ? "leadInSeconds" : "";
            if (supportsSpokenSources) optional += " displacedVersions";
            Object(clip, "id startWordId endWordId title origin aiResultId aiClipIndex selected", optional, path: path);
            if (clip.TryGetProperty("displacedVersions", out var displaced)) Array(displaced, path + "/displacedVersions", (range, rangePath) =>
            {
                Object(range, "startWordId endWordId", path: rangePath);
                String(range.GetProperty("startWordId"), Id);
                String(range.GetProperty("endWordId"), Id);
            });
            if (clip.TryGetProperty("kind", out var kind) &&
                (!clip.TryGetProperty("parts", out _) || kind.ValueKind != JsonValueKind.String || kind.GetString() is not ("story" or "showreel")))
                throw Problem(path + "/kind", "invalid clip kind");
            if (clip.TryGetProperty("parts", out var parts)) Array(parts, path + "/parts", (part, partPath) =>
            {
                Object(part, "id startWordId endWordId", supportsSpokenSources ? "reframe takeReason" : "reframe", path: partPath);
                if (part.TryGetProperty("takeReason", out var reason)) Text(reason, 0, StoryClips.MaxTakeReasonScalars);
                if (part.TryGetProperty("reframe", out var reframe))
                {
                    Object(reframe, "mode zoom centerX centerY", path: partPath + "/reframe");
                    Require(reframe.GetProperty("mode").ValueKind == JsonValueKind.String && reframe.GetProperty("mode").GetString() == "face");
                    Number(reframe.GetProperty("zoom"), 1, 1);
                    Number(reframe.GetProperty("centerX"), 0, 1); Number(reframe.GetProperty("centerY"), 0, 1);
                }
            });
            if (clip.TryGetProperty("leadInSeconds", out var leadIn)) { Number(leadIn, double.Epsilon, 0.6 + 1e-9); }
            foreach (var key in new[] { "id", "startWordId", "endWordId" }) String(clip.GetProperty(key), Id);
            Nullable(clip.GetProperty("title"), value => Text(value, 0, 120)); Choice(clip.GetProperty("origin"), "manual", "ai");
            Nullable(clip.GetProperty("aiResultId"), value => String(value, Id)); Nullable(clip.GetProperty("aiClipIndex"), value => Number(value, 0, int.MaxValue, true)); Boolean(clip.GetProperty("selected"));
        });
        UniqueIds(edits.GetProperty("clips").EnumerateArray().Select(clip => clip.GetProperty("id").GetString()!)); Nullable(edits.GetProperty("activeClipId"), value => String(value, Id));
        var captions = root.GetProperty("captions"); Object(captions, "styleId overrides position positionByAspect", path: "captions"); String(captions.GetProperty("styleId"), Slug);
        ExpectObject(captions.GetProperty("overrides"), "captions/overrides");
        Nullable(captions.GetProperty("position"), position => Position(position, "captions/position"));
        Dictionary(captions.GetProperty("positionByAspect"), "captions/positionByAspect", (aspect, position, path) =>
        {
            if (aspect is not ("16:9" or "9:16" or "1:1")) throw Problem("captions/positionByAspect", "unknown field");
            Position(position, path);
        });
        if (root.TryGetProperty("clipStyle", out var clipStyle))
        {
            // Project schema $defs/clipStyle (design §6.6).
            Object(clipStyle, "preset captions music maxLengthSec shapes rewording captionPicks", "tone", path: "clipStyle");
            if (clipStyle.TryGetProperty("tone", out var tone)) { String(tone, Slug); Require(tone.GetString() != "auto" && System.Text.Encoding.UTF8.GetByteCount(tone.GetString()!) <= 64); }
            Choice(clipStyle.GetProperty("preset"), "auto", "punchy", "calm", "demo", "mine"); String(clipStyle.GetProperty("captions"), Slug);
            Choice(clipStyle.GetProperty("music"), "auto", "off"); Number(clipStyle.GetProperty("maxLengthSec"), 5, 600, true);
            var shapes = clipStyle.GetProperty("shapes");
            Array(shapes, "clipStyle/shapes", (shape, _) => Choice(shape, "16:9", "9:16", "1:1"));
            Require(shapes.GetArrayLength() > 0 && shapes.EnumerateArray().Select(shape => shape.GetString()).Distinct().Count() == shapes.GetArrayLength());
            Choice(clipStyle.GetProperty("rewording"), "off", "fix-only", "tighten");
            Dictionary(clipStyle.GetProperty("captionPicks"), "clipStyle/captionPicks", (_, pick, path) =>
            {
                // Optional: the clip's overrides and "by": "user" for the creator's own choice (design §6.6).
                Object(pick, "styleId reason", "overrides by", path: path); String(pick.GetProperty("styleId"), Slug); Require(pick.GetProperty("styleId").GetString() != "auto");
                if (pick.TryGetProperty("overrides", out var overrides)) ExpectObject(overrides, $"{path}/overrides");
                if (pick.TryGetProperty("by", out var by)) Require(by.ValueKind == JsonValueKind.String && by.GetString() == "user");
                Require(pick.GetProperty("reason").ValueKind == JsonValueKind.String && pick.GetProperty("reason").GetString()!.EnumerateRunes().Count() <= 120);
            }, Id);
        }
        var export = root.GetProperty("export"); Object(export, "aspect quality srt folder", path: "export");
        var aspect = export.GetProperty("aspect");
        if (aspect.ValueKind != JsonValueKind.String || aspect.GetString() is not ("source" or "16:9" or "9:16" or "1:1"))
            throw Problem("export/aspect", "invalid value");
        var quality = export.GetProperty("quality");
        if (quality.ValueKind != JsonValueKind.String || quality.GetString() is not ("standard" or "high"))
            throw Problem("export/quality", "invalid value");
        Boolean(export.GetProperty("srt")); Nullable(export.GetProperty("folder"), value => Text(value, 1, 4096));
        var share = root.GetProperty("share"); Object(share, "captions", path: "share");
        Dictionary(share.GetProperty("captions"), "share/captions", (_, value, _) => Text(value, 0, 3000), "(?:full|" + Id + ")");
        var ai = root.GetProperty("ai"); Object(ai, "results", path: "ai"); Array(ai.GetProperty("results"), "ai/results", (result, path) =>
        {
            Object(result, "id createdAt provider model preset instructions language inputSha256 clips", path: path); String(result.GetProperty("id"), Id); Timestamp(result.GetProperty("createdAt"));
            String(result.GetProperty("provider"), Slug); Text(result.GetProperty("model"), 1, 128); Choice(result.GetProperty("preset"), "best", "hooks", "topics", "quotes", "custom");
            Nullable(result.GetProperty("instructions"), value => Text(value, 0, 500)); Nullable(result.GetProperty("language"), value => Text(value, 0, 35)); String(result.GetProperty("inputSha256"), Hash);
            Array(result.GetProperty("clips"), $"{path}/clips", (clip, clipPath) =>
            {
                Object(clip, "title reason score startWordId endWordId", supportsStories ? "parts notInTake" : "", path: clipPath);
                if (clip.TryGetProperty("parts", out var parts))
                    Array(parts, $"{clipPath}/parts", (part, partPath) => Object(part, "startWordId endWordId", path: partPath));
                if (clip.TryGetProperty("notInTake", out var note)) Text(note, 0, 200);
                Text(clip.GetProperty("title"), 1, 120); Text(clip.GetProperty("reason"), 0, 300);
                Number(clip.GetProperty("score"), 1, 10, true); String(clip.GetProperty("startWordId"), Id); String(clip.GetProperty("endWordId"), Id);
            });
        });
        UniqueIds(ai.GetProperty("results").EnumerateArray().Select(result => result.GetProperty("id").GetString()!));
        var voice = root.GetProperty("voiceLab");
        var projectVersion = root.GetProperty("schemaVersion").GetInt32();
        if (voice.ValueKind == JsonValueKind.Object && voice.TryGetProperty("speakingRateSamples", out var rates))
            Dictionary(rates, "voiceLab/speakingRateSamples", (key, samples, path) =>
            {
                if (key.Length == 0) throw Problem("voiceLab/speakingRateSamples", "invalid value");
                if (samples.ValueKind == JsonValueKind.Array && samples.GetArrayLength() > VoiceLabWordingFit.ProjectSampleLimit)
                    throw Problem(path, "invalid value");
                Array(samples, path, (sample, samplePath) =>
                {
                    Object(sample, "id ratio", path: samplePath); Text(sample.GetProperty("id"), 1, int.MaxValue);
                    Require(sample.GetProperty("ratio").ValueKind == JsonValueKind.Number && sample.GetProperty("ratio").GetDouble() is var ratio && double.IsFinite(ratio) && ratio > 0);
                });
            });
        if (projectVersion == 1)
        {
            Object(voice, "segments", "speakingRateSamples", path: "voiceLab");
            Array(voice.GetProperty("segments"), "voiceLab/segments", (_, _) => throw Problem("voiceLab/segments", "Version 1 Voice Lab must be empty"));
        }
        else
        {
            Object(voice, projectVersion >= 3 ? "segments assets cleanAudio voices videoAssets" : "segments assets",
                projectVersion >= 3 ? "speakingRateSamples wholeClipRevoices" : "speakingRateSamples", path: "voiceLab");
            // A whole-clip revoice (ADR-R46): every key present, usd and match may be null; the rules are WholeClipRevoice.Validate's.
            if (voice.TryGetProperty("wholeClipRevoices", out var revoices))
                Array(revoices, "voiceLab/wholeClipRevoices", (revoice, path) =>
                {
                    Object(revoice, "id clipId segmentIds script consentRecordId videoRetime lipsyncModel usd match createdAt", path: path);
                    String(revoice.GetProperty("id"), Id); String(revoice.GetProperty("clipId"), Id);
                    Array(revoice.GetProperty("segmentIds"), $"{path}/segmentIds", (segment, _) => Text(segment, 1, int.MaxValue));
                    Text(revoice.GetProperty("script"), 1, int.MaxValue); Text(revoice.GetProperty("consentRecordId"), 1, int.MaxValue);
                    Number(revoice.GetProperty("videoRetime"), double.MinValue);
                    Choice(revoice.GetProperty("lipsyncModel"), "fal-ai/sync-lipsync/v2:lipsync-2", "fal-ai/sync-lipsync/v3");
                    Nullable(revoice.GetProperty("usd"), usd => Number(usd, 0, double.MaxValue));
                    Nullable(revoice.GetProperty("match"), match =>
                    {
                        Object(match, "take anchorBaseline realSpeech", path: $"{path}/match"); Number(match.GetProperty("take"), -1, 1);
                        Nullable(match.GetProperty("anchorBaseline"), score => Number(score, -1, 1));
                        Nullable(match.GetProperty("realSpeech"), score => Number(score, -1, 1));
                    });
                    Timestamp(revoice.GetProperty("createdAt"));
                });
            Array(voice.GetProperty("assets"), "voiceLab/assets", (asset, path) => Object(asset, "id kind file sha256 durationSeconds sampleRate createdAt", path: path));
            Array(voice.GetProperty("segments"), "voiceLab/segments", (segment, path) =>
            {
                Object(segment, "id kind enabled replace outDuration audio text words provenance qa candidates selectedCandidateIndex" + (projectVersion >= 3 ? " scope" : ""), projectVersion >= 3 ? "groupId" : "", path: path);
                if (projectVersion >= 3) { Choice(segment.GetProperty("scope"), "passage", "fullTake"); Choice(segment.GetProperty("kind"), "tts", "voiceChanger", "recorded"); }
                Object(segment.GetProperty("replace"), "start end firstWordId lastWordId", path: $"{path}/replace");
                Object(segment.GetProperty("audio"), "assetId trimStart trimEnd stretch gainDb", "tiltDbPerOctave", path: $"{path}/audio");
                Nullable(segment.GetProperty("text"), text =>
                {
                    Object(text, "original new", "audioTags", path: $"{path}/text");
                    if (text.TryGetProperty("audioTags", out var annotations))
                        Array(annotations, $"{path}/text/audioTags", (annotation, annotationPath) => Object(annotation, "beforeToken tag", path: annotationPath));
                });
                Nullable(segment.GetProperty("words"), words => Array(words, $"{path}/words", (word, wordPath) => Object(word, "text start end synthetic", path: wordPath)));
                Object(segment.GetProperty("provenance"), "provider endpoint model voiceId consentRecordId requestId seed createdAt" + (projectVersion >= 3 ? " region" : ""), "pace", path: $"{path}/provenance");
                if (segment.GetProperty("provenance").TryGetProperty("pace", out var pace)) Number(pace, VoiceLabPace.Minimum, VoiceLabPace.Maximum);
                Object(segment.GetProperty("qa"), "transcriptMatch lufsJumpLu peakDbfs speakerScore", path: $"{path}/qa");
                Array(segment.GetProperty("candidates"), $"{path}/candidates", (candidate, candidatePath) =>
                {
                    Object(candidate, "assetId score rejected", projectVersion >= 3 ? "recipe" : "", path: candidatePath);
                    var recipePath = $"{candidatePath}/recipe";
                    if (candidate.TryGetProperty("recipe", out var recipe)) RenderRecipe(recipe, recipePath);
                    else if (projectVersion >= 3 && candidate.GetProperty("rejected").ValueKind == JsonValueKind.Null)
                        throw Problem(recipePath, "missing required field");
                });
            });
            if (projectVersion >= 3)
            {
                Object(voice.GetProperty("cleanAudio"), "mode assetId mix", path: "voiceLab/cleanAudio");
                Choice(voice.GetProperty("cleanAudio").GetProperty("mode"), "off", "on");
                Array(voice.GetProperty("voices"), "voiceLab/voices", (item, path) => { Object(item, "id provider voiceId consentRecordId displayName status", path: path); Choice(item.GetProperty("status"), "active", "deleted"); });
                Array(voice.GetProperty("videoAssets"), "voiceLab/videoAssets", (item, path) => Object(item, "id file sha256 durationSeconds frameRate width height", path: path));
            }
        }
        if (root.TryGetProperty("contextDemo", out var demo))
        {
            Object(demo, "format version projectId planId revision sourceContentKey narration assets placements", path: "contextDemo");
            Array(demo.GetProperty("assets"), "contextDemo/assets", (asset, path) =>
            {
                ExpectObject(asset, path);
                if (!asset.TryGetProperty("target", out var target)) throw Problem($"{path}/target", "missing required field");
                Object(target, "kind displayName locator", path: $"{path}/target");
                Choice(target.GetProperty("kind"), "desktopApp", "codeProject", "webPage");
            });
            ContextDemoDocument context;
            // The demo decodes as its own document, so its error paths start inside `contextDemo`.
            try { context = ContextDemoCodec.Decode(System.Text.Encoding.UTF8.GetBytes(demo.GetRawText())); }
            catch (JsonException exception)
            {
                var inner = FieldPath(exception.Path);
                throw Problem(inner.Length == 0 ? "contextDemo" : $"contextDemo/{inner}", "invalid value");
            }
            Require(context.ProjectId == root.GetProperty("id").GetString() && context.SourceContentKey == source.GetProperty("contentKey").GetString());
        }
        if (root.TryGetProperty("motionCues", out var cues)) MotionCue.ValidateWire(cues);
        if (root.TryGetProperty("music", out var music)) VoxClip.Core.Domain.Music.MusicProject.ValidateWire(music, supportsTimelineEdits);
        if (root.TryGetProperty("clipEffects", out var effects)) VoxClip.Core.Domain.Effects.ClipEffects.ValidateWire(effects, supportsTimelineEdits);
        if (root.TryGetProperty("clipControls", out var controls)) ClipControlsProject.ValidateWire(controls);
        if (root.TryGetProperty("captionTranslations", out var translations)) VoxClip.Core.Domain.Captions.CaptionTranslations.ValidateWire(translations);
    }

    private static void RenderRecipe(JsonElement recipe, string path)
    {
        Object(recipe, "audio words outDuration seed chunks roomTone seams video qa provenance cost voiceSource voiceRefId consentVerifiedAt", "edgeGain", path: path);
        Object(recipe.GetProperty("audio"), "assetId trimStart trimEnd stretch gainDb", "tiltDbPerOctave", path: $"{path}/audio");
        Nullable(recipe.GetProperty("words"), words => Array(words, $"{path}/words", (word, wordPath) => Object(word, "text start end synthetic", path: wordPath)));
        Array(recipe.GetProperty("chunks"), $"{path}/chunks", (item, itemPath) => Object(item, "sourceStartSample sourceEndSample requestId seed assetId assetSha256 assembledStartFrame assembledEndFrame", path: itemPath));
        Nullable(recipe.GetProperty("roomTone"), item => Object(item, "sourceStartSample sourceEndSample gainDb", "endGainDb", path: $"{path}/roomTone"));
        var seams = recipe.GetProperty("seams"); Object(seams, "in out", path: $"{path}/seams");
        foreach (var side in new[] { "in", "out" })
        {
            var seam = seams.GetProperty(side);
            var seamPath = $"{path}/seams/{side}";
            Object(seam, "kind fadeSamples sourceHandleSamples assetHandleFrames", "microPause", path: seamPath);
            if (seam.TryGetProperty("microPause", out var pause)) Object(pause, "wordStartSeconds wordEndSeconds", path: $"{seamPath}/microPause");
        }
        if (recipe.TryGetProperty("edgeGain", out var gains))
        {
            Object(gains, "", "in out", path: $"{path}/edgeGain");
            foreach (var side in new[] { "in", "out" })
                if (gains.TryGetProperty(side, out var gain))
                {
                    var gainPath = $"{path}/edgeGain/{side}";
                    Object(gain, "gainDb wordSeconds", path: gainPath);
                    Object(gain.GetProperty("wordSeconds"), "wordStartSeconds wordEndSeconds", path: $"{gainPath}/wordSeconds");
                }
        }
        Choice(seams.GetProperty("in").GetProperty("kind"), "none", "gap", "hard", "synthToSynth");
        Choice(seams.GetProperty("out").GetProperty("kind"), "none", "gap", "hard", "synthToSynth");
        var video = recipe.GetProperty("video");
        Object(video, "mode sourceStartSample sourceEndSample outputSamples retimeFactor zoom faceX faceY assetId provider model requestId windowStartSample windowEndSample syncMode", "cuts", path: $"{path}/video");
        if (video.TryGetProperty("cuts", out var cuts)) Array(cuts, $"{path}/video/cuts", (cut, cutPath) => Object(cut, "startSample endSample", path: cutPath));
        Choice(video.GetProperty("mode"), "source", "cut", "retimed", "zoomCover", "lipsync");
        Choice(recipe.GetProperty("voiceSource"), "own", "stock");
        var qa = recipe.GetProperty("qa");
        Object(qa, "transcriptTokens transcriptExact transcriptMatch lufsJumpLu peakDbfs speakerScore speakerThreshold speakerModel speakerPassed", "shortSpeech joinAdvisory outputSpeakerCheckSkipped", path: $"{path}/qa");
        if (qa.TryGetProperty("outputSpeakerCheckSkipped", out var skipped)) Require(skipped.ValueKind == JsonValueKind.True);
        if (qa.TryGetProperty("joinAdvisory", out var advisory))
        {
            Object(advisory, "seams acceptedAt", path: $"{path}/qa/joinAdvisory");
            Array(advisory.GetProperty("seams"), $"{path}/qa/joinAdvisory/seams", (seam, seamPath) => {
                Object(seam, "side excessLu", path: seamPath);
                Choice(seam.GetProperty("side"), "left", "right");
                Number(seam.GetProperty("excessLu"), 2);
            });
            Timestamp(advisory.GetProperty("acceptedAt"));
        }
        if (qa.TryGetProperty("shortSpeech", out var shortSpeech))
        {
            Object(shortSpeech, "mode recordId consentMethod voicedFrames takeCount", path: $"{path}/qa/shortSpeech");
            Choice(shortSpeech.GetProperty("mode"), "pooled", "unmeasured");
            Text(shortSpeech.GetProperty("recordId"), 0, int.MaxValue);
            Choice(shortSpeech.GetProperty("consentMethod"), "recordedStatement", "projectAttestation");
            Number(shortSpeech.GetProperty("voicedFrames"), 0, int.MaxValue, true);
            Number(shortSpeech.GetProperty("takeCount"), 0, int.MaxValue, true);
        }
        Object(recipe.GetProperty("provenance"), "provider endpoint model voiceId consentRecordId requestId seed createdAt region", "pace", path: $"{path}/provenance");
        if (recipe.GetProperty("provenance").TryGetProperty("pace", out var pace)) Number(pace, VoiceLabPace.Minimum, VoiceLabPace.Maximum);
        Object(recipe.GetProperty("cost"), "quoteId usd", path: $"{path}/cost");
    }

    private static void Transcript(JsonElement transcript, bool normalizeWordText, string path)
    {
        Object(transcript, "schemaVersion words language languageProbability durationSeconds engine verbatim refined pipelineVersion rawKey createdAt", path: path);
        Number(transcript.GetProperty("schemaVersion"), 1, 1, true);
        Nullable(transcript.GetProperty("language"), value => String(value, "[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*")); Nullable(transcript.GetProperty("languageProbability"), value => Number(value, 0, 1));
        Number(transcript.GetProperty("durationSeconds"), 0); Boolean(transcript.GetProperty("verbatim")); Boolean(transcript.GetProperty("refined")); Number(transcript.GetProperty("pipelineVersion"), 1, int.MaxValue, true);
        String(transcript.GetProperty("rawKey"), Hash); Timestamp(transcript.GetProperty("createdAt"));
        var engine = transcript.GetProperty("engine"); Object(engine, "id modelId modelSha256 engineVersion locale", path: path + "/engine"); Choice(engine.GetProperty("id"), "elevenlabs", "whispercpp", "apple-speech");
        Nullable(engine.GetProperty("modelId"), value => Text(value, 0, 128)); Nullable(engine.GetProperty("modelSha256"), value => String(value, Hash));
        Text(engine.GetProperty("engineVersion"), 1, 128); Nullable(engine.GetProperty("locale"), value => Text(value, 0, 35));
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var previousStart = double.NegativeInfinity;
        Array(transcript.GetProperty("words"), path + "/words", (word, wordPath) =>
        {
            Object(word, "id text kind start end rawStart rawEnd conf speaker timing", path: wordPath); String(word.GetProperty("id"), Id); WordText(word.GetProperty("text"), normalizeWordText); Choice(word.GetProperty("kind"), "word", "event", "unlabeledSpeech");
            Number(word.GetProperty("start"), 0); Number(word.GetProperty("end"), 0);
            var start = word.GetProperty("start").GetDouble();
            Require(start >= previousStart && word.GetProperty("end").GetDouble() > start && ids.Add(word.GetProperty("id").GetString()!));
            previousStart = start;
            Nullable(word.GetProperty("rawStart"), value => Number(value, 0)); Nullable(word.GetProperty("rawEnd"), value => Number(value, 0)); Nullable(word.GetProperty("conf"), value => Number(value, 0, 1));
            Nullable(word.GetProperty("speaker"), value => Text(value, 0, 64)); Choice(word.GetProperty("timing"), "native", "dtw", "tokenGrouped", "runGrouped", "detected");
        });
    }

    private static void WordText(JsonElement value, bool normalizeWordText)
    {
        Require(value.ValueKind == JsonValueKind.String);
        var text = value.GetString()!;
        if (normalizeWordText) text = EditingAlgorithms.Nfc(text);
        Require(text.EnumerateRunes().Count() is >= 1 and <= 200);
        Require(text == EditingAlgorithms.JsTrim(text) && string.Equals(EditingAlgorithms.Nfc(text), text, StringComparison.Ordinal));
    }

    private static void Position(JsonElement position, string path)
    {
        Object(position, "x y", path: path);
        At($"{path}/x", () => Number(position.GetProperty("x"), 0, 1)); At($"{path}/y", () => Number(position.GetProperty("y"), 0, 1));
    }

    // A failed value check inside an element reports that element's path, not the whole document.
    private static void At(string path, Action validate)
    {
        try { validate(); }
        catch (JsonException) { throw Problem(path, "invalid value"); }
    }

    // "$.a.b[0]['key']" (System.Text.Json) as "a/b/0/key"; empty when unknown.
    // The path stops before the first key that is not a plain identifier, so a rejected key is never printed.
    internal static string FieldPath(string? jsonPath)
    {
        if (jsonPath is not { Length: > 1 } || jsonPath[0] != '$') return "";
        var segments = new List<string>();
        foreach (Match match in Regex.Matches(jsonPath[1..], @"\.([^.\[]+)|\[(\d+)\]|\['(.*?)'\]"))
        {
            var segment = match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Success ? match.Groups[2].Value : match.Groups[3].Value;
            if (!PathKey.IsMatch(segment)) break;
            segments.Add(segment);
        }
        return string.Join('/', segments);
    }

    private static void Timestamp(JsonElement value)
        => Require(value.ValueKind == JsonValueKind.String && UtcTimestamp.TryParse(value.GetString(), out _));

    private static VoxClipException Problem(string path, string reason) => new(VoxClipErrorCode.ProjectUnreadable, $"{path}: {reason}");

    private static void ExpectObject(JsonElement value, string path)
    {
        if (value.ValueKind != JsonValueKind.Object) throw Problem(path, "expected object");
    }

    private static void Object(JsonElement value, string required, string optional = "", string path = "/")
    {
        ExpectObject(value, path);
        var keys = required.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        foreach (var key in keys)
        {
            if (value.TryGetProperty(key, out _)) continue;
            throw Problem(path == "/" ? key : path + "/" + key, "missing required field");
        }
        var allowed = keys.Concat(optional.Split(' ', StringSplitOptions.RemoveEmptyEntries)).ToHashSet(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (allowed.Contains(property.Name)) continue;
            throw Problem(path, "unknown field");
        }
    }

    private static void Array(JsonElement value, string path, Action<JsonElement, string> validate)
    {
        if (value.ValueKind != JsonValueKind.Array) throw Problem(path, "expected array");
        var index = 0;
        foreach (var item in value.EnumerateArray())
        {
            var itemPath = $"{path}/{index++}";
            At(itemPath, () => validate(item, itemPath));
        }
    }

    // A key that fails its pattern is reported at the map; an accepted key names its entry only when it is a plain identifier.
    private static void Dictionary(JsonElement value, string path, Action<string, JsonElement, string> validate, string? keyPattern = null)
    {
        ExpectObject(value, path);
        foreach (var property in value.EnumerateObject())
        {
            if (keyPattern is not null) At(path, () => Pattern(property.Name, keyPattern));
            var entryPath = Entry(path, property.Name);
            At(entryPath, () => validate(property.Name, property.Value, entryPath));
        }
    }

    private static readonly Regex PathKey = new(@"\A[A-Za-z0-9._:-]{1,128}\z", RegexOptions.CultureInvariant);
    private static string Entry(string parent, string key) => PathKey.IsMatch(key) ? $"{parent}/{key}" : parent;

    private static void UniqueStrings(JsonElement value, string pattern, string path)
    {
        var found = new HashSet<string>(StringComparer.Ordinal);
        Array(value, path, (item, _) => { String(item, pattern); Require(found.Add(item.GetString()!)); });
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
    private static void Pattern(string value, string pattern) => Require(Regex.IsMatch(value, "\\A(?:" + pattern + ")\\z",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking, Regex.InfiniteMatchTimeout));
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
