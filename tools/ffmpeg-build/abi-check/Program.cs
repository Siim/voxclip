using System.Text.Json;
using FFmpeg.AutoGen;

var majors = new Dictionary<string, int>
{
    ["avcodec"] = ffmpeg.LIBAVCODEC_VERSION_MAJOR,
    ["avformat"] = ffmpeg.LIBAVFORMAT_VERSION_MAJOR,
    ["avutil"] = ffmpeg.LIBAVUTIL_VERSION_MAJOR,
    ["avfilter"] = ffmpeg.LIBAVFILTER_VERSION_MAJOR,
    ["swresample"] = ffmpeg.LIBSWRESAMPLE_VERSION_MAJOR,
    ["swscale"] = ffmpeg.LIBSWSCALE_VERSION_MAJOR
};

Console.WriteLine(JsonSerializer.Serialize(majors));
if (args.Length > 0)
{
    using var manifest = JsonDocument.Parse(File.ReadAllText(args[0]));
    foreach (var library in manifest.RootElement.GetProperty("libraryMajors").EnumerateObject())
    {
        if (!majors.TryGetValue(library.Name, out var major) || major != library.Value.GetInt32())
            throw new InvalidOperationException("FFmpeg.AutoGen ABI mismatch: " + library.Name);
    }
    Console.WriteLine("FFmpeg.AutoGen ABI majors match the manifest; no Windows code was executed.");
}
