"""Compare Windows dialog exports, including the slip, fade and split timeline case."""
import argparse
from array import array
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

BASELINE = "05105bae02f9199d47728143794b1d285b92357b"
ROOT = Path(__file__).resolve().parents[6]
TRACK = Path(__file__).resolve().parent
RELATIVE = TRACK.relative_to(ROOT)
STREAM_FIELDS = (
    "index", "codec_name", "codec_type", "profile", "width", "height", "pix_fmt",
    "r_frame_rate", "avg_frame_rate", "time_base", "sample_fmt", "sample_rate",
    "channels", "channel_layout", "bits_per_raw_sample", "nb_frames", "duration_ts", "duration",
)


def run(command, *, cwd=ROOT, env=None, log=None):
    flags = subprocess.BELOW_NORMAL_PRIORITY_CLASS if os.name == "nt" else 0
    if os.name != "nt" and command[0] == "dotnet":
        command = ["nice", "-n", "10", *command]
    result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, creationflags=flags)
    if log is not None:
        log.write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed ({result.returncode}): {(result.stdout + result.stderr)[-6000:]}")
    return result.stdout


def baseline_routing():
    dialog = run(["git", "show", f"{BASELINE}:apps/windows/src/VoxClip.App/Controls/ExportDialog.cs"])
    factory = run(["git", "show", f"{BASELINE}:apps/windows/src/VoxClip.App/Services/ProjectFactory.cs"])
    routing = dialog[dialog.index('                    var aspectName ='):dialog.index('                    var result = await App.Services.Exporter.ExportAsync')]
    routing = '\n'.join(line for line in routing.splitlines() if 'var pattern = App.Services.Get' not in line)
    for old, new in (("aspect.SelectedIndex", "(int)aspect"), ("model.Title", "project"), ("clip?.Title", "clip"), ("folder.Text", "folder"), ("ProjectFactory.AvailablePath", "AvailablePath")):
        routing = routing.replace(old, new)
    selected = next(line.strip() for line in dialog.splitlines() if 'var selectedClips =' in line).replace('target.SelectedIndex == 1', '!full')
    jobs = next(line.strip() for line in dialog.splitlines() if 'var jobs = selectedClips.Length' in line)
    available = factory[factory.index('    internal static string AvailablePath'):factory.rindex('}')]
    return f'''using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
namespace VoxClip.Ui.Tests;
internal static class BaselineExportRouting
{{
    internal static IReadOnlyList<ExportTarget> Targets(EditorViewModel model, string? onlyClip, bool full)
    {{
        {selected}
        {jobs}
        return jobs.Select(clip => clip is null ? (ExportTarget)new ExportTarget.FullEdit() : new ExportTarget.Clip(clip.Id)).ToArray();
    }}
    internal static (string Mp4, string? Srt) Paths(string project, string? clip, ExportAspect aspect, bool srt, string folder, string pattern)
    {{
{routing}
        return (output, srt ? Path.ChangeExtension(output, ".srt") : null);
    }}
{available}
}}
'''


def prepare():
    scratch = TRACK / ".artifacts" / "obj" / "export-equivalence"
    if scratch.exists():
        raise RuntimeError(f"Use a fresh export-equivalence scratch directory: {scratch}")
    scratch.mkdir(parents=True)
    archive = scratch / "before.tar"
    run(["git", "archive", "--format=tar", "-o", str(archive), BASELINE, "apps/windows", "shared"])
    before = scratch / "before"
    with tarfile.open(archive) as source:
        source.extractall(before, filter="data")
    before_track = before / RELATIVE
    shutil.copyfile(TRACK / "ExportEquivalenceTests.cs", before_track / "ExportEquivalenceTests.cs")
    (before_track / "BaselineExportRouting.cs").write_text(baseline_routing(), encoding="utf-8")
    project = before_track / "VoxClip.Ui.Tests.csproj"
    text = project.read_text(encoding="utf-8").replace('<Compile Include="RoundThreeTests.cs" />', '<Compile Include="RoundThreeTests.cs" /><Compile Include="ExportEquivalenceTests.cs" /><Compile Include="BaselineExportRouting.cs" />')
    text = text.replace(';WIN_UI_TESTS</DefineConstants>', ';WIN_UI_TESTS;EXPORT_BASELINE</DefineConstants>')
    project.write_text(text, encoding="utf-8")
    return before


def probe(executable, video):
    data = json.loads(run([str(executable), "-v", "error", "-show_streams", "-show_format", "-of", "json", str(video)]))
    return {"streams": [{key: stream.get(key) for key in STREAM_FIELDS} for stream in data["streams"]], "duration": data["format"]["duration"]}


def compare(before, after, ffprobe):
    first = json.loads((before / "manifest.json").read_text(encoding="utf-8"))
    second = json.loads((after / "manifest.json").read_text(encoding="utf-8"))
    assert len(first) == len(second) == 16
    assert first == second, "Export names, target folders, order, scope or renderer result fields differ"
    comparisons = []
    for row in first:
        prior_srt = (before / row["srt"]).read_bytes()
        assert prior_srt == (after / row["srt"]).read_bytes(), f"SRT bytes differ: {row['srt']}"
        prior = probe(ffprobe, before / row["video"])
        current = probe(ffprobe, after / row["video"])
        assert prior == current, f"MP4 stream parameters or durations differ: {row['video']}"
        comparisons.append({"video": row["video"], "srtSha256": hashlib.sha256(prior_srt).hexdigest(), "srtBytes": len(prior_srt),
                            "streams": current, "mp4BytesEqual": (before / row["video"]).read_bytes() == (after / row["video"]).read_bytes()})
    return {"baseline": BASELINE, "current": run(["git", "rev-parse", "HEAD"]).strip(), "result": "passed", "exports": comparisons,
            "comparedStreamFields": STREAM_FIELDS, "comparedFormatFields": ["duration"],
            "notes": "Real Core/Media builds from each revision; baseline dialog target/name code extracted mechanically, current dialog and harness both use production ExportDialogRouting for control indexes, scope, aspect, destination, quality and snapshot. Shared interview project, original timings/cuts/correction/style, synthetic matching 7-second source, two kept clips plus an excluded suggestion. All four aspects, full/all/this scopes and name collisions. MP4 container/encoder metadata bytes are informational, not an equality gate."}


def render_source(ffmpeg, destination, size):
    source = destination / "source.mp4"
    run([str(ffmpeg), "-v", "error", "-f", "lavfi", "-i", f"testsrc2=s={size}:r=30", "-f", "lavfi", "-i",
         "sine=frequency=440:sample_rate=48000", "-t", "7", "-c:v", "mpeg4", "-q:v", "8", "-c:a", "aac", "-ac", "1", "-y", str(source)],
        log=destination / "source.log")
    return source


def run_exports(root, tools, evidence, env, prefix=""):
    if shutil.disk_usage(root).free < 15 * 1024 ** 3:
        raise RuntimeError("Builds require at least 15 GiB free")
    project = root / RELATIVE / "VoxClip.Ui.Tests.csproj"
    run(["dotnet", "build", str(project), "-c", "Release", "-m:1", "-nodeReuse:false", "-p:UseSharedCompilation=false"],
        cwd=root / "apps/windows", env=env, log=evidence / f"{prefix}build.log")
    output = project.parent / ".artifacts/bin/Release/net10.0"
    pin = json.loads((ROOT / "apps/windows/build/ffmpeg.json").read_text(encoding="utf-8"))
    for library, major in pin["libraryMajors"].items():
        shutil.copyfile(tools / f"{library}-{major}.dll", output / f"{library}-{major}.dll")
    run(["dotnet", str(output / "VoxClip.Ui.Tests.dll"), "-class", "VoxClip.Ui.Tests.ExportEquivalenceTests", "-noLogo"],
        cwd=root / "apps/windows", env=env, log=evidence / f"{prefix}export.log")


def samples(ffmpeg, path):
    decoded = subprocess.run([str(ffmpeg), "-v", "error", "-i", str(path), "-map", "0:a:0", "-ac", "1", "-ar", "48000",
                              "-f", "f32le", "-"], check=True, stdout=subprocess.PIPE)
    result = array("f")
    result.frombytes(decoded.stdout)
    return result


def tone(samples, start, end, hz):
    window = samples[round(start * 48000):round(end * 48000)]
    step = 2 * math.pi * hz / 48000
    weights = [0.5 - 0.5 * math.cos(2 * math.pi * idx / len(window)) for idx in range(len(window))]
    real = sum(value * weight * math.cos(idx * step) for idx, (value, weight) in enumerate(zip(window, weights)))
    imaginary = sum(value * weight * math.sin(idx * step) for idx, (value, weight) in enumerate(zip(window, weights)))
    return 2 * math.hypot(real, imaginary) / sum(weights)


def verify_timeline(tools, evidence):
    ffmpeg = tools / "ffmpeg.exe"
    source = render_source(ffmpeg, evidence, "640x360")
    run([str(ffmpeg), "-v", "error", "-f", "lavfi", "-i",
         "aevalsrc='if(lt(t,0.5),0.4*sin(2*PI*173*t),0.4*sin(2*PI*317*t))':s=48000:d=4", "-c:a", "flac",
         "-y", str(evidence / "music-timeline.flac")], log=evidence / "music.log")
    env = dict(os.environ, VOXCLIP_SHARED_DIR=str(ROOT / "shared"), VOXCLIP_LIVE_TESTS="0", VOXCLIP_TEST_DOWNLOAD="0",
               VOXCLIP_DATA_DIR=str(evidence / "data"), VOXCLIP_EXPORT_EQ_ROOT="", VOXCLIP_EXPORT_EQ_TIMELINE=str(evidence),
               VOXCLIP_EXPORT_EQ_SOURCE=str(source))
    run_exports(ROOT, tools, evidence, env)
    unsplit, split = (samples(ffmpeg, evidence / f"{name}.mp4") for name in ("unsplit", "split"))
    assert len(unsplit) == len(split) and len(split) >= 6 * 48000, "Splitting changed the export length"
    delta = max(abs(first - second) for first, second in zip(unsplit, split, strict=True))
    assert delta < 1e-4, f"Splitting changed the encoded music: peak error {delta:.6g}"
    held = tone(split, 1.25, 1.45, 317)
    assert held > .005, "The slipped portion of the song did not play"
    levels = {"before": tone(split, .12, .35, 317) / held, "fadeIn": tone(split, .53, .67, 317) / held,
              "fadeOut": tone(split, 2.33, 2.47, 317) / held, "after": tone(split, 2.7, 3.05, 317) / held,
              "unslippedTone": tone(split, .65, .85, 173) / held}
    assert max(levels["before"], levels["after"], levels["unslippedTone"]) < .05, f"Music leaked outside the placement or slipped window: {levels}"
    assert all(.12 < levels[edge] < .42 for edge in ("fadeIn", "fadeOut")), f"The music did not ramp at both ends: {levels}"
    (evidence / "comparison.json").write_text(json.dumps({"result": "passed", "frames": len(split), "peakSplitDelta": delta,
                                                         "toneRatios": levels}, indent=2) + '\n', encoding="utf-8")
    print("PASS: slipped music, two fades and sample-equivalent split export")


def verify_recordings(tools, evidence):
    env = dict(os.environ, VOXCLIP_SHARED_DIR=str(ROOT / "shared"), VOXCLIP_LIVE_TESTS="0", VOXCLIP_TEST_DOWNLOAD="0",
               VOXCLIP_DATA_DIR=str(evidence / "data"), VOXCLIP_EXPORT_EQ_ROOT="", VOXCLIP_EXPORT_EQ_TIMELINE="",
               VOXCLIP_EXPORT_EQ_RECORDINGS=str(evidence))
    run_exports(ROOT, tools, evidence, env)
    manifest = json.loads((evidence / "recordings.json").read_text(encoding="utf-8"))
    differences = []
    for sample in manifest["samples"]:
        expected = (evidence / sample["file"]).read_bytes()
        frame = sample["frame"]
        actual = subprocess.run([str(tools / "ffmpeg.exe"), "-v", "error", "-i", manifest["Output"],
                                 "-vf", f"select=eq(n\\,{frame})", "-frames:v", "1", "-pix_fmt", "bgra", "-f", "rawvideo", "-"],
                                check=True, stdout=subprocess.PIPE).stdout
        assert len(actual) == len(expected) == sample["Width"] * sample["Height"] * 4, f"Invalid frame {frame}"
        mean_error = sum(abs(before - after) for before, after in zip(expected, actual, strict=True)) / len(expected)
        assert mean_error < 8, f"Preview/export mismatch at frame {frame}: {mean_error:.3f}"
        differences.append({"frame": frame, "meanByteError": mean_error})
    assert len(differences) == 5
    (evidence / "comparison.json").write_text(json.dumps(differences, indent=2) + '\n', encoding="utf-8")
    print("PASS: preview equals export picture at five story parts across recordings")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--timeline-only", action="store_true")
    parser.add_argument("--recordings-only", action="store_true")
    parser.add_argument("--tools", type=Path)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.timeline_only or args.recordings_only:
        if os.name != "nt" or args.tools is None or args.evidence is None or args.prepare_only:
            parser.error("--timeline-only and --recordings-only require Windows, --tools and --evidence (without --prepare-only)")
        if args.timeline_only and args.recordings_only:
            parser.error("Choose either --timeline-only or --recordings-only")
        evidence = args.evidence.resolve()
        evidence.mkdir(parents=True, exist_ok=True)
        (verify_timeline if args.timeline_only else verify_recordings)(args.tools.resolve(), evidence)
        return
    if run(["git", "cat-file", "-t", BASELINE]).strip() != "commit":
        raise RuntimeError("The exact baseline commit is required")
    before = prepare()
    if args.prepare_only:
        print(f"Prepared baseline {BASELINE} in {before}")
        return
    if os.name != "nt" or args.tools is None or args.evidence is None:
        raise RuntimeError("Windows, --tools and --evidence are required")
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    source = render_source(args.tools / "ffmpeg.exe", evidence, "1920x1080")
    for name, root in (("before", before), ("after", ROOT)):
        env = dict(os.environ, VOXCLIP_SHARED_DIR=str(root / "shared"), VOXCLIP_LIVE_TESTS="0", VOXCLIP_TEST_DOWNLOAD="0",
                   VOXCLIP_DATA_DIR=str(evidence / name / "data"), VOXCLIP_EXPORT_EQ_ROOT=str(evidence / name),
                   VOXCLIP_EXPORT_EQ_TIMELINE="", VOXCLIP_EXPORT_EQ_SOURCE=str(source))
        run_exports(root, args.tools, evidence, env, prefix=f"{name}-")
    report = compare(evidence / "before", evidence / "after", args.tools / "ffprobe.exe")
    (evidence / "comparison.json").write_text(json.dumps(report, indent=2) + '\n', encoding="utf-8")
    print(f"PASS: {len(report['exports'])} before/after exports, names/folders/order, SRT bytes and MP4 stream parameters/durations")


if __name__ == "__main__":
    main()
