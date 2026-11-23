# Final editable visual assets

This is the client-mod asset library. Keep final artwork and the inputs needed
to edit or regenerate it here and under `source/`; do not add brainstorm previews.

| Asset | Editable source / build recipe | Review artwork |
| --- | --- | --- |
| Checkpoint waypoint | `checkpoints/waypoint.svg`, `checkpoints/palette.json`, `source/build_checkpoint_materials.py` | `checkpoints/` |
| Competitive Top 10 | `ranks/competitive/competitive.svg`, `source/build_competitive_icon.py` | `ranks/competitive/` |
| Challenge ranks 1-10 | `ranks/rings/rank-*.svg`, `ranks/rings/palette.json`, `source/build_rank_icons.py` | `ranks/rings/` |
| Eight active mode badges | `source/build_mode_icons.py`, `source/mode-icons/*.svg` | `mode-icons/` |
| Optional Oldschool bunny | `source/mode-icons/rabbit.svg`, `source/build_mode_icons.py --oldschool-only` | `mode-icons/oldschool/`, including reusable symbol SVG |
| Branding | `source/build_logo.py` | `branding/` |
| Flags | `source/build_flag_atlas.py`, `source/flag_atlas_manifest.json` | `flags/flag-icons-v7.5.0/` |
| Map previews | `source/build_map_previews.py`, `source/map_previews.json` | `map-previews/` |
| Replacement map artwork | source and instructions alongside each map | `map-replacements/` |

Paths beginning with `source/` are relative to the client-mod root. Runtime
textures go in `cod4/images`; raw TGA inputs go in `source/texture_source`, next
to the earlier icon inputs. Existing `source/cod4/source_data/*.gdt` files remain
intact. Generated code-based badges are edited through their recipe and source
SVGs, not a missing layered Photoshop file. PNG/IWI alone are not the master.

The active rank and competitive masters are in `ranks/rings/` and `ranks/competitive/`.
Oldschool is a final exported asset for later use and is not enabled in game.
