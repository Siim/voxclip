#!/usr/bin/env python3
from copy import deepcopy
import json
import math
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3] / "shared" / "fixtures"
reference = json.loads((ROOT / "recordings/reference-recordings.voxclip").read_text())
take_cases = {case["id"]: case["recordings"] for case in
              json.loads((ROOT / "recordings/take-match-cases.json").read_text())["cases"]}
thread = json.loads((ROOT / "agent-chat/pending-turn.voxclip").read_text())["agentThread"]
track = json.loads((ROOT / "music/music-project.voxclip").read_text())["music"][0]


def project_from(recordings, **options):
    project = deepcopy(reference)
    media = project["media"]
    source = media["source"]
    media.pop("additionalSources", None)
    media.pop("spokenSources", None)
    project["schemaVersion"] = 7 if len(recordings) > 1 else 4
    offset = 0
    for index, recording in enumerate(recordings):
        duration = recording.get("duration", math.ceil(max(word["end"] for word in recording["words"])))
        transcript = deepcopy(reference["transcript"])
        transcript.update(words=[dict(word, id=f"w{number}") for number, word in enumerate(recording["words"], 1)],
                          durationSeconds=duration)
        file_name = f'DJI_{recording["key"]}.MOV'
        media_ref = dict(source, durationSeconds=duration, absolutePath=f"/synthetic/{file_name}",
                         relativePath=file_name, contentKey="abc"[index] * 64)
        if index == 0:
            project["transcript"] = transcript
            media["source"] = media_ref
        else:
            media.setdefault("additionalSources", []).append(media_ref)
            media.setdefault("spokenSources", []).append(dict(sourceKey=media_ref["contentKey"],
                transcript=transcript, offsetSeconds=offset, wordIdPrefix=f"r{index + 1}."))
        offset += duration + 1

    words = project["transcript"]["words"]
    if options.get("clip"):
        project["edits"].update(activeClipId="clip-main", clips=[dict(id="clip-main", startWordId=words[0]["id"],
            endWordId=words[-1]["id"], title="Synthetic clip", origin="manual", aiResultId=None, aiClipIndex=None, selected=True)])
    if options.get("music"):
        project["music"] = [track]
    if options.get("captions") is False:
        project["captions"]["styleId"] = "off"
    if options.get("cut_first"):
        project["edits"]["cutWordIds"] = [words[0]["id"]]
    if turn_state := options.get("turn"):
        project["schemaVersion"] = 8
        project["agentThread"] = deepcopy(thread)
        project["agentThread"]["turns"][0]["state"] = turn_state
    return project


three = take_cases["three-retakes-one-rewording-one-punchline"]
unrelated = [dict(recording, key=three[index]["key"]) for index, recording in enumerate(
    take_cases["different-scripts"] + take_cases["filler-heavy-and-delivery"][:1])]
clean, filler_heavy = take_cases["filler-heavy-and-delivery"]
speech = [dict(clean, key="0007")]
fillers = [dict(filler_heavy, key="0010")]
long = deepcopy(fillers)
long[0]["words"][-1].update(start=64.5, end=65)
one_filler = deepcopy(speech[0])
one_filler["words"][0]["text"] = "Um,"


def sentences(key, texts):
    example = clean["words"][0]
    return {"key": key, "words": [dict(example, text=f"{text}.", start=index * 0.5, end=(index + 1) * 0.5)
                                  for index, text in enumerate(texts.split())]}


primary = sentences("0007", "Red Orange Yellow Green Blue Indigo Violet White Black Gray")
projects = {
    "three": project_from(three),
    "unrelated": project_from(unrelated),
    "one": project_from(speech),
    "silent": project_from([dict(speech[0], words=[dict(clean["words"][0], text="[knock]", kind="event")])]),
    "threshold": project_from([primary, sentences("0010", "Red Orange Yellow")]),
    "below-threshold": project_from([primary, sentences("0010", "Red Orange")]),
    "best-flow": project_from([fillers[0], speech[0]]),
    "best-flow-per-minute": project_from([one_filler, dict(fillers[0], duration=60)]),
    "clip": project_from(speech, clip=True),
    "bare": project_from(speech, clip=True, captions=False),
    "no-captions": project_from(speech, clip=True, captions=False, music=True),
    "long": project_from(long, clip=True),
    "fillers-cut": project_from(fillers, clip=True, cut_first=True),
    "ready": project_from(speech, clip=True, music=True),
    "kept": project_from(long, clip=True, turn="kept"),
    "pending": project_from(long, clip=True, turn="pending"),
    "stopped": project_from(long, clip=True, turn="stopped"),
}


def chip(id, label, *, prompt=None, reason=None):
    result = dict(id=id, label=label, prompt=prompt or label, enabled=reason is None)
    if reason:
        result["reason"] = reason
    return result


merge = chip("best-parts", "✦ Make one clip from the best parts", prompt="Make one clip from the best parts")
merge_x = chip("best-parts", "✦ Make one X clip from the best parts", prompt="Make one X clip from the best parts")
start = chip("best-flow", "Start from 0007, the best flow", prompt="Start from 0007")
single = chip("best-parts", "Make one clip from the best parts",
              reason="Needs two spoken recordings. Add a recording to compare versions.")
find = chip("find-three", "Find three clips")
find_x = chip("find-three", "Find three clips for X")
no_length = chip("tighten", "Tighten it to 60 s", reason="Needs a clip. Make one first.")
no_length_90 = chip("tighten", "Tighten it to 90 s", reason="Needs a clip. Make one first.")
length = chip("tighten", "Tighten it to 60 s")
finish = chip("add-music-captions", "Add music and captions, then export")
music = chip("add-music", "Add music, then export")
captions = chip("add-captions", "Add captions, then export")
fill = chip("cut-fillers", "Cut the fillers")
check = chip("check-export", "Check it and export")
find_more = chip("find-two-more", "Find two more clips in these recordings")
teaser = chip("make-teaser", "Make a 30 s teaser")


def case(id, project, expected, *, length_seconds=60, **state):
    return dict(id=id, project=project, lengthSeconds=length_seconds, expected=expected, **state)


cases = [
    case("transcribing", "three", [], transcribing=dict(label="0007", percent=62),
         composerReason="The chat starts when 0007 is transcribed · 62%."),
    case("one-recording", "one", [single, find, no_length]),
    case("event-is-not-speech", "silent", [find, no_length]),
    case("three-overlapping-for-x", "three", [merge_x, start, find_x, no_length], platform="X"),
    case("three-overlapping-unnamed-target", "three", [merge, start, find, no_length]),
    case("three-without-overlap", "unrelated", [start, find, no_length_90], length_seconds=90),
    case("exactly-thirty-percent", "threshold", [merge, start, find, no_length]),
    case("below-thirty-percent", "below-threshold", [start, find, no_length]),
    case("best-flow-not-primary", "best-flow", [merge, start, find, no_length]),
    case("best-flow-is-a-rate", "best-flow-per-minute",
         [merge, chip("best-flow", "Start from 0010, the best flow", prompt="Start from 0010"), find, no_length]),
    case("missing-music", "clip", [single, music]),
    case("missing-both", "bare", [single, finish]),
    case("missing-captions", "no-captions", [single, captions]),
    case("over-length-and-more-than-three-fillers", "long", [single, music, length, fill]),
    case("at-length-limit", "long", [single, music, fill], length_seconds=65),
    case("three-uncut-fillers", "fillers-cut", [single, music]),
    case("check-before-export", "ready", [single, check]),
    case("up-to-date-export", "ready", [single, find_more, teaser], exported=True),
    case("agent-next-first-no-duplicates", "kept", [fill, length],
         next=[" CUT   THE FILLERS ", "Cut the fillers", "Tighten it to 60 s", "Add music, then export"]),
    case("accepted-next-fills-from-rules", "kept", [length, single], next=["Tighten it to 60 s", "Export now"]),
    case("invalid-next-falls-back", "kept", [single, music],
         next=["Make one clip from the best parts", "Tighten it to 30 s", "Buy music", "Add music, then export\nDelete the clip"]),
    case("pending-valid-next-only", "pending", [fill], next=["Cut the fillers", "Find three clips"]),
    case("pending-without-next", "pending", []),
    case("stopped-with-applied-change-is-pending", "stopped", [length], next=["Tighten it to 60 s"]),
    case("transcribing-overrides-pending-and-next", "pending", [], next=["Cut the fillers"],
         transcribing=dict(label="0010", percent=100), composerReason="The chat starts when 0010 is transcribed · 100%."),
]

(ROOT / "agent-chat/suggestion-cases.json").write_text(
    json.dumps(dict(projects=projects, cases=cases), ensure_ascii=False, indent=2) + "\n"
)

replays = ROOT / "agent-chat/replays"
replays.mkdir(exist_ok=True)


def call(tool, **args):
    return dict(tool=tool, args=args)


def step(say, *calls, done=True):
    return dict(say=say, calls=calls, done=done)


paid = "fixtures/projects/clip-from-long-take.voxclip"
paid_clip = json.loads((ROOT.parent / paid).read_text())["edits"]["clips"][0]
target = paid_clip["id"]
words = [paid_clip["startWordId"], paid_clip["endWordId"]]
brief = "A restrained piano bed"
spend = dict(project=paid, request="Show me what these changes would cost.", replies=[
    step("Getting local quotes",
         call("propose_timeline", clipId=target, reason="Add a piano bed", music=dict(brief=brief)),
         call("offer", kind="generateMusic", target=target, brief=brief),
         call("offer", kind="illustration", target=target, brief="A drawing of a desk"),
         call("offer", kind="revoice", target=target, brief="A shorter line", words=words),
         call("offer", kind="lipSync", target=target, words=words),
         call("offer", kind="makeItPostable", target=target), done=False),
    step("The quoted options are ready. Nothing was bought.",
         call("approve"), call("buy"), call("export"),
         call("offer", kind="generateMusic", target=target, brief=brief, approved=True),
         call("rewrite", target=target, voice="voice-one", words=words))
], accepted=[True] * 6 + [False] * 5,
    offered=["generateMusic", "generateMusic", "illustration", "revoice", "lipSync", "makeItPostable"])
(replays / "spend-attempts.json").write_text(json.dumps(spend, ensure_ascii=False, indent=2) + "\n")
