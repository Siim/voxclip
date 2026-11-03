# Join advisory recipe vectors

Run `python3 tools/fixtures/voice-lab/generate_join_advisory.py` to regenerate these independent vectors.
Do not add categories to existing fixture files. Swift and C# replay this file against the same base
project for schema versions 3 and 4. `qa` merges into the first candidate's render QA; mirror
`transcriptMatch`, `lufsJumpLu`, `peakDbfs` and `speakerScore` into the segment's summary QA.

`schemaValid` tests wire shape; `valid` also requires render policy, including a unique left/right
seam list, measurements matching the stored maximum and acceptance no later than recipe creation.
An acceptance never waives words, clipping, speaker or consent policy. Old clean projects need no field.
