# Card and folder import

On macOS, Home offers a removable volume containing `DCIM`. Open or drop a folder to use the same importer. Planning never deletes or edits the originals. The importer scans for supported video, identifies recordings by full SHA-256, and copies new selected recordings to `Movies/VoxClip/<name> <date>`. It saves a normal `.voxclip` project beside each copy, with the other selected recordings available as companion media. The full `recordingHash` does not replace the existing sampled `contentKey` used for relinking and caches.

When macOS asks for removable-volume access, VoxClip explains that it reads recordings for import and leaves the originals on the card unchanged.

**Make clips from {n} new · up to ${cap}** uses local transcription in two lanes, then the selected AI connector for Find Clips, ranking and planning. It states which AI receives words, recording names and selected still frames. First-use consent and metered AI sends use the normal inline approval; the card cap does not cover API-key AI charges. The single voice and lip-sync cap for the card is captured from the Clips spend-cap setting when the card starts; a $0 cap sends no paid voice or lip sync. Found clips are ranked together, with duplicate takes grouped. Stopping keeps saved projects and finished work. **Copy selected without making clips** needs no connector.

## Companion video

`media.source` is still the primary picture and audio. Schema v4 adds `media.additionalSources`, identified by `recordingHash` or `contentKey`, and optional `media.footage` placements. Clip-plan entries `bRoll`, `screenshot`, and `videoStack` use the same kept-word anchors as the other plan effects, with a companion key and a source start in seconds. A moving placement must fit its source; a still needs only the start frame. Placements on the same clip cannot overlap. A vertical video stack fills both halves; B-roll and screenshots replace the primary picture in their interval. Companion video is silent. The transcript and sound remain anchored to the primary recording.

Windows Core round-trips these fields and validates plan placements against the same fixtures as Swift. Card UI and companion compositing are macOS features.

## Export review

Batch export renders Ready clips, saves their covers when available, and collects their copy into `posts.txt` (`posts-16x9.txt` for the landscape export). The exporter applies its usual social loudness pass. It then reuses the local CLI self-check to inspect the written video for word matching, sync evidence, loudness, and caption safe area. The review identifies warnings, unavailable checks, and places to listen. It does not start a new paid take on a warning.
