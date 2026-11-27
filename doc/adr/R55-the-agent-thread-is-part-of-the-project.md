# ADR-R55: The agent thread is part of the project

Accepted 2026-11-27 · [Issue 34](https://github.com/Siim/voxclip/issues/34)

## Decision

Store one `agentThread` in the `.voxclip` file. Write schema v8 only when a thread exists. A project without chat keeps its previous version, including v7 for spoken companions. A v7 reader refuses v8 before validating its contents.

Store the effects of accepted reducer calls as per-change field patches, with the prior values as the checkpoint. Use stable IDs for array members. Keeping a turn commits no new media edits; its changes are already live. Undo restores just that turn when later edits are disjoint and requires confirmation before rolling back overlapping changes. Paid media stays in its existing asset store when a placement is undone.

## Alternatives

A sidecar would let an older build open the project, but the thread could be lost when a project is moved or saved separately. Two writes could also disagree on whether changes are applied. A session-only thread would lose the checkpoint on restart. Whole-project snapshots would let Undo overwrite unrelated edits and grow with project size rather than change size.

## Consequences

The thread travels and autosaves with the project. Pending changes remain applied on reopen; interrupted running turns are marked stopped. The history is limited to 200 cards and roughly 2 MiB, with pending checkpoints and the newest 30 kept checkpoints taking priority. Manual undo and the card's undo have separate responsibilities. See [editing §14](../spec/editing.md#14-agent-turns).
