"""Run the real pre-round-3 and current Windows export pipelines, then compare."""
import argparse
import hashlib
import json
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--tools", type=Path)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
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
    source = evidence / "source.mp4"
    run([str(args.tools / "ffmpeg.exe"), "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "7", "-c:v", "mpeg4", "-q:v", "8", "-c:a", "aac", "-ac", "1", "-y", str(source)], log=evidence / "source.log")
    for name, root in (("before", before), ("after", ROOT)):
        if shutil.disk_usage(root).free < 15 * 1024 ** 3:
            raise RuntimeError("Builds require at least 15 GiB free")
        env = dict(os.environ, VOXCLIP_SHARED_DIR=str(root / "shared"), VOXCLIP_LIVE_TESTS="0", VOXCLIP_TEST_DOWNLOAD="0",
                   VOXCLIP_DATA_DIR=str(evidence / name / "data"), VOXCLIP_EXPORT_EQ_ROOT=str(evidence / name), VOXCLIP_EXPORT_EQ_SOURCE=str(source))
        project = root / RELATIVE / "VoxClip.Ui.Tests.csproj"
        run(["dotnet", "build", str(project), "-c", "Release", "-m:1", "-nodeReuse:false", "-p:UseSharedCompilation=false"], cwd=root / "apps/windows", env=env, log=evidence / f"{name}-build.log")
        output = project.parent / ".artifacts/bin/Release/net10.0"
        pin = json.loads((ROOT / "apps/windows/build/ffmpeg.json").read_text(encoding="utf-8"))
        for library, major in pin["libraryMajors"].items():
            shutil.copyfile(args.tools / f"{library}-{major}.dll", output / f"{library}-{major}.dll")
        run(["dotnet", str(output / "VoxClip.Ui.Tests.dll"), "-class", "VoxClip.Ui.Tests.ExportEquivalenceTests", "-noLogo"], cwd=root / "apps/windows", env=env, log=evidence / f"{name}-export.log")
    report = compare(evidence / "before", evidence / "after", args.tools / "ffprobe.exe")
    (evidence / "comparison.json").write_text(json.dumps(report, indent=2) + '\n', encoding="utf-8")
    print(f"PASS: {len(report['exports'])} before/after exports, names/folders/order, SRT bytes and MP4 stream parameters/durations")


if __name__ == "__main__":
    main()
