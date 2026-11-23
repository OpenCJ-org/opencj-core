# Country flag atlas

Sources: pinned flag-icons v7.5.0 SVGs, archive/checksums and country order in
provenance.json. The existing individual flags came from the same icon family.
Keep licenses/flag-icons.txt in every packaged IWD. Do not generate national
flag artwork with AI. DB-IP updates do not alter flag artwork; adding/changing
country artwork is a deliberate client build, independent of monthly data.

The production catalogue has 256 entries, packed into eight 1024x1024 lossless
BGRA8 textures with full mip chains. Each flag is 128x96 in a 128px square,
with 16px extruded gutters and 160px cells. Each page holds up to 36 entries.
The shared shader chooses a cell using the draw color's encoded alpha, while
preserving the texture's actual alpha. The scoreboard sends material plus
selector, so no per-country material is registered. Unknown country draws the
existing default material directly; no extra unknown texture/material exists.

Each page's mip payload is 5,592,404 bytes, below the observed stock 6 MiB
image-load scratch buffer. Total texture payload is 44,739,232 bytes (42.67 MiB);
this is neither download size nor a measurement of total process/GPU overhead.
Do not combine these into 2048px BGRA pages: each would exceed that loader
buffer. Tiny scoreboard icons naturally cannot display subpixel emblem detail.

## Regenerate and build

Run source/build_flag_atlas.py from the client-mod directory with Pillow and
CairoSVG available. It writes the eight images/materials, technique/techsets,
source/flag_atlas_manifest.json and sibling server-gsc/opencj/flagatlas.gsc.
Keep all of those outputs together. Existing country order is explicit in the
provenance file; every change must regenerate the GSC mapping too.

For a private comparison build, select all three destinations with `--output`,
`--gsc-output` and `--manifest-output`. This keeps both the lookup and manifest
out of the working source tree. The generator checks the compiled material
template and image-loader size limit before accepting those formats.

Client builds use the unchanged installed Windows makeMod.py. Stage source/build_client_assets_windows.py in a private _<task>/source folder
under the selected Mod Tools Mods/opencj/cod4 directory. Stage the HLSL source
as opencj_flag_atlas.hlsl and the intended cod4 inputs under _<task>/stage.
Include license files. Preserve the installation's custom files and avoid
mixing unrelated unfinished assets into the staged build.

Run the helper with Windows Python; --mod-tools and --game-dir must identify an
existing installation. It compiles the shader through Windows d3dcompiler_47,
registers it only in its private shader lookup, invokes the original makeMod.py
in the isolated toolroot, and copies missing stock dependencies there. Outputs
are toolroot/Mods/proof/mod.ff and z_opencj.iwd; evidence includes compiler/linker
logs and hashes proving shared build inputs/outputs stayed unchanged.

Before deployment, unlink and compare the full build with the live package,
verify all SVG cells against decoded pixels, check both licenses and the image
loader budget, and run exact-release GSC tests. Follow
../../../docs/operations/client-assets.md for matching client/
server installation and the required full server-process restart.
