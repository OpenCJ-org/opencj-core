# Checkpoint waypoint

The editable `waypoint.svg` master replaces the CoD4 checkpoint arrow with a
hollow location pin. Its transparent canvas and black contrast edge work over
both bright scenery and the minimap. `waypoint.png` is the white tint master.

## Rebuild

From `client-mod`, using Python with Pillow and CairoSVG installed:

```sh
python source/build_checkpoint_materials.py
```

The generator preserves manual SVG edits. `palette.json` retains the seven
legacy colors, the white HUD tint source, and the existing eight minimap route
colors. It renders at four times the final size and writes 512 px RGBA textures
with a complete mip chain and the original clamp flags. Final TGA inputs live
in `source/texture_source`; CoD4 IWI outputs live in `cod4/images`.
`manifest.json` records the editable inputs and generated outputs.

## Consumers and color behavior

Both existing material families retain their names and techniques: the base
materials support world sprites; `_obj` materials support screen markers and
compass objectives. Every CoD4 checkpoint texture uses the same pin geometry.
Marker sizes, positions, visibility settings, moving-checkpoint updates, and
screen-edge direction arrows are controlled by the existing game code.

HUD/world markers accept arbitrary route RGB through the white tint texture.
Stock compass objectives have no RGB field, so custom route colors still use
the nearest existing palette material on the minimap. This artwork change does
not alter that engine limitation or expand the palette. CoD2's shipped IWI
textures and materials are unchanged; this generator targets CoD4.

## Provenance

The geometry derives from Lucide 0.468.0 `map-pin`, under the ISC license.
`source/map-pin.svg` retains the original input. `source.json` records its URL,
hash and modifications. `LICENSE-lucide.txt` contains the required notice;
the same notice is packaged as `licenses/lucide.txt` in the CoD4 IWD.
