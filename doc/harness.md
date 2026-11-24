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
| `read_transcript` | `transcript --project Talk.voxclip --offset 0 --limit 200` | Returns transcript items with their zero-based indices, corrected words, cut flags and source seconds. Follow `nextOffset` until it's null. |
| `read_clips` | `clips --project Talk.voxclip` | Lists kept and suggested clips with ids, inclusive word indices and source spans. |
| `read_decisions` | `decisions --project Talk.voxclip --clip CLIP_ID` | Reads the clip's saved choices: Find Clips reason where available, opening lead-in, framing and cover controls, captions, effects, zooms and saved music ids. |
| `read_frames` | `frames --project Talk.voxclip --time 2.1 --time 3` | Returns one to four unedited source thumbnails from a local MP4, M4V or MOV. CLI output includes JPEGs as base64. Relink missing media in VoxClip. |
| `propose_timeline` | `propose-timeline --project Talk.voxclip < timeline.json` | Stages a proposal for one existing clip. It writes no project edits and returns separate estimates for requested paid actions. |

You might ask: “Read the clips and the transcript. For the clip about editing faster, propose a punch-in on the strongest sentence and a short on-screen title. Don't generate anything.”

The [timeline schema](../shared/schemas/harness-timeline.schema.json) is also the proposal tool's input schema. For example:

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

Use inclusive transcript indices from the current project. Cuts change the source's shared cut list, so overlapping clips also reflect them. Effects need kept spoken-word anchors and a span of 0.1–5 seconds. Use `zoom`, `punchIn`, `motionTitle`, `lowerThird`, `emojiPop` (bundled stickers), or `motionTemplate`. `musicTrackId` reuses a saved track; `generateMusic` instead describes a new track and returns a local estimate.

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

## Review in VoxClip on macOS

- Save edits before asking the agent to propose. The server reads the saved file, not unsaved edits in the editor.
- The open project shows **Timeline proposal** above its transcript. Expand **Proposed changes** to see what the agent wants to do. **Keep** applies the free changes as one edit; **Undo** dismisses the proposal without changing the project. After Keep, ⌘Z undoes the edit as usual.
- Keeping the timeline doesn't send anything. If it includes music generation, open the proposed clip and use the separate **Generate music · $…** button after VoxClip confirms the price. That click sends the brief to Eleven Music. The estimate returned to the agent isn't approval. Voice consent stays in the app's existing flows and can't be requested or recorded through these tools.
- There's one pending proposal per saved project. Finish reviewing it before staging another. If the app says the project changed, dismiss the old proposal, save, and have the agent read the current project again. If an externally edited proposal can't be read, remove only the neighboring `Talk.voxclip.proposal.json` file; leave `Talk.voxclip` in place.

The Windows CLI validates and stages the same proposal format, but the Windows editor does not yet offer Keep/Undo for it. Staging makes no edits and doesn't start a paid action. To dismiss a pending proposal on Windows, remove only the neighboring `.voxclip.proposal.json` file.

## Run the offline contract replay

On macOS, install the `jsonschema` Python dependency, then run `python3 tools/schemas/test_harness_contract.py`. It uses the Mac CLI build above and denies network access to every CLI subprocess. To test the Windows CLI built with .NET on macOS, run:

```sh
dotnet build apps/windows/src/VoxClip.Cli -c Release -m:2
VOXCLIP_CLI="$PWD/apps/windows/src/VoxClip.Cli/bin/Release/net10.0/voxclip-cli.dll" \
  python3 tools/schemas/test_harness_contract.py
```

The Windows CLI's JPEG case needs the project's pinned LGPL FFmpeg 9 libraries built for the test host, beside the DLL. If those libraries aren't available, the remaining cases can be run individually with `python3 tools/schemas/test_harness_contract.py HarnessContract.test_replays_reads_and_stages_schema_valid_proposal` and the same `VOXCLIP_CLI` setting. See [ADR-R52](adr/R52-project-harness-mcp.md) for the tool and spending boundary.
