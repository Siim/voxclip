# Card and folder import

On macOS, Home offers a removable volume containing `DCIM`. Open or drop a folder to use the same importer. Planning never deletes or edits the originals. The importer scans for supported video, identifies recordings by full SHA-256, and copies new selected recordings to `Movies/VoxClip/<name> <date>`. It saves a normal `.voxclip` project beside each copy, with the other selected recordings available as companion media. The full `recordingHash` does not replace the existing sampled `contentKey` used for relinking and caches.

When macOS asks for removable-volume access, VoxClip explains that it reads recordings for import and leaves the originals on the card unchanged.

The priced card action uses local transcription in two lanes and requires Claude Code signed in to the Claude plan. It sends words, recording labels, and selected stills for Find Clips and planning. Found clips are ranked together, with duplicate takes grouped. Make it postable uses the same voice and lip-sync authorization and a single fixed cap across the card. Stopping keeps saved projects and completed work. The copy-only path needs no connector.

## Companion video

`media.source` is still the primary picture and audio. Schema v4 adds `media.additionalSources`, identified by `recordingHash` or `contentKey`, and optional `media.footage` placements. Clip-plan entries `bRoll`, `screenshot`, and `videoStack` use the same kept-word anchors as the other plan effects, with a companion key and a source start in seconds. A moving placement must fit its source; a still needs only the start frame. Placements on the same clip cannot overlap. A vertical video stack fills both halves; B-roll and screenshots replace the primary picture in their interval. Companion video is silent. The transcript and sound remain anchored to the primary recording.

Windows Core round-trips these fields and validates plan placements against the same fixtures as Swift. The Windows preview and exporter resolve and verify the companion file alongside the project, then use the same frame composer for all three placements. The interval is half-open on the edited clock. Moving footage is fitted to that interval; a screenshot holds one frame. Stacks place the edited primary picture above the companion, centre-cropping each to fill its half. Companion orientation comes from its own recording. Missing or changed files stop the render rather than silently dropping a placement. The card import UI remains macOS-only.

## Export review

Batch export renders Ready clips, saves their covers when available, and collects their copy into `posts.txt` (`posts-16x9.txt` for the landscape export). The exporter applies its usual social loudness pass. It then reuses the local CLI self-check to inspect the written video for word matching, sync evidence, loudness, and caption safe area. The review identifies warnings, unavailable checks, and places to listen. It does not start a new paid take on a warning.
