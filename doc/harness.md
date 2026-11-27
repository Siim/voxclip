# Connect your agent to a VoxClip project

On macOS and Windows, the VoxClip command-line tool can give Claude Code or Codex a transcript, clip list, saved decisions and source thumbnails for **one saved `.voxclip` file**. The agent can propose a timeline. It can't change the project, send a provider request, spend money or record voice consent. The agent host can see whatever the server returns, including transcript text and thumbnails. Only connect projects you're comfortable sharing with that host.

## Set up the connection

Save your project in VoxClip first. Use absolute paths to the `.voxclip` file and the CLI.

- **macOS:** `swift build --package-path apps/macos --product voxclip-cli` builds `apps/macos/.build/debug/voxclip-cli`.
- **Windows:** use `voxclip-cli.exe` next to the installed `VoxClip.exe`. Use local paths for the project and source. If the CLI asks for the Windows component terms, run `voxclip-cli --runtime-terms`, then `voxclip-cli --accept-runtime-terms <SHA-256>` if you accept them.

### Claude Code

From the folder where you'll run Claude Code, register a local entry, used only by you in this folder:

```sh
claude mcp add --transport stdio --scope local voxclip -- \
  "/absolute/path/to/voxclip-cli" mcp --project "/absolute/path/to/Talk.voxclip"
```

Start Claude Code from that folder and check `/mcp`. Use `--scope project` only if you want to save the entry in a shared `.mcp.json`. Don't commit personal project paths.

### Codex

In a trusted workspace, put this in `.codex/config.toml`. Use `~/.codex/config.toml` instead if you want the entry in every workspace. Restart Codex and check `codex mcp list` or `/mcp`.

```toml
[mcp_servers.voxclip]
command = "/absolute/path/to/voxclip-cli"
args = ["mcp", "--project", "/absolute/path/to/Talk.voxclip"]
```

The executable finds `shared/` in its checkout or app bundle. If you relocate it on its own, set `VOXCLIP_SHARED_DIR` to the absolute path to the matching `shared/` folder in the host's MCP environment. You don't need to configure provider keys for this server. To connect a different VoxClip project, change `--project` and restart the connection.

## Read and propose

| MCP tool | Matching CLI | What it does |
|---|---|---|
| `read_transcript` | `transcript --project Talk.voxclip --offset 0 --limit 200` | Returns transcript items with their zero-based project indices, corrected words, cut flags, recording labels and project-clock seconds. Follow `nextOffset` until it's null. |
| `read_clips` | `clips --project Talk.voxclip` | Lists clips with ids, kinds, parts in play order and their recordings, plus `footageSources` keys for companion footage. |
| `read_takes` | `takes --project Talk.voxclip` | Returns shared beats, alternate takes, aligned spans, delivery flags and solo runs. Its word and beat ids are the ones VoxClip uses. |
| `read_decisions` | `decisions --project Talk.voxclip --clip CLIP_ID` | Reads the clip's saved choices: Find Clips reason where available, opening lead-in, framing and cover controls, captions, effects, zooms and saved music ids. |
| `read_frames` | `frames --project Talk.voxclip --time 2.1 --time 3` | Returns one to four unedited source thumbnails from a local MP4, M4V or MOV. CLI output includes JPEGs as base64. Relink missing media in VoxClip. |
| `propose_timeline` | `propose-timeline --project Talk.voxclip < timeline.json` | Stages one to six timelines for new or existing clips. It writes no project edits and returns separate estimates for requested paid actions. |

You might ask: “Read the clips and the transcript. For the clip about editing faster, propose a punch-in on the strongest sentence and a short on-screen title. Don't generate anything.”

The proposal tool takes a [timeline](../shared/schemas/harness-timeline.schema.json) or an object with `timelines` containing one to six timelines. To update an existing clip, use its `clipId`:

```json
{
  "clipId": "clip-2f1c",
  "reason": "Get to the main point faster.",
  "cuts": [{"startWord": 11, "endWord": 11, "kind": "other", "reason": "Remove the aside."}],
  "captionStyle": "vox-bold",
  "title": "A faster edit",
  "effects": [
    {"kind": "motionTitle", "startWord": 9, "endWord": 9, "text": "A faster edit", "reason": "Name the topic."},
    {"kind": "punchIn", "startWord": 14, "endWord": 15, "scale": 1.1, "reason": "Emphasize the takeaway."}
  ]
}
```

To make a new clip, use `newClip` instead of `clipId`. For example, this story plays the later moment first:

```json
{"timelines":[{
  "newClip":{"kind":"story","title":"Start with the result"},
  "parts":[{"startWord":140,"endWord":164},{"startWord":23,"endWord":51}],
  "reason":"Lead with the result, then explain how we got there.",
  "look":{"id":"warm"},"captionStyle":"vox-bold"
}]}
```

Use inclusive transcript indices from the current project. List nonoverlapping parts in play order: one for a `stretch`, two to twelve for a `story` or `showreel`. `read_clips` returns `kind` and `parts` in that order. Cuts change the source's shared cut list, so overlapping clips also reflect them. Effects need kept spoken-word anchors and use the complete [clip-plan entry schema](../shared/schemas/clip-plan-effect.schema.json), including `bRoll`, `screenshot`, `videoStack`, `illustration`, `soundEffect`, `colourLook` and `speedForPart`. Footage uses a `sourceKey` from `read_clips`, with a source start in seconds.

Timeline fields mirror the [shared clip proposal vocabulary](../shared/schemas/clip-proposal.schema.json), including caption font, case and word count, pause cuts, corrections, hook, speed, cover title and post text. `music: {"trackId":"…"}` reuses a saved track; `music: {"brief":"…"}` proposes generating a track. The legacy `musicTrackId` and `generateMusic` fields still work. The tool returns `pricedActions` and `freeActions` with zero-based `timelineIndex` values. A `rewrite` quote is a local list-price estimate for one voice take, not the final price. Rewrites, illustrations and generated music require approval in VoxClip; **Find sound · free** needs its own click. No tool sends an asset request.

### Make a story from two recordings

`read_transcript`, `read_clips` and `read_takes` list `recordings` with each recording's key, label, duration in seconds, inclusive `firstWord` and `lastWord`, `transcribed` status and `gainDb`. Words and clip parts carry the `recording` label and `recordingKey`. Join the word ids in `read_takes` to the indices in `read_transcript`. Each part must stay inside one recording, but consecutive parts can come from different recordings and play in either order.

For example, if the payoff from recording 0010 is at indices 42–51 and the setup from 0007 is at 9–18:

```json
{
  "newClip": {"kind": "story", "title": "The reporting tool"},
  "reason": "Lead with the payoff from 0010, then explain it with 0007.",
  "parts": [{"startWord": 42, "endWord": 51}, {"startWord": 9, "endWord": 18}]
}
```

A recording marked `transcribed: false` has no project indices yet. For a companion with a cached local transcript, call `read_transcript` with its `recordingKey` (CLI: `--recording-key KEY`) to preview the indices it will have if added. Include `"edits": [{"op": "useRecording", "key": "COMPANION_CONTENT_KEY"}]` in the proposal to add it before applying the parts. Use the recording's actual `key`, not its label or footage key. Only one recording can be added per timeline.

If there is no cached transcript, propose `useRecording` on an existing clip without using the new words yet. **Keep** transcribes using the project's local engine, then adds the recording and applies the other changes as one Undo step. Save and read the updated transcript before proposing parts from the new words. The agent never starts transcription or sends media. If the project only has a cloud engine, VoxClip refuses the operation: “Transcribe 0010 in VoxClip first.”

### Edit existing timeline items

Call `read_decisions` for the clip. Its `timeline` has the editor's item IDs, lanes and rows, word anchors, edited intervals, hidden markers, seam notches, snap targets and current shape. An item's `paid` flag describes the existing asset, not the cost of editing it. Copy the item IDs as returned; use `shape.track` for `setDuck`.

```json
{"clipId":"clip-2f1c","reason":"Start on the next word and let the music trail off.","edits":[
  {"op":"trim","item":"clip:clip-2f1c","edge":"start","toWord":10},
  {"op":"fade","item":"music:music-bed/seg-1","edge":"out","seconds":1.5}
]}
```

Use `toWord` or `atWord` for positions: a trim to an `end` uses the end of that word; other anchors use its start. `fromSeconds` and `atSeconds` identify existing gain points by their item-local time in `shape.gainPoints`. `bySeconds` slips the media under the item. See the [timeline schema](../shared/schemas/harness-timeline.schema.json) for all commands. VoxClip applies them in order as one **Keep timeline proposal** undo step. If any edit is refused, the exact reason appears on that proposal row and none of its changes apply. The CLI also returns the reason in `refusals`. Edits never appear in `pricedActions`.

For new placements, use `fadeIn` and `fadeOut` on supported effects. A sound can also set `gainDb`, `soundFrom` (seconds into the sound), and `volume` points as `[{"word":14,"db":-6}]`. In `music`, either a saved `trackId` or a paid `brief` can set `fadeIn`, `fadeOut`, `duckDb` (zero turns it off) and `segments`, for example `[{"startWord":10,"endWord":15,"songFrom":4,"loop":true}]`. Omit `segments` for the usual continuous bed.

### Motion templates

Add a `motionTemplate` to `effects` with a `template` object, for example:

```json
{"kind":"motionTemplate","startWord":9,"endWord":15,"reason":"Show the improvement.","template":{"name":"counter","from":0,"to":100}}
```

| `template.name` | Parameters | What appears |
|---|---|---|
| `titleCard` | `text`, up to 80 characters | A full-frame card with an animated accent and centered title. |
| `kineticCaption` | `text`, up to 80 characters | Words reveal in sequence, separate from the clip's normal captions. |
| `logoSting` | `text`, up to 24 characters | A wordmark that pops in and settles. Use brand lettering, not a logo file or URL. |
| `counter` | `from` and `to`, integers from −999999 to 999999 | A number counts up or down and holds briefly on the final value. |

Text must be a single nonempty line with no leading or trailing whitespace. The template starts and ends with the selected words, not the file's start or the render clock. VoxClip draws it locally in the same compositor for preview and export. Templates can't fetch assets, invoke providers, or authorize a charge. Keeping a template uses the same Keep/Undo review as other edits.

## Review in VoxClip on Mac or Windows

- Save edits before asking the agent to propose. The server reads the saved file, not unsaved edits in the editor.
- The open project shows **Timeline proposal** above its transcript. Expand **Proposed changes** to see the agent's edits and reasons. Each timeline has its own **Keep** and **Undo**. Keep applies that timeline's local changes as one edit; Undo dismisses only that timeline. After Keep, ⌘Z on Mac or Ctrl+Z on Windows undoes the edit as usual.
- Keeping the timeline doesn't send anything. If it includes music generation, open the proposed clip and use **Get price** if needed. The separate **Generate music · $…** button sends the brief to Eleven Music. The estimate returned to the agent isn't approval. Voice consent stays in the app's existing flows and can't be requested or recorded through these tools.
- There's one pending proposal per saved project. New sidecars use the version 2 `timelines` array; VoxClip still reads version 1 sidecars with a single `timeline`. Finish reviewing the series before staging another. If the app says the project changed, dismiss the old proposal, save, and have the agent read the current project again. If an externally edited proposal can't be read, remove only the neighboring `Talk.voxclip.proposal.json` file; leave `Talk.voxclip` in place.

## In-app tool surface

Both hosts dispatch through Core's `HarnessTools`. The live host supplies the open project snapshot; the CLI still reads one saved file and is the only host that stages a `.voxclip.proposal.json` sidecar. The CLI's tool list and timeline schema do not change.

- In live `propose_timeline` calls, `label` names the changes on each timeline and `revises` names a pending turn. For a series, put `revises` next to `timelines` and each `label` on its own timeline. Core returns the revision id and aligned labels for the live host; it does not replace the turn itself. The CLI refuses `revises` with “Revising is only for the in-app chat.”
- `check` takes a clip id and optional targets and forwards them to the host's timeline checker. These are plan checks, not the exported-file check. Timeline check rules are implemented separately in T7.
- `find_music` takes a mood and length in seconds. It searches only the free Openverse library and the host-approved Music folder. Track ids can be used as `music.trackId`; the live host supplies the existing free audio importer, which receives only tracks returned by that session's search. The reply contains no file paths or download URLs.
- `offer` returns an id and a local quote only. No provider, approval, or spend API is available to the tool. Music and illustration use the same quote as a timeline proposal; the live host supplies the applicable Make it postable cap.
- `point_to` returns a panel link and optionally a target; it doesn't open anything itself.

The [live tool input schemas](../shared/schemas/agent-tools.schema.json) are generated with `python3 tools/schemas/generate_agent_tools_schema.py`. None of the four live-only tools is exposed over stdio.

## Run the offline contract replay

On macOS, install the `jsonschema` Python dependency, then run `python3 tools/schemas/test_harness_contract.py`. It uses the Mac CLI build above and denies network access to every CLI subprocess. To replay only the `edits` timeline, append `HarnessContract.test_edits_use_timeline_decisions_without_spending`. To test the Windows CLI built with .NET on macOS, run:

```sh
dotnet build apps/windows/src/VoxClip.Cli -c Release -m:2
VOXCLIP_CLI="$PWD/apps/windows/src/VoxClip.Cli/bin/Release/net10.0/voxclip-cli.dll" \
  python3 tools/schemas/test_harness_contract.py
```

The Windows CLI's JPEG case needs the project's pinned LGPL FFmpeg 9 libraries built for the test host, beside the DLL. If those libraries aren't available, run individual cases such as `HarnessContract.test_replays_reads_and_stages_schema_valid_proposal` and `HarnessContract.test_places_local_motion_templates_through_mcp_and_cli` with the same `VOXCLIP_CLI` setting. See [ADR-R52](adr/R52-project-harness-mcp.md) for the tool and spending boundary.
