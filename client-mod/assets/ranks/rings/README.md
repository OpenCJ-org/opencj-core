# Continuous-ring ranks

The rounded continuous ring, one color per rank,
with a spectrum finish at rank 10. A solid dark backing connects the center
to the outer ring so world scenery cannot show through the gap. Every rank retains the same neutral center,
white numeral, circle geometry and stroke weight. Progress is rank / 10,
clockwise from twelve o'clock.

## Edit and rebuild

- `rank-1.svg` through `rank-10.svg` are editable artwork. Each has named center,
  track, progress/spectrum and number elements. Text stays editable.
- `palette.json` controls every color, spectrum stop, ring dimension and font size.
- `source/build_rank_icons.py` (from the client-mod root) regenerates SVGs and exports.
- PNGs are transparent 512 px review exports. TGA build inputs are in
  `source/texture_source/opencj_rank_*.tga`; IWI runtime textures are in
  `cod4/images/opencj_rank_*.iwi`.
- `manifest.json` records source and output hashes; `size-preview.png` shows
  the actual 15, 26 and 28 pixel samples as well as an enlarged row.

From the client-mod directory:

    python3 source/build_rank_icons.py

For direct manual SVG edits, preserve them with:

    python3 source/build_rank_icons.py --render-only

Dependencies: Pillow, CairoSVG and Nimbus Sans Bold from fonts-urw-base35.
The SVG font fallback can be changed in palette.json before rebuilding.
Install the font separately; it is not redistributed as an asset.

Rank 10 uses overlapping color sectors under one circular SVG mask. All ten
textures render at 4x size and downsample with Lanczos, then receive a complete
RGBA mip chain. This avoids the separate hard-edged CSS mask used by the draft.

No brainstorm previews belong to this final-asset folder.

Challenge tabs draw these at 28 x 28 units, centered in their former 40-unit slots.
The personal progress summary uses 26 units; the Escape badge retains 15 units.
