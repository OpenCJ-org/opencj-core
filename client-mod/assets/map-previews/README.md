# Map-list previews

The menu requests `loadscreen_<mapname>` materials. Original map archives
usually provide loading images without the UI materials needed to browse other
maps. The mod supplies matching preview materials and a missing-image fallback.

Eight previews reuse original map-package imagery. Bouncer Training and Futile
use actual game captures of their starting areas. The source catalogue records
image provenance, hashes and conversion details.

These previews are retained based on the maintainer's understanding of the
community's established map-sharing practice. No formal asset license or
separate permission text has been recorded. The
[packaged attribution notice](../../licenses/map-previews.txt) preserves mapper
credits and source links; it does not grant additional rights or place map and
game artwork under the project license. See
[licenses and asset sources](../../../docs/reference/licensing.md#map-preview-artwork)
for the recorded status.

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

## Futile loading screen

The connection screen uses `$levelbriefing` from the map's `_load.ff`, separately
from the named preview material bundled in `mod.ff`. Futile's loading-zone inputs
are in `loading/maps/mp_futile_fixed.csv` and
`loading/zone_source/mp_futile_fixed_load.csv`. They reference the existing
`loadscreen_mp_futile_fixed` image, so both screens use the same artwork.

To build the loading zone in an isolated CoD4 Mod Tools staging directory,
retain the stock `zone_source/english/assetlist/` files used by its `ignore`
entries:

1. Copy `loading/maps/mp_futile_fixed.csv` into `raw/maps/` and the zone CSV
   into `zone_source/`.
2. Copy `cod4/images/loadscreen_mp_futile_fixed.iwi` from the client-mod root
   into `raw/images/`, preserving its filename.
3. From the staged `bin/` directory, run
   `linker_pc.exe -language english -compress -cleanup mp_futile_fixed_load`.
4. Verify the output contains `$levelbriefing` referencing
   `loadscreen_mp_futile_fixed`, then deploy only `mp_futile_fixed_load.ff`
   to the map's existing server and client directories. Keep its main map
   fastfile and any map IWD unchanged.

The image remains in the OpenCJ IWD; this loading zone is for OpenCJ clients
with those assets installed. Keep the existing map-preview attribution notices.
Follow the [client deployment procedure](../../../docs/operations/client-assets.md)
for matching files, backups and server restart requirements.
