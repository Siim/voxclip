"""Reference implementation of the VoxClip caption layout and timing spec (doc/spec/captions.md).

It decides everything that must be bit-identical across platforms (text normalisation, shaping
widths in font units, paging, line breaks, shrink, placement, page timing, word states and
animation values). It does not rasterise; pixel goldens come from the platform renderers.
"""
