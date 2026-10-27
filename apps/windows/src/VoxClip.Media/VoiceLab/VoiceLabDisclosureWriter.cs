using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Media.VoiceLab;

/// <summary>New staged MP4 and sidecar bytes for the exporter's existing multi-file transaction.</summary>
public sealed record VoiceLabStagedDisclosure(string Mp4Path, string SidecarFilename, byte[] SidecarData, string Sha256);

/// <summary>Standard ISO BMFF Adobe XMP UUID attachment and final-file provenance; Voice Lab §11.7–11.8.</summary>
public static class VoiceLabDisclosureWriter
{
    /// <summary>IPTC composite media vocabulary value required by Voice Lab §11.7.</summary>
    public const string DigitalSourceType = "http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia";
    private static readonly byte[] XmpUuid = Convert.FromHexString("BE7ACFCB97A942E89C71999491E3AFAC");
    /// <summary>UTF-8 XMP RDF packet embedded in the standard Adobe UUID box.</summary>
    public static byte[] XmpPacket() => Encoding.UTF8.GetBytes("<?xpacket begin=\"\uFEFF\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>" +
        "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" +
        "<rdf:Description rdf:about=\"\" xmlns:Iptc4xmpExt=\"http://iptc.org/std/Iptc4xmpExt/2008-02-29/\" " +
        "Iptc4xmpExt:DigitalSourceType=\"" + DigitalSourceType + "\"/></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>");

    /// <summary>The caller passes its actual app version and publishes both returned artifacts transactionally.</summary>
    public static async Task<VoiceLabStagedDisclosure> StageAsync(string sourceMp4, string stagedMp4, string finalFilename,
        Project project, VoiceLabPreparedRender prepared, string appVersion, DateTimeOffset createdAt, CancellationToken ct)
    {
        prepared.Verify(project, prepared.OutputPlan.Scope, prepared.Disclosure.Position);
        var isolated = ProjectSerialization.Deserialize(ProjectSerialization.Serialize(project));
        prepared.Verify(isolated, prepared.OutputPlan.Scope, prepared.Disclosure.Position);
        var frozen = VoiceLabRenderContract.Prepare(isolated, prepared.OutputPlan.Scope, prepared.Disclosure.Position);
        prepared.Verify(project, prepared.OutputPlan.Scope, prepared.Disclosure.Position);
        if (!prepared.Disclosure.Required || prepared.SelectedSegmentRecipes.Count == 0 ||
            string.IsNullOrWhiteSpace(appVersion) || appVersion.Contains('/') || appVersion.Contains('\\') ||
            !finalFilename.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase) || finalFilename.Contains('\\') ||
            Path.GetFileName(finalFilename) != finalFilename ||
            Path.GetFullPath(sourceMp4) == Path.GetFullPath(stagedMp4)) throw new InvalidDataException("Invalid disclosure staging request.");
        if (File.Exists(stagedMp4)) throw new IOException("Disclosure stage already exists.");
        var created = false;
        try
        {
            await using var source = new FileStream(sourceMp4, FileMode.Open, FileAccess.Read, FileShare.Read, 1_048_576, true);
            ValidateMp4(source);
            source.Position = 0;
            await using var output = new FileStream(stagedMp4, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1_048_576, true);
            created = true;
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[1_048_576];
            long copied = 0;
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                var count = await source.ReadAsync(buffer, ct).ConfigureAwait(false);
                if (count == 0) break;
                await output.WriteAsync(buffer.AsMemory(0, count), ct).ConfigureAwait(false);
                hash.AppendData(buffer, 0, count);
                copied += count;
                if (copied / (64L * 1024 * 1024) != (copied - count) / (64L * 1024 * 1024))
                    VoiceLabCapacity.Require([new VoiceLabCapacity.Allocation(stagedMp4,
                        VoiceLabCapacity.Bytes(source.Length - copied, 1, 65_536))]);
            }
            var packet = XmpPacket();
            var box = new byte[24 + packet.Length];
            BinaryPrimitives.WriteUInt32BigEndian(box, checked((uint)box.Length));
            Encoding.ASCII.GetBytes("uuid").CopyTo(box, 4);
            XmpUuid.CopyTo(box, 8);
            packet.CopyTo(box, 24);
            await output.WriteAsync(box, ct).ConfigureAwait(false);
            hash.AppendData(box);
            await output.FlushAsync(ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            var digest = Convert.ToHexStringLower(hash.GetHashAndReset());
            var sidecar = Sidecar(isolated, frozen, finalFilename, digest, appVersion, createdAt);
            return new(stagedMp4, finalFilename + ".provenance.json", sidecar, digest);
        }
        catch
        {
            if (created) try { File.Delete(stagedMp4); } catch (IOException) { }
            throw;
        }
    }

    private static void ValidateMp4(FileStream stream)
    {
        var header = new byte[16];
        HashSet<string> Scan(long start, long end, int depth)
        {
            if (depth > 4) throw new InvalidDataException("Invalid MP4 box nesting.");
            var found = new HashSet<string>(StringComparer.Ordinal);
            var uuid = new byte[16];
            var cursor = start;
            while (cursor < end)
            {
                if (end - cursor < 8) throw new InvalidDataException("Truncated MP4 box.");
                stream.Position = cursor;
                stream.ReadExactly(header.AsSpan(0, 8));
                var size = BinaryPrimitives.ReadUInt32BigEndian(header);
                var kind = Encoding.ASCII.GetString(header, 4, 4);
                // A zero-sized terminal box extends to EOF and would absorb our appended UUID.
                if (size == 0) throw new InvalidDataException("Cannot append XMP after a size-zero MP4 box.");
                var headerSize = size == 1 ? 16 : 8;
                long boxSize = size;
                if (size == 1)
                {
                    stream.ReadExactly(header.AsSpan(8, 8));
                    var large = BinaryPrimitives.ReadUInt64BigEndian(header.AsSpan(8));
                    if (large > long.MaxValue) throw new InvalidDataException("Invalid large MP4 box.");
                    boxSize = (long)large;
                }
                if (boxSize < headerSize || boxSize > end - cursor)
                    throw new InvalidDataException("Invalid MP4 box length.");
                if (kind == "XMP_") throw new InvalidDataException("MP4 already contains XMP.");
                if (kind == "uuid")
                {
                    if (boxSize < headerSize + 16) throw new InvalidDataException("Invalid MP4 UUID box.");
                    stream.Position = cursor + headerSize;
                    stream.ReadExactly(uuid);
                    if (uuid.SequenceEqual(XmpUuid)) throw new InvalidDataException("MP4 already contains XMP.");
                }
                if (kind is "moov" or "udta" or "meta")
                {
                    var extra = kind == "meta" ? 4 : 0;
                    if (boxSize < headerSize + extra) throw new InvalidDataException("Invalid MP4 container.");
                    _ = Scan(cursor + headerSize + extra, cursor + boxSize, depth + 1);
                }
                found.Add(kind); cursor += boxSize;
            }
            return found;
        }
        var found = Scan(0, stream.Length, 0);
        if (!found.IsSupersetOf(["ftyp", "moov", "mdat"])) throw new InvalidDataException("Not a complete MP4.");
    }

    private static byte[] Sidecar(Project project, VoiceLabPreparedRender prepared, string filename, string hash,
        string appVersion, DateTimeOffset createdAt)
    {
        using var stream = new MemoryStream();
        using (var json = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
        {
            json.WriteStartObject();
            json.WriteString("schema", "voxclip-provenance/1");
            json.WriteStartObject("app"); json.WriteString("name", "VoxClip"); json.WriteString("version", appVersion);
            json.WriteString("platform", "windows"); json.WriteEndObject();
            json.WriteStartObject("export"); json.WriteString("file", filename); json.WriteString("sha256", hash);
            json.WriteNumber("durationSeconds", prepared.OutputPlan.Duration); json.WriteString("createdAt", UtcTimestamp.Format(createdAt)); json.WriteEndObject();
            json.WriteStartObject("source"); json.WriteString("contentKey", project.Media.Source.ContentKey);
            json.WriteNumber("durationSeconds", project.Media.Source.DurationSeconds); json.WriteEndObject();
            json.WriteStartObject("scope"); json.WriteString("kind", prepared.OutputPlan.Scope.ClipId is null ? "full" : "clip");
            if (prepared.OutputPlan.Scope.ClipId is { } clipId) json.WriteString("clipId", clipId); json.WriteEndObject();
            json.WriteStartObject("edits"); json.WriteNumber("cutWords", project.Edits.CutWordIds.Count);
            json.WriteNumber("cutPauses", project.Edits.CutPauseIds.Count); json.WriteNumber("corrections", project.Edits.Corrections.Count); json.WriteEndObject();
            json.WriteStartArray("aiSegments");
            foreach (var selected in prepared.SelectedSegmentRecipes)
            {
                var segment = project.VoiceLab.Segments.Single(item => item.Id == selected.SegmentId);
                var provenance = selected.Recipe.Provenance;
                var asset = project.VoiceLab.Assets!.Single(item => item.Id == selected.Recipe.Audio.AssetId);
                json.WriteStartObject(); json.WriteString("segmentId", segment.Id);
                json.WriteString("kind", segment.Kind == VoiceLabSegmentKind.Tts ? "tts" : "voiceChanger");
                json.WriteNumber("outputStart", selected.Piece.OutputStartSample / prepared.OutputPlan.SampleRate);
                json.WriteNumber("outputEnd", selected.Piece.OutputEndSample / prepared.OutputPlan.SampleRate);
                json.WriteNumber("candidateIndex", segment.SelectedCandidateIndex); json.WriteString("assetSha256", asset.Sha256);
                json.WriteString("provider", provenance.Provider); json.WriteString("endpoint", provenance.Endpoint);
                json.WriteString("model", provenance.Model); json.WriteString("voice", selected.Recipe.VoiceSource == VoiceLabVoiceSource.Own ? "own" : "stock");
                json.WriteString("voiceId", provenance.VoiceId); json.WriteNumber("seed", selected.Recipe.Seed);
                json.WriteString("generatedAt", UtcTimestamp.Format(provenance.CreatedAt));
                if (segment.Text is { } text) json.WriteString("text", text.New);
                if (provenance.Region is { } region) json.WriteString("region", region);
                if (provenance.RequestId is { } request) json.WriteString("requestId", request);
                var qa = selected.Recipe.Qa;
                if (qa.SpeakerScore is not null || qa.SpeakerThreshold is not null || qa.SpeakerModel is not null || qa.SpeakerPassed is not null)
                {
                    json.WriteStartObject("verification");
                    if (qa.SpeakerScore is { } score) json.WriteNumber("speakerScore", score);
                    if (qa.SpeakerThreshold is { } threshold) json.WriteNumber("speakerThreshold", threshold);
                    if (qa.SpeakerModel is { } model) json.WriteString("speakerModel", model);
                    if (qa.SpeakerPassed is { } passed) json.WriteBoolean("speakerPassed", passed);
                    json.WriteEndObject();
                }
                if (provenance.ConsentRecordId is { } record) json.WriteString("consentRecordId", record);
                json.WriteEndObject();
            }
            json.WriteEndArray();
            var disclosure = prepared.Disclosure;
            json.WriteStartObject("disclosure"); json.WriteBoolean("required", disclosure.Required);
            json.WriteBoolean("persistent", disclosure.Persistent); json.WriteStartArray("labelIntervals");
            foreach (var interval in disclosure.Intervals) { json.WriteStartArray(); json.WriteNumberValue(interval.Start); json.WriteNumberValue(interval.End); json.WriteEndArray(); }
            json.WriteEndArray(); json.WriteString("postText", disclosure.PostText ?? ""); json.WriteBoolean("c2pa", false); json.WriteEndObject();
            json.WriteStartArray("consent");
            foreach (var group in prepared.SelectedSegmentRecipes.Where(item => item.Recipe.Provenance.ConsentRecordId is not null)
                .GroupBy(item => item.Recipe.Provenance.ConsentRecordId!, StringComparer.Ordinal))
            {
                json.WriteStartObject(); json.WriteString("recordId", group.Key);
                if (group.First().Recipe.ConsentVerifiedAt is { } verified) json.WriteString("verifiedAt", UtcTimestamp.Format(verified));
                json.WriteEndObject();
            }
            json.WriteEndArray(); json.WriteEndObject();
        }
        return stream.ToArray();
    }
}
