#!/usr/bin/env python3
"""Build the deterministic Five questions redesign project without media or providers."""
import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FOLDER = ROOT / "shared/fixtures/projects"
OUTPUT = FOLDER / "five-questions.voxclip"
PASSAGES = [
    ("Start with the question", "Um, what makes a good interview question? Start with something simple that invites a story rather than a yes or no answer."),
    ("Listen for the story", "Um, how do you find the story? Listen for a specific moment and ask what changed when the speaker made that decision."),
    ("Give the answer room", "Um, when should you ask another question? Leave a little room after the answer so the speaker can finish the thought in their own words."),
    ("Keep the useful details", "Um, which details should stay in the edit? Keep the concrete examples that help a listener understand the idea without needing the rest of the conversation."),
    ("End with a clear thought", "What makes a useful ending? Return to the question and leave the listener with one clear thought they can remember and try for themselves."),
]


def build():
    project = json.loads((FOLDER / "interview-take.voxclip").read_text())
    project.update(id="f15e0000-0000-4000-8000-000000000018", title="Five questions",
                   createdAt="2026-10-28T06:00:00.000Z", modifiedAt="2026-10-28T06:00:00.000Z")
    source = project["media"]["source"]
    source.update(absolutePath="/fixtures/five-questions.mov", relativePath="five-questions.mov",
                  sizeBytes=1024, contentKey=hashlib.sha256(b"synthetic-five-questions").hexdigest())
    words, clips = [], []
    for passage_index, (title, passage) in enumerate(PASSAGES):
        first = len(words) + 1
        for text in passage.split():
            position = len(words)
            start = round(0.5 + position * 0.8 + passage_index * 0.8, 3)
            end = round(start + 0.55, 3)
            words.append(dict(id=f"fq-{position + 1}", text=text, kind="word", start=start, end=end,
                              rawStart=start, rawEnd=end, conf=0.99, speaker=None, timing="native"))
        clips.append(dict(id=f"fq-clip-{passage_index + 1}", title=title, startWordId=f"fq-{first}",
                          endWordId=words[-1]["id"], origin="ai" if passage_index == 4 else "manual",
                          aiResultId="fq-result" if passage_index == 4 else None,
                          aiClipIndex=0 if passage_index == 4 else None, selected=passage_index != 4))
    duration = round(words[-1]["end"] + 1, 3)
    source["durationSeconds"] = duration
    project["transcript"].update(words=words, durationSeconds=duration, createdAt=project["createdAt"])
    project["edits"].update(cutWordIds=[f"fq-{index}" for index in range(2, 10)], cutPauseIds=[],
                            corrections={}, clips=clips, activeClipId=None)
    project["captions"].update(styleId="vox-highlight", overrides={}, position=None, positionByAspect={})
    project["export"].update(aspect="16:9", quality="standard", srt=False, folder=None)
    project["share"] = {"captions": {}}
    reference = json.loads((FOLDER / "clip-from-long-take.voxclip").read_text())["ai"]["results"][0]
    result = copy.deepcopy(reference)
    result.update(id="fq-result", createdAt=project["createdAt"], provider="ollama", model="fixture-local",
                  language="en", preset="best", instructions=None,
                  inputSha256=hashlib.sha256(" ".join(word["text"] for word in words).encode()).hexdigest(),
                  clips=[dict(title=clips[-1]["title"], reason="A self-contained closing thought.", score=8,
                              startWordId=clips[-1]["startWordId"], endWordId=clips[-1]["endWordId"])])
    project["ai"] = {"results": [result]}
    project["extensions"] = {"voxclip.fixture": {"generator": "tools/fixtures/projects/generate_five_questions.py"}}
    return project


if __name__ == "__main__":
    OUTPUT.write_text(json.dumps(build(), indent=2, ensure_ascii=False) + "\n")
