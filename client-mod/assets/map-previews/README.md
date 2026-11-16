# Map-list previews

The menu requests `loadscreen_<mapname>` materials. Original map archives
usually provide loading images without the UI materials needed to browse other
maps. The mod supplies matching preview materials and a missing-image fallback.

Eight previews reuse original map-package imagery. Bouncer Training and Futile
use actual game captures of their starting areas. These are recorded images,
not generated reconstructions. The source catalogue records image provenance,
hashes and conversion details. It does not record permission to redistribute
map artwork separately. See [licenses and asset sources](../../../docs/reference/licensing.md)
for the unresolved publication review; mapper credit and public downloads alone
do not settle that question.

`source/map_previews.json` is an asset inventory, not a voting allowlist.
Eligibility comes from `mapids.inRotation`. The shared preview helper serves
the map list and end-map votes; absent artwork uses `opencj_missing_image`.
Intentional branding continues to use `opencj_logo_nobg`.

## Generate and package

Run from the client-mod directory with Python and Pillow:

```sh
python3 source/build_map_previews.py
```

The generator verifies source hashes and writes images, 2D materials and mod.csv
entries. Original reused IWI pixels remain unchanged. Inspect the compiled
materials and images, preserve unrelated IWD entries, and retain all license
files. Follow the [preview guide](../../../docs/development/map-previews.md)
and [client deployment procedure](../../../docs/operations/client-assets.md).

## Bouncer Training replacements

The starting-area image replaces the loading image and map-list preview.
The map's `christina` and `compass_map_mp_bouncer_training` pictures use the
question-mark artwork in `../map-replacements/mp_bouncer_training/`.
The replacement preserves the original image headers, dimensions, compression
formats and byte lengths; it does not alter map geometry or scripts.

Supply the original archive and a separate output directory explicitly.
From the repository root:

```sh
python3 dev-tools/scripts/build-bouncer-art.py --map-iwd "$MAP_IWD" --output-dir "$OUTPUT_DIR"
```

Keep the input archive and deployment backups private. For an image-only mod
IWD update, replace only the intended image entries and preserve all other
content. Stage the matching source inputs so later builds retain the change.

## Missing-image materials

The dedicated preview fallback and built-in `default` image use the same dark
question-mark artwork. They remain separate from the logo.
`python3 source/build_missing_image.py` regenerates the default IWI and TGA,
preserving dimensions, flags and mip levels. UI placeholders use lossless
pixels; in-map replacements retain their original DXT1 layout.
