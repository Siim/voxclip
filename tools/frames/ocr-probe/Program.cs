// Usage: voxclip-ocr-probe <shared dir> <folder of rendered PNG frames> [runs, default 20]. Prints the OCR languages, then per frame the
// line boxes, quads, screens (with and without quads, and through ScanAsync) and the OCR and QuadFinder times. No text is printed.
using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using VoxClip.App.Services;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

var shared = args[0];
var pngDir = args[1];
var runs = args.Length > 2 ? int.Parse(args[2]) : 20;
Console.WriteLine($"arch={System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture} os={Environment.OSVersion.VersionString}");
Console.WriteLine("available OCR languages: " + string.Join(", ", OcrEngine.AvailableRecognizerLanguages.Select(l => l.LanguageTag)));
var profile = OcrEngine.TryCreateFromUserProfileLanguages();
Console.WriteLine("user-profile engine: " + (profile is null ? "null" : profile.RecognizerLanguage.LanguageTag) + $", max dimension {OcrEngine.MaxImageDimension}");

var frames = new List<(string Name, PixelBuffer Frame)>();
var vectors = JsonNode.Parse(File.ReadAllText(Path.Combine(shared, "fixtures", "clip-frames", "frame-quad-cases.json")))!;
foreach (var node in vectors["frames"]!.AsArray())
{
    var id = node!["id"]!.GetValue<string>();
    if (!id.StartsWith("phone", StringComparison.Ordinal) && id != "laptop") continue;
    int w = node["width"]!.GetValue<int>(), h = node["height"]!.GetValue<int>();
    var grey = new byte[w * h];
    var at = 0;
    foreach (var token in node["runs"]!.GetValue<string>().Split(' '))
    {
        var star = token.IndexOf('*');
        var count = int.Parse(token.AsSpan(star + 1));
        grey.AsSpan(at, count).Fill(byte.Parse(token.AsSpan(0, star)));
        at += count;
    }
    if (Convert.ToHexStringLower(SHA256.HashData(grey)) != node["sha256"]!.GetValue<string>()) throw new InvalidDataException(id);
    var bgra = new byte[w * h * 4];
    for (var i = 0; i < grey.Length; i++) { bgra[i * 4] = bgra[i * 4 + 1] = bgra[i * 4 + 2] = grey[i]; bgra[i * 4 + 3] = 255; }
    frames.Add(("vector:" + id, new PixelBuffer(bgra, w, h, w * 4)));
}
foreach (var png in Directory.GetFiles(pngDir, "*.png").OrderBy(p => p, StringComparer.Ordinal))
{
    var bytes = await File.ReadAllBytesAsync(png);
    using var stream = new InMemoryRandomAccessStream();
    await stream.WriteAsync(bytes.AsBuffer());
    stream.Seek(0);
    var decoder = await BitmapDecoder.CreateAsync(stream);
    using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
    var buffer = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4];
    bitmap.CopyToBuffer(buffer.AsBuffer());
    frames.Add(("rendered:" + Path.GetFileNameWithoutExtension(png), new PixelBuffer(buffer, bitmap.PixelWidth, bitmap.PixelHeight, bitmap.PixelWidth * 4)));
}

using var text = new WindowsFrameText();
static string R(ClipEffectRect r) => $"({r.X:F3},{r.Y:F3} {r.Width:F3}x{r.Height:F3})";
foreach (var (name, frame) in frames)
{
    var finder = new QuadFinder();
    var lines = await text.LinesAsync(frame, CancellationToken.None);
    var quads = finder.Find(frame);
    var framed = FrameScreenScan.Detect(lines, quads);
    var unframed = FrameScreenScan.Detect(lines, []);
    var scanned = await new FrameScreenScan(text, new QuadFinder()).ScanAsync(frame, false, CancellationToken.None);
    for (var i = 0; i < 3; i++) await text.LinesAsync(frame, CancellationToken.None);
    var ocr = new List<double>();
    var quad = new List<double>();
    for (var i = 0; i < runs; i++)
    {
        var sw = Stopwatch.StartNew();
        await text.LinesAsync(frame, CancellationToken.None);
        ocr.Add(sw.Elapsed.TotalMilliseconds);
        sw.Restart();
        finder.Find(frame);
        quad.Add(sw.Elapsed.TotalMilliseconds);
    }
    ocr.Sort(); quad.Sort();
    Console.WriteLine($"== {name} {frame.Width}x{frame.Height}");
    Console.WriteLine($"  lines {lines.Count}: " + string.Join(" ", lines.Select(R)));
    Console.WriteLine($"  quads {quads.Count}: " + string.Join(" ", quads.Select(q => R(q.BoundingBox) + $" c={q.Confidence:F3}")));
    Console.WriteLine($"  screens with quads {framed.Screens.Count}: " + string.Join(" ", framed.Screens.Select(s => $"{R(s.Rect)} boxes={s.TextBoxes} cov={s.TextCoverage:F3} framed={s.Framed}")));
    Console.WriteLine($"  screens without quads {unframed.Screens.Count}");
    Console.WriteLine($"  ScanAsync screens {scanned.Screens.Count}, text rects {scanned.TextRects.Count}");
    Console.WriteLine($"  OCR ms median {ocr[runs / 2]:F1} min {ocr[0]:F1} max {ocr[^1]:F1}; QuadFinder ms median {quad[runs / 2]:F1} (n={runs})");
}
