using System.Buffers.Binary;
using System.Text;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Media.VoiceLab;

internal interface IVoiceLabSource
{
    void Read(long startSample, Span<float> stereo, CancellationToken ct);
}

/// <summary>Bounded source-grid reader for one validated private PCM/float WAV snapshot.</summary>
internal sealed class VoiceLabWaveReader : IDisposable
{
    private readonly FileStream file;
    private readonly byte[] bytes;
    private readonly float[] cache;
    private readonly long dataStart;
    private readonly int bytesPerFrame;
    private readonly int format;
    private readonly int bits;
    private long cachedStart = -1;
    private int cachedFrames;
    internal int Rate { get; }
    internal int Channels { get; }
    internal long Frames { get; }

    internal VoiceLabWaveReader(PreparedVoiceLabAsset asset)
    {
        file = new FileStream(asset.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, FileOptions.RandomAccess);
        try
        {
            using var reader = new BinaryReader(file, Encoding.ASCII, true);
            if (file.Length < 44 || Encoding.ASCII.GetString(reader.ReadBytes(4)) != "RIFF") throw Invalid();
            var size = reader.ReadUInt32();
            if (size + 8L != file.Length || Encoding.ASCII.GetString(reader.ReadBytes(4)) != "WAVE") throw Invalid();
            int rate = 0, channels = 0, sampleBits = 0, sampleFormat = 0, block = 0;
            long offset = -1, length = 0;
            while (file.Position + 8 <= file.Length)
            {
                var id = Encoding.ASCII.GetString(reader.ReadBytes(4));
                var count = (long)reader.ReadUInt32();
                var start = file.Position;
                if (count + (count & 1) > file.Length - start) throw Invalid();
                if (id == "fmt ")
                {
                    if (rate != 0 || count < 16) throw Invalid();
                    sampleFormat = reader.ReadUInt16(); channels = reader.ReadUInt16(); rate = reader.ReadInt32();
                    _ = reader.ReadInt32(); block = reader.ReadUInt16(); sampleBits = reader.ReadUInt16();
                }
                else if (id == "data") { if (offset >= 0) throw Invalid(); offset = start; length = count; }
                file.Position = start + count + (count & 1);
            }
            if (rate != asset.SampleRate || channels != asset.Channels || offset < 0 || block <= 0 ||
                length / block != asset.FrameCount || length % block != 0 || channels is < 1 or > 8 ||
                sampleFormat == 1 && sampleBits is not (16 or 24 or 32) ||
                sampleFormat == 3 && sampleBits is not (32 or 64) || sampleFormat is not (1 or 3) ||
                block != channels * sampleBits / 8) throw Invalid();
            Rate = rate; Channels = channels; Frames = asset.FrameCount;
            dataStart = offset; bytesPerFrame = block; format = sampleFormat; bits = sampleBits;
            bytes = new byte[checked(4096 * block)]; cache = new float[4096 * channels];
        }
        catch { file.Dispose(); throw; }
    }

    private static IOException Invalid() => new("The prepared Voice Lab WAV snapshot cannot be decoded.");

    internal void Read(double firstFrame, double step, Span<float> stereo, CancellationToken ct)
    {
        if (stereo.Length % 2 != 0 || !double.IsFinite(firstFrame) || !double.IsFinite(step) || step <= 0)
            throw Invalid();
        for (var i = 0; i < stereo.Length / 2; i++)
        {
            if ((i & 4095) == 0) ct.ThrowIfCancellationRequested();
            var position = firstFrame + i * step;
            if (position < 0 || position >= Frames) throw Invalid();
            var frame = (long)Math.Floor(position);
            var fraction = position - frame;
            var left = Sample(frame, 0);
            var right = Channels == 1 ? left : Sample(frame, 1);
            if (fraction > 0 && frame + 1 < Frames)
            {
                left += (Sample(frame + 1, 0) - left) * (float)fraction;
                right += (Sample(frame + 1, Math.Min(1, Channels - 1)) - right) * (float)fraction;
            }
            stereo[2 * i] = left; stereo[2 * i + 1] = right;
        }
    }

    private float Sample(long frame, int channel)
    {
        if (frame < cachedStart || frame >= cachedStart + cachedFrames) Load(frame);
        return cache[checked((int)(frame - cachedStart) * Channels + channel)];
    }

    private void Load(long frame)
    {
        if (frame < 0 || frame >= Frames) throw Invalid();
        cachedStart = frame; cachedFrames = (int)Math.Min(4096, Frames - frame);
        file.Position = checked(dataStart + frame * bytesPerFrame);
        file.ReadExactly(bytes.AsSpan(0, cachedFrames * bytesPerFrame));
        var sampleBytes = bits / 8;
        for (var i = 0; i < cachedFrames * Channels; i++)
        {
            var sample = bytes.AsSpan(i * sampleBytes, sampleBytes);
            var value = format == 3 ? bits == 32
                ? BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(sample))
                : (float)BitConverter.Int64BitsToDouble(BinaryPrimitives.ReadInt64LittleEndian(sample))
                : bits switch
                {
                    16 => BinaryPrimitives.ReadInt16LittleEndian(sample) / 32768f,
                    24 => ((sample[0] | sample[1] << 8 | sample[2] << 16) << 8 >> 8) / 8388608f,
                    _ => BinaryPrimitives.ReadInt32LittleEndian(sample) / 2147483648f
                };
            if (!float.IsFinite(value)) throw Invalid();
            cache[i] = value;
        }
    }

    public void Dispose() => file.Dispose();
}

/// <summary>Reads source, generated pieces, room tone and centered seams with fixed block storage.</summary>
internal sealed class VoiceLabAudioMixer : IDisposable
{
    private readonly VoiceLabOutputPlan plan;
    private readonly IVoiceLabSource source;
    private readonly Dictionary<string, (VoiceLabSelectedRecipe recipe, PreparedVoiceLabAsset asset)> assets;
    private readonly IReadOnlyDictionary<string, VoiceLabTempoTrack>? tempoTracks;
    private readonly List<(long start, int count, VoiceLabOutputPiece left, VoiceLabOutputPiece right)> seams = [];
    private readonly (string id, VoiceLabWaveReader wave)?[] waveCache = new (string, VoiceLabWaveReader)?[2];
    private readonly (string id, VoiceLabTempoReader reader)?[] tempoCache = new (string, VoiceLabTempoReader)?[2];
    private string? toneSegment;
    private float[]? toneSamples;
    private int cachedSeamIndex = -1;
    private float[]? cachedSeam;
    private long position;

    internal VoiceLabAudioMixer(VoiceLabPreparedRender prepared, IReadOnlyDictionary<string, PreparedVoiceLabAsset> handles,
        IVoiceLabSource source, long startSample = 0, IReadOnlyDictionary<string, VoiceLabTempoTrack>? tempoTracks = null,
        CancellationToken ct = default)
    {
        plan = prepared.OutputPlan; this.source = source; this.tempoTracks = tempoTracks;
        assets = new(StringComparer.Ordinal);
        try
        {
            foreach (var recipe in prepared.SelectedSegmentRecipes)
            {
                ct.ThrowIfCancellationRequested();
                var asset = handles[recipe.SegmentId];
                assets.Add(recipe.SegmentId, (recipe, asset));
            }
            BuildSeams();
            position = Math.Clamp(startSample, 0, plan.OutputSamples);
        }
        catch { Dispose(); throw; }
    }

    private static VoiceLabProjectException Invalid() => new(VoiceLabProjectErrorCode.InvalidFadeHandles);

    internal long Remaining => plan.OutputSamples - position;

    private int PieceIndex(long sample)
    {
        var low = 0; var high = plan.Pieces.Count - 1;
        while (low <= high)
        {
            var middle = low + (high - low) / 2;
            var piece = plan.Pieces[middle];
            if (sample < piece.OutputStartSample) high = middle - 1;
            else if (sample >= piece.OutputEndSample) low = middle + 1;
            else return middle;
        }
        throw Invalid();
    }

    private VoiceLabWaveReader Wave(string id)
    {
        if (waveCache[0] is { } first && first.id == id) return first.wave;
        if (waveCache[1] is { } second && second.id == id)
        { waveCache[1] = waveCache[0]; waveCache[0] = second; return second.wave; }
        var wave = new VoiceLabWaveReader(assets[id].asset);
        waveCache[1]?.wave.Dispose();
        waveCache[1] = waveCache[0]; waveCache[0] = (id, wave);
        return wave;
    }

    private VoiceLabTempoReader Tempo(string id)
    {
        if (tempoTracks is null || !tempoTracks.TryGetValue(id, out var track)) throw new VoiceLabTempoException();
        if (tempoCache[0] is { } first && first.id == id) return first.reader;
        if (tempoCache[1] is { } second && second.id == id)
        { tempoCache[1] = tempoCache[0]; tempoCache[0] = second; return second.reader; }
        var reader = track.OpenReader();
        tempoCache[1]?.reader.Dispose();
        tempoCache[1] = tempoCache[0]; tempoCache[0] = (id, reader);
        return reader;
    }

    internal int Read(Span<float> stereo, int frames, CancellationToken ct)
    {
        frames = (int)Math.Min(frames, Math.Min(Remaining, stereo.Length / 2));
        var written = 0;
        while (written < frames)
        {
            ct.ThrowIfCancellationRequested();
            var index = PieceIndex(position);
            var piece = plan.Pieces[index];
            var count = (int)Math.Min(Math.Min(4096, frames - written), piece.OutputEndSample - position);
            var target = stereo.Slice(written * 2, count * 2);
            Render(piece, position - piece.OutputStartSample, target, ct);
            ApplySeams(position, target, ct);
            ApplyOrdinaryCutGain(piece, index, position, target);
            position += count; written += count;
        }
        return written;
    }

    private void Render(VoiceLabOutputPiece piece, long relative, Span<float> target, CancellationToken ct)
    {
        if (piece.Kind == VoiceLabOutputPieceKind.Source)
        { source.Read(piece.SourceStartSample + relative, target, ct); return; }
        var (_, asset) = assets[piece.SegmentId!];
        if (VoiceLabTempo.RequiresFit(asset.Stretch))
            Tempo(piece.SegmentId!).Read(relative, plan.SampleRate, target, ct);
        else
        {
            var first = asset.TrimStartFrame + relative * (double)asset.SampleRate / plan.SampleRate;
            Wave(piece.SegmentId!).Read(first, asset.SampleRate / plan.SampleRate, target, ct);
        }
        var gain = (float)Math.Pow(10, asset.GainDb / 20);
        for (var i = 0; i < target.Length; i++) target[i] *= gain;
        AddRoomTone(piece.SegmentId!, relative, target, ct);
    }

    private void AddRoomTone(string segmentId, long relative, Span<float> target, CancellationToken ct)
    {
        var recipe = assets[segmentId].recipe.Recipe;
        if (recipe.RoomTone is { } run)
        {
            if (toneSegment != segmentId)
            {
                var size = checked((int)(run.SourceEndSample - run.SourceStartSample));
                if (size <= 0 || size > plan.SampleRate || size > 192_000) throw Invalid();
                var loaded = new float[size * 2];
                source.Read(run.SourceStartSample, loaded, ct);
                toneSamples = loaded; toneSegment = segmentId;
            }
            var tone = toneSamples!;
            var toneGain = (float)Math.Pow(10, run.GainDb / 20);
            var length = tone.Length / 2;
            var fade = Math.Min((int)Math.Round(plan.SampleRate * 0.05), length / 2);
            for (var i = 0; i < target.Length / 2; i++)
            {
                if ((i & 4095) == 0) ct.ThrowIfCancellationRequested();
                for (var channel = 0; channel < 2; channel++)
                    target[2 * i + channel] += toneGain * RoomToneSample(tone, relative + i, channel, fade);
            }
        }
    }

    internal static float RoomToneSample(float[] tone, long relative, int channel, int fade)
    {
        var length = tone.Length / 2;
        var period = length - fade;
        var index = (int)(((relative % period) + period) % period);
        var head = tone[2 * index + channel];
        if (fade == 0 || relative < period || index >= fade) return head;
        var u = (index + 1) / (float)(fade + 1);
        return tone[2 * (period + index) + channel] * (1 - u) + head * u;
    }

    private void BuildSeams()
    {
        for (var i = 0; i + 1 < plan.Pieces.Count; i++)
        {
            var left = plan.Pieces[i]; var right = plan.Pieces[i + 1];
            if (left.Kind != VoiceLabOutputPieceKind.Synth && right.Kind != VoiceLabOutputPieceKind.Synth) continue;
            var seam = left.Kind == VoiceLabOutputPieceKind.Synth
                ? assets[left.SegmentId!].recipe.Recipe.Seams.Out : assets[right.SegmentId!].recipe.Recipe.Seams.In;
            if (seam.Kind == VoiceLabSeamKind.None) throw Invalid();
            var n = checked((int)seam.FadeSamples);
            if (n < 2 || n > 8192) throw Invalid();
            var before = n / 2; var after = n - before;
            if (left.OutputEndSample - left.OutputStartSample < before || right.OutputEndSample - right.OutputStartSample < after)
                throw Invalid();
            var first = left.OutputEndSample - before;
            seams.Add((first, n, left, right));
        }
    }

    private void RenderExtended(VoiceLabOutputPiece piece, long relative, Span<float> target, CancellationToken ct)
    {
        if (piece.Kind == VoiceLabOutputPieceKind.Source)
        {
            var sourceStart = piece.SourceStartSample + relative;
            if (sourceStart < 0 || sourceStart + target.Length / 2 > plan.TotalSourceSamples) throw Invalid();
            source.Read(sourceStart, target, ct);
            return;
        }
        var (_, asset) = assets[piece.SegmentId!];
        if (VoiceLabTempo.RequiresFit(asset.Stretch))
            Tempo(piece.SegmentId!).Read(relative, plan.SampleRate, target, ct);
        else
        {
            var step = asset.SampleRate / plan.SampleRate;
            var first = asset.TrimStartFrame + relative * step;
            Wave(piece.SegmentId!).Read(first, step, target, ct);
        }
        var gain = (float)Math.Pow(10, asset.GainDb / 20);
        for (var j = 0; j < target.Length; j++) target[j] *= gain;
        AddRoomTone(piece.SegmentId!, relative, target, ct);
    }

    private float[] SeamSamples(int index, CancellationToken ct)
    {
        if (cachedSeamIndex == index && cachedSeam is { } prior) return prior;
        var (first, n, left, right) = seams[index];
        var lhs = new float[n * 2]; var rhs = new float[n * 2];
        RenderExtended(left, first - left.OutputStartSample, lhs, ct);
        RenderExtended(right, first - right.OutputStartSample, rhs, ct);
        for (var j = 0; j < n; j++)
        {
            if ((j & 4095) == 0) ct.ThrowIfCancellationRequested();
            var u = j / (double)(n - 1);
            var a = (float)Math.Cos(Math.PI * u / 2);
            var b = (float)Math.Sin(Math.PI * u / 2);
            lhs[2 * j] = lhs[2 * j] * a + rhs[2 * j] * b;
            lhs[2 * j + 1] = lhs[2 * j + 1] * a + rhs[2 * j + 1] * b;
        }
        cachedSeamIndex = index; cachedSeam = lhs;
        return lhs;
    }

    private void ApplySeams(long start, Span<float> target, CancellationToken ct)
    {
        var low = 0; var high = seams.Count;
        while (low < high)
        {
            var middle = low + (high - low) / 2;
            if (seams[middle].start < start) low = middle + 1;
            else high = middle;
        }
        for (var i = Math.Max(0, low - 1); i < seams.Count && seams[i].start < start + target.Length / 2; i++)
        {
            var seamStart = seams[i].start;
            var from = Math.Max(start, seamStart); var end = Math.Min(start + target.Length / 2, seamStart + seams[i].count);
            if (end <= from) continue;
            var samples = SeamSamples(i, ct);
            samples.AsSpan(checked((int)(from - seamStart) * 2), checked((int)(end - from) * 2))
                .CopyTo(target.Slice(checked((int)(from - start) * 2)));
        }
    }

    private void ApplyOrdinaryCutGain(VoiceLabOutputPiece piece, int index, long start, Span<float> target)
    {
        if (piece.Kind != VoiceLabOutputPieceKind.Source) return;
        var maxFade = (long)Math.Round(plan.SampleRate * 0.005, MidpointRounding.AwayFromZero);
        var length = piece.OutputEndSample - piece.OutputStartSample;
        var fade = Math.Min(maxFade, length / 2);
        var fadeIn = piece.SourceStartSample > 0 && (index == 0 ||
            plan.Pieces[index - 1].Kind == VoiceLabOutputPieceKind.Source &&
            plan.Pieces[index - 1].SourceEndSample < piece.SourceStartSample);
        var fadeOut = piece.SourceEndSample < plan.TotalSourceSamples && (index + 1 == plan.Pieces.Count ||
            plan.Pieces[index + 1].Kind == VoiceLabOutputPieceKind.Source &&
            piece.SourceEndSample < plan.Pieces[index + 1].SourceStartSample);
        for (var j = 0; j < target.Length / 2; j++)
        {
            var at = start + j - piece.OutputStartSample;
            var gain = 1.0;
            if (fadeIn && at < fade) gain *= at / (double)fade;
            if (fadeOut && length - 1 - at < fade) gain *= (length - 1 - at) / (double)fade;
            target[2 * j] *= (float)gain; target[2 * j + 1] *= (float)gain;
        }
    }

    public void Dispose()
    {
        waveCache[0]?.wave.Dispose(); waveCache[1]?.wave.Dispose();
        tempoCache[0]?.reader.Dispose(); tempoCache[1]?.reader.Dispose();
        toneSamples = null; cachedSeam = null;
    }
}
