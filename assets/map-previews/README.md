# Map-list previews (#203)

The existing menu asks for a material named `loadscreen_<mapname>`. The original
map packages generally supply an image with that name behind `$levelbriefing`
in the map's loading zone; they do not supply the named UI material for browsing
other maps. The mod now bundles ten matching 2D materials and their images.

`source/map_previews.json` records source paths, archive/image hashes and capture
details. It is an asset inventory, not a voting allowlist. Game eligibility still
comes exclusively from `mapids.inRotation`. Maps outside that pool use
`opencj_logo_nobg` through the shared GSC preview helper, including uber-admin
votes and the map-list menu. End-map voting uses the same helper.

## Build and deploy

1. Add the preview image and provenance entry when preparing a new pool map.
2. On the authoritative source host, run `source/build_map_previews.py` with
   Python 3 and Pillow. It verifies source hashes and produces the 2D material
   binaries and `mod.csv` entries. Existing original IWI pixels are unchanged.
3. Stage the resulting images, materials, material_properties and `mod.csv` in
   the existing Windows Mod Tools build directory. Preserve its custom files
   and run its existing `makeMod.py` unchanged.
4. Retain `licenses/flag-icons.txt` in the final IWD: the legacy packer currently
   includes only images and weapons. Verify pre-existing IWD entries are
   byte-for-byte unchanged before deployment.
5. Deploy matching `mod.ff` and `z_opencj.iwd` to the server and client. Restart
   OpenCJ safely, retaining its active map; clients must reload the mod/reconnect.

## Bouncer Training artwork, 14 November 2026

Build on the authoritative host with:
