# Look fixtures

Synthetic data only, for the looks in `shared/looks/clip-looks.json` (looks spec 2026-11-28, sections 4, 8.3 and 9.6).

- `frozen-looks.json` (`voxclip-frozen-looks/1`): the looks of the last release, which never change. A retune ships under a
  new ID and the old entry stays in clip-looks.json, `"hidden": true` if it should leave the pickers. No release has
  shipped yet, so it holds the eight looks projects already used before the library (the four base looks and Clean Pop,
  Soft Light, Cool Film and Vintage Fade). Hand-maintained: when a release ships, copy every look it shipped into this file
  (`id`, `label`, `base`, `adjustments`, `grade`) and write the release's version in `release`. Swift
  `ClipLookLibraryTests.shippedLooksAreFrozen` and C# `ClipLookLibraryTests.ShippedLooksAreFrozen` check it.
- `look-cases.json` (`voxclip-look-cases/1`): which look a clip's colour state shows as applied or edited, and
  `ClipControlsProject.settingLookPreset` on the clip-controls fixture project. Regenerate with
  `python3 tools/fixtures/looks/generate_look_cases.py` (check_drift.py runs it); do not hand-edit. Swift and C#
  `ClipLookRuleTests` replay it.
