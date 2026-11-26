# ADR-R52: Give an agent a project, not the VoxClip command line

Accepted 2026-11-24 · [Issue 18](https://github.com/Siim/voxclip/issues/18)

## Decision

`voxclip-cli mcp --project` starts a stdio MCP server pinned to a saved project's canonical path and id. It advertises exactly four reads and one proposal tool. Tool calls don't accept a path, provider, endpoint, credentials, approval or command to execute. The standalone CLI commands use the same handlers; the server never dispatches to the general CLI parser or to `autopilot`, `find-clips`, transcription, export, Rewrite, publishing or consent. Reads do not use provider clients or account data. Frame reads verify the saved media identity and use local decoding with external asset references disallowed.

The [proposal envelope](../../shared/schemas/harness-proposal.schema.json) holds a version, project id, revision and [timeline](../../shared/schemas/harness-timeline.schema.json). It contains intent, not a second project, project patches, URLs, executable recipes or a signed approval. Reuse `ClipPlanEffect`, existing edit commands, the project's caption and music settings, and the shared compositor. Validate the resulting document through the same project reader/writer contract before staging and again against the open project before Keep. Don't guess new anchors if the reference edit changed.

Stage a single file, `<project>.proposal.json`, alongside its canonical project path. Publish it atomically without replacing a pending review. A read, a failed validation or a refused second proposal does not change the `.voxclip` file. The open project's inline review applies the changes as one normal undoable edit or dismisses them. Changing tabs alone doesn't invalidate the proposal.

The only priced intent in this version is an Eleven Music brief. The CLI computes an estimate from the bundled price catalog without credentials, network access, or spend and returns it as a separate action. Keep never starts the paid step. The Mac and Windows editors use the existing Music quote and confirmation flow to price the open clip and accept only a separate priced button click. The existing Music pipeline stores the returned asset before attaching it to the project. No agent proposal can approve a charge, attest to consent, or install a voice.

## Trade-offs

A saved project gives agents stable anchors, with no socket or app-session credentials. Unsaved edits are intentionally invisible to the agent and can make an otherwise valid proposal stale. One pending sidecar prevents concurrent agents overwriting each other's work. The user's agent may send read results to its own model; VoxClip doesn't make that decision for it. A new sidecar format leaves existing `.voxclip` versions unchanged except when Keep adopts an existing v4 feature such as motion or effects.

A generic project patch or CLI proxy would offer more operations, but it would expose unrelated state and paid commands. An embedded scripting engine would let agents bypass timeline validation and the shared renderer. Neither is part of this surface. Named motion templates are fixed compositor graphics carried as a bounded `ClipPlanEffect` payload and saved as clip effects; nothing in them names an asset, endpoint or executable. Both editors use the same proposal format as their CLI and MCP tools.

The contract replays the MCP wire and CLI against a fixture with the subprocess network denied, rejects paid, consent and arbitrary-project calls, and validates both the proposal envelope and the materialized project against their shared schemas.
