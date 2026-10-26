using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using FFmpeg.AutoGen;

// Standalone diagnostic. Its input is only the audited six-DLL ZIP extracted to
// nativeDir, its matching build report, and the committed schema-2 manifest.
// No app or test-tools binaries are referenced.
if (args.Length != 4 || args[0] is not ("win-arm64" or "win-x64"))
    throw new ArgumentException("Usage: NativeAtempo <win-arm64|win-x64> <nativeDir> <report.json> <ffmpeg.json>");
var rid = args[0];
var nativeDir = Path.GetFullPath(args[1]);
using var report = JsonDocument.Parse(File.ReadAllText(args[2]));
using var manifest = JsonDocument.Parse(File.ReadAllText(args[3]));
var root = report.RootElement;
if (root.GetProperty("rid").GetString() != rid ||
    root.GetProperty("buildInputsSha256").GetString() != manifest.RootElement.GetProperty("buildInputsSha256").GetString() ||
    root.GetProperty("sha256").GetString() != manifest.RootElement.GetProperty("builds").GetProperty(rid).GetProperty("sha256").GetString())
    throw new InvalidDataException("Build report does not match RID and committed manifest");
var expectedArch = rid == "win-arm64" ? Architecture.Arm64 : Architecture.X64;
if (!OperatingSystem.IsWindows() || RuntimeInformation.ProcessArchitecture != expectedArch || !Environment.Is64BitProcess)
    throw new PlatformNotSupportedException($"Expected Windows {expectedArch} process; got {RuntimeInformation.OSDescription} {RuntimeInformation.ProcessArchitecture}");
var dlls = root.GetProperty("dlls");
string[] names = ["avcodec-63.dll", "avformat-63.dll", "avutil-61.dll", "avfilter-12.dll", "swresample-7.dll", "swscale-10.dll"];
if (dlls.EnumerateObject().Count() != names.Length || Directory.GetFiles(nativeDir, "*.dll").Length != names.Length)
    throw new InvalidDataException("Native directory or report does not contain exactly six DLLs");
foreach (var name in names)
{
    var path = Path.GetFullPath(Path.Combine(nativeDir, name));
    if (!Path.GetDirectoryName(path)!.Equals(nativeDir.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase))
        throw new InvalidDataException("DLL escaped the native directory");
    CheckFile(path, dlls.GetProperty(name));
}
ffmpeg.RootPath = nativeDir;
// Version calls force all six AutoGen entry points. The module inventory below
// then checks what Windows actually mapped, including dependencies.
var versions = new Dictionary<string, uint>
{
    ["avcodec"] = ffmpeg.avcodec_version(), ["avformat"] = ffmpeg.avformat_version(),
    ["avutil"] = ffmpeg.avutil_version(), ["avfilter"] = ffmpeg.avfilter_version(),
    ["swresample"] = ffmpeg.swresample_version(), ["swscale"] = ffmpeg.swscale_version()
};
foreach (var (library, version) in versions)
    if (version >> 16 != manifest.RootElement.GetProperty("libraryMajors").GetProperty(library).GetInt32())
        throw new InvalidDataException($"ABI major mismatch: {library} {version >> 16}");
var actualModules = Process.GetCurrentProcess().Modules.Cast<ProcessModule>()
    .Where(m => names.Contains(m.ModuleName, StringComparer.OrdinalIgnoreCase)).ToArray();
if (actualModules.Length != names.Length) throw new InvalidDataException($"Loaded {actualModules.Length} FFmpeg modules, expected six");
var moduleRows = new List<object>();
foreach (var name in names)
{
    var matches = actualModules.Where(m => m.ModuleName.Equals(name, StringComparison.OrdinalIgnoreCase)).ToArray();
    if (matches.Length != 1) throw new InvalidDataException($"Loaded module count for {name}: {matches.Length}");
    var path = Path.GetFullPath(matches[0].FileName);
    if (!path.Equals(Path.GetFullPath(Path.Combine(nativeDir, name)), StringComparison.OrdinalIgnoreCase))
        throw new InvalidDataException($"Loaded foreign DLL: {path}");
    CheckFile(path, dlls.GetProperty(name));
    moduleRows.Add(new { name, path, size = new FileInfo(path).Length, sha256 = Hash(path) });
}
if (!ffmpeg.avcodec_license().StartsWith("LGPL", StringComparison.Ordinal) ||
    ffmpeg.avcodec_configuration().Contains("--enable-gpl", StringComparison.Ordinal) ||
    ffmpeg.avcodec_configuration().Contains("--enable-nonfree", StringComparison.Ordinal))
    throw new InvalidDataException("Native FFmpeg licence/configuration gate failed");
unsafe { if (ffmpeg.avfilter_get_by_name("atempo") == null) throw new InvalidDataException("atempo is not registered"); }
ffmpeg.av_log_set_level(ffmpeg.AV_LOG_QUIET);
var rows = new List<CaseResult>();
foreach (var rate in new[] { 24000, 48000 })
foreach (var channels in new[] { 1, 2 })
foreach (var stretch in new[] { 0.92, 1.0, 1.08 })
foreach (var seconds in new[] { 0.18, 3.0 })
    rows.Add(RunCase(rate, channels, stretch, seconds, cancel: false));
foreach (var rate in new[] { 24000, 48000 })
    rows.Add(RunCase(rate, 2, 1.08, 3.0, cancel: true));
var evidence = new
{
    rid, processArchitecture = RuntimeInformation.ProcessArchitecture.ToString(),
    osArchitecture = RuntimeInformation.OSArchitecture.ToString(),
    emulated = RuntimeInformation.ProcessArchitecture != RuntimeInformation.OSArchitecture,
    reportSha256 = root.GetProperty("sha256").GetString(), versions,
    loadedModules = moduleRows, cases = rows,
    failures = rows.Where(r => !r.Passed).Select(r => r.Name).ToArray()
};
Console.WriteLine(JsonSerializer.Serialize(evidence, new JsonSerializerOptions { WriteIndented = true }));
if (rows.Any(r => !r.Passed)) Environment.ExitCode = 1;

static void CheckFile(string path, JsonElement expected)
{
    if (!File.Exists(path) || new FileInfo(path).Length != expected.GetProperty("size").GetInt64() ||
        !Hash(path).Equals(expected.GetProperty("sha256").GetString(), StringComparison.OrdinalIgnoreCase))
        throw new InvalidDataException($"Audited DLL size/hash mismatch: {path}");
}
static string Hash(string path) { using var stream = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant(); }

static unsafe CaseResult RunCase(int rate, int channels, double stretch, double seconds, bool cancel)
{
    const int maxChunk = 4096;
    var inputCount = checked((int)Math.Round(rate * seconds));
    var markerIn = new[] { (int)(rate * 0.035), inputCount - (int)(rate * 0.035) };
    var output = new List<float>(cancel ? 0 : (int)(inputCount * stretch * channels) + maxChunk);
    var maxInput = 0; var maxDrain = 0; var eagain = 0; var eofCount = 0; var feeds = 0;
    var emittedFrames = 0; long? firstPts = null; long? lastPts = null;
    var graph = ffmpeg.avfilter_graph_alloc();
    if (graph == null) throw new OutOfMemoryException();
    AVFrame* frame = null; AVFrame* drained = null;
    var name = $"{rate}Hz/{channels}ch/stretch={stretch.ToString("F2", CultureInfo.InvariantCulture)}/{seconds:F2}s{(cancel ? "/cancel" : "")}";
    try
    {
        graph->nb_threads = 1;
        AVFilterContext* source = null; AVFilterContext* tempo = null; AVFilterContext* sink = null;
        var layout = channels == 1 ? "mono" : "stereo";
        var sourceArgs = $"time_base=1/{rate}:sample_rate={rate}:sample_fmt=flt:channel_layout={layout}";
        Check(ffmpeg.avfilter_graph_create_filter(&source, ffmpeg.avfilter_get_by_name("abuffer"), "input", sourceArgs, null, graph), "create abuffer");
        var tempoValue = (1 / stretch).ToString("R", CultureInfo.InvariantCulture);
        Check(ffmpeg.avfilter_graph_create_filter(&tempo, ffmpeg.avfilter_get_by_name("atempo"), "tempo", "tempo=" + tempoValue, null, graph), "create atempo");
        Check(ffmpeg.avfilter_graph_create_filter(&sink, ffmpeg.avfilter_get_by_name("abuffersink"), "output", null, null, graph), "create abuffersink");
        Check(ffmpeg.avfilter_link(source, 0, tempo, 0), "link source");
        Check(ffmpeg.avfilter_link(tempo, 0, sink, 0), "link sink");
        Check(ffmpeg.avfilter_graph_config(graph, null), "configure graph");
        var sinkTimeBase = ffmpeg.av_buffersink_get_time_base(sink);
        var timeBase = $"{sinkTimeBase.num}/{sinkTimeBase.den}";
        frame = ffmpeg.av_frame_alloc(); drained = ffmpeg.av_frame_alloc();
        if (frame == null || drained == null) throw new OutOfMemoryException();
        for (var start = 0; start < inputCount; start += maxChunk)
        {
            var count = Math.Min(maxChunk, inputCount - start);
            maxInput = Math.Max(maxInput, count); feeds++;
            ffmpeg.av_frame_unref(frame);
            frame->format = (int)AVSampleFormat.AV_SAMPLE_FMT_FLT;
            frame->sample_rate = rate; frame->nb_samples = count; frame->pts = start;
            ffmpeg.av_channel_layout_default(&frame->ch_layout, channels);
            Check(ffmpeg.av_frame_get_buffer(frame, 0), "allocate feed frame");
            var samples = (float*)frame->data[0];
            for (var i = 0; i < count; i++)
            {
                var t = (start + i) / (double)rate;
                var value = 0.18 * Math.Sin(2 * Math.PI * 440 * t) + 0.06 * Math.Sin(2 * Math.PI * (220 * t + 90 * t * t));
                foreach (var marker in markerIn)
                    if (Math.Abs(start + i - marker) < 24) value += 0.70 * (1 - Math.Abs(start + i - marker) / 24.0);
                for (var ch = 0; ch < channels; ch++) samples[i * channels + ch] = (float)(value * (ch == 0 ? 1 : 0.8));
            }
            Check(ffmpeg.av_buffersrc_add_frame_flags(source, frame, (int)AvBuffersrcFlag.AV_BUFFERSRC_FLAG_KEEP_REF), "feed atempo");
            Drain(sink, drained, channels, inputCount, output, cancel, false, ref maxDrain, ref eagain,
                ref eofCount, ref emittedFrames, ref firstPts, ref lastPts);
            if (cancel && feeds == 3) break;
        }
        if (cancel)
            return new(name, inputCount, null, emittedFrames, firstPts, lastPts, timeBase,
                null, null, null, null, maxInput, maxDrain, eagain, eofCount, feeds, true,
                "cancelled midstream; graph disposed without EOF");
        Check(ffmpeg.av_buffersrc_add_frame_flags(source, null, 0), "send EOF once");
        Drain(sink, drained, channels, inputCount, output, false, true, ref maxDrain, ref eagain,
            ref eofCount, ref emittedFrames, ref firstPts, ref lastPts);
        if (eofCount != 1) throw new InvalidDataException("Sink did not reach EOF exactly once");
        var actual = output.Count / channels;
        if (actual != emittedFrames) throw new InvalidDataException("Retained/output frame count mismatch");
        var expected = inputCount * stretch;
        var markerOut = markerIn.Select(m => FindMarker(output, channels, m * stretch, rate)).ToArray();
        var frequency = DominantFrequency(output, channels, rate);
        // These are diagnostic gates, not sample-exact promises. Preserve the
        // measured row on failure; the consumer must define any compensation.
        var countAllowance = Math.Max(1024, expected * 0.02);
        var markerAllowance = Math.Max(1024, rate * 0.03);
        var passed = Math.Abs(actual - expected) <= countAllowance && eofCount == 1 &&
            markerOut[0] >= 0 && markerOut[1] >= 0 &&
            Math.Abs(markerOut[0] - markerIn[0] * stretch) <= markerAllowance &&
            Math.Abs(markerOut[1] - markerIn[1] * stretch) <= markerAllowance &&
            (seconds < 1 || Math.Abs(frequency - 440) <= 4.4);
        return new(name, inputCount, expected, actual, firstPts, lastPts, timeBase,
            markerOut[0], markerOut[1], frequency, (frequency - 440) / 440 * 100,
            maxInput, maxDrain, eagain, eofCount, feeds, passed,
            $"count allowance {countAllowance:F0} frames; marker allowance {markerAllowance:F0} frames; long pitch allowance 1%");
    }
    finally
    {
        ffmpeg.av_frame_free(&frame);
        ffmpeg.av_frame_free(&drained);
        ffmpeg.avfilter_graph_free(&graph);
    }
}

static unsafe void Drain(AVFilterContext* sink, AVFrame* drained, int channels, int inputCount,
    List<float> output, bool cancel, bool final, ref int maxDrain, ref int eagain, ref int eofCount,
    ref int emittedFrames, ref long? firstPts, ref long? lastPts)
{
    const int maxChunk = 4096;
    for (var guard = 0; guard < inputCount * 2 / maxChunk + 100; guard++)
    {
        ffmpeg.av_frame_unref(drained);
        var result = ffmpeg.av_buffersink_get_samples(sink, drained, maxChunk);
        if (result == ffmpeg.AVERROR(ffmpeg.EAGAIN)) { eagain++; if (final) throw new InvalidDataException("EAGAIN after EOF"); return; }
        if (result == ffmpeg.AVERROR_EOF) { eofCount++; return; }
        Check(result, "drain atempo");
        if (drained->nb_samples <= 0 || drained->nb_samples > maxChunk || drained->format != (int)AVSampleFormat.AV_SAMPLE_FMT_FLT || drained->ch_layout.nb_channels != channels)
            throw new InvalidDataException("Unbounded or malformed drain frame");
        maxDrain = Math.Max(maxDrain, drained->nb_samples);
        emittedFrames += drained->nb_samples;
        if (drained->pts != ffmpeg.AV_NOPTS_VALUE)
        {
            firstPts ??= drained->pts;
            lastPts = drained->pts;
        }
        var samples = (float*)drained->data[0];
        for (var i = 0; i < drained->nb_samples * channels; i++)
        {
            if (!float.IsFinite(samples[i])) throw new InvalidDataException("Nonfinite PCM");
            if (!cancel) output.Add(samples[i]);
        }
        if (output.Count > inputCount * channels * 2 + maxChunk * channels)
            throw new InvalidDataException("Output exceeded bounded diagnostic cap");
    }
    throw new InvalidDataException("Drain did not terminate");
}

static int FindMarker(List<float> audio, int channels, double expected, int rate)
{
    var frames = audio.Count / channels;
    var from = Math.Max(0, (int)(expected - rate * 0.08));
    var to = Math.Min(frames, (int)(expected + rate * 0.08));
    if (to <= from) return -1;
    var best = -1; var peak = 0.35f;
    for (var i = from; i < to; i++)
        if (audio[i * channels] > peak) { peak = audio[i * channels]; best = i; }
    return best;
}

static double DominantFrequency(List<float> audio, int channels, int rate)
{
    var frames = audio.Count / channels;
    var count = Math.Min(frames / 2, rate / 2);
    if (count < rate / 12) return double.NaN;
    var start = (frames - count) / 2;
    var bestHz = 0.0; var bestPower = double.NegativeInfinity;
    for (var hz = 400; hz <= 480; hz += 1)
    {
        var re = 0.0; var im = 0.0;
        for (var i = 0; i < count; i++)
        {
            var sample = audio[(start + i) * channels] * (0.5 - 0.5 * Math.Cos(2 * Math.PI * i / (count - 1)));
            var phase = 2 * Math.PI * hz * i / rate;
            re += sample * Math.Cos(phase); im += sample * Math.Sin(phase);
        }
        var power = re * re + im * im;
        if (power > bestPower) { bestPower = power; bestHz = hz; }
    }
    return bestHz;
}

static void Check(int result, string operation)
{
    if (result >= 0) return;
    throw new InvalidOperationException($"{operation} returned FFmpeg error {result}");
}

internal sealed record CaseResult(string Name, int InputFrames, double? ExpectedFrames, int ActualFrames,
    long? FirstOutputPts, long? LastOutputPts, string SinkTimeBase,
    int? PrefixMarkerFrame, int? TailMarkerFrame, double? DominantHz, double? PitchErrorPercent,
    int MaxFeedFrames, int MaxDrainFrames, int EagainCount, int EofCount, int Feeds, bool Passed, string Note);
