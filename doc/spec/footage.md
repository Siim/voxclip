# Card and folder import

On macOS, Home offers a removable volume containing `DCIM`. Open or drop a folder to use the same importer. Planning never deletes or edits the originals. The importer scans for supported video, identifies recordings by full SHA-256, and copies new selected recordings to `Movies/VoxClip/<name> <date>`. It saves a normal `.voxclip` project beside each copy, with the other selected recordings available as companion media. The full `recordingHash` does not replace the existing sampled `contentKey` used for relinking and caches.

When macOS asks for removable-volume access, VoxClip explains that it reads recordings for import and leaves the originals on the card unchanged.

**Make clips from {n} new · up to ${cap}** uses local transcription in two lanes, then the selected AI connector for Find Clips, ranking and planning. It states which AI receives words, recording names and selected still frames. First-use consent and metered AI sends use the normal inline approval; the card cap does not cover API-key AI charges. The single voice and lip-sync cap for the card is captured from the Clips spend-cap setting when the card starts; a $0 cap sends no paid voice or lip sync. Found clips are ranked together, with duplicate takes grouped. Stopping keeps saved projects and finished work. **Copy selected without making clips** needs no connector.

**Make one clip from these** copies and transcribes the selected recordings locally in the same two lanes. It saves their individual projects and a new project with the recordings on one spoken clock before asking to send. **Best versions** receives the transcripts, recording names, and selected still frames where supported. It proposes one story; the recording that contributes the most beats becomes the project's source, and the other spoken recordings stay in recording-time order. Stop keeps the saved projects. Metered AI sends still ask inline; this action spends none of the card's voice and lip-sync cap.

Without a connector, **Make one project from these** does the local work only and opens the combined project with no clip.

## Companion video

`media.source` is still the primary picture and audio. Schema v4 adds `media.additionalSources`, identified by `recordingHash` or `contentKey`, and optional `media.footage` placements. Clip-plan entries `bRoll`, `screenshot`, and `videoStack` use the same kept-word anchors as the other plan effects, with a companion key and a source start in seconds. A moving placement must fit its source; a still needs only the start frame. Placements on the same clip cannot overlap. A vertical video stack fills both halves; B-roll and screenshots replace the underlying picture in their interval. A companion **placement** is silent. A companion can also be a [spoken recording](../adr/R54-spoken-recordings-on-one-project-clock.md) with its own transcript and audio. Removing it from the spoken clock does not remove its picture or change how it is relinked.

Windows Core round-trips these fields and validates plan placements against the same fixtures as Swift. The Windows preview and exporter resolve and verify the companion file alongside the project, then use the same frame composer for all three placements. The interval is half-open on the edited clock. Moving footage is fitted to that interval; a screenshot holds one frame. Stacks place the edited primary picture above the companion, centre-cropping each to fill its half. Companion orientation comes from its own recording. Missing or changed files stop the render rather than silently dropping a placement. The card import UI remains macOS-only.

On Mac, moving footage now plays continuously at 1× from its companion start, even across a cut in the primary picture. Its slot follows the edited word range; a short companion runs out early and reveals the primary picture. Timeline fades dissolve to and from that picture without touching the primary audio.

## Export review

Batch export renders Ready clips, saves their covers when available, and collects their copy into `posts.txt` (`posts-16x9.txt` for the landscape export). The exporter applies its usual social loudness pass. It then reuses the local CLI self-check to inspect the written video for word matching, sync evidence, loudness, and caption safe area. The review identifies warnings, unavailable checks, and places to listen. It does not start a new paid take on a warning.
