import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import stat
import subprocess
import tempfile
import unittest

import jsonschema
from referencing import Registry, Resource


ROOT = Path(__file__).resolve().parents[2]
CLI = Path(os.environ.get("VOXCLIP_CLI", ROOT / "apps/macos/.build/debug/voxclip-cli"))
TEMPLATES = json.loads((ROOT / "shared/fixtures/clip-effects/motion-template-cases.json").read_text())
INVALID_TEMPLATES = json.loads((ROOT / "shared/fixtures/clip-effects/motion-template-invalid-cases.json").read_text())


def proposal_validator():
    registry = Registry()
    for name in ["harness-proposal", "harness-timeline", "clip-proposal", "clip-plan-effect", "motion-template"]:
        schema = json.loads((ROOT / f"shared/schemas/{name}.schema.json").read_text())
        registry = registry.with_resource(schema["$id"], Resource.from_contents(schema))
        if name == "harness-proposal":
            envelope = schema
    return jsonschema.Draft202012Validator(envelope, registry=registry, format_checker=jsonschema.FormatChecker())


class ProposalSchema(unittest.TestCase):
    def test_timeline_volume_edits(self):
        validator = proposal_validator()
        edits = [dict(op="setTrackGain", track="music-main", db=-12),
                 dict(op="dipGain", item="sound", startWord=4, endWord=5, byDb=-6)]
        envelope = dict(id="83a63352-80f7-4500-82ca-9405899b0be6", projectId="project", baseRevision="a" * 64,
                        version=2, timelines=[dict(clipId="clip", reason="Make room for speech.", edits=edits)])
        validator.validate(envelope)
        for edit, field, value in ((edits[0], "item", "sound"), (edits[1], "endWord", -1), (edits[1], "byDb", "-6")):
            timeline = dict(envelope["timelines"][0], edits=[dict(edit, **{field: value})])
            self.assertFalse(validator.is_valid(dict(envelope, timelines=[timeline])))

    def test_story_series_and_legacy_envelopes(self):
        validator = proposal_validator()
        envelope = {"id": "83a63352-80f7-4500-82ca-9405899b0be6", "projectId": "project", "baseRevision": "a" * 64}
        story = {"newClip": {"kind": "story", "title": "Two moments"}, "reason": "Lead with the result.",
                 "parts": [{"startWord": 9, "endWord": 12}, {"startWord": 0, "endWord": 3}]}
        validator.validate(dict(envelope, version=2, timelines=[story, story]))
        validator.validate(dict(envelope, version=1, timeline={"clipId": "clip", "title": "New title", "reason": "Shorter"}))
        for timelines in ([], [story] * 7, [dict(story, clipId="clip")], [dict(story, parts=story["parts"][:1])]):
            self.assertFalse(validator.is_valid(dict(envelope, version=2, timelines=timelines)))


class HarnessContract(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.project = Path(folder.name) / "fixture.voxclip"
        shutil.copyfile(ROOT / "shared/fixtures/projects/clip-from-long-take.voxclip", self.project)
        self.original = self.project.read_bytes()
        self.pending = self.project.with_suffix(".voxclip.proposal.json")
        self.environment = {key: value for key, value in os.environ.items() if not key.endswith("_API_KEY")}
        self.environment.update(VOXCLIP_DATA_DIR=folder.name, VOXCLIP_SHARED_DIR=str(ROOT / "shared"), VOXCLIP_NO_KEYCHAIN="1")
        self.timeline = {
            "clipId": "clip-2f1c", "reason": "Open with the main point.", "title": "A faster edit",
            "captionStyle": "vox-bold",
            "cuts": [{"kind": "other", "startWord": 11, "endWord": 11, "reason": "Keep the point short."}],
            "effects": [
                {"kind": "motionTitle", "startWord": 9, "endWord": 9, "text": "A faster edit", "reason": "Name the topic."},
                {"kind": "punchIn", "startWord": 14, "endWord": 15, "scale": 1.1, "reason": "Emphasize the takeaway."},
            ],
            "generateMusic": "A quiet instrumental bed",
        }

    def command(self, command, *options):
        guard = ["/usr/bin/sandbox-exec", "-p", "(version 1) (allow default) (deny network*)"]
        launcher = ["dotnet", str(CLI.resolve())] if CLI.suffix == ".dll" else [str(CLI)]
        return [*guard, *launcher, command, "--project", str(self.project), *options]

    def run_cli(self, command, body=None, *options):
        return subprocess.run(self.command(command, *options), input=body,
                              text=True, capture_output=True, env=self.environment, timeout=20)

    def replay(self, *requests):
        initialize = {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
            "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "contract", "version": "1"},
        }}
        initialized = {"jsonrpc": "2.0", "method": "notifications/initialized"}
        messages = [initialize, initialized] + [dict(jsonrpc="2.0", id=index, **request)
                                                for index, request in enumerate(requests, 1)]
        process = self.run_cli("mcp", "".join(json.dumps(message) + "\n" for message in messages))
        self.assertEqual(process.returncode, 0, process.stderr)
        replies = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual([reply["id"] for reply in replies], list(range(len(messages) - 1)))
        self.assertEqual(replies[0]["result"]["protocolVersion"], "2025-11-25")
        return [reply.get("result", reply.get("error")) for reply in replies[1:]]

    @staticmethod
    def call(name, **arguments):
        return {"method": "tools/call", "params": {"name": name, "arguments": arguments}}

    def test_replays_reads_and_stages_schema_valid_proposal(self):
        listing, transcript, clips, decisions, result, second = self.replay(
            {"method": "tools/list"}, self.call("read_transcript", limit=2), self.call("read_clips"),
            self.call("read_decisions", clipId="clip-2f1c"), self.call("propose_timeline", **self.timeline),
            self.call("propose_timeline", **dict(self.timeline, title="Don't overwrite the first proposal")),
        )
        tools = {tool["name"]: tool for tool in listing["tools"]}
        self.assertEqual(set(tools), {"read_transcript", "read_clips", "read_decisions", "read_frames", "propose_timeline"})
        jsonschema.validate(self.timeline, tools["propose_timeline"]["inputSchema"])
        self.assertEqual(transcript["structuredContent"]["words"][1]["index"], 1)
        self.assertTrue(clips["structuredContent"]["clips"])
        self.assertEqual(decisions["structuredContent"]["clipId"], "clip-2f1c")
        for command, options, expected in [
            ("transcript", ["--limit", "2"], transcript), ("clips", [], clips), ("decisions", ["--clip", "clip-2f1c"], decisions),
        ]:
            cli = self.run_cli(command, None, *options)
            self.assertEqual(cli.returncode, 0, cli.stderr)
            self.assertEqual(json.loads(cli.stdout), expected["structuredContent"])
        staged = result["structuredContent"]
        proposal_validator().validate(staged["proposal"])
        self.assertEqual(json.loads(self.pending.read_text()), staged["proposal"])
        self.assertEqual(stat.S_IMODE(self.pending.stat().st_mode), 0o600)
        self.assertEqual(staged["proposal"]["timelines"], [self.timeline])
        self.assertRegex(staged["pricedActions"][0]["price"], r"^\$\d+\.\d\d$")
        self.assertTrue(second["isError"])
        self.assertEqual(self.project.read_bytes(), self.original)
        self.pending.unlink()
        cli = self.run_cli("propose-timeline", json.dumps(self.timeline))
        self.assertEqual(cli.returncode, 0, cli.stderr)
        self.assertEqual(json.loads(cli.stdout)["proposal"]["timelines"], [self.timeline])

    def test_edits_use_timeline_decisions_without_spending(self):
        clip = "clip-2f1c"
        listing, decisions = self.replay({"method": "tools/list"}, self.call("read_decisions", clipId=clip))
        layout = decisions["structuredContent"]["timeline"]
        speech = next(item for item in layout["items"] if item["kind"] == "clip")
        self.assertEqual(speech["lane"], "V1")
        self.assertFalse(speech["paid"])
        self.assertTrue(speech["editedIntervals"])
        self.assertTrue(layout["snapTargets"])
        edit = {"op": "trim", "item": speech["id"], "edge": "start", "toWord": speech["startWord"] + 1}
        timeline = {"clipId": clip, "reason": "Start on the next word.", "edits": [edit]}
        schema = next(tool["inputSchema"] for tool in listing["tools"] if tool["name"] == "propose_timeline")
        jsonschema.validate(timeline, schema)
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(dict(timeline, edits=[dict(edit, pay=True)]), schema)
        proposed, = self.replay(self.call("propose_timeline", **timeline))
        staged = proposed["structuredContent"]
        self.assertEqual(staged["pricedActions"], [])
        proposal_validator().validate(staged["proposal"])
        self.assertEqual(staged["proposal"]["timelines"], [timeline])
        self.pending.unlink()

        refused = dict(timeline, edits=[edit, {"op": "delete", "items": ["missing"]}], generateMusic="A quiet instrumental")
        response = self.run_cli("propose-timeline", json.dumps(refused))
        self.assertEqual(response.returncode, 0, response.stderr)
        staged = json.loads(response.stdout)
        self.assertEqual(staged["pricedActions"], [])
        self.assertEqual(staged["refusals"], [{"timelineIndex": 0, "reason": "Select an item on this timeline."}])
        self.assertEqual(json.loads(self.pending.read_text()), staged["proposal"])
        self.assertEqual(self.project.read_bytes(), self.original)

    def test_stages_a_story_series_without_editing_or_sending(self):
        story = json.loads((ROOT / "shared/fixtures/clips-mode/harness-proposal-cases.json").read_text())["story"]
        series = {"timelines": [story, self.timeline]}
        listing, clips, reply = self.replay({"method": "tools/list"}, self.call("read_clips"), self.call("propose_timeline", **series))
        tool = next(tool for tool in listing["tools"] if tool["name"] == "propose_timeline")
        jsonschema.validate(series, tool["inputSchema"])
        clip = clips["structuredContent"]["clips"][0]
        self.assertEqual(clip["kind"], "stretch")
        self.assertEqual(clip["parts"], [{"startWord": clip["startWord"], "endWord": clip["endWord"]}])
        self.assertFalse(reply.get("isError", False), reply)
        staged = reply["structuredContent"]
        proposal_validator().validate(staged["proposal"])
        self.assertEqual(staged["proposal"]["timelines"], series["timelines"])
        self.assertEqual([(action["timelineIndex"], action["kind"]) for action in staged["pricedActions"]],
                         [(0, "rewrite"), (1, "generateMusic")])
        self.assertTrue(all("$" in action["price"] for action in staged["pricedActions"]))
        self.assertEqual(json.loads(self.pending.read_text()), staged["proposal"])
        self.assertEqual(self.project.read_bytes(), self.original)

    def test_places_local_motion_templates_through_mcp_and_cli(self):
        for effect in TEMPLATES:
            with self.subTest(template=effect["template"]["name"]):
                self.pending.unlink(missing_ok=True)
                timeline = {"clipId": "clip-2f1c", "reason": "Make a showreel.", "effects": [effect]}
                listing, result = self.replay({"method": "tools/list"}, self.call("propose_timeline", **timeline))
                self.assertNotIn("isError", result)
                schema = next(tool["inputSchema"] for tool in listing["tools"] if tool["name"] == "propose_timeline")
                jsonschema.validate(timeline, schema)
                staged = result["structuredContent"]
                proposal_validator().validate(staged["proposal"])
                self.assertEqual(staged["proposal"]["timelines"], [timeline])
                self.assertEqual(staged["pricedActions"], [])
                self.assertEqual(json.loads(self.pending.read_text()), staged["proposal"])
                self.pending.unlink()
                cli = self.run_cli("propose-timeline", json.dumps(timeline))
                self.assertEqual(cli.returncode, 0, cli.stderr)
                cli_staged = json.loads(cli.stdout)
                proposal_validator().validate(cli_staged["proposal"])
                self.assertEqual(cli_staged["proposal"]["timelines"], [timeline])
                self.assertEqual(cli_staged["pricedActions"], [])
                self.assertEqual(json.loads(self.pending.read_text()), cli_staged["proposal"])
                self.pending.unlink()
                self.assertEqual(self.project.read_bytes(), self.original)

    def test_rejects_unsafe_or_malformed_templates_and_cut_anchors(self):
        timelines = [{"clipId": "clip-2f1c", "reason": "Make a showreel.", "effects": [dict(TEMPLATES[0], template=template)]}
                     for template in INVALID_TEMPLATES]
        cut = dict(timelines[0], effects=[TEMPLATES[0]],
                   cuts=[{"startWord": 10, "endWord": 10, "kind": "other", "reason": "Remove the anchor."}])
        listing, *results = self.replay({"method": "tools/list"},
                                        *(self.call("propose_timeline", **timeline) for timeline in [*timelines, cut]))
        schema = next(tool["inputSchema"] for tool in listing["tools"] if tool["name"] == "propose_timeline")
        for timeline, result in zip(timelines, results, strict=False):
            with self.subTest(timeline=timeline):
                with self.assertRaises(jsonschema.ValidationError):
                    jsonschema.validate(timeline, schema)
                self.assertTrue(result["isError"])
        self.assertTrue(results[-1]["isError"])
        self.assertFalse(self.pending.exists())
        self.assertEqual(self.project.read_bytes(), self.original)

    def test_rejects_unscoped_paid_and_consent_requests_without_writing(self):
        responses = self.replay(self.call("generate_music", prompt="music"), self.call("capture_consent"),
                                self.call("export"), self.call("read_transcript", project="../other.voxclip"),
                                self.call("propose_timeline", **self.timeline, approved=True),
                                self.call("propose_timeline", **dict(self.timeline, clipId="other-project")))
        for response in responses:
            self.assertTrue(response.get("isError") or response.get("code"))
        self.assertFalse(self.pending.exists())
        self.assertEqual(self.project.read_bytes(), self.original)

    def test_overlay_proposal_prices_illustration_without_sending_and_lists_footage(self):
        project = json.loads(self.original)
        companion = dict(project["media"]["source"], contentKey="e" * 64, absolutePath="/Media/other.mov")
        project["schemaVersion"] = 4
        project["voiceLab"].update(assets=[], cleanAudio={"mode": "off", "assetId": None, "mix": None}, voices=[], videoAssets=[])
        project["media"]["additionalSources"] = [companion]
        self.project.write_text(json.dumps(project))
        original = self.project.read_bytes()
        entries = [
            {"kind": "bRoll", "footage": {"sourceKey": companion["contentKey"], "start": 1}},
            {"kind": "screenshot", "startWord": 11, "endWord": 11, "footage": {"sourceKey": companion["contentKey"], "start": 2}},
            {"kind": "videoStack", "startWord": 14, "endWord": 14, "footage": {"sourceKey": companion["contentKey"], "start": 3}},
            {"kind": "illustration", "prompt": "A cutaway of a lighthouse"},
            {"kind": "soundEffect", "query": "wind"},
            {"kind": "colourLook", "look": "warm"},
            {"kind": "speedForPart", "endWord": 16, "rate": 0.5},
        ]
        timeline = {"clipId": "clip-2f1c", "reason": "Show the scene.", "generateMusic": "A restrained piano bed", "effects": [
            {"startWord": 9, "endWord": 9, "reason": "Show the scene.", **entry} for entry in entries]}
        listing, clips, reply = self.replay({"method": "tools/list"}, self.call("read_clips"), self.call("propose_timeline", **timeline))
        schema = next(tool["inputSchema"] for tool in listing["tools"] if tool["name"] == "propose_timeline")
        jsonschema.validate(timeline, schema)
        self.assertEqual(clips["structuredContent"]["footageSources"][0]["sourceKey"], companion["contentKey"])
        for result in [reply["structuredContent"], None]:
            if result is None:
                self.pending.unlink()
                cli = self.run_cli("propose-timeline", json.dumps(timeline))
                self.assertEqual(cli.returncode, 0, cli.stderr)
                result = json.loads(cli.stdout)
            proposal_validator().validate(result["proposal"])
            self.assertEqual(result["proposal"]["timelines"], [timeline])
            self.assertEqual([action["kind"] for action in result["pricedActions"]], ["generateMusic", "generateIllustration"])
            self.assertEqual(result["pricedActions"][0]["price"], "$0.02")
            self.assertTrue(result["pricedActions"][1]["price"].startswith("$"))
            self.assertEqual(result["freeActions"][0]["kind"], "findSound")
            self.assertEqual(self.project.read_bytes(), original)

    def test_rejects_invalid_edit_anchors_without_staging(self):
        cuts = dict(self.timeline["cuts"][0], startWord=0, endWord=0)
        duplicate = self.timeline["cuts"] * 2
        overlap = dict(self.timeline["effects"][1], startWord=11)
        invalid = [dict(self.timeline, cuts=[cuts]), dict(self.timeline, cuts=duplicate),
                   dict(self.timeline, effects=[overlap]), dict(self.timeline, captionStyle="not-a-bundled-style")]
        for response in self.replay(*(self.call("propose_timeline", **timeline) for timeline in invalid)):
            self.assertTrue(response["isError"])
        self.assertFalse(self.pending.exists())
        self.assertEqual(self.project.read_bytes(), self.original)

    def test_concurrent_proposals_leave_one_complete_sidecar(self):
        with ThreadPoolExecutor(max_workers=2) as workers:
            requests = [workers.submit(self.run_cli, "propose-timeline", json.dumps(dict(self.timeline, title=title)))
                        for title in ("First edit", "Second edit")]
            replies = [request.result() for request in requests]
        winners = [json.loads(reply.stdout)["proposal"] for reply in replies if reply.returncode == 0]
        self.assertEqual(len(winners), 1)
        self.assertEqual(json.loads(self.pending.read_text()), winners[0])
        self.assertEqual(self.project.read_bytes(), self.original)

    def test_oversized_message_does_not_close_the_stdio_session(self):
        process = self.run_cli("mcp", " " * (128 * 1024 + 1) + '\n{"jsonrpc":"2.0","id":1,"method":"ping"}\n')
        self.assertEqual(process.returncode, 0, process.stderr)
        refused, ping = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual(refused["error"]["code"], -32700)
        self.assertEqual(ping, {"jsonrpc": "2.0", "id": 1, "result": {}})
        self.assertFalse(self.pending.exists())

    def test_missing_media_is_a_local_frame_error(self):
        result, = self.replay(self.call("read_frames", times=[0]))
        self.assertTrue(result["isError"])

    def test_source_identity_must_match_before_decoding(self):
        fixture = ROOT / "shared/fixtures/media/counter-1080p.mp4"
        project = json.loads(self.original)
        project["media"]["source"].update(absolutePath=str(fixture), relativePath=None, sizeBytes=fixture.stat().st_size,
                                           contentKey="0" * 64)
        self.project.write_text(json.dumps(project))
        result, = self.replay(self.call("read_frames", times=[0]))
        self.assertTrue(result["isError"])
        self.assertIn("Relink", result["content"][0]["text"])

    def test_project_source_frames_are_jpeg_content(self):
        fixture = ROOT / "shared/fixtures/media/counter-1080p.mp4"
        content = fixture.read_bytes()
        key = hashlib.sha256(f"voxclip-source-v1\n{len(content)}\n".encode() + content).hexdigest()
        project = json.loads(self.original)
        project["media"]["source"].update(absolutePath=str(fixture), relativePath=None, sizeBytes=len(content), contentKey=key)
        self.project.write_text(json.dumps(project))
        result, = self.replay(self.call("read_frames", times=[0, 0.5]))
        self.assertNotIn("isError", result)
        self.assertEqual([item["type"] for item in result["content"]], ["text", "image", "image"])
        for image in result["content"][1:]:
            self.assertEqual(image["mimeType"], "image/jpeg")
            self.assertTrue(base64.b64decode(image["data"], validate=True).startswith(b"\xff\xd8"))
        cli = self.run_cli("frames", None, "--time", "0", "--time", "0.5")
        self.assertEqual(cli.returncode, 0, cli.stderr)
        self.assertEqual([frame["actual"] for frame in json.loads(cli.stdout)["frames"]], [0, 0.5])

    def test_live_stdio_pins_the_project_before_reading_requests(self):
        with subprocess.Popen(self.command("mcp"), env=self.environment, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process, selectors.DefaultSelector() as ready:
            ready.register(process.stdout, selectors.EVENT_READ)

            def send(method, identifier, **params):
                request = dict(jsonrpc="2.0", id=identifier, method=method, params=params)
                process.stdin.write((json.dumps(request) + "\n").encode())
                process.stdin.flush()
                if not ready.select(timeout=5):
                    process.kill()
                    self.fail(f"No live stdio reply to {method}")
                return json.loads(process.stdout.readline())

            try:
                self.assertIn("result", send("initialize", "init", protocolVersion="2025-06-18",
                                             capabilities={}, clientInfo={"name": "contract", "version": "1"}))
                process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
                process.stdin.flush()
                self.assertEqual(send("ping", "keep-alive"), {"jsonrpc": "2.0", "id": "keep-alive", "result": {}})
                swapped = json.loads(self.original)
                swapped["id"] = "06f0351b-b7a9-4386-baa7-09e054faf3d5"
                self.project.write_text(json.dumps(swapped))
                refusal = send("tools/call", "swap", name="read_clips", arguments={})
                self.assertTrue(refusal["result"]["isError"])
                self.assertEqual(refusal["id"], "swap")
            finally:
                process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    self.fail("MCP server did not exit after stdin closed")


if __name__ == "__main__":
    unittest.main()
