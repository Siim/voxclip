# Looks

`clip-looks.json` (`voxclip-clip-looks/1`) is the one list of clip looks. The Mac and Windows apps, the planner prompt
and the vector generators read it; nothing copies it. The design is the looks spec of 2026-11-28 (sections 4 and 8) and
doc/design.md section 6.9.

## Shape

- `categories`: `{id, label}` in display order (natural, bright, warm, film, cinematic, bw).
- `measure`: the shared numbers for Auto (`auto`) and the planner's light notes (`light`).
- `looks`: the looks in display order. Each holds `id`, `label`, `category`, `strength` (`light`, `medium` or `strong`),
  `line` (one line for help, screen readers and the prompt), `planner` (`pickWhen` and the `amount` the planner starts at
  on a face), `classic` (one of the eight looks projects used before this file), an optional `hidden`, `base` (one of the
  `look` IDs `original`, `muted`, `warm`, `bw`), `adjustments` (`brightness`, `contrast`, `saturation`, `warmth`) and
  `grade` (`highlights`, `shadows`, `vibrance`, `fade`, `vignette`, `grain`, an optional `curve` and `splitTone`). A
  missing number means 0. Ranges match a project's `colorAdjustments` and `colorGrade`.

## The test card

`test-card.png` is the synthetic picture looks are shown on before a clip's own frame is ready, or while its source is
offline: a sky, a skin ramp through the spec's skin swatches, sixteen neutral greys, eight saturated hues, and a dark corner
beside the grade vectors' swatches. Goldens, mockups and screenshots use it too; footage never stands in for it. Regenerate
it with `python3 tools/looks/make_test_card.py` (check_drift.py checks its decoded pixels). Do not edit it by hand.

## Rules the Cores enforce

- A look never sets the Fix: `exposure`, `temperature` and `tint` belong to the clip, never to a preset.
- IDs follow labels: for every look but As filmed (`original`), the label with case and non-letters dropped equals the ID
  with case dropped ("Teal & Amber" is `tealAmber`).
- Shipped values are frozen. To retune a look after a release, add it under a new ID and keep the old entry, with
  `"hidden": true` if it should leave the pickers, so a project whose `colorGrade.preset` names it still shows its name.
  `shared/fixtures/looks/frozen-looks.json` holds the last release's looks and both Cores check the file against it.
- Names are generic: no film stock, filter, app or profile names.

A project stores a look's values expanded, never a reference to this file, so editing it never changes an existing
project's picture or export fingerprint.
