# Context-demo project wire fixtures

These synthetic JSON fixtures contain no recordings, credentials or provider calls. Asset paths, hashes and sizes describe synthetic metadata, not real capture files. The source project is the existing synthetic `projects/interview-take.voxclip` fixture. Narration snapshots are persisted data; render currentness is checked separately by the Core planner.

Regenerate only with `python3 tools/fixtures/projects/generate_context_demo_v4.py --patch | apply_patch`; check drift with `python3 tools/fixtures/projects/generate_context_demo_v4.py --check`. Do not hand-edit expected cases. Review changes to the generator as cross-platform behavior changes.

`v4-project.voxclip` exercises both approved v4 fields and the required project ID plus source-content-key binding. `wire-cases.json` applies JSON-pointer replacements/removals to that project. Swift `ContextDemoV4WireTests` and C# `ContextDemoV4WireTests` consume the same valid and rejected cases. Both also load real existing v1/v2/v3 fixtures rather than constructing legacy documents by deleting new fields.

The schema rejects unknown keys, future versions, old-version feature keys, missing required keys and expressible field bounds. `schemaValid: true` on an invalid runtime case marks constraints JSON Schema cannot express: cross-object identity/source binding, canonical frame ordering/duration, sample-grid coverage, path ownership, unique identities, asset-trim bounds, edited-placement overlap, and per-clip budgets. Execute `python3 tools/schemas/test_context_demo_v4_schema.py` alongside the platform suites; it is not a substitute for them.

Compatibility limits: v4 uses the complete v3 Voice Lab policy; legacy saves never auto-upgrade. Feature mutation explicitly promotes through the existing reviewed v3 policy. Legacy v2 projects containing paid segments still require explicit review rather than inventing missing render recipes. Absent demo/empty motion are omitted on save. Sidecar codec import/export is explicit, not a second auto-discovered source. Actual asset bytes, hashes, streams and containment remain Media checks.
