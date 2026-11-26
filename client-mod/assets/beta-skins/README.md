# Beta weapon skins and player models

`source/build_beta_skins.py` generates the shop's Beta collection and the
player models into `cod4/`:

- the Glitch ("Neon Corrupt") skin for the Desert Eagle and the RPG, with the
  RPG's rockets and the shop icons;
- the dark default player model and the black Beta player model with a beta
  mark on its backpack, with matching heads and first-person hands;
- a trimmed `weapons/mp/deserteagle_mp` that lets player models supply the hands.

Run it on a machine with the game and Mod Tools; it prints a SHA-256 manifest of
every file it writes:

```sh
python3 -B source/build_beta_skins.py --game-main GAME/main \
    --stock-raw MOD_TOOLS/raw --stock-deagle UNLINKED/weapons/mp/deserteagle_mp
```

`--stock-raw` needs the stock xmodel, xmodelsurfs, xmodelparts, materials and
material_properties named in the script. `--stock-deagle` is the stock
Desert Eagle weapon file exported from the game's fastfiles, for example with
the OpenAssetTools Unlinker. Add `--preview-dir` for PNG copies of the textures.

## Provenance and licensing

These outputs are derived from Call of Duty 4 stock assets: recoloured stock
textures, stock materials, models and weapon files with renamed references,
and stock body meshes with new texture coordinates for the backpack mark. The
stock inputs come from the user's licensed game and the CoD4 Mod Tools and are
not stored in this repository.

The derived files are distributed as part of the OpenCJ mod, as with the other
stock-based files in `cod4/`. Their redistribution terms follow the Call of Duty 4
Mod Tools license and have not been separately reviewed. Resolve that before
publishing them anywhere other than the mod download.

## Mesh notes

- The Desert Eagle's grip, slide and barrel texture areas are shared by both
  sides of the gun, mirrored, so lettering would read backwards on one side.
- In first person the RPG tube passes the camera. Its triangles are found from
  the mesh and painted from their 3D position (`TubeStripes`), so the neon lines
  run straight along the tube whatever the texture layout.
- The body texture's back is mirrored across the spine, so the backpack pieces
  get new texture coordinates in the map's unused lower half (`BackpackMark`).
- DXT1 rounds near-black greys towards green; player textures are snapped to
  grey levels it stores exactly (`dxt1_neutral`).
