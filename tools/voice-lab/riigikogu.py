"""Riigikogu adapter for the Estonian et-v1 speaker calibration (doc/spec/voice-lab.md section 6.6).

Selection reads transcripts only, before any audio is decoded or scored. `transcripts` and `excerpt` are the
only network steps: they read the pinned Hugging Face revision over HTTPS and verify every file. `excerpt`
streams each pool FLAC once, checks its LFS SHA-256 and FLAC STREAMINFO MD5, and keeps only the six-second
excerpts. Names stay in the local selection file; the excerpt manifest and committed evidence use rkNNN keys.
"""
import argparse
import collections
import concurrent.futures
import decimal
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import threading
import unicodedata
import urllib.request
import wave
import xml.etree.ElementTree as ET

DATASET = "TalTechNLP/riigikogu-audio-stenograms-2018-2025"
REVISION = "52e34438a43b26b785ad2f76806633bf9942b2fb"
LICENCE = "CC BY-SA 3.0"
POLICY = "riigikogu-et-v1"
ATTRIBUTION = ("Derived from Riigikogu plenary recordings and stenograms (© Riigikogu, CC BY-SA) via "
               f"{DATASET} (CC BY-SA 3.0), revision {REVISION}. No audio or text redistributed.")
# Capitalised role words that can precede a name inside its capitalised run. Any word ending in a suffix below
# is a role too (Peaminister, Rahandusminister, Peaministrikandidaat, Riigikontrolörikandidaat).
ROLE_WORDS = frozenset(["aseesimees", "esimees", "akadeemik", "doktor", "ajaloodoktor", "filosoofiadoktor", "professor",
                        "emeriitprofessor", "vanemteadur", "energeetik", "ettevõtja", "jurist", "kindralleitnant",
                        "majandusanalüütik", "majandusekspert", "maksuekspert", "perearst", "psühhiaater",
                        "riigikontrolör", "õiguskantsler", "vandeadvokaat"])
ROLE_SUFFIXES = ("minister", "kandidaat")
TURN_MS = 10_000
OFFSET_MS = 2_000
EXCERPT_MS = 6_000
RATE = 16_000
EXCERPT_SAMPLES = EXCERPT_MS * RATE // 1000
POOL_SESSIONS = 30
SESSIONS = 3
CANDIDATES = 4
GROUPS = ["rk-cal-a", "rk-val-a", "rk-cal-b", "rk-val-b"]
ROLES = {"rk-cal-a": "calibration", "rk-val-a": "speaker-disjoint validation",
         "rk-cal-b": "calibration", "rk-val-b": "speaker-disjoint validation"}
TARGET_SPEAKERS = 40
MINIMUM_SPEAKERS = 17
SESSION_ID = re.compile(r"^[0-9]{12}$")


def normalise_name(raw):
    """Strip the role prefix from a stenogram speaker label; None for labels that are not one named person."""
    tokens = unicodedata.normalize("NFC", raw or "").split()
    start = len(tokens)
    while start and tokens[start - 1][:1].isupper():
        start -= 1
    name = tokens[start:]
    while name and (name[0].casefold() in ROLE_WORDS or name[0].casefold().endswith(ROLE_SUFFIXES)):
        name = name[1:]
    if len(name) < 2 or name[0].casefold() == "unknown":
        return None
    return " ".join(name)


def edit_distance(first, second):
    row = list(range(len(second) + 1))
    for index, left in enumerate(first, 1):
        previous, row[0] = row[0], index
        for column, right in enumerate(second, 1):
            previous, row[column] = row[column], min(row[column] + 1, row[column - 1] + 1, previous + (left != right))
    return row[-1]


def same_person(first, second):
    """Identical given names and a surname that differs by one edit or adds/drops a hyphenated part."""
    left, right = first.casefold().split(), second.casefold().split()
    if left == right:
        return True
    if left[:-1] != right[:-1]:
        return False
    return left[-1] in right[-1].split("-") or right[-1] in left[-1].split("-") or edit_distance(left[-1], right[-1]) <= 1


def canonical_names(sessions):
    """Map every normalised name to one spelling per person: the variant in the most sessions, then code-point order."""
    counts = collections.Counter(name for names in sessions.values() for name in set(names))
    parent = {name: name for name in counts}

    def root(name):
        while parent[name] != name:
            parent[name] = parent[parent[name]]
            name = parent[name]
        return name
    ordered = sorted(counts)
    for index, first in enumerate(ordered):
        for second in ordered[index + 1:]:
            if same_person(first, second):
                parent[root(second)] = root(first)
    members = collections.defaultdict(list)
    for name in ordered:
        members[root(name)].append(name)
    canonical = {}
    for names in members.values():
        chosen = min(names, key=lambda name: (-counts[name], name))
        canonical.update({name: chosen for name in names})
    return canonical


def milliseconds(text):
    value = decimal.Decimal(text) * 1000
    if value != value.to_integral_value():
        raise ValueError("Turn times must have millisecond resolution")
    return int(value)


def parse_trs(data):
    """Single-speaker turns as (raw speaker label, start ms, end ms)."""
    root = ET.fromstring(data)
    labels = {speaker.get("id"): speaker.get("name") or "" for speaker in root.iter("Speaker")}
    turns = []
    for turn in root.iter("Turn"):
        speakers = (turn.get("speaker") or "").split()
        if len(speakers) == 1:
            turns.append((labels[speakers[0]], milliseconds(turn.get("startTime")), milliseconds(turn.get("endTime"))))
    return turns


def qualifying_turns(sessions):
    """sessions: {session: [(label, start, end)]} -> {session: {canonical name: [qualifying turn starts]}}."""
    names = {session: [name for name in (normalise_name(label) for label, _, _ in turns) if name] for session, turns in sessions.items()}
    canonical = canonical_names(names)
    result = {}
    for session, turns in sessions.items():
        if not SESSION_ID.match(session):
            raise ValueError("Unexpected session ID: " + session)
        speakers = collections.defaultdict(list)
        for label, start, end in turns:
            name = normalise_name(label)
            if name and end - start >= TURN_MS:
                speakers[canonical[name]].append(start)
        result[session] = {name: sorted(starts) for name, starts in speakers.items()}
    return result


def choose_pool(qualifying):
    """Greedy and transcript-only: add the session that most increases sum(min(pool sessions, 3)) over speakers.
    At most one session per calendar date; ties go to the earlier session ID; stop at 30 sessions or no gain."""
    pool, coverage, dates = [], collections.Counter(), set()
    while len(pool) < POOL_SESSIONS:
        best = None
        for session in sorted(qualifying):
            if session in pool or session[:8] in dates:
                continue
            gain = sum(coverage[name] < SESSIONS for name in qualifying[session])
            if gain and (best is None or gain > best[0]):
                best = (gain, session)
        if best is None:
            break
        pool.append(best[1])
        dates.add(best[1][:8])
        coverage.update(qualifying[best[1]].keys())
    return sorted(pool)


def speaker_hash(name):
    return hashlib.sha256(name.encode("utf-8")).hexdigest()


def seconds(value):
    return f"{value // 1000}.{value % 1000:03d}"


def select(qualifying):
    """Pool, then speakers with qualifying turns in at least three pool sessions, numbered rk001... in SHA-256 order
    of the canonical name and dealt in turn to rk-cal-a, rk-val-a, rk-cal-b, rk-val-b. Candidates are the first
    qualifying turn in each of the speaker's first four pool sessions by date."""
    pool = choose_pool(qualifying)
    visits = collections.defaultdict(list)
    for session in pool:
        for name, starts in qualifying[session].items():
            visits[name].append((session, starts[0]))
    names = sorted((name for name, sessions in visits.items() if len(sessions) >= SESSIONS), key=lambda name: (speaker_hash(name), name))
    speakers = []
    for index, name in enumerate(names):
        candidates = []
        for session, turn in visits[name][:CANDIDATES]:
            start, end = turn + OFFSET_MS, turn + OFFSET_MS + EXCERPT_MS
            candidates.append({"id": f"{session}-{start}", "source": f"{session}@{seconds(start)}-{seconds(end)}", "session": session, "startMs": start, "endMs": end})
        speakers.append({"key": f"rk{index + 1:03d}", "name": name, "group": GROUPS[index % len(GROUPS)], "candidates": candidates})
    identities = [candidate["id"] for speaker in speakers for candidate in speaker["candidates"]]
    if len(set(identities)) != len(identities):
        raise ValueError("Candidate excerpts must be distinct")
    return {"policy": POLICY, "dataset": DATASET, "revision": REVISION, "pool": pool, "speakers": speakers}


def assemble(speakers, passed, groups=GROUPS):
    """First TARGET_SPEAKERS speakers per group, in key order, whose first three passing candidates exist.
    passed(candidate ID) is True when both rate renders have at least three seconds of Silero speech."""
    chosen = {group: [] for group in groups}
    rejected = []
    for speaker in speakers:
        group = speaker["group"]
        if group not in chosen or len(chosen[group]) == TARGET_SPEAKERS:
            continue
        kept = []
        for candidate in speaker["candidates"]:
            if len(kept) == SESSIONS:
                break
            if passed(candidate["id"]):
                kept.append(candidate)
            else:
                rejected.append({"speaker": speaker["key"], "source": candidate["source"], "reason": "under 3 s of Silero speech at 48000 or 44100 Hz"})
        if len(kept) == SESSIONS:
            chosen[group].append({"key": speaker["key"], "candidates": kept})
        else:
            rejected.append({"speaker": speaker["key"], "source": None, "reason": "fewer than three passing candidates; speaker skipped"})
    return chosen, rejected


def minimum_pairs(speakers):
    """Impostor and same-speaker pairs in one condition x rate cell with three utterances per speaker."""
    return 9 * speakers * (speakers - 1) // 2, 3 * speakers


def git_blob(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def tree(path):
    url = f"https://huggingface.co/api/datasets/{DATASET}/tree/{REVISION}/{path}?recursive=true&expand=true"
    items = []
    while url:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "voxclip-voice-lab/1"}), timeout=60) as response:
            items += json.load(response)
            link = re.search(r'<([^>]+)>;\s*rel="next"', response.headers.get("Link") or "")
            url = link.group(1) if link else None
    return {item["path"]: item for item in items if item.get("type") == "file"}


def resolve(path):
    return f"https://huggingface.co/datasets/{DATASET}/resolve/{REVISION}/{path}"


def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "voxclip-voice-lab/1"}), timeout=120) as response:
        return response.read()


def transcripts(args):
    files = {path: item for path, item in tree("trs").items() if path.endswith(".trs")}
    args.output.mkdir(parents=True, exist_ok=True)

    def download(path):
        data = fetch(resolve(path))
        if len(data) != files[path]["size"] or git_blob(data) != files[path]["oid"]:
            raise ValueError("Transcript does not match the pinned revision: " + path)
        (args.output / pathlib.PurePosixPath(path).name).write_bytes(data)
        return {"path": path, "bytes": len(data), "gitBlobSha1": files[path]["oid"], "sha256": hashlib.sha256(data).hexdigest()}
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        records = sorted(pool.map(download, sorted(files)), key=lambda record: record["path"])
    (args.output / "transcripts.json").write_text(json.dumps({"dataset": DATASET, "revision": REVISION, "files": records}, indent=1) + "\n")
    print(f"Verified {len(records)} transcripts at {REVISION}.")
    return 0


def load_transcripts(directory):
    manifest = json.loads((directory / "transcripts.json").read_text())
    if manifest["revision"] != REVISION:
        raise ValueError("Transcripts are from another revision")
    sessions = {}
    for record in manifest["files"]:
        data = (directory / pathlib.PurePosixPath(record["path"]).name).read_bytes()
        if hashlib.sha256(data).hexdigest() != record["sha256"] or git_blob(data) != record["gitBlobSha1"]:
            raise ValueError("Transcript changed: " + record["path"])
        sessions[pathlib.PurePosixPath(record["path"]).stem] = parse_trs(data)
    return sessions, manifest


def select_command(args):
    sessions, manifest = load_transcripts(args.transcripts)
    selection = select(qualifying_turns(sessions))
    selection["transcripts"] = manifest["files"]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(selection, indent=1, ensure_ascii=False) + "\n")
    groups = collections.Counter(speaker["group"] for speaker in selection["speakers"])
    print(json.dumps({"pool": selection["pool"], "qualifyingSpeakers": len(selection["speakers"]), "groups": dict(sorted(groups.items())),
                      "candidates": sum(len(speaker["candidates"]) for speaker in selection["speakers"])}))
    return 0


def streaminfo(head):
    if len(head) < 42 or head[:4] != b"fLaC" or head[4] & 0x7F != 0:
        raise ValueError("FLAC stream must start with STREAMINFO")
    block = head[8:42]
    rate = block[10] << 12 | block[11] << 4 | block[12] >> 4
    channels = ((block[12] >> 1) & 7) + 1
    bits = ((block[12] & 1) << 4 | block[13] >> 4) + 1
    samples = (block[13] & 0xF) << 32 | int.from_bytes(block[14:18], "big")
    return rate, channels, bits, samples, block[18:34].hex()


def collect(blocks, windows):
    """Copy PCM16 excerpt windows {id: start sample} out of a byte stream; returns parts, byte length and MD5."""
    spans = {identity: (start * 2, (start + EXCERPT_SAMPLES) * 2) for identity, start in windows.items()}
    parts = {identity: bytearray() for identity in windows}
    pcm = hashlib.md5(usedforsecurity=False)
    offset = 0
    for block in blocks:
        pcm.update(block)
        end = offset + len(block)
        for identity, (low, high) in spans.items():
            if low < end and high > offset:
                parts[identity] += block[max(low, offset) - offset:min(high, end) - offset]
        offset = end
    return parts, offset, pcm.hexdigest()


def stream_session(url, size, sha256, windows, ffmpeg):
    """Stream one FLAC once: hash every byte, decode to PCM16 with FFmpeg and keep only the excerpt windows."""
    decoder = subprocess.Popen([ffmpeg, "-nostdin", "-v", "error", "-f", "flac", "-i", "pipe:0", "-map", "0:a:0", "-f", "s16le", "-c:a", "pcm_s16le", "pipe:1"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    state = {"hash": hashlib.sha256(), "bytes": 0, "head": bytearray(), "error": None}

    def feed():
        writable = True
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "voxclip-voice-lab/1"}), timeout=120) as response:
                while chunk := response.read(1 << 20):
                    state["hash"].update(chunk)
                    state["bytes"] += len(chunk)
                    state["head"] += chunk[:max(0, 42 - len(state["head"]))]
                    if writable:
                        try:
                            decoder.stdin.write(chunk)
                        except BrokenPipeError:
                            writable = False
        except Exception as error:
            state["error"] = error
        finally:
            try:
                decoder.stdin.close()
            except BrokenPipeError:
                pass
    thread = threading.Thread(target=feed)
    thread.start()
    parts, offset, pcm = collect(iter(lambda: decoder.stdout.read(1 << 20), b""), windows)
    code = decoder.wait()
    thread.join()
    if state["error"] is not None:
        raise state["error"]
    if code != 0:
        raise ValueError("FFmpeg failed to decode " + url)
    if state["bytes"] != size or state["hash"].hexdigest() != sha256:
        raise ValueError("FLAC does not match its LFS SHA-256: " + url)
    rate, channels, bits, samples, md5 = streaminfo(bytes(state["head"]))
    if (rate, channels, bits) != (RATE, 1, 16) or samples * 2 != offset:
        raise ValueError("FLAC must decode to 16 kHz mono PCM16 with its declared length")
    if md5 != "0" * 32 and md5 != pcm:
        raise ValueError("Decoded PCM does not match the FLAC STREAMINFO MD5")
    if any(len(part) != EXCERPT_SAMPLES * 2 for part in parts.values()):
        raise ValueError("An excerpt runs past the end of its recording")
    return parts, {"samples": samples, "streaminfoMd5": md5}


def excerpt(args):
    selection = json.loads(args.selection.read_text())
    if (selection["policy"], selection["revision"]) != (POLICY, REVISION):
        raise ValueError("Selection is for another policy or revision")
    audio = tree("audio")
    windows = collections.defaultdict(dict)
    for speaker in selection["speakers"]:
        for candidate in speaker["candidates"]:
            windows[candidate["session"]][candidate["id"]] = candidate["startMs"] * RATE // 1000
    clips = args.output / "excerpts"
    clips.mkdir(parents=True, exist_ok=True)
    records, hashes = {}, {}

    def run(session):
        path = f"audio/{session}.flac"
        item = audio[path]
        for attempt in range(3):
            try:
                parts, info = stream_session(resolve(path), item["lfs"]["size"], item["lfs"]["oid"], windows[session], args.ffmpeg)
                break
            except (OSError, ValueError) as error:
                if attempt == 2 or "SHA-256" in str(error) or "STREAMINFO" in str(error):
                    raise
                print(f"Retrying {session}: {error}", file=sys.stderr, flush=True)
        for identity, data in parts.items():
            target = clips / (identity + ".wav")
            with wave.open(str(target), "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(RATE)
                output.writeframes(bytes(data))
            hashes[identity] = hashlib.sha256(target.read_bytes()).hexdigest()
        records[session] = {"path": path, "bytes": item["lfs"]["size"], "lfsSha256": item["lfs"]["oid"], **info}
        print(f"{session}: {len(parts)} excerpts", flush=True)
    sessions = [session for session in selection["pool"] if windows[session]]
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        list(pool.map(run, sessions))
    manifest = {"policy": POLICY, "dataset": DATASET, "revision": REVISION, "licence": LICENCE, "pool": selection["pool"],
                "audio": [records[session] for session in sessions], "transcripts": selection["transcripts"],
                "speakers": [{"key": speaker["key"], "group": speaker["group"],
                              "candidates": [dict(candidate, wav=str(clips / (candidate["id"] + ".wav")), sha256=hashes[candidate["id"]]) for candidate in speaker["candidates"]]}
                             for speaker in selection["speakers"]]}
    (args.output / "excerpts.json").write_text(json.dumps(manifest, indent=1) + "\n")
    print(f"Wrote {len(hashes)} excerpts from {len(sessions)} verified recordings.")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Riigikogu et-v1 transcript selection and verified excerpt streaming.")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("transcripts", help="Download and verify every .trs at the pinned revision")
    command.add_argument("--output", type=pathlib.Path, required=True)
    command.add_argument("--jobs", type=int, default=8)
    command = commands.add_parser("select", help="Choose pool, speakers, groups and candidates from transcripts alone (local file; contains names)")
    command.add_argument("--transcripts", type=pathlib.Path, required=True)
    command.add_argument("--output", type=pathlib.Path, required=True)
    command = commands.add_parser("excerpt", help="Stream each pool FLAC once and keep only verified six-second excerpts")
    command.add_argument("--selection", type=pathlib.Path, required=True)
    command.add_argument("--output", type=pathlib.Path, required=True)
    command.add_argument("--ffmpeg", default="ffmpeg")
    command.add_argument("--jobs", type=int, default=3)
    args = parser.parse_args()
    return {"transcripts": transcripts, "select": select_command, "excerpt": excerpt}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
