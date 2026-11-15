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

Run source/build_flag_atlas.py on the authoritative server with Pillow and
CairoSVG available. It writes the eight images/materials, technique/techsets,
source/flag_atlas_manifest.json and sibling server-gsc/opencj/flagatlas.gsc.
Keep all of those outputs together. Existing country order is explicit in the
provenance file; every change must regenerate the GSC mapping too.

Client builds use the unchanged installed Windows makeMod.py. The tracked
source/build_client_assets_windows.py is copied into a private _<task>/source
folder inside the permitted Mod Tools Mods/opencj/cod4 directory. Copy
source/flag_atlas.hlsl there as opencj_flag_atlas.hlsl. Put the approved cod4
inputs in _<task>/stage and the license files in stage/licenses. Transfer these
server-owned build inputs, never a local source checkout. Preserve currently
deployed versions of unrelated unfinished menus and IWD entries when staging.

Run the helper with Windows Python; --mod-tools and --game-dir can select an
existing installation. It compiles the shader through Windows d3dcompiler_47,
registers it only in its private shader lookup, invokes the original makeMod.py
in the isolated toolroot, and copies missing stock dependencies there. Outputs
are toolroot/Mods/proof/mod.ff and z_opencj.iwd; evidence includes compiler/linker
logs and hashes proving shared build inputs/outputs stayed unchanged.

Before deployment, unlink and compare the full build with the live package,
verify all SVG cells against decoded pixels, check both licenses and the image
loader budget, and run exact-release GSC tests. Follow
../../../dev-tools/docs/runbooks/client-asset-deployment.md for matching client/
server installation and the required full server-process restart.
