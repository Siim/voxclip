#!/usr/bin/env python3
"""Build take-journal-cases.json, the paid-take journal's shared vectors (voice-lab section 3 "Paid takes are kept"):
tiny canonical PCM16 assets with their SHA-256, the journal entries over them (some with the verdict of their checks),
and the parse and match cases both platforms replay. Pure integer and hash maths, so every platform writes the same
bytes. Run from anywhere."""
import hashlib
import json
import struct
from pathlib import Path

OUT = Path(__file__).resolve().parents[3] / 'shared/fixtures/voice-lab/take-journal-cases.json'
project = "8be1e34a-6c1d-4e0a-9b52-3f0d2a7c9e11"
def wav(frames, rate, fill):
    data = struct.pack("<h", fill) * frames
    header = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16) + b"data" + struct.pack("<I", len(data))
    return header + data
def sha(frames, rate, fill): return hashlib.sha256(wav(frames, rate, fill)).hexdigest()
key = {"recordID": "fixture-record", "voiceID": "fixtureOwnVoice", "modelID": "eleven_v3", "language": "en",
       "requestText": "Hello", "previousText": "before", "nextText": "after", "pace": 1.0}
assets = [
    {"assetId": "0f6a1c2e-1111-4a00-8000-000000000001", "frames": 240, "sampleRate": 24000, "fill": 1000},
    {"assetId": "0f6a1c2e-2222-4a00-8000-000000000002", "frames": 480, "sampleRate": 24000, "fill": -2000},
    {"assetId": "0f6a1c2e-3333-4a00-8000-000000000003", "frames": 240, "sampleRate": 24000, "fill": 300},
    {"assetId": "0f6a1c2e-5555-4a00-8000-000000000005", "frames": 240, "sampleRate": 24000, "fill": 5},
    {"assetId": "0f6a1c2e-6666-4a00-8000-000000000006", "frames": 360, "sampleRate": 24000, "fill": 7},
    {"assetId": "0f6a1c2e-7777-4a00-8000-000000000007", "frames": 240, "sampleRate": 24000, "fill": 11},
    {"assetId": "0f6a1c2e-8888-4a00-8000-000000000008", "frames": 240, "sampleRate": 24000, "fill": 13},
    {"assetId": "0f6a1c2e-aaaa-4a00-8000-00000000000a", "frames": 240, "sampleRate": 24000, "fill": 17},
]
for a in assets: a["sha256"] = sha(a["frames"], a["sampleRate"], a["fill"])
byid = {a["assetId"]: a for a in assets}
def entry(asset_id, k, created, request, frames=None, sha_of=None, **extra):
    a = byid.get(asset_id)
    e = {"schema": "voxclip-take-journal/1", "assetFile": f"{project}/{asset_id}.wav",
         "assetSha256": (byid[sha_of]["sha256"] if sha_of else (a["sha256"] if a else hashlib.sha256(b"missing").hexdigest())),
         "requestID": request, "recordID": k["recordID"], "voiceID": k["voiceID"], "modelID": k["modelID"], "language": k["language"],
         "requestText": k["requestText"], "previousText": k["previousText"], "nextText": k["nextText"], "pace": k["pace"],
         "seed": 4294967295, "sampleRate": 24000, "frames": frames if frames is not None else (a["frames"] if a else 240),
         "receipt": {"provider": "elevenlabs", "region": "default", "endpoint": "v1/text-to-speech/fixtureOwnVoice/with-timestamps"},
         "createdAt": created}
    e.update(extra)
    return e
alignment = {"recovered": False, "characters": [
    {"character": "H", "start": 0.1, "end": 0.2}, {"character": "e", "start": 0.2, "end": 0.3},
    {"character": "l", "start": 0.3, "end": 0.4}, {"character": "l", "start": 0.4, "end": 0.5}, {"character": "o", "start": 0.5, "end": 0.6}]}
older = entry(assets[0]["assetId"], key, "2026-11-21T00:24:07Z", "22ec0b66-1e2f-4a3b-9c4d-5e6f70819201",
              providerRequestID="req_fixture_older", alignment=alignment, estimateUSD="0.0125")
newer = entry(assets[1]["assetId"], key, "2026-11-21T00:25:30Z", "37d85075-1e2f-4a3b-9c4d-5e6f70819202")
other_voice = entry(assets[2]["assetId"], dict(key, voiceID="otherVoice"), "2026-11-21T00:26:00Z", "f25a6832-1e2f-4a3b-9c4d-5e6f70819203",
                    receipt={"provider": "elevenlabs", "region": "default", "endpoint": "v1/text-to-speech/otherVoice/with-timestamps"})
missing = entry("0f6a1c2e-4444-4a00-8000-000000000004", dict(key, requestText="Missing"), "2026-11-21T00:27:00Z", "4a1b2c3d-1e2f-4a3b-9c4d-5e6f70819204")
wrong_frames = entry(assets[3]["assetId"], dict(key, requestText="Short"), "2026-11-21T00:28:00Z", "5a1b2c3d-1e2f-4a3b-9c4d-5e6f70819205", frames=480)
recovered = entry(assets[4]["assetId"], dict(key, requestText="Slow [laughs] words", pace=0.8, modelID="eleven_v4", previousText="", nextText=""),
                  "2026-11-21T00:29:00Z", "6a1b2c3d-1e2f-4a3b-9c4d-5e6f70819206",
                  alignment={"recovered": True, "characters": [{"character": "S", "start": 0, "end": 0.05}]},
                  receipt={"provider": "elevenlabs", "region": "eu", "endpoint": "v1/text-to-dialogue/with-timestamps"}, estimateUSD="0")
# The verdict of a take's checks: a hard failure (the same audio fails the same way again) is never adopted.
passed_checks = {"hardFailures": [], "speaker": "passed", "words": "passed"}
checked_key = dict(key, requestText="Checked")
checked_passed = entry(assets[5]["assetId"], checked_key, "2026-11-21T00:30:00Z", "7a1b2c3d-1e2f-4a3b-9c4d-5e6f70819207", checks=passed_checks)
# A short take (its speaker check pooled, so not its own) that dropped words, newer than the take that passed.
checked_failed_words = entry(assets[6]["assetId"], checked_key, "2026-11-21T00:31:00Z", "8a1b2c3d-1e2f-4a3b-9c4d-5e6f70819208",
                             checks={"hardFailures": ["transcript"], "words": "failed"})
# Failed its own speaker check, so its word check was never sent.
failed_speaker = entry(assets[7]["assetId"], dict(key, requestText="Unlike"), "2026-11-21T00:32:00Z", "9a1b2c3d-1e2f-4a3b-9c4d-5e6f70819209",
                       checks={"hardFailures": ["speaker"], "speaker": "failed"})
entries = [older, newer, other_voice, missing, wrong_frames, recovered, checked_passed, checked_failed_words, failed_speaker]
F = lambda e: e["assetFile"]
cases = []
def match(cid, k, expected, claimed=()):
    cases.append({"id": cid, "kind": "match", "key": k, "claimed": [F(c) for c in claimed], "expected": F(expected) if expected else None})
def parse(cid, e, valid):
    cases.append({"id": cid, "kind": "parse", "entry": e, "valid": valid})
match("newest-of-two", key, newer)
match("claimed-newest-falls-back", key, older, [newer])
match("all-claimed", key, None, [newer, older])
match("pace-rounds-to-what-was-sent", dict(key, pace=1.004), newer)
match("other-voice-is-its-own", dict(key, voiceID="otherVoice"), other_voice)
match("changed-text", dict(key, requestText="Hello there"), None)
match("changed-next-words", dict(key, nextText="after that"), None)
match("changed-pace", dict(key, pace=0.9), None)
match("changed-model", dict(key, modelID="eleven_multilingual_v2"), None)
match("changed-record", dict(key, recordID="other-record"), None)
match("changed-language", dict(key, language="de"), None)
match("asset-missing", dict(key, requestText="Missing"), None)
match("asset-frames-differ", dict(key, requestText="Short"), None)
match("recovered-timing-and-tags", dict(key, requestText="Slow [laughs] words", pace=0.8, modelID="eleven_v4", previousText="", nextText=""), recovered)
match("newer-take-that-failed-its-words-is-skipped", checked_key, checked_passed)
match("a-failed-take-is-never-the-fallback", checked_key, None, [checked_passed])
match("only-take-failed-its-speaker-check", dict(key, requestText="Unlike"), None)
parse("provider-timing-round-trips", older, True)
parse("optional-fields-absent-round-trips", newer, True)
parse("recovered-timing-round-trips", recovered, True)
parse("wrong-schema", dict(older, schema="voxclip-take-journal/2"), False)
parse("asset-outside-project", dict(older, assetFile="0e0e0e0e-0000-4000-8000-000000000000/" + assets[0]["assetId"] + ".wav"), False)
parse("asset-not-wav", dict(older, assetFile=f"{project}/{assets[0]['assetId']}.mp4"), False)
parse("uppercase-request-id", dict(older, requestID=older["requestID"].upper()), False)
parse("unknown-region", dict(older, receipt=dict(older["receipt"], region="mars")), False)
parse("malformed-sha", dict(older, assetSha256="abc"), False)
parse("no-frames", dict(older, frames=0), False)
parse("negative-timing", dict(older, alignment={"recovered": False, "characters": [{"character": "H", "start": 0.3, "end": 0.2}]}), False)
parse("unparsable-estimate", dict(older, estimateUSD="about a cent"), False)
parse("passed-checks-round-trip", checked_passed, True)
parse("failed-checks-round-trip", checked_failed_words, True)
parse("unrecovered-timing-round-trips", dict(older, checks={"hardFailures": ["timing"], "words": "failed"}), True)
parse("unknown-check-outcome", dict(older, checks={"hardFailures": [], "speaker": "maybe"}), False)
parse("empty-failure-name", dict(older, checks={"hardFailures": [""], "words": "failed"}), False)
parse("checks-without-failures", dict(older, checks={"speaker": "passed", "words": "passed"}), False)
doc = {"schema": "voxclip-take-journal-cases/1", "entrySchema": "voxclip-take-journal/1", "projectId": project,
       "caseCount": len(cases), "assets": assets, "entries": entries, "cases": cases}
OUT.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
